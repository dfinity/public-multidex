#!/bin/bash
# W4-22 follow-up fixture — placeLimitOrderPO END-TO-END on the sweep path.
#
# main.mo's published contract (:10119): post-only is "maker-or-kill at
# release, NEVER pays taker". Pre-fix, a post-only order that successfully
# rested and was then taken by the AMM SWEEP paid the full taker rate (the
# sweep re-submits the resting order as an aggressor; the engine stamped the
# aggressor taker unconditionally). Under aggressorIsMaker the swept order
# keeps the MAKER fee rate and maker attribution while still getting the
# AMM's fresh price (an improvement over its own limit).
#
#   §1 the PO bid stages, releases (kill-gate sees no funded cross), RESTS
#   §2 the mark falls 6% — the requote's sweep re-homes the resting bid at
#      the AMM's fresh ask (price improvement vs the 9.60 limit)
#   §3 fee pin on the swept fill: ≤ 6bps (L0 maker 5 + rounding), NOT the
#      10bps taker rate; and the volume landed in myMakerVolUsd
#
# Venue physics — the five traps the first PO choreography hit, and how this
# fixture dodges each (docs/tasks/done/W4-22-sweep-fee-role-and-maker-attribution.md):
#   1 jump breaker: feed-path moves >6% are held — the single synthetic move
#     here is exactly −6.0% via setAmmRefPrice, the dev OVERRIDE path
#   2 vol-EWMA → W4-23 half-spread clamp: one hop on a fresh venue is one
#     EWMA feed; no cumulative widening to push the ask past the bid
#   3 pending-jump ×2 ladder widening: setAmmRefPrice CLEARS the pend for
#     the asset by design — nothing leaks between sections
#   4 GEPTOR staging: a release fires only once a FRESH ref price postdates
#     the entry (anti-snipe) — with timers paused there is no keeper, so the
#     test re-stamps setAmmRefPrice (same price) before the releasing requote
#   5 spread geometry: the bid rests at 9.60, well BELOW the ~20bps ask band
#     around 10.00 — a bid above the ask would cross and be killed at release
# Needs #dev. ⚠️ resetExchange for a deterministic book.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
P=$(mkid pf_p)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
SEED=$(mkid pf_seed)
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 300.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 20000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
icp canister call --identity pf_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 20000.0) : nat, $(e8 200000.0) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null

echo "── §1 post-only bid stages, releases, RESTS (maker-or-kill: maker) ──"
adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 30000.0) : nat)" >/dev/null
icp canister call --identity pf_p backend placeLimitOrderPO "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.60) : nat, $(e8 1100.0) : nat, null)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null   # re-stamp: fresh price postdates the entry
adm requoteAmm '("ICP-ICPUSD")' >/dev/null                           # → releases; no funded cross at 9.60 → rests
MO=$(icp canister call --identity pf_p backend getMyOrders '()' --query | tr -d '_\n' | grep -c 'id = ')
STG=$(icp canister call --identity pf_p backend getMyStagedOrderIds '()' --query | tr -d ' \n_')
PK=$(icp canister call --identity pf_p backend getMyReleaseRejections '()' --query | tr -d '\n' | grep -c 'Post-only' || true)
if [ "${MO:-0}" -ge 1 ] && [ "$STG" = "(vec{})" ] && [ "${PK:-0}" = "0" ]; then
  ok "post-only bid RESTS at 9.60 (released, not killed — no funded cross below the ~10.02 ask)"
else nok "post-only did not rest (fixture)" "open=$MO staged=$STG poKills=$PK $(icp canister call --identity pf_p backend getMyReleaseRejections '()' --query | tr -d '\n' | head -c 150)"; fi

echo "── §2 mark falls 6% — the sweep re-homes the resting PO bid ──"
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 9.40) : nat)" >/dev/null   # −6.0%: bid 9.60 now rich vs fresh ask ≈9.42
adm requoteAmm '("ICP-ICPUSD")' >/dev/null                           # ladder rebuilds → sweep takes the bid
ROWS=$(icp canister call --identity pf_p backend getMyTradesSinceId '(0 : nat, 5 : nat)' --query 2>/dev/null | tr -d '_\n' | tr -s ' ')
NT=$(echo "$ROWS" | grep -c 'trade = record' || true)
if [ "${NT:-0}" -ge 1 ]; then ok "swept: $NT fill(s) at the AMM's fresh ask (price improvement vs the 9.60 limit)"
else nok "sweep did not take the resting PO bid" "$(icp canister call --identity pf_p backend getMyOrders '()' --query | tr -d '\n' | head -c 150)"; fi

echo "── §3 the swept PO maker pays the MAKER rate (:10119 end-to-end) ──"
FEE=$(echo "$ROWS" | grep -oE 'buyer = [0-9]+' | head -1 | grep -oE '[0-9]+$')
QTY=$(echo "$ROWS" | grep -oE 'quantity = [0-9]+' | head -1 | grep -oE '[0-9]+$')
PRC=$(echo "$ROWS" | grep -oE 'price = [0-9]+' | head -1 | grep -oE '[0-9]+$')
if [ -n "$FEE" ] && [ -n "$QTY" ] && [ -n "$PRC" ]; then
  V=$(awk -v q="$QTY" -v p="$PRC" 'BEGIN{ printf "%.0f", q*p/100000000 }')
  TAKER=$(awk -v v="$V" 'BEGIN{ printf "%.0f", v*100/100000 }')   # L0 taker = 10.0 bps
  MAXOK=$(awk -v v="$V" 'BEGIN{ printf "%.0f", v*60/100000 }')    # 6 bps: L0 maker (5) + rounding, well under taker
  if [ "$FEE" -le "$MAXOK" ]; then
    ok "swept post-only paid the MAKER rate (fee=$FEE on \$-value $V; taker would be $TAKER) — 'never pays taker' holds end-to-end"
  else nok "swept post-only paid TAKER (the published-contract violation)" "fee=$FEE vs taker-rate $TAKER"; fi
else nok "sweep fill not found for the fee assertion" "$(echo "$ROWS" | head -c 160)"; fi
MVOL=$(icp canister call --identity pf_p backend getAccessPolicy '()' --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE 'myMakerVolUsd = [0-9]+' | grep -oE '[0-9]+$')
if [ "${MVOL:-0}" -gt 0 ]; then
  ok "swept fill landed in MAKER volume (myMakerVolUsd=$MVOL)"
else nok "swept post-only binned as taker volume" "myMakerVolUsd=${MVOL:-unreadable}"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_po_sweep_fee ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_po_sweep_fee ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
