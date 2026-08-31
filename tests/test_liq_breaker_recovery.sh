#!/bin/bash
# Regression pins for #52.4 — the liquidation `pending` signal is recoverable.
#
# Pre-fix, `pending` was SafeMath.subOrZero(_liqDispatches, _liqCompletions):
# a difference of MONOTONE totals with no writer anywhere that could close a
# gap. One trapped dispatch skewed it permanently — (1) the `pending <= 1`
# pin in test_audit_2026_08_fixes.sh tripped on a venue that had long since
# healed, and (2) the breaker predicate shared the inequality, so a
# pre-existing gap pre-armed the fail streak and a fresh trap escalated after
# 2 trapped passes instead of 3.
#
# The fix derives `pending` from the live in-flight flag (_liqInFlight):
# raised in the dispatch message, lowered ONLY by the pass's own completion
# stamp — never by elapsed time or an admin reset, either of which would mask
# a stuck engine. The monotone totals remain on the health surface as
# telemetry (lifetime trap count = dispatches − completions).
#
# Fixture: devDriveLiqCycle (dev-only) drives one dispatch cycle
# deterministically. trap=true arms the dispatch and never completes it —
# state-identical to the real batch trapping, since a trap rolls back every
# write of the batch message. Timers are paused so the real heartbeat cannot
# interleave dispatches mid-assertion.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+"; }

MODE=$(adm getDeployMode "()" | grep -oE '"[a-z]+"' | tr -d '"')
echo "  (posture: ${MODE:-unknown})"
if [ "${MODE:-}" != "dev" ]; then
  echo -e "${YELLOW}  ⊘ SKIP (posture ${MODE:-unknown}): devDriveLiqCycle is a dev-only hook — assumed exercised on #dev${NC}"
  echo -e "\n${YELLOW}SKIP: test_liq_breaker_recovery (posture)${NC}"
  exit 0
fi

# Quiesce the heartbeat (it would arm real dispatches mid-assertion), then
# settle to a known baseline: one completed pass lowers any in-flight flag a
# pause may have stranded, and a breaker reset clears the pacing.
adm setTestTimersPaused '(true)' >/dev/null 2>&1
adm devDriveLiqCycle '(false)' >/dev/null 2>&1
adm adminResetLiquidationBreaker '()' >/dev/null 2>&1

echo "── #52.4a — a healed sweep reports pending=0, however many passes ever trapped ──"
adm devDriveLiqCycle '(true)' >/dev/null 2>&1
adm devDriveLiqCycle '(true)' >/dev/null 2>&1
H=$(adm getLiquidationSweepHealth '()')
PENDING=$(fld pending "$H")
# At most ONE dispatch can be outstanding: the second trap replaced the first
# as "the outstanding pass". Pre-fix this read 2 (both lost completions).
if [ -n "${PENDING:-}" ] && [ "$PENDING" -eq 1 ]; then
  ok "two trapped dispatches leave exactly one outstanding (pending=1)"
else nok "two trapped dispatches leave exactly one outstanding" "pending=${PENDING:-absent} (a counter-difference reads 2)"; fi

adm devDriveLiqCycle '(false)' >/dev/null 2>&1
H=$(adm getLiquidationSweepHealth '()')
PENDING=$(fld pending "$H"); STREAK=$(fld failStreak "$H")
if [ -n "${PENDING:-}" ] && [ "$PENDING" -eq 0 ]; then
  ok "a completed pass returns pending to 0"
else nok "a completed pass returns pending to 0" "pending=${PENDING:-absent} — the gap is sticky, the venue can never look healthy again"; fi
if [ -n "${STREAK:-}" ] && [ "$STREAK" -eq 0 ]; then
  ok "a completed pass clears the failure streak"
else nok "a completed pass clears the failure streak" "failStreak=${STREAK:-absent}"; fi
# The monotone totals must SURVIVE as telemetry: the two traps above are
# lifetime history an operator can still read off the same surface.
D=$(fld dispatches "$H"); C=$(fld completions "$H")
if [ -n "${D:-}" ] && [ -n "${C:-}" ] && [ "$D" -gt "$C" ]; then
  ok "monotone totals retain the trap history as telemetry (dispatches=$D > completions=$C)"
else nok "monotone totals retain the trap history as telemetry" "dispatches=${D:-absent} completions=${C:-absent} — the counters were reset, history lost"; fi

echo "── #52.4b — escalation cadence is 3 observed traps, not 2, despite the healed history ──"
# The venue now carries ≥2 lifetime traps that all healed. Pre-fix, that
# history left dispatches>completions forever, so the FIRST arm below already
# counted a failure and the breaker tripped one pass early.
adm adminResetLiquidationBreaker '()' >/dev/null 2>&1
adm devDriveLiqCycle '(true)' >/dev/null 2>&1   # trap 1: nothing outstanding at arm → streak 0
adm devDriveLiqCycle '(true)' >/dev/null 2>&1   # trap 2: observes trap 1 → streak 1
adm devDriveLiqCycle '(true)' >/dev/null 2>&1   # trap 3: observes trap 2 → streak 2
H=$(adm getLiquidationSweepHealth '()')
STREAK=$(fld failStreak "$H"); BACKOFF=$(fld backoffNs "$H")
if [ -n "${STREAK:-}" ] && [ "$STREAK" -eq 2 ]; then
  ok "after 3 trapped passes only 2 are yet observed (failStreak=2, below the threshold)"
else nok "after 3 trapped passes only 2 are yet observed" "failStreak=${STREAK:-absent} — a pre-existing gap pre-armed the streak (cadence 2, not 3)"; fi
if [ -n "${BACKOFF:-}" ] && [ "$BACKOFF" -eq 30000000000 ]; then
  ok "cadence still at the 30s base below the threshold"
else nok "cadence still at the 30s base below the threshold" "backoffNs=${BACKOFF:-absent} — the breaker escalated early"; fi

adm devDriveLiqCycle '(true)' >/dev/null 2>&1   # trap 4: observes trap 3 → streak 3 → breaker
H=$(adm getLiquidationSweepHealth '()')
STREAK=$(fld failStreak "$H"); BACKOFF=$(fld backoffNs "$H")
if [ -n "${STREAK:-}" ] && [ "$STREAK" -eq 3 ]; then
  ok "the third observed trap reaches the threshold (failStreak=3)"
else nok "the third observed trap reaches the threshold" "failStreak=${STREAK:-absent}"; fi
if [ -n "${BACKOFF:-}" ] && [ "$BACKOFF" -gt 30000000000 ]; then
  ok "backoff engages at the threshold (backoffNs=$BACKOFF)"
else nok "backoff engages at the threshold" "backoffNs=${BACKOFF:-absent}"; fi

echo "── #52.4c — recovery is one completed pass, with no admin intervention ──"
adm devDriveLiqCycle '(false)' >/dev/null 2>&1
H=$(adm getLiquidationSweepHealth '()')
PENDING=$(fld pending "$H"); STREAK=$(fld failStreak "$H"); BACKOFF=$(fld backoffNs "$H")
if [ -n "${PENDING:-}" ] && [ "$PENDING" -eq 0 ] && [ -n "${STREAK:-}" ] && [ "$STREAK" -eq 0 ] \
   && [ -n "${BACKOFF:-}" ] && [ "$BACKOFF" -eq 30000000000 ]; then
  ok "one completed pass fully recovers: pending=0, failStreak=0, base cadence"
else nok "one completed pass fully recovers" "pending=${PENDING:-absent} failStreak=${STREAK:-absent} backoffNs=${BACKOFF:-absent}"; fi

# Restore the venue: pacing cleared, heartbeat running again.
adm adminResetLiquidationBreaker '()' >/dev/null 2>&1
adm setTestTimersPaused '(false)' >/dev/null 2>&1

echo
echo "──────────────────────────────────────────"
echo -e "  ${GREEN}$pass passed${NC}, $([ $fail -gt 0 ] && echo -e "${RED}$fail failed${NC}" || echo "0 failed")"
[ $fail -eq 0 ] || exit 1
