#!/usr/bin/env bash
# deploy-and-verify-all.sh
# Deploy via forge script (or provided command), parse broadcast/run-latest.json,
# and attempt automatic verification for all deployed contracts.
# Requires: forge, jq, curl, sed, grep, awk, cast (optional but helpful)
set -euo pipefail

# ---------------------- User config (override by env) ----------------------
export PRIVATE_KEY=""
RPC_URL="${RPC_URL:-https://sepolia.hpp.io}"
VERIFIER_URL="${VERIFIER_URL:-https://explorer-hpp-sepolia-turdrv0107.t.conduit.xyz/api/}"
VERIFIER="${VERIFIER:-blockscout}"
RETRIES="${RETRIES:-30}"
SLEEP_SECONDS="${SLEEP_SECONDS:-2}"


# --------------------------------------------------------------------------

if [ -z "$PRIVATE_KEY" ]; then
  echo "ERROR: PRIVATE_KEY not set. export PRIVATE_KEY='0x...'"
  exit 1
fi

# --------------- forge script command (from arg or default) ----------------
if [ $# -gt 0 ]; then
  FORGE_CMD="$*"
else
  FORGE_CMD="forge script scripts/Deploy.sol:Deploy --broadcast --skip-simulation --optimize --optimizer-runs 1000000 --extra-output-files abi --rpc-url ${RPC_URL}"
fi

echo "Running deploy command:"
echo "  $FORGE_CMD"
echo

# ------------------------------ Run the forge script -----------------------
set +e
DEPLOY_OUTPUT=$($FORGE_CMD 2>&1)
DEPLOY_RC=$?
set -e

echo "$DEPLOY_OUTPUT"
if [ $DEPLOY_RC -ne 0 ]; then
  echo "forge script failed (exit ${DEPLOY_RC}). Aborting."
  exit $DEPLOY_RC
fi

# ------------- locate run-latest.json produced by forge broadcast -----------
RUNFILE=$(find broadcast -type f -name "run-latest.json" | sort | tail -n1 || true)
if [ -z "$RUNFILE" ]; then
  echo "Could not find broadcast run-latest.json. Check forge script output or broadcast/ folder."
  exit 1
fi
echo "Using run file: $RUNFILE"

# ------------------------- helper functions --------------------------------

# Extract artifact path for a contract name
find_artifact_for_name() {
  local name="$1"
  # search out/ for <Name>.json
  find out -type f -name "${name}.json" 2>/dev/null | head -n1 || true
}

# Extract source key from artifact metadata.sources for the contract
find_sourcepath_for_artifact() {
  local art="$1"
  local name="$2"
  # try to find a source path that ends with ContractName.sol
  local basename="${name}.sol"
  jq -r --arg b "$basename" '.metadata.sources | keys[]' "$art" 2>/dev/null \
    | grep -E "/\Q$basename\E$" -m1 || \
  jq -r '.metadata.sources | keys[]' "$art" 2>/dev/null | grep -F "$basename" -m1 || true
}

# Try to map library symbol names (as appear in linkReferences) to addresses
# Strategy: look in run-latest.json for transactions with contractName matching library short name
# or for returns object values. Return "LibName:0xAddr,Lib2:0xAddr"
build_libraries_flag() {
  local art="$1"
  local runfile="$2"
  # get linkReferences structure keys and inner keys
  local libs_json
  libs_json=$(jq -r '.linkReferences // {}' "$art")
  if [ "$libs_json" = "null" ] || [ -z "$libs_json" ]; then
    echo ""   # nothing
    return
  fi

  # We'll collect pairs into an array
  declare -a pairs=()

  # Iterate top-level keys (source filenames)
  # For each, get library symbol names
  mapfile -t src_keys < <(jq -r 'keys[]' <<<"$libs_json" 2>/dev/null || true)
  for sk in "${src_keys[@]}"; do
    # for each library symbol under this source
    mapfile -t syms < <(jq -r --arg sk "$sk" '.[$sk] | keys[]' <<<"$libs_json" 2>/dev/null || true)
    for sym in "${syms[@]}"; do
      # try to find an address for sym in runfile (transactions' contractName)
      # sometimes library contractName equals the solidity contract name
      ADDR=$(jq -r --arg name "$sym" '.transactions[] | select(.contractName==$name and .contractAddress!=null) | .contractAddress' "$runfile" 2>/dev/null | head -n1 || true)
      if [ -z "$ADDR" ]; then
        # sometimes in returns map
        ADDR=$(jq -r --arg name "$sym" '.returns[]? | select(. | tostring | test($name))' "$runfile" 2>/dev/null || true)
      fi
      if [ -n "$ADDR" ]; then
        pairs+=("${sym}:${ADDR}")
      else
        # can't find address automatically
        echo "WARN: library symbol '$sym' found in artifact but unable to auto-locate deployed address."
      fi
    done
  done

  if [ ${#pairs[@]} -eq 0 ]; then
    echo ""
  else
    # join with commas
    IFS=, ; echo "${pairs[*]}"
  fi
}

# Try to extract constructor args hex from transaction input when possible
# Inputs: artifact path, tx input hex
extract_constructor_args() {
  local art="$1"
  local txinput="$2"
  # return empty string if not found
  if [ -z "$txinput" ] || [ "$txinput" = "null" ]; then
    echo ""
    return
  fi
  local creation_local
  creation_local=$(jq -r '.bytecode.object // .bytecode // empty' "$art" 2>/dev/null || true)
  # if no creation data in artifact, fail
  if [ -z "$creation_local" ] || [ "$creation_local" = "null" ]; then
    # try alternative field "deployedBytecode" can't help for constructor args
    echo ""
    return
  fi
  # strip 0x
  local txhex=${txinput#0x}
  local crehex=${creation_local#0x}

  # If txhex starts with crehex, remainder is constructor args
  if [[ "${txhex}" == "${crehex}"* ]]; then
    local argshex="${txhex:${#crehex}}"
    if [ -n "$argshex" ]; then
      echo "0x${argshex}"
      return
    else
      echo ""
      return
    fi
  fi

  # If not exact match, attempt heuristic: creation_local may contain library placeholders (__...__)
  # Remove placeholders (underscores) and try matching prefix
  local cre_sanitized
  cre_sanitized=$(echo "$crehex" | sed 's/__\w\+__//g')
  if [[ "${txhex}" == "${cre_sanitized}"* ]]; then
    local argshex="${txhex:${#cre_sanitized}}"
    if [ -n "$argshex" ]; then
      echo "0x${argshex}"
      return
    fi
  fi

  # Last resort: if tx length > creation_local length, take suffix as args (best-effort)
  if [ ${#txhex} -gt ${#crehex} ]; then
    local argshex="${txhex:${#crehex}}"
    if [ -n "$argshex" ]; then
      echo "0x${argshex}"
      return
    fi
  fi

  # Could not determine
  echo ""
}

# ----------------------- parse run-latest.json entries ---------------------
# We consider transactions[] entries that have contractName and contractAddress
mapfile -t ENTRIES < <(jq -c '.transactions[] | select(.contractName != null and .contractAddress != null) | {name:.contractName, address:.contractAddress, tx:.transaction.hash, input:.transaction.input}' "$RUNFILE")

if [ ${#ENTRIES[@]} -eq 0 ]; then
  echo "No deployed contracts found in $RUNFILE (no .transactions[] entries with contractName+contractAddress)."
  # Try returns map as fallback
  mapfile -t RETURNS_KEYS < <(jq -r 'keys[]' "$RUNFILE" 2>/dev/null || true)
  if [ ${#RETURNS_KEYS[@]} -gt 0 ]; then
    echo "Found .returns entries in run file; manual verification may be needed. Exiting."
    exit 0
  fi
  exit 0
fi

# We'll also build a quick map of deployed contract names -> addresses for library auto-linking
declare -A DEPLOYED_ADDRS
for e in "${ENTRIES[@]}"; do
  NAME=$(jq -r '.name' <<<"$e")
  ADDR=$(jq -r '.address' <<<"$e")
  DEPLOYED_ADDRS["$NAME"]="$ADDR"
done

# ------------------- iterate each deployed contract and verify -----------------
for e in "${ENTRIES[@]}"; do
  NAME=$(jq -r '.name' <<<"$e")
  ADDR=$(jq -r '.address' <<<"$e")
  TXHASH=$(jq -r '.tx // empty' <<<"$e")
  TXINPUT=$(jq -r '.input // empty' <<<"$e")
  echo
  echo "================================================================"
  echo "Contract: $NAME"
  echo "Address:  $ADDR"
  echo "TxHash:   ${TXHASH:-(none)}"

  # get on-chain code
  ONCHAIN=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$ADDR\",\"latest\"]}" "$RPC_URL" | jq -r .result)
  echo "on-chain code length: ${#ONCHAIN}"

  # find local artifact
  ART=$(find_artifact_for_name "$NAME")
  if [ -z "$ART" ]; then
    echo "WARN: artifact for $NAME not found under out/. Will attempt flatten fallback later."
    ART=""
  else
    echo "Found artifact: $ART"
  fi

  LOCAL=""
  if [ -n "$ART" ]; then
    LOCAL=$(jq -r '.deployedBytecode.object // .deployedBytecode // empty' "$ART" 2>/dev/null || true)
    # if local empty, try .deployedBytecode (string)
    if [ -z "$LOCAL" ] || [ "$LOCAL" = "null" ]; then
      LOCAL=""
    fi
  fi

  # Compare
  MATCH=false
  if [ -n "$LOCAL" ] && [ -n "$ONCHAIN" ] && [ "$LOCAL" = "$ONCHAIN" ]; then
    echo "Local deployedBytecode matches on-chain."
    MATCH=true
  else
    echo "Local deployedBytecode does NOT match on-chain (or not available)."
  fi

  # Build verify command pieces
  COMPILER=""
  OPT_RUNS=""
  LIBS_FLAG=""
  CONS_FLAG=""

  if [ -n "$ART" ]; then
    COMPILER=$(jq -r '.metadata.compiler.version // empty' "$ART" || true)
    OPT_RUNS=$(jq -r '.metadata.settings.optimizer.runs // empty' "$ART" || true)
    # build libraries flag attempt
    LIBS_FLAG=$(build_libraries_flag "$ART" "$RUNFILE" || true)
    if [ -n "$LIBS_FLAG" ]; then
      echo "Auto-detected libraries: $LIBS_FLAG"
    fi
  fi

  # Try extract constructor args if we have tx input and artifact
  if [ -n "$ART" ] && [ -n "$TXINPUT" ] && [ "$TXINPUT" != "null" ]; then
    CONS_HEX=$(extract_constructor_args "$ART" "$TXINPUT" || true)
    if [ -n "$CONS_HEX" ]; then
      CONS_FLAG="--constructor-args $CONS_HEX"
      echo "Extracted constructor args (hex): $CONS_HEX"
    else
      echo "Could not extract constructor args automatically."
    fi
  fi

  # If match -> attempt verify
  if [ "$MATCH" = true ]; then
    echo "Attempting forge verify-contract for $NAME..."
    VERIFY_CMD=(forge verify-contract --rpc-url "$RPC_URL" --verifier "$VERIFIER" --verifier-url "$VERIFIER_URL" "$ADDR")
    # set source path param: try to infer source path
    if [ -n "$ART" ]; then
      SRC_KEY=$(find_sourcepath_for_artifact "$ART" "$NAME" || true)
      if [ -n "$SRC_KEY" ]; then
        VERIFY_CMD+=("${SRC_KEY}:${NAME}")
      else
        # fallback guesses
        VERIFY_CMD+=("src/${NAME}.sol:${NAME}")
      fi
    else
      VERIFY_CMD+=("src/${NAME}.sol:${NAME}")
    fi
    [ -n "$COMPILER" ] && VERIFY_CMD+=("--compiler-version" "$COMPILER")
    [ -n "$OPT_RUNS" ] && VERIFY_CMD+=("--optimizer-runs" "$OPT_RUNS")
    if [ -n "$LIBS_FLAG" ]; then
      VERIFY_CMD+=("--libraries" "$LIBS_FLAG")
    fi
    if [ -n "$CONS_FLAG" ]; then
      # split and append safely
      VERIFY_CMD+=("--constructor-args" "$CONS_HEX")
    fi

    echo "Running: ${VERIFY_CMD[*]}"
    set +e
    "${VERIFY_CMD[@]}" 2>&1
    VRC=$?
    set -e
    if [ $VRC -eq 0 ]; then
      echo "Verification submission ok for $NAME"
      continue
    else
      echo "Automatic verification command failed for $NAME (see output above). Will proceed to diagnostics."
    fi
  fi

  # If we get here => mismatch or verify failed -> proxy/impl check
  echo "Checking EIP-1967 implementation slot for proxy..."
  SLOT_IMPL="0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC"
  IMPL_SLOT_VAL=$(curl -s -X POST -H "Content-Type: application/json" \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getStorageAt\",\"params\":[\"$ADDR\",\"$SLOT_IMPL\",\"latest\"]}" "$RPC_URL" | jq -r .result || echo "0x")
  if [ -n "$IMPL_SLOT_VAL" ] && [ "$IMPL_SLOT_VAL" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
    IMPL_ADDR="0x$(echo "$IMPL_SLOT_VAL" | sed 's/^0x//' | sed -E 's/^0+//' | tail -c 40)"
    echo "Detected implementation address: $IMPL_ADDR"
    IMPL_ONCHAIN=$(curl -s -X POST -H "Content-Type: application/json" --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$IMPL_ADDR\",\"latest\"]}" "$RPC_URL" | jq -r .result || true)
    if [ -n "$ART" ] && [ -n "$LOCAL" ] && [ "$IMPL_ONCHAIN" = "$LOCAL" ]; then
      echo "Implementation bytecode matches local artifact. Suggest verifying implementation address instead."
      echo "Forge command:"
      echo "  forge verify-contract --rpc-url $RPC_URL --verifier $VERIFIER --verifier-url $VERIFIER_URL $IMPL_ADDR ${SRC_KEY:-src/${NAME}.sol}:${NAME} --compiler-version ${COMPILER:-unknown} --optimizer-runs ${OPT_RUNS:-unknown}"
      continue
    else
      echo "Implementation does not match local artifact (or artifact unavailable)."
    fi
  else
    echo "No EIP-1967 implementation slot present."
  fi

  # Fallback: create flattened file for manual submission
  FLAT="Flat_${NAME}_${ADDR}.sol"
  echo "Creating flattened file: $FLAT"
  # try to find a likely source file
  if [ -n "$ART" ]; then
    SRC_KEY=$(find_sourcepath_for_artifact "$ART" "$NAME" || true)
    # flatten expects a path like src/..., so we take the key part before the colon
    if [ -n "$SRC_KEY" ]; then
      FLAT_SRC="${SRC_KEY%%:*}"
      forge flatten "$FLAT_SRC" > "$FLAT" || { echo "forge flatten failed for $FLAT_SRC"; }
    else
      # fallback guesses
      if [ -f "src/${NAME}.sol" ]; then
        forge flatten "src/${NAME}.sol" > "$FLAT"
      elif [ -f "src/v1_0_0/${NAME}.sol" ]; then
        forge flatten "src/v1_0_0/${NAME}.sol" > "$FLAT"
      else
        echo "Could not find source to flatten automatically. Please create flattened file manually."
        continue
      fi
    fi
  else
    # no artifact; try guesses
    if [ -f "src/${NAME}.sol" ]; then
      forge flatten "src/${NAME}.sol" > "$FLAT"
    elif [ -f "src/v1_0_0/${NAME}.sol" ]; then
      forge flatten "src/v1_0_0/${NAME}.sol" > "$FLAT"
    else
      echo "No source found to flatten for $NAME. Skip."
      continue
    fi
  fi

  echo "Flattened file created: $FLAT"
  echo "Open the explorer's Flattened verify UI and paste contents of $FLAT."
  if [ -n "$CONS_HEX" ]; then
    echo "Constructor args hex (if needed): $CONS_HEX"
  elif [ -n "$TXHASH" ]; then
    echo "To obtain constructor args from tx: curl -s -X POST -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getTransactionByHash\",\"params\":[\"$TXHASH\"]}' $RPC_URL | jq ."
  fi

done

echo
echo "All done. Check verification statuses on the explorer and review any flattened files created."
