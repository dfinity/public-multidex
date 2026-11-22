#!/bin/bash
# Verifies the swap endpoint's three routing modes:
#   1. quote → base       (ICPUSD → BTC, executes a market BUY)
#   2. base → quote       (BTC → ICPUSD, executes a market SELL)
#   3. base → base via quote (BTC → ETH, staged cross-swap, both legs atomic)
#   4. #limitOrder mode inherits placeLimitOrder's price band (H-08): the 100×
#      fat-finger band and the 5% collar on marketable orders, same strings
#
# Sealed-until-GEPTOR model: every market-order swap STAGES (the call returns
# fromAmount=0 / fullyFilled=false / swapOrderId=opt N) and only settles on the
# next GEPTOR after a FRESH oracle fetch + requote (anti-snipe). Each route
# stages, forces a release, then polls for the settled balance.
#
# Uses `full` mode so all three markets have ≥1 layer of book depth.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_swap ──"
# `full` seed WITHOUT the 14d CoinGecko history backfill: the swap routes only
# need markets + funded AMM pools + book depth, and the multi-thousand-call
# history injection reliably kills the local pocket-ic mid-test.
seed_logged full --history-days 0

# Set up a fresh swapper so the named seed traders' books stay
# untouched.
mdx_identity_new swapper
SW=$(principal_of swapper)

# Fund swapper with both legs so all three swap routes are testable.
# (Integer-money migration: setTestBalance takes Nat BASE UNITS at 10^8.)
call setTestBalance "(principal \"$SW\", \"ICPUSD\", $(e8 100000) : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$SW\", \"BTC\",    $(e8 1)      : nat)" --identity alice > /dev/null
call setTestBalance "(principal \"$SW\", \"ETH\",    $(e8 20)     : nat)" --identity alice > /dev/null

# Swapper's balance in BASE UNITS (getBalance returns a Nat now; Candid may
# print it with underscores — extract_first_nat strips them first).
swapper_bal() { local n; n=$(extract_first_nat "$(call getBalance "(\"$1\")" --identity swapper)"); echo "${n:-0}"; }

# Force a sealed-model release on one market: re-stamp the pool's CURRENT
# refPrice (counts as a fresh fetch without moving the market), then requote —
# the GEPTOR that follows settles staged swaps/orders on that market.
release_market() {
  local m="$1" px
  px=$(call getAmmPool "(\"$m\")" | tr -d '_' | grep -oE "refPrice = [0-9]+" | grep -oE "[0-9]+" | head -1)
  [ -n "$px" ] || { echo "release_market: no refPrice for $m" >&2; return 1; }
  call setAmmRefPrice "(\"$m\", $px : nat)" --identity alice > /dev/null
  call requoteAmm "(\"$m\")" --identity alice > /dev/null
}

# ── Route 1: ICPUSD → BTC ────────────────────────────────────────
# Spend $5,000 on BTC at market with 5% slippage. Amount + maxSlippage are
# e8 Nats now (maxSlippage is an e8 FRACTION of 1).
SW1=$(call swap "(record {
  fromToken = \"ICPUSD\";
  toToken   = \"BTC\";
  amount    = $(e8 5000) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.05) : nat } };
  noPartialFill = false
})" --identity swapper)
assert_ok "ICPUSD→BTC swap accepted" "$SW1"
assert_contains "ICPUSD→BTC staged (sealed model, swapOrderId returned)" "$SW1" "swapOrderId = opt"

release_market "BTC-ICPUSD"
wait_for "[ \"\$(swapper_bal BTC)\" -gt $(e8 1) ]" 20 1
BTC_BAL=$(from_e8 "$(swapper_bal BTC)")
assert_gt "swapper BTC balance grew" "$BTC_BAL" "1.0"

# ── Route 2: BTC → ICPUSD ────────────────────────────────────────
USD_BEFORE2=$(swapper_bal ICPUSD)
SW2=$(call swap "(record {
  fromToken = \"BTC\";
  toToken   = \"ICPUSD\";
  amount    = $(e8 0.05) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.05) : nat } };
  noPartialFill = false
})" --identity swapper)
assert_ok "BTC→ICPUSD swap accepted" "$SW2"

release_market "BTC-ICPUSD"
wait_for "[ \"\$(swapper_bal ICPUSD)\" -gt $USD_BEFORE2 ]" 20 1
ICPUSD_BAL=$(from_e8 "$(swapper_bal ICPUSD)")
assert_gt "BTC→ICPUSD proceeds landed" "$ICPUSD_BAL" "$(from_e8 "$USD_BEFORE2")"
# Started with 100k, spent 5k on BTC (≈$5k out), got back the proceeds of
# selling 0.05 BTC. Final >$90k easily covers any slippage + fees.
assert_gt "swapper ICPUSD balance" "$ICPUSD_BAL" "90000"

# ── Route 3: BTC → ETH (cross-market) ───────────────────────────
# Ground first (task 3088527364): this route buys ETH capped at the mid (mark
# × 1.10 for the 10% slippage below), so it can only fill if the seeded ETH
# ask ladder rests inside that band. It did not when seed.sh's step-0 mark
# lookup fell back to the $3500 default on a just-reset venue (no pools, so
# nothing had cached an aggregate) while the feed then confirmed ~$2450: the
# ladder stayed at $3500, the AMM withdrew its ETH asks (vault leg mis-sized
# at the fallback), quoteSwap previewed `exhausted = true`, and the balance
# line below went red ("got 20.0") for a SEED reason that read like a
# matching-engine one. seed.sh now fetches the live aggregate on demand
# before it resets; this pins the ground so any recurrence reds HERE, with
# the numbers, before the balance assertion.
ETH_MARK3=$(call getAmmPool '("ETH-ICPUSD")' | tr -d '_' | grep -oE 'refPrice = [0-9]+' | grep -oE '[0-9]+' | head -1)
ETH_ASK3=$(call getOrderBook '("ETH-ICPUSD")' | tr -d '\n_' | sed 's/^.*asks = vec {//' | grep -oE 'price = [0-9]+' | grep -oE '[0-9]+' | head -1)
ETH_CAP3=$(python3 -c "print(int(${ETH_MARK3:-0} * 1.10))")
assert_lt "route 3 ground: seeded ETH best ask \$$(from_e8 "${ETH_ASK3:-0}") rests inside the buy cap (mark \$$(from_e8 "${ETH_MARK3:-0}") × 1.10), e8" "${ETH_ASK3:-999999999999999999}" "$ETH_CAP3"

ETH_BEFORE3=$(swapper_bal ETH)
SW3=$(call swap "(record {
  fromToken = \"BTC\";
  toToken   = \"ETH\";
  amount    = $(e8 0.05) : nat;
  mode      = variant { marketOrder = record { maxSlippage = $(e8 0.10) : nat } };
  noPartialFill = false
})" --identity swapper)
assert_ok "BTC→ETH cross-swap accepted" "$SW3"
assert_contains "BTC→ETH staged (deferred until BOTH legs fresh)" "$SW3" "swapOrderId = opt"

# A cross-swap releases only once BOTH legs' markets are fresh; the deferred
# processor is normally timer-driven — force it for determinism.
release_market "BTC-ICPUSD"
release_market "ETH-ICPUSD"
call adminRunDeferredSwaps '()' --identity alice > /dev/null
wait_for "[ \"\$(swapper_bal ETH)\" -gt $ETH_BEFORE3 ]" 20 1

# ETH balance should have grown (started at 20, gained some).
ETH_BAL=$(from_e8 "$(swapper_bal ETH)")
assert_gt "swapper ETH balance grew" "$ETH_BAL" "20.0"

# ── §4 swap #limitOrder inherits placeLimitOrder's price band (H-08) ──
# `swap({mode:#limitOrder})` parks a #limit entry through the SAME release
# path as placeLimitOrder, but the branch used to skip priceBandCheck: the
# 100× fat-finger band AND the 5% collar on marketable orders
# (MARKETABLE_BAND_BPS) were enforced on every sibling limit path and not
# here, so two accounts could print a trade at any price via swap. Each
# refusal below is asserted to be the SAME string placeLimitOrder returns for
# the same (market, side, price) — one band, one message. Layout mirrors
# tests/test_price_collar.sh (§4a/§4b band, §4c collar, §4d resting allowed,
# §4e boundary, §4f/§4g adjacent paths).
MKT4="BTC-ICPUSD"
MARK4=$(call getAmmPool "(\"$MKT4\")" --query | tr -d '_' | grep -oE 'refPrice = [0-9]+' | head -1 | grep -oE '[0-9]+')
if [ -z "${MARK4:-}" ] || [ "$MARK4" = "0" ]; then
  _fail "§4 $MKT4 has no reference price — the band cannot be exercised"
else
  err_of() { echo "$1" | tr -d '_' | grep -oE 'err = "[^"]*"' | head -1; }
  swap_lim() {  # $1 from  $2 to  $3 amount(base units)  $4 limitPrice
    call swap "(record { fromToken = \"$1\"; toToken = \"$2\"; amount = $3 : nat;
      mode = variant { limitOrder = record { limitPrice = $4 : nat } }; noPartialFill = false })" --identity swapper
  }
  place4() { call placeLimitOrder "(\"$MKT4\", variant { $1 }, $2 : nat, $3 : nat)" --identity swapper; }
  FATFINGER="likely an input error"
  COLLAR="must be within"
  ABSURD_HI=$(python3 -c "print($MARK4 * 500)")      # outside the 100× band
  ABSURD_LO=$(python3 -c "print(max(1, $MARK4 // 500))")
  HIGH4=$(python3 -c "print($MARK4 * 50)")           # inside 100×, far outside 5%
  LOW4=$(python3 -c "print(max(1, $MARK4 // 50))")
  # A $500 spend / 0.05 BTC sell: comfortably above the venue minimum, and
  # far below the swapper's funding, so every refusal is the band's own.
  SPEND4=$(e8 500); SELL4=$(e8 0.05)
  # placeLimitOrder quantities sized so the notional stays ≈ $500 at each price.
  QTY_AT() { python3 -c "print(max(1, ($SPEND4 * 100000000) // $1))"; }

  # §4a/§4b — the 100× fat-finger band binds regardless of marketability, and
  # the refusal is byte-identical to placeLimitOrder's.
  R=$(swap_lim ICPUSD BTC "$SPEND4" "$ABSURD_HI")
  assert_contains "§4a swap #limitOrder buy 500× above the mark is refused" "$R" "$FATFINGER"
  assert_contains "§4a ...by the 100× band (above)" "$R" "100× above"
  assert_eq "§4a same string as placeLimitOrder" "$(err_of "$(place4 buy "$ABSURD_HI" "$(QTY_AT "$ABSURD_HI")")")" "$(err_of "$R")"
  R=$(swap_lim BTC ICPUSD "$SELL4" "$ABSURD_LO")
  assert_contains "§4b swap #limitOrder sell 500× below the mark is refused" "$R" "$FATFINGER"
  assert_contains "§4b ...by the 100× band (below)" "$R" "100× below"
  assert_eq "§4b same string as placeLimitOrder" "$(err_of "$(place4 sell "$ABSURD_LO" "$SELL4")")" "$(err_of "$R")"

  # §4c — the 5% collar on MARKETABLE orders. Marketability is a property of
  # the BOOK (isMarketable: buy ≥ best ask / sell ≤ best bid), so each probe
  # is gated on actually crossing the touch, exactly as test_price_collar does.
  DEPTH4=$(call getOrderBookDepth "(\"$MKT4\", null)" --query 2>&1 | tr -d '_')
  side_prices4() { echo "$DEPTH4" | sed -n "/$1 = /,/}/p" | grep -oE 'price = [0-9]+' | grep -oE '[0-9]+'; }
  BEST_ASK4=$(side_prices4 asks | sort -n  | head -1)
  BEST_BID4=$(side_prices4 bids | sort -rn | head -1)
  echo "  §4 market=$MKT4 mark=$MARK4 best ask=${BEST_ASK4:-none} best bid=${BEST_BID4:-none}"
  crosses4() { case "$2" in
    buy)  [ -n "$BEST_ASK4" ] && [ "$1" -ge "$BEST_ASK4" ] ;;
    sell) [ -n "$BEST_BID4" ] && [ "$1" -le "$BEST_BID4" ] ;;
  esac; }
  if crosses4 "$HIGH4" buy; then
    R=$(swap_lim ICPUSD BTC "$SPEND4" "$HIGH4")
    assert_contains "§4c marketable swap-limit buy 50× above the mark is collared" "$R" "$COLLAR"
    assert_eq "§4c same string as placeLimitOrder" "$(err_of "$(place4 buy "$HIGH4" "$(QTY_AT "$HIGH4")")")" "$(err_of "$R")"
  else
    skip_section "§4c buy: $HIGH4 does not cross the best ask (${BEST_ASK4:-none}) — not marketable"
  fi
  if crosses4 "$LOW4" sell; then
    R=$(swap_lim BTC ICPUSD "$SELL4" "$LOW4")
    assert_contains "§4c marketable swap-limit sell 50× below the mark is collared" "$R" "$COLLAR"
    assert_eq "§4c same string as placeLimitOrder" "$(err_of "$(place4 sell "$LOW4" "$SELL4")")" "$(err_of "$R")"
  else
    skip_section "§4c sell: $LOW4 does not cross the best bid (${BEST_BID4:-none}) — not marketable"
  fi

  # §4d — RESTING far from the mark stays allowed (the collar's asymmetry):
  # a sell 50× above / a buy 50× below cannot cross, so the band lets them park.
  R=$(swap_lim BTC ICPUSD "$SELL4" "$HIGH4")
  assert_not_contains "§4d resting swap-limit sell 50× above is not collared" "$R" "$COLLAR"
  assert_contains     "§4d ...and stages" "$R" "swapOrderId = opt"
  R=$(swap_lim ICPUSD BTC "$SPEND4" "$LOW4")
  assert_not_contains "§4d resting swap-limit buy 50× below is not collared" "$R" "$COLLAR"
  assert_contains     "§4d ...and stages" "$R" "swapOrderId = opt"

  # §4e — the collar boundary: +4% marketable passes, +6% marketable is refused.
  IN4=$(python3 -c "print(int($MARK4 * 1.04))")
  OUT4=$(python3 -c "print(int($MARK4 * 1.06))")
  R=$(swap_lim ICPUSD BTC "$SPEND4" "$IN4")
  assert_not_contains "§4e swap-limit buy +4% (inside the collar) passes" "$R" "$COLLAR"
  assert_contains     "§4e ...and stages" "$R" "swapOrderId = opt"
  if crosses4 "$OUT4" buy; then
    assert_contains "§4e swap-limit buy +6% (outside) is refused" "$(swap_lim ICPUSD BTC "$SPEND4" "$OUT4")" "$COLLAR"
  else
    skip_section "§4e +6%: $OUT4 does not cross the best ask (${BEST_ASK4:-none})"
  fi

  # §4f — the zero check still precedes the band (placeLimitInner's order).
  assert_contains "§4f zero limit price is refused before the band" \
    "$(swap_lim ICPUSD BTC "$SPEND4" 0)" "Limit price must be positive"
  # §4g — the cross-market #limitOrder path parks nothing: still refused as
  # unsupported, never reaches a band (adjacent site, unchanged).
  assert_contains "§4g cross-market #limitOrder is still refused as unsupported" \
    "$(swap_lim BTC ETH "$SELL4" "$MARK4")" "not yet supported"

  # Leave no staged swapper orders behind (the §4d/§4e parks).
  call cancelAllMyOrders '(null)' --identity swapper >/dev/null 2>&1 || true
fi

finish_test "test_swap"
