#!/bin/bash
# Layered archive-failure handling (docs/amm-vault-design.md — July-2026
# archive-backlog incident). A wedged archive must never let the in-memory ship
# queue grow unbounded and starve trading. Two layers, driven deterministically
# via the dev hooks setTestShipFailover (force ship failures + tiny thresholds)
# and adminForceShipTick (one synchronous ship tick):
#
#   A  baseline: events ship, the sidecar spawns, the queue drains.
#   B  L1 — after N consecutive ship FAILURES, seal the wedged archive and roll
#          to a fresh successor (emergencyRolls climbs, a sealed archive appears);
#          NO data loss.
#   C  L2 — a sustained failure past the hard cap DROPS oldest events to bound
#          the heap (shedEvents climbs, a ledger gap is recorded) and immediately
#          RE-BASELINES the tape: one absolute re-attestation row per live ledger
#          entry (balances/debt/LP/insurance), so the queue lands at exactly
#          shedTo + baselineWidth and the gap stays replayable.
#   D  recovery: clear the failure → the queue (incl. the baseline) drains onto a
#          fresh archive, the gap is closed + queryable, the baseline sits after
#          the gap, and the active archive's chain verifies.
#   E  the point of it all: adminReplay folds the tape ACROSS the gap (hop the
#          dropped range, reset at the baseline) and must reproduce every live
#          balance with ZERO mismatches on all four ledgers.
#   F  L3 shear (#52.2, H-32) — the absolute ceiling above L2: internal
#          emitters are not admission-throttled, so a queue can pass the L2 cap
#          while the shipper reads healthy and the both-conditions gate stays
#          cold. Above shipShearCap the shed fires with failStreak 0 — but only
#          under MEMORY PRESSURE (H-32: size alone with heap room is drained,
#          not sheared; the pin is setTestShipFailover's 7th arg), with the same
#          gap-ledger + re-anchor semantics; at hardCap alone with a healthy
#          shipper L2 still does NOT fire (both-conditions unchanged).
#   G  back-to-back sheds with nothing acked (#55.4): ONE list jump, the chain
#          declares [a..b) then the COALESCED [a..c) — the verifier accepts.
#   H  a THIRD shed whose drop passes the earlier #gap events (1788469743):
#          the one surviving declaration must span the whole outage [a..d),
#          else no verifier can ever justify the honest list jump again.
#   I  the season boundary PRESERVES the closed season's gap tuples + shed
#          re-baselines (1788474114): resetSeason over the §C..§H tape, then
#          getSeasonGaps(N) / getSeasonShedBaselines(N) equal the pre-reset
#          live pair (which is now empty), and `verify_ledger.mjs --season N
#          --fold` resets its fold at the preserved baselines — "healed by",
#          no "not preserved" warning.
#
# Timers stay PAUSED; shipping is stepped by hand so the sequence is exact.
# ⚠️ Calls resetExchange AND resetSeason (wallets zero, a SeasonRecord is
# appended). Needs a #dev backend.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
info() { adm getCanisterInfo '()' --query | tr -d '_'; }
field() { echo "$1" | grep -oE "$2 = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
mdx_identity_new afo_wd; WD=$(principal_of afo_wd)

# The sim must be dead (header: it would inject noise into the assertions).
# Stop it via the PID-file stopper — NEVER a pattern kill: `pkill -f` cannot
# tell a local simulator from one driving multidex.ai and took the live fleet
# down three times (run_all.sh's stopper comment + scripts/lib/bots.sh).
# run_all.sh already stops the fleet for suite runs; this covers standalone.
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
if [ -f "$STOPPER" ]; then
  bash "$STOPPER" >/dev/null 2>&1 || true
  sleep 2
else
  echo "⚠ stop_bots_local.sh not found at $STOPPER — the local fleet was NOT stopped."
  echo "  Red results below may be simulator noise rather than regressions."
fi
adm setTestTimersPaused '(true)' >/dev/null 2>&1     # step shipping by hand
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestShipFailover "(false, null, null, null, null, null, null)" >/dev/null 2>&1  # clean slate
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 1_000_000_000_000_000 : nat)" >/dev/null

# Emit N withdrawal events (each → 1 semantic UserEvent straight into the ship
# queue; timers paused, so no #delta drain muddies the count). 10 ICPUSD
# each — GENUINE exits: since H-32 a DUST exit (< 10 ICPUSD) repeated inside
# one principal's 30 s window is coalesced into one row at the window's end
# (test_exit_coalesce.sh), which is exactly the burst shape this emitter
# used to be; the wallet above is sized for every emit in this file.
emit() { local n="$1" tag="$2" i=0; while [ $i -lt "$n" ]; do
  icp canister call --candid "$MDX_CANDID" --identity afo_wd backend withdraw "(\"ICPUSD\", 1_000_000_000 : nat, \"$tag-$i\")" >/dev/null 2>&1; i=$((i+1)); done; }
ship() { adm adminForceShipTick '()' >/dev/null 2>&1; }   # one synchronous ship tick

# ── S. The spawn slot is a busy guard (#55 "orphan slot overwritten") ──
# W4-16 records a spawn's principal the moment create_canister replies and
# reaps a never-installed orphan after 5 min. Before task 1788465033 no spawn
# site CHECKED the record and the reconciler cleared it UNCONDITIONALLY, so a
# second spawn (a wipe zeroing the cooldown mid-install) overwrote it — a
# funded canister main controls, listed nowhere. Now: a held slot refuses
# every spawn (logged once per occupant, no failure cooldown), the reconciler
# clears only the record it read, and getCanisterInfo lists the slot.
# Driven by the dev hooks setTestSpawnOrphan (a REAL never-installed canister
# in the slot), setTestPendingSpawn (age/plant/clear) and the ops hook
# adminForceSpawnReconcile (the heartbeat ALSO runs the reconciler once a
# minute — setTestTimersPaused does not gate it, so a sibling reconcile can
# land mid-section; every assertion below holds under that too).
echo "── S. spawn slot: a held slot refuses the spawn; the reconciler reaps only what it read ──"
# (icp wraps the record across lines — flatten before matching)
pending() { info | tr -d '\n' | tr -s ' ' | grep -oE 'pendingSpawn = opt record \{ cid = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"'; }
events() { adm getRecentEvents "($1 : nat)" --query 2>/dev/null | tr -d '\n'; }
ORPHAN=$(adm setTestSpawnOrphan '(0 : nat)' | grep -oE 'principal "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
if [ -n "$ORPHAN" ] && [ "$(pending)" = "$ORPHAN" ]; then ok "manufactured orphan $ORPHAN sits in the spawn slot (getCanisterInfo.pendingSpawn lists it)"
else nok "could not manufacture an orphan" "orphan=${ORPHAN:-none} pending=$(pending)"; fi
if adm setTestSpawnOrphan '(0 : nat)' | grep -qF 'spawn slot occupied'; then ok "the hook itself is refused while the slot is held"
else nok "a second orphan was manufactured over the first" "pending=$(pending)"; fi
emit 1 slot
ship; sleep 1
if ! info | grep -q 'archiveCanisterId = opt'; then ok "first-event spawn refused: no sidecar was spawned while the slot is held"
else nok "a spawn ran over the held slot" "active=$(active_archive)"; fi
if [ "$(pending)" = "$ORPHAN" ]; then ok "the slot record survived the refused tick (not overwritten)"
else nok "the slot record changed" "pending=$(pending)"; fi
if events 80 | grep -qF "ARCHIVE SPAWN (initial): refused — slot occupied by $ORPHAN"; then ok "the refusal is logged with the occupant's principal"
else nok "no refusal log line" "$(events 80 | grep -oE 'ARCHIVE SPAWN[^;]{0,90}' | head -2)"; fi
ship; sleep 1
N_REF=$(adm getRecentEvents '(80 : nat)' --query 2>/dev/null | grep -cF 'refused — slot occupied')
if [ "${N_REF:-0}" = "1" ]; then ok "a second refused tick adds no second line (one warn per occupant, not per tick)"
else nok "refusal log is per-tick" "lines=$N_REF"; fi
adm adminForceSpawnReconcile '()' >/dev/null 2>&1
if [ "$(pending)" = "$ORPHAN" ]; then ok "the reconciler leaves a record younger than its 5-min gate alone"
else nok "the reconciler reaped a fresh record" "pending=$(pending)"; fi
# Age it past the gate: the reconciler stops, deletes, and clears exactly it.
adm setTestPendingSpawn "(opt principal \"$ORPHAN\", 400 : nat)" >/dev/null
adm adminForceSpawnReconcile '()' >/dev/null 2>&1
if [ -z "$(pending)" ] && events 80 | grep -qF "SPAWN RECONCILER: orphaned archive spawn $ORPHAN"; then ok "aged past the gate, the reconciler reaped $ORPHAN and cleared the slot"
else nok "the reconciler did not reap the aged orphan" "pending=$(pending) log=$(events 80 | grep -oE 'SPAWN RECONCILER[^;]{0,100}' | head -2)"; fi
# The failed-cleanup path KEEPS the record (by-hand recovery needs it): a
# principal we do not control cannot be stopped, so the catch must not clear.
adm setTestPendingSpawn '(opt principal "aaaaa-aa", 400 : nat)' >/dev/null
adm adminForceSpawnReconcile '()' >/dev/null 2>&1
if [ "$(pending)" = "aaaaa-aa" ] && events 80 | grep -qF "SPAWN RECONCILER: cleanup of aaaaa-aa failed"; then ok "a cleanup the IC refuses keeps the record and logs the cause"
else nok "failed cleanup did not keep the record" "pending=$(pending)"; fi
# The interleave itself (task 1788485539): a record REPLACED during the
# reconciler's stop/delete awaits must survive its clear. The dev hold
# setTestSpawnReconcileHold parks the reconciler between the two awaits and
# reports whether one is parked, so the swap lands inside the window by
# PROTOCOL, not by timing: arm; start the reconcile (background, its only
# output is `()`); re-arm as a PROBE until it reads true (the reconciler has
# read A, its stop await has returned, and it is yielding in the hold — the
# hold ends only on release or at its runaway cap); swap the record to B;
# release; join. Every call here is an ingress update, so nothing depends on
# query availability while the reconciler yields — but confirmation IS slow
# while it yields (measured 5-25s per call with timers paused, 75-140s with
# the heartbeat live), which is why the arm is 20k rounds (~7 min at ~22ms)
# against a 30k cap: the window must dwarf the calls inside it, and a 6k
# (~2 min) arm expired under the swap on a live-heartbeat venue. The elapsed
# time is printed so a creeping venue shows before it flakes. A heartbeat sibling that
# enters meanwhile returns at the single-flight latch (task 1788507866, the
# block after this one) — before the latch it read A too, parked alongside,
# and its later delete of an already-deleted A failed into the
# keep-the-record catch — so B survives and A is named in every
# interleaving. Under the pre-1788465033 unconditional clear, B would be
# wiped by the reconciler that read A.
adm setTestPendingSpawn '(null, 0 : nat)' >/dev/null
A_ORPH=$(adm setTestSpawnOrphan '(400 : nat)' | grep -oE 'principal "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
if [ -n "$A_ORPH" ] && [ "$(pending)" = "$A_ORPH" ]; then ok "interleave: orphan A=$A_ORPH planted aged past the gate"
else nok "interleave: could not plant A" "a=${A_ORPH:-none} pending=$(pending)"; fi
adm setTestSpawnReconcileHold '(20000 : nat)' >/dev/null     # arm: park between stop and delete (~7 min runaway; released below)
IL_T0=$(date +%s)
adm adminForceSpawnReconcile '()' >/dev/null 2>&1 &
REC_PID=$!
PARKED=0; PROBES=0
while [ "$PROBES" -lt 60 ]; do
  PROBES=$((PROBES+1))
  if adm setTestSpawnReconcileHold '(20000 : nat)' | grep -q 'true'; then PARKED=1; break; fi
  sleep 0.5
done
if [ "$PARKED" = "1" ]; then ok "interleave: the reconciler is parked in the hold after $PROBES probe(s) (A read, stop returned, delete not yet sent)"
else nok "interleave: the reconciler never parked (hold not reached in $PROBES probes)" "pending=$(pending)"; fi
SWAP_REPLY=$(adm setTestPendingSpawn '(opt principal "aaaaa-aa", 400 : nat)' | tr -d '\n')
RELEASED=$(adm setTestSpawnReconcileHold '(0 : nat)' | tr -d '\n')   # release; the reconciler deletes A and reaches its clear
wait "$REC_PID" 2>/dev/null || true
IL_T1=$(date +%s)
if echo "$SWAP_REPLY" | grep -qF 'variant { ok }' && echo "$RELEASED" | grep -qF 'true'; then ok "interleave: the swap to B=aaaaa-aa landed while the reconciler was still parked (release observed parked=true; $((IL_T1-IL_T0))s start→join)"
else nok "interleave: the window closed before the swap/release" "swap=$(echo "$SWAP_REPLY" | head -c 80) release=$(echo "$RELEASED" | head -c 40)"; fi
if [ "$(pending)" = "aaaaa-aa" ]; then ok "interleave: B survived the reconciler's clear (compare-and-clear saw A ≠ B and kept B)"
else nok "interleave: the reconciler's clear wiped B — a record replaced mid-await was lost" "pending=$(pending)"; fi
if events 80 | grep -qF "SPAWN RECONCILER: orphaned archive spawn $A_ORPH"; then ok "interleave: the reconciler's log names A ($A_ORPH), the record it read"
else nok "interleave: no reconciler log line naming A" "$(events 80 | grep -oE 'SPAWN RECONCILER[^;]{0,100}' | head -3)"; fi
UNPARKED=0; for _i in 1 2 3 4 5 6; do   # a sibling released by the same 0 leaves within a round or two
  if adm setTestSpawnReconcileHold '(0 : nat)' | grep -q 'false'; then UNPARKED=1; break; fi; sleep 0.5; done
if [ "$UNPARKED" = "1" ]; then ok "interleave: no reconciler is parked after release (the count returns to zero with the hold)"
else nok "interleave: parked count stuck after release" "$(adm setTestSpawnReconcileHold '(0 : nat)' | tr -d '\n')"; fi
# Single-flight (task 1788507866): the heartbeat's once-a-minute reconcile is
# NOT gated by setTestTimersPaused, so a second reconciler could enter while
# the first sat in its stop/delete awaits (an adminForceSpawnReconcile landing
# during a heartbeat reconcile, or vice versa). It read the SAME orphan,
# stopped it again (harmless), and its delete failed "not found" after the
# first's delete — into the keep-the-record catch, which logged a
# level-"error" "recover by hand" line for a canister that no longer existed
# (measured on a seat venue while building the interleave above: two
# "orphaned archive spawn X" lines, one "cleanup of X failed"). Now a
# transient latch (_spawnReconcileInFlight, raised before the first await,
# released in finally) makes the second entry return at once. Same protocol
# as the interleave: plant C aged, arm, background one reconcile, probe until
# parked, then start a SECOND reconcile while the first is parked and give it
# a bounded wait — latched, it returns within one ingress confirmation and
# the first is STILL parked after it; unlatched, it reads C too and parks
# alongside, so it cannot return before the release. The bound is DERIVED,
# not a constant (task 1788538177): a fixed 90s was an ingress-latency bet —
# at load average 19-21 (five seats + fleets) ONE update round-trip on this
# pocket-ic exceeded 90s and a CORRECT build redded (returned=0 waited=90s
# parked_after=true, the tape half green). Every parked-probe above is
# itself one ingress update issued while a reconciler yields, so the slowest
# probe IS this venue's ingress time right now, and the wait is
# max(90, 6 × that). Should even that expire, the second reconcile is joined
# BEFORE the release — a join the hold's runaway bounds by construction: a
# parked reconciler counts its OWN 20k rounds from the moment it parked
# (re-arming probes do not extend it), leaves at the cap, deletes C and
# clears, and an unlatched second follows it out — and the hold is re-probed.
# The first STILL parked means the second got out before the release: the
# latch held and the venue was merely slow — a loud ⊘ load-skip stands in
# for the timing assertion, and only when the tape half below passes. The
# first NO LONGER parked means the second left only with the hold's expiry
# — the unlatched signature — and the assertion stays RED. Release, join
# both, then count the tape: exactly ONE line names C and NO cleanup-failed
# line exists. Bounding the wait at all (not an unbounded join) is what
# keeps a regressed build from stalling the section for the hold's whole
# runaway on a quiet venue.
adm setTestPendingSpawn '(null, 0 : nat)' >/dev/null
C_ORPH=$(adm setTestSpawnOrphan '(400 : nat)' | grep -oE 'principal "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
if [ -n "$C_ORPH" ] && [ "$(pending)" = "$C_ORPH" ]; then ok "single-flight: orphan C=$C_ORPH planted aged past the gate"
else nok "single-flight: could not plant C" "c=${C_ORPH:-none} pending=$(pending)"; fi
adm setTestSpawnReconcileHold '(20000 : nat)' >/dev/null     # arm (released below)
SF_T0=$(date +%s)
adm adminForceSpawnReconcile '()' >/dev/null 2>&1 &
SF1_PID=$!
SF_PARKED=0; SF_PROBES=0; SF_INGRESS_S=0
while [ "$SF_PROBES" -lt 60 ]; do
  SF_PROBES=$((SF_PROBES+1))
  SF_PT0=$(date +%s)
  SF_PROBE=$(adm setTestSpawnReconcileHold '(20000 : nat)' | tr -d '\n')
  SF_PT=$(( $(date +%s) - SF_PT0 ))
  [ "$SF_PT" -gt "$SF_INGRESS_S" ] && SF_INGRESS_S=$SF_PT   # the slowest probe = the venue's ingress time under this load
  if echo "$SF_PROBE" | grep -qF 'true'; then SF_PARKED=1; break; fi
  sleep 0.5
done
if [ "$SF_PARKED" = "1" ]; then ok "single-flight: the first reconciler is parked in the hold after $SF_PROBES probe(s) (C read, stop returned; slowest probe ${SF_INGRESS_S}s)"
else nok "single-flight: the first reconciler never parked (hold not reached in $SF_PROBES probes)" "pending=$(pending)"; fi
SF2_BOUND=$(( SF_INGRESS_S * 6 )); [ "$SF2_BOUND" -lt 90 ] && SF2_BOUND=90   # max(90, 6 × observed ingress)
adm adminForceSpawnReconcile '()' >/dev/null 2>&1 &          # the SECOND reconcile, while the first is parked
SF2_PID=$!
SF2_DONE=0; SF2_WAITS=0
while [ "$SF2_WAITS" -lt "$SF2_BOUND" ]; do   # a captured PID, never a pattern (mdex-process-safety §1)
  if ! kill -0 "$SF2_PID" 2>/dev/null; then SF2_DONE=1; break; fi
  SF2_WAITS=$((SF2_WAITS+1)); sleep 1
done
SF2_LATE_S=0
if [ "$SF2_DONE" != "1" ]; then   # bound expired: join it BEFORE the release (the parked first's own runaway bounds this)
  SF2_LT0=$(date +%s)
  wait "$SF2_PID" 2>/dev/null || true
  SF2_LATE_S=$(( $(date +%s) - SF2_LT0 ))
fi
SF_STILL=$(adm setTestSpawnReconcileHold '(20000 : nat)' | tr -d '\n')   # probe: is the first still parked?
SF2_VERDICT=red
if echo "$SF_STILL" | grep -qF 'true'; then
  if [ "$SF2_DONE" = "1" ]; then SF2_VERDICT=ok; ok "single-flight: the second reconcile returned at the latch in ${SF2_WAITS}s while the first was still parked (it did not join the hold; bound ${SF2_BOUND}s = max(90, 6 × ${SF_INGRESS_S}s ingress))"
  else SF2_VERDICT=load; fi   # past the bound yet before the release, first still parked: the latch held — decided at the tape below
fi
if [ "$SF2_VERDICT" = "red" ]; then nok "single-flight: the second reconcile did not return past a parked first" "returned=$SF2_DONE waited=$((SF2_WAITS+SF2_LATE_S))s bound=${SF2_BOUND}s ingress=${SF_INGRESS_S}s parked_after=$(echo "$SF_STILL" | head -c 40)"; fi
adm setTestSpawnReconcileHold '(0 : nat)' >/dev/null           # release; the parked reconciler deletes C and clears
wait "$SF1_PID" 2>/dev/null || true
wait "$SF2_PID" 2>/dev/null || true
SF_T1=$(date +%s)
SF_TAPE=$(adm getRecentEvents '(80 : nat)' --query 2>/dev/null)
N_ORPH_C=$(printf '%s\n' "$SF_TAPE" | grep -oF "SPAWN RECONCILER: orphaned archive spawn $C_ORPH" | wc -l | tr -d ' ')
N_FAIL_C=$(printf '%s\n' "$SF_TAPE" | grep -oF "SPAWN RECONCILER: cleanup of $C_ORPH failed" | wc -l | tr -d ' ')
if [ "$SF2_VERDICT" = "load" ]; then   # the residual: a slow venue, never a latch regression (the tape half must agree)
  if [ "${N_ORPH_C:-0}" = "1" ] && [ "${N_FAIL_C:-0}" = "0" ]; then skip_section "single-flight: load-skip — the second reconcile returned at the latch only after the ${SF2_BOUND}s bound (${SF2_WAITS}+${SF2_LATE_S}s; ingress ${SF_INGRESS_S}s/call, load average$(uptime | sed 's/.*load averages*://')) but BEFORE the release with the first still parked, and the tape half passes: the latch held, the venue was slow"
  else nok "single-flight: the second reconcile returned past the bound AND the tape disagrees with the latch" "waited=$((SF2_WAITS+SF2_LATE_S))s bound=${SF2_BOUND}s ingress=${SF_INGRESS_S}s orph_lines=${N_ORPH_C:-0} failed_lines=${N_FAIL_C:-0}"; fi
fi
if [ "${N_ORPH_C:-0}" = "1" ]; then ok "single-flight: exactly one reconciler log line names C ($((SF_T1-SF_T0))s start→join)"
else nok "single-flight: C was named ${N_ORPH_C:-0} times — a second reconciler read the same orphan" "$(printf '%s\n' "$SF_TAPE" | tr -d '\n' | grep -oE 'SPAWN RECONCILER[^;]{0,100}' | head -3 | tr '\n' ' ')"; fi
if [ "${N_FAIL_C:-0}" = "0" ] && [ -z "$(pending)" ]; then ok "single-flight: no false 'cleanup of C failed' line and the slot is clear (one stop, one delete, one clear)"
else nok "single-flight: a second delete of C failed into the recover-by-hand error" "failed_lines=${N_FAIL_C:-0} pending=$(pending)"; fi
adm setTestPendingSpawn '(null, 0 : nat)' >/dev/null
if [ -z "$(pending)" ]; then ok "slot cleared for the baseline"; else nok "could not clear the slot" "pending=$(pending)"; fi
SELF_ID=$(info | grep -oE '(^|[^a-zA-Z])canisterId = "[a-z0-9-]+"' | head -1 | grep -oE '"[a-z0-9-]+"' | tr -d '"')
if adm setTestPendingSpawn "(opt principal \"$SELF_ID\", 0 : nat)" | grep -qF 'refusing to plant this canister'; then ok "the plant hook refuses this canister as its own orphan"
else nok "the plant hook accepted the backend's own principal" "self=$SELF_ID pending=$(pending)"; fi

# ── A. Baseline: shipping works ────────────────────────────────────
echo "── A. baseline: events ship, sidecar spawns, queue drains ──"
emit 6 base
UNSHIP0=$(field "$(info)" journalUnshipped)
ship; sleep 1; ship   # first tick spawns the sidecar; second ships into it
I=$(info)
UNSHIP1=$(field "$I" journalUnshipped); ARCHED=$(field "$I" archivedEvents)
if [ "${UNSHIP0:-0}" -ge 6 ] && [ "${UNSHIP1:-99}" = "0" ] && [ "${ARCHED:-0}" -ge 6 ]; then
  ok "queue drained to the sidecar (queued $UNSHIP0 → 0, archived $ARCHED)"
else nok "baseline ship failed" "queued0=$UNSHIP0 queued1=$UNSHIP1 archived=$ARCHED"; fi
# (§S, continued) the plant hook refuses a ROUTED segment — the reconciler
# would stop-and-delete whatever the record names.
ACT_S=$(info | grep -oE 'archiveCanisterId = opt "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')   # active_archive() is defined further down
PLANT_REPLY=$(adm setTestPendingSpawn "(opt principal \"$ACT_S\", 0 : nat)" | tr -d '\n' | tr -s ' ')
if echo "$PLANT_REPLY" | grep -qF 'routed archive segment'; then ok "the plant hook refuses a routed archive segment ($ACT_S)"
else nok "the plant hook accepted the active archive" "active=${ACT_S:-none} reply=$(echo "$PLANT_REPLY" | head -c 160) pending=$(pending)"; fi

# ── B. Layer 1: roll on persistent failure ─────────────────────────
echo ""
echo "── B. L1: N ship failures → seal wedged archive + roll to fresh ──"
# fail=true, roll after 2 failures, hard cap high (no L2 interference).
adm setTestShipFailover "(true, opt (2 : nat), opt (100000 : nat), opt (90000 : nat), null, null, null)" >/dev/null
emit 4 wedge
SEALED0=$(field "$(info)" archivesSealed)
ship; ship; ship   # fail,fail,then streak≥2 → roll
I=$(info)
ROLLS=$(field "$I" emergencyRolls); SEALED1=$(field "$I" archivesSealed); STREAK=$(field "$I" shipFailStreak)
# NOTE: ${var}→ needs the braces — macOS bash 3.2 under a UTF-8 locale swallows the
# multibyte glyph into the variable name and `set -u` kills the script ("unbound").
echo "   emergencyRolls=$ROLLS archivesSealed=${SEALED0}→$SEALED1 streak=$STREAK"
if [ "${ROLLS:-0}" -ge 1 ]; then ok "L1 emergency roll fired (emergencyRolls=$ROLLS)"; else nok "L1 should roll after the fail streak" "rolls=$ROLLS"; fi
if [ "${SEALED1:-0}" -gt "${SEALED0:-0}" ]; then ok "wedged archive sealed at its acked prefix (sealed ${SEALED0}→$SEALED1)"; else nok "roll should seal the wedged archive" "${SEALED0}→$SEALED1"; fi
SHED_B=$(field "$I" shedEvents)
if [ "${SHED_B:-0}" = "0" ]; then ok "no data dropped by L1 (shedEvents=0)"; else nok "L1 must not drop data" "shedEvents=$SHED_B"; fi

# ── C. Layer 2: shed to bound the heap ─────────────────────────────
echo ""
echo "── C. L2: sustained failure past the hard cap → drop oldest, record gap ──"
# Shrink the cap so ~55 events trip it. Still failing.
adm setTestShipFailover "(true, opt (2 : nat), opt (50 : nat), opt (30 : nat), null, null, null)" >/dev/null
emit 55 flood
QBEFORE=$(field "$(info)" journalUnshipped)
# TWO ticks, not one. The L2 shed now requires BOTH conditions — queue ≥ cap
# AND shipFailStreak ≥ rollThreshold — where it used to fire on queue depth
# alone (issue #9.4 / triage §2.10: "if shipping is broken *and* the queue hit
# the cap" is what the comment always claimed, and now what the code does).
# §B's emergency roll RESETS the streak, so entering §C the streak is 1: the
# first tick here is the one that carries it back to the threshold and
# correctly declines to shed, and the second is the one that sheds. Asserting
# after a single tick was asserting the pre-fix contract.
ship   # streak 1 → 2; queue ≥ 50 but streak not yet at threshold, so no shed
ship   # streak at threshold + queue ≥ 50 → shed to 30 + re-baseline
I=$(info)
QAFTER=$(field "$I" journalUnshipped); SHED=$(field "$I" shedEvents); GAPS=$(field "$I" ledgerGaps)
echo "   journalUnshipped=${QBEFORE}→$QAFTER shedEvents=$SHED ledgerGaps=$GAPS"
if [ "${SHED:-0}" -ge 1 ]; then ok "L2 dropped events to bound the heap (shedEvents=$SHED)"; else nok "L2 should shed above the cap" "shedEvents=$SHED"; fi
if [ "${GAPS:-0}" -ge 1 ]; then ok "a ledger gap is recorded (ledgerGaps=$GAPS)"; else nok "L2 must record a gap" "ledgerGaps=$GAPS"; fi
# The shed immediately re-baselines the tape: one absolute row per live ledger
# entry. So the post-shed queue is EXACTLY shedTo + baselineWidth — deterministic
# whatever balances earlier suites left on the replica.
baseline() {  # → "<from> <toExcl>" of the NEWEST recorded baseline (or "0 0")
  local row
  row=$(adm getShedBaselines '()' --query | tr -d '_\n' \
    | grep -oE 'record \{ [0-9]+ : nat; [0-9]+ : nat \}' | tail -1)
  if [ -z "$row" ]; then echo "0 0"; else echo "$row" | grep -oE '[0-9]+' | tr '\n' ' '; fi
}
read -r BF BT <<<"$(baseline)"
BWIDTH=$(( ${BT:-0} - ${BF:-0} ))
NBASE=$(adm getShedBaselines '()' --query | tr -d '\n' | grep -oE 'record \{' | wc -l | tr -d ' ')
echo "   baseline: [$BF..$BT) = $BWIDTH re-attestation rows (recorded=$NBASE)"
if [ "${NBASE:-0}" -ge 1 ] && [ "$BWIDTH" -ge 1 ]; then
  ok "shed emitted a balance re-baseline ($BWIDTH absolute rows, seq [$BF..$BT))"
else nok "no re-baseline after the shed" "n=$NBASE width=$BWIDTH"; fi
# +1: the shed declares its gap ON the chain (W2-04 #gap event) before the
# baseline rows — the queue lands at shedTo + gapEvent + baselineWidth.
if [ "${QAFTER:-9999}" = "$(( 30 + 1 + BWIDTH ))" ]; then
  ok "queue bounded at shedTo + #gap + baseline (journalUnshipped=$QAFTER = 30+1+$BWIDTH)"
else nok "queue not at shedTo + #gap + baseline" "journalUnshipped=$QAFTER want $(( 30 + 1 + BWIDTH ))"; fi

# ── D. Recovery: drain + re-anchor + gap queryable ─────────────────
echo ""
echo "── D. recovery: clear the failure → drain onto a fresh archive, gap closed ──"
adm setTestShipFailover "(false, opt (2 : nat), opt (50 : nat), opt (30 : nat), null, null, null)" >/dev/null  # keep test cooldown=0
ship; sleep 1; ship; sleep 1; ship   # re-anchor roll, then ship the post-gap tail
I=$(info)
QREC=$(field "$I" journalUnshipped)
if [ "${QREC:-99}" = "0" ]; then ok "queue drained after recovery (journalUnshipped=0)"; else nok "queue should drain on recovery" "journalUnshipped=$QREC"; fi
# The gap is now CLOSED and queryable, and its width must equal exactly the
# number of shed events (no over/under-recording — the verifier trusts this).
GAPQ=$(adm getLedgerGaps '()' --query | tr -d '_')
NG=$(field "$(info)" ledgerGaps)
# The inner gap tuple is `{ FROM : nat; TO : nat; TS : int }`; take the first two nats.
GFROM=$(echo "$GAPQ" | grep -oE "\{ [0-9]+ : nat; [0-9]+ : nat;" | head -1 | grep -oE "[0-9]+" | head -1)
GTO=$(echo "$GAPQ"   | grep -oE "\{ [0-9]+ : nat; [0-9]+ : nat;" | head -1 | grep -oE "[0-9]+" | sed -n '2p')
GWIDTH=$(( ${GTO:-0} - ${GFROM:-0} ))
SHEDNOW=$(field "$(info)" shedEvents)
if [ "${NG:-0}" = "1" ] && [ "$GWIDTH" = "${SHEDNOW:-x}" ]; then
  ok "exactly one gap recorded, width == shed count (seq [$GFROM..$GTO) = $GWIDTH events)"
else nok "gap record wrong" "gaps=$NG width=$GWIDTH shed=$SHEDNOW"; fi
# Routing-consistency: NO archive may claim the gap. The seal boundary must be
# the wedged archive's TRUE acked high-water (gapFrom−1), and the active archive
# must re-anchor exactly at gapTo. (The buggy version sealed at the post-shed
# cursor, claiming the gap events it never received — this is the regression lock.)
ARCHJSON=$(adm getArchives '()' --query | tr -d '_')
read -r ACTIVE_FIRST MAX_SEALED_LAST <<<"$(python3 -c '
import re, sys
s = sys.stdin.read()
active_first = None; max_sealed_last = -1
for c in s.split("record {")[1:]:                            # one chunk per archive (field order varies)
    fm = re.search(r"firstSeq = (\d+)", c)
    if not fm: continue
    first = int(fm.group(1))
    if "lastSeq = null" in c: active_first = first            # the open/active archive
    else:
        lm = re.search(r"lastSeq = opt \((\d+)", c)
        if lm: max_sealed_last = max(max_sealed_last, int(lm.group(1)))
print(active_first if active_first is not None else -1, max_sealed_last)
' <<<"$ARCHJSON")"
if [ "${ACTIVE_FIRST:-x}" = "${GTO:-y}" ] && [ "${MAX_SEALED_LAST:-x}" = "$(( ${GFROM:-0} - 1 ))" ]; then
  ok "routing intact: sealed content stops at $MAX_SEALED_LAST (=gapFrom−1), active re-anchors at $ACTIVE_FIRST (=gapTo) — no archive claims the gap"
else nok "routing claims the gap (seal-boundary regression)" "activeFirst=$ACTIVE_FIRST (want $GTO) maxSealedLast=$MAX_SEALED_LAST (want $(( ${GFROM:-0} - 1 )))"; fi
# The newest baseline must sit ON the tape AFTER the gap (it shipped with the
# tail): from ≥ gapTo, nonempty. (A re-shed during recovery replaces it — the
# recorded ranges always describe the tape as it now exists.)
read -r BF2 BT2 <<<"$(baseline)"
if [ "${BF2:-0}" -ge "${GTO:-999999}" ] && [ "${BT2:-0}" -gt "${BF2:-0}" ]; then
  ok "re-baseline sits after the gap on the durable tape (seq [$BF2..$BT2) ≥ gapTo=$GTO)"
else nok "baseline not after the gap" "bf=$BF2 bt=$BT2 gapTo=$GTO"; fi
# The active archive's own chain verifies end-to-end.
ARCH=$(echo "$I" | grep -oE 'archiveCanisterId = opt "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
if [ -n "$ARCH" ]; then
  V=$(icp canister call --identity anonymous "$ARCH" verifyChain '(0 : nat, 100000 : nat)' --query 2>&1 | tr -d '_\n' | tr -s ' ')
  if echo "$V" | grep -q "ok = true"; then ok "active archive chain verifies after failover ($(echo "$V" | grep -oE 'checked = [0-9]+'))"; else nok "post-failover chain broken" "$V"; fi
else nok "no active archive after recovery" "?"; fi

# ── E. replay ACROSS the gap: the re-baseline makes the fold exact ──
echo ""
echo "── E. replay across the gap → zero mismatches (the gap is CLOSED) ──"
# The auditor walks the tape from seq 0: folds the pre-gap archives, HOPS the
# recorded gap, RESETS at the baseline, folds the re-attestation rows + tail —
# and must reproduce every live balance exactly. This is the §3 replay-test
# invariant (docs/archive-design.md), restored across an L2 shed.
adm adminReplayReset '()' >/dev/null
steps=0; RDONE=""
while [ $steps -lt 20 ]; do
  ST=$(adm adminReplayStep '(20000 : nat)' | tr -d '_\n' | tr -s ' ')
  echo "$ST" | grep -q "done = true" && { RDONE=1; break; }
  steps=$((steps+1))
done
if [ "$RDONE" = "1" ]; then ok "replay caught the tape (hopped the gap, reset at the baseline)"; else nok "replay stalled at the gap" "$ST"; fi
R=$(adm adminReplayReport '()' --query | tr -d '_\n' | tr -s ' ')
CHECKED=$(echo "$R" | grep -oE "accountsChecked = [0-9]+" | grep -oE "[0-9]+")
if echo "$R" | grep -q "mismatches = vec {}"; then
  ok "ZERO balance mismatches across the shed gap ($CHECKED accounts) — the tape reconstructs unaided"
else nok "fold ≠ live across the gap" "$(echo "$R" | head -c 300)"; fi
for L in debt lp ins; do
  if echo "$R" | grep -q "${L}Mismatches = vec {}"; then
    ok "${L} ledger folds exactly across the gap"
  else nok "${L} ledger mismatch across the gap" "$(echo "$R" | grep -oE "${L}Mismatches = vec \{[^}]*" | head -c 200)"; fi
done

# ── F. Layer 3 shear: SIZE-ONLY shed on a HEALTHY shipper (#52.2) ──
echo ""
echo "── F. L3 shear: size alone sheds above the shear cap; L2 stays both-conditions ──"
# Healthy shipper (fail=false); D/E's successful ships reset the streak to 0.
# hardCap=40 < shearCap=60, shedTo=30; rollThreshold stays the default (3) so
# the streak condition genuinely gates L2 here.
adm setTestShipFailover "(false, null, opt (40 : nat), opt (30 : nat), opt (60 : nat), null, null)" >/dev/null
I=$(info); SHED_F0=$(field "$I" shedEvents); GAPS_F0=$(field "$I" ledgerGaps); STREAK_F0=$(field "$I" shipFailStreak)
if [ "${STREAK_F0:-x}" = "0" ]; then ok "precondition: shipper healthy (shipFailStreak=0)"
else nok "expected a healthy shipper entering §F" "streak=$STREAK_F0"; fi
# Negative half: queue ≥ hardCap (45 ≥ 40) but under the shear cap, streak 0 →
# NO shed. The L2 both-conditions contract is unchanged; the healthy shipper
# just drains the backlog.
emit 45 nofire
ship; sleep 1; ship
I=$(info); SHED_F1=$(field "$I" shedEvents); GAPS_F1=$(field "$I" ledgerGaps); Q_F1=$(field "$I" journalUnshipped)
if [ "${SHED_F1:-x}" = "${SHED_F0:-y}" ] && [ "${GAPS_F1:-x}" = "${GAPS_F0:-y}" ]; then
  ok "no shed at hardCap alone with streak 0 (shedEvents=$SHED_F1 unchanged; queue drained to $Q_F1)"
else nok "L2 fired without a fail streak (both-conditions regression)" "shed ${SHED_F0}→$SHED_F1 gaps ${GAPS_F0}→$GAPS_F1"; fi
# H-32 (F12, D2): the shear is no longer SIZE-ONLY — it needs a memory-
# pressure signal too (shearMemoryPressure: wasm memory at 75 % of the
# limit, or a lowmemory() hook in the last 10 min), because one principal's
# exit-set dust reached the size cap in ~18 min with a HEALTHY archive and
# 175k events of everyone's history were dropped for nothing. Negative half
# first: queue past the SHEAR cap (65 ≥ 60), streak 0, NO memory pressure
# (pinned false) → NO shed; the healthy shipper drains it instead (the
# backlog-scaled burst — the queue here sits under the 50k soft tier, so it
# drains one batch per tick).
adm setTestShipFailover "(false, null, opt (40 : nat), opt (30 : nat), opt (60 : nat), null, opt false)" >/dev/null
emit 65 shear
QF=$(field "$(info)" journalUnshipped)
ship
I=$(info); SHED_F1b=$(field "$I" shedEvents); GAPS_F1b=$(field "$I" ledgerGaps); Q_F1b=$(field "$I" journalUnshipped)
if [ "${SHED_F1b:-x}" = "${SHED_F1:-y}" ] && [ "${GAPS_F1b:-x}" = "${GAPS_F1:-y}" ]; then
  ok "no shed past the shear cap WITHOUT memory pressure (queue $QF ≥ 60, streak 0; shedEvents=$SHED_F1b unchanged, queue → $Q_F1b) — H-32"
else nok "the shear fired on size alone with heap room (the H-32 finding: a healthy backlog is drained, not sheared)" "shed ${SHED_F1}→$SHED_F1b gaps ${GAPS_F1}→$GAPS_F1b queue=$QF"; fi
# Positive half: the same queue with memory pressure pinned TRUE → the shear
# sheds to shedTo (+ #gap + re-baseline) and records a gap, streak still 0.
adm setTestShipFailover "(false, null, opt (40 : nat), opt (30 : nat), opt (60 : nat), null, opt true)" >/dev/null
Q_NOW=$(field "$(info)" journalUnshipped); [ "${Q_NOW:-0}" -ge 60 ] || emit $((62 - ${Q_NOW:-0})) shear2
QF=$(field "$(info)" journalUnshipped)
ship
I=$(info); SHED_F2=$(field "$I" shedEvents); GAPS_F2=$(field "$I" ledgerGaps)
if [ "${SHED_F2:-0}" -gt "${SHED_F1b:-0}" ]; then
  ok "L3 shear fired on size + memory pressure (shedEvents ${SHED_F1b}→$SHED_F2 at queue $QF ≥ 60, streak 0)"
else nok "shear should shed above the shear cap under memory pressure on a healthy shipper" "shed ${SHED_F1b}→$SHED_F2 queue=$QF"; fi
adm setTestShipFailover "(false, null, opt (40 : nat), opt (30 : nat), opt (60 : nat), null, null)" >/dev/null   # pressure pin off; caps stay for the drain below
if [ "${GAPS_F2:-0}" -gt "${GAPS_F1:-0}" ]; then
  ok "the shear recorded a ledger gap (ledgerGaps ${GAPS_F1}→$GAPS_F2)"
else nok "shear must record a gap" "gaps ${GAPS_F1}→$GAPS_F2"; fi
# Same semantics as L2: the shear sealed the active archive, so the healthy
# shipper re-anchors a fresh one and drains the tail (gap + baseline included).
ship; sleep 1; ship; sleep 1; ship
QREC_F=$(field "$(info)" journalUnshipped)
if [ "${QREC_F:-99}" = "0" ]; then ok "post-shear tail drained onto a fresh archive (journalUnshipped=0)"
else nok "post-shear queue should drain" "journalUnshipped=$QREC_F"; fi

# ── G. Back-to-back sheds with NOTHING acked between (#55.4) ────────
echo ""
echo "── G. two sheds, no ack between → ONE list jump, TWO contiguous #gap events; verify_ledger.mjs --full accepts ──"
# The production shape: a shed fires while the successor spawn is still
# blocked (10-min backoff), the queue refills, and a second shed fires before
# anything was acked. No spawn block is needed to reproduce the LIST shape:
# the archive installed after shed 1 simply never acks (fail=true), and an
# archive that acked nothing is ABANDONED at the next seal, not sealed
# (sealActiveArchiveAtAcked) — no sealed-list entry. So getArchives gains ONE
# jump [a..c) while the chain carries TWO declarations [a..b) and [b..c) — the
# first survives shed 2 because the drop stops at shedTo, before it. Pre-#55.4
# both verifiers matched a jump only against a SINGLE declaration and called
# this honest tape an "unjustified discontinuity". §C/§F cannot pin it: they
# ship successfully between sheds, so their gaps are non-contiguous.
adm setTestShipFailover "(true, opt (2 : nat), opt (50 : nat), opt (30 : nat), null, null, null)" >/dev/null
I=$(info); SHED_G0=$(field "$I" shedEvents); SEALED_G0=$(field "$I" archivesSealed); GAPS_G0=$(field "$I" ledgerGaps)
shed_until() {  # shed_until <shedEvents before> — ticks (max 5) until shedEvents grows
  local before="$1" t=0 now
  while [ $t -lt 5 ]; do ship; now=$(field "$(info)" shedEvents); [ "${now:-0}" -gt "$before" ] && return 0; t=$((t+1)); done
  return 1
}
lastgap() {  # → "<from> <toExcl>" of the NEWEST recorded gap tuple
  adm getLedgerGaps '()' --query | tr -d '_\n' | grep -oE "\{ [0-9]+ : nat; [0-9]+ : nat;" | tail -1 | grep -oE "[0-9]+" | tr '\n' ' '
}
emit 55 twice
# Streak enters at 0 (§F drained healthily): two failing ticks reach the
# threshold, the next sheds + rolls onto a fresh archive that never acks.
if shed_until "${SHED_G0:-0}"; then ok "shed 1 fired under a failing shipper"; else nok "shed 1 did not fire" "shedEvents=$(field "$(info)" shedEvents)"; fi
I=$(info); SEALED_G1=$(field "$I" archivesSealed); GAPS_G1=$(field "$I" ledgerGaps)
read -r GA GB <<<"$(lastgap)"
if [ "${SEALED_G1:-0}" = "$(( ${SEALED_G0:-0} + 1 ))" ] && [ "${GAPS_G1:-0}" = "$(( ${GAPS_G0:-0} + 1 ))" ]; then
  ok "shed 1 sealed the acked archive and opened gap [$GA..$GB) (archivesSealed ${SEALED_G0}→$SEALED_G1, ledgerGaps ${GAPS_G0}→$GAPS_G1)"
else nok "shed 1 bookkeeping wrong" "sealed ${SEALED_G0}→$SEALED_G1 gaps ${GAPS_G0}→$GAPS_G1"; fi
# Refill with nothing acked, then shed again — sized so the drop is EXACTLY
# 30 (= shed 1's surviving tail): the boundary lands ON the first #gap event,
# which therefore stays on the chain. Two queue readings matter: the tick
# gates the shed on List.size(userEvents) as it stands (hardCap = N2), but
# shedOldestEvents FLUSHES the pending ledger journal first (one #delta per
# balance move the withdrawals made) and computes the drop on the flushed
# size — so shedTo = N2 + J2 − 30. Sizing on N2 alone overshoots by J2, drops
# the first #gap event and its baseline (the bisect rule swallows it whole),
# and leaves a coalesced [a..c) jump no verifier can justify — that is task
# 1788469743's backend follow-up, not this section's subject.
emit 10 twice2
I=$(info); N2=$(field "$I" journalUnshipped); J2=$(field "$I" ledgerJournalPending)
adm setTestShipFailover "(true, opt (2 : nat), opt ($N2 : nat), opt ($(( N2 + J2 - 30 )) : nat), null, null, null)" >/dev/null
SHED_G1=$(field "$(info)" shedEvents)
if shed_until "${SHED_G1:-0}"; then ok "shed 2 fired with nothing acked in between (queue $N2 + journal $J2 → shedTo $(( N2 + J2 - 30 )))"; else nok "shed 2 did not fire" "queue=$N2 journal=$J2 shed=$(field "$(info)" shedEvents)"; fi
I=$(info); SEALED_G2=$(field "$I" archivesSealed); GAPS_G2=$(field "$I" ledgerGaps)
read -r GA2 GC <<<"$(lastgap)"
if [ "${SEALED_G2:-0}" = "${SEALED_G1:-x}" ]; then
  ok "the never-acked archive was ABANDONED, not sealed (archivesSealed stays $SEALED_G2) — the list gains ONE jump"
else nok "an empty archive entered the sealed list" "${SEALED_G1}→$SEALED_G2"; fi
if [ "${GAPS_G2:-0}" = "${GAPS_G1:-x}" ] && [ "${GA2:-x}" = "${GA:-y}" ] && [ "${GC:-0}" = "$(( ${GB:-0} + 30 ))" ]; then
  ok "the ops tuple coalesced to [$GA..$GC) (ledgerGaps stays $GAPS_G2; halves [$GA..$GB) + [$GB..$GC))"
else nok "gap tuple did not coalesce as expected" "gaps ${GAPS_G1}→$GAPS_G2 last=[$GA2..$GC) want [$GA..$(( ${GB:-0} + 30 )))"; fi
# Recovery: the healthy shipper drains gap1 + baseline1 + refill + gap2 +
# baseline2 onto the fresh archive anchored at c.
adm setTestShipFailover "(false, opt (2 : nat), opt ($N2 : nat), opt ($(( N2 + J2 - 30 )) : nat), null, null, null)" >/dev/null
t=0; while [ $t -lt 6 ]; do ship; sleep 1; [ "$(field "$(info)" journalUnshipped)" = "0" ] && break; t=$((t+1)); done
QREC_G=$(field "$(info)" journalUnshipped)
if [ "${QREC_G:-99}" = "0" ]; then ok "post-shed tail drained onto the fresh archive (journalUnshipped=0)"; else nok "post-shed queue should drain" "journalUnshipped=$QREC_G"; fi
# What the CHAIN says (1788469743): the fresh archive anchored at c serves
# shed 1's surviving declaration [a..b) at seq c, and shed 2's declaration
# after the refill — which must carry the COALESCED range [a..c), not just
# shed 2's own half [b..c). The tuple list is uncertified and forgets nothing;
# the chain is what a verifier trusts, and a later shed can drop the earlier
# declaration (§H), so the newest one must always span from the last acked seq.
active_archive() { info | grep -oE 'archiveCanisterId = opt "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"'; }
# chaingaps <archive> <fromSeq> → one "<from> <toExcl>" line per #gap event
# served from fromSeq to the archive's END, in chain order. PAGED: getEventsRange
# caps a page at 200 events (ArchiveCanister.mo), and a shed's re-baseline is
# one row per LIVE ledger entry — resetExchange KEEPS wallets (only resetSeason
# zeroes them), so on a venue whose throwaway identities accumulated across
# suites, baseline1 alone can exceed the page and push shed 2's #gap past the
# first 200 events from c. Read as a single page, that venue shape made THIS
# suite report "shed 2's chain declaration covers only its own half" (2/72 red
# under run_all on seat-1, 2026-09-04) against a chain that declared it
# correctly — reproduced at 428 live balances, green at 155. The page loop
# advances past the last `seq` served and stops at an empty page.
chaingaps() {
  local s="$2" page last
  while :; do
    page=$(icp canister call --identity anonymous "$1" getEventsRange "($s : nat, 200 : nat)" --query 2>&1 | tr -d '_\n')
    echo "$page" | grep -oE 'gap = record \{[^}]*\}' \
      | while read -r g; do echo "$(echo "$g" | grep -oE 'fromSeq = [0-9]+' | grep -oE '[0-9]+') $(echo "$g" | grep -oE 'toSeq = [0-9]+' | grep -oE '[0-9]+')"; done
    # the event's own `seq` field — fromSeq/toSeq end in a capital S and never match
    last=$(echo "$page" | grep -oE 'seq = [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
    [ -z "$last" ] && break
    s=$(( last + 1 ))
  done
}
ARCH_G=$(active_archive)
CHAIN_G=$(chaingaps "$ARCH_G" "$GC")
read -r D1F D1T <<<"$(echo "$CHAIN_G" | head -1)"
read -r D2F D2T <<<"$(echo "$CHAIN_G" | tail -1)"
if [ "$(echo "$CHAIN_G" | grep -c .)" = "2" ] && [ "${D1F:-x}" = "$GA" ] && [ "${D1T:-x}" = "$GB" ]; then
  ok "shed 1's declaration [$GA..$GB) survived shed 2 at the front of the fresh archive (seq $GC)"
else nok "the fresh archive does not open with shed 1's surviving declaration" "chain: $(echo "$CHAIN_G" | tr '\n' ' ')"; fi
if [ "${D2F:-x}" = "$GA" ] && [ "${D2T:-x}" = "$GC" ]; then
  ok "shed 2 declared the COALESCED outage [$GA..$GC) on the chain, not just its own half (1788469743)"
else nok "shed 2's chain declaration covers only its own half" "newest #gap reads [${D2F:-?}..${D2T:-?}) want [$GA..$GC)"; fi
# The standalone verifier walks the WHOLE chain (every gap this suite made,
# §C/§F single declarations included). The [a..c) jump is declared VERBATIM
# by shed 2's coalesced #gap event, so no contiguous merge is needed here —
# the merge stays for chains written before 1788469743 (the halves-only
# shape, pinned offline by test_verify_ledger_gate.sh double-shed).
API_URL=$(icp network status 2>/dev/null | sed -n 's/^Api Url: //p' | head -1); API_URL=${API_URL%/}
BACKEND_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["backend"])' "$SCRIPT_DIR/../.icp/cache/mappings/local.ids.json" 2>/dev/null)
if [ -n "$API_URL" ] && [ -n "$BACKEND_ID" ]; then
  VOUT=$(cd "$SCRIPT_DIR/.." && node scripts/verify_ledger.mjs --backend "$BACKEND_ID" --host "$API_URL" --full 2>&1); VRC=$?
  if [ "$VRC" = "0" ] && echo "$VOUT" | grep -q "chain links verified across"; then
    ok "verify_ledger.mjs --full: exit 0 across the [$GA..$GC) jump ($(echo "$VOUT" | grep -oE '[0-9,]+ chain links verified across [0-9]+ gap' | tail -1))"
  else nok "verify_ledger.mjs --full refused the honest back-to-back shed tape" "rc=$VRC $(echo "$VOUT" | grep -E '✗|unjustified' | head -2 | tr '\n' ' ')"; fi
else nok "cannot locate the venue for the verifier" "api=$API_URL backend=$BACKEND_ID"; fi

# ── H. A THIRD shed drops the earlier declarations (1788469743) ──────
echo ""
echo "── H. third shed, nothing acked, drop passes the earlier #gap events → the surviving declaration spans [a..d); verify_ledger.mjs --full accepts ──"
# The production shape §G stops short of. Under a spawn still blocked, every
# later shed drops hardCap − shedTo events from the FRONT of the queue and
# the earlier #gap events sit ever closer to it: production L2 (250k/200k)
# drops the first declaration at shed 6, the L3 shear (375k/200k) at shear
# 3 — the bisect rule then swallows its baseline too. From that point the
# tuple list and the archive list both say [a..d) while the durable chain
# declares only later halves, and BOTH verifiers refuse an HONEST tape
# forever (#55.4's contiguous merge has nothing left to merge: the dropped
# declaration is gone from the tape, only the uncertified tuple remembers a).
# Reproduced as three sheds with nothing acked: shed 3's shedTo is small
# enough that its drop swallows gap1, baseline1, the refill, gap2 AND
# baseline2. Pre-fix the chain keeps [c..d) alone under the jump [a..d):
# the verifier exits 1 "unjustified discontinuity". Fixed, every shed
# declares the coalesced outage, so the one survivor reads [a..d).
adm setTestShipFailover "(true, opt (2 : nat), opt (50 : nat), opt (30 : nat), null, null, null)" >/dev/null
I=$(info); SHED_H0=$(field "$I" shedEvents); GAPS_H0=$(field "$I" ledgerGaps)
emit 55 thrice
if shed_until "${SHED_H0:-0}"; then ok "shed 1 fired under a failing shipper"; else nok "shed 1 did not fire" "shedEvents=$(field "$(info)" shedEvents)"; fi
read -r HA HB <<<"$(lastgap)"
emit 10 thrice2
I=$(info); N2=$(field "$I" journalUnshipped); J2=$(field "$I" ledgerJournalPending)
adm setTestShipFailover "(true, opt (2 : nat), opt ($N2 : nat), opt ($(( N2 + J2 - 30 )) : nat), null, null, null)" >/dev/null
SHED_H1=$(field "$(info)" shedEvents)
if shed_until "${SHED_H1:-0}"; then ok "shed 2 fired with nothing acked (drop 30 — the boundary lands ON gap1, which survives)"; else nok "shed 2 did not fire" "queue=$N2 journal=$J2 shed=$(field "$(info)" shedEvents)"; fi
read -r HA2 HC <<<"$(lastgap)"
if [ "${HA2:-x}" = "${HA:-y}" ] && [ "${HC:-0}" = "$(( ${HB:-0} + 30 ))" ]; then
  ok "ops tuple coalesced to [$HA..$HC) after shed 2"
else nok "shed 2 tuple wrong" "last=[$HA2..$HC) want [$HA..$(( ${HB:-0} + 30 )))"; fi
emit 10 thrice3
I=$(info); N3=$(field "$I" journalUnshipped); J3=$(field "$I" ledgerJournalPending)
# shedTo 5: the flushed queue is gap1 + baseline1 + refill2 + its deltas +
# gap2 + baseline2 + refill3 + its deltas; dropping all but 5 passes BOTH
# earlier declarations (and their baselines whole — no bisect), leaving
# refill3's tail as the survivors.
adm setTestShipFailover "(true, opt (2 : nat), opt ($N3 : nat), opt (5 : nat), null, null, null)" >/dev/null
SHED_H2=$(field "$(info)" shedEvents)
if shed_until "${SHED_H2:-0}"; then ok "shed 3 fired: drop $(( N3 + J3 - 5 )) passes gap1 and gap2 (queue $N3 + journal $J3 → shedTo 5)"; else nok "shed 3 did not fire" "queue=$N3 journal=$J3 shed=$(field "$(info)" shedEvents)"; fi
I=$(info); GAPS_H3=$(field "$I" ledgerGaps)
read -r HA3 HD <<<"$(lastgap)"
if [ "${GAPS_H3:-0}" = "$(( ${GAPS_H0:-0} + 1 ))" ] && [ "${HA3:-x}" = "${HA:-y}" ] && [ "${HD:-0}" -gt "${HC:-0}" ]; then
  ok "ops tuple coalesced to [$HA..$HD) across all three sheds (ledgerGaps ${GAPS_H0}→$GAPS_H3)"
else nok "three-shed tuple wrong" "gaps ${GAPS_H0}→$GAPS_H3 last=[$HA3..$HD) want [$HA..>$HC)"; fi
# Recovery onto a fresh archive anchored at d.
adm setTestShipFailover "(false, opt (2 : nat), opt ($N3 : nat), opt (5 : nat), null, null, null)" >/dev/null
t=0; while [ $t -lt 6 ]; do ship; sleep 1; [ "$(field "$(info)" journalUnshipped)" = "0" ] && break; t=$((t+1)); done
QREC_H=$(field "$(info)" journalUnshipped)
if [ "${QREC_H:-99}" = "0" ]; then ok "post-shed tail drained onto the fresh archive (journalUnshipped=0)"; else nok "post-shed queue should drain" "journalUnshipped=$QREC_H"; fi
ARCH_H=$(active_archive)
CHAIN_H=$(chaingaps "$ARCH_H" "$HD")
read -r D3F D3T <<<"$(echo "$CHAIN_H" | tail -1)"
if [ "$(echo "$CHAIN_H" | grep -c .)" = "1" ]; then
  ok "gap1 and gap2 were dropped with the queue front — the fresh archive (seq ${HD}…) carries ONE declaration"
else nok "expected exactly one #gap event on the fresh archive" "chain: $(echo "$CHAIN_H" | tr '\n' ' ')"; fi
if [ "${D3F:-x}" = "$HA" ] && [ "${D3T:-x}" = "$HD" ]; then
  ok "the surviving declaration spans the whole outage [$HA..$HD) — the dropped halves do not matter"
else nok "the surviving declaration is only shed 3's half: the honest jump [$HA..$HD) is unjustifiable forever" "newest #gap reads [${D3F:-?}..${D3T:-?})"; fi
if [ -n "$API_URL" ] && [ -n "$BACKEND_ID" ]; then
  VOUT=$(cd "$SCRIPT_DIR/.." && node scripts/verify_ledger.mjs --backend "$BACKEND_ID" --host "$API_URL" --full 2>&1); VRC=$?
  if [ "$VRC" = "0" ] && echo "$VOUT" | grep -q "chain links verified across"; then
    ok "verify_ledger.mjs --full: exit 0 after the earlier declarations were dropped ($(echo "$VOUT" | grep -oE '[0-9,]+ chain links verified across [0-9]+ gap' | tail -1))"
  else nok "verify_ledger.mjs --full refuses the honest three-shed tape (the 1788469743 permanent false positive)" "rc=$VRC $(echo "$VOUT" | grep -E '✗|unjustified' | head -2 | tr '\n' ' ')"; fi
else nok "cannot locate the venue for the verifier" "api=$API_URL backend=$BACKEND_ID"; fi

# ── I. The season boundary preserves the closed season's gaps + baselines (1788474114) ──
echo ""
echo "── I. resetSeason preserves the §C..§H gap tuples + shed baselines; verify_ledger.mjs --season N --fold resets at them ──"
# §C..§H left this epoch's tape with recorded gaps (getLedgerGaps) and shed
# re-baselines (getShedBaselines). The season detach clears both for the new
# epoch — before 1788474114 they were simply gone: `--season N --fold` had
# no reset points, so it folded the sealed segments' deltas straight across
# each shed and warned "shed re-baselines are not preserved". Now
# performWorldWipe(forSeason) writes the pair under the season number FIRST
# (_seasonGaps, a parallel stable map — SeasonRecord cannot grow a field in
# place under EOP) and getSeasonGaps(N) / getSeasonShedBaselines(N) export
# them in the live pair's shapes; the season walks consult those.
flat() { tr -d '_\n' | tr -s ' '; }
ntuples() { grep -oE 'record \{' | wc -l | tr -d ' '; }
GAPS_PRE=$(adm getLedgerGaps '()' --query | flat); NGAP_PRE=$(echo "$GAPS_PRE" | ntuples)
BASE_PRE=$(adm getShedBaselines '()' --query | flat); NBASE_PRE=$(echo "$BASE_PRE" | ntuples)
if [ "${NGAP_PRE:-0}" -ge 3 ] && [ "${NBASE_PRE:-0}" -ge 3 ]; then
  ok "pre-boundary live pair: $NGAP_PRE gap tuple(s), $NBASE_PRE shed baseline(s) from §C..§H"
else nok "the §C..§H tape should carry several gaps + baselines before the boundary" "gaps=$NGAP_PRE baselines=$NBASE_PRE"; fi
# resetSeason's gates want a drained tape (semantic queue + ledger journal).
t=0; while [ $t -lt 10 ]; do I=$(info); [ "$(field "$I" journalUnshipped)" = "0" ] && [ "$(field "$I" ledgerJournalPending)" = "0" ] && break; ship; sleep 1; t=$((t+1)); done
R=$(adm resetSeason '()' | flat)
SEASON_I=$(echo "$R" | grep -oE "season = [0-9]+" | head -1 | grep -oE "[0-9]+$")
if echo "$R" | grep -q "variant { ok" && [ -n "$SEASON_I" ]; then ok "resetSeason #ok — season $SEASON_I closed over the shed tape"
else nok "resetSeason refused" "$(echo "$R" | head -c 240)"; fi
GAPS_S=$(adm getSeasonGaps "(${SEASON_I:-0} : nat)" --query | flat)
BASE_S=$(adm getSeasonShedBaselines "(${SEASON_I:-0} : nat)" --query | flat)
if [ -n "$SEASON_I" ] && [ "$GAPS_S" = "$GAPS_PRE" ]; then ok "getSeasonGaps($SEASON_I) == the pre-boundary getLedgerGaps ($NGAP_PRE tuple(s), verbatim)"
else nok "the closed season's gap tuples were not preserved verbatim" "season=$(echo "$GAPS_S" | head -c 160) live-before=$(echo "$GAPS_PRE" | head -c 160)"; fi
if [ -n "$SEASON_I" ] && [ "$BASE_S" = "$BASE_PRE" ]; then ok "getSeasonShedBaselines($SEASON_I) == the pre-boundary getShedBaselines ($NBASE_PRE baseline(s), verbatim)"
else nok "the closed season's shed baselines were not preserved verbatim" "season=$(echo "$BASE_S" | head -c 160) live-before=$(echo "$BASE_PRE" | head -c 160)"; fi
if [ "$(adm getLedgerGaps '()' --query | flat)" = "(vec {})" ] && [ "$(adm getShedBaselines '()' --query | flat)" = "(vec {})" ]; then
  ok "the LIVE pair is empty after the boundary (it describes the new season)"
else nok "the live pair still carries the closed season's tuples" "gaps=$(adm getLedgerGaps '()' --query | flat | head -c 120)"; fi
if [ "$(adm getSeasonGaps "($(( ${SEASON_I:-0} + 1 )) : nat)" --query | flat)" = "(vec {})" ]; then ok "an unknown season answers [] (season $(( ${SEASON_I:-0} + 1 )))"
else nok "unknown season did not answer []" "$(adm getSeasonGaps "($(( ${SEASON_I:-0} + 1 )) : nat)" --query | flat | head -c 120)"; fi
if [ -n "$API_URL" ] && [ -n "$BACKEND_ID" ] && [ -n "$SEASON_I" ]; then
  VOUT=$(cd "$SCRIPT_DIR/.." && node scripts/verify_ledger.mjs --backend "$BACKEND_ID" --host "$API_URL" --season "$SEASON_I" --fold 2>&1); VRC=$?
  if [ "$VRC" = "0" ] && echo "$VOUT" | grep -q "season $SEASON_I anchored" \
     && echo "$VOUT" | grep -q "chain links verified across $NGAP_PRE gap" \
     && echo "$VOUT" | grep -q "preserved at the season boundary"; then
    ok "verify_ledger.mjs --season $SEASON_I --fold: exit 0 — $(echo "$VOUT" | grep -oE '[0-9,]+ chain links verified across [0-9]+ gap' | tail -1) from the PRESERVED tuples, record anchor met"
  else nok "verify_ledger.mjs --season $SEASON_I --fold refused the honest shed season" "rc=$VRC $(echo "$VOUT" | grep -E '✗|unjustified|season' | head -3 | tr '\n' ' ')"; fi
  if echo "$VOUT" | grep -q "healed by" && echo "$VOUT" | grep -q "$NBASE_PRE re-baseline(s)" \
     && ! echo "$VOUT" | grep -q "not preserved" && ! echo "$VOUT" | grep -q "no shed re-baselines were preserved"; then
    ok "the season fold reset at the $NBASE_PRE preserved re-baseline(s) — 'healed by' reported, no 'not preserved' warning"
  else nok "the season fold did not reset at the preserved baselines" "$(echo "$VOUT" | grep -E 're-baseline|preserved|healed' | head -3 | tr '\n' ' ')"; fi
else nok "§I verifier run could not resolve its inputs" "api=[$API_URL] backend=[$BACKEND_ID] season=[$SEASON_I]"; fi

# Cleanup: clear overrides + resume timers.
adm setTestShipFailover "(false, null, null, null, null, null, null)" >/dev/null 2>&1
adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
