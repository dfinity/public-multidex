#!/bin/bash
# Cross-swap leg sizing (directive 3): leg 1 sells only enough source to produce
# ICPUSD that leg 2 can fully spend on the destination. Worst case = LESS source
# converted, NEVER ICPUSD left stranded as a side effect.
#
# Setup makes the BUY leg (BTC) THIN so it can absorb far less than a full sale of
# the source (ICP) would raise. Expect: ICPUSD residual bounded by the slippage-band
# fraction of leg 2's spend, some BTC bought, and most of the source ICP left
# unconverted.
#
# Residual bound (task 1787204744, tightening the 1787189218 band-fraction
# slack): the buy leg passes its sell proceeds to the engine as maxQuoteSpend
# (a cost+takerFee budget) and sizes its quantity at the BEST ask — the engine
# stops every fill walk exactly at the budget, so it can NEVER spend beyond
# the proceeds into the owner's unrelated ICPUSD (see test_cross_swap_budget.sh)
# AND fills landing below the cap no longer strand a band-fraction residual
# (the old cap-sizing left up to spend×slip/(1+slip) ≈ $12 here; the engine
# stop leaves sub-dollar conversion crumbs only).
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_cross_swap_sizing.sh

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

S=$(mkid amm_seed); UA=$(mkid amm_uA)
u() { icp canister call --identity amm_uA backend "$@" 2>&1; }
seedpool() { # market base refprice baseSeed quoteSeed depth
  adm createAmmPool "(\"$1\")" >/dev/null 2>&1
  # (quoteDepthBase is a base-unit Nat quantity now; the other knobs stay plain nats.)
  adm setAmmConfig "(\"$1\", 20:nat, $(e8 "$6") : nat, 5:nat, 25:nat, 8:nat)" >/dev/null
  adm setAmmRefPrice "(\"$1\", $(e8 "$3") : nat)" >/dev/null
  adm setTestBalance "(principal \"$S\", \"$2\", $(e8 "$4") : nat)" >/dev/null
  adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 "$5") : nat)" >/dev/null
  icp canister call --identity amm_seed backend seedAmmPool "(\"$1\", $(e8 "$4") : nat, $(e8 "$5") : nat)" >/dev/null 2>&1
  adm enableAmm "(\"$1\", true)" >/dev/null
  adm requoteAmm "(\"$1\")" >/dev/null
}

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # quiesce background timers for a deterministic run
# ICP sell-leg: deep (100/level bids). BTC buy-leg: THIN (0.5 BTC/level asks → ~2.5
# BTC ≈ $250 absorbable within the cap).
seedpool "ICP-ICPUSD" "ICP" 10.0  10000.0 100000.0 100.0
seedpool "BTC-ICPUSD" "BTC" 100.0 100.0    100000.0 0.5
for t in ICP BTC ICPUSD; do adm setTestBalance "(principal \"$UA\", \"$t\", $(e8 0.0) : nat)" >/dev/null; done
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 100.0) : nat)" >/dev/null

# Conservation set: UA + AMM per asset — plus the treasury on the quote leg
# (fees skim there on every fill; base tokens carry no fee).
base_tot() { local t=0; if [ "$1" = "ICPUSD" ]; then t=$(treas); fi; awk -v a="$(bal "$UA" "$1")" -v b="$(bal "$AMM" "$1")" -v c="$t" 'BEGIN{printf "%.4f", a+b+c}'; }
ICP_B=$(base_tot ICP); BTC_B=$(base_tot BTC); USD_B=$(base_tot ICPUSD)

# ── Swap 50 ICP → BTC. A full 50-ICP sale would raise ~$500, but BTC absorbs ~$250.
echo ""
echo "── Cross-swap 50 ICP → BTC with a thin BTC buy leg ──"
u swap "(record { fromToken=\"ICP\"; toToken=\"BTC\"; amount=$(e8 50.0) : nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.05) : nat } }; noPartialFill=false })" >/dev/null
# Drive the release REPEATEDLY: leg 2 executes as a spot market order that
# walks the AMM ladder and RE-DEFERS its remainder across requotes — a single
# release pass leaves in-flight tranches whose funds sit in transit, which
# reads as a "leak" if the conservation sums run mid-walk. Quiesce first.
for i in 1 2 3 4 5; do
  adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
  adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 100.0) : nat)" >/dev/null
  adm requoteAmm '("ICP-ICPUSD")' >/dev/null
  adm requoteAmm '("BTC-ICPUSD")' >/dev/null
  adm adminRunDeferredSwaps "()" >/dev/null 2>&1
done
sleep 2
ICPUSD_UA=$(bal "$UA" ICPUSD); BTC_UA=$(bal "$UA" BTC); ICP_UA=$(bal "$UA" ICP)
echo "   UA after: ICP=$ICP_UA  BTC=$BTC_UA  ICPUSD=$ICPUSD_UA"

# 1) KEY: residual ICPUSD ≈ 0 — the engine's maxQuoteSpend stop converts the
#    whole leg-2 budget (sub-dollar crumbs only: per-level floor rounding plus
#    any sliver the walk can't fit at the last price). Pre-1787204744 the
#    cap-sizing left ~$12 here (spend×slip/(1+slip)) and this assertion reads
#    RED on that build.
if awk -v x="$ICPUSD_UA" 'BEGIN{exit (x<1.0?0:1)}'; then ok "residual ICPUSD ($ICPUSD_UA) ≈ 0 (<\$1) — budget-stop converts the whole leg-2 spend"; else nok "ICPUSD residual beyond the engine-stop bound" "ICPUSD=$ICPUSD_UA"; fi
# 2) Got some BTC (leg 2 executed).
if awk -v x="$BTC_UA" 'BEGIN{exit (x>2.0?0:1)}'; then ok "bought BTC (~$BTC_UA, leg 2 executed up to the thin depth)"; else nok "leg 2 should have bought BTC" "BTC=$BTC_UA"; fi
# 3) Source under-converted (most ICP kept) — the accepted worst case.
if awk -v x="$ICP_UA" 'BEGIN{exit (x>70.0?0:1)}'; then ok "source under-converted (~$ICP_UA ICP kept) rather than producing stranded ICPUSD"; else nok "expected most ICP kept (under-conversion)" "ICP=$ICP_UA"; fi

# 4) Conservation.
echo ""
echo "── Conservation (UA + AMM [+ treasury for ICPUSD], per asset) ──"
okc=1
for pair in "ICP $(base_tot ICP) $ICP_B" "BTC $(base_tot BTC) $BTC_B" "ICPUSD $(base_tot ICPUSD) $USD_B"; do
  set -- $pair
  awk -v a="$2" -v b="$3" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.02?0:1)}' || { nok "leak in $1" "$2 vs $3"; okc=0; }
done
[ "$okc" = 1 ] && ok "ICP, BTC, ICPUSD all conserved"

echo ""
# Fixture hygiene: the vault LP minted above is held by the ad-hoc `amm_seed`
# identity, which _lib.sh's I1 (Σ alice..eve LP == lpSupply) can never
# account for. Reset at exit so the next test starts from an EMPTY venue
# (I1 skips on lpSupply == 0) — test_deposit_ledger_guard runs directly
# after this file and was the standing victim of the leak.
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
