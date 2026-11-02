#!/bin/bash
# H-37 (F34) — the mark is applied on a robust quorum or a per-refresh
# deadline; one slow provider cannot delay the aggregate past the staging
# window.
#
# Before: refreshMultiSourcePrice dispatched eight futures and awaited each
# in order, so one provider that trickled its body set the cadence of every
# mark — staged orders missed DEFERRED_EXPIRY_NS (15s) and fell to the
# users-only pass, FOKs died, marks went a timeout stale. Now each source is
# its own self-call recording into a per-refresh fan-out; the FIRST arrival
# to see a robust quorum (5 of 8, never below minSources) with acceptable
# dispersion applies the mark, every source reporting applies it, and the
# heartbeat's deadline sweep (PRICE_FANOUT_DEADLINE_NS = 8s) applies it on
# what arrived. Late readings attach for observability only. Both in-flight
# guards (the GEPTOR arm, the tick's dispatch stamp) release at finalization.
#
# A provider that never answers cannot be staged against the live feed (#dev
# runs the real sources), so the #dev hook devStallSource pins one by name:
# #never (records nothing) and #park (answers after the mark applied).
#
#   §1 getPriceFeedStats carries the fan-out shape (quorum 5 of 8, deadline 8s)
#      and the staging window it protects (stagingWindowSec 15)
#   §2 baseline: an admin fetch finalizes on quorum/completion, 8 arrivals
#   §3 ONE source never answers: the admin fetch still applies the mark, on
#      7 arrivals, within the deadline (the brief's Verify item)
#   §4 the GEPTOR path under that stall: a staged order's arm releases and
#      its market's mark advances inside the staging window (≤ 13s from
#      staging = DEFERRED_EXPIRY_NS 15s − 2s; THE TWO CLOCKS, below)
#   §5 the DEADLINE path: four sources never answer (4 < quorum 5, 4 < 8), so
#      the heartbeat sweep finalizes at ~8s on 4 ≥ floor 3 — the arm releases
#      and the mark applies, ≤ 10s after the fleet's own dispatch (the
#      deadline's assertion) and ≤ 13s after staging (the window's); the
#      admin fetch drains its own fleet sooner
#   §6 a source that answers LATE attaches (late 1, readings 8) and never
#      re-applies the mark
#   §7 cleared stalls: the next fetch sees all 8 again
#
# Pre-fix the hooks do not exist (every section's first call fails) — and
# the property they pin did not hold: a stalled source held the arm and the
# mark until the outcall's own timeout. Needs #dev; BTC-ICPUSD; restores the
# stalls, the mark clock and the timer brake at exit.
#
# THE SUCCESSOR-FLEET READ HAZARD (task 1788549334, 2026-09-04): devGetFanout
# returns the asset's LATEST fan-out, and a GEPTOR fleet's own finalizer
# re-arms the next GEPTOR (ammRequote → processDeferred re-arms while entries
# stay staged), which dispatches a NEW fleet ~1s after the close
# (GEPTOR_DELAY_NS + a finaliser beat). A `fanout` poll that straddles that
# window sees the successor — open, arrived 0..4, ITS arm held — and the old
# wait read it as "the deadline sweep did not close the fan-out within 12s"
# (seen once on a busy seat venue right after test_market_walks_locked; the
# breaker was never involved — getHbHealth's "oraclefan" streak stayed 0 with
# dispatches == completions across every reproduction). The successor's OWN
# deadline close, 8s later under §5's stalls, then landed mid-§6 and rewrote
# lastAggregates with its 4 readings ("did not pick up the late reading —
# readings=4"). So §4/§5 now (a) wait for the GEPTOR's OWN fleet (its
# dispatchNs IS the arm time — H-23), (b) BRAKE the venue (setTestTimersPaused)
# while it is in flight — the deadline sweep runs ABOVE the pause gate by
# design ("H-37 (F34): the oracle fan-out's deadline sweep — ABOVE the pause
# gate too", main.mo heartbeat), while the finaliser that would dispatch the
# successor is braked, so the watched fleet stays the asset's latest until
# the sweep closes it — and (c) accept supersession as proof of closure
# (processGeptorDue dedups on a live arm and the tick JOINS an open fleet, so
# a newer fleet exists only once the watched one finalized), then (d) resume
# and SETTLE (latest closed, no arm held) before the next section.
#
# THE TWO CLOCKS (task 1788556943, 2026-09-04): a GEPTOR fleet is pinned
# against two bounds with DIFFERENT referents, and the header names each.
#   DISPATCH-relative — the 8s deadline's own assertion: the sweep closes the
#   fleet ≤ fanoutDeadlineSec + 2s after its own dispatchNs (8s + a finaliser
#   beat + a poll; a fine sampler measured a steady 8.0s, task 1788549334).
#   Load-insensitive: nothing sits between the deadline and the sweep.
#   STAGING-relative — the STAGING WINDOW's assertion: the fleet closes and
#   the mark applies inside DEFERRED_EXPIRY_NS (15s, main.mo `transient let
#   DEFERRED_EXPIRY_NS`), the window H-37 protects — a staged entry that
#   misses it falls to the users-only pass. Between staging and dispatch sits
#   the GEPTOR's arm-and-dispatch chain (GEPTOR_DELAY_NS 1s → an HB_FINALISE_NS
#   0.5s beat → hbRunAsync("finalise") → processGeptorDue's own message):
#   1.5s nominal, up to ~3s with other seats deploying — eleven runs on a
#   loaded seat put the staging-relative close at 9, 10, 10, 10, 10, 11, 11,
#   12, 9, 10, 10 s (the 12 while three merges hit main in 40 min). The old
#   ≤ 12s bound had the DEADLINE as its referent ("8s + a beat + the arm
#   delay") and no headroom under load. The bound is now the window it
#   protects: DEFERRED_EXPIRY_NS − 2s = 13s, where 2s is the release beat
#   (the expiry is processed on the finaliser cadence) + this suite's 0.5s
#   poll + the CLI skew (EL counts from the placement call's RETURN, up to
#   ~1s after the canister stamped the entry). Both clocks are read from the
#   VENUE: getPriceFeedStats carries the deadline (fanoutDeadlineSec) and,
#   since task 1788558580, the window (stagingWindowSec = DEFERRED_EXPIRY_NS
#   in whole seconds) — so the bound follows the canister the suite actually
#   runs against, not the tree it runs from (the source grep it replaced
#   dropped silently to the default on a renamed constant, and pinned a
#   venue deployed from another tree against the wrong window). A pre-field
#   venue defaults to 15s, loudly.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_oracle_fanout_deadline" "devStallSource / devGetFanout / devReleaseParkedReadings (#dev hooks)"

e8()  { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
flat() { tr -d '_\n' | tr -s ' '; }
MKT="BTC-ICPUSD"; ASSET="BTC"
ALL_SOURCES="coinbase okx kucoin coingecko htx cryptocom binance kraken"

stats()   { adm getPriceFeedStats '()' --query | flat; }
statn()   { stats | grep -oE "$1 = [0-9]+" | head -1 | awk '{print $3}'; }
# The staging window (THE TWO CLOCKS, header): getPriceFeedStats.stagingWindowSec
# from the venue (task 1788558580 — DEFERRED_EXPIRY_NS in whole seconds),
# else 15s on a pre-field venue. The staging-relative bound is the window
# minus the 2s release-beat + poll + CLI-skew margin; the dispatch-relative
# bound is set in §1 from fanoutDeadlineSec the same way.
STAGING_WINDOW_S=15
VENUE_WIN=$(statn stagingWindowSec)
if [ -n "$VENUE_WIN" ] && [ "$VENUE_WIN" -ge 1 ] 2>/dev/null; then
  [ "$VENUE_WIN" = "$STAGING_WINDOW_S" ] || echo "  (note: getPriceFeedStats.stagingWindowSec = ${VENUE_WIN}s — the staging window is taken from the venue, not the default ${STAGING_WINDOW_S}s)"
  STAGING_WINDOW_S=$VENUE_WIN
else
  echo "  (note: getPriceFeedStats carries no stagingWindowSec — a pre-1788558580 venue; the staging window defaults to ${STAGING_WINDOW_S}s)"
fi
STAGING_BOUND_S=$(( STAGING_WINDOW_S - 2 ))
SWEEP_BOUND_S=10   # re-derived in §1 from fanoutDeadlineSec + 2
fanout()  { adm devGetFanout "(\"$ASSET\")" --query | flat; }
fo_field(){ printf '%s' "$1" | grep -oE "$2 = [0-9]+" | head -1 | awk '{print $3}'; }
fo_text() { printf '%s' "$1" | grep -oE "$2 = \"[a-z]+\"" | head -1 | sed 's/.*"\(.*\)"/\1/'; }
fo_open() { printf '%s' "$1" | grep -oE "open = (true|false)" | head -1 | awk '{print $3}'; }
refns()   { adm getAmmPool "(\"$MKT\")" | flat | grep -oE "refPriceUpdatedNs = [0-9-]+" | head -1 | awk '{print $3}'; }
guard()   { adm devGetGeptorInFlight "(\"$MKT\")" --query | tr -d '\n'; }
stall()   { adm devStallSource "(\"$1\", variant { $2 })" >/dev/null; }
clear_all(){ for s in $ALL_SOURCES; do stall "$s" clear; done; }
# Pin the mark AT the live aggregate and backdate its clock, so the next
# aggregate is inside the jump breaker and newer than the mark (every apply
# below is then deterministic — the seed's mark may sit >2.5% off the live
# price and pend).
pin_mark() {
  local px; px=$(adm getLastAggregate "(\"$ASSET\")" --query | flat | grep -oE "price = [0-9.]+" | head -1 | awk '{print $3}')
  [ -n "$px" ] || px=100000
  adm setTestPendingJump "(\"$ASSET\", null, null)" >/dev/null 2>&1
  adm setAmmRefPrice "(\"$MKT\", $(e8 "$px") : nat)" >/dev/null
  adm setTestRefPriceUpdatedNs "(\"$MKT\", $(( ($(date +%s) - 60) * 1000000000 )) : int)" >/dev/null
}
cleanup() {
  clear_all
  adm devReleaseParkedReadings '()' >/dev/null 2>&1
  adm setTestPendingJump "(\"$ASSET\", null, null)" >/dev/null 2>&1
  [ -n "${TRADER:-}" ] && icp canister call --candid "$MDX_CANDID" --identity fo_trader backend cancelAllMyOrders '()' >/dev/null 2>&1
}
on_exit cleanup   # via _lib (its EXIT trap also removes fo_trader)
# TIMER HYGIENE (as test_market_walks_locked): §4/§5 brake the venue while
# their GEPTOR fleet is in flight; a failure path that exits under the brake
# would strand the finaliser OFF for every later suite. Registered AFTER
# cleanup, so LIFO runs it first.
on_exit 'adm setTestTimersPaused "(false)" >/dev/null 2>&1'
brake_on()  { adm setTestTimersPaused '(true)'  >/dev/null; }
brake_off() { adm setTestTimersPaused '(false)' >/dev/null; }

# A GEPTOR arms on any staged order: a far-from-market SELL stages (never
# crosses) — the trader needs BTC to reserve.
mdx_identity_new fo_trader; TRADER=$(principal_of fo_trader)
adm setTestBalance "(principal \"$TRADER\", \"BTC\", $(e8 2.0) : nat)" >/dev/null
tr_place() { icp canister call --candid "$MDX_CANDID" --identity fo_trader backend placeLimitOrder "(\"$MKT\", variant { sell }, $(e8 "$1") : nat, $(e8 0.1) : nat)" 2>&1; }
# The guard's arm time (ns digits), or "" when null.
guard_ns() { local g; g=$(guard); case "$g" in *null*) echo "" ;; *) printf '%s' "$g" | tr -d '_' | grep -oE '[0-9]{15,}' | head -1 ;; esac; }
# Wait until the GEPTOR's OWN fleet for $MKT is the asset's latest: an id
# past $1, dispatched on or after the staging clock $3 (2s of skew allowed),
# and either IN FLIGHT with dispatchNs equal to the held arm (H-23: the arm
# time IS the dispatch clock — a tick fleet that happened first has a
# different clock) or ALREADY CLOSED (a quorum fleet lands in a beat or two
# and releases its arm before a poll can see it held). Sets WATCHED (that
# fleet's view) and DNS; called as a STATEMENT.
WATCHED=""; EL=""; DNS=""
wait_geptor_dispatched() {
  local after="$1" limit="$2" t0="$3" floor fv g d
  floor=$(( (t0 - 2) * 1000000000 ))
  while :; do
    fv=$(fanout); g=$(guard_ns); d=$(fo_field "$fv" dispatchNs)
    if [ "$(fo_field "$fv" id)" -gt "$after" ] 2>/dev/null && [ "${d:-0}" -ge "$floor" ] 2>/dev/null \
       && { [ "$g" = "$d" ] || [ "$(fo_open "$fv")" = "false" ]; }; then WATCHED="$fv"; DNS="$d"; return 0; fi
    [ $(( $(date +%s) - t0 )) -ge "$limit" ] && { WATCHED="$fv"; DNS="$d"; return 1; }
    sleep 0.5
  done
}
# Wait until the watched fleet (id $1) is CLOSED — or SUPERSEDED by a newer
# fleet for the asset, which proves the same thing (the successor-fleet
# hazard, header): processGeptorDue dedups on a live arm and the tick joins
# an open fleet, so a newer id exists only once the watched one finalized.
# EL counts from $3 (the staging epoch) so the bound stays "since staging";
# the limit is measured from the same clock. Leaves the closed view in
# $WATCHED when it was observed directly, "" when only the successor was
# (the caller then falls back to the census), and the host second the close
# was observed in CLOSED_AT. Called as a STATEMENT.
CLOSED_AT=""
wait_fanout_closed() {
  local watched="$1" limit="$2" t0="$3" fv id
  while :; do
    fv=$(fanout); id=$(fo_field "$fv" id)
    if [ "$id" = "$watched" ] && [ "$(fo_open "$fv")" = "false" ]; then WATCHED="$fv"; CLOSED_AT=$(date +%s); EL=$(( CLOSED_AT - t0 )); return 0; fi
    if [ "${id:-0}" -gt "$watched" ] 2>/dev/null; then WATCHED=""; EL=$(( $(date +%s) - t0 )); return 0; fi
    [ $(( $(date +%s) - t0 )) -ge "$limit" ] && { WATCHED="$fv"; EL=timeout; return 1; }
    sleep 0.5
  done
}
# Quiesce before the next section: the asset's latest fleet closed and no
# GEPTOR arm held for $MKT (a successor re-armed under the brake fires
# ~1.5s after the resume and, with every source live again, closes on
# quorum within a beat or two). Bounded; never asserts.
settle_fleets() {
  local limit="$1" t0; t0=$(date +%s)
  while :; do
    if [ "$(fo_open "$(fanout)")" = "false" ] && [ -z "$(guard_ns)" ]; then return 0; fi
    [ $(( $(date +%s) - t0 )) -ge "$limit" ] && return 1
    sleep 1
  done
}
# The arm that dispatched the watched fan-out is released iff the guard no
# longer holds ITS arm time (null, or a newer arm — the GEPTOR's own dedup).
arm_released() { [ "$(guard_ns)" != "$1" ]; }

clear_all
# Self-bootstrap on a wiped venue (an earlier oracle suite's resetExchange
# leaves only ICP-ICPUSD): the fan-out applies into an AMM pool, so create
# BTC's if it is gone — the first fetch below stamps its mark from the live
# fleet (refPrice 0 accepts any first sample). Left DISABLED, deliberately:
# the GEPTOR and admin paths this suite drives apply into a disabled pool
# fine, while an enabled, feed-tracked pool with no liquidity would outlive
# the suite and have the periodic tick PEND every later fixture's synthetic
# BTC stamp (seen live: test_play_deposit_cap's "mark held pending a
# price-jump confirmation" after a run-order wipe). A fixture that needs the
# pool live creates it as it always did.
if ! adm getAmmPool "(\"$MKT\")" 2>&1 | grep -q 'refPrice'; then
  adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
  adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null 2>&1
  echo "  (bootstrapped $MKT on a wiped venue — disabled, mark from the live fleet)"
fi
echo "── §1 the fan-out shape on getPriceFeedStats ──"
S=$(stats)
if echo "$S" | grep -qE "fanoutSources = 8 : nat"; then ok "fanoutSources = 8"; else nok "fanoutSources missing/not 8 (pre-H-37 record)" "$(echo "$S" | head -c 200)"; fi
if echo "$S" | grep -qE "fanoutQuorum = 5 : nat"; then ok "fanoutQuorum = 5 (a majority of 8, never below minSources 3)"; else nok "fanoutQuorum missing/not 5" "$(echo "$S" | grep -oE 'fanoutQuorum = [0-9]+')"; fi
if echo "$S" | grep -qE "fanoutDeadlineSec = 8 : nat"; then ok "fanoutDeadlineSec = 8 (well under the ${STAGING_WINDOW_S}s staging window)"; else nok "fanoutDeadlineSec missing/not 8" "$(echo "$S" | grep -oE 'fanoutDeadlineSec = [0-9]+')"; fi
if echo "$S" | grep -qE "stagingWindowSec = 15 : nat"; then ok "stagingWindowSec = 15 (DEFERRED_EXPIRY_NS in whole seconds — the window the deadline protects, read from the venue)"; else nok "stagingWindowSec missing/not 15 (pre-1788558580 record, or DEFERRED_EXPIRY_NS moved)" "$(echo "$S" | grep -oE 'stagingWindowSec = [0-9]+')"; fi
DEADLINE_S=$(printf '%s' "$S" | grep -oE 'fanoutDeadlineSec = [0-9]+' | head -1 | awk '{print $3}'); DEADLINE_S=${DEADLINE_S:-8}
SWEEP_BOUND_S=$(( DEADLINE_S + 2 ))
# The design invariant in numbers: the deadline plus the arm-and-dispatch
# chain's loaded worst case (~3s) still lands inside the staging bound.
if [ $(( DEADLINE_S + 3 )) -le "$STAGING_BOUND_S" ]; then ok "deadline ${DEADLINE_S}s + a ~3s arm-and-dispatch chain fits the staging bound ${STAGING_BOUND_S}s (DEFERRED_EXPIRY_NS ${STAGING_WINDOW_S}s − 2s)"; else nok "the deadline leaves no room for the GEPTOR's arm chain inside the staging window" "deadline=$DEADLINE_S window=$STAGING_WINDOW_S bound=$STAGING_BOUND_S"; fi

echo "── §2 baseline: a full fleet finalizes on quorum or completion ──"
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null 2>&1   # warms lastAggregates for pin_mark
pin_mark
ID0=$(fo_field "$(fanout)" id); ID0=${ID0:-0}
T0=$(date +%s)
R=$(adm fetchAndSetRefPrice "(\"$MKT\")" | flat)
EL=$(( $(date +%s) - T0 ))
FV=$(fanout)
REASON=$(fo_text "$FV" reason); ARR=$(fo_field "$FV" arrived); ID1=$(fo_field "$FV" id)
if mdx_ok "$R"; then ok "admin fetch applied (${EL}s): $(echo "$R" | head -c 60)"; else nok "admin fetch did not apply" "$(echo "$R" | head -c 160)"; fi
case "$REASON" in quorum|complete|drained) ok "fan-out #$ID1 finalized by '$REASON' with $ARR arrivals" ;; *) nok "fan-out not finalized by quorum/complete/drained" "reason=$REASON view=$(echo "$FV" | head -c 200)" ;; esac
if [ "${ARR:-0}" -ge 5 ] 2>/dev/null; then ok "at least the quorum arrived ($ARR)"; else nok "fewer arrivals than the quorum" "arrived=$ARR"; fi
if [ "$(fo_open "$FV")" = "false" ]; then ok "the fan-out is closed"; else nok "fan-out still open after the admin fetch returned" "$FV"; fi

echo "── §3 ONE source never answers: the mark still advances, within the deadline ──"
stall kraken never
pin_mark
N0=$(refns)
T0=$(date +%s)
R=$(adm fetchAndSetRefPrice "(\"$MKT\")" | flat)
EL=$(( $(date +%s) - T0 ))
N1=$(refns)
FV=$(fanout); REASON=$(fo_text "$FV" reason); ARR=$(fo_field "$FV" arrived); ID2=$(fo_field "$FV" id)
if mdx_ok "$R"; then ok "the mark applied with kraken stalled (${EL}s)"; else nok "the stalled source blocked the apply" "$(echo "$R" | head -c 160)"; fi
if [ -n "$N1" ] && [ "$N1" -gt "${N0:-0}" ] 2>/dev/null; then ok "refPriceUpdatedNs advanced ($N0 → $N1)"; else nok "the mark's clock did not move" "before=$N0 after=$N1"; fi
if [ "$ARR" = "7" ]; then ok "7 arrivals — the stalled source recorded nothing"; else nok "expected 7 arrivals" "arrived=$ARR view=$(echo "$FV" | head -c 200)"; fi
case "$REASON" in quorum|drained) ok "finalized by '$REASON', not by the missing source" ;; *) nok "expected quorum or drained" "reason=$REASON" ;; esac
if [ "$EL" -le 8 ]; then ok "the admin fetch returned in ${EL}s (≤ the 8s deadline — it never waited for the stall)"; else nok "the admin fetch took ${EL}s" "the stall delayed it"; fi

echo "── §4 the GEPTOR path under the stall: arm released and mark advanced within the staging window ──"
pin_mark
N0=$(refns)
IDB=$(fo_field "$(fanout)" id)
G0=$(guard)
T0=$(date +%s)
R=$(tr_place 300000)
T1=$(date +%s)   # staged (the call returned) — the clock every bound below counts from
if mdx_ok "$R"; then ok "far sell staged (arms a GEPTOR for $MKT)"; else nok "order should stage" "$(echo "$R" | head -c 120)"; fi
# Brake once the GEPTOR's own fleet is out (header: the successor-fleet
# hazard). Its market is read from the view seen at detection — the closed
# one may be superseded by the time the quorum lands.
wait_geptor_dispatched "$IDB" 8 "$T1" || nok "no GEPTOR fleet for $MKT within 8s of staging" "view=$(echo "$WATCHED" | head -c 200) guard=$(guard)"
OPENV="$WATCHED"; WID=$(fo_field "$OPENV" id); WID=${WID:-0}
brake_on
wait_fanout_closed "$WID" $(( STAGING_BOUND_S + 3 )) "$T1"
FV="$WATCHED"; REASON=$(fo_text "$FV" reason); ARR=$(fo_field "$FV" arrived)
if [ "$EL" != "timeout" ] && [ "$EL" -le "$STAGING_BOUND_S" ]; then ok "the GEPTOR's fan-out #$WID closed ${EL}s after staging — inside the ${STAGING_WINDOW_S}s staging window (bound ${STAGING_BOUND_S}s; $([ -n "$FV" ] && echo "reason '$REASON', $ARR arrivals" || echo "superseded by a newer fleet — closed by construction"))"; else nok "the GEPTOR's fan-out did not close inside the staging window (bound ${STAGING_BOUND_S}s = DEFERRED_EXPIRY_NS ${STAGING_WINDOW_S}s − 2s)" "elapsed=$EL view=$(echo "$FV" | head -c 200)"; fi
if echo "$OPENV" | grep -q "\"$MKT\""; then ok "the fan-out carries $MKT (the GEPTOR attached its market)"; else nok "market not attached" "$OPENV"; fi
if arm_released "$DNS"; then ok "the GEPTOR arm that dispatched it released at finalization"; else nok "the arm is still held" "guard=$(guard) armedAt=$DNS"; fi
N1=$(refns)
if [ -n "$N1" ] && [ "$N1" -gt "${N0:-0}" ] 2>/dev/null; then ok "the market's mark advanced on the GEPTOR fan-out ($N0 → $N1) — the staged entry can release"; else nok "the mark did not move on the GEPTOR fan-out" "before=$N0 after=$N1 outcomes=$(echo "$FV" | grep -oE 'outcomes = vec \{.{0,160}')"; fi
icp canister call --candid "$MDX_CANDID" --identity fo_trader backend cancelAllMyOrders '()' >/dev/null 2>&1
brake_off
settle_fleets 10 || echo "  (warn: $ASSET fleets did not settle within 10s — guard=$(guard))"

echo "── §5 the DEADLINE path: four sources never answer (4 < quorum 5) ──"
for s in kraken htx cryptocom kucoin; do stall "$s" never; done
pin_mark
D0=$(statn fanoutDeadlineCount); D0=${D0:-0}
T0=$(date +%s)
R=$(adm fetchAndSetRefPrice "(\"$MKT\")" | flat)
EL=$(( $(date +%s) - T0 ))
FV=$(fanout); REASON=$(fo_text "$FV" reason); ARR=$(fo_field "$FV" arrived)
if mdx_ok "$R"; then ok "the admin fetch applied on 4 arrivals (${EL}s; ≥ the floor 3)"; else nok "the admin fetch did not apply on 4 sources" "$(echo "$R" | head -c 160)"; fi
if [ "$REASON" = "drained" ] && [ "$ARR" = "4" ]; then ok "the admin fleet DRAINED at 4 arrivals (no quorum, no completion — its own awaits are its deadline)"; else nok "expected drained/4" "reason=$REASON arrived=$ARR"; fi
# Now the heartbeat-driven path: a GEPTOR fan-out with 4 live sources can
# reach neither quorum nor completion — only the deadline sweep closes it.
pin_mark
N0=$(refns)
IDB=$(fo_field "$(fanout)" id)
T0=$(date +%s)
R=$(tr_place 310000)
T1=$(date +%s)   # staged (the call returned)
if mdx_ok "$R"; then ok "far sell staged (arms a GEPTOR)"; else nok "order should stage" "$(echo "$R" | head -c 120)"; fi
# Brake once the GEPTOR's own fleet is out: 4 arrivals can reach neither
# quorum nor completion, so nothing but the heartbeat's deadline sweep (above
# the pause gate) closes it — and under the brake no successor fleet can
# supersede it before the sweep, so the deadline view is read DIRECTLY.
wait_geptor_dispatched "$IDB" 8 "$T1" || nok "no GEPTOR fleet for $MKT within 8s of staging" "view=$(echo "$WATCHED" | head -c 200) guard=$(guard)"
WID=$(fo_field "$WATCHED" id); WID=${WID:-0}
brake_on
wait_fanout_closed "$WID" $(( STAGING_BOUND_S + 3 )) "$T1"
FV="$WATCHED"; REASON=$(fo_text "$FV" reason); ARR=$(fo_field "$FV" arrived)
# The STAGING window's assertion (THE TWO CLOCKS, header): the staged entry
# expires DEFERRED_EXPIRY_NS after staging, so the sweep's close — deadline
# plus the GEPTOR's arm-and-dispatch chain — must land inside it.
if [ "$EL" != "timeout" ] && [ "$EL" -le "$STAGING_BOUND_S" ]; then ok "the GEPTOR's fan-out #$WID closed ${EL}s after staging — inside the ${STAGING_WINDOW_S}s staging window (bound ${STAGING_BOUND_S}s = DEFERRED_EXPIRY_NS − 2s; the deadline + the arm-and-dispatch chain)"; else nok "the deadline sweep did not close the fan-out inside the staging window (bound ${STAGING_BOUND_S}s = DEFERRED_EXPIRY_NS ${STAGING_WINDOW_S}s − 2s)" "elapsed=$EL view=$(echo "$FV" | head -c 200)"; fi
# The DEADLINE's own assertion, measured from the fleet's OWN dispatch clock
# (the staging-relative bound above also carries the arm-and-dispatch chain
# — ~1.5s, up to ~3s on a loaded machine — and is what moves under load;
# this one does not: measured 8.0s dispatch → close with the fine sampler,
# task 1788549334). Integer seconds, so ≤ fanoutDeadlineSec + 2 is 8s + a
# beat + a poll.
if [ "$EL" != "timeout" ] && [ -n "$DNS" ]; then
  SW=$(( CLOSED_AT - DNS / 1000000000 ))
  if [ "$SW" -le "$SWEEP_BOUND_S" ]; then ok "the heartbeat sweep closed it ${SW}s after its dispatch (≤ ${SWEEP_BOUND_S}s: PRICE_FANOUT_DEADLINE_NS ${DEADLINE_S}s + a beat + a poll)"; else nok "the sweep closed it ${SW}s after dispatch (> the ${DEADLINE_S}s deadline + a beat + a poll)" "dispatchNs=$DNS closedAt=$CLOSED_AT"; fi
  echo "  (timings, host integer seconds: staging → dispatch $(( DNS / 1000000000 - T1 ))s, dispatch → close ${SW}s, staging → close ${EL}s)"
fi
if [ "$REASON" = "deadline" ] && [ "$ARR" = "4" ]; then ok "finalized by the DEADLINE on 4 arrivals"; else nok "expected deadline/4 (under the brake the watched fleet cannot be superseded)" "reason=$REASON arrived=$ARR view=$(echo "$FV" | head -c 200)"; fi
D1=$(statn fanoutDeadlineCount)
if [ -n "$D1" ] && [ "$D1" -gt "$D0" ] 2>/dev/null; then ok "fanoutDeadlineCount advanced ($D0 → $D1)"; else nok "fanoutDeadlineCount did not move" "before=$D0 after=$D1"; fi
if arm_released "$DNS"; then ok "the GEPTOR arm that dispatched it released by the deadline finalization"; else nok "the arm is still held after the deadline" "guard=$(guard) armedAt=$DNS"; fi
N1=$(refns)
if [ -n "$N1" ] && [ "$N1" -gt "${N0:-0}" ] 2>/dev/null; then ok "the mark advanced on the deadline sample ($N0 → $N1) — inside the 15s staging window"; else nok "the deadline finalization did not move the mark" "before=$N0 after=$N1 outcomes=$(echo "$FV" | grep -oE 'outcomes = vec \{.{0,160}')"; fi
icp canister call --candid "$MDX_CANDID" --identity fo_trader backend cancelAllMyOrders '()' >/dev/null 2>&1
# Clear the stalls BEFORE the resume: a successor re-armed under the brake
# then fires against a whole fleet and closes on quorum in a beat — instead
# of closing on the DEADLINE 8s later, mid-§6, and rewriting the cached
# aggregate with 4 readings (seen live).
clear_all
brake_off
settle_fleets 10 || echo "  (warn: $ASSET fleets did not settle within 10s — guard=$(guard))"

echo "── §6 a source that answers LATE attaches, and never re-applies ──"
stall kraken park
pin_mark
L0=$(statn fanoutLateReadings); L0=${L0:-0}
R=$(adm fetchAndSetRefPrice "(\"$MKT\")" | flat)
N1=$(refns)
FV=$(fanout); ARR=$(fo_field "$FV" arrived); IDP=$(fo_field "$FV" id); LP=$(fo_field "$FV" late)
if mdx_ok "$R" && [ "$ARR" = "7" ]; then ok "applied on 7 arrivals with kraken parked (late so far: $LP — live arrivals after a quorum close count too)"; else nok "expected an apply on 7" "arrived=$ARR r=$(echo "$R" | head -c 120)"; fi
REL=$(adm devReleaseParkedReadings '()' | grep -oE '[0-9]+' | head -1)
# ≥ 1: every fleet dispatched while kraken was parked (the venue's own GEPTOR
# and tick fan-outs included) parked its kraken reading too.
if [ -n "$REL" ] && [ "$REL" -ge 1 ] 2>/dev/null; then ok "devReleaseParkedReadings landed the parked reading(s) ($REL)"; else nok "expected ≥ 1 parked reading" "released=$REL"; fi
FV=$(fanout)
if [ "$(fo_field "$FV" id)" = "$IDP" ] && [ "$(fo_field "$FV" late)" = "$(( LP + 1 ))" ] && [ "$(fo_field "$FV" arrived)" = "8" ]; then ok "the parked reading ATTACHED to fan-out #$IDP (late $LP → $(( LP + 1 )), arrivals 8)"; else nok "late attach not recorded" "$(echo "$FV" | head -c 200)"; fi
N2=$(refns)
if [ "$N2" = "$N1" ]; then ok "the mark's clock did not move on the late arrival ($N1) — attached, not applied"; else nok "a late reading re-applied the mark" "before=$N1 after=$N2"; fi
L1=$(statn fanoutLateReadings)
if [ -n "$L1" ] && [ "$L1" -gt "$L0" ] 2>/dev/null; then ok "fanoutLateReadings advanced ($L0 → $L1)"; else nok "fanoutLateReadings did not move" "before=$L0 after=$L1"; fi
AGG_N=$(adm getLastAggregate "(\"$ASSET\")" --query | grep -c 'sourceId =' || true)
if [ "${AGG_N:-0}" -ge 8 ]; then ok "getLastAggregate now carries all 8 readings (observability refreshed)"; else nok "the cached aggregate did not pick up the late reading" "readings=$AGG_N"; fi

echo "── §7 stalls cleared: the next fleet is whole again ──"
clear_all
pin_mark
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null 2>&1
FV=$(fanout); ARR=$(fo_field "$FV" arrived); REASON=$(fo_text "$FV" reason)
if [ "$ARR" = "8" ]; then ok "8 arrivals with no stalls (reason '$REASON')"; else nok "expected 8 arrivals after clearing" "arrived=$ARR reason=$REASON"; fi
A=$(statn fanoutAbandoned)
echo "  (census: quorum $(statn fanoutQuorumCount), complete $(statn fanoutCompleteCount), deadline $(statn fanoutDeadlineCount), drained $(statn fanoutDrainedCount), late $(statn fanoutLateReadings), abandoned ${A:-?})"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_oracle_fanout_deadline ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_oracle_fanout_deadline ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
