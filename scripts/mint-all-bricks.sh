#!/usr/bin/env bash
set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${BUILD_NFT:?BUILD_NFT is required}"

DENSITIES=${DENSITIES:-"1 8 27 64 125"}
FEE_WEI=${FEE_WEI:-100000000000000}
CHECK_ONLY=${CHECK_ONLY:-0}
RETRIES=${RETRIES:-3}
SLEEP_SECS=${SLEEP_SECS:-1}

BLOX=$(cast call "$BUILD_NFT" "blox()(address)" --rpc-url "$RPC_URL" | awk '{print $1}')
SIGNER=$(cast wallet address --private-key "$PRIVATE_KEY")
NEXT_TOKEN_ID=$(cast call "$BUILD_NFT" "nextTokenId()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')

TMP_SPECS=$(mktemp)
TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_SPECS" "$TMP_ERR"' EXIT

echo "BuildNFT: $BUILD_NFT"
echo "Signer:   $SIGNER"
echo "BLOX:     $BLOX"
echo "nextTokenId: $NEXT_TOKEN_ID"
echo "Scanning existing brick specs..."

for (( i=1; i<NEXT_TOKEN_ID; i++ )); do
  kind=$(cast call "$BUILD_NFT" "kindOf(uint256)(uint8)" "$i" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}' || true)
  [ "$kind" = "0" ] || continue

  # One value per line from cast for tuple
  spec=$(cast call "$BUILD_NFT" "brickSpecOf(uint256)(uint8,uint8,uint16)" "$i" --rpc-url "$RPC_URL" 2>/dev/null || true)
  [ -n "$spec" ] || continue

  w=$(echo "$spec" | sed -n '1p' | awk '{print $1}')
  d=$(echo "$spec" | sed -n '2p' | awk '{print $1}')
  dens=$(echo "$spec" | sed -n '3p' | awk '{print $1}')

  if [ -n "$w" ] && [ -n "$d" ] && [ -n "$dens" ]; then
    echo "$w,$d,$dens,$i" >> "$TMP_SPECS"
  fi
done

echo "Indexed $(wc -l < "$TMP_SPECS" | tr -d ' ') brick specs"

is_spec_consumed() {
  w="$1"; d="$2"; dens="$3"
  grep -q "^${w},${d},${dens}," "$TMP_SPECS"
}

find_base_token_for_density() {
  dens="$1"
  grep "^1,1,${dens}," "$TMP_SPECS" | head -n1 | awk -F',' '{print $4}'
}

record_spec() {
  w="$1"; d="$2"; dens="$3"; token="$4"
  echo "$w,$d,$dens,$token" >> "$TMP_SPECS"
}

record_last_minted_spec() {
  w="$1"; d="$2"; dens="$3"
  id=$(cast call "$BUILD_NFT" "nextTokenId()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
  id=$((id-1))
  record_spec "$w" "$d" "$dens" "$id"
}

mint_brick_once() {
  w="$1"; d="$2"; dens="$3"; base_token="$4"
  area=$((w*d))
  geom=$(cast keccak "brick:${w}x${d}:d${dens}:$(date +%s%N)")

  if [ "$area" -eq 1 ]; then
    cast send "$BUILD_NFT" \
      "mint(bytes32,uint256,string,uint256[],uint256[],uint8,uint8,uint8,uint16)" \
      "$geom" "$area" "" "[]" "[]" 0 "$w" "$d" "$dens" \
      --value "$FEE_WEI" \
      --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
  else
    cast send "$BUILD_NFT" \
      "mint(bytes32,uint256,string,uint256[],uint256[],uint8,uint8,uint8,uint16)" \
      "$geom" "$area" "" "[$base_token]" "[$area]" 0 "$w" "$d" "$dens" \
      --value "$FEE_WEI" \
      --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
  fi
}

mint_brick_with_retry() {
  w="$1"; d="$2"; dens="$3"; base_token="$4"
  attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    if mint_brick_once "$w" "$d" "$dens" "$base_token" 2>"$TMP_ERR"; then
      record_last_minted_spec "$w" "$d" "$dens"
      return 0
    fi

    # If on-chain already consumed, treat as success/skip (common after RPC nonce/500 glitches)
    if is_spec_consumed "$w" "$d" "$dens"; then
      return 0
    fi

    # Re-check chain quickly in case tx landed despite local error
    if find_spec_now=$(find_spec_token_now "$w" "$d" "$dens"); then
      record_spec "$w" "$d" "$dens" "$find_spec_now"
      return 0
    fi

    err=$(cat "$TMP_ERR")
    if echo "$err" | grep -qi "brick spec used"; then
      # Another attempt/process minted it
      return 0
    fi

    if echo "$err" | grep -Eqi "nonce too low|null response|HTTP error 5|timeout|internal server error"; then
      sleep "$SLEEP_SECS"
      attempt=$((attempt+1))
      continue
    fi

    return 1
  done
  return 1
}

find_spec_token_now() {
  want_w="$1"; want_d="$2"; want_dens="$3"
  next=$(cast call "$BUILD_NFT" "nextTokenId()(uint256)" --rpc-url "$RPC_URL" | awk '{print $1}')
  for (( i=1; i<next; i++ )); do
    kind=$(cast call "$BUILD_NFT" "kindOf(uint256)(uint8)" "$i" --rpc-url "$RPC_URL" 2>/dev/null | awk '{print $1}' || true)
    [ "$kind" = "0" ] || continue
    spec=$(cast call "$BUILD_NFT" "brickSpecOf(uint256)(uint8,uint8,uint16)" "$i" --rpc-url "$RPC_URL" 2>/dev/null || true)
    [ -n "$spec" ] || continue
    w=$(echo "$spec" | sed -n '1p' | awk '{print $1}')
    d=$(echo "$spec" | sed -n '2p' | awk '{print $1}')
    dens=$(echo "$spec" | sed -n '3p' | awk '{print $1}')
    if [ "$w" = "$want_w" ] && [ "$d" = "$want_d" ] && [ "$dens" = "$want_dens" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

missing_mass=0
missing_specs=0
for dens in $DENSITIES; do
  for (( w=1; w<=10; w++ )); do
    for (( d=w; d<=10; d++ )); do
      if ! is_spec_consumed "$w" "$d" "$dens"; then
        missing_mass=$((missing_mass + w*d))
        missing_specs=$((missing_specs + 1))
      fi
    done
  done
done

balance_wei=$(cast call "$BLOX" "balanceOf(address)(uint256)" "$SIGNER" --rpc-url "$RPC_URL" | awk '{print $1}')
required_wei=$(node -e "console.log((BigInt(process.argv[1]) * 1000000000000000000n).toString())" "$missing_mass")

echo "Missing specs: $missing_specs"
echo "Missing mass/BLOX needed: $missing_mass"
echo "Signer BLOX balance (wei): $balance_wei"

if [ "$CHECK_ONLY" = "1" ]; then
  echo "CHECK_ONLY=1 -> exiting before approve/mint."
  exit 0
fi

if node -e "const a=BigInt(process.argv[1]); const b=BigInt(process.argv[2]); process.exit(a < b ? 0 : 1)" "$balance_wei" "$required_wei"; then
  echo ""
  echo "ERROR: signer has insufficient BLOX to mint all missing specs."
  echo "Need: $missing_mass BLOX (wei=$required_wei)"
  echo "Have: wei=$balance_wei"
  exit 1
fi

approve_wei=115792089237316195423570985008687907853269984665640564039457584007913129639935
echo "Approving BLOX allowance to BuildNFT..."
cast send "$BLOX" "approve(address,uint256)" "$BUILD_NFT" "$approve_wei" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
echo "Approved."

minted=0
skipped=0
failed=0

for dens in $DENSITIES; do
  echo ""
  echo "=== Density $dens ==="

  base_token=$(find_base_token_for_density "$dens" || true)
  if [ -n "$base_token" ]; then
    echo "Found base 1x1-D$dens tokenId=$base_token"
  else
    echo "No base 1x1-D$dens found. Minting it now..."
    if mint_brick_with_retry 1 1 "$dens" 0; then
      minted=$((minted+1))
      base_token=$(find_base_token_for_density "$dens" || true)
      echo "Minted base 1x1-D$dens tokenId=${base_token:-unknown}"
    else
      failed=$((failed+1))
      echo "FAILED base 1x1-D$dens"
      continue
    fi
  fi

  [ -n "$base_token" ] || { failed=$((failed+1)); echo "Missing base token for density $dens"; continue; }

  for (( w=1; w<=10; w++ )); do
    for (( d=w; d<=10; d++ )); do
      if is_spec_consumed "$w" "$d" "$dens"; then
        skipped=$((skipped+1))
        continue
      fi

      if mint_brick_with_retry "$w" "$d" "$dens" "$base_token"; then
        if is_spec_consumed "$w" "$d" "$dens"; then
          minted=$((minted+1))
          echo "Minted ${w}x${d}-D${dens}"
        else
          skipped=$((skipped+1))
        fi
      else
        failed=$((failed+1))
        echo "FAILED ${w}x${d}-D${dens}"
      fi
      sleep "$SLEEP_SECS"
    done
  done
done

echo ""
echo "Done. minted=$minted skipped=$skipped failed=$failed"
echo "kind unlocked?"
cast call "$BUILD_NFT" "isKindUnlocked()(bool)" --rpc-url "$RPC_URL"
echo "coveredBrickSizes:"
cast call "$BUILD_NFT" "coveredBrickSizes()(uint16)" --rpc-url "$RPC_URL"
