#!/bin/bash
# W4 batch 3 — the season boundary keeps the prior season's ledger alive:
#   §1 W4-14: a pre-reset user's archived history is still readable BY THE
#      SAME segment id after the reset (pre-fix: {events=[]; total=0} as a
#      success for the entire prior season)
#   §2 W4-15: the detached segment stays in the funding/observation set —
#      a fuel pass observes it and the chain table shows it (role "season")
#   §3 W4-15: adminFundCanister can fund an arbitrary segment id
#
# Needs #dev. ⚠️ Runs resetSeason — reseed afterwards.

set -u
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
U=$(mkid w43_u)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm setTestTimersPaused '(false)' >/dev/null 2>&1

# History for the user + a live archive.
adm setTestBalance "(principal \"$U\", \"ICPUSD\", 10_000_000_000 : nat)" >/dev/null
i=0; while [ $i -lt 6 ]; do icp canister call --identity w43_u backend withdraw '("ICPUSD", 100_000_000 : nat, "w43")' >/dev/null 2>&1; i=$((i+1)); done
# drain so the reset gates pass
for i in $(seq 1 45); do
  INFO=$(adm getCanisterInfo '()' --query | tr -d '_')
  UNSH=$(echo "$INFO" | grep -oE "journalUnshipped = [0-9]+" | grep -oE "[0-9]+")
  JP=$(echo "$INFO" | grep -oE "ledgerJournalPending = [0-9]+" | grep -oE "[0-9]+")
  [ "${UNSH:-1}" = "0" ] && [ "${JP:-1}" = "0" ] && break
  sleep 2
done
RAW=$(adm getArchives '()' --query)
ACTIVE=$(echo "$RAW" | tr -d '_\n' | grep -oE 'canisterId = "[a-z0-9-]+"' | tail -1 | grep -oE '"[a-z0-9-]+"' | tr -d '"')
[ -n "$ACTIVE" ] || { echo "no archive to test against"; exit 1; }
PRE=$(icp canister call --identity w43_u backend getMyArchivedEvents "(principal \"$ACTIVE\", 0 : nat, 50 : nat)" --query 2>&1 | tr -d '_\n')
PRE_TOTAL=$(echo "$PRE" | grep -oE "total = [0-9]+" | grep -oE "[0-9]+")
[ "${PRE_TOTAL:-0}" -gt 0 ] && ok "pre-reset history present (total=$PRE_TOTAL on $ACTIVE)" || nok "no pre-reset history" "$PRE_TOTAL"

R=$(adm resetSeason '()')
echo "$R" | grep -q "ok" && ok "season reset completed" || nok "reset refused" "$(echo "$R" | head -c 150)"

echo "── §1 W4-14: prior-season history still readable ──"
POST=$(icp canister call --identity w43_u backend getMyArchivedEvents "(principal \"$ACTIVE\", 0 : nat, 50 : nat)" --query 2>&1 | tr -d '_\n')
POST_TOTAL=$(echo "$POST" | grep -oE "total = [0-9]+" | grep -oE "[0-9]+")
if [ "${POST_TOTAL:-0}" = "${PRE_TOTAL:-x}" ]; then
  ok "same events readable after the reset (total=$POST_TOTAL) — the season registry resolves"
else nok "prior season answered empty-as-success (the finding)" "pre=$PRE_TOTAL post=$POST_TOTAL"; fi

echo "── §2 W4-15: the detached segment stays observed + funded ──"
adm adminRunArchiveFuelPass '()' >/dev/null 2>&1
CH=$(adm getArchiveChain '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$CH" | grep -q "role = \"season\""; then ok "chain table lists the prior season's segments"; else nok "season rows missing" "$(echo "$CH" | head -c 200)"; fi
if echo "$CH" | grep -qE "role = \"season\"[^}]*cycles = opt"; then
  ok "the fuel pass observed the detached segment (cycles present)"
else nok "detached segment unobserved (the funding set lost it — the finding)" "$(echo "$CH" | head -c 300)"; fi

echo "── §3 W4-15: arbitrary-segment rescue funding ──"
R=$(adm adminFundCanister "(principal \"$ACTIVE\", 1_000_000_000_000 : nat)")
if echo "$R" | tr -d '_' | grep -qE "ok = [0-9]+"; then ok "adminFundCanister deposited into the detached segment"; else nok "rescue funding failed" "$(echo "$R" | head -c 150)"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_w4_batch3 ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_w4_batch3 ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
