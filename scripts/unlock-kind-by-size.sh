#!/usr/bin/env bash
set -euo pipefail

# Mint only missing brick sizes (w<=d, 1..10) at density=1 to unlock kind>0.
# Fast path vs minting all 5 densities.

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${BUILD_NFT:?BUILD_NFT is required}"

DENSITY=${DENSITY:-1}
BASE_TOKEN_ID=${BASE_TOKEN_ID:-1}   # expected 1x1-D1 token id
FEE_WEI=${FEE_WEI:-100000000000000}
CHECK_ONLY=${CHECK_ONLY:-0}
RETRIES=${RETRIES:-3}
SLEEP_SECS=${SLEEP_SECS:-1}

if [ "$DENSITY" != "1" ]; then
  echo "This helper assumes DENSITY=1 for fastest unlock path."
fi

BLOX=$(cast call "$BUILD_NFT" "blox()(address)" --rpc-url "$RPC_URL" | awk '{print $1}')
SIGNER=$(cast wallet address --private-key "$PRIVATE_KEY")

echo "BuildNFT: $BUILD_NFT"
echo "Signer:   $SIGNER"
echo "BLOX:     $BLOX"

tmp_missing=$(mktemp)
tmp_err=$(mktemp)
trap 'rm -f "$tmp_missing" "$tmp_err"' EXIT

size_key() {
  w="$1"; d="$2"
  # w<=d already by loop
  echo $(( (w << 8) | d ))
}

mint_once() {
  w="$1"; d="$2"; area=$((w*d))
  geom=$(cast keccak "unlock:${w}x${d}:d${DENSITY}:$(date +%s%N)")

  cast send "$BUILD_NFT" \
    "mint(bytes32,uint256,string,uint256[],uint256[],uint8,uint8,uint8,uint16)" \
    "$geom" "$area" "" "[$BASE_TOKEN_ID]" "[$area]" 0 "$w" "$d" "$DENSITY" \
    --value "$FEE_WEI" \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" > /dev/null
}

mint_with_retry() {
  w="$1"; d="$2"
  key=$(size_key "$w" "$d")

  attempt=1
  while [ "$attempt" -le "$RETRIES" ]; do
    if mint_once "$w" "$d" 2>"$tmp_err"; then
      return 0
    fi

    # if already covered, treat as success
    covered=$(cast call "$BUILD_NFT" "brickSizeCovered(uint16)(bool)" "$key" --rpc-url "$RPC_URL" | awk '{print $1}' || echo false)
    if [ "$covered" = "true" ]; then
      return 0
    fi

    err=$(cat "$tmp_err")
    if echo "$err" | grep -Eqi "nonce too low|null response|HTTP error 5|timeout|internal server error|brick spec used"; then
      sleep "$SLEEP_SECS"
      attempt=$((attempt+1))
      continue
    fi

    return 1
  done

  return 1
}

missing=0
missing_mass=0
for (( w=1; w<=10; w++ )); do
  for (( d=w; d<=10; d++ )); do
    key=$(size_key "$w" "$d")
    covered=$(cast call "$BUILD_NFT" "brickSizeCovered(uint16)(bool)" "$key" --rpc-url "$RPC_URL" | awk '{print $1}')
    if [ "$covered" != "true" ]; then
      echo "$w,$d" >> "$tmp_missing"
      missing=$((missing+1))
      missing_mass=$((missing_mass + w*d))
    fi
  done
done

echo "Missing brick sizes: $missing"
echo "Mass/BLOX needed (at D1): $missing_mass"

bal=$(cast call "$BLOX" "balanceOf(address)(uint256)" "$SIGNER" --rpc-url "$RPC_URL" | awk '{print $1}')
need=$(node -e "console.log((BigInt(process.argv[1]) * 1000000000000000000n).toString())" "$missing_mass")
echo "Signer BLOX balance (wei): $bal"

if [ "$CHECK_ONLY" = "1" ]; then
  echo "CHECK_ONLY=1 -> exiting before mint."
  exit 0
fi

if node -e "const a=BigInt(process.argv[1]); const b=BigInt(process.argv[2]); process.exit(a < b ? 0 : 1)" "$bal" "$need"; then
  echo "ERROR: insufficient BLOX for unlock pass."
  exit 1
fi

approve_wei=115792089237316195423570985008687907853269984665640564039457584007913129639935
echo "Approving BLOX..."
cast send "$BLOX" "approve(address,uint256)" "$BUILD_NFT" "$approve_wei" \
  --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
echo "Approved."

minted=0
failed=0
while IFS=, read -r w d; do
  [ -n "$w" ] || continue
  if mint_with_retry "$w" "$d"; then
    minted=$((minted+1))
    echo "Minted ${w}x${d}-D${DENSITY}"
  else
    failed=$((failed+1))
    echo "FAILED ${w}x${d}-D${DENSITY}"
  fi
  sleep "$SLEEP_SECS"
done < "$tmp_missing"

covered=$(cast call "$BUILD_NFT" "coveredBrickSizes()(uint16)" --rpc-url "$RPC_URL" | awk '{print $1}')
unlocked=$(cast call "$BUILD_NFT" "isKindUnlocked()(bool)" --rpc-url "$RPC_URL" | awk '{print $1}')

echo "Done. minted=$minted failed=$failed coveredBrickSizes=$covered isKindUnlocked=$unlocked"
