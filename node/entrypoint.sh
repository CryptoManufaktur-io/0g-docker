#!/usr/bin/env bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/data}"
NETWORK="${NETWORK:-aristotle}"
CHAIN_ID="${CHAIN_ID:-16661}"
MONIKER="${MONIKER:-0g-node}"
SNAPSHOT="${SNAPSHOT:-}"
LOG_LEVEL="${LOG_LEVEL:-info}"
RPC_PORT="${RPC_PORT:-8545}"
WS_PORT="${WS_PORT:-8546}"
AUTH_RPC_PORT="${AUTH_RPC_PORT:-8551}"
GETH_P2P_PORT="${GETH_P2P_PORT:-30303}"
GETH_METRICS_PORT="${GETH_METRICS_PORT:-9001}"
CL_RPC_PORT="${CL_RPC_PORT:-26657}"
CL_P2P_PORT="${CL_P2P_PORT:-26656}"
CL_METRICS_PORT="${CL_METRICS_PORT:-26660}"
P2P_EXTERNAL_IP="${P2P_EXTERNAL_IP:-}"

OG_HOME="${DATA_DIR}/0g-home"
GETH_HOME="${OG_HOME}/geth-home"
CL_HOME="${OG_HOME}/0gchaind-home"
GETH_CONFIG="${OG_HOME}/geth-archive-config.toml"
JWT_FILE="${OG_HOME}/jwt.hex"

if [[ "$#" -gt 0 ]]; then
  exec "$@"
fi

case "${NETWORK}" in
  aristotle|mainnet)
    ;;
  *)
    echo "Unsupported network: ${NETWORK}. Supported networks: aristotle, mainnet"
    exit 1
    ;;
esac

restore_snapshot() {
  [[ -n "${SNAPSHOT}" ]] || return 0
  [[ ! -f "${DATA_DIR}/.snapshot-restored" ]] || return 0

  echo "Restoring snapshot from ${SNAPSHOT}"
  case "${SNAPSHOT}" in
    *.tar.lz4)
      curl --fail --location "${SNAPSHOT}" | lz4 -dc | tar -x -C "${DATA_DIR}"
      ;;
    *.tar.gz|*.tgz)
      curl --fail --location "${SNAPSHOT}" | tar -xz -C "${DATA_DIR}"
      ;;
    *.tar.zst|*.tar.zstd)
      curl --fail --location "${SNAPSHOT}" | zstd -d | tar -x -C "${DATA_DIR}"
      ;;
    *.tar)
      curl --fail --location "${SNAPSHOT}" | tar -x -C "${DATA_DIR}"
      ;;
    *)
      echo "Unknown snapshot archive format: ${SNAPSHOT}"
      exit 1
      ;;
  esac
  touch "${DATA_DIR}/.snapshot-restored"
}

replace_toml_int() {
  local file="$1"
  local key="$2"
  local value="$3"
  sed -i -E "s#^${key}[[:space:]]*=.*#${key} = ${value}#" "${file}"
}

replace_toml_string() {
  local file="$1"
  local key="$2"
  local value="$3"
  sed -i -E "s#^${key}[[:space:]]*=.*#${key} = \"${value}\"#" "${file}"
}

prepare_layout() {
  mkdir -p "${DATA_DIR}"

  if [[ ! -d "${OG_HOME}" ]]; then
    cp -a /opt/0g/0g-home "${OG_HOME}"
  fi

  mkdir -p "${GETH_HOME}" "${CL_HOME}" "${OG_HOME}/log"

  if [[ ! -f "${GETH_CONFIG}" ]]; then
    cp /opt/0g/geth-archive-config.toml "${GETH_CONFIG}"
  fi
}

configure_geth() {
  replace_toml_int "${GETH_CONFIG}" "NetworkId" "${CHAIN_ID}"
  replace_toml_int "${GETH_CONFIG}" "HTTPPort" "${RPC_PORT}"
  replace_toml_int "${GETH_CONFIG}" "WSPort" "${WS_PORT}"
  replace_toml_int "${GETH_CONFIG}" "AuthPort" "${AUTH_RPC_PORT}"
  replace_toml_string "${GETH_CONFIG}" "JWTSecret" "${JWT_FILE}"
  replace_toml_string "${GETH_CONFIG}" "ListenAddr" ":${GETH_P2P_PORT}"
  replace_toml_string "${GETH_CONFIG}" "DiscAddr" ":${GETH_P2P_PORT}"

  if ! grep -q '^LogHistory[[:space:]]*=' "${GETH_CONFIG}"; then
    sed -i '/^\[Eth\]/a LogHistory = 0' "${GETH_CONFIG}"
  fi
}

configure_0gchaind() {
  local config="${CL_HOME}/config/config.toml"
  [[ -f "${config}" ]] || return 0

  replace_toml_string "${config}" "moniker" "${MONIKER}"
  replace_toml_string "${config}" "log_level" "${LOG_LEVEL}"
  sed -i -E "0,/^laddr[[:space:]]*=/{s#^laddr[[:space:]]*=.*#laddr = \"tcp://0.0.0.0:${CL_RPC_PORT}\"#}" "${config}"
  sed -i -E "/^\\[p2p\\]/,/^\\[/{s#^laddr[[:space:]]*=.*#laddr = \"tcp://0.0.0.0:${CL_P2P_PORT}\"#}" "${config}"
  sed -i -E "/^\\[instrumentation\\]/,/^\\[/{s#^prometheus_listen_addr[[:space:]]*=.*#prometheus_listen_addr = \"0.0.0.0:${CL_METRICS_PORT}\"#}" "${config}"
}

initialize_keys() {
  local force="${1:-0}"

  if [[ "${force}" == "1" || ! -f "${CL_HOME}/config/node_key.json" || ! -f "${CL_HOME}/config/priv_validator_key.json" ]]; then
    local tmp_home="${DATA_DIR}/tmp-0gchaind-init"
    rm -rf "${tmp_home}"
    0gchaind init "${MONIKER}" --home "${tmp_home}"
    cp "${tmp_home}/config/node_key.json" "${CL_HOME}/config/node_key.json"
    cp "${tmp_home}/config/priv_validator_key.json" "${CL_HOME}/config/priv_validator_key.json"
    cp "${tmp_home}/data/priv_validator_state.json" "${CL_HOME}/data/priv_validator_state.json"
    rm -rf "${tmp_home}"
  fi

  if [[ "${force}" == "1" || ! -f "${JWT_FILE}" ]]; then
    0gchaind jwt generate --home "${CL_HOME}"
    cp -f "${CL_HOME}/config/jwt.hex" "${JWT_FILE}"
  fi
}

initialize_geth() {
  if [[ ! -d "${GETH_HOME}/geth/chaindata" ]]; then
    geth init --datadir "${GETH_HOME}" /opt/0g/geth-genesis.json
  fi
}

initialize_once() {
  [[ ! -f "${DATA_DIR}/.initialized" ]] || return 0

  restore_snapshot
  prepare_layout
  configure_geth
  configure_0gchaind
  initialize_keys 1
  initialize_geth
  touch "${DATA_DIR}/.initialized"
}

initialize_once
prepare_layout
configure_geth
configure_0gchaind

echo "Starting 0G Aristotle node"
echo "  moniker: ${MONIKER}"
echo "  chain id: ${CHAIN_ID}"
echo "  data dir: ${DATA_DIR}"

pids=()

stop_children() {
  if [[ "${#pids[@]}" -gt 0 ]]; then
    kill "${pids[@]}" 2>/dev/null || true
    wait "${pids[@]}" 2>/dev/null || true
  fi
}

trap stop_children INT TERM

cl_args=(
  0gchaind start
  --rpc.laddr "tcp://0.0.0.0:${CL_RPC_PORT}"
  --p2p.laddr "tcp://0.0.0.0:${CL_P2P_PORT}"
  --chaincfg.kzg.trusted-setup-path /opt/0g/kzg-trusted-setup.json
  --chaincfg.engine.jwt-secret-path "${JWT_FILE}"
  --chaincfg.block-store-service.enabled
  --home "${CL_HOME}"
)

if [[ -n "${P2P_EXTERNAL_IP}" ]]; then
  cl_args+=(--p2p.external_address "${P2P_EXTERNAL_IP}:${CL_P2P_PORT}")
fi

# shellcheck disable=SC2086
"${cl_args[@]}" ${CL_EXTRA_FLAGS:-} &
pids+=("$!")

sleep 5

geth_args=(
  geth
  --config "${GETH_CONFIG}"
  --datadir "${GETH_HOME}"
  --networkid "${CHAIN_ID}"
  --metrics
  --metrics.addr 0.0.0.0
  --metrics.port "${GETH_METRICS_PORT}"
)

if [[ -n "${P2P_EXTERNAL_IP}" ]]; then
  geth_args+=(--nat "extip:${P2P_EXTERNAL_IP}")
fi

# shellcheck disable=SC2086
"${geth_args[@]}" ${GETH_EXTRA_FLAGS:-} &
pids+=("$!")

wait -n "${pids[@]}"
status="$?"
stop_children
exit "${status}"
