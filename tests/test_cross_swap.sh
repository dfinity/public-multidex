#!/bin/bash
# Cross-market swap — defer-until-BOTH-fresh. A token→token swap stages, reserving
# the `from` amount, and executes BOTH legs atomically against their fresh AMMs
# only once BOTH legs' markets have re-quoted past the request (anti-snipe on both).
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_cross_swap.sh
#
# Verifies:
#   1. A cross-swap (ICP→BTC) STAGES — reserves `from`, no immediate execution.
#   2. Anti-snipe: with only ONE leg's market fresh, it does NOT execute.
#   3. With BOTH legs fresh, it executes both legs at the fresh AMM prices.
#   4. Conservation across both pools.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money migration: trading/admin methods take Nat BASE UNITS (10^8), and
# balances come back as base-unit Nats (Candid may print them with underscores —
# strip those BEFORE grepping). e8 converts human→base for call args; from_e8
# converts base→human so the human-scale assertions below stay unchanged.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
# Resolve the AMM principal LIVE — a hardcoded id goes stale on every redeploy.
AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
# bal → HUMAN units: pull the base-unit Nat (strip Candid underscores) and /1e8.
bal()  { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
# Treasury USD (human) — the maker/taker fee skims here on every fill, so the
# ICPUSD conservation set must include it (resetExchange zeroes it at setup).
treas() { local n; n=$(adm getTreasury '()' | tr -d '_' | grep -oE "balanceUsd = [0-9]+" | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
avail() { local n; n=$(u getMyAvailableBalance "(\"$1\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
setup_pool() { # market base refprice baseSeed quoteSeed
  adm createAmmPool "(\"$1\")" >/dev/null 2>&1
  # (quoteDepthBase is a base-unit Nat quantity now; the other knobs stay plain nats.)
  adm setAmmConfig "(\"$1\", 20:nat, $(e8 "$4") : nat, 5:nat, 25:nat, 8:nat)" >/dev/null
  adm setAmmRefPrice "(\"$1\", $(e8 "$3") : nat)" >/dev/null
  adm setTestBalance "(principal \"$S\", \"$2\", $(e8 "$4") : nat)" >/dev/null
  adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 "$5") : nat)" >/dev/null
  icp canister call --identity amm_seed backend seedAmmPool "(\"$1\", $(e8 "$4") : nat, $(e8 "$5") : nat)" >/dev/null 2>&1
  adm enableAmm "(\"$1\", true)" >/dev/null
  adm requoteAmm "(\"$1\")" >/dev/null
}
freshrequote() { adm setAmmRefPrice "(\"$1\", $(e8 "$2") : nat)" >/dev/null; adm requoteAmm "(\"$1\")" >/dev/null; }

S=$(mkid amm_seed); UA=$(mkid amm_uA)
u() { icp canister call --identity amm_uA backend "$@" 2>&1; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # quiesce background timers for a deterministic run
setup_pool "ICP-ICPUSD" "ICP" 10.0  10000.0 100000.0
setup_pool "BTC-ICPUSD" "BTC" 100.0  1000.0  100000.0
for t in ICP BTC ICPUSD; do adm setTestBalance "(principal \"$UA\", \"$t\", $(e8 0.0) : nat)" >/dev/null; done
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 100.0) : nat)" >/dev/null

# Conservation baseline: UA + AMM across ICP / BTC / ICPUSD — plus the treasury
# on the quote leg (fees skim there on every fill; base tokens carry no fee).
base_tot() { local t=0; if [ "$1" = "ICPUSD" ]; then t=$(treas); fi; awk -v a="$(bal "$UA" "$1")" -v b="$(bal "$AMM" "$1")" -v c="$t" 'BEGIN{printf "%.4f", a+b+c}'; }
ICP_B=$(base_tot ICP); BTC_B=$(base_tot BTC); USD_B=$(base_tot ICPUSD)

# ── 1. Cross-swap 50 ICP → BTC STAGES (reserves ICP, no execution) ──
echo ""
echo "── 1. Swap 50 ICP → BTC stages (reserved, swapOrderId returned, not executed) ──"
RES=$(u swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 50.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })")
BTC_P=$(bal "$UA" BTC); ICP_P=$(bal "$UA" ICP)
AVAIL=$(avail ICP)
if echo "$RES" | grep -q "swapOrderId = opt" \
   && awk -v x="$BTC_P" 'BEGIN{exit (x<0.0000001?0:1)}' \
   && awk -v a="$AVAIL" 'BEGIN{exit (a<50.5?0:1)}'; then
  ok "staged: 0 BTC, ICP reserved (available ICP=$AVAIL ≈ 50 of 100), swapOrderId returned"
else nok "cross-swap should stage + reserve" "btc=$BTC_P availICP=$AVAIL res=[$(echo "$RES" | head -c 120)]"; fi

# ── 2. Anti-snipe: only ICP market fresh → NOT executed ──
echo ""
echo "── 2. Only the sell-leg market fresh → NOT executed (needs BOTH) ──"
freshrequote "ICP-ICPUSD" 10.0
adm adminRunDeferredSwaps "()" >/dev/null 2>&1
BTC_NS=$(bal "$UA" BTC)
if awk -v x="$BTC_NS" 'BEGIN{exit (x<0.0000001?0:1)}'; then ok "not executed (buy-leg market not fresh yet)"; else nok "should need BOTH legs fresh" "btc=$BTC_NS"; fi

# ── 3. Both legs fresh → executes both at the fresh AMM prices ──
echo ""
echo "── 3. Both legs fresh → executes (ICP sold ~10, BTC bought ~100) ──"
freshrequote "BTC-ICPUSD" 100.0
adm adminRunDeferredSwaps "()" >/dev/null 2>&1
BTC1=$(bal "$UA" BTC); ICP1=$(bal "$UA" ICP)
# 50 ICP @ ~10 = ~500 ICPUSD → ~5 BTC @ ~100. Allow for spread + fees.
if awk -v b="$BTC1" 'BEGIN{exit (b>4.7?0:1)}' && awk -v i="$ICP1" 'BEGIN{exit (i<50.5?0:1)}'; then
  ok "executed: UA now holds $BTC1 BTC (~5), ICP down to $ICP1 (~50)"
else nok "both-fresh release should execute both legs" "btc=$BTC1 icp=$ICP1"; fi

# ── 4. Conservation (UA + AMM + treasury totals unchanged per asset) ──
echo ""
echo "── 4. Conservation (UA + AMM [+ treasury for ICPUSD], per asset) ──"
icp_now=$(base_tot ICP); btc_now=$(base_tot BTC); usd_now=$(base_tot ICPUSD)
okc=1
for pair in "ICP $icp_now $ICP_B" "BTC $btc_now $BTC_B" "ICPUSD $usd_now $USD_B"; do
  set -- $pair
  awk -v a="$2" -v b="$3" 'BEGIN{exit (((a-b<0?b-a:a-b)) < 0.02 ? 0 : 1)}' || { nok "leak in $1" "$2 vs $3"; okc=0; }
done
# NOTE: ${var}≈ needs the braces — macOS bash 3.2 swallows the multibyte ≈ into
# the variable name and `set -u` kills the script with "icp_now≈: unbound".
[ "$okc" = 1 ] && ok "ICP (${icp_now}≈$ICP_B), BTC (${btc_now}≈$BTC_B), ICPUSD (${usd_now}≈$USD_B) all conserved"

echo ""
# Fixture hygiene: every unit of vault LP minted above belongs to the ad-hoc
# `amm_seed` identity, which _lib.sh's I1 (Σ alice..eve LP == lpSupply) can
# never account for. Reset at exit so the next test starts from an EMPTY
# venue (I1 skips on lpSupply == 0) instead of inheriting an unattributable
# vault — test_deposit_ledger_guard was the standing victim of this leak.
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
