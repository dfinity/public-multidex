#!/bin/bash
# W1-04 / W3-01 — owner-keyed staged indexes stay consistent, and the
# soft-lock read is O(log n) instead of O(global staged).
#
# cancelAllUserOrders (liquidation H2) and softLockedReserved (margin
# valuations, ×5 per health check) both used to scan the ENTIRE
# pendingMatches / deferredExecs / deferredSwaps maps. They now read
# owner-keyed transient indexes plus a per-(owner, token) accumulator,
# maintained in the map chokepoints and rebuilt in the actor init block.
# getStagedIndexAudit is the drift oracle: it recomputes everything the
# slow way and diffs, and it measures indexed vs recomputed read cost with
# the IC performance counter.
#
#   §1 stage a mix (limit buys, crossing sells, a cross-swap) → audit
#      consistent, live counts match
#   §2 cancel one after the commit window → audit consistent, count drops
#   §3 release everything (fresh fetch + requote both markets) → all
#      staged state drains, accumulator empty, audit consistent
#   §4 with TIMERS RUNNING, newly staged state drains through the same
#      chokepoints (GEPTOR release or expiry sweep) → audit consistent
#   §5 stage 25 entries and RECORD the read costs: the indexed soft-lock
#      read must be cheaper than the recomputed full scan (the number the
#      next report diffs against)
#
# Timers paused except §4. ⚠️ Calls resetExchange. Needs #dev.

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
ua() { icp canister call --identity sidx_a backend "$@" 2>&1; }
ub() { icp canister call --identity sidx_b backend "$@" 2>&1; }
A=$(mkid sidx_a); B=$(mkid sidx_b)

# The sim must be dead (it would stage/trade underneath the counts).
# PID-file stopper only — never a pattern kill (see scripts/lib/bots.sh).
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }

AUDIT=""
audit() { AUDIT=$(adm getStagedIndexAudit '()' --query | tr -d '_\n' | tr -s ' '); }
afield() { echo "$AUDIT" | grep -oE "$1 = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
assert_consistent() {
  audit
  if echo "$AUDIT" | grep -q 'consistent = true'; then ok "$1: audit consistent"
  else nok "$1: audit INCONSISTENT" "$(echo "$AUDIT" | head -c 300)"; fi
}

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
setup_pool() { # market token ref baseAmt quoteAmt
  adm createAmmPool "(\"$1\")" >/dev/null 2>&1
  adm setAmmConfig "(\"$1\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
  adm setAmmRefPrice "(\"$1\", $(e8 $3) : nat)" >/dev/null
  adm setTestBalance "(principal \"$SEED\", \"$2\", $(e8 $4) : nat)" >/dev/null
  adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
  icp canister call --identity sidx_seed backend seedAmmPool "(\"$1\", $(e8 $4) : nat, $(e8 $5) : nat)" >/dev/null 2>&1
  adm enableAmm "(\"$1\", true)" >/dev/null
  adm requoteAmm "(\"$1\")" >/dev/null
}
SEED=$(mkid sidx_seed)
setup_pool "ICP-ICPUSD" "ICP" 10.0  10000.0 100000.0
setup_pool "BTC-ICPUSD" "BTC" 100.0  1000.0 100000.0
adm setTestBalance "(principal \"$A\", \"ICPUSD\", $(e8 10000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$B\", \"ICP\", $(e8 100.0) : nat)" >/dev/null

echo "── §1 stage a mix; audit ──"
ua placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.30) : nat, $(e8 2.0) : nat)" >/dev/null
ua placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.25) : nat, $(e8 1.0) : nat)" >/dev/null
ua placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.28) : nat, $(e8 1.5) : nat)" >/dev/null
# Order VALUE must clear the 10-ICPUSD minimum (price × qty ≥ 10).
ub placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 9.70) : nat, $(e8 2.0) : nat)" >/dev/null
ub placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 9.75) : nat, $(e8 1.5) : nat)" >/dev/null
SW=$(ub swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 20.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })")
echo "$SW" | grep -q "swapOrderId = opt" && ok "cross-swap staged" || nok "swap did not stage" "$SW"
assert_consistent "§1"
EX=$(afield execLive); SWL=$(afield swapLive)
[ "$EX" = "5" ] && ok "execLive = 5" || nok "execLive" "got $EX"
[ "$SWL" = "1" ] && ok "swapLive = 1" || nok "swapLive" "got $SWL"

echo "── §2 cancel one after the 3s commit window ──"
sleep 4
OID=$(ua getMyStagedOrderIds '()' | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+")
CR=$(ua cancelMyOrder "(${OID:-0} : nat)")
echo "$CR" | grep -q "ok" && ok "cancelMyOrder(${OID:-?})" || nok "cancel refused" "$CR"
assert_consistent "§2"
EX=$(afield execLive)
[ "$EX" = "4" ] && ok "execLive = 4 after cancel" || nok "execLive after cancel" "got $EX"

echo "── §3 release everything (fresh fetch + requote, both markets) ──"
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 100.0) : nat)" >/dev/null
adm requoteAmm '("BTC-ICPUSD")' >/dev/null
# With timers paused the swap sweep never fires on its own — run it by hand
# now that BOTH legs are fresh (same recipe as test_cross_swap.sh §3).
adm adminRunDeferredSwaps "()" >/dev/null 2>&1
assert_consistent "§3"
EX=$(afield execLive); SWL=$(afield swapLive); ACC=$(afield accEntries)
[ "$EX" = "0" ] && ok "all staged execs drained" || nok "execs left" "got $EX"
[ "$SWL" = "0" ] && ok "staged swap drained" || nok "swap left" "got $SWL"
[ "$ACC" = "0" ] && ok "accumulator empty" || nok "accumulator leaks" "got $ACC entries: $(echo "$AUDIT" | head -c 200)"

echo "── §4 timers running: staged state drains through the chokepoints ──"
ua placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.30) : nat, $(e8 1.0) : nat)" >/dev/null
ub swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 5.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })" >/dev/null
adm setTestTimersPaused '(false)' >/dev/null 2>&1
tries=0; EX=1; SWL=1
while [ $tries -lt 15 ]; do
  audit; EX=$(afield execLive); SWL=$(afield swapLive)
  [ "${EX:-1}" = "0" ] && [ "${SWL:-1}" = "0" ] && break
  sleep 3; tries=$((tries+1))
done
if [ "${EX:-1}" = "0" ] && [ "${SWL:-1}" = "0" ]; then ok "GEPTOR/expiry drained the staged state"; else nok "staged state stuck" "exec=$EX swap=$SWL"; fi
assert_consistent "§4"

echo "── §5 record the read costs at S = 25 ──"
adm setTestTimersPaused '(true)' >/dev/null 2>&1
i=0
while [ $i -lt 25 ]; do
  ua placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.30) : nat, $(e8 1.0) : nat)" >/dev/null 2>&1
  i=$((i+1))
done
assert_consistent "§5"
EX=$(afield execLive)
[ "${EX:-0}" -ge 20 ] && ok "staged S = $EX" || nok "staging for the measurement failed" "execLive=$EX"
IDX=$(afield indexedReadInstructions); REC=$(afield recomputedReadInstructions)
echo "   soft-lock read: indexed = ${IDX:-?} instructions, recomputed scan = ${REC:-?} instructions (S = $EX)"
if [ -n "$IDX" ] && [ -n "$REC" ] && [ "$IDX" -lt "$REC" ]; then
  ok "indexed read is cheaper than the full scan (${IDX} < ${REC})"
else
  nok "indexed read not cheaper" "indexed=$IDX recomputed=$REC"
fi
# Drain and hand the venue back with timers running.
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm setTestTimersPaused '(false)' >/dev/null 2>&1
assert_consistent "final"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_staged_owner_index ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_staged_owner_index ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
