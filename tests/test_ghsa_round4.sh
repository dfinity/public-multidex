#!/bin/bash
# Round-4 private advisories (W6-07) — both live findings pinned:
#   §1 GHSA-458x: depositLp(0,0) is REFUSED before any event is written —
#      the permanent tape gains no free row (was: #ok(0) + a chained
#      #lpDeposit row shipped to the archive)
#   §2 GHSA-5rcg: archiveExecute's chain walk is hop-bounded — a caller with
#      NO archived history gets an answer without the fan-out being O(chain)
#      (observable here as: the call still answers fast and well-formed on a
#      multi-segment chain; the structural hop cap is asserted statically)
# Needs #dev.
set -u
export PATH="$HOME/.local/bin:$PATH"
# run_all runs suites with CWD=tests/, so source greps must be REPO-relative.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINMO="$SCRIPT_DIR/../src/backend/main.mo"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
U=$(mkid g4_u)
adm setTestBalance "(principal \"$U\", \"ICPUSD\", 100_000_000 : nat)" >/dev/null

echo "── §1 GHSA-458x: (0,0) deposit refused, tape untouched ──"
N0=$(adm getRecentEvents '(200 : nat)' --query | grep -c "lpDeposit" || true)
R=$(icp canister call backend depositLp '("ICP-ICPUSD", 0 : nat, 0 : nat)' --identity g4_u 2>&1)
if echo "$R" | grep -q "Nothing to deposit"; then ok "zero-zero deposit refused loudly"; else nok "not refused (the finding)" "$(echo "$R" | tr -d '\n' | head -c 120)"; fi
N1=$(adm getRecentEvents '(200 : nat)' --query | grep -c "lpDeposit" || true)
[ "${N0:-0}" = "${N1:-x}" ] && ok "no #lpDeposit row written (tape count unchanged: $N1)" || nok "a permanent row was written for a no-op" "before=$N0 after=$N1"

# ── W3-10 (R3): (0,0) closed one point; (0,1) was one base unit away and
# behaved identically — transferred a unit, minted dust-or-zero, and STILL
# moved vaultCostBasis (corrupting gainLossPct for every LP). Entry doors
# now carry the order path's MIN_ORDER_ICPUSD floor (spend-all exempt); the
# zero-mint backstop unwinds the legs; exit doors stay uncapped. ──
# Fixture is venue-shape agnostic: first live pool wins; the insurance pool
# is bootstrapped past its own $100 first-stake floor so the DUST floor
# (not the first-stake floor) is what the dust case exercises.
MKT=$(adm getAmmPools '()' --query | grep -o 'marketId = "[^"]*"' | head -1 | cut -d'"' -f2)
[ -n "$MKT" ] || MKT="ICP-ICPUSD"
adm setTestBalance "(principal \"$U\", \"ICPUSD\", 15_400_000_000 : nat)" >/dev/null
R=$(icp canister call backend stakeInsurance '(15_000_000_000 : nat)' --identity g4_u 2>&1)
echo "$R" | grep -q "ok" || nok "insurance bootstrap stake failed (fixture)" "$(echo "$R" | tr -d '\n' | head -c 120)"
# On a fresh live-oracle venue the vaultPricesStale gate (main.mo) can refuse
# this with "LP deposit paused: ... awaiting circuit-breaker confirmation" —
# legitimate venue behavior while a pending price jump awaits its confirming
# oracle tick, NOT the R3 door. Bounded retry (~10s) while — and ONLY while —
# the refusal carries the stable "LP deposit paused" substring; any other
# outcome ((0,1) accepted, or refused for a different reason) exits the loop
# on that attempt and is asserted strictly below, so a genuine R3 regression
# still reds. Only THIS probe needs the retry: (0,0) is refused by "Nothing
# to deposit" BEFORE the pause gate, and stakeInsurance has no such gate.
R=""
for attempt in 1 2 3 4 5; do
  R=$(icp canister call backend depositLp "(\"$MKT\", 0 : nat, 1 : nat)" --identity g4_u 2>&1)
  echo "$R" | grep -q "LP deposit paused" || break
  sleep 2
done
if echo "$R" | grep -q "below the"; then ok "(0,1) dust deposit refused (min notional, W3-10)"; else nok "(0,1) accepted — the R3 door" "$(echo "$R" | tr -d '\n' | head -c 120)"; fi
N2=$(adm getRecentEvents '(200 : nat)' --query | grep -c "lpDeposit" || true)
[ "${N1:-0}" = "${N2:-x}" ] && ok "no tape row for the dust attempt (count $N2)" || nok "dust deposit wrote a permanent row" "before=$N1 after=$N2"
R=$(icp canister call backend stakeInsurance '(1_000 : nat)' --identity g4_u 2>&1)
if echo "$R" | grep -q "below the"; then ok "dust insurance stake refused (min notional, W3-10)"; else nok "dust stake accepted" "$(echo "$R" | tr -d '\n' | head -c 120)"; fi
AVAIL=$(icp canister call backend getMyAvailableBalance '("ICPUSD")' --query --identity g4_u 2>&1 | tr -d '_' | grep -oE '[0-9]+' | head -1)
R=$(icp canister call backend stakeInsurance "(${AVAIL:-1} : nat)" --identity g4_u 2>&1)
if echo "$R" | grep -q "ok"; then ok "spend-all stake ($AVAIL) EXEMPT from the floor (mirrors placeOrder)"; else nok "spend-all exemption broken (over-tightened floor)" "$(echo "$R" | tr -d '\n' | head -c 120)"; fi
# The four W3-10 guards, pinned structurally (fundMarginPool's floor shares
# the exact shape; a pool fixture here would cost more than it proves).
for needle in "Deposit value below the" "Stake below the" "Funding below the" "mint 0 LP shares"; do
  if grep -qF "$needle" "$MAINMO"; then ok "guard present: ${needle} [structure pin]"; else nok "guard missing" "$needle"; fi
done

echo "── §2 GHSA-5rcg: sparse-history caller is hop-bounded ──"
# structural pin: the exit is no longer the bare conjunction
if grep -q "ARCHIVE_MAX_HOPS" "$MAINMO" && grep -q "hops >= ARCHIVE_MAX_HOPS" "$MAINMO"; then
  ok "hop budget present at the chain walk [structure pin]"
else nok "hop budget missing" "the conjunction exit is the only one again"; fi
# behavioural: an identity with zero archived history still gets a well-formed answer
Q='{"entity":"userEvent","limit":5}'
R=$(icp canister call backend archiveExecute "(\"$Q\")" --identity g4_u --query 2>&1)
if echo "$R" | grep -qE "rows|ok|vec"; then ok "no-history caller answered well-formed (no unbounded walk trap)"; else nok "archiveExecute failed for a fresh caller" "$(echo "$R" | tr -d '\n' | head -c 140)"; fi

echo ""
if [ $fail -eq 0 ]; then echo -e "${GREEN}PASS: test_ghsa_round4 ($pass assertions)${NC}"; exit 0
else echo -e "${RED}FAIL: test_ghsa_round4 ($fail of $((pass+fail)) failed)${NC}"; exit 1; fi
