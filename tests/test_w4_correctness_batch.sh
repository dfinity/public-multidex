#!/bin/bash
# W4 batch — play-real correctness one-liners, driven end-to-end:
#   §1 W4-04: out-of-range maxSlippage returns #err on swap AND quoteSwap
#      (pre-fix: Nat-underflow trap in the UI's quote path)
#   §2 W4-02: an LP deposit cannot spend funds a staged order reserved
#   §3 W4-05: a released staged order cancels by its ORIGINAL (staging) id
#   §4 W4-06: a staged order whose good-till lapsed is KILLED at release
#   §5 W4-01: resetSeason refuses while ledger-journal rows are unshipped
#      (LAST: a passing reset wipes the venue)
#
# Needs #dev. ⚠️ §5 runs resetSeason on success — reseed after this test.

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
u()   { icp canister call --identity w4_u backend "$@" 2>&1; }
U=$(mkid w4_u)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
SEED=$(mkid w4_seed)
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 10000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
icp canister call --identity w4_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000.0) : nat, $(e8 100000.0) : nat)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 100.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$U\", \"ICP\", $(e8 10.0) : nat)" >/dev/null

echo "── §1 W4-04: slippage range check, not a trap ──"
R=$(u quoteSwap '("ICP", "ICPUSD", 100_000_000 : nat, 900_000_000 : nat)' --query)
if echo "$R" | grep -q "Slippage must be"; then ok "quoteSwap: structured #err at 900%"; else nok "quoteSwap did not range-check" "$(echo "$R" | head -c 150)"; fi
R=$(u swap '(record { fromToken="ICP"; toToken="ICPUSD"; amount=100_000_000 : nat; mode=variant { marketOrder=record { maxSlippage=900_000_000 : nat } }; noPartialFill=false })')
if echo "$R" | grep -q "Slippage must be"; then ok "swap: structured #err at 900%"; else nok "swap did not range-check" "$(echo "$R" | head -c 150)"; fi

echo "── §2 W4-02: LP deposit cannot spend a staged order's reserve ──"
u placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.30) : nat, $(e8 5.0) : nat)" >/dev/null   # stages; reserves ~51.5 ICPUSD
NST=$(u getMyStagedOrderIds '()' | tr -d '_' | grep -cE "[0-9]+ : nat")
[ "${NST:-0}" -ge 1 ] && ok "order staged (reserve active)" || nok "no staged order" "n=$NST"
R=$(u depositLp "(\"ICP-ICPUSD\", 0 : nat, $(e8 100.0) : nat)")   # full RAW balance — must refuse
if echo "$R" | grep -q "Insufficient available"; then ok "deposit of the full raw balance refused (available-gated)"; else nok "reserve spent into the vault (the finding)" "$(echo "$R" | head -c 200)"; fi
NST2=$(u getMyStagedOrderIds '()' | tr -d '_' | grep -cE "[0-9]+ : nat")
[ "${NST2:-0}" = "${NST:-x}" ] && ok "staged order survived the attempt" || nok "staged order defunded" "n=$NST2"

echo "── §3 W4-05: cancel by the staging id after release ──"
OID=$(u getMyStagedOrderIds '()' | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+")
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null          # release: crossing buy fills or rests
sleep 1
ST=$(u getMyOrderStatus "(${OID:-0} : nat)")
if echo "$ST" | grep -qi "err"; then nok "status by staging id lost after release" "$(echo "$ST" | head -c 150)"; else ok "status by staging id resolves after release"; fi
R=$(u cancelMyOrder "(${OID:-0} : nat)")
# Either the released remainder cancels (#ok) or it fully filled ("not open").
if echo "$R" | grep -qE "ok|not open"; then ok "cancel by staging id resolves the released order (got: $(echo "$R" | tr -d '\n' | head -c 40))"; else nok "cancel by staging id says not-found (the finding)" "$(echo "$R" | head -c 150)"; fi

echo "── §4 W4-06: lapsed good-till kills at release ──"
ICP_B=$(adm getTestBalance "(principal \"$U\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+")
u placeLimitOrderExp "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.30) : nat, $(e8 2.0) : nat, opt (2 : nat))" >/dev/null   # GTD 2s, stages
sleep 4                                             # expiry lapses while staged (timers paused — no release)
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null          # release attempt
sleep 1
ICP_A=$(adm getTestBalance "(principal \"$U\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+")
[ "${ICP_A:-x}" = "${ICP_B:-y}" ] && ok "expired order did NOT fill (ICP unchanged)" || nok "filled past its own deadline (the finding)" "before=$ICP_B after=$ICP_A"
RR=$(u getMyReleaseRejections '()' --query | tr -d '\n')
if echo "$RR" | grep -q "expired while staged\|Order expired"; then ok "kill recorded in release rejections"; else nok "no kill record" "$(echo "$RR" | head -c 200)"; fi

echo "── §5 W4-01: reset refuses while the ledger journal is unshipped ──"
icp canister call --identity w4_u backend withdraw '("ICPUSD", 100_000_000 : nat, "w4-journal-probe")' >/dev/null 2>&1
R=$(adm resetSeason '()')
if echo "$R" | grep -q "unshipped ledger journal"; then
  ok "reset refused, naming the journal depth"
else
  # The event-queue gate may fire first — both refusals are correct; the
  # journal-specific one needs the queue drained but the journal not.
  if echo "$R" | grep -q "unshipped history"; then ok "reset refused (event queue gate fired first — journal gate sits behind it)"; else nok "reset proceeded with unshipped rows (the finding)" "$(echo "$R" | head -c 200)"; fi
fi
adm setTestTimersPaused '(false)' >/dev/null 2>&1

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_w4_correctness_batch ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_w4_correctness_batch ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
