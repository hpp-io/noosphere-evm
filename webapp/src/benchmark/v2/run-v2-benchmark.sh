#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run-v2-benchmark.sh
# V2 Benchmark Runner - Tests TransientComputeClient with PayloadData support
# Payload sizes (same as v1): 0, 16, 64, 256, 1024, 4096 bytes
# -----------------------------------------------------------------------------

# --- Location ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="${SCRIPT_DIR}/.."

# -------------------------
# User configurable
# -------------------------
# Payload sizes to test (expanded for production scenarios)
# Design spec: < 1KB inline (data:), >= 1KB off-chain (ipfs://)
# Sizes: 64B, 256B, 512B, 1KB, 4KB, 10KB, 100KB, 1MB
SIZES=(64 256 512 1024 4096 10240 102400 1048576)

# Inline threshold: data below this size uses RAW_DATA, above uses PAYLOAD_DATA with URI
INLINE_THRESHOLD="${INLINE_THRESHOLD:-1024}"  # 1KB default

# Input type mode:
# - AUTO: automatically select based on size (< threshold = RAW_DATA, >= threshold = PAYLOAD_DATA)
# - RAW_DATA: force all inline (v1 compatible)
# - PAYLOAD_DATA: force all off-chain URI reference
INPUT_TYPE_MODE="${INPUT_TYPE_MODE:-AUTO}"

# Default values
ANVIL_PORT_DEFAULT=8545
ANVIL_CHAIN_ID_DEFAULT=31337

# Scripts
CLIENT_SCRIPT="${CLIENT_SCRIPT:-${SCRIPT_DIR}/benchtest-v2-client.js}"
AGENT_SCRIPT="${AGENT_SCRIPT:-${SCRIPT_DIR}/benchtest-v2-agent.js}"
SUMMARIZER="${SUMMARIZER:-${BENCH_DIR}/scripts/summarize-gas-log.js}"

# -------------------------
# Internal config
# -------------------------
ENV="${1:-fork-anvil}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
# Logs stored in same location as v1: webapp/src/benchmark/logs/v2/...
LOG_BASE_DIR="${BENCH_DIR}/logs"
LOG_DIR="${LOG_BASE_DIR}/v2/${ENV}/${TIMESTAMP}"
mkdir -p "$LOG_DIR"

ANVIL_PORT="${ANVIL_PORT:-$ANVIL_PORT_DEFAULT}"
ANVIL_LOG="${LOG_DIR}/anvil.log"
AGENT_LOG="${LOG_DIR}/agent.log"
CLIENT_LOG_DIR="${LOG_DIR}/clients"

CSV_PATH="${LOG_DIR}/gas_log_v2_${ENV}.csv"
export CSV_PATH
echo "CSV will be written to: ${CSV_PATH}"

# PIDs
PIDS=""

# -------------------------
# cleanup
# -------------------------
function cleanup() {
  echo "=== cleanup ==="
  if [[ -n "${AGENT_PID:-}" ]]; then
    echo "Stopping agent (pid ${AGENT_PID})..."
    kill "${AGENT_PID}" 2>/dev/null || true
  fi
  if [[ -n "${ANVIL_PID:-}" ]]; then
    echo "Stopping anvil (pid ${ANVIL_PID})..."
    kill "${ANVIL_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# -------------------------
# env file loader
# -------------------------
function load_env_for_env() {
  local envname="$1"
  local chosen=""

  # Priority: v2 dir first, then parent bench dir
  if [[ -f "${SCRIPT_DIR}/.env-bench.${envname}" ]]; then
    chosen="${SCRIPT_DIR}/.env-bench.${envname}"
  elif [[ -f "${SCRIPT_DIR}/.env-bench" ]]; then
    chosen="${SCRIPT_DIR}/.env-bench"
  elif [[ -f "${BENCH_DIR}/.env-bench.${envname}" ]]; then
    chosen="${BENCH_DIR}/.env-bench.${envname}"
  elif [[ -f "${BENCH_DIR}/.env-bench" ]]; then
    chosen="${BENCH_DIR}/.env-bench"
  else
    mapfile -t arr < <(ls -1 "${SCRIPT_DIR}" 2>/dev/null | grep -E '^\.env-bench\.' || true)
    if [[ ${#arr[@]} -eq 1 ]]; then
      chosen="${SCRIPT_DIR}/${arr[0]}"
    fi
  fi

  if [[ -n "${chosen}" ]]; then
    echo "Loading env from: ${chosen}"
    set -o allexport
    # shellcheck disable=SC1090
    source "${chosen}"
    set +o allexport
  else
    echo "No env file found in BENCH_DIR (${BENCH_DIR}) matching .env-bench.${envname} or .env-bench -> continue (expect external env)"
  fi

  if [[ -z "${RPC_URL:-}" && -n "${FORK_RPC_URL:-}" ]]; then
    export RPC_URL="${FORK_RPC_URL}"
    echo "Temporarily mapped FORK_RPC_URL -> RPC_URL"
  fi
  if [[ -z "${CHAIN_ID:-}" && -n "${FORK_CHAIN_ID:-}" ]]; then
    export CHAIN_ID="${FORK_CHAIN_ID}"
  fi
}

# -------------------------
# anvil fork start
# -------------------------
function start_anvil_fork() {
  local FORK_SOURCE="${FORK_RPC_URL:-}"

  if [[ -z "${FORK_SOURCE}" ]]; then
    echo "Error: FORK_RPC_URL must be set for fork mode."
    exit 2
  fi

  local RESOLVED_FORK_CHAIN_ID="${FORK_CHAIN_ID:-${CHAIN_ID:-$ANVIL_CHAIN_ID_DEFAULT}}"

  echo "Fork source: ${FORK_SOURCE}"
  echo "Resolved fork chain id: ${RESOLVED_FORK_CHAIN_ID}"

  echo "Fetching latest block number from fork RPC..."
  local LATEST_BLOCK_HEX
  LATEST_BLOCK_HEX="$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
    "${FORK_SOURCE}" | sed -n 's/.*"result"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"

  local FORK_BLOCK_ARG=""
  if [[ -n "${LATEST_BLOCK_HEX:-}" ]]; then
    local HB="${LATEST_BLOCK_HEX#0x}"
    if [[ -n "$HB" ]]; then
      local FORK_BLOCK_DEC=$((16#$HB))
      FORK_BLOCK_ARG="--fork-block-number ${FORK_BLOCK_DEC}"
      echo "  remote latest block: ${LATEST_BLOCK_HEX} (dec: ${FORK_BLOCK_DEC})"
    fi
  else
    echo "  Warning: couldn't fetch latest block number"
  fi

  local CMD=(anvil --fork-url "${FORK_SOURCE}")
  if [[ -n "${FORK_BLOCK_ARG}" ]]; then
    read -r -a TOKS <<< "${FORK_BLOCK_ARG}"
    for t in "${TOKS[@]}"; do CMD+=("$t"); done
  fi
  CMD+=(--fork-chain-id "${RESOLVED_FORK_CHAIN_ID}" --port "${ANVIL_PORT}")

  echo "Starting anvil (fork) -> logging: ${ANVIL_LOG}"
  "${CMD[@]}" > "${ANVIL_LOG}" 2>&1 &
  ANVIL_PID=$!
  PIDS="${PIDS} ${ANVIL_PID}"
  echo "Anvil started (pid ${ANVIL_PID})"

  echo "Waiting for local RPC http://127.0.0.1:${ANVIL_PORT} ..."
  for i in $(seq 1 60); do
    if curl -s -X POST -H "Content-Type: application/json" \
      --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
      "http://127.0.0.1:${ANVIL_PORT}" | grep -q '"result"'; then
      echo "Local anvil RPC responded."
      break
    fi
    sleep 0.5
  done

  if ! kill -0 "${ANVIL_PID}" 2>/dev/null; then
    echo "Anvil exited early. Check log: ${ANVIL_LOG}"
    exit 5
  fi

  export RPC_URL="http://127.0.0.1:${ANVIL_PORT}"
  export CHAIN_ID="${RESOLVED_FORK_CHAIN_ID}"
  echo "Exported RPC_URL=${RPC_URL} CHAIN_ID=${CHAIN_ID}"
}

# -------------------------
# fund addresses
# -------------------------
function fund_addresses_to_anvil() {
  local rpc="http://127.0.0.1:${ANVIL_PORT}"
  local addrs_csv="${FUND_ADDRESSES:-${FUND_ADDRESS:-}}"
  local amount_hex="${FUND_AMOUNT_WEI_HEX:-0xde0b6b3a7640000}"  # 1 ETH

  if [[ -z "${addrs_csv}" ]]; then
    echo "No FUND_ADDRESSES set -> skipping anvil funding."
    return 0
  fi

  IFS=',' read -r -a ADDR_LIST <<< "${addrs_csv}"

  for rawaddr in "${ADDR_LIST[@]}"; do
    addr="$(echo "${rawaddr}" | xargs)"
    if [[ -z "${addr}" ]]; then
      continue
    fi
    echo "Funding address ${addr} with ${amount_hex} wei..."

    res=$(curl -s -X POST -H "Content-Type: application/json" \
      --data "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_setBalance\",\"params\":[\"${addr}\",\"${amount_hex}\"],\"id\":1}" \
      "${rpc}" || true)

    if [[ -z "${res}" ]]; then
      echo "  -> ERROR: no response from ${rpc}"
    elif echo "${res}" | grep -q '"error"'; then
      echo "  -> ERROR funding ${addr}: ${res}"
    else
      echo "  -> OK funded ${addr}"
    fi
  done
}

# -------------------------
# start agent
# -------------------------
function start_agent() {
  mkdir -p "$CLIENT_LOG_DIR"
  echo "Starting V2 agent: node ${AGENT_SCRIPT} -> ${AGENT_LOG}"
  node "${AGENT_SCRIPT}" > "${AGENT_LOG}" 2>&1 &
  AGENT_PID=$!
  PIDS="${PIDS} ${AGENT_PID}"
  echo "Agent PID: ${AGENT_PID}"
  sleep 1
}

# -------------------------
# main
# -------------------------
echo "=== V2 Benchmark run start ==="
echo "Environment: ${ENV}"
echo "Input Type Mode: ${INPUT_TYPE_MODE}"
echo "Inline Threshold: ${INLINE_THRESHOLD} bytes (1KB)"
echo "Payload Sizes: ${SIZES[*]}"
echo "  - Below ${INLINE_THRESHOLD}B: RAW_DATA (inline on-chain)"
echo "  - Above ${INLINE_THRESHOLD}B: PAYLOAD_DATA (off-chain URI reference)"
echo "Logs dir: ${LOG_DIR}"
echo "CSV: ${CSV_PATH}"

# load env file
load_env_for_env "${ENV}"

# Validate
if [[ -z "${RPC_URL:-}" ]]; then
  echo "Error: RPC_URL is not set."
  exit 2
fi
if [[ -z "${CHAIN_ID:-}" ]]; then
  echo "Error: CHAIN_ID is not set."
  exit 2
fi

# Remove old CSV
if [[ -f "${CSV_PATH}" ]]; then
  echo "Removing old CSV at ${CSV_PATH}"
  rm -f "${CSV_PATH}"
fi

# fork mode
if [[ "${ENV}" == fork-* ]]; then
  echo "Environment requests fork -> starting anvil..."
  start_anvil_fork
  fund_addresses_to_anvil
fi

echo "RPC_URL (used by client/agent): ${RPC_URL}"
echo "CHAIN_ID (used by client/agent): ${CHAIN_ID}"

# start agent
start_agent

# iterate sizes with auto input type selection
FAILURES=0
for SIZE in "${SIZES[@]}"; do
  echo ""

  # Determine input type based on mode and size
  if [[ "${INPUT_TYPE_MODE}" == "AUTO" ]]; then
    if (( SIZE < INLINE_THRESHOLD )); then
      CURRENT_INPUT_TYPE="RAW_DATA"
    else
      CURRENT_INPUT_TYPE="PAYLOAD_DATA"
    fi
  elif [[ "${INPUT_TYPE_MODE}" == "RAW_DATA" ]]; then
    CURRENT_INPUT_TYPE="RAW_DATA"
  else
    CURRENT_INPUT_TYPE="PAYLOAD_DATA"
  fi

  echo "=== RUN payload size=${SIZE} bytes ($(numfmt --to=iec ${SIZE} 2>/dev/null || echo ${SIZE})) inputType=${CURRENT_INPUT_TYPE} ==="
  export TEST_PAYLOAD_SIZE="${SIZE}"
  export TEST_ITERATION="${TEST_ITERATION:-1}"
  export TEST_INPUT_TYPE="${CURRENT_INPUT_TYPE}"
  export TEST_INLINE_THRESHOLD="${INLINE_THRESHOLD}"

  CLIENT_RUN_LOG="${CLIENT_LOG_DIR}/client_size_${SIZE}_${TIMESTAMP}.log"
  echo "Running V2 client -> ${CLIENT_RUN_LOG}"
  if node "${CLIENT_SCRIPT}" > "${CLIENT_RUN_LOG}" 2>&1; then
    echo "Client finished for size=${SIZE}"
  else
    echo "Client failed for size=${SIZE}. Check ${CLIENT_RUN_LOG}"
    ((FAILURES++))
  fi

  sleep 0.5
done

# final wait
FINAL_WAIT="${FINAL_WAIT:-5}"
echo "Final wait for agent: ${FINAL_WAIT}s"
sleep "${FINAL_WAIT}"

cleanup

# summarizer
if [[ -x "$(command -v node)" && -f "${SUMMARIZER}" ]]; then
  echo "Running summarizer..."
  if node "${SUMMARIZER}" "${CSV_PATH}"; then
    echo "Summarizer done."
  else
    echo "Summarizer failed. Check ${SUMMARIZER} and ${CSV_PATH}"
  fi
fi

echo "=== V2 Benchmark run complete ==="
echo "Logs dir: ${LOG_DIR}"
echo "CSV: ${CSV_PATH}"

if (( FAILURES > 0 )); then
  echo "Some client runs failed: ${FAILURES}"
  exit 1
fi

exit 0
