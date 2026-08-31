#!/bin/bash
# W3-04 — the Bridge's admission counter is write-ahead, so an upgrade landing
# in the await window can no longer double-charge the lifetime allowance.
#
# Pre-fix: devSimulateDeposit advanced `admittedUnits` and `l.pending` only in
# the continuation AFTER the DEX call. A lost continuation (upgrade mid-await)
# left the counter stale; the retry computed a DIFFERENT seq, the DEX's replay
# gate did not fire, and the allowance was debited twice. Write-ahead makes
# the post-upgrade state identical to a completed deposit, so:
#
#   §1 a normal deposit charges the allowance exactly once
#   §2 an upgrade between deposits changes nothing: the counter is
#      reproducible, the second deposit charges exactly its own value
#   §3 a DEX refusal (over-allowance) rolls BOTH write-aheads back —
#      pending and used are byte-identical before/after
#   §4 claim-side flow is untouched (confirm + claim still credit)
#
# Needs #dev. Uses a fresh identity; does not reset the venue.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
u() { icp canister call --identity bwa_u "$1" "${@:2}" 2>&1; }
U=$(mkid bwa_u)

used() { u backend getPlayDepositAllowance '()' | tr -d '_\n' | tr -s ' ' | grep -oE "usedUsd = [0-9]+" | awk '{print $3}'; }
pend() { u bridge getMyDeposits '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "asset = \"BTC\"[^}]*" | grep -oE "pending = [0-9]+" | awk '{print $3}'; }

# The deposit is valued at the venue mark — make BTC's live.
icp canister call --identity anonymous backend createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1
icp canister call --identity anonymous backend setAmmRefPrice '("BTC-ICPUSD", 10_000_000_000 : nat)' >/dev/null 2>&1
icp canister call --identity anonymous backend requoteAmm '("BTC-ICPUSD")' >/dev/null 2>&1

# Anti-Sybil: deposits need a verified binding — dev hook supplies one.
icp canister call --identity anonymous backend setTestEmailBinding "(principal \"$U\", \"bwa-test@example.com\")" >/dev/null 2>&1

echo "── §1 one deposit, one charge ──"
U0=$(used); [ -n "$U0" ] || U0=0
R=$(u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)')
echo "$R" | grep -q "ok" && ok "deposit admitted" || nok "deposit refused" "$R"
U1=$(used); P1=$(pend)
[ "${U1:-0}" -gt "${U0:-0}" ] && ok "allowance charged once (used $U0 → $U1)" || nok "allowance not charged" "u0=$U0 u1=$U1"
[ "${P1:-0}" = "100000000" ] && ok "pending credited (write-ahead visible)" || nok "pending wrong" "p1=$P1"

echo "── §2 upgrade between deposits: counter reproducible, no phantom charge ──"
icp canister install bridge --mode upgrade -y --identity anonymous >/dev/null 2>&1 \
  && ok "bridge upgraded in place" || nok "upgrade failed" "install error"
R=$(u bridge devSimulateDeposit '("BTC", 100_000_000 : nat)')
echo "$R" | grep -q "ok" && ok "post-upgrade deposit admitted" || nok "post-upgrade deposit refused" "$R"
U2=$(used); P2=$(pend)
D1=$((U1 - U0)); D2=$((U2 - U1))
[ "$D1" = "$D2" ] && ok "second charge equals the first exactly ($D2) — no double-charge, no skip" || nok "charge drifted across the upgrade" "d1=$D1 d2=$D2"
[ "${P2:-0}" = "200000000" ] && ok "pending accumulated exactly (2 × deposit)" || nok "pending wrong" "p2=$P2"

echo "── §3 DEX refusal rolls the write-aheads back ──"
R=$(u bridge devSimulateDeposit '("BTC", 100_000_000_000_000 : nat)')   # ≫ lifetime cap → DEX #err
if echo "$R" | grep -qi "err"; then ok "over-allowance deposit refused by the DEX"; else nok "giant deposit accepted?!" "$(echo "$R" | head -c 200)"; fi
U3=$(used); P3=$(pend)
[ "${U3:-x}" = "${U2:-y}" ] && ok "used byte-identical after refusal ($U3)" || nok "allowance moved on refusal" "u2=$U2 u3=$U3"
[ "${P3:-x}" = "${P2:-y}" ] && ok "pending byte-identical after refusal ($P3)" || nok "pending moved on refusal" "p2=$P2 p3=$P3"
R=$(u bridge devSimulateDeposit '("BTC", 50_000_000 : nat)')
echo "$R" | grep -q "ok" && ok "counter healthy after rollback (small deposit admits)" || nok "counter wedged" "$R"

echo "── §4 claim side untouched ──"
u bridge devConfirmDeposits '()' >/dev/null
R=$(u bridge claim '("BTC")')
echo "$R" | grep -q "ok" && ok "confirm + claim still credit" || nok "claim broke" "$(echo "$R" | head -c 200)"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_bridge_write_ahead ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_bridge_write_ahead ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
