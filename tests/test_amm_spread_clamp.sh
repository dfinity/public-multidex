#!/bin/bash
# W4-23 (R12 retargeted) — an UNCONFIRMED breaker pend must not empty the bid
# ladder.
#
# ammBreakerWidenBps returns |proposed − ref|/ref × 10000 with no cap, and it
# entered the half-spread sum at full weight: a merely PENDING 2.5× upward
# proposal put breakerBps past 9,980, drove half ≥ 1.0, zeroed every bid
# target — and ammApplyQuotes' off-ladder sweep then CANCELLED every resting
# bid, silently. R12 blamed volRegime, whose trigger needs a ~550× one-step
# mark move (unreachable); the pend path needs one bad source for one
# reading. The fix clamps the COMBINED half-spread (0.5) in buildQuoteLadder
# — bounding all four contributors — and adds the missing edge-triggered
# bid-withdrawn warn beside the floor/stale logs.
#
#   §1 baseline: pool quoting normally, bid side present
#   §2 inject a pending 2.5× jump (setTestPendingJump, dev) → requote →
#      the bid side SURVIVES (clamped at ≤50% half-spread; pre-fix: empty)
#   §3 clear the pend → requote → bids at normal width again
#
# State-light on a seeded #dev venue: uses whatever pool exists, restores the
# pend to empty. Needs #dev (setTestPendingJump, requoteAmm, setAmmRefPrice).
set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

MKT=$(adm getAmmPools '()' --query | grep -o 'marketId = "[^"]*"' | head -1 | cut -d'"' -f2)
[ -n "$MKT" ] || { echo "no AMM pool on this venue — seed first"; exit 1; }
BASE=$(echo "$MKT" | cut -d- -f1)
bidcount() {  # resting bids on the book right now (field order agnostic)
  adm getOrderBook "(\"$MKT\")" --query | tr -d '_\n' | tr -s ' ' \
    | awk -F'bids = vec' '{print $2}' | awk -F'asks = vec' '{print $1}' \
    | grep -o 'price =' | wc -l | tr -d ' '
}
# The GEPTOR keeper re-stamps the LIVE ref within ~2s, so a synthetic
# setAmmRefPrice does not stick — derive the pend from the CURRENT ref
# instead (2.5×, matching the finding's scenario).
REF=$(adm getAmmPools '()' --query | tr -d '_\n' | tr -s ' ' | grep -o 'refPrice = [0-9]*' | head -1 | grep -o '[0-9]*$')
[ -n "$REF" ] && [ "$REF" -gt 0 ] || { echo "pool has no refPrice — seed first"; exit 1; }
PEND=$(awk -v r="$REF" 'BEGIN{ printf "%.0f", r*2.5 }')

echo "── §1 baseline quoting (ref=$REF) ──"
adm setTestPendingJump "(\"$BASE\", null, null)" >/dev/null   # ensure no stale pend
adm requoteAmm "(\"$MKT\")" >/dev/null
B0=$(bidcount)
if [ "${B0:-0}" -ge 1 ]; then ok "bid side present at baseline ($B0 resting bids)"; else nok "no bids at baseline (fixture)" "book empty — is the pool enabled+funded?"; fi

echo "── §2 a pending, UNCONFIRMED 2.5× jump must not withdraw the bids ──"
adm setTestPendingJump "(\"$BASE\", opt ($PEND : nat), opt (5 : nat))" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
B1=$(bidcount)
if [ "${B1:-0}" -ge 1 ]; then
  ok "bid side SURVIVES the pend ($B1 bids; pre-fix: 0 — every resting bid cancelled)"
else nok "bid ladder emptied by an unconfirmed proposal (the finding)" "bids=$B1"; fi

echo "── §3 pend cleared → normal width restored ──"
adm setTestPendingJump "(\"$BASE\", null, null)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
B2=$(bidcount)
if [ "${B2:-0}" -ge "${B0:-1}" ]; then ok "bid side restored ($B2 bids)"; else nok "bids did not recover after the pend cleared" "before=$B0 after=$B2"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_amm_spread_clamp ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_amm_spread_clamp ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
