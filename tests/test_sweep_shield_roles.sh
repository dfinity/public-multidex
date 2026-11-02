#!/bin/bash
# H-24 (F25, D1 — the W4-22 amendment) — the AMM sweep honours the L4 shield
# for NON-AMM makers, and rates the swept (re-homed) order MAKER only against
# the AMM: a user-vs-user sweep fill carries a taker leg with the swept order as
# the taker.
#
# Pre-fix, sweepCtx set isNonTakeable = false (the W4-22 DECISION: the AMM leg
# is price improvement, so the shield was switched off for the whole walk) and
# aggressorIsMaker = true for the whole walk — but the re-homed order is a full
# taker walk at its own limit, so it could ALSO (a) take a shielded L4 quote
# before its staged reprice landed and (b) settle a user-vs-user fill
# maker/maker: no taker leg, 2× maker volume on both sides, contradicting the
# wash guardrail. Now the walk skips shielded non-AMM makers (the AMM leg keeps
# its price-improvement rationale) and MatchingEngine.ProtectionCtx.aggressorRole
# = #swept({ makerVs }) rates each slice by its counterparty.
#
# Choreography (per section, from a fresh venue): the MM (L4) rests an ask at
# 50050; a whale stages a bid at 50150 that CROSSES it; the mark is re-stamped
# (dispatch) and THEN the MM stages a commensurate repricing intent, so at the
# whale's release the MM's ask is shielded (stamp > dispatch) and the whale's
# bid RESTS above it — a crossed user-vs-user book only the sweep can re-home.
# Then the AMM ladder is switched on (numLevels 0 → 5 at 20 bps: best ask
# 50100, strictly between the MM's 50050 and the whale's 50150) and a requote
# sweeps the whale's bid as the aggressor:
#   §1 with a NEW MM intent in flight past the sweep's dispatch: the walk skips
#      the MM's shielded ask and fills the AMM's 50100 — the shielded L4 quote
#      is never taken (pre-fix: filled at 50050, maker/maker)
#   §2 with the shield lapsed (no new intent; the old stamp predates the
#      dispatch): the walk fills the MM's 50050 user-vs-user — the swept whale
#      pays the TAKER rate and bins taker volume, the MM (L4, 0 bps) is the
#      maker (pre-fix: whale paid the maker rate and binned maker volume)
# The AMM-leg role (swept order maker-rated against the AMM) stays pinned by
# test_po_sweep_fee.sh and test_volume_credit.sh §2/§3.
# Needs #dev. ⚠️ Calls resetExchange (reset again at exit).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

if [ "$(venue_posture)" != "dev" ]; then skip_posture "test_sweep_shield_roles" "setTestScorecard / setAmmRefPrice (#dev hooks)"; fi

mdx_identity_new sr_mm; MM=$(principal_of sr_mm); mdx_identity_new sr_whl; WHL=$(principal_of sr_whl); mdx_identity_new sr_seed; SEED=$(principal_of sr_seed)
adm()  { echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
mm()   { echo y | icp canister call --candid "$MDX_CANDID" --identity sr_mm   backend "$@" 2>&1; }
whl()  { echo y | icp canister call --candid "$MDX_CANDID" --identity sr_whl  backend "$@" 2>&1; }
seed() { echo y | icp canister call --candid "$MDX_CANDID" --identity sr_seed backend "$@" 2>&1; }
restamp()      { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null; }
requote()      { adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
staged_count() { echo y | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyStagedOrderIds '()' 2>&1 | tr -d '_' | grep -oE "[0-9]+" | wc -l | tr -d ' '; }
open_prices()  { echo y | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyOrders '()' --query 2>&1 | tr -d '_\n' | tr -s ' ' | grep -oE 'price = [0-9]+' | grep -oE '[0-9]+$' | tr '\n' ' '; }
fills()        { echo y | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyTradesSinceId '(0 : nat, 20 : nat)' --query 2>&1 | tr -d '_\n' | tr -s ' '; }
pol()          { echo y | icp canister call --candid "$MDX_CANDID" --identity "$1" backend getAccessPolicy '()' --query 2>&1 | tr -d '_\n' | tr -s ' '; }
field()        { echo "$1" | grep -oE "$2 = [0-9]+" | head -1 | grep -oE '[0-9]+$'; }

# Phase 1 — the crossed user-vs-user book under an in-flight L4 shield.
crossed_book() {
  adm resetExchange "()" >/dev/null 2>&1 || true
  adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
  adm setAmmConfig "(\"BTC-ICPUSD\", 20:nat, 0 : nat, 0:nat, 10:nat)" >/dev/null   # no ladder yet
  restamp
  adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
  for P in "$MM" "$WHL"; do
    adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 1000000.0) : nat)" >/dev/null
    adm setTestBalance "(principal \"$P\", \"BTC\",    $(e8 10.0) : nat)"      >/dev/null
  done
  adm setTestBalance "(principal \"$SEED\", \"BTC\",    $(e8 20.0) : nat)"      >/dev/null
  adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 2000000.0) : nat)" >/dev/null
  mdx_lp_deposit sr_seed "BTC-ICPUSD" "$(e8 5.0)" "$(e8 250000.0)" >/dev/null   # vault stock for the ladder later
  adm setTestScorecard "(principal \"$MM\", $(e8 50000) : nat, 0 : nat, 30 : nat, 25 : nat)" >/dev/null   # L4
  mm placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50050) : nat, $(e8 0.2) : nat)" >/dev/null
  restamp; requote                                                                                        # MM ask rests
  whl placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 50150) : nat, $(e8 0.2) : nat)" >/dev/null # crosses the MM ask — staged
  restamp                                                                                                 # dispatch: the whale's bid is due
  mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49600) : nat, $(e8 0.1) : nat)" >/dev/null  # I1: commensurate ($4,960 ≈ 50% of $10,010; 0.8% off) — staged AFTER the dispatch → shield
  requote                                                                                                 # whale's bid releases: MM ask shielded → the bid RESTS
  local wp mp
  wp=$(open_prices sr_whl); mp=$(open_prices sr_mm)
  if [ "$(staged_count sr_whl)" = "0" ] && echo "$wp" | grep -q "$(e8 50150)" && echo "$mp" | grep -q "$(e8 50050)" && [ "$(staged_count sr_mm)" = "1" ]; then
    ok "$1 fixture: crossed book — whale bid 50150 RESTS above the MM's shielded ask 50050, MM intent I1 in flight"
  else nok "$1 fixture: crossed book not established" "whaleStaged=$(staged_count sr_whl) whaleOpen=[$wp] mmOpen=[$mp] mmStaged=$(staged_count sr_mm)"; fi
}
# Phase 2 — switch the ladder on (best ask 50100 sits between 50050 and 50150)
# and re-stamp the mark: this dispatch postdates I1 (I1 becomes due; its stamp
# no longer shields), and the whale's resting bid now crosses the AMM's ask.
ladder_on() {
  adm setAmmConfig "(\"BTC-ICPUSD\", 20:nat, $(e8 1.0) : nat, 5:nat, 10:nat)" >/dev/null
  restamp
}

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true

echo "── §1 the sweep honours the shield for a non-AMM maker ──"
crossed_book "§1"
ladder_on
mm placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 49650) : nat, $(e8 0.1) : nat)" >/dev/null   # I2: in flight past THIS dispatch → shield holds through the sweep
requote   # ladder posts (ask 50100) → sweep re-homes the whale's bid → processDeferred lands I1
WF=$(fills sr_whl); MF=$(fills sr_mm)
WP=$(field "$WF" price); WN=$(echo "$WF" | grep -o 'trade = record' | wc -l | tr -d ' ')
if [ "${WN:-0}" -ge 1 ] && [ "${WP:-0}" = "$(e8 50100)" ]; then ok "§1: the swept bid filled the AMM's fresh ask @50100 (price improvement kept)"
else nok "§1: swept bid did not fill the AMM ask" "fills=$WN price=${WP:-?} $(echo "$WF" | head -c 200)"; fi
if echo "$(open_prices sr_mm)" | grep -q "$(e8 50050)" && ! echo "$MF" | grep -q 'trade = record'; then ok "§1: the MM's SHIELDED ask @50050 was never taken (still resting, MM has no fill)"
else nok "§1: the sweep took the shielded L4 quote" "mmOpen=[$(open_prices sr_mm)] mmFills=$(echo "$MF" | grep -o 'trade = record' | wc -l | tr -d ' ')"; fi
WFEE=$(field "$WF" buyer); WQ=$(field "$WF" quantity)
if [ -n "$WFEE" ] && [ -n "$WQ" ]; then
  V=$(awk -v q="$WQ" -v p="${WP:-0}" 'BEGIN{ printf "%.0f", q*p/100000000 }')
  MAXMAKER=$(awk -v v="$V" 'BEGIN{ printf "%.0f", v*60/100000 }')    # 6 bps: L0 maker (5) + rounding
  if [ "$WFEE" -le "$MAXMAKER" ]; then ok "§1: against the AMM the swept order keeps the MAKER rate (fee=$WFEE on \$-value $V)"
  else nok "§1: swept-vs-AMM fee not maker-rated" "fee=$WFEE > $MAXMAKER"; fi
else nok "§1: fee fields unreadable" "$(echo "$WF" | head -c 200)"; fi

echo "── §2 a user-vs-user sweep fill has a TAKER leg (the swept order) ──"
crossed_book "§2"
ladder_on     # no new intent: I1's stamp predates this dispatch → the MM's ask is no longer shielded
requote       # sweep re-homes the whale's bid → walks the MM's ask FIRST (50050 < AMM 50100)
WF=$(fills sr_whl); MF=$(fills sr_mm)
WP=$(field "$WF" price); WN=$(echo "$WF" | grep -o 'trade = record' | wc -l | tr -d ' ')
if [ "${WN:-0}" = "1" ] && [ "${WP:-0}" = "$(e8 50050)" ] && echo "$WF" | grep -q "principal \"$MM\""; then ok "§2: the swept bid filled the MM's ask @50050 user-vs-user (one fill, seller = MM)"
else nok "§2: expected one user-vs-user fill at 50050" "fills=$WN price=${WP:-?} $(echo "$WF" | head -c 240)"; fi
WFEE=$(field "$WF" buyer); SFEE=$(field "$WF" seller); WQ=$(field "$WF" quantity)
if [ -n "$WFEE" ] && [ -n "$SFEE" ] && [ -n "$WQ" ]; then
  V=$(awk -v q="$WQ" -v p="${WP:-0}" 'BEGIN{ printf "%.0f", q*p/100000000 }')
  TAKER=$(awk -v v="$V" 'BEGIN{ printf "%.0f", v*100/100000 }')      # L0 taker = 10.0 bps
  MINTAKER=$(awk -v v="$V" 'BEGIN{ printf "%.0f", v*90/100000 }')    # 9 bps: taker (10) − rounding, well above the 5 bps maker rate
  if [ "$WFEE" -ge "$MINTAKER" ]; then ok "§2: the swept whale paid the TAKER rate (fee=$WFEE ≈ $TAKER on \$-value $V; maker would be ≤ $(awk -v v="$V" 'BEGIN{ printf "%.0f", v*50/100000 }'))"
  else nok "§2: the swept whale paid the MAKER rate (maker/maker fill — the finding)" "fee=$WFEE < $MINTAKER"; fi
  if [ "$SFEE" = "0" ]; then ok "§2: the MM is the maker of that fill (L4 maker fee 0)"
  else nok "§2: MM fee not the L4 maker rate" "sellerFee=$SFEE"; fi
else nok "§2: fee fields unreadable" "$(echo "$WF" | head -c 240)"; fi
if echo "$WF" | grep -qE 'buyOrderId = 0 : nat'; then ok "§2: the trade carries the id-0 sentinel on the swept side (taker attribution)"
else nok "§2: swept side stamped with an order id (maker attribution)" "$(echo "$WF" | grep -oE 'buyOrderId = [0-9]+' | head -1)"; fi
WPOL=$(pol sr_whl); WT=$(field "$WPOL" myTakerVolUsd); WMK=$(field "$WPOL" myMakerVolUsd)
if [ "${WT:-0}" -gt 0 ] && [ "${WMK:-0}" = "0" ]; then ok "§2: the whale's fill binned as TAKER volume (taker=$WT maker=$WMK)"
else nok "§2: the whale's fill binned as maker volume (2× maker volume both sides)" "taker=${WT:-?} maker=${WMK:-?}"; fi
MPOL=$(pol sr_mm); MMK=$(field "$MPOL" myMakerVolUsd)   # pinned at $50,000 by setTestScorecard; the fill adds ~$10,010
if [ "${MMK:-0}" -gt "$(e8 50000)" ]; then ok "§2: the MM's leg binned as MAKER volume (maker=$MMK > the pinned \$50k)"
else nok "§2: MM leg not maker volume" "maker=${MMK:-?}"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
