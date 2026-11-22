#!/bin/bash
# Base-token DEBT liquidation (short squeeze) — pool era.
# (Rewritten 2026-07: the original hand-built a SOL-collateral/BTC-debt user
# via the removed whole-wallet API. Under segregated pools, collateral is
# ICPUSD + the pool's own market holdings, so the constructible non-quote-debt
# shape is a SHORT: the pool BORROWS the base token and owes it back. The gap
# the original guarded — debt token ≠ ICPUSD must still be liquidatable, never
# an #unsupported zombie — is exactly what a squeezed short exercises: repay
# BTC debt out of ICPUSD collateral via the vault at the oracle mid.)
#
# Setup: $30k pool SHORTS 1 BTC at ~$50k (borrows the BTC, sells it — pool
# holds ~$80k ICPUSD, owes 1 BTC). Squeeze BTC to $70k → health < 1.15.
# Batch must reduce the BTC debt from ICPUSD collateral and restore health.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=b2bp; mdx_identity_new $ID
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

echo "── setup: \$30k pool, SHORT 1 BTC (owes the base token) ──"
R=$(usr createMarginPool '("b2b pool", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 30000.0) : nat)" >/dev/null
O=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { sell }, $(e8 1.0) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$O"; then ok "short staged"; else nok "openPosition sell" "$O"; fi
release
SZ0=$(fld size "$(usr getMyPositions '()')")   # |size| of the short
D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ -n "${D0:-}" ] && [ "$D0" != "0" ]; then
  ok "short open: size $(from_e8 "${SZ0:-0}") BTC, debt \$$(from_e8 "$D0") (the borrowed BTC)"
else nok "setup" "size=$SZ0 debt=$D0"; fi

echo "── squeeze BTC 50k → 70k: base-token debt balloons ──"
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 70000.0) : nat)" >/dev/null
HP=$(usr getMyMarginPools "()")
if echo "$HP" | grep -q "isLiquidatable = true"; then ok "squeezed pool is liquidatable"; else nok "should be liquidatable at 70k" "$HP"; fi

echo "── batch: BTC debt repaid FROM ICPUSD collateral (no #unsupported zombie) ──"
adm adminRunLiquidationBatch "()" >/dev/null 2>&1
HP2=$(usr getMyMarginPools "()")
D1=$(fld debtUsd "$HP2")
if [ -n "${D1:-}" ] && awk -v a="$D1" -v b="$D0" 'BEGIN{exit (a<b?0:1)}'; then
  ok "base-token debt reduced (\$$(from_e8 "$D0") → \$$(from_e8 "$D1"))"
else nok "BTC debt should reduce (was this route left #unsupported?)" "before=$D0 after=$D1"; fi
if echo "$HP2" | grep -q "isLiquidatable = false"; then
  ok "pool restored out of liquidatable range (not a lingering zombie)"
else nok "still liquidatable — the non-quote-debt route failed" "$HP2"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
