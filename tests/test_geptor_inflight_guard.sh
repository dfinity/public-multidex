#!/bin/bash
# #52.6 — the _geptorInFlight guard must be self-clearing, never a permanent
# latch. The arm (in processGeptorDue, the CALLER's message) and the release
# (geptorFetchAndSweep's `finally`, a SEPARATE message) commit independently:
# a failed self-call send or a pre-await callee trap leaves the arm committed
# with no release. The guard is therefore a TIMESTAMP with a TTL
# (GEPTOR_INFLIGHT_TTL_NS = 60s): a fresh entry dedups dispatch exactly as the
# old bool did; a stale entry is treated as not-in-flight and overwritten.
#
# The failure itself (a send that never enqueues) cannot be forced on a local
# replica, so this is a HOOK-LEVEL demonstration: devPoisonGeptorInFlight
# plants an entry of arbitrary age directly, and the assertions watch
# processGeptorDue honour a fresh one (dedup: the entry survives untouched —
# no dispatch ran, so no `finally` deleted it) and ignore-then-clear a stale
# one (self-heal: dispatch proceeds despite the latch, and its `finally`
# removes its own arm). With the pre-fix bool, the stale case latched forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_geptor_inflight_guard ──"

[ "$(venue_posture)" = "dev" ] || skip_posture "test_geptor_inflight_guard" "devPoisonGeptorInFlight / devGetGeptorInFlight (#dev hooks)"

setup_mode pending   # alice: staged BUY on BTC-ICPUSD; bob: 5 BTC

MID="BTC-ICPUSD"
STALE_AGE_NS=120000000000   # 120s — twice GEPTOR_INFLIGHT_TTL_NS

get_guard() { call devGetGeptorInFlight "(\"$MID\")" --query | tr -d '\n'; }

# ── 0. Baseline: the fixture's own seed-time GEPTORs have long completed,
#      so the guard entry must be absent (the `finally` released each arm).
wait_for '[ "$(call devGetGeptorInFlight "(\"BTC-ICPUSD\")" --query | grep -c "null")" -ge 1 ]' 30 2
G0=$(get_guard)
case "$G0" in
  *null*) _ok "baseline: no in-flight entry for $MID" ;;
  *)      _fail "baseline: unexpected in-flight entry: $G0" ;;
esac

# ── 1. FRESH poison → the dispatch-window dedup still holds.
#      Plant an entry aged 0, then arm a GEPTOR by staging an order. The due
#      pass must SKIP dispatch (entry younger than the TTL), so nothing runs a
#      `finally` and the poisoned value survives byte-for-byte.
call devPoisonGeptorInFlight "(\"$MID\", 0 : int)" > /dev/null
P1=$(get_guard | grep -oE '[0-9_]{10,}' | head -1)
assert_gt "fresh poison planted (armed-at recorded)" "${P1//_/}" "0"

# A far-from-market SELL: stages (arming the deadline), never crosses.
call placeLimitOrder "(\"$MID\", variant { sell }, $(e8 200000.0) : nat, $(e8 0.1) : nat)" --identity bob > /dev/null
sleep 4   # deadline 1s + finaliser 0.5s cadence + margin — the due pass has run
P2=$(get_guard | grep -oE '[0-9_]{10,}' | head -1)
assert_eq "fresh entry deduped the dispatch (guard value untouched)" "$P1" "$P2"

# ── 2. STALE poison → the latch self-heals instead of sticking.
#      Plant an entry aged 120s (past the 60s TTL), arm another GEPTOR. The
#      due pass must treat the entry as NOT in flight, overwrite it with a
#      real arm, dispatch — and that flight's `finally` deletes its own arm,
#      leaving the guard EMPTY. The pre-fix bool stayed latched here forever
#      (transient map: survives performWorldWipe, cleared only by upgrade).
call devPoisonGeptorInFlight "(\"$MID\", $STALE_AGE_NS : int)" > /dev/null
call placeLimitOrder "(\"$MID\", variant { sell }, $(e8 210000.0) : nat, $(e8 0.1) : nat)" --identity bob > /dev/null

# The fetch fans out to real HTTPS outcalls locally — allow a generous window.
if wait_for '[ "$(call devGetGeptorInFlight "(\"BTC-ICPUSD\")" --query | grep -c "null")" -ge 1 ]' 90 2; then
  _ok "stale latch self-healed: dispatch proceeded and its finally cleared the guard"
else
  _fail "stale latch STUCK: guard still holds $(get_guard) after 90s (pre-#52.6 behaviour)"
fi

finish_test "test_geptor_inflight_guard"
