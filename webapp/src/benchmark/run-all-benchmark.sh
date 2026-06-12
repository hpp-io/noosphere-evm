#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run-all-benchmark.sh (refactor)
# - Arg1: environment (fork-testnet | fork-mainnet | testnet | mainnet | fork-anvil | ...)
# - Sizes: SIZES=(...) 배열을 스크립트 상단에서 수정하여 순회 실행
# -----------------------------------------------------------------------------

# --- 위치 관련 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -------------------------
# 사용자 수정 가능한 부분
# -------------------------
# 테스트할 payload 바이트 크기들 (순회)
SIZES=(0 16 64 256 1024 4096)

# 기본 값들 (원하면 env로 오버라이드)
ANVIL_PORT_DEFAULT=8545
ANVIL_CHAIN_ID_DEFAULT=31337

# BENCH_DIR: bench 스크립트가 위치한 디렉터리 (기본 = 이 스크립트 위치)
BENCH_DIR="${BENCH_DIR:-${SCRIPT_DIR}}"
CLIENT_SCRIPT="${CLIENT_SCRIPT:-${BENCH_DIR}/benchtest-client.js}"
AGENT_SCRIPT="${AGENT_SCRIPT:-${BENCH_DIR}/benchtest-agent.js}"
SUMMARIZER="${SUMMARIZER:-${SCRIPT_DIR}/../scripts/summarize-gas-log.js}"

# -------------------------
# 내부 설정 (변경 불필요)
# -------------------------
ENV="${1:-fork-anvil}"                              # 첫번째 인자: 실행 환경
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_BASE_DIR="${BENCH_DIR}/logs"
LOG_DIR="${LOG_BASE_DIR}/${ENV}/${TIMESTAMP}"
mkdir -p "$LOG_DIR"

ANVIL_PORT="${ANVIL_PORT:-$ANVIL_PORT_DEFAULT}"
ANVIL_LOG="${LOG_DIR}/anvil.log"
AGENT_LOG="${LOG_DIR}/agent.log"
CLIENT_LOG_DIR="${LOG_DIR}/clients"

CSV_PATH="${LOG_DIR}/gas_log_${ENV}.csv"   # 여기를 benchmark 스크립트들이 읽도록 export 합니다
export CSV_PATH
echo "CSV will be written to: ${CSV_PATH}"

# PIDs 보관
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
# env 파일 자동 로드
# 우선순위:
# 1) ${BENCH_DIR}/.env-bench.${ENV}
# 2) ${BENCH_DIR}/.env-bench
# 3) ${BENCH_DIR}에 단 하나의 .env-bench.* 파일이 있으면 그것 사용
# -------------------------
function load_env_for_env() {
  local envname="$1"
  local chosen=""

  # candidate exact
  if [[ -f "${BENCH_DIR}/.env-bench.${envname}" ]]; then
    chosen="${BENCH_DIR}/.env-bench.${envname}"
  elif [[ -f "${BENCH_DIR}/.env-bench" ]]; then
    chosen="${BENCH_DIR}/.env-bench"
  else
    # any single .env-bench.* (단 하나만 있으면 사용)
    mapfile -t arr < <(ls -1 "${BENCH_DIR}" 2>/dev/null | grep -E '^\.env-bench\.' || true)
    if [[ ${#arr[@]} -eq 1 ]]; then
      chosen="${BENCH_DIR}/${arr[0]}"
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

  # 포크 모드일 때 (FORK_RPC_URL,FORK_CHAIN_ID 매핑)
  if [[ -z "${RPC_URL:-}" && -n "${FORK_RPC_URL:-}" ]]; then
    # 단, 우리는 포크 실행 시 실제로 anvil 시작 후 RPC_URL을 로컬로 덮어씌웁니다.
    export RPC_URL="${FORK_RPC_URL}"
    echo "Temporarily mapped FORK_RPC_URL -> RPC_URL (will be replaced by local anvil RPC after anvil starts)"
  fi
  if [[ -z "${CHAIN_ID:-}" && -n "${FORK_CHAIN_ID:-}" ]]; then
    export CHAIN_ID="${FORK_CHAIN_ID}"
  fi
}

# -------------------------
# anvil fork 시작 함수
# - FORK_RPC_URL(원격 RPC)이 반드시 있어야 함
# - FORK_CHAIN_ID가 주어지지 않으면 CHAIN_ID 또는 ANVIL_CHAIN_ID_DEFAULT를 사용
# - anvil 시작 후 export RPC_URL="http://127.0.0.1:${ANVIL_PORT}" 및 CHAIN_ID을
#   anvil에 적용한 체인ID로 설정합니다 (client/agent가 로컬로 동작하도록)
# -------------------------
function start_anvil_fork() {
  local FORK_SOURCE="${FORK_RPC_URL:-}"

  if [[ -z "${FORK_SOURCE}" ]]; then
    echo "Error: FORK_RPC_URL must be set in the environment for fork mode."
    exit 2
  fi

  # 우선순위로 포크 체인 아이디 결정: FORK_CHAIN_ID -> CHAIN_ID -> 기본값
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
    echo "  Warning: couldn't fetch latest block number from remote; starting anvil without --fork-block-number"
  fi

  # Build anvil command array (안정적인 인자 전달)
  local CMD=(anvil --fork-url "${FORK_SOURCE}")
  if [[ -n "${FORK_BLOCK_ARG}" ]]; then
    read -r -a TOKS <<< "${FORK_BLOCK_ARG}"
    for t in "${TOKS[@]}"; do CMD+=("$t"); done
  fi
  CMD+=(--fork-chain-id "${RESOLVED_FORK_CHAIN_ID}" --port "${ANVIL_PORT}")

  # Debug 출력
  echo "Starting anvil (fork) -> logging: ${ANVIL_LOG}"
  echo "  Command preview:"
  printf '    '
  for a in "${CMD[@]}"; do printf "'%s' " "$a"; done
  printf "> '%s' 2>&1 &\n" "${ANVIL_LOG}"

  # 실제 실행
  "${CMD[@]}" > "${ANVIL_LOG}" 2>&1 &
  ANVIL_PID=$!
  PIDS="${PIDS} ${ANVIL_PID}"
  echo "Anvil started (pid ${ANVIL_PID})"

  # anvil RPC 응답 대기
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

  # anvil이 정상적으로 실행되면 로컬 RPC로 덮어쓰기 (client/agent에서 사용할 값)
  export RPC_URL="http://127.0.0.1:${ANVIL_PORT}"
  export CHAIN_ID="${RESOLVED_FORK_CHAIN_ID}"
  echo "Exported RPC_URL=${RPC_URL} CHAIN_ID=${CHAIN_ID} (for client/agent)"
}

# -------------------------
# anvil에 addresses를 세팅(충전)하는 함수
# - FUND_ADDRESSES: 콤마로 구분된 주소 목록 (또는 FUND_ADDRESS 단일값)
# - FUND_AMOUNT_WEI_HEX: wei 단위의 hex (예: 0xde0b6b3a7640000 = 1 ETH)
# -------------------------
function fund_addresses_to_anvil() {
  local rpc="http://127.0.0.1:${ANVIL_PORT}"
  local addrs_csv="${FUND_ADDRESSES:-${FUND_ADDRESS:-}}"
  local amount_hex="${FUND_AMOUNT_WEI_HEX:-0xde0b6b3a7640000}"  # 기본 1 ETH

  if [[ -z "${addrs_csv}" ]]; then
    echo "No FUND_ADDRESSES or FUND_ADDRESS set -> skipping anvil funding."
    return 0
  fi

  # split CSV into array
  IFS=',' read -r -a ADDR_LIST <<< "${addrs_csv}"

  for rawaddr in "${ADDR_LIST[@]}"; do
    # trim whitespace
    addr="$(echo "${rawaddr}" | xargs)"
    if [[ -z "${addr}" ]]; then
      continue
    fi
    echo "Funding address ${addr} with ${amount_hex} wei on ${rpc} ..."

    res=$(curl -s -X POST -H "Content-Type: application/json" \
      --data "{\"jsonrpc\":\"2.0\",\"method\":\"anvil_setBalance\",\"params\":[\"${addr}\",\"${amount_hex}\"],\"id\":1}" \
      "${rpc}" || true)

    # 간단한 결과 체크
    if [[ -z "${res}" ]]; then
      echo "  -> ERROR: no response from ${rpc} (check anvil log: ${ANVIL_LOG})"
    elif echo "${res}" | grep -q '"error"'; then
      echo "  -> ERROR funding ${addr}: ${res}"
    else
      echo "  -> OK funded ${addr}"
    fi
  done
}



# -------------------------
# agent 시작
# -------------------------
function start_agent() {
  mkdir -p "$CLIENT_LOG_DIR"
  echo "Starting agent: node ${AGENT_SCRIPT} -> ${AGENT_LOG}"
  node "${AGENT_SCRIPT}" > "${AGENT_LOG}" 2>&1 &
  AGENT_PID=$!
  PIDS="${PIDS} ${AGENT_PID}"
  echo "Agent PID: ${AGENT_PID}"
  sleep 1
}

# -------------------------
# main
# -------------------------
echo "=== Benchmark run start ==="
echo "Environment: ${ENV}"
echo "Logs dir: ${LOG_DIR}"
echo "CSV: ${CSV_PATH}"

# load env file if exists
load_env_for_env "${ENV}"

# Validate that RPC_URL and CHAIN_ID exist now (fork or non-fork 둘 다 필수)
if [[ -z "${RPC_URL:-}" ]]; then
  echo "Error: RPC_URL is not set. Provide in env or .env-bench.${ENV}"
  exit 2
fi
if [[ -z "${CHAIN_ID:-}" ]]; then
  echo "Error: CHAIN_ID is not set. Provide in env or .env-bench.${ENV}"
  exit 2
fi

# Remove old CSV if 존재
if [[ -f "${CSV_PATH}" ]]; then
  echo "Removing old CSV at ${CSV_PATH}"
  rm -f "${CSV_PATH}"
fi

# fork-* 환경이면 anvil 시작 (FORK_RPC_URL이 반드시 있어야 함)
if [[ "${ENV}" == fork-* ]]; then
  echo "Environment requests fork -> starting anvil..."
  start_anvil_fork
  fund_addresses_to_anvil
fi

echo "RPC_URL (used by client/agent): ${RPC_URL}"
echo "CHAIN_ID (used by client/agent): ${CHAIN_ID}"

# start agent
start_agent

# iterate sizes
FAILURES=0
for SIZE in "${SIZES[@]}"; do
  echo ""
  echo "=== RUN payload size=${SIZE} ==="
  export TEST_PAYLOAD_SIZE="${SIZE}"
  export TEST_ITERATION="${TEST_ITERATION:-1}"

  CLIENT_RUN_LOG="${CLIENT_LOG_DIR}/client_size_${SIZE}_${TIMESTAMP}.log"
  echo "Running client -> ${CLIENT_RUN_LOG}"
  if node "${CLIENT_SCRIPT}" > "${CLIENT_RUN_LOG}" 2>&1; then
    echo "Client finished for size=${SIZE}"
  else
    echo "Client failed for size=${SIZE}. Check ${CLIENT_RUN_LOG}"
    ((FAILURES++))
  fi

  sleep 0.5
done

# final wait (agent가 결과를 기록할 시간)
FINAL_WAIT="${FINAL_WAIT:-5}"
echo "Final wait for agent: ${FINAL_WAIT}s"
sleep "${FINAL_WAIT}"

cleanup

# summarizer 수행 (있으면)
if [[ -x "$(command -v node)" && -f "${SUMMARIZER}" ]]; then
  echo "Running summarizer..."
  if node "${SUMMARIZER}" "${CSV_PATH}"; then
    echo "Summarizer done."
  else
    echo "Summarizer failed. Check ${SUMMARIZER} and ${CSV_PATH}"
  fi
fi

echo "=== Benchmark run complete ==="
echo "Logs dir: ${LOG_DIR}"
echo "CSV: ${CSV_PATH}"

if (( FAILURES > 0 )); then
  echo "Some client runs failed: ${FAILURES}"
  exit 1
fi

exit 0
