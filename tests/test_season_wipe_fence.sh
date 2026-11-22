#!/bin/bash
# tests/test_season_wipe_fence.sh — H-26 (F41): the Bridge's wipe-pending
# fence lets the season wipe complete against a sustained admission stream.
#
# Pre-fix: adminSeasonWipe refused while ANY claim or admission was in flight,
# resetSeason aborted on the refusal, and a caller that never passes the DEX's
# binding gate could still take the Bridge's in-flight guard for one round
# trip per call — so a loop of unbound keypairs held the venue-global
# interlock against every retry the operator made (probabilistically). Now a
# refused wipe ARMS `wipePending`: new claims and admissions are refused with
# a typed #err, the in-flight ones drain, and the next attempt lands.
#
#   §1 deterministic: devTestHoldAdmission parks an admission; attempt 1 is
#      refused AND arms the fence; under the fence an ELIGIBLE user's deposit,
#      claim and confirm refuse, and the attacker cannot re-take the
#      interlock; once the hold releases, attempt 2 completes and the fence
#      clears (bounded: exactly two attempts).
#   §2 the flag is STABLE: armed, then a Bridge upgrade — the in-flight guard
#      is cleared (postupgrade) but the fence survives; adminCancelSeasonWipe
#      is controller/DEX-only and disarms it.
#   §3 a REAL stream: three unbound identities hammer devSimulateDeposit in
#      the background while resetSeason is attempted; the reset completes
#      within a bounded number of attempts, the fence is clear afterwards, and
#      the refused stream left no rows (F40 under load).
#
# Needs #dev (devTestHoldAdmission). ⚠️ §1 and §3 season-wipe the venue —
# reseed afterwards (cold_start --mode full --no-simulate). Order-independent.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"     # NB: _lib.sh REDEFINES SCRIPT_DIR as the repo root
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm()  { echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
badm() { echo y | icp canister call --identity anonymous bridge "$@" 2>&1; }
w()    { echo y | icp canister call --identity swf_w bridge "$@" 2>&1; }
flat() { tr -d '_\n' | tr -s ' '; }
stats() { badm getBridgeStats '()' --query | flat; }
statn() { echo "$1" | grep -oE "$2 = [0-9]+" | awk '{print $3}'; }
statb() { echo "$1" | grep -oE "$2 = (true|false)" | awk '{print $3}'; }
# A typed #ok, PRECISELY: `grep -q ok` also matches the word "hook" inside a
# dev-hook REFUSAL ("...is a dev-only hook"), which turned a refused hold into
# a green line once. mdx_ok (tests/_lib.sh) matches the variant tag itself.

[ "$(venue_posture)" = "dev" ] || skip_posture "test_season_wipe_fence" "resetSeason + setTestEmailBinding (#dev backend)"
# The HOOK sections (§1, §2) need the BRIDGE at #dev too. On a seat the tree
# sits at #play between deploys, and any earlier suite that rebuilds the
# Bridge from the tree (test_deposit_ledger_guard's `icp deploy bridge`, an
# in-place `--mode upgrade`) flips the venue's Bridge to #play under us —
# so read the Bridge's OWN posture, not the DEX's. §3 needs no Bridge hook.
BRIDGE_POSTURE=$(bridge_posture)

STOPPER="$ROOT/scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # the shipper must run: the seal gates need a drained tape

mdx_identity_new swf_w; W=$(principal_of swf_w)   # the ELIGIBLE user (bound below); virgin each run, deleted on EXIT (tests/_lib.sh)
mdx_identity_new swf_x; X=$(principal_of swf_x)   # the attacker: unbound, never passes the DEX's binding gate

drain_tape() {
  for _ in $(seq 1 60); do
    INFO=$(adm getCanisterInfo '()' --query | tr -d '_')
    UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+$")
    JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+$")
    [ "${UNSH:-1}" = "0" ] && [ "${JP:-1}" = "0" ] && return 0
    adm adminForceShipTick '()' >/dev/null 2>&1
    sleep 2
  done
  return 1
}
provision() {   # binding + a BTC mark (a wiped venue has neither)
  adm setTestEmailBinding "(principal \"$W\", \"swf${RANDOM}$$@example.com\")" >/dev/null 2>&1
  adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
  adm setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
  adm requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
}
# Make sure a stale fence from an aborted earlier run cannot skew §1.
badm adminCancelSeasonWipe '()' >/dev/null 2>&1

if [ "$BRIDGE_POSTURE" != "dev" ]; then
  skip_section "§1+§2 (devTestHoldAdmission needs the BRIDGE at #dev; the venue's Bridge is #${BRIDGE_POSTURE:-unknown} — an earlier suite rebuilt it from a #play tree; redeploy the Bridge under the posture rhythm to exercise them)"
else
echo "── §1 deterministic: a held admission delays the wipe by exactly one attempt ──"
provision
R=$(w devSimulateDeposit '("BTC", 100_000_000 : nat)')
mdx_ok "$R" && ok "eligible user's deposit admitted before the boundary" || nok "admit failed" "$(echo "$R" | head -c 200)"
R=$(badm devTestHoldAdmission "(principal \"$X\", \"BTC\", true)")
mdx_ok "$R" && ok "attacker's admission parked in its round trip (hold taken)" || nok "hold hook refused" "$(echo "$R" | head -c 200)"
S=$(stats)
[ "$(statn "$S" admitting)" = "1" ] && ok "interlock occupied (admitting = 1)" || nok "interlock not held" "$(echo "$S" | head -c 200)"
drain_tape || nok "tape did not drain" "gates would refuse"
R=$(adm resetSeason '()' | flat)
if echo "$R" | grep -q "Bridge refused the season wipe" && echo "$R" | grep -q "ARMED"; then ok "attempt 1 refused by the Bridge and the fence is ARMED"
else nok "attempt 1 did not refuse-and-arm" "$(echo "$R" | head -c 250)"; fi
S=$(stats)
[ "$(statb "$S" wipePending)" = "true" ] && ok "getBridgeStats: wipePending = true" || nok "fence not armed" "$(echo "$S" | head -c 200)"
INFO=$(adm getCanisterInfo '()' --query | flat)
echo "$INFO" | grep -q "seasonSealing = false" && ok "DEX latch released on the refusal (seasonSealing = false)" || nok "latch stranded" "$(echo "$INFO" | grep -oE 'seasonSealing = [a-z]+')"
R=$(w devSimulateDeposit '("BTC", 100_000_000 : nat)')
echo "$R" | grep -q "season wipe is pending" && ok "under the fence an eligible deposit is refused with the wipe #err" || nok "deposit not fenced" "$(echo "$R" | head -c 200)"
R=$(w claim '("BTC")')
echo "$R" | grep -q "season wipe is pending" && ok "under the fence a claim is refused with the wipe #err" || nok "claim not fenced" "$(echo "$R" | head -c 200)"
R=$(w devConfirmDeposits '()')
echo "$R" | grep -q "season wipe is pending" && ok "under the fence devConfirmDeposits traps with the wipe message" || nok "confirm not fenced" "$(echo "$R" | head -c 200)"
R=$(badm devTestHoldAdmission "(principal \"$X\", \"ETH\", true)")
echo "$R" | grep -q "season wipe is pending" && ok "the attacker cannot re-take the interlock under the fence" || nok "re-hold succeeded under the fence" "$(echo "$R" | head -c 200)"
S=$(stats)
[ "$(statn "$S" admitting)" = "1" ] && ok "still exactly the one in-flight hold (admitting = 1)" || nok "admitting drifted" "$(echo "$S" | head -c 200)"
R=$(badm devTestHoldAdmission "(principal \"$X\", \"BTC\", false)")
mdx_ok "$R" && ok "the in-flight admission settles (hold released)" || nok "release refused" "$(echo "$R" | head -c 200)"
drain_tape || nok "tape did not drain" "gates would refuse"
R=$(adm resetSeason '()' | flat)
mdx_ok "$R" && ok "attempt 2 completes — bounded at two attempts" || nok "attempt 2 refused" "$(echo "$R" | head -c 250)"
S=$(stats)
[ "$(statb "$S" wipePending)" = "false" ] && ok "fence cleared on completion (wipePending = false)" || nok "fence stuck after the wipe" "$(echo "$S" | head -c 200)"
[ "$(statn "$S" ledgers)" = "0" ] && [ "$(statn "$S" admittedUnits)" = "0" ] && ok "Bridge maps wiped (ledgers 0, admittedUnits 0)" || nok "maps not wiped" "$(echo "$S" | head -c 200)"
provision
R=$(w devSimulateDeposit '("BTC", 100_000_000 : nat)')
mdx_ok "$R" && ok "on-ramp open again after the wipe" || nok "deposit still refused" "$(echo "$R" | head -c 200)"

echo "── §2 the fence is STABLE across a Bridge upgrade; a controller can disarm it ──"
R=$(badm devTestHoldAdmission "(principal \"$X\", \"BTC\", true)")
mdx_ok "$R" && ok "hold taken again" || nok "hold hook refused" "$(echo "$R" | head -c 200)"
drain_tape || nok "tape did not drain" "gates would refuse"
R=$(adm resetSeason '()' | flat)
echo "$R" | grep -q "ARMED" && ok "attempt refused, fence armed" || nok "did not arm" "$(echo "$R" | head -c 250)"
# An in-place upgrade lands a build of the tree: only when the tree's posture
# matches the venue's can it run without flipping the venue's Bridge — the
# shared guard (tests/_lib.sh) decides, builds first (install alone never
# rebuilds) and prints the ⊘ on a mismatch.
bridge_upgrade_if_posture_matches "§2 in-place upgrade"; BUP_RC=$?
if [ "$BUP_RC" = "0" ]; then
  ok "$BRIDGE_UPGRADE_NOTE"
  S=$(stats)
  [ "$(statn "$S" admitting)" = "0" ] && ok "postupgrade cleared the in-flight guard (admitting = 0)" || nok "guard survived the upgrade" "$(echo "$S" | head -c 200)"
  [ "$(statb "$S" wipePending)" = "true" ] && ok "the fence SURVIVED the upgrade (stable Bool)" || nok "fence lost on upgrade" "$(echo "$S" | head -c 200)"
  R=$(w devSimulateDeposit '("BTC", 100_000_000 : nat)')
  echo "$R" | grep -q "season wipe is pending" && ok "still fenced after the upgrade" || nok "fence not enforced post-upgrade" "$(echo "$R" | head -c 200)"
else
  [ "$BUP_RC" = "1" ] || nok "upgrade failed" "$BRIDGE_UPGRADE_NOTE"
  R=$(badm devTestHoldAdmission "(principal \"$X\", \"BTC\", false)")   # release, as the upgrade would have
fi
R=$(w adminCancelSeasonWipe '()')
echo "$R" | grep -q "neither the wired DEX nor a controller" && ok "cancel refused for a plain user" || nok "cancel not gated" "$(echo "$R" | head -c 200)"
R=$(badm adminCancelSeasonWipe '()')
mdx_ok "$R" && ok "controller cancelled the pending wipe" || nok "cancel failed" "$(echo "$R" | head -c 200)"
S=$(stats)
[ "$(statb "$S" wipePending)" = "false" ] && ok "wipePending = false after cancel" || nok "fence still armed" "$(echo "$S" | head -c 200)"
R=$(w devSimulateDeposit '("BTC", 100_000_000 : nat)')
mdx_ok "$R" && ok "on-ramp open after the cancel" || nok "deposit refused after cancel" "$(echo "$R" | head -c 200)"

fi   # bridge-posture gate for §1+§2

echo "── §3 a REAL unbound admission stream: the reset completes within a bounded number of attempts ──"
L_PRE=$(statn "$(stats)" ledgers)
STOP="$(mktemp -d)/stop"
PIDS=()
for n in 1 2 3; do
  mdx_identity_new "swf_s$n"
  ( while [ ! -f "$STOP" ]; do
      icp canister call --identity "swf_s$n" bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' >/dev/null 2>&1
    done ) &
  PIDS+=($!)
done
ok "3 unbound identities hammering devSimulateDeposit in the background (pids ${PIDS[*]})"
sleep 3
S=$(stats)
[ "$(statn "$S" ledgers)" = "$L_PRE" ] && ok "3s into the stream the ledgers size is unchanged ($L_PRE) — refusals leave no rows under load" || nok "the refused stream is creating rows" "pre=$L_PRE now=$(statn "$S" ledgers)"
ATT=0; DONE=false; LAST=""
while [ $ATT -lt 8 ]; do
  ATT=$((ATT+1))
  drain_tape >/dev/null 2>&1
  LAST=$(adm resetSeason '()' | flat)
  if mdx_ok "$LAST"; then DONE=true; break; fi
  echo "   attempt $ATT refused: $(echo "$LAST" | grep -oE 'err = "[^"]{0,90}')"
  sleep 1
done
if [ "$DONE" = "true" ]; then ok "resetSeason completed under the stream in $ATT attempt(s) (bound 8)"
else nok "resetSeason never completed under the stream" "$(echo "$LAST" | head -c 250)"; fi
touch "$STOP"; wait "${PIDS[@]}" 2>/dev/null
ok "stream stopped (marker file; own child pids reaped)"
S=$(stats)
[ "$(statb "$S" wipePending)" = "false" ] && ok "fence clear after the completed wipe" || nok "fence stuck" "$(echo "$S" | head -c 200)"
[ "$(statn "$S" ledgers)" = "0" ] && [ "$(statn "$S" admittedUnits)" = "0" ] && [ "$(statn "$S" admitting)" = "0" ] \
  && ok "the refused stream left NO rows and holds nothing (ledgers 0, admittedUnits 0, admitting 0)" \
  || nok "stream left rows or a hold behind (F40 under load)" "$(echo "$S" | head -c 200)"
R=$(icp canister call --identity swf_s1 bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' 2>&1)
echo "$R" | grep -q "verified Google" && ok "after the boundary the stream's refusal is the binding gate again, not the fence" || nok "unexpected post-reset refusal" "$(echo "$R" | head -c 200)"
S=$(stats)
[ "$(statn "$S" ledgers)" = "0" ] && [ "$(statn "$S" admittedUnits)" = "0" ] && ok "one more refused admission on the empty Bridge: still 0 rows" || nok "refused admission created rows" "$(echo "$S" | head -c 200)"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_season_wipe_fence ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_season_wipe_fence ($fail failed, $pass passed)${NC}"; exit 1
fi
