#!/bin/bash
# Record fidelity of a MARKET order walking the AMM curve (the Calm-Bear-91
# bug): a market order larger than one ladder pass fills across several
# re-defer cycles. Before the fix, each cycle rested the remainder as a LIMIT
# order and cancelled it — so Trade History said LIMIT and Recently Closed
# Orders showed N phantom "cancelled limit orders". Now:
#   • every trade carries takerOrderType = market
#   • closed-order records for the walker are MARKET + #filled tranches
#   • NO #cancelled records appear for the walk
#   • the fill itself still completes (walk mechanics unchanged)
# Fixture: thin ladder (3 levels × 0.4 ICP-equivalent) so a 2-ladder order must
# walk. Timers paused; releases driven manually. ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

mdx_identity_new mwr_seed; S=$(principal_of mwr_seed); mdx_identity_new mwr_whale; W=$(principal_of mwr_whale)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
whl() { icp canister call --candid "$MDX_CANDID" --identity mwr_whale backend "$@" 2>&1; }
release() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1 || true
# THIN ladder: 3 levels × 0.4 ICP per side ≈ 1.2 ICP takeable per pass.
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 0.4) : nat, 3:nat, 10:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
mdx_lp_deposit mwr_seed "ICP-ICPUSD" "$(e8 10000.0)" "$(e8 100000.0)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm setTestBalance "(principal \"$W\", \"ICPUSD\", $(e8 10000.0) : nat)" >/dev/null

echo "── whale MARKET buy 3 ICP against a ~1.2-ICP-per-pass ladder (must walk) ──"
R=$(whl placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 3.0) : nat, $(e8 0.05) : nat, false)")
if mdx_ok "$R"; then ok "market order staged"; else nok "placement" "$R"; fi

# Drive enough release cycles for the full walk (each takes ≤ one ladder).
for i in 1 2 3 4 5 6; do release; done
ICP_GOT=$(adm getTestBalance "(principal \"$W\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if awk -v g="${ICP_GOT:-0}" 'BEGIN{exit (g >= 290000000 ? 0 : 1)}'; then
  ok "walk completed — whale holds $(from_e8 "${ICP_GOT:-0}") ICP (≥2.9 of 3 requested)"
else nok "walk should fill ~3 ICP across cycles" "got=$(from_e8 "${ICP_GOT:-0}")"; fi

echo "── record fidelity ──"
# (1) Trade History: the whale's trades are MARKET-taker trades. The public
# tape (getRecentTrades) is de-identified PublicTrade (2026-07) and no longer
# carries takerOrderType — read the whale's caller-scoped history instead,
# which still returns full Trade records for the caller's own fills.
TR=$(whl getMyTradeHistory '()')
MKT_TRADES=$(echo "$TR" | grep -c "takerOrderType = opt variant { market }" || true)
LIM_TRADES=$(echo "$TR" | grep -c "takerOrderType = opt variant { limit }" || true)
if [ "${MKT_TRADES:-0}" -ge 2 ] && [ "${LIM_TRADES:-0}" = "0" ]; then
  ok "all $MKT_TRADES walk trades stamped takerOrderType = MARKET (0 mislabeled limit)"
else nok "trades should be MARKET-taker" "market=$MKT_TRADES limit=$LIM_TRADES"; fi

# (2) Recently Closed Orders: MARKET #filled tranches, ZERO phantom cancels.
# (Force a reaper pass? closed records are captured by the reaper sweep — with
#  timers paused, run the sweep via a fresh unpause+pause window.)
adm setTestTimersPaused '(false)' >/dev/null; sleep 12; adm setTestTimersPaused '(true)' >/dev/null
CO=$(whl getMyClosedOrders '()')
CANCELLED=$(echo "$CO" | grep -c "status = variant { cancelled }" || true)
MARKET_FILLED=$(echo "$CO" | grep -c "orderType = variant { market }" || true)
LIMIT_RECS=$(echo "$CO" | grep -c "orderType = variant { limit }" || true)
if [ "${CANCELLED:-0}" = "0" ]; then
  ok "NO phantom cancelled records (was 5 per walk before the fix)"
else nok "walk produced cancelled records" "cancelled=$CANCELLED"; fi
if [ "${MARKET_FILLED:-0}" -ge 1 ] && [ "${LIMIT_RECS:-0}" = "0" ]; then
  ok "closed records are MARKET fills ($MARKET_FILLED tranche(s), 0 limit-labeled)"
else nok "closed records should be MARKET" "market=$MARKET_FILLED limit=$LIMIT_RECS"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
