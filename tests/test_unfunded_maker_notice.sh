#!/bin/bash
# W4-24 (R5(c)) — the graceful unfunded-maker cancel is REPORTED, and the
# fill walks on.
#
# Resting orders hold no reservation (documented design), so a maker whose
# balance moved can be resting unfunded. Every fill path re-checks and
# cancels such makers GRACEFULLY (no solvency hole — the taker walks to the
# next level), but the cancel used to be SILENT — against the "never silent"
# doctrine that cancelPoolRestingOrder and cancelSelfMaker both follow. The
# engine now reports through ProtectionCtx.onUnfundedMaker and the owner
# gets a release-rejection notice.
#
#   §1 fresh pool; maker rests a bid AT ref (inside the AMM spread)
#   §2 maker's backing balance is drained (setTestBalance 0)
#   §3 a taker sell crosses: the maker's order is cancelled GRACEFULLY, the
#      taker's fill continues to the AMM bid behind it
#   §4 the maker's getMyReleaseRejections gained the mid-match notice
#
# Venue physics — the release gate is PRICE-FRESHNESS, not a delay: a staged
# entry releases only once a fresh ref price POSTDATES it (anti-snipe,
# processDeferred: d.ts < refPriceUpdatedNs). With timers paused there is no
# GEPTOR keeper to fetch one, so the test RE-STAMPS setAmmRefPrice (same
# price — the dev override, which also clears any pending-jump entry) before
# each releasing requote. The first red-cycle of this fixture stalled with
# both orders staged-open because it slept for the mythical "~2s anti-free-
# look" instead of re-stamping — getMyOrders shows staged entries too, so
# the §1 "rests" check even passed. getMyStagedOrderIds is the discriminator.
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
M=$(mkid ufm_m); T=$(mkid ufm_t)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
SEED=$(mkid ufm_seed)
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 300.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 20000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
icp canister call --identity ufm_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 20000.0) : nat, $(e8 200000.0) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null

echo "── §1 maker rests a bid AT ref (inside the spread) ──"
adm setTestBalance "(principal \"$M\", \"ICPUSD\", $(e8 20000.0) : nat)" >/dev/null
icp canister call --identity ufm_m backend placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.00) : nat, $(e8 1000.0) : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null   # re-stamp: fresh price postdates the entry
adm requoteAmm '("ICP-ICPUSD")' >/dev/null                           # → releases → rests
MO=$(icp canister call --identity ufm_m backend getMyOrders '()' --query | tr -d '_\n' | grep -c 'id = ')
STG=$(icp canister call --identity ufm_m backend getMyStagedOrderIds '()' --query | tr -d ' \n_')
if [ "${MO:-0}" -ge 1 ] && [ "$STG" = "(vec{})" ]; then ok "maker's bid RESTS at 10.00 (released — staged set empty; AMM bid ≈9.98, ask ≈10.02)"; else nok "maker's bid did not rest (fixture)" "open=$MO staged=$STG $(icp canister call --identity ufm_m backend getMyReleaseRejections '()' --query | tr -d '\n' | head -c 150)"; fi
R0=$(icp canister call --identity ufm_m backend getMyReleaseRejections '()' --query | tr -d '\n' | grep -c 'mid-match' || true)

echo "── §2 the backing balance is drained out from under it ──"
adm setTestBalance "(principal \"$M\", \"ICPUSD\", 0 : nat)" >/dev/null
ok "maker balance forced to 0 (resting order holds no reservation, by design)"

echo "── §3 a taker crosses: graceful cancel, fill walks on ──"
adm setTestBalance "(principal \"$T\", \"ICP\", $(e8 2000.0) : nat)" >/dev/null
icp canister call --identity ufm_t backend placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 9.90) : nat, $(e8 500.0) : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null   # re-stamp → the crossing sell releases
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
TT=$(icp canister call --identity ufm_t backend getMyTradesSinceId '(0 : nat, 5 : nat)' --query | tr -d '\n' | grep -c 'trade = record' || true)
if [ "${TT:-0}" -ge 1 ]; then ok "taker filled anyway ($TT fill(s) — walked past the unfunded maker to real liquidity)"; else nok "taker did not fill (graceful-walk broken?)" "$(icp canister call --identity ufm_t backend getMyOrders '()' --query | tr -d '\n' | head -c 120)"; fi
MO2=$(icp canister call --identity ufm_m backend getMyOrders '()' --query | tr -d '_\n' | grep -c 'id = ' || true)
[ "${MO2:-9}" = "0" ] && ok "unfunded maker's order is off the book" || nok "unfunded order still resting" "open=$MO2"

echo "── §4 the owner got the notice (the W4-24 fix) ──"
R1=$(icp canister call --identity ufm_m backend getMyReleaseRejections '()' --query | tr -d '\n' | grep -c 'mid-match' || true)
if [ "${R1:-0}" -gt "${R0:-0}" ]; then
  ok "release-rejection notice recorded: 'cancelled mid-match — balance no longer covers it'"
else nok "cancel was SILENT (the finding — no notice recorded)" "before=$R0 after=$R1 $(icp canister call --identity ufm_m backend getMyReleaseRejections '()' --query | tr -d '\n' | head -c 150)"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_unfunded_maker_notice ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_unfunded_maker_notice ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
