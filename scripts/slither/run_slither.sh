#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET_DIR="$ROOT_DIR/src/v1_0_0"   # <-- 분석할 폴더
REPORT_DIR="$ROOT_DIR/reports"
JSON_DIR="$REPORT_DIR/json"
SARIF_DIR="$REPORT_DIR/sarif"
TXT_DIR="$REPORT_DIR/txt"

mkdir -p "$JSON_DIR" "$SARIF_DIR" "$TXT_DIR"

# 1) 전체 디렉토리 한 번 분석 (권장: imports가 연동되어야 함)
echo "Running Slither on $TARGET_DIR ..."
slither "$TARGET_DIR" \
  --config-file "$ROOT_DIR/.slither.config.json" \
  --json "$JSON_DIR/all.json" \
  --sarif "$SARIF_DIR/all.sarif" \
  --print human-summary > "$TXT_DIR/all.txt" || true

# 2) (옵션) 파일별로도 돌리고 싶다면 주석 해제:
# for f in $(find "$TARGET_DIR" -name '*.sol'); do
#   base=$(basename "$f" .sol)
#   echo "Analyzing $f ..."
#   slither "$f" \
#     --config-file "$ROOT_DIR/.slither.config.json" \
#     --json "$JSON_DIR/${base}.json" \
#     --print human-summary > "$TXT_DIR/${base}.txt" || true
# done

echo "Slither finished. Reports in $REPORT_DIR"
