#!/bin/bash
# W1-05 — load shedding never refuses the EXIT SET.
#
# inspect's shed verdict used to be caller-only: at any floor ≥ 1 a rank-0
# registered user was refused pre-consensus on EVERY update — including the
# exit methods, none of which is reachable by query — with no error the UI
# can classify and no retry into consensus. The fix exempts the exit set
# (cancel / close / unstake / withdraw) from the floor, method-scoped via
# the msg variant.
#
#   §1 a registered rank-0 user exists; the floor is forced to 4 (max)
#   §2 an ENTRY method (placeLimitOrder) is refused AT THE GATE
#   §3 all NINE exit methods reach their bodies (a body-level ok/#err,
#      never the gate refusal) — the W1-05 eight + repayPoolDebt (1788523828)
#   §4 whyAmIRefused agrees with the gate on BOTH halves: admittedNow = false
#      (order entry shed) AND exitsAdmitted = true (#55 — the exit set passes),
#      with exitMethods naming the ten
#   §5 floor restored → entry calls reach their bodies again
#
# State-light: no resetExchange, no seeding — safe against any #dev venue.
# Needs #dev (setTestShedFloor, addTestTokens).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --candid "$MDX_CANDID" --identity shed_u backend "$@" 2>&1; }
mdx_identity_new shed_u; U=$(principal_of shed_u)

# The gate refusal is a pre-consensus ingress reject; the agent surfaces it
# with wording distinct from any candid body reply. Everything body-level
# contains ok/err/record instead.
gate_refused() { echo "$1" | grep -qiE "refus|inspect|403"; }
body_reached() { ! gate_refused "$1" && echo "$1" | grep -qE "err|record|\(|[0-9]"; }

echo "── §1 register a rank-0 user, force the floor to 4 ──"
R=$(u addTestTokens '("ICPUSD", 100_000_000 : nat)')   # faucet registers the caller (dev)
if gate_refused "$R"; then nok "faucet call refused — cannot register" "$R"; else ok "shed_u registered via faucet"; fi
adm setTestShedFloor '(opt (4 : nat))' >/dev/null
WHY=$(u whyAmIRefused '()' --query | tr -d '\n' | tr -s ' ')
echo "$WHY" | grep -q "registered = true" && ok "whyAmIRefused: registered" || nok "user not registered" "$WHY"

echo "── §2 entry method refused at the gate ──"
R=$(u placeLimitOrder '("ICP-ICPUSD", variant { buy }, 1_000_000_000 : nat, 100_000_000 : nat)')
if gate_refused "$R"; then ok "placeLimitOrder refused pre-consensus at floor 4"; else nok "entry method was NOT shed" "$(echo "$R" | head -c 200)"; fi

echo "── §3 the ten exits reach their bodies at floor 4 ──"
try_exit() { # name candid-args
  local R; R=$(u "$1" "$2")
  if gate_refused "$R"; then nok "$1 refused at the gate (the finding, resurfaced)" "$(echo "$R" | head -c 150)"
  elif body_reached "$R"; then ok "$1 reached its body"
  else nok "$1 gave no classifiable reply" "$(echo "$R" | head -c 150)"; fi
}
try_exit cancelMyOrder        '(999_999_999 : nat)'
try_exit cancelAllMyOrders    '(null)'
try_exit closePosition        '(0 : nat, "ICP-ICPUSD", 5_000_000 : nat, null)'
try_exit withdrawMarginPool   '(0 : nat, 1 : nat)'
try_exit unstakeInsurance     '(1 : nat)'
try_exit withdrawLp           '(1 : nat)'
try_exit withdraw             '("ICPUSD", 1_000_000 : nat, "shed-exit-probe")'
try_exit cancelPoolOrder      '(0 : nat, 1 : nat)'
try_exit repayPoolDebt        '(0 : nat, "ICPUSD", 1 : nat)'
try_exit cancelStagedLpRequest '(999_999_999 : nat)'   # task 1788731609: the tenth exit — releases the owner's own staged-LP reservation

echo "── §4 the diagnostic agrees with the gate (#55: both halves) ──"
WHY=$(u whyAmIRefused '()' --query | tr -d '\n' | tr -s ' ')
echo "$WHY" | grep -q "admittedNow = false" && ok "whyAmIRefused: admittedNow = false under the floor (entry shed, as §2 saw)" || nok "diagnostic says entry admitted while the gate refused it" "$WHY"
echo "$WHY" | grep -q "exitsAdmitted = true" && ok "whyAmIRefused: exitsAdmitted = true under the floor (exits pass, as §3 saw)" || nok "diagnostic disagrees with the gate — exits passed in §3 but the diagnostic says refused (#55)" "$WHY"
EXIT_MISSING=""
for m in cancelMyOrder cancelAllMyOrders closePosition withdrawMarginPool unstakeInsurance withdrawLp withdraw cancelPoolOrder repayPoolDebt cancelStagedLpRequest; do
  echo "$WHY" | grep -q "\"$m\"" || EXIT_MISSING="$EXIT_MISSING $m"
done
[ -z "$EXIT_MISSING" ] && ok "whyAmIRefused: exitMethods names all ten exits" || nok "exitMethods is missing$EXIT_MISSING" "$WHY"

echo "── §5 floor restored → entry reaches the body ──"
adm setTestShedFloor '(null)' >/dev/null
R=$(u placeLimitOrder '("ICP-ICPUSD", variant { buy }, 1_000_000_000 : nat, 100_000_000 : nat)')
if gate_refused "$R"; then nok "entry still refused after floor restore" "$(echo "$R" | head -c 150)"; else ok "placeLimitOrder passes the gate again (body-level reply)"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_load_shed_exits ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_load_shed_exits ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
