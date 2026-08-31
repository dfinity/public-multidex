#!/bin/bash
# Treasury → cycles fuel loop (Stage 2) + archive fuel plumbing.
#
# Stage 2 burns treasury ledger-ICP for REAL cycles through the wired fuel
# route: icrc1_transfer to the CMC subaccount, notify_top_up, deposit. In dev
# the route is the fuel-mock (ledger + CMC in one canister) which actually
# deposit_cycles the DEX at 1 ICP → 1T, so this test asserts a genuine
# cycle-balance rise — the whole loop, no simulation gaps:
#   §1  route wired (cold_start) + treasury seeded
#   §2  burn 1.5 ICP → #ok ≈1.5T cycles; internal ICP debited exactly;
#       balance delta ≥ 1.4T; lifetime counters + FUEL event
#   §3  guards: zero amount / over-balance / unwired → clean errors, no debit
#   §3b unaffordable notify: a deposit past the mock's own balance → clean
#       #Refunded (NOT a trap/wedge), pending cleared, block kept unconsumed
#       (retry after topping the mock delivers), normal burn works after
#   §3c stranded notify (#47.2): a #Processing notify keeps the latch; one
#       auto-fuel tick on a HEALTHY balance retries and completes the saga
#       unattended (pre-fix the health gate made the retry unreachable),
#       the aged latch raises the FUEL age alarm, and getCanisterInfo
#       mirrors the latch for the dashboard
#   §4  archive fuel: adminFundArchive forwards cycles to the sidecar
# Does NOT resetExchange (touches only treasury ICP + cycle balances).
# Timers paused; sim killed (event-log grep needs a quiet log).

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
fm()  { icp canister call --identity anonymous fuel-mock "$@" 2>&1; }
cycles() { adm getCanisterInfo '()' --query | tr -d '_' | grep -oE "cycles = [0-9]+" | head -1 | grep -oE "[0-9]+"; }

# The sim must be dead (header: the event-log grep needs a quiet log).
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
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true

echo "── §1 route wired + treasury seeded ──"
FUEL_MOCK_ID=$(icp canister status fuel-mock --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
if [ -z "$FUEL_MOCK_ID" ]; then
  nok "fuel-mock canister not deployed" "run icp deploy before this test"
  echo "RESULT: passed=$pass failed=$fail"; exit $fail
fi
adm setFuelRoute "(opt principal \"$FUEL_MOCK_ID\", opt principal \"$FUEL_MOCK_ID\")" >/dev/null
# The mock forwards REAL cycles (1 ICP → 1T), so it needs a mintable balance —
# a fresh canister's default can't cover a 1.5T deposit. Local mint, free.
icp canister top-up --amount 20t fuel-mock --identity anonymous >/dev/null 2>&1 || true
# Self-heal: a prior aborted run may have left a pending notify (stable).
adm adminRetryFuelNotify '(null)' >/dev/null 2>&1 || true
FS=$(adm getFuelStatus '()' --query | tr -d '\n' | tr -s ' ')
if echo "$FS" | grep -q "$FUEL_MOCK_ID"; then ok "fuel route wired at the mock"; else nok "route not wired" "$FS"; fi
L0=$(echo "$FS" | tr -d '_' | grep -oE "lifetimeIcpE8s = [0-9]+" | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
# Field renders QUOTED ("principal" = "...") — the name collides with the
# candid keyword; the value is the second quoted token on the line.
TREAS=$(adm getTreasury '()' --query | tr -d '\n' | grep -oE '"principal" = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tail -1 | tr -d '"')
if [ -n "$TREAS" ]; then ok "treasury principal resolved ($TREAS)"; else nok "no treasury principal" "$(adm getTreasury '()' --query | head -c 120)"; fi
adm setTestBalance "(principal \"$TREAS\", \"ICP\", 200_000_000 : nat)" >/dev/null   # 2 ICP

echo "── §2 burn 1.5 ICP → real cycles ──"
C0=$(cycles)
R=$(adm burnTreasuryIcpToCycles '(150_000_000 : nat)')
if echo "$R" | tr -d '_' | grep -qE "ok = 1499[0-9]{9}"; then
  ok "burn returned ≈1.5T minted cycles"
else nok "burn result wrong" "$R"; fi
ICP_LEFT=$(adm getTestBalance "(principal \"$TREAS\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ "${ICP_LEFT:-x}" = "50000000" ]; then
  ok "internal ICP debited exactly (2 → 0.5 ICP)"
else nok "internal debit wrong" "left=$ICP_LEFT"; fi
C1=$(cycles)
DELTA=$(( ${C1:-0} - ${C0:-0} ))
if [ "$DELTA" -ge 1400000000000 ]; then
  ok "cycle balance rose by ≥1.4T (Δ=$DELTA) — deposit really landed"
else nok "no real cycle deposit" "Δ=$DELTA (before=$C0 after=$C1)"; fi
FS2=$(adm getFuelStatus '()' --query | tr -d '_\n' | tr -s ' ')
L1=$(echo "$FS2" | grep -oE "lifetimeIcpE8s = [0-9]+" | grep -oE "= [0-9]+" | grep -oE "[0-9]+")
if [ "$(( ${L1:-0} - ${L0:-0} ))" = "150000000" ]; then
  ok "lifetime ICP-burned counter advanced by exactly 1.5 ICP"
else nok "lifetime counter wrong" "before=$L0 after=$L1"; fi
if echo "$FS2" | grep -q "pendingNotify = null"; then
  ok "no pending notify left behind"
else nok "pending notify stuck" "$(echo "$FS2" | head -c 200)"; fi
EV=$(adm getRecentEvents '(50 : nat)' --query 2>/dev/null | grep -c "FUEL: minted")
if [ "${EV:-0}" -ge 1 ]; then ok "mint is event-logged"; else nok "no FUEL event" "count=$EV"; fi

echo "── §3 guards ──"
R0=$(adm burnTreasuryIcpToCycles '(0 : nat)')
if echo "$R0" | grep -q "err"; then ok "zero amount refused"; else nok "zero accepted" "$R0"; fi
RB=$(adm burnTreasuryIcpToCycles '(999_999_999_999 : nat)')
if echo "$RB" | grep -q "err"; then ok "over-balance refused"; else nok "over-balance accepted" "$RB"; fi
adm setFuelRoute '(null, null)' >/dev/null
RU=$(adm burnTreasuryIcpToCycles '(50_000_000 : nat)')
if echo "$RU" | grep -q "not wired"; then ok "unwired route refused"; else nok "unwired accepted" "$RU"; fi
ICP_LEFT2=$(adm getTestBalance "(principal \"$TREAS\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ "${ICP_LEFT2:-x}" = "50000000" ]; then
  ok "failed attempts debited nothing"
else nok "guard leaked a debit" "left=$ICP_LEFT2"; fi
adm setFuelRoute "(opt principal \"$FUEL_MOCK_ID\", opt principal \"$FUEL_MOCK_ID\")" >/dev/null   # restore

echo "── §3b unaffordable notify → clean refusal, no wedge ──"
# The 2026-08-06 wedge: a deposit the mock couldn't fund TRAPPED the cycle
# attach; the backend read the trap as a transport error and kept
# pendingNotify forever — every later burn got "a prior top-up is awaiting
# notify", and this test's own §1 self-heal hit the same trap. Locks:
#   (a) the mock refuses DEFINITIVELY (#Refunded) instead of trapping,
#   (b) the backend clears the pending on that refusal (saga not wedged),
#   (c) the refused block stays UNCONSUMED — after topping the mock,
#       adminRetryFuelNotify(opt block) completes the SAME top-up,
#   (d) a normal burn works afterwards.
MOCK_CYC=$(icp canister status fuel-mock --identity anonymous 2>/dev/null | tr -d '_' | awk -F': ' '/^ *Cycles:/{print $2; exit}' | tr -d '[:space:]')
if [ -z "${MOCK_CYC:-}" ]; then
  nok "could not read fuel-mock cycle balance" "icp canister status fuel-mock"
else
  # e8s sized so the deposit = mock balance + 5T — past any refusal margin.
  UNAFF=$(( MOCK_CYC / 10000 + 500000000 ))
  adm setTestBalance "(principal \"$TREAS\", \"ICP\", $(( UNAFF + 100000000 )) : nat)" >/dev/null
  RR=$(adm burnTreasuryIcpToCycles "($UNAFF : nat)")
  if echo "$RR" | grep -q "Refunded" && echo "$RR" | grep -q "insufficient mock cycles"; then
    ok "unaffordable notify refused definitively (#Refunded, not a trap)"
  else nok "unaffordable notify not a clean #Refunded" "$RR"; fi
  FS3=$(adm getFuelStatus '()' --query | tr -d '\n' | tr -s ' ')
  if echo "$FS3" | grep -q "pendingNotify = null"; then
    ok "pending notify cleared by the refusal (saga not wedged)"
  else nok "pending notify wedged" "$(echo "$FS3" | head -c 200)"; fi
  BLOCK=$(echo "$RR" | grep -oE "block_index = \?[0-9]+" | grep -oE "[0-9]+")
  if [ -z "${BLOCK:-}" ]; then
    nok "refusal did not echo the block index" "$RR"
  else
    icp canister top-up --amount 20t fuel-mock --identity anonymous >/dev/null 2>&1 || true
    CB0=$(cycles)
    RT=$(adm adminRetryFuelNotify "(opt ($BLOCK : nat))")
    CB1=$(cycles)
    if echo "$RT" | grep -q "ok =" && [ $(( ${CB1:-0} - ${CB0:-0} )) -ge $(( MOCK_CYC / 2 )) ]; then
      ok "refused block kept: retry after topping the mock delivered the deposit"
    else nok "refused block not recoverable" "$RT (Δ=$(( ${CB1:-0} - ${CB0:-0} )))"; fi
  fi
  adm setTestBalance "(principal \"$TREAS\", \"ICP\", 200_000_000 : nat)" >/dev/null
  RN=$(adm burnTreasuryIcpToCycles '(60_000_000 : nat)')
  if echo "$RN" | tr -d '_' | grep -qE "ok = 599[0-9]{9}"; then
    ok "subsequent burn works (0.6 ICP → ≈0.6T real cycles)"
  else nok "subsequent burn failed" "$RN"; fi
  # The retry drained the mock by ~its pre-§3b balance — restore the venue's
  # fuel posture (cold_start sizes it to cover a 100-ICP auto-fuel tranche).
  icp canister top-up --amount 100t fuel-mock --identity anonymous >/dev/null 2>&1 || true
fi

echo "── §3c stranded notify auto-retries on a healthy balance (#47.2) ──"
# The finding: tickAutoFuel's health gate preceded the pending-notify retry,
# so once the cycle balance recovered (a local venue is ALWAYS healthy) the
# tick returned before the retry — a landed-but-un-notified top-up waited on
# a controller (adminRetryFuelNotify) forever while fuelStage2 refused every
# further draw. Locks:
#   (a) a #Processing notify KEEPS the pending record (saga latch armed),
#   (b) a retry tick that still can't complete an AGED latch logs the FUEL
#       age alarm (sinceNs is finally read),
#   (c) one auto-fuel tick on a HEALTHY balance retries and completes the
#       saga — latch cleared, cycles minted — with no admin call,
#   (d) getCanisterInfo mirrors the latch for the dashboard (null once done).
adm setAutoFuel '(true)' >/dev/null
adm setTestBalance "(principal \"$TREAS\", \"ICP\", 200_000_000 : nat)" >/dev/null
fm setProcessingNotifies '(true)' >/dev/null
RS=$(adm burnTreasuryIcpToCycles '(80_000_000 : nat)')
if echo "$RS" | grep -q "still processing"; then
  ok "notify #Processing surfaced as a retryable error"
else nok "unexpected burn result under #Processing" "$RS"; fi
FS4=$(adm getFuelStatus '()' --query | tr -d '\n' | tr -s ' ')
if echo "$FS4" | grep -q "pendingNotify = opt"; then
  ok "pending notify KEPT on #Processing (latch armed)"
else nok "latch not armed" "$(echo "$FS4" | head -c 200)"; fi
# Backdate the latch 2h and tick while the mock still answers #Processing:
# the retry must fire regardless of headroom, keep the latch, and log the
# age alarm.
adm setTestFuelPendingSince "($(( $(date +%s) * 1000000000 - 7200000000000 )) : int)" >/dev/null
adm devTickAutoFuel '()' >/dev/null
EV2=$(adm getRecentEvents '(30 : nat)' --query 2>/dev/null | grep -c "still awaiting notify")
if [ "${EV2:-0}" -ge 1 ]; then
  ok "age alarm logged for the stranded notify"
else nok "no age alarm in the event log" "count=$EV2"; fi
# Heal the mock; the NEXT unattended tick must complete the saga even though
# the balance is healthy — pre-#47.2 this tick returned at the health gate.
fm setProcessingNotifies '(false)' >/dev/null
CS0=$(cycles)
adm devTickAutoFuel '()' >/dev/null
CS1=$(cycles)
FS5=$(adm getFuelStatus '()' --query | tr -d '\n' | tr -s ' ')
if echo "$FS5" | grep -q "pendingNotify = null"; then
  ok "auto-retry cleared the latch on a healthy balance (the #47.2 fix)"
else nok "latch survived the tick — retry unreachable behind the health gate" "$(echo "$FS5" | head -c 200)"; fi
if [ $(( ${CS1:-0} - ${CS0:-0} )) -ge 700000000000 ]; then
  ok "the stranded mint landed (Δ=$(( ${CS1:-0} - ${CS0:-0} )) cycles)"
else nok "no deposit from the auto-retry" "Δ=$(( ${CS1:-0} - ${CS0:-0} ))"; fi
CI=$(adm getCanisterInfo '()' --query | tr -d '\n' | tr -s ' ')
if echo "$CI" | grep -q "fuelPendingNotify = null"; then
  ok "getCanisterInfo surfaces fuelPendingNotify (null once cleared)"
else nok "fuelPendingNotify missing from getCanisterInfo" "$(echo "$CI" | grep -o 'fuel[A-Za-z]* = [a-z0-9]*' | head -c 160)"; fi
# Conservation physics: leave the venue with auto-fuel OFF (a seed burst
# inflates the burn EMA and Stage-1 buys trader ICP into the treasury,
# faking leaks in value-conservation frames).
adm setAutoFuel '(false)' >/dev/null

echo "── §4 archive fuel forwarding ──"
RA=$(adm adminFundArchive '(100_000_000_000 : nat)')
if echo "$RA" | tr -d '_' | grep -q "ok = 100000000000"; then
  ok "adminFundArchive forwarded 100B cycles to the sidecar"
elif echo "$RA" | grep -q "no archive sidecar"; then
  ok "no sidecar spawned on this deployment (fresh install) — guard answered cleanly"
else nok "archive funding failed" "$RA"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
