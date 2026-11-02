#!/bin/bash
# H-23 (F27 + F39 + F6) — the sealed model keys on fetch DISPATCH time.
#
# `refPriceUpdatedNs` is the mark's ARRIVAL/observation clock (W3-06): right
# for every staleness wall, wrong as the anti-snipe key — the providers served
# the price at or after the fetch was DISPATCHED, and the response lands
# seconds later. The release reference is now the dispatch clock of the
# standing mark (`releaseRefs`, stamped by every mark writer; read by
# processDeferred, ammSweepResting, the L4 shield pass and the cross-swap
# predicate), a fresh mark is not a fresh LADDER (the cross-swap predicate
# also wants lastRequoteNs ≥ the mark's applied clock), and the owner commit
# lock is bound to a fetch dispatched after the entry (either leg of a swap).
#
#   §1 F27 — a staged limit order whose ts postdates the standing mark's
#      dispatch is HELD even when the arrival clock moves past it; a mark
#      dispatched after it (setAmmRefPrice = dispatch+apply now) releases it
#   §2 F39 — a staged cross-swap with BOTH marks fresh (dispatched after it)
#      but neither ladder requoted stays staged; requoting both releases it
#   §3 F6  — a staged cross-swap past the 3s window cannot be cancelled while
#      a GEPTOR arm dispatched after it is live on EITHER leg; a lapsed arm
#      (past GEPTOR_INFLIGHT_TTL_NS) unlocks it
#
# Pre-fix (mark keyed on arrival, lock = 3s wall clock) every gate assertion
# here goes red: the §1 order releases against the pre-order ladder, the §2
# swap executes against the stale ladders, the §3 cancel succeeds.
#
# Self-seeded like test_cross_swap.sh (resetExchange, timers paused, two
# pools); needs #dev (setAmmRefPrice / setTestRefPriceUpdatedNs /
# devPoisonGeptorInFlight). Resets at exit.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of / mdx_ok); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_sealed_release_reference" "setAmmRefPrice / setTestRefPriceUpdatedNs / devPoisonGeptorInFlight (#dev hooks)"

e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
adm()  { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
bal()  { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
avail() { local n; n=$(u getMyAvailableBalance "(\"$1\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
setup_pool() { # market base refprice baseSeed quoteSeed
  adm createAmmPool "(\"$1\")" >/dev/null 2>&1
  adm setAmmConfig "(\"$1\", 20:nat, $(e8 "$4") : nat, 5:nat, 25:nat)" >/dev/null
  adm setAmmRefPrice "(\"$1\", $(e8 "$3") : nat)" >/dev/null
  adm setTestBalance "(principal \"$S\", \"$2\", $(e8 "$4") : nat)" >/dev/null
  adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 "$5") : nat)" >/dev/null
  mdx_lp_deposit rr_seed "$1" "$(e8 "$4")" "$(e8 "$5")" >/dev/null 2>&1
  adm enableAmm "(\"$1\", true)" >/dev/null
  adm requoteAmm "(\"$1\")" >/dev/null
}
freshrequote() { adm setAmmRefPrice "(\"$1\", $(e8 "$2") : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }
# UA's staged (off-book) entries, and whether the ICP book carries a bid ≈ arg (human).
ua_staged() { u getMyStagedOrderIds '()' | grep -oE "[0-9_]+ : nat" | wc -l | tr -d ' '; }
book_has_price() { local t; t=$(e8 "$2"); adm getOrderBook "(\"$1\")" 2>&1 | tr -d '_' | grep -oE "price = [0-9]+" | grep -oE "[0-9]+" | awk -v t="$t" 'function abs(x){return x<0?-x:x} abs($1-t)<2000000{f=1} END{print (f?"yes":"no")}'; }
release_ref() { adm getReleaseInfo "(\"$1\")" --query | tr -d '_\n' | tr -s ' ' | grep -oE "releaseRefNs = [0-9-]+" | head -1 | awk '{print $3}'; }
now_ns_plus() { echo $(( ($(date +%s) + $1) * 1000000000 )); }

mdx_identity_new rr_seed; S=$(principal_of rr_seed); mdx_identity_new rr_uA; UA=$(principal_of rr_uA)
u() { icp canister call --candid "$MDX_CANDID" --identity rr_uA backend "$@" 2>&1; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # no beat: no GEPTOR due pass, no tick, no finaliser — every release below is ours
setup_pool "ICP-ICPUSD" "ICP" 10.0  10000.0 100000.0
setup_pool "BTC-ICPUSD" "BTC" 100.0  1000.0  100000.0
for t in ICP BTC ICPUSD; do adm setTestBalance "(principal \"$UA\", \"$t\", $(e8 0.0) : nat)" >/dev/null; done
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 200.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICPUSD\", $(e8 10000.0) : nat)" >/dev/null

# ── §1 F27: the release gate keys on DISPATCH, not arrival ──
echo ""
echo "── §1 F27: an order staged after the mark's dispatch is HELD when only the arrival clock moves ──"
REF0=$(release_ref "ICP-ICPUSD")
if [ -n "$REF0" ] && [ "${REF0:-0}" -gt 0 ] 2>/dev/null; then ok "getReleaseInfo exposes the release reference (releaseRefNs=$REF0, D6: kept public)"; else nok "getReleaseInfo has no releaseRefNs (pre-H-23 shape)" "$(adm getReleaseInfo '("ICP-ICPUSD")' --query | tr -d '\n' | head -c 160)"; fi
# A passive BUY below the ladder (asks ≈ 10.02): stages, and on release RESTS on the book.
R=$(u placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.0) : nat, $(e8 2.0) : nat)")
if mdx_ok "$R" && [ "$(ua_staged)" = "1" ]; then ok "passive buy @9.0 staged (1 off-book entry, not on the book)"; else nok "order should stage" "staged=$(ua_staged) res=[$(echo "$R" | head -c 120)]"; fi
# The standing mark's ARRIVAL clock moves past the order (a response landing
# after it was staged, from a fetch dispatched BEFORE it) — the pre-fix key.
adm setTestRefPriceUpdatedNs "(\"ICP-ICPUSD\", $(now_ns_plus 2) : int)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
if [ "$(ua_staged)" = "1" ] && [ "$(book_has_price ICP-ICPUSD 9.0)" = "no" ]; then
  ok "HELD: arrival clock past the order but the dispatch clock is not — still staged, not on the book"
else nok "released against a pre-order ladder (the F27 finding)" "staged=$(ua_staged) book9=$(book_has_price ICP-ICPUSD 9.0)"; fi
REF1=$(release_ref "ICP-ICPUSD")
if [ "$REF1" = "$REF0" ]; then ok "the release reference did not move with the arrival stamp ($REF1)"; else nok "setTestRefPriceUpdatedNs moved the release reference" "before=$REF0 after=$REF1"; fi
# A mark DISPATCHED after the order (the dev override is dispatch+apply now) releases it.
freshrequote "ICP-ICPUSD" 10.0
if [ "$(ua_staged)" = "0" ] && [ "$(book_has_price ICP-ICPUSD 9.0)" = "yes" ]; then
  ok "RELEASED by a mark dispatched after it: off the staged set, resting @9.0 on the book"
else nok "a post-order dispatch should release" "staged=$(ua_staged) book9=$(book_has_price ICP-ICPUSD 9.0)"; fi
REF2=$(release_ref "ICP-ICPUSD")
if [ -n "$REF2" ] && [ "${REF2:-0}" -gt "${REF1:-0}" ] 2>/dev/null; then ok "the release reference advanced with the new mark ($REF1 → $REF2)"; else nok "reference did not advance" "before=$REF1 after=$REF2"; fi
u cancelMyOrder "($(u getMyOrdersOnMarket '("ICP-ICPUSD")' | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+") : nat)" >/dev/null 2>&1

# ── §2 F39: a fresh mark is not a fresh ladder ──
echo ""
echo "── §2 F39: both marks fresh (dispatched after the swap) but ladders NOT requoted → still staged ──"
R=$(u swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 50.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })")
SW1=$(echo "$R" | tr -d '_' | grep -oE "swapOrderId = opt \([0-9]+" | grep -oE "[0-9]+$")
BTC_P=$(bal "$UA" BTC)
if [ -n "$SW1" ] && awk -v x="$BTC_P" 'BEGIN{exit (x<0.0000001?0:1)}'; then ok "cross-swap 50 ICP → BTC staged (id $SW1, 0 BTC)"; else nok "cross-swap should stage" "res=[$(echo "$R" | head -c 120)]"; fi
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null    # dispatch+apply now on BOTH legs — no requote
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 100.0) : nat)" >/dev/null
adm adminRunDeferredSwaps "()" >/dev/null 2>&1
BTC_S=$(bal "$UA" BTC)
if awk -v x="$BTC_S" 'BEGIN{exit (x<0.0000001?0:1)}'; then ok "HELD: marks fresh on both legs, ladders stale (lastRequoteNs < applied) — not executed"; else nok "executed against stale ladders (the F39 finding)" "btc=$BTC_S"; fi
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm adminRunDeferredSwaps "()" >/dev/null 2>&1
BTC_H=$(bal "$UA" BTC)
if awk -v x="$BTC_H" 'BEGIN{exit (x<0.0000001?0:1)}'; then ok "one ladder requoted → still held (needs BOTH)"; else nok "released on one fresh ladder" "btc=$BTC_H"; fi
adm requoteAmm '("BTC-ICPUSD")' >/dev/null
adm adminRunDeferredSwaps "()" >/dev/null 2>&1
BTC1=$(bal "$UA" BTC); ICP1=$(bal "$UA" ICP)
if awk -v b="$BTC1" 'BEGIN{exit (b>4.7?0:1)}' && awk -v i="$ICP1" 'BEGIN{exit (i<150.5?0:1)}'; then
  ok "RELEASED once both ladders postdate their marks: UA holds $BTC1 BTC (~5), ICP $ICP1 (~150)"
else nok "both-requoted release should execute both legs" "btc=$BTC1 icp=$ICP1"; fi

# ── §3 F6: the commit lock is bound to a fetch dispatched after the entry ──
echo ""
echo "── §3 F6: a staged cross-swap past 3s stays committed while a post-staging arm is live on either leg ──"
for LEG in BTC-ICPUSD ICP-ICPUSD; do
  R=$(u swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 10.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })")
  SW=$(echo "$R" | tr -d '_' | grep -oE "swapOrderId = opt \([0-9]+" | grep -oE "[0-9]+$")
  AV0=$(avail ICP)
  sleep 3.2                                                          # the wall-clock window is over
  adm devPoisonGeptorInFlight "(\"$LEG\", 0 : int)" >/dev/null       # an arm dispatched NOW (> swap ts) on this leg
  C=$(u cancelMyOrder "(${SW:-0} : nat)")
  if echo "$C" | grep -q "fetch dispatched after it was staged is in flight"; then
    ok "$LEG arm live → cancel refused with the in-flight lock text (swap $SW, 3.2s after staging)"
  else nok "cancel succeeded under a live post-staging arm on $LEG (the F6 free look)" "$(echo "$C" | tr -d '\n' | head -c 140)"; fi
  AV1=$(avail ICP)
  if [ "$AV1" = "$AV0" ]; then ok "reservation intact while locked (available ICP $AV1)"; else nok "balance moved on a refused cancel" "$AV0 → $AV1"; fi
  adm devPoisonGeptorInFlight "(\"$LEG\", 120000000000 : int)" >/dev/null   # the arm lapsed (2× GEPTOR_INFLIGHT_TTL_NS)
  C2=$(u cancelMyOrder "(${SW:-0} : nat)")
  if mdx_ok "$C2"; then ok "arm past its TTL → cancel permitted again (the lock never latches)"; else nok "cancel still refused after the arm lapsed" "$(echo "$C2" | tr -d '\n' | head -c 140)"; fi
  AV2=$(avail ICP)
  if awk -v a="$AV2" -v b="$AV0" 'BEGIN{exit ((a-b > 9.99 && a-b < 10.01)?0:1)}'; then ok "the 10 ICP reservation refunded (available $AV0 → $AV2)"; else nok "refund wrong" "$AV0 → $AV2"; fi
done

echo ""
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
