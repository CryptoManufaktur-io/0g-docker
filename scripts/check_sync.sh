#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --container NAME         Docker container name or ID to run curl/jq within
  --compose-service NAME   Docker Compose service name to resolve to a container
  --local-rpc URL          Local RPC URL (default: http://127.0.0.1:8545)
  --public-rpc URL         Public/reference RPC URL (default: https://evmrpc.0g.ai)
  --block-lag N            Acceptable lag in blocks (default: 5)
  --no-install             Do not install curl/jq inside the container
  --env-file PATH          Path to env file to load
  -h, --help               Show this help

Exit Codes:
  0 - Synced
  1 - Syncing
  2 - Error

Examples:
  ./scripts/check_sync.sh
  ./scripts/check_sync.sh --local-rpc http://127.0.0.1:8545
  ./scripts/check_sync.sh --compose-service geth --public-rpc https://evmrpc.0g.ai
USAGE
}

ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
PUBLIC_RPC="${PUBLIC_RPC:-https://evmrpc.0g.ai}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-5}"
INSTALL_TOOLS="${INSTALL_TOOLS:-1}"
LOCAL_RPC_WAS_SET=0
SERVICE_WAS_SET=0
CONTAINER_WAS_SET=0

load_env_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    line="${line#export }"
    if [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "${val}" =~ ^\".*\"$ || "${val}" =~ ^\'.*\'$ ]]; then
        val="${val:1:-1}"
      fi
      export "${key}=${val}"
    fi
  done < "${file}"
}

error_exit() {
  local message="$1"
  echo "❌ error: ${message}"
  echo
  echo "❌ Final status: error"
  exit 2
}

resolve_container() {
  if [[ -n "${CONTAINER}" || -z "${DOCKER_SERVICE}" ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    error_exit "docker not found; cannot resolve compose service ${DOCKER_SERVICE}"
  fi
  if docker compose version >/dev/null 2>&1; then
    CONTAINER="$(docker compose ps -q "${DOCKER_SERVICE}" | head -n 1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    CONTAINER="$(docker-compose ps -q "${DOCKER_SERVICE}" | head -n 1)"
  else
    error_exit "docker compose not available; cannot resolve compose service ${DOCKER_SERVICE}"
  fi
  if [[ -z "${CONTAINER}" ]]; then
    error_exit "no running container found for service: ${DOCKER_SERVICE}"
  fi
}

check_tools() {
  if [[ -n "${CONTAINER}" ]]; then
    echo "⏳ Checking tools inside container"
    if [[ "${INSTALL_TOOLS}" == "1" ]]; then
      docker exec -u root "${CONTAINER}" sh -c '
        set -e
        if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
          exit 0
        fi
        if command -v apt-get >/dev/null 2>&1; then
          apt-get update -y >/dev/null
          apt-get install -y curl jq ca-certificates >/dev/null
        elif command -v apk >/dev/null 2>&1; then
          apk add --no-cache curl jq ca-certificates >/dev/null
        else
          echo "unsupported base image; no apt-get or apk found"
          exit 1
        fi
      ' || error_exit "failed to install curl/jq inside container"
    fi
    docker exec "${CONTAINER}" sh -c 'command -v curl >/dev/null && command -v jq >/dev/null' \
      || error_exit "curl/jq unavailable inside container"
    echo "✅ Tools available in container"
    return 0
  fi

  echo "⏳ Checking local tools"
  command -v curl >/dev/null 2>&1 || error_exit "curl unavailable on host"
  command -v jq >/dev/null 2>&1 || error_exit "jq unavailable on host"
  echo "✅ Tools available locally"
}

http_post() {
  local url="$1"
  local data="$2"
  if [[ -n "${CONTAINER}" ]]; then
    docker exec "${CONTAINER}" curl -sS --fail -X POST -H "Content-Type: application/json" -d "${data}" "${url}"
  else
    curl -sS --fail -X POST -H "Content-Type: application/json" -d "${data}" "${url}"
  fi
}

jq_eval() {
  local filter="$1"
  if [[ -n "${CONTAINER}" ]]; then
    docker exec -i "${CONTAINER}" jq -r "${filter}"
  else
    jq -r "${filter}"
  fi
}

RPC_RESPONSE=""
rpc_post() {
  local url="$1"
  local payload="$2"
  local label="$3"
  local response

  if ! response="$(http_post "${url}" "${payload}" 2>/tmp/0g-check-sync-curl.err)"; then
    error_exit "${label} RPC unreachable (${url})"
  fi
  if [[ "$(printf '%s' "${response}" | jq_eval '.error // empty')" != "" ]]; then
    error_exit "${label} RPC returned error: $(printf '%s' "${response}" | jq_eval '.error.message // .error')"
  fi
  RPC_RESPONSE="${response}"
}

LATEST_HEIGHT=""
LATEST_HASH=""
latest_block() {
  local url="$1"
  local label="$2"
  local number_hex hash

  rpc_post "${url}" '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' "${label}"
  number_hex="$(printf '%s' "${RPC_RESPONSE}" | jq_eval '.result.number // empty')"
  hash="$(printf '%s' "${RPC_RESPONSE}" | jq_eval '.result.hash // empty')"

  if [[ -z "${number_hex}" || "${number_hex}" == "null" || -z "${hash}" || "${hash}" == "null" ]]; then
    error_exit "${label} RPC returned an invalid latest block response"
  fi

  LATEST_HEIGHT="$((16#${number_hex#0x}))"
  LATEST_HASH="${hash}"
}

SYNC_RESULT=""
eth_syncing() {
  rpc_post "${LOCAL_RPC}" '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' "local"
  SYNC_RESULT="$(printf '%s' "${RPC_RESPONSE}" | jq_eval '.result')"
}

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--env-file" ]]; then
    ENV_FILE="${args[$((i+1))]:-}"
  fi
done

if [[ -n "${ENV_FILE}" ]]; then
  load_env_file "${ENV_FILE}"
elif [[ -f ".env" ]]; then
  load_env_file ".env"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|--compose-service|--local-rpc|--public-rpc|--block-lag|--env-file)
      [[ $# -ge 2 ]] || error_exit "$1 requires a value"
      ;;&
    --container)
      CONTAINER="$2"
      CONTAINER_WAS_SET=1
      shift 2
      ;;
    --compose-service)
      DOCKER_SERVICE="$2"
      SERVICE_WAS_SET=1
      shift 2
      ;;
    --local-rpc)
      LOCAL_RPC="$2"
      LOCAL_RPC_WAS_SET=1
      shift 2
      ;;
    --public-rpc)
      PUBLIC_RPC="$2"
      shift 2
      ;;
    --block-lag)
      BLOCK_LAG_THRESHOLD="$2"
      shift 2
      ;;
    --no-install)
      INSTALL_TOOLS="0"
      shift
      ;;
    --env-file)
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error_exit "unknown option: $1"
      ;;
  esac
done

LOCAL_RPC="${LOCAL_RPC:-http://127.0.0.1:${RPC_PORT:-8545}}"
PUBLIC_RPC="${PUBLIC_RPC:-https://evmrpc.0g.ai}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-${BLOCK_LAG:-5}}"

if [[ "${LOCAL_RPC_WAS_SET}" -eq 0 && "${SERVICE_WAS_SET}" -eq 0 && "${CONTAINER_WAS_SET}" -eq 0 ]]; then
  DOCKER_SERVICE="${DOCKER_SERVICE:-geth}"
fi

resolve_container
check_tools

echo
echo "⏳ Latest block comparison"

eth_syncing
sync_result="${SYNC_RESULT}"
latest_block "${LOCAL_RPC}" "local"
local_height="${LATEST_HEIGHT}"
local_hash="${LATEST_HASH}"
latest_block "${PUBLIC_RPC}" "public"
public_height="${LATEST_HEIGHT}"
public_hash="${LATEST_HASH}"

lag=$((public_height - local_height))
relation="in sync"
display_lag="${lag}"

if (( lag > 0 )); then
  relation="local behind"
elif (( lag < 0 )); then
  relation="local ahead"
  display_lag=0
fi

echo "Local latest:  ${local_height} ${local_hash}"
echo "Public latest: ${public_height} ${public_hash}"
echo "Lag:         ${display_lag} blocks (threshold: ${BLOCK_LAG_THRESHOLD}) (${relation})"
echo

if [[ "${local_height}" == "${public_height}" && "${local_hash}" != "${public_hash}" ]]; then
  echo "❌ Final status: error"
  exit 2
fi

if [[ "${sync_result}" != "false" && "${sync_result}" != "null" ]]; then
  echo "⏳ Final status: syncing"
  exit 1
fi

if (( lag > BLOCK_LAG_THRESHOLD )); then
  echo "⏳ Final status: syncing"
  exit 1
fi

echo "✅ Final status: in sync"
