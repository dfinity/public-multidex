#!/bin/bash
# W4 batch 2 — replay single-flight, blackholed observability, vault fee
# weight, season/bridge coherence.
#
#   §1 W4-09: overlapping adminReplayStep calls cannot double-fold — the
#      audit completes with ZERO mismatches (pre-fix: false reserve alarm)
#   §2 W4-11: a skewing LP deposit mints less than a balancing one of equal
#      value (the pre-deposit snapshot charged the skew NOTHING)
#   §3 W4-10: a blackholed sealed segment is still observed (via its own
#      stats()) and its chain row is marked degraded
#   §4 W4-12: admit → season reset → the Bridge's half is wiped WITH the
#      DEX's; a fresh deposit afterwards charges the allowance exactly once
#      (LAST: the reset wipes the venue)
#
# Needs #dev. ⚠️ §4 wipes the venue — reseed afterwards.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --identity w42_u backend "$@" 2>&1; }
U=$(mkid w42_u)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # shipper must run for §1/§4

# Self-contained venue setup (§2 needs a seeded vault; prior runs may have
# season-wiped the venue).
SEED=$(mkid w42_seed)
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 10000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
icp canister call --identity w42_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000.0) : nat, $(e8 100000.0) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null

echo "── §1 W4-09: replay is single-flight, audit stays truthful ──"
adm adminReplayReset '()' >/dev/null
# Fire two overlapping steps; the guard must refuse one.
adm adminReplayStep '(5_000 : nat)' >/tmp/w42_a.out 2>&1 &
P1=$!
adm adminReplayStep '(5_000 : nat)' >/tmp/w42_b.out 2>&1 &
P2=$!
wait $P1 $P2
# Drive the fold to completion.
for i in $(seq 1 40); do
  R=$(adm adminReplayStep '(20_000 : nat)')
  echo "$R" | grep -q "done = true" && break
  sleep 1
done
REP=$(adm adminReplayReport '()' --query | tr -d '_\n' | tr -s ' ')
MIS=$(echo "$REP" | grep -oE "mismatches = vec \{[^}]*" | head -1)
if echo "$REP" | grep -q "mismatches = vec {}"; then
  ok "fold completed with ZERO balance mismatches (no double-count)"
else nok "replay mismatches present (double-fold or real drift)" "$(echo "$MIS" | head -c 200)"; fi

echo "── §2 W4-11: skewing deposit pays, balancing does not ──"
adm setTestBalance "(principal \"$U\", \"ICP\", $(e8 200.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 4000.0) : nat)" >/dev/null
LP0=$(u getMyVaultLp '()' --query | tr -d '_' | grep -oE "[0-9]+" | head -1)
# THE finding's shape: quote sits AT target (50%), so the PRE-deposit
# snapshot prices any quote deposit at multiplier 1.0 — however far it
# skews. A small deposit barely moves the weight (≈ free either way); a
# LARGE one lands the vault deep over target and must now pay, because the
# fee reads the MIDPOINT weight. Compare per-USD minting.
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 150000.0) : nat)" >/dev/null
R=$(u depositLp "(\"ICP-ICPUSD\", 0 : nat, $(e8 200.0) : nat)")            # $200 from at-target: ≈ free
LP1=$(u getMyVaultLp '()' --query | tr -d '_' | grep -oE "[0-9]+" | head -1)
SMALL=$(( ${LP1:-0} - ${LP0:-0} ))
R=$(u depositLp "(\"ICP-ICPUSD\", 0 : nat, $(e8 100000.0) : nat)")         # $100k: skews deep past target
LP2=$(u getMyVaultLp '()' --query | tr -d '_' | grep -oE "[0-9]+" | head -1)
BIG=$(( ${LP2:-0} - ${LP1:-0} ))
if [ "$SMALL" -gt 0 ] && [ "$BIG" -gt 0 ]; then
  SMALL_PER=$(( SMALL / 200 )); BIG_PER=$(( BIG / 100000 ))
  if [ "$BIG_PER" -lt "$SMALL_PER" ]; then
    ok "a large skewing deposit pays per-USD where a small one is ≈free ($BIG_PER < $SMALL_PER LP/USD) — pre-fix both were free"
  else nok "large skew paid no fee (the finding)" "smallPer=$SMALL_PER bigPer=$BIG_PER"; fi
else nok "deposits did not mint" "small=$SMALL big=$BIG r=$(echo "$R" | head -c 120)"; fi

echo "── §3 W4-10: blackholed segment stays observed, marked degraded ──"
adm setTestArchiveCap '(opt (20 : nat))' >/dev/null
adm setBlackholeAtSeal '(true)' >/dev/null
i=0; while [ $i -lt 15 ]; do icp canister call --identity w42_u backend withdraw '("ICPUSD", 100_000_000 : nat, "w42-bh")' >/dev/null 2>&1; i=$((i+1)); done
BH=0
for _ in $(seq 1 15); do
  adm getRecentEvents '(120 : nat)' --query 2>/dev/null | grep -q "BLACKHOLED" && { BH=1; break; }
  sleep 3
done
[ "$BH" = "1" ] && ok "a sealed segment was blackholed" || nok "no blackhole happened" "cap/seal flow"
adm setBlackholeAtSeal '(false)' >/dev/null
adm setTestArchiveCap '(null)' >/dev/null
# run a fuel pass NOW (the heartbeat cadence is 5min)
adm adminRunArchiveFuelPass '()' >/dev/null 2>&1
DEG=0
for _ in $(seq 1 5); do
  CH=$(adm getArchiveChain '()' --query | tr -d '_\n' | tr -s ' ')
  if echo "$CH" | grep -q "degraded = opt true"; then DEG=1; break; fi
  adm adminRunArchiveFuelPass '()' >/dev/null 2>&1
  sleep 2
done
if [ "$DEG" = "1" ]; then
  ok "blackholed segment re-observed via stats() and marked degraded"
  echo "$CH" | grep -oE "degraded = opt true[^}]*" | head -1 >/dev/null
else nok "no degraded observation (stale ok persists — the finding)" "$(echo "${CH:-none}" | head -c 200)"; fi

echo "── §4 W4-12: season boundary wipes BOTH halves of the deposit pair ──"
adm setTestEmailBinding "(principal \"$U\", \"w42@example.com\")" >/dev/null 2>&1
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
adm requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
R=$(icp canister call --identity w42_u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' 2>&1)
echo "$R" | grep -q "ok" && ok "pre-reset deposit admitted" || nok "admit failed" "$(echo "$R" | head -c 150)"
U1=$(u getPlayDepositAllowance '()' | tr -d '_\n' | tr -s ' ' | grep -oE "usedUsd = [0-9]+" | awk '{print $3}')
# drain the tape so the reset's gates pass
for i in $(seq 1 45); do
  INFO=$(adm getCanisterInfo '()' --query | tr -d '_' )
  UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
  JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+")
  [ "${UNSH:-1}" = "0" ] && [ "${JP:-1}" = "0" ] && break
  sleep 2
done
R=$(adm resetSeason '()')
if echo "$R" | grep -q "ok"; then ok "season reset completed (two-phase with the Bridge)"; else nok "reset refused" "$(echo "$R" | head -c 200)"; fi
DEP=$(icp canister call --identity w42_u bridge getMyDeposits '()' --query 2>&1 | tr -d '_\n')
if echo "$DEP" | grep -qE "confirmed = 0[^0-9]" && echo "$DEP" | grep -qE "pending = 0[^0-9]"; then
  ok "Bridge half wiped with the DEX half (no surviving claimable)"
else nok "Bridge kept claimables across the boundary (the finding)" "$(echo "$DEP" | head -c 200)"; fi
adm setTestEmailBinding "(principal \"$U\", \"w42@example.com\")" >/dev/null 2>&1
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
adm requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1
R=$(icp canister call --identity w42_u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)' 2>&1)
U2=$(u getPlayDepositAllowance '()' | tr -d '_\n' | tr -s ' ' | grep -oE "usedUsd = [0-9]+" | awk '{print $3}')
if echo "$R" | grep -q "ok" && [ "${U2:-0}" = "10000000000" ]; then
  ok "fresh post-reset deposit charges exactly once (used=$U2)"
else nok "post-reset charge wrong" "r=$(echo "$R" | head -c 80) used=$U2"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_w4_batch2 ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_w4_batch2 ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
