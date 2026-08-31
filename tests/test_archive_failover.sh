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
#   F  L3 shear (#52.2) — the SIZE-ONLY absolute ceiling above L2: internal
#          emitters are not admission-throttled, so a queue can pass the L2 cap
#          while the shipper reads healthy and the both-conditions gate stays
#          cold. Above shipShearCap the shed fires on size ALONE (failStreak 0),
#          with the same gap-ledger + re-anchor semantics; at hardCap alone with
#          a healthy shipper L2 still does NOT fire (both-conditions unchanged).
#
# Timers stay PAUSED; shipping is stepped by hand so the sequence is exact.
# ⚠️ Calls resetExchange. Needs a #dev backend.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
info() { adm getCanisterInfo '()' --query | tr -d '_'; }
field() { echo "$1" | grep -oE "$2 = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
WD=$(mkid afo_wd)

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
adm setTestShipFailover "(false, null, null, null, null)" >/dev/null 2>&1  # clean slate
adm setTestBalance "(principal \"$WD\", \"ICPUSD\", 100_000_000_000 : nat)" >/dev/null

# Emit N withdrawal events (each → 1 semantic UserEvent straight into the ship
# queue; timers paused, so no #delta drain muddies the count).
emit() { local n="$1" tag="$2" i=0; while [ $i -lt "$n" ]; do
  icp canister call --identity afo_wd backend withdraw "(\"ICPUSD\", 100_000_000 : nat, \"$tag-$i\")" >/dev/null 2>&1; i=$((i+1)); done; }
ship() { adm adminForceShipTick '()' >/dev/null 2>&1; }   # one synchronous ship tick

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

# ── B. Layer 1: roll on persistent failure ─────────────────────────
echo ""
echo "── B. L1: N ship failures → seal wedged archive + roll to fresh ──"
# fail=true, roll after 2 failures, hard cap high (no L2 interference).
adm setTestShipFailover "(true, opt (2 : nat), opt (100000 : nat), opt (90000 : nat), null)" >/dev/null
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
adm setTestShipFailover "(true, opt (2 : nat), opt (50 : nat), opt (30 : nat), null)" >/dev/null
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
adm setTestShipFailover "(false, opt (2 : nat), opt (50 : nat), opt (30 : nat), null)" >/dev/null  # keep test cooldown=0
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
adm setTestShipFailover "(false, null, opt (40 : nat), opt (30 : nat), opt (60 : nat))" >/dev/null
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
# Positive half: queue past the SHEAR cap (65 ≥ 60), streak still 0 → the
# size-only shear sheds to shedTo (+ #gap + re-baseline) and records a gap.
emit 65 shear
QF=$(field "$(info)" journalUnshipped)
ship
I=$(info); SHED_F2=$(field "$I" shedEvents); GAPS_F2=$(field "$I" ledgerGaps)
if [ "${SHED_F2:-0}" -gt "${SHED_F1:-0}" ]; then
  ok "L3 shear fired on size alone (shedEvents ${SHED_F1}→$SHED_F2 at queue $QF ≥ 60, streak 0)"
else nok "shear should shed above the shear cap on a healthy shipper" "shed ${SHED_F1}→$SHED_F2 queue=$QF"; fi
if [ "${GAPS_F2:-0}" -gt "${GAPS_F1:-0}" ]; then
  ok "the shear recorded a ledger gap (ledgerGaps ${GAPS_F1}→$GAPS_F2)"
else nok "shear must record a gap" "gaps ${GAPS_F1}→$GAPS_F2"; fi
# Same semantics as L2: the shear sealed the active archive, so the healthy
# shipper re-anchors a fresh one and drains the tail (gap + baseline included).
ship; sleep 1; ship; sleep 1; ship
QREC_F=$(field "$(info)" journalUnshipped)
if [ "${QREC_F:-99}" = "0" ]; then ok "post-shear tail drained onto a fresh archive (journalUnshipped=0)"
else nok "post-shear queue should drain" "journalUnshipped=$QREC_F"; fi

# Cleanup: clear overrides + resume timers.
adm setTestShipFailover "(false, null, null, null, null)" >/dev/null 2>&1
adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
