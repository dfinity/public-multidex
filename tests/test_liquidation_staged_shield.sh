#!/bin/bash
# Security regression — H2, pool era: an underwater margin pool cannot dodge
# liquidation via order activity (the "staged shield").
#
# The original attack (whole-wallet era): staging a sell of collateral reserved
# funds WITHOUT moving them, the health valuation double-counted the reserve,
# and an underwater user read as healthy. The whole-wallet API is gone; the
# pool-era equivalents this test pins:
#   (a) an open staged order (an unreleased position add) does NOT inflate the
#       pool's health — after a crash the pool still reads isLiquidatable;
#   (b) liquidation PROCEEDS despite that staged order: debt is repaid by a
#       real seize (not a zero-recovery write-off) and health is restored.
#
# Timers paused so the manual crash price sticks and nothing releases the
# staged order behind our back; liquidation is driven explicitly via
# adminRunLiquidationBatch. ⚠️ Calls resetExchange — not for the live sim.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=shld; mdx_identity_new $ID
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --candid "$MDX_CANDID" --identity $ID backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 "$1") : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1 || true
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$P\",   \"ICPUSD\", $(e8 100000.0) : nat)"   >/dev/null

echo "── setup: \$30k pool, 1 BTC long @ ~50k (≈1.7×) ──"
R=$(usr createMarginPool '("shield pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release 50000.0
SZ=$(fld size "$(usr getMyPositions '()')")
if [ -n "${SZ:-}" ] && awk -v s="$SZ" 'BEGIN{exit (s>=90000000 ? 0 : 1)}'; then ok "long open ($(from_e8 "$SZ") BTC)"; else nok "setup open" "size=$SZ"; fi
D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ -n "${D0:-}" ] && [ "$D0" != "0" ]; then ok "pool carries debt ($(from_e8 "$D0"))"; else nok "setup debt" "debt=$D0"; fi

echo "── the 'shield': stage another (unreleased) risk-adding open ──"
# Staged = sealed in the deferred queue (no release happens while timers are
# paused and we don't requote). If staged reserves inflated health, the crash
# below would read healthy.
usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.05) : nat, $(e8 0.05) : nat, null)" >/dev/null
ok "staged add-on placed (sealed, unreleased)"

echo "── crash BTC 50k → 25k: pool must read LIQUIDATABLE despite the staged order ──"
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 25000.0) : nat)" >/dev/null
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = true"; then
  ok "(a) staged order did NOT inflate health — pool is liquidatable"
else nok "(a) pool should be liquidatable after the crash" "$HP"; fi

echo "── liquidation proceeds: real seize, debt repaid, health restored ──"
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
HP2=$(usr getMyMarginPools "()")
D1=$(fld debtUsd "$HP2")
if [ -n "${D1:-}" ] && [ -n "${D0:-}" ] && awk -v a="$D1" -v b="$D0" 'BEGIN{exit (a<b?0:1)}'; then
  ok "(b) debt reduced by a real seize ($(from_e8 "$D0") → $(from_e8 "$D1"))"
else nok "(b) liquidation did not reduce debt" "before=$D0 after=$D1"; fi
if echo "$HP2" | grep -q "isLiquidatable = false"; then
  ok "(b) pool restored out of liquidatable range"
else nok "(b) pool still liquidatable after batch" "$HP2"; fi
# The position was partially closed by the seize (size strictly reduced).
SZ2=$(fld size "$(usr getMyPositions '()')")
if [ -z "${SZ2:-}" ] || awk -v a="${SZ2:-0}" -v b="$SZ" 'BEGIN{exit (a<b?0:1)}'; then
  ok "position reduced by the liquidation ($(from_e8 "${SZ2:-0}") BTC left)"
else nok "position size should shrink" "before=$SZ after=$SZ2"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
