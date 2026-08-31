#!/bin/bash
# W1-08 — the archive ship queue applies backpressure at admission.
#
# The shipper drains at most SHIP_BATCH_MAX per HB_SHIP_NS (200 events/s, a
# hard ceiling). Free tape-writing methods used to grow `userEvents` in the
# backend's own heap with NOTHING throttling them: the L2 shed deliberately
# never fires on a HEALTHY shipper, and the L1 floor keyed only on staged
# depth — an attacker placing zero orders never raised it. ~10 GB/day of
# heap against a ~6 GiB wall = main-canister OOM that halts trading.
#
# The fix feeds List.size(userEvents) into recomputeShedFloor as a second
# hysteresis signal (SHED_*_SHIP bands). This test proves it BEHAVIOURALLY,
# through the real recompute path — the floor is never pinned:
#
#   §1 pause timers (shipper stops draining), read the baseline queue depth
#   §2 generate real tape events (faucet deposits), depth grows
#   §3 pin the ship bands just UNDER the new depth → recompute raises the
#      floor from REAL queue pressure; stats surface shows both
#   §4 an ENTRY method (placeLimitOrder) is refused AT THE GATE
#   §5 an EXIT method (withdraw) still reaches its body (W1-05 exit set)
#   §6 bands released → real 50k bands see a tiny queue → floor drops,
#      entry reaches its body again; timers back on
#
# State-light: no resetExchange, no seeding — safe against any #dev venue.
# Needs #dev (setTestShipShedBands, setTestTimersPaused, addTestTokens).

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --identity shipbp_u backend "$@" 2>&1; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
U=$(mkid shipbp_u)

gate_refused() { echo "$1" | grep -qiE "refus|inspect|403"; }
body_reached() { ! gate_refused "$1" && echo "$1" | grep -qE "ok|err|record|\(|[0-9]"; }
# getAccessPolicy field reader: candid nat with _ separators, first match.
policy_nat() { u getAccessPolicy '()' --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE "$1 = [0-9]+" | grep -oE '[0-9]+' | head -1; }

restore() {  # always leave the venue as found — bands off, timers running
  adm setTestShipShedBands '(null)' >/dev/null 2>&1
  adm setTestTimersPaused '(false)' >/dev/null 2>&1
}
trap restore EXIT

echo "── §1 pause the drain, read the baseline ──"
R=$(u addTestTokens '("ICPUSD", 100_000_000 : nat)')   # faucet registers the caller (dev)
if gate_refused "$R"; then nok "faucet call refused — cannot register" "$R"; else ok "shipbp_u registered via faucet"; fi
adm setTestTimersPaused '(true)' >/dev/null
BASE=$(policy_nat "shipQueueDepth")
if [ -n "$BASE" ]; then ok "baseline shipQueueDepth = $BASE (timers paused, shipper stopped)"; else nok "shipQueueDepth missing from getAccessPolicy" "observability box"; BASE=0; fi

echo "── §2 real free-writes grow the queue ──"
i=0; while [ $i -lt 12 ]; do u addTestTokens '("ICPUSD", 1_000_000 : nat)' >/dev/null; i=$((i+1)); done
D=$(policy_nat "shipQueueDepth"); D=${D:-0}
if [ "$D" -gt "$BASE" ]; then ok "queue grew under paused shipper ($BASE → $D)"; else nok "queue did not grow" "base=$BASE now=$D"; fi

echo "── §3 bands under the depth → the floor rises from REAL pressure ──"
SOFT=$((D > 6 ? D - 6 : 1)); HARD=$((D > 3 ? D - 3 : 2))
SL=$((SOFT > 2 ? SOFT - 2 : 0)); HL=$((HARD > 2 ? HARD - 2 : 1))
adm setTestShipShedBands "(opt record { 0 = $SOFT : nat; 1 = $HARD : nat; 2 = $SL : nat; 3 = $HL : nat })" >/dev/null
FLOOR=$(policy_nat "shedFloor"); FLOOR=${FLOOR:-0}
if [ "$FLOOR" -ge 1 ]; then ok "shedFloor = $FLOOR from ship-queue depth alone (no pin, no staged orders)"; else nok "floor did not rise (depth=$D bands=$SOFT/$HARD)" "floor=$FLOOR"; fi

echo "── §4 entry refused at the gate ──"
R=$(u placeLimitOrder '("ICP-ICPUSD", variant { buy }, 1_000_000_000 : nat, 100_000_000 : nat)')
if gate_refused "$R"; then ok "placeLimitOrder refused pre-consensus under ship backpressure"; else nok "entry method was NOT shed" "$(echo "$R" | head -c 200)"; fi
WHY=$(u whyAmIRefused '()' --query | tr -d '\n' | tr -s ' ')
echo "$WHY" | grep -q "admittedNow = false" && ok "whyAmIRefused: admittedNow = false under the floor" || nok "diagnostic disagrees with the gate" "$WHY"

echo "── §5 the exit set still reaches its body ──"
R=$(u withdraw '("ICPUSD", 1_000_000 : nat, "shipbp-exit-probe")')
if gate_refused "$R"; then nok "withdraw refused at the gate (exit set broken)" "$(echo "$R" | head -c 150)"
elif body_reached "$R"; then ok "withdraw reached its body at floor $FLOOR"
else nok "withdraw gave no classifiable reply" "$(echo "$R" | head -c 150)"; fi

echo "── §6 bands released → floor drops, entry admitted again ──"
adm setTestShipShedBands '(null)' >/dev/null
FLOOR2=$(policy_nat "shedFloor"); FLOOR2=${FLOOR2:-9}
if [ "$FLOOR2" -eq 0 ]; then ok "floor back to 0 under the real 50k bands"; else nok "floor stuck after release" "floor=$FLOOR2"; fi
R=$(u placeLimitOrder '("ICP-ICPUSD", variant { buy }, 1_000_000_000 : nat, 100_000_000 : nat)')
if gate_refused "$R"; then nok "entry still refused after band release" "$(echo "$R" | head -c 150)"; else ok "placeLimitOrder passes the gate again (body-level reply)"; fi
adm setTestTimersPaused '(false)' >/dev/null
ok "timers restored"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_ship_backpressure ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_ship_backpressure ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
