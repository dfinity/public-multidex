#!/bin/bash
# Ledger-of-record reconciliation (docs/archive-design.md).
#
# Every balance mutation journals a signed delta at the Accounts write funnel
# and drains into #delta archive events, so folding the archive alone must
# reproduce EVERY account balance — the property disaster-recovery-by-replay
# and Proof-of-Reserves liabilities stand on. This test runs a mixed workload
# (admin mints, user↔user fills with fees, AMM fills, LP round-trip,
# insurance stake/unstake, withdrawals), lets the journal + shipper drain,
# then folds the tape via the in-canister auditor and demands ZERO mismatches
# across ALL accounts — users, AMM vault, treasury, insurance alike.
# Timers stay ON (drain + ship are heartbeat-driven); sim killed.
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
A=$(mkid rp_a); B=$(mkid rp_b); SEED=$(mkid rp_seed)
ua() { icp canister call --identity rp_a backend "$@" 2>&1; }
ub() { icp canister call --identity rp_b backend "$@" 2>&1; }

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
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
# Defensive: test_archive_chain pins a tiny archive cap (20 events) and only
# clears it on a CLEAN exit — a mid-test crash leaks the pin and this tape
# then rolls archives every 20 events, scattering the rows §3 asserts on.
adm setTestArchiveCap '(null)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true

echo "── §1 mixed workload (every leg journals by construction) ──"
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\",    $(e8 5000)  : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 15000) : nat)" >/dev/null
adm setTestBalance "(principal \"$A\",    \"ICP\",    $(e8 500)   : nat)" >/dev/null
adm setTestBalance "(principal \"$A\",    \"ICPUSD\", $(e8 5000)  : nat)" >/dev/null
adm setTestBalance "(principal \"$B\",    \"ICPUSD\", $(e8 5000)  : nat)" >/dev/null
icp canister call --identity rp_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 5000) : nat, $(e8 15000) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
fresh() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }
fresh

# user↔user cross (maker+taker fees hit the treasury)
ua placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 3) : nat, $(e8 100) : nat)" >/dev/null 2>&1
fresh
ub placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 3) : nat, $(e8 100) : nat)" >/dev/null 2>&1
fresh
# AMM fill (vault as counterparty)
ub placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 30) : nat, opt (5_000_000 : nat))" >/dev/null 2>&1
fresh
# LP round-trip
ua depositLp "(\"ICP-ICPUSD\", $(e8 50) : nat, $(e8 150) : nat)" >/dev/null 2>&1
ua withdrawLp "(\"ICP-ICPUSD\", $(e8 20) : nat)" >/dev/null 2>&1
# insurance round-trip
ub stakeInsurance "($(e8 200) : nat)" >/dev/null 2>&1
ub unstakeInsurance "($(e8 50) : nat)" >/dev/null 2>&1
# arbitrageur external-market flows (venue-minted synthetic supply): fund the
# arb, then import base at the mark. fundArbitrageur + both legs of the import
# land on the permanent tape as semantic #deposit/#withdrawal rows (attributed
# to the arb in verify_ledger.mjs --fold), so the ledger accounts for the mint
# rather than reading it as a break. We wire a CALLABLE test identity as the
# arbitrageur (extMarketSwap is caller-gated to the wired principal); the real
# canister-driven import/export path is covered by test_arbitrage.sh.
ARB=$(mkid rp_arb)
adm setArbitrageur "(principal \"$ARB\")" >/dev/null 2>&1
adm fundArbitrageur "($(e8 3000) : nat)" >/dev/null 2>&1
# import 100 ICP at mark $3 → arb pays ICPUSD (withdrawal), receives ICP (deposit).
# Retry with a freshly-stamped mark each attempt: with timers running the
# heartbeat can age the mark past the staleness gate between our fresh() and
# the call — exactly what the real arb canister rides out by re-ticking.
IMP=""
for attempt in 1 2 3 4 5; do
  fresh
  IMP=$(icp canister call --identity rp_arb backend extMarketSwap "(\"ICP\", variant { importBase }, $(e8 100) : nat, null)" 2>&1)
  echo "$IMP" | grep -q "ok = " && break
  sleep 1
done
echo "$IMP" | grep -q "ok = " && echo "  (arb imported 100 ICP at the mark)" || echo "  (arb import skipped: $(echo "$IMP" | tr -d '\n' | head -c 100))"
# margin: fund a pool, open a leveraged long, leave it OPEN — live pool debt
# and pool-principal balances must reconcile too (they replay raw)
PIDR=$(ua createMarginPool '("replay pool", false)' | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "$PIDR" ]; then ok "margin pool created (id=$PIDR)"; else nok "createMarginPool failed" "?"; fi
FM=$(ua fundMarginPool "($PIDR, $(e8 1000) : nat)")
if echo "$FM" | grep -q ok; then ok "pool funded \$1000"; else nok "fundMarginPool" "$FM"; fi
OP=$(ua openPosition "($PIDR, \"ICP-ICPUSD\", variant { buy }, $(e8 600) : nat, $(e8 0.05) : nat, null)")
if echo "$OP" | grep -q ok; then ok "leveraged long staged (borrows the shortfall)"; else nok "openPosition" "$OP"; fi
fresh   # release the staged open
sleep 2 # one finalise beat — the release settles, the loan persists
# withdrawal (external flow out)
ua withdraw "(\"ICPUSD\", $(e8 75) : nat, \"replay-dest\")" >/dev/null 2>&1
sleep 3   # let any deferred releases settle
fresh

echo "── §2 drain the journal + capture queue ──"
tries=0
while [ $tries -lt 15 ]; do
  INFO=$(adm getCanisterInfo '()' --query | tr -d '_' )
  UNSHIPPED=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
  PENDINGJ=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+")
  [ "${UNSHIPPED:-1}" = "0" ] && [ "${PENDINGJ:-1}" = "0" ] && break
  sleep 3; tries=$((tries+1))
done
if [ "${UNSHIPPED:-1}" = "0" ] && [ "${PENDINGJ:-1}" = "0" ]; then
  ok "ledger journal + capture queue fully drained to the archive"
else nok "not drained" "unshipped=$UNSHIPPED journalPending=$PENDINGJ"; fi
ARCHIVED=$(echo "$INFO" | grep -oE "archivedEvents = [0-9]+" | grep -oE "[0-9]+")
if [ "${ARCHIVED:-0}" -ge 30 ]; then
  ok "workload produced a real tape ($ARCHIVED events archived)"
else nok "tape suspiciously small" "archived=$ARCHIVED"; fi

# Freeze the world so live balances can't move under the fold.
adm setTestTimersPaused '(true)' >/dev/null

echo "── §3 fold the tape → compare against every live balance ──"
adm adminReplayReset '()' >/dev/null
steps=0
while [ $steps -lt 20 ]; do
  ST=$(adm adminReplayStep '(20_000 : nat)' | tr -d '_\n' | tr -s ' ')
  echo "$ST" | grep -q "done = true" && break
  steps=$((steps+1))
done
if echo "$ST" | grep -q "done = true"; then ok "fold caught the tape (steps=$((steps+1)))"; else nok "fold never completed" "$ST"; fi
R=$(adm adminReplayReport '()' --query | tr -d '_\n' | tr -s ' ')
CHECKED=$(echo "$R" | grep -oE "accountsChecked = [0-9]+" | grep -oE "[0-9]+")
if echo "$R" | grep -q "mismatches = vec {}"; then
  ok "ZERO mismatches across $CHECKED accounts — the archive alone reproduces every balance"
else nok "LEDGER INCOMPLETE" "$(echo "$R" | head -c 400)"; fi
if [ "${CHECKED:-0}" -ge 10 ]; then
  ok "coverage is real ($CHECKED accounts incl. vault/treasury/insurance)"
else nok "too few accounts checked" "checked=$CHECKED"; fi
# The three claim ledgers reconcile the same way (shadow-diff completeness).
for L in debt lp ins; do
  if echo "$R" | grep -q "${L}Mismatches = vec {}"; then
    ok "${L} ledger folds exactly (zero mismatches)"
  else nok "${L} LEDGER INCOMPLETE" "$(echo "$R" | grep -oE "${L}Mismatches = vec \{[^}]*" | head -c 200)"; fi
done
LCHK=$(echo "$R" | grep -oE "lpChecked = [0-9]+" | grep -oE "[0-9]+")
ICHK=$(echo "$R" | grep -oE "insChecked = [0-9]+" | grep -oE "[0-9]+")
if [ "${LCHK:-0}" -ge 1 ] && [ "${ICHK:-0}" -ge 1 ]; then
  ok "claim coverage is real (lp=$LCHK ins=$ICHK live entries)"
else nok "a claim ledger had no live entries to check" "lp=$LCHK ins=$ICHK"; fi
# Debt may legitimately be ZERO live (the ladder-edge kill unwinds the borrow
# — itself a great fold test: +N then −N must net out). Coverage = the tape
# actually carried debt deltas, whatever their net.
ARCH_ID0=$(adm getCanisterInfo '()' --query | grep -oE 'archiveCanisterId = opt "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
# PAGE the tape: getEventsRange serves at most 200 rows per call, and the
# fee split (drain fix 4) journals an extra ledger row per fill, so the
# margin leg's debt rows now sit past the first page. LC_ALL=C + grep -a:
# the rows' prevHash blobs make grep treat the page as binary otherwise.
NDEBT=0
NARBFLOW=0
for OFF in 0 200 400 600 800; do
  PAGE=$(icp canister call --identity anonymous "$ARCH_ID0" getEventsRange "($OFF : nat, 200 : nat)" --query 2>/dev/null)
  N=$(echo "$PAGE" | LC_ALL=C grep -ao "debtDelta" | wc -l | tr -d ' ')
  NDEBT=$(( NDEBT + ${N:-0} ))
  # arbitrageur external flows land as semantic #deposit rows carrying its
  # principal — count those tagged with the wired arb id.
  if [ -n "${ARB:-}" ]; then
    NA=$(echo "$PAGE" | LC_ALL=C grep -ao "$ARB" | wc -l | tr -d ' ')
    NARBFLOW=$(( NARBFLOW + ${NA:-0} ))
  fi
  # short page = end of tape
  ROWS=$(echo "$PAGE" | LC_ALL=C grep -ao "seq = " | wc -l | tr -d ' ')
  [ "${ROWS:-0}" -lt 200 ] && break
done
if [ "${NDEBT:-0}" -ge 1 ]; then
  ok "debt deltas flowed through the tape ($NDEBT rows — borrow and/or unwind)"
else nok "no debt activity captured" "the margin leg produced no debtDelta rows"; fi
if [ "${NARBFLOW:-0}" -ge 3 ]; then
  ok "arbitrageur external flows recorded on the tape ($NARBFLOW rows — fund + both import legs + deltas)"
else nok "arb flows missing from the tape" "expected >=3 arb-attributed rows, got ${NARBFLOW:-0}"; fi

echo "── §4 the ledger rides the tamper-evidence chain ──"
ARCH_ID=$(adm getCanisterInfo '()' --query | grep -oE 'archiveCanisterId = opt "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
if [ -n "$ARCH_ID" ]; then
  V=$(icp canister call --identity anonymous "$ARCH_ID" verifyChain '(0 : nat, 10_000 : nat)' --query | tr -d '_\n' | tr -s ' ')
  if echo "$V" | grep -q "ok = true"; then
    ok "mixed semantic+delta tape hash-chains cleanly ($(echo "$V" | grep -oE 'checked = [0-9]+'))"
  else nok "chain broken with delta events" "$V"; fi
else nok "no archive spawned" "?"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
