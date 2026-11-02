#!/bin/bash
# Partial-close liquidation — pool era. A pool that dips just below the 1.15
# maintenance ratio is liquidated only ENOUGH to restore health toward the
# 1.25 TARGET — not flattened. (Rewritten 2026-07: the original drove the
# removed whole-wallet borrowAsset API and hand-built multi-token balances;
# under segregated pools the liquidator's seize sizing is the same
# partialSeizeQty math, exercised here through a real pool.)
#
# Setup: $30k pool, 1 BTC long at ~$50k (debt ≈ $20k). Crash BTC to $27.3k —
# only slightly below maintenance — so a SMALL seize restores target. Verify:
# debt only partially repaid (still > 0), a strict MAJORITY of the position
# survives, and the pool leaves liquidatable range. Contrast: test_liquidation
# crashes deeper (27k) and still expects a partial close; this pins the
# "just-under → barely touched" end of the curve. ⚠️ Calls resetExchange.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=pclose; mdx_identity_new $ID
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --candid "$MDX_CANDID" --identity $ID backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
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

echo "── setup: \$30k pool, 1 BTC long ──"
R=$(usr createMarginPool '("pclose pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release
SZ0=$(fld size "$(usr getMyPositions '()')")
D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
[ -n "${SZ0:-}" ] && [ -n "${D0:-}" ] && ok "long open: $(from_e8 "$SZ0") BTC, debt \$$(from_e8 "$D0")" || nok "setup" "size=$SZ0 debt=$D0"

echo "── dip JUST below maintenance (25.7k) ──"
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 25700.0) : nat)" >/dev/null
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = true"; then ok "pool marginally liquidatable"; else nok "should be (just) liquidatable at 25.7k" "$HP"; fi

echo "── batch: partial close to target — debt trimmed, MOST of the position kept ──"
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
HP2=$(usr getMyMarginPools "()")
D1=$(fld debtUsd "$HP2")
SZ1=$(fld size "$(usr getMyPositions '()')")

if [ -n "${D1:-}" ] && [ "$D1" != "0" ] && awk -v a="$D1" -v b="$D0" 'BEGIN{exit (a<b?0:1)}'; then
  ok "debt PARTIALLY repaid (\$$(from_e8 "$D0") → \$$(from_e8 "$D1"), not zero)"
else nok "expected a partial (non-total) debt repayment" "before=$D0 after=$D1"; fi

# Strict majority of the position survives a marginal breach.
if [ -n "${SZ1:-}" ] && awk -v a="$SZ1" -v b="$SZ0" 'BEGIN{exit (a > b/2 && a < b ? 0 : 1)}'; then
  ok "most of the position retained ($(from_e8 "$SZ0") → $(from_e8 "$SZ1") BTC)"
else nok "expected >50% of the position to survive" "before=$SZ0 after=$SZ1"; fi

if echo "$HP2" | grep -q "isLiquidatable = false"; then
  ok "health restored out of liquidatable range"
else nok "still liquidatable after the partial close" "$HP2"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
