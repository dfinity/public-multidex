#!/bin/bash
# W2-03 — the immediate cross-swap's #err contract is literal: #err ⇒ nothing
# settled, and every settled fill reaches the tape.
#
# executeSwapCross (noPartialFill=true, the immediate two-leg path) used to
# settle the SELL leg, then `return #err` from two buy-side refusals below
# the settlement — no rollback, fill hooks (incl. the sole emitFillEvents
# call site) skipped. A caller retrying on #err double-sold, and settled
# fills never reached the hash-chained archive. The fix resolves the buy
# leg's liquidity/price BEFORE the sell commits.
#
#   §1 buy market has NO book liquidity → #err "No liquidity", and the
#      seller's balance is EXACTLY unchanged (pre-fix: sell settled first)
#   §2 buy market has a thin resting ask → #ok with fromAmount>0,
#      fullyFilled=false, and the sell fill is IN the event journal
#
# Timers paused throughout (journal stays inspectable). ⚠️ resetExchange.
# Needs #dev.

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
m1() { icp canister call --identity xsa_m1 backend "$@" 2>&1; }
s2() { icp canister call --identity xsa_s2 backend "$@" 2>&1; }
w()  { icp canister call --identity xsa_w  backend "$@" 2>&1; }
M1=$(mkid xsa_m1); S2=$(mkid xsa_s2); W=$(mkid xsa_w)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }

balN() { adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
SEED=$(mkid xsa_seed)
setup_pool() { # market token ref base quote requote?
  adm createAmmPool "(\"$1\")" >/dev/null 2>&1
  adm setAmmConfig "(\"$1\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
  adm setAmmRefPrice "(\"$1\", $(e8 $3) : nat)" >/dev/null
  adm setTestBalance "(principal \"$SEED\", \"$2\", $(e8 $4) : nat)" >/dev/null
  adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
  icp canister call --identity xsa_seed backend seedAmmPool "(\"$1\", $(e8 $4) : nat, $(e8 $5) : nat)" >/dev/null 2>&1
  adm enableAmm "(\"$1\", true)" >/dev/null
}
setup_pool "ICP-ICPUSD" "ICP" 10.0  10000.0 100000.0
setup_pool "BTC-ICPUSD" "BTC" 100.0  1000.0 100000.0
# Requote ONLY the sell market: the buy market's book must stay empty for §1
# (a requote would lay AMM quotes on it and defeat the no-liquidity case).
adm requoteAmm '("ICP-ICPUSD")' >/dev/null

adm setTestBalance "(principal \"$M1\", \"ICPUSD\", $(e8 1000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$W\", \"ICP\", $(e8 3.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S2\", \"BTC\", $(e8 1.0) : nat)" >/dev/null

echo "── setup: passive bid rests on the sell market ──"
m1 placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.90) : nat, $(e8 5.0) : nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null   # fresh fetch + requote → staged bid releases and RESTS
BOOK=$(adm getOrderBook '("ICP-ICPUSD")' | tr -d '_')
if echo "$BOOK" | grep -q "$(e8 9.90)"; then ok "maker bid resting at 9.90"; else nok "bid did not rest" "$(echo "$BOOK" | head -c 200)"; fi

echo "── §1 no buy-side liquidity → #err with NOTHING settled ──"
W_ICP_BEFORE=$(balN "$W" ICP)
R=$(w swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 3.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=true })")
if echo "$R" | grep -q "No liquidity on BTC-ICPUSD"; then ok "#err names the buy market"; else nok "wrong result" "$(echo "$R" | head -c 200)"; fi
W_ICP_AFTER=$(balN "$W" ICP)
if [ "${W_ICP_AFTER:-0}" = "${W_ICP_BEFORE:-1}" ]; then
  ok "#err ⇒ nothing settled (ICP balance byte-identical: $W_ICP_AFTER)"
else
  nok "sell leg settled under #err (the finding, resurfaced)" "before=$W_ICP_BEFORE after=$W_ICP_AFTER"
fi

echo "── §2 thin buy-side ask → honest partial #ok, fills on the tape ──"
s2 placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 101.0) : nat, $(e8 0.15) : nat)" >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 100.0) : nat)" >/dev/null
adm requoteAmm '("BTC-ICPUSD")' >/dev/null   # release S2's staged ask onto the book
R=$(w swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 3.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=true })" | tr -d '_\n' | tr -s ' ')
if echo "$R" | grep -q "ok = record"; then ok "swap returns #ok (settlement report)"; else nok "swap failed" "$(echo "$R" | head -c 250)"; fi
FROM=$(echo "$R" | grep -oE "fromAmount = [0-9]+" | grep -oE "[0-9]+")
if [ "${FROM:-0}" -gt 0 ]; then ok "fromAmount = $FROM (sell leg settled and reported)"; else nok "sell leg not reported" "$R"; fi
if echo "$R" | grep -q "fullyFilled = false"; then ok "fullyFilled = false (honest partial)"; else nok "partial not flagged" "$R"; fi
W_ICP_FINAL=$(balN "$W" ICP)
if [ "${W_ICP_FINAL:-999999999}" -lt "${W_ICP_AFTER:-0}" ]; then ok "balances reflect the sell"; else nok "balance unchanged on #ok" "final=$W_ICP_FINAL"; fi
EV=$(w getMyUnshippedEvents '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$EV" | grep -q 'fill' && echo "$EV" | grep -q 'ICP-ICPUSD'; then
  ok "the sell fill is in the event journal (emitFillEvents ran)"
else
  nok "settled fill missing from the tape" "$(echo "$EV" | head -c 250)"
fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_cross_swap_atomic ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_cross_swap_atomic ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
