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
# ⚠️ Calls resetExchange — the wipe clears EVERY AMM pool (performWorldWipe's
# Map.clear(pools)) and this suite recreates only ICP-ICPUSD, so the venue is
# left with ONE enabled pool: a later suite that needs a mark on BTC/ETH/SOL
# must provision it itself (the 1788556083 self-provision class) or reseed.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
mdx_identity_new rp_a; A=$(principal_of rp_a); mdx_identity_new rp_b; B=$(principal_of rp_b); mdx_identity_new rp_seed; SEED=$(principal_of rp_seed)
ua() { icp canister call --candid "$MDX_CANDID" --identity rp_a backend "$@" 2>&1; }
ub() { icp canister call --candid "$MDX_CANDID" --identity rp_b backend "$@" 2>&1; }

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
# The wipe RESETS the tape (seq 0; the old archive is deleted and a fresh one
# spawned on the first ship) and reopens it with one genesis #delta per
# surviving (user, token) balance — resetExchange KEEPS wallets, and every
# suite that ever ran here minted identities into registeredUsers, so on a
# long-lived venue that block runs to THOUSANDS of rows (2153 on a seat venue
# with 3177 registered users; a few dozen after a cold_start). §3 must scan
# THIS RUN'S rows wherever the genesis block pushed them: let it drain and
# ship, then anchor the scan at the shipped extent (archivedEvents ==
# shippedSeq == the next seq the workload writes). A fixed window from seq 0
# ended inside the genesis block and reported the run's debtDelta / arb rows
# "missing" while they sat 1200 seqs further on (task 1788657132).
TAPE0=0
tries=0
while [ $tries -lt 20 ]; do
  INFO0=$(adm getCanisterInfo '()' --query | tr -d '_')
  U0=$(echo "$INFO0" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
  P0=$(echo "$INFO0" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+")
  if [ "${U0:-1}" = "0" ] && [ "${P0:-1}" = "0" ]; then
    TAPE0=$(echo "$INFO0" | grep -oE "archivedEvents = [0-9]+" | grep -oE "[0-9]+"); break
  fi
  sleep 3; tries=$((tries+1))
done
echo "  (genesis re-baseline shipped: the run's rows start at seq ${TAPE0:-0})"

echo "── §1 mixed workload (every leg journals by construction) ──"
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\",    $(e8 5000)  : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 15000) : nat)" >/dev/null
adm setTestBalance "(principal \"$A\",    \"ICP\",    $(e8 500)   : nat)" >/dev/null
adm setTestBalance "(principal \"$A\",    \"ICPUSD\", $(e8 5000)  : nat)" >/dev/null
adm setTestBalance "(principal \"$B\",    \"ICPUSD\", $(e8 5000)  : nat)" >/dev/null
mdx_lp_deposit rp_seed "ICP-ICPUSD" "$(e8 5000)" "$(e8 15000)" >/dev/null 2>&1
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
# LP round-trip (staged doors since apiVersion 6.0.0 — the helper stages,
# re-stamps and drives the settlement, whose #lpDeposit / #lpWithdraw rows
# are what the replay folds)
mdx_lp_deposit rp_a "ICP-ICPUSD" "$(e8 50)" "$(e8 150)" >/dev/null 2>&1
mdx_lp_withdraw rp_a "$(e8 20)" >/dev/null 2>&1
# insurance round-trip
ub stakeInsurance "($(e8 200) : nat)" >/dev/null 2>&1
# H-35: a fresh stake is locked for 10 min; the #dev re-stamp hook crosses the
# cooldown so the unstake leg lands on the tape (the replay fold covers both).
adm setTestInsuranceStakedAt "(principal \"$B\", 1 : int)" >/dev/null 2>&1 || true
ub unstakeInsurance "($(e8 50) : nat)" >/dev/null 2>&1
# arbitrageur external-market flows (venue-minted synthetic supply): fund the
# arb, then import base at the mark. fundArbitrageur + both legs of the import
# land on the permanent tape as semantic #deposit/#withdrawal rows (attributed
# to the arb in verify_ledger.mjs --fold), so the ledger accounts for the mint
# rather than reading it as a break. We wire a CALLABLE test identity as the
# arbitrageur (extMarketSwap is caller-gated to the wired principal); the real
# canister-driven import/export path is covered by test_arbitrage.sh.
mdx_identity_new rp_arb; ARB=$(principal_of rp_arb)
# H-30: a VIRGIN principal reaches only the pre-registration set at inspect —
# extMarketSwap from an unregistered arb identity was refused pre-consensus
# ("canister_inspect_message explicitly refused message", 5/5 attempts) and
# the arb rows §3 counts never landed. setTestBalance(…, 0) registers it on
# every non-production posture (the 1788519160 shape); fundArbitrageur
# credits the arb but does not register it.
adm setTestBalance "(principal \"$ARB\", \"ICPUSD\", 0 : nat)" >/dev/null 2>&1 || true
adm setArbitrageur "(principal \"$ARB\")" >/dev/null 2>&1
adm fundArbitrageur "($(e8 3000) : nat)" >/dev/null 2>&1
# import 100 ICP at mark $3 → arb pays ICPUSD (withdrawal), receives ICP (deposit).
# Retry with a freshly-stamped mark each attempt: with timers running the
# heartbeat can age the mark past the staleness gate between our fresh() and
# the call — exactly what the real arb canister rides out by re-ticking.
IMP=""
for attempt in 1 2 3 4 5; do
  fresh
  IMP=$(icp canister call --candid "$MDX_CANDID" --identity rp_arb backend extMarketSwap "(\"ICP\", variant { importBase }, $(e8 100) : nat, null)" 2>&1)
  echo "$IMP" | grep -q "ok = " && break
  sleep 1
done
echo "$IMP" | grep -q "ok = " && echo "  (arb imported 100 ICP at the mark)" || echo "  (arb import skipped: $(echo "$IMP" | tr -d '\n' | head -c 100))"
# margin: fund a pool, open a leveraged long, leave it OPEN — live pool debt
# and pool-principal balances must reconcile too (they replay raw).
# H-34 / D5 (d): the leverage is borrowed AT THE FILL, per slice, for exactly
# that slice's shortfall — a staged or resting entry holds no debt, so the tape
# carries debtDelta rows only if a FILL exceeds the pool's own $1000. The
# recreated ICP-ICPUSD pool quotes its DEFAULT dust ladder (quoteDepthBase
# 0.05 ICP × 3 levels; seedAmmPool above is refused on a used venue's vault
# concentration cap — resetExchange keeps wallets, the AMM's included), so a
# release against the AMM alone fills ≈0.15 ICP (≈$0.45), borrows nothing and
# the fold's debt coverage reads zero. The counter-order is a resting USER ask
# sized past the pool's cash: 400 ICP at the mark = $1200, so the first slice
# borrows ≈$200 — inside H-05's release clamp (a $1000 pool at ICP LTV 0.80
# and the 5 % ceiling clears ≈650 ICP) and the vault's 0.5× lending cap.
mdx_identity_new rp_mk; MK=$(principal_of rp_mk)
um() { icp canister call --candid "$MDX_CANDID" --identity rp_mk backend "$@" 2>&1; }
adm setTestBalance "(principal \"$MK\", \"ICP\", $(e8 1000) : nat)" >/dev/null
MKR=$(um placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 3) : nat, $(e8 400) : nat)")
if mdx_ok "$MKR"; then ok "maker ask staged (400 ICP @ \$3 — the leveraged long's counter-order)"; else nok "maker ask" "$MKR"; fi
fresh   # release the ask so it RESTS on the book (the sealed gate: price postdates entry)
PIDR=$(ua createMarginPool '("replay pool", false)' | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "$PIDR" ]; then ok "margin pool created (id=$PIDR)"; else nok "createMarginPool failed" "?"; fi
FM=$(ua fundMarginPool "($PIDR, $(e8 1000) : nat)")
if mdx_ok "$FM"; then ok "pool funded \$1000"; else nok "fundMarginPool" "$FM"; fi
OP=$(ua openPosition "($PIDR, \"ICP-ICPUSD\", variant { buy }, $(e8 600) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$OP"; then ok "leveraged long staged (the shortfall is borrowed at the fill — H-34)"; else nok "openPosition" "$OP"; fi
fresh   # release the staged open: it walks the resting ask, and the borrow happens HERE
sleep 2 # one finalise beat — the release settles, the loan persists
POS=$(ua getMyPositions '()' --query | tr -d '_\n' | tr -s ' ')
PSZ=$(echo "$POS" | grep -oE 'size = -?[0-9]+' | head -1 | grep -oE '[0-9]+$')
if [ "${PSZ:-0}" -ge "$(e8 400)" ]; then
  ok "the leveraged long FILLED past the pool's own cash (size=$(awk -v s="$PSZ" 'BEGIN{printf "%.2f", s/100000000}') ICP ≥ 400)"
else nok "margin leg did not fill past the pool's cash — nothing borrowed, no debtDelta to fold" "size=${PSZ:-0} positions=$(echo "$POS" | head -c 240)"; fi
# getMyMarginPools is the owner's view (one record per pool, `id` first, its
# `health` later in the same record): strip up to THIS pool's id, then the
# first debtUsd is its own.
PDEBT=$(ua getMyMarginPools '()' --query | tr -d '_\n' | tr -s ' ' | sed "s/.*id = $PIDR : nat;//" | grep -oE 'debtUsd = [0-9]+' | head -1 | grep -oE '[0-9]+$')
if [ "${PDEBT:-0}" -gt 0 ]; then
  ok "borrow-at-fill landed: pool debt \$$(awk -v d="$PDEBT" 'BEGIN{printf "%.2f", d/100000000}') > 0 (live for the fold)"
else nok "pool carries no debt after the fill" "debtUsd=${PDEBT:-0}"; fi
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
DCHK=$(echo "$R" | grep -oE "debtChecked = [0-9]+" | grep -oE "[0-9]+")
if [ "${LCHK:-0}" -ge 1 ] && [ "${ICHK:-0}" -ge 1 ] && [ "${DCHK:-0}" -ge 1 ]; then
  ok "claim coverage is real (lp=$LCHK ins=$ICHK debt=$DCHK live entries)"
else nok "a claim ledger had no live entries to check" "lp=$LCHK ins=$ICHK debt=$DCHK"; fi
# H-34: the open long's debt is LIVE (borrowed at its fill, never unwound —
# there is no idle pre-borrow to repay any more), so the tape must carry the
# borrow's debtDelta row(s). Coverage = at least one such row, whatever the net.
ARCH_ID0=$(adm getCanisterInfo '()' --query | grep -oE 'archiveCanisterId = opt "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
# PAGE the tape from the run's first seq (TAPE0, anchored above once the
# wipe's genesis block had shipped) to its END — the short page — never a
# fixed window from seq 0: getEventsRange serves at most 200 rows per call,
# the fee split (drain fix 4) journals an extra ledger row per fill, and the
# genesis block in front of the run grows with every identity the corpus ever
# registered on this venue. The page cap only bounds a runaway (one run
# writes ~110 rows); hitting it is a finding of its own, asserted below.
# LC_ALL=C + grep -a: the rows' prevHash blobs make grep treat the page as
# binary otherwise.
NDEBT=0
NARBFLOW=0
OFF=${TAPE0:-0}; PAGES=0; TAPE_END=0
while [ $PAGES -lt 50 ]; do
  PAGE=$(icp canister call --identity anonymous "$ARCH_ID0" getEventsRange "($OFF : nat, 200 : nat)" --query 2>/dev/null)
  PAGES=$((PAGES+1))
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
  if [ "${ROWS:-0}" -lt 200 ]; then TAPE_END=1; break; fi
  OFF=$((OFF+200))
done
if [ "$TAPE_END" = "1" ]; then
  ok "scanned the run's rows to the tape's end (from seq $TAPE0, $PAGES page(s))"
else nok "scan never reached the tape's end" "50 full pages from seq $TAPE0 — the row counts below are of a prefix"; fi
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
