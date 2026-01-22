#!/usr/bin/env bash
# run-all-benchmark-v2.sh
# V2 benchmark runner - uses PayloadData structs
#
# Usage: ./run-all-benchmark-v2.sh [environment]
# Example: ./run-all-benchmark-v2.sh testnet

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# V2 scripts
export CLIENT_SCRIPT="${SCRIPT_DIR}/v2/benchtest-v2-client.js"
export AGENT_SCRIPT="${SCRIPT_DIR}/v2/benchtest-v2-agent.js"

# Default to RAW_DATA for fair comparison with V1
export TEST_INPUT_TYPE="${TEST_INPUT_TYPE:-RAW_DATA}"

echo "=== V2 Benchmark ==="
echo "CLIENT_SCRIPT: ${CLIENT_SCRIPT}"
echo "AGENT_SCRIPT: ${AGENT_SCRIPT}"
echo "TEST_INPUT_TYPE: ${TEST_INPUT_TYPE}"
echo ""

# Run the main benchmark script
exec "${SCRIPT_DIR}/run-all-benchmark.sh" "$@"
