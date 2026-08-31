#!/bin/bash
# W3-02 / W3-03 — the self-funding loop's failure classification and budget.
#
# Stage-2 used to treat every ledger-transfer catch identically: keep the
# debit, log one line, arm nothing — so an ambiguous transport failure let
# the trigger debit ANOTHER tranche every cooldown window, unbounded, with
# no record to reconcile against.
#
#   §1 CLEAN reject (destination does not exist): the debit is re-credited
#      byte-identically and no interlock is armed
#   §2 AMBIGUOUS reject (ledger traps mid-call): debit KEPT, interlock
#      armed, further stage-2 spends refused until the operator clears it;
#      clearing re-enables and a healthy burn then completes
#   §3 the operator lever refuses when nothing is pending
#
# Does NOT resetExchange (touches only treasury ICP + fuel plumbing).
# Needs #dev (setTestBalance) and the fuel-mock canister.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
fm()  { icp canister call --identity anonymous fuel-mock "$@" 2>&1; }

FUEL_MOCK_ID=$(icp canister status fuel-mock --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
[ -n "$FUEL_MOCK_ID" ] || { echo "fuel-mock not deployed — run cold_start first"; exit 1; }
# "principal" renders QUOTED (name collides with the candid keyword); the
# value is the SECOND quoted token on the line (same shape as test_fuel_topup).
TREAS=$(adm getTreasury '()' --query | tr -d '\n' | grep -oE '"principal" = "[a-z0-9-]+"' | grep -oE '"[a-z0-9-]+"' | tail -1 | tr -d '"')
[ -n "$TREAS" ] || { echo "cannot resolve treasury"; exit 1; }
adm setTestBalance "(principal \"$TREAS\", \"ICP\", 1_000_000_000 : nat)" >/dev/null
treasIcp() { adm getFuelStatus '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "treasuryIcpE8s = [0-9]+" | awk '{print $3}'; }

echo "── §1 clean reject: re-credited, no interlock ──"
adm setFuelRoute '(opt principal "rrkah-fqaaa-aaaaa-aaaaq-cai", opt principal "rrkah-fqaaa-aaaaa-aaaaq-cai")' >/dev/null
B0=$(treasIcp)
R=$(adm burnTreasuryIcpToCycles '(150_000_000 : nat)')
if echo "$R" | grep -q "clean reject"; then ok "classified as a clean reject"; else nok "not classified" "$(echo "$R" | head -c 200)"; fi
B1=$(treasIcp)
[ "$B0" = "$B1" ] && ok "debit re-credited byte-identically ($B1)" || nok "balance changed on clean reject" "before=$B0 after=$B1"
FS=$(adm getFuelStatus '()' --query | tr -d '\n' | tr -s ' ')
echo "$FS" | grep -q "ambiguous = null" && ok "no interlock armed" || nok "interlock wrongly armed" "$FS"

echo "── §2 ambiguous reject: debit kept, interlock blocks, operator clears ──"
adm setFuelRoute "(opt principal \"$FUEL_MOCK_ID\", opt principal \"$FUEL_MOCK_ID\")" >/dev/null
fm setTrapTransfers '(true)' >/dev/null
R=$(adm burnTreasuryIcpToCycles '(150_000_000 : nat)')
if echo "$R" | grep -qi "ambiguous"; then ok "classified as ambiguous"; else nok "not classified" "$(echo "$R" | head -c 200)"; fi
B2=$(treasIcp)
if [ "$((B1 - B2))" = "150000000" ]; then ok "debit KEPT (insolvency-safe direction): $B1 → $B2"; else nok "debit not kept" "before=$B1 after=$B2"; fi
FS=$(adm getFuelStatus '()' --query | tr -d '_\n' | tr -s ' ')
echo "$FS" | grep -q "ambiguous = opt" && ok "interlock armed and visible in getFuelStatus" || nok "interlock missing" "$FS"
SPENT=$(echo "$FS" | grep -oE "spentTodayE8s = [0-9]+" | awk '{print $3}')
[ "${SPENT:-0}" -ge 150000000 ] && ok "daily counter tracks the kept debit ($SPENT e8s)" || nok "spend not counted" "$FS"
R=$(adm burnTreasuryIcpToCycles '(150_000_000 : nat)')
if echo "$R" | grep -q "AMBIGUOUS — reconcile"; then ok "second spend refused by the interlock"; else nok "re-entry not blocked (the finding)" "$(echo "$R" | head -c 200)"; fi
R=$(adm adminClearFuelAmbiguous '()')
echo "$R" | grep -q "cleared" && ok "operator lever clears (logged)" || nok "clear failed" "$R"
fm setTrapTransfers '(false)' >/dev/null
R=$(adm burnTreasuryIcpToCycles '(150_000_000 : nat)')
if echo "$R" | grep -q "ok"; then ok "healthy burn completes after the clear"; else nok "burn failed post-clear" "$(echo "$R" | head -c 200)"; fi

echo "── §3 the lever refuses when nothing is pending ──"
R=$(adm adminClearFuelAmbiguous '()')
echo "$R" | grep -q "no ambiguous" && ok "clear refuses with nothing recorded" || nok "vacuous clear accepted" "$R"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_autofuel_guards ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_autofuel_guards ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
