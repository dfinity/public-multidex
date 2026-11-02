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
#
# §3 (H-23 / F6): the owner commit lock is BOUND to the arm. Past the 3s
# wall-clock window a staged entry stays committed while an arm dispatched
# AFTER it was staged is live within the TTL — the free look was cancelling
# an adverse outcome while the venue's fetch was parked in its fan-out. Timers
# are paused for §3 so the seat's own GEPTOR/tick cannot release the probes;
# the exits are each asserted: no arm (stall exit), an arm OLDER than the
# entry, a lapsed arm (TTL), the entry's expiry — and the expiry release
# itself still runs under a live arm (the lock is cancel-only) — and §3f: the
# controller-only admin fetch (fetchAndSetRefPrice) is a locking dispatcher too
# (task 3088525590; it stamps the shared _fetchInFlight map beside the tick).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_geptor_inflight_guard ──"

[ "$(venue_posture)" = "dev" ] || skip_posture "test_geptor_inflight_guard" "devPoisonGeptorInFlight / devGetGeptorInFlight (#dev hooks)"

setup_mode staged    # alice: staged BUY on BTC-ICPUSD; bob: 5 BTC

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

# ── 3. H-23 / F6: the commit lock is bound to a post-staging arm.
call setTestTimersPaused '(true)' > /dev/null
stage_far_sell() { # $1 = price → prints the staged id
  call placeLimitOrder "(\"$MID\", variant { sell }, $(e8 "$1") : nat, $(e8 0.1) : nat)" --identity bob \
    | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+"
}
LOCK_TXT="fetch dispatched after it was staged is in flight"
# 3a. stall exit: no arm in flight → cancellable once the 3s window is over.
call devPoisonGeptorInFlight "(\"$MID\", $STALE_AGE_NS : int)" > /dev/null   # whatever §2 left: lapsed
OA=$(stage_far_sell 230000.0); sleep 3.2
assert_ok "3a stall exit: no live arm → cancel ok at 3.2s" "$(call cancelMyOrder "(${OA:-0} : nat)" --identity bob)"
# 3b. an arm dispatched BEFORE the entry does not lock it (it cannot release it).
call devPoisonGeptorInFlight "(\"$MID\", 0 : int)" > /dev/null
sleep 0.3; OB=$(stage_far_sell 231000.0); sleep 3.2
assert_ok "3b arm older than the entry → cancel ok (that fetch cannot release it)" "$(call cancelMyOrder "(${OB:-0} : nat)" --identity bob)"
# 3c. THE LOCK: an arm dispatched after the entry, live within the TTL → refused; lapsed → ok.
OC=$(stage_far_sell 232000.0); sleep 3.2
call devPoisonGeptorInFlight "(\"$MID\", 0 : int)" > /dev/null   # armed now (> entry ts)
CC=$(call cancelMyOrder "(${OC:-0} : nat)" --identity bob)
case "$CC" in
  *"$LOCK_TXT"*) _ok "3c live post-staging arm → cancel REFUSED with the in-flight lock text" ;;
  *) _fail "3c cancel not refused under a live post-staging arm (the F6 free look): $(echo "$CC" | tr -d '\n' | head -c 140)" ;;
esac
STAGED_C=$(call getMyStagedOrderIds '()' --identity bob | grep -c "${OC:-x} : nat" || true)
assert_eq "3c the refused entry is still staged" "1" "$STAGED_C"
call devPoisonGeptorInFlight "(\"$MID\", $STALE_AGE_NS : int)" > /dev/null   # the arm lapsed
assert_ok "3c arm past GEPTOR_INFLIGHT_TTL_NS → cancel ok (no permanent latch)" "$(call cancelMyOrder "(${OC:-0} : nat)" --identity bob)"
# 3d. expiry exit: a live arm, but the entry's expiry has passed → cancel ok.
OD=$(stage_far_sell 233000.0); sleep 3.2
call devPoisonGeptorInFlight "(\"$MID\", 0 : int)" > /dev/null
call setTestDeferredExpiry "(${OD:-0} : nat, 1 : int)" > /dev/null
assert_ok "3d entry past its expiry → cancel ok even under a live arm" "$(call cancelMyOrder "(${OD:-0} : nat)" --identity bob)"
# 3e. the lock is cancel-only: the users-only expiry release still runs under a live arm.
OE=$(stage_far_sell 234000.0); sleep 3.2
call devPoisonGeptorInFlight "(\"$MID\", 0 : int)" > /dev/null
call setTestDeferredExpiry "(${OE:-0} : nat, 1 : int)" > /dev/null
call adminRunDeferredExpiry '()' > /dev/null
STAGED_E=$(call getMyStagedOrderIds '()' --identity bob | grep -c "${OE:-x} : nat" || true)
assert_eq "3e expiry release under a live arm: entry left the staged set" "0" "$STAGED_E"
# 3f. THE THIRD DISPATCHER (task 3088525590): the controller-only admin fetch
#     (fetchAndSetRefPrice) stamps the shared in-flight map, so an operator's
#     manual fetch dispatched after the entry locks it for its duration exactly
#     as a GEPTOR arm or a tick fetch does. No poison here — the GEPTOR entry is
#     lapsed, timers are paused (no tick), so ONLY the admin fetch can lock.
#     Locally the fetch is a real 8-way HTTPS fan-out, but a FAST one (~0.8–1s
#     canister-side; a plain update round-trips in ~0.3s), so the
#     test_oracle_time_bases §4 shape (background fetch, 1s pause, one probe)
#     observed the window about one attempt in three. Three things make it
#     observable here:
#       · ORDERING comes from the 3s commit window, not a sleep: the first
#         fetch is fired ~2s after staging, so it is dispatched AFTER the entry
#         and BEFORE the window closes by construction, and every probe that
#         executes inside the window is refused with the window text (never a
#         cancel) — the probe loop simply keeps going until the window opens.
#       · WIDTH comes from staggering three fetches 0.5s apart: each re-stamps
#         the market and each clears ONLY its own stamp (the guarded delete),
#         so the lock holds until the LAST one lands (~1.5s past the window).
#       · NO RELEASE: the source floor is pinned at 99 for the duration, so
#         every fetch completes its fan-out but is refused below the floor —
#         no mark, so the entry can never leave the staged set by release and
#         "cancel ok" past the lock can only mean the lock let go.
#     Verdicts: refused with the lock text → LOCKED (definitive — only an
#     in-flight stamp produces it); cancelled while a fetch's CLI call is still
#     parked → the HOLE (pre-fix: the admin path captured dispatchNs for the
#     release reference but never stamped the map); every fetch landed with the
#     entry never seen locked → inconclusive, a fresh entry is staged and the
#     attempt repeats (three attempts).
call devPoisonGeptorInFlight "(\"$MID\", $STALE_AGE_NS : int)" > /dev/null   # GEPTOR arm lapsed: not a locker
call setTestMinSources '(opt (99 : nat))' > /dev/null                        # floor unreachable: fetches refuse, never release
COMMIT_TXT="cancellable in a few seconds"
TMPF=$(mktemp -d); F_VERDICT="inconclusive"; F_ATTEMPT=0; OF=""; CF=""
for F_ATTEMPT in 1 2 3; do
  OF=$(stage_far_sell 235000.0)
  sleep 2.0; ( call fetchAndSetRefPrice "(\"$MID\")" > "$TMPF/fetch1" 2>&1 ) & FP1=$!
  sleep 0.5; ( call fetchAndSetRefPrice "(\"$MID\")" > "$TMPF/fetch2" 2>&1 ) & FP2=$!
  ( sleep 0.5; call fetchAndSetRefPrice "(\"$MID\")" > "$TMPF/fetch3" 2>&1 ) & FP3=$!
  F_VERDICT="inconclusive"; F_PROBES=0
  while [ "$F_PROBES" -lt 60 ]; do
    F_PROBES=$((F_PROBES + 1))
    CF=$(call cancelMyOrder "(${OF:-0} : nat)" --identity bob)
    F_ALIVE=0; for P in "$FP1" "$FP2" "$FP3"; do kill -0 "$P" 2>/dev/null && F_ALIVE=1; done
    case "$CF" in
      *"$LOCK_TXT"*)   F_VERDICT="locked"; break ;;
      *"$COMMIT_TXT"*) ;;                                           # inside the 3s window: keep probing
      *) if [ "$F_ALIVE" = 1 ]; then F_VERDICT="hole"; fi; break ;;  # cancelled — while a fetch was still parked = the hole
    esac
    [ "$F_ALIVE" = 1 ] || break                                     # every fetch landed, never seen locked: inconclusive
    sleep 0.1
  done
  wait "$FP1" "$FP2" "$FP3"
  [ "$F_VERDICT" = "inconclusive" ] || break
  call cancelMyOrder "(${OF:-0} : nat)" --identity bob > /dev/null 2>&1 || true   # clear the probe entry, retry
done
case "$F_VERDICT" in
  locked)
    _ok "3f admin fetch dispatched after the entry → cancel REFUSED with the in-flight lock text (attempt $F_ATTEMPT, probe $F_PROBES)"
    STAGED_F=$(call getMyStagedOrderIds '()' --identity bob | grep -c "${OF:-x} : nat" || true)
    assert_eq "3f the refused entry is still staged (refused fetches release nothing)" "1" "$STAGED_F"
    assert_ok "3f every admin fetch landed → cancel ok (the lock followed the last fetch, no latch)" "$(call cancelMyOrder "(${OF:-0} : nat)" --identity bob)" ;;
  hole)
    _fail "3f cancel ok while an admin fetch was still parked (the free look via fetchAndSetRefPrice, probe $F_PROBES): $(echo "$CF" | tr -d '\n' | head -c 120)" ;;
  *)
    _fail "3f inconclusive: every admin fetch landed before the window opened on all 3 attempts (last probe: $(echo "$CF" | tr -d '\n' | head -c 80); last fetch: $(tr -d '\n' < "$TMPF/fetch3" | head -c 80))" ;;
esac
call setTestMinSources '(null)' > /dev/null
rm -rf "$TMPF"
call cancelAllMyOrders '(null)' --identity bob > /dev/null 2>&1 || true
call devPoisonGeptorInFlight "(\"$MID\", $STALE_AGE_NS : int)" > /dev/null
call setTestTimersPaused '(false)' > /dev/null

finish_test "test_geptor_inflight_guard"
