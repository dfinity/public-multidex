#!/bin/bash
# Canonical pool liquidation at health < maintenance (1.15) — pool era.
# (Rewritten 2026-07: the original drove the removed whole-wallet borrowAsset
# API. Margin lives on segregated pools now; the liquidation batch scans pool
# principals' loans.)
#
# Setup: a margin pool with $30k collateral opens a 1 BTC long at ~$50k
# (~1.7×, borrowing the ~$20k shortfall). Crash BTC to $25k → health < 1.15.
# (At 0.9 BTC LTV the liquidation price is ≈ $25.9k: collateral 0.999×P×0.9
# vs debt ≈ $20.2k × 1.15 maintenance. The original $27k crash sat ABOVE the
# threshold — health 1.20 — so the batch correctly did nothing and the test
# could never pass; it predates the current LTV/maintenance constants.)
# adminRunLiquidationBatch must: seize collateral (the vault ABSORBS it at the
# oracle mid — its BTC balance grows), reduce the debt, and restore the pool
# out of liquidatable range with the position only PARTIALLY closed.
# Timers paused for deterministic prices; liquidation is engine-bypassing so
# no GEPTOR wait is needed after the crash. ⚠️ Calls resetExchange.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=liqp; mdx_identity_new $ID
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --candid "$MDX_CANDID" --identity $ID backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }
bal() { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+" | head -1); echo "${n:-0}"; }

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

echo "── setup: \$30k pool, 1 BTC long (~1.7×) ──"
R=$(usr createMarginPool '("liq pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)" >/dev/null
release
SZ0=$(fld size "$(usr getMyPositions '()')")
D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ -n "${SZ0:-}" ] && [ -n "${D0:-}" ] && [ "$D0" != "0" ]; then
  ok "long open: $(from_e8 "$SZ0") BTC, debt \$$(from_e8 "$D0")"
else nok "setup" "size=$SZ0 debt=$D0"; fi

echo "── crash BTC 50k → 25k: pool below maintenance ──"
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 25000.0) : nat)" >/dev/null
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = true"; then ok "pool is liquidatable"; else nok "should be liquidatable at 25k" "$HP"; fi

echo "── liquidation batch: seize → vault absorbs, debt down, health restored ──"
VAULT_BTC0=$(bal "$AMM" BTC)
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
VAULT_BTC1=$(bal "$AMM" BTC)

# The vault ABSORBED the seized BTC at the oracle mid (its inventory grew).
if awk -v a="$VAULT_BTC1" -v b="$VAULT_BTC0" 'BEGIN{exit (a>b?0:1)}'; then
  ok "vault absorbed seized BTC ($(from_e8 "$VAULT_BTC0") → $(from_e8 "$VAULT_BTC1"))"
else nok "vault BTC should grow from the seize" "before=$VAULT_BTC0 after=$VAULT_BTC1"; fi

HP2=$(usr getMyMarginPools "()")
D1=$(fld debtUsd "$HP2")
if [ -n "${D1:-}" ] && awk -v a="$D1" -v b="$D0" 'BEGIN{exit (a<b?0:1)}'; then
  ok "debt reduced (\$$(from_e8 "$D0") → \$$(from_e8 "$D1"))"
else nok "debt should reduce" "before=$D0 after=$D1"; fi
if echo "$HP2" | grep -q "isLiquidatable = false"; then
  ok "pool restored out of liquidatable range"
else nok "still liquidatable after batch" "$HP2"; fi

# Partial, not total: some position survives the seize.
SZ1=$(fld size "$(usr getMyPositions '()')")
if [ -n "${SZ1:-}" ] && [ "$SZ1" != "0" ] && awk -v a="$SZ1" -v b="$SZ0" 'BEGIN{exit (a<b?0:1)}'; then
  ok "position partially closed ($(from_e8 "$SZ0") → $(from_e8 "$SZ1") BTC)"
else nok "expected a PARTIAL close" "before=$SZ0 after=$SZ1"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
