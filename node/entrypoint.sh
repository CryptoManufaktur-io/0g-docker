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
GETH_ENGINE_HOST="${GETH_ENGINE_HOST:-geth}"
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
INITIALIZED_FILE="${DATA_DIR}/.initialized"
RESOLVED_P2P_EXTERNAL_IP=""

validate_network() {
  case "${NETWORK}" in
    aristotle|mainnet)
      ;;
    *)
      echo "Unsupported network: ${NETWORK}. Supported networks: aristotle, mainnet"
      exit 1
      ;;
  esac
}

is_ipv4() {
  local ip="$1"
  local octet
  local o1
  local o2
  local o3
  local o4

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r o1 o2 o3 o4 <<< "${ip}"

  for octet in "${o1}" "${o2}" "${o3}" "${o4}"; do
    (( 10#${octet} <= 255 )) || return 1
  done
}

is_public_ipv4() {
  local ip="$1"
  local o1
  local o2
  local o3
  local o4

  is_ipv4 "${ip}" || return 1
  IFS=. read -r o1 o2 o3 o4 <<< "${ip}"

  case "${o1}" in
    0|10|127|224|225|226|227|228|229|230|231|232|233|234|235|236|237|238|239|240|241|242|243|244|245|246|247|248|249|250|251|252|253|254|255)
      return 1
      ;;
  esac

  if (( 10#${o1} == 169 && 10#${o2} == 254 )); then
    return 1
  fi
  if (( 10#${o1} == 100 && 10#${o2} >= 64 && 10#${o2} <= 127 )); then
    return 1
  fi
  if (( 10#${o1} == 172 && 10#${o2} >= 16 && 10#${o2} <= 31 )); then
    return 1
  fi
  if (( 10#${o1} == 192 && 10#${o2} == 168 )); then
    return 1
  fi
  if (( 10#${o1} == 198 && (10#${o2} == 18 || 10#${o2} == 19) )); then
    return 1
  fi

  # Keep documentation and runtime behavior aligned: manual values must be routable.
  if (( 10#${o1} == 192 && 10#${o2} == 0 && 10#${o3} == 0 )); then
    return 1
  fi

  return 0
}

resolve_p2p_external_ip() {
  local endpoint
  local ip
  local endpoints=(
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
    "https://api.ipify.org"
  )

  RESOLVED_P2P_EXTERNAL_IP=""

  case "${P2P_EXTERNAL_IP}" in
    none)
      return 0
      ;;
  esac

  if [[ -n "${P2P_EXTERNAL_IP}" && "${P2P_EXTERNAL_IP}" != "auto" ]]; then
    if ! is_public_ipv4 "${P2P_EXTERNAL_IP}"; then
      echo "P2P_EXTERNAL_IP must be a public IPv4 address, empty, auto, or none: ${P2P_EXTERNAL_IP}"
      exit 1
    fi
    RESOLVED_P2P_EXTERNAL_IP="${P2P_EXTERNAL_IP}"
    return 0
  fi

  for endpoint in "${endpoints[@]}"; do
    if ip="$(curl -4fsS --max-time 5 "${endpoint}" 2>/dev/null | tr -d '[:space:]')" && is_public_ipv4 "${ip}"; then
      RESOLVED_P2P_EXTERNAL_IP="${ip}"
      echo "Resolved P2P_EXTERNAL_IP to ${RESOLVED_P2P_EXTERNAL_IP} via ${endpoint}"
      return 0
    fi
  done

  echo "Unable to resolve P2P_EXTERNAL_IP to a public IPv4 address"
  exit 1
}

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

run_init() {
  validate_network

  if [[ ! -f "${INITIALIZED_FILE}" ]]; then
    restore_snapshot
    prepare_layout
    configure_geth
    configure_0gchaind
    initialize_keys 1
    initialize_geth
    touch "${INITIALIZED_FILE}"
    echo "0G data initialized in ${DATA_DIR}"
    return 0
  fi

  prepare_layout
  configure_geth
  configure_0gchaind
  initialize_keys 0
  initialize_geth
  echo "0G data already initialized in ${DATA_DIR}"
}

wait_for_initialized() {
  local waited=0
  local timeout="${INIT_WAIT_TIMEOUT:-600}"

  until [[ -f "${INITIALIZED_FILE}" ]]; do
    if (( waited >= timeout )); then
      echo "Timed out waiting for ${INITIALIZED_FILE}"
      exit 1
    fi
    echo "Waiting for 0G initialization to complete"
    sleep 5
    waited=$((waited + 5))
  done
}

run_geth() {
  validate_network
  wait_for_initialized
  prepare_layout
  configure_geth
  initialize_geth
  resolve_p2p_external_ip

  echo "Starting 0G geth"
  echo "  chain id: ${CHAIN_ID}"
  echo "  data dir: ${GETH_HOME}"
  if [[ -n "${RESOLVED_P2P_EXTERNAL_IP}" ]]; then
    echo "  p2p external ip: ${RESOLVED_P2P_EXTERNAL_IP}"
  fi

  geth_args=(
    geth
    --config "${GETH_CONFIG}"
    --datadir "${GETH_HOME}"
    --networkid "${CHAIN_ID}"
    --metrics
    --metrics.addr 0.0.0.0
    --metrics.port "${GETH_METRICS_PORT}"
  )

  if [[ -n "${RESOLVED_P2P_EXTERNAL_IP}" ]]; then
    geth_args+=(--nat "extip:${RESOLVED_P2P_EXTERNAL_IP}")
  fi

  # shellcheck disable=SC2086
  exec "${geth_args[@]}" ${GETH_EXTRA_FLAGS:-}
}

run_0gchaind() {
  validate_network
  wait_for_initialized
  prepare_layout
  configure_0gchaind
  resolve_p2p_external_ip

  echo "Starting 0G 0gchaind"
  echo "  moniker: ${MONIKER}"
  echo "  chain id: ${CHAIN_ID}"
  echo "  data dir: ${CL_HOME}"
  echo "  engine RPC: http://${GETH_ENGINE_HOST}:${AUTH_RPC_PORT}"
  if [[ -n "${RESOLVED_P2P_EXTERNAL_IP}" ]]; then
    echo "  p2p external address: ${RESOLVED_P2P_EXTERNAL_IP}:${CL_P2P_PORT}"
  fi

  cl_args=(
    0gchaind start
    --rpc.laddr "tcp://0.0.0.0:${CL_RPC_PORT}"
    --p2p.laddr "tcp://0.0.0.0:${CL_P2P_PORT}"
    --chaincfg.kzg.trusted-setup-path /opt/0g/kzg-trusted-setup.json
    --chaincfg.engine.jwt-secret-path "${JWT_FILE}"
    --chaincfg.engine.rpc-dial-url "http://${GETH_ENGINE_HOST}:${AUTH_RPC_PORT}"
    --chaincfg.block-store-service.enabled
    --home "${CL_HOME}"
  )

  if [[ -n "${RESOLVED_P2P_EXTERNAL_IP}" ]]; then
    cl_args+=(--p2p.external_address "${RESOLVED_P2P_EXTERNAL_IP}:${CL_P2P_PORT}")
  fi

  # shellcheck disable=SC2086
  exec "${cl_args[@]}" ${CL_EXTRA_FLAGS:-}
}

case "${1:-run-geth}" in
  init)
    run_init
    ;;
  run-geth)
    run_geth
    ;;
  run-0gchaind)
    run_0gchaind
    ;;
  *)
    exec "$@"
    ;;
esac
