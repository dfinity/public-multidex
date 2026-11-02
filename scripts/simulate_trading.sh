#!/bin/bash
# UPLANDS DEX — Trading Simulator
# Creates 20 trader accounts with balances, then runs a continuous loop
# of random trading activity (limit orders, market orders, cancels, swaps)
# with periodic verification checks.
#
# Usage:
#   bash scripts/simulate_trading.sh [--reset] [--rounds N] [--speed fast|normal|slow]
#
#   --reset        Wipe the exchange before starting
#   --rounds N     Run N rounds then stop (default: infinite)
#   --speed SPEED  Trading pace: fast (0.5-1s), normal (1-3s), slow (3-6s)

set -o pipefail
export PATH="$HOME/.local/bin:$PATH"

# Scratch-file locations (.run/, not fixed names under sticky /tmp) — see
# scripts/lib/runfiles.sh. This script only READS the price snapshot, but it
# has to look where inject_history.sh wrote it: reading the old /tmp path
# after the writers moved would silently fall back to the hardcoded
# DEFAULT_PRICES and walk a freshly-seeded AMM off its real price.
# shellcheck source=scripts/lib/runfiles.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/runfiles.sh"

# ── Colors ────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ── CLI Flags ─────────────────────────────────────────────────────
RESET_FIRST=false
MAX_ROUNDS=0       # 0 = infinite
SPEED="normal"

while [ $# -gt 0 ]; do
  case "$1" in
    --reset)  RESET_FIRST=true; shift ;;
    --rounds) MAX_ROUNDS="$2"; shift 2 ;;
    --speed)  SPEED="$2"; shift 2 ;;
    *)        echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ── Constants ─────────────────────────────────────────────────────
NUM_TRADERS=20
VERIFY_EVERY=10

# Markets (indexed arrays — bash 3 compatible)
MARKETS=("BTC-ICPUSD" "ETH-ICPUSD" "SOL-ICPUSD" "ICP-ICPUSD")
BASE_TOKENS=("BTC" "ETH" "SOL" "ICP")

# Hardcoded fallbacks if neither the live canister nor the oracle
# snapshot file is reachable. Kept only for offline operation; in
# normal use these get overwritten by the canister-side lastPrice
# (or oracle snapshot) on startup.
DEFAULT_PRICES=("78000.0" "2350.0" "200.0" "2.45")
MIN_QTYS=("0.01" "0.5" "0.5" "50.0")
# Sized against the $100k-value wallets below (~$15k of each asset, $40k
# cash): the max single order stays well inside one trader's holdings so
# the loop isn't dominated by insufficient-balance skips.
MAX_QTYS=("0.1" "4.0" "80.0" "3000.0")

# Track last known prices (updated when trades occur). Bootstrap from
# (a) the canister's getMarkets lastPrice if non-zero, falling back
# to (b) the $MDX_ORACLE_PRICES snapshot if present,
# falling back to (c) the hardcoded DEFAULT_PRICES.
LAST_PRICES=("${DEFAULT_PRICES[@]}")
ORACLE_FILE="$MDX_ORACLE_PRICES"
for i in 0 1 2 3; do
  m="${MARKETS[$i]}"; base="${BASE_TOKENS[$i]}"
  lp=$(icp canister call backend getMarkets '()' --identity anonymous 2>/dev/null \
       | awk -v m="$m" '$0 ~ m{f=1} f && /lastPrice/{ v=$3; gsub(/_/,"",v); if (v+0==0) print "0"; else printf "%.8f", v/100000000; exit }')
  if [ -n "$lp" ] && [ "$lp" != "0.0" ] && [ "$lp" != "0" ]; then
    LAST_PRICES[$i]="$lp"
    continue
  fi
  if [ -f "$ORACLE_FILE" ]; then
    op=$(awk -v a="$base" '$1 == a { print $2; exit }' "$ORACLE_FILE")
    if [ -n "$op" ]; then LAST_PRICES[$i]="$op"; fi
  fi
done
echo "Simulator anchored to: BTC=${LAST_PRICES[0]} ETH=${LAST_PRICES[1]} SOL=${LAST_PRICES[2]} ICP=${LAST_PRICES[3]}"

ALL_TOKENS=("ICPUSD" "BTC" "ETH" "SOL" "ICP")

# Lookup market index by name
market_idx() {
  local m="$1"
  case "$m" in
    BTC-ICPUSD) echo 0 ;;
    ETH-ICPUSD) echo 1 ;;
    SOL-ICPUSD) echo 2 ;;
    ICP-ICPUSD) echo 3 ;;
  esac
}

# Stats counters
STAT_LIMIT=0
STAT_MARKET=0
STAT_CANCEL=0
STAT_SWAP=0
STAT_SKIP=0
STAT_ERROR=0
STAT_ROUNDS=0
STAT_WARNINGS=0

# Trader arrays (populated during init)
TRADER_NAMES=()
TRADER_PRINCIPALS=()

# ── Utility Functions ─────────────────────────────────────────────
log()  { echo -e "${CYAN}▶${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; STAT_WARNINGS=$((STAT_WARNINGS + 1)); }
err()  { echo -e "  ${RED}✗${NC} $1"; STAT_ERROR=$((STAT_ERROR + 1)); }
section() { echo -e "\n${YELLOW}═══ $1 ═══${NC}"; }
dim()  { echo -e "  ${DIM}$1${NC}"; }

# Trader actions pass their own --identity. Calls that omit it get
# `--identity anonymous` appended — NEVER the CLI's global default identity,
# which is machine-shared mutable state that other sessions and connectors
# move at will (mdex-process-safety §5). Anonymous signs the market reads
# fine, so identity-less probes stay deterministic.
call() {
  case " $* " in
    *" --identity "*) echo "y" | icp canister call backend "$@" 2>&1 ;;
    *)                echo "y" | icp canister call backend "$@" --identity anonymous 2>&1 ;;
  esac
}

# Integer-money: the backend ledger is Nat base units (10^8). Money args go out
# as base-unit integers; prices/qtys parsed back from Candid output (which prints
# Nat with `_` grouping) must be underscore-stripped and divided by 10^8. The
# simulator keeps its internal prices/qtys HUMAN, converting only at the wire.
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }       # human  -> base int
d8() { awk -v x="${1:-0}" 'BEGIN{ printf "%.8f", x/100000000 }'; }  # base int (no _) -> human

# Random integer in [min, max]
rand_int() {
  local min=$1 max=$2
  echo $(( RANDOM % (max - min + 1) + min ))
}

# Random float in [min, max] with given decimals (default 4)
rand_float() {
  local min="$1" max="$2" dec="${3:-4}"
  awk -v min="$min" -v max="$max" -v dec="$dec" -v seed="$RANDOM$RANDOM" \
    'BEGIN { srand(seed); printf "%.*f", dec, min + rand() * (max - min) }'
}

# Price with random deviation from base. Side: "buy" → below, "sell" → above
rand_price() {
  local base="$1" side="$2"
  local dev
  dev=$(awk -v seed="$RANDOM$RANDOM" \
    'BEGIN { srand(seed); printf "%.6f", 0.001 + rand() * 0.019 }')
  if [ "$side" = "buy" ]; then
    awk -v b="$base" -v d="$dev" 'BEGIN { printf "%.2f", b * (1 - d) }'
  else
    awk -v b="$base" -v d="$dev" 'BEGIN { printf "%.2f", b * (1 + d) }'
  fi
}

# Pick a random index from 0..N-1
rand_idx() {
  echo $(( RANDOM % $1 ))
}

# Check if Candid response is ok or err
# Deliberately SELF-CONTAINED — not sourced from scripts/lib/reply.sh: live
# fleets on other targets run their own copy of this file for hours, and a
# sourced lib is one more file a mid-run edit could re-parse under them. The
# needle is mdx_reply_ok's byte for byte (hygiene §7i pins it literally, §6af
# drives this function with the named and hashed spellings): the tag `ok`
# OR icp's hash spelling `24_860`, printed when its per-call candid fetch
# misses ("WARN could not fetch candid type …", task 1788507289) — a filled
# order answered that way must tally as a fill, never as a refusal. `err`
# (5_048_165) and `Err` (3_456_837) still refuse.
is_ok() {
  printf '%s\n' "$1" | tr -s '[:space:]' ' ' | grep -cE 'variant \{ (ok|24_860)( \}| =)' >/dev/null
}
is_err() { echo "$1" | grep -q 'err\|Error'; }
get_err_msg() { echo "$1" | sed -n 's/.*err = "\([^"]*\)".*/\1/p' | head -1; }

# Extract the first money value from Candid output as a HUMAN number. Balances
# are now Nat base units (10^8) — integers with no decimal point — so match an
# integer-or-decimal and divide by 10^8.
extract_float() {
  local v
  v=$(echo "$1" | tr -d '_' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$v" ] && d8 "$v"
}

# Extract order IDs from getMyOrders output
extract_order_ids() {
  echo "$1" | tr -d '_' | grep -oE 'id = [0-9]+' | grep -oE '[0-9]+' | tr '\n' ' '
}

# Sleep for random duration based on speed setting
random_sleep() {
  local min max dur
  case "$SPEED" in
    fast)   min="0.2"; max="0.5" ;;
    slow)   min="2.0"; max="4.0" ;;
    *)      min="0.5"; max="1.5" ;;
  esac
  dur=$(rand_float "$min" "$max" 1)
  sleep "$dur"
}

# ── Action Functions ──────────────────────────────────────────────

action_limit_order() {
  local trader="$1"
  local mi=$(rand_idx ${#MARKETS[@]})
  local market="${MARKETS[$mi]}"
  local base_price="${LAST_PRICES[$mi]}"
  local min_q="${MIN_QTYS[$mi]}"
  local max_q="${MAX_QTYS[$mi]}"

  # Random side
  local side
  if [ $((RANDOM % 2)) -eq 0 ]; then side="buy"; else side="sell"; fi

  local price qty result
  price=$(rand_price "$base_price" "$side")
  qty=$(rand_float "$min_q" "$max_q" 4)

  result=$(call placeLimitOrder "(\"$market\", variant { $side }, $(e8 $price), $(e8 $qty))" --identity "$trader")

  if is_ok "$result" && ! is_err "$result"; then
    ok "${trader}: ${GREEN}LIMIT ${side}${NC} ${market} ${qty} @ ${price}"
    STAT_LIMIT=$((STAT_LIMIT + 1))
    # If the order was immediately filled, update LAST_PRICES from
    # the canister's lastPrice — which is the MAKER's fill price (set
    # by updateStatsAfterTrades inside placeLimitOrder), not the
    # TAKER's limit `$price` we passed in.
    #
    # The taker's limit can be FAR from the actual trade price for
    # deeply-crossing orders: a taker buy at $78k that crosses an
    # ask at $76k produces a trade at $76k, but `$price` is still
    # $78k. Recording $78k as our anchor here would compound:
    # subsequent orders place at ±2% of $78k, occasionally cross
    # asks deeper into the book, and the simulator's view of "market
    # price" walks further off-oracle. (The $1.30 ICP and $78k BTC
    # candles we observed were both this drift mechanism in action.)
    if echo "$result" | grep -q 'filled\|partiallyFilled'; then
      local lp_actual
      lp_actual=$(icp canister call backend getMarkets '()' --identity anonymous 2>/dev/null \
        | awk -v m="$market" '$0 ~ m{f=1} f && /lastPrice/{ v=$3; gsub(/_/,"",v); if (v+0==0) print "0"; else printf "%.8f", v/100000000; exit }')
      if [ -n "$lp_actual" ] && [ "$lp_actual" != "0.0" ] && [ "$lp_actual" != "0" ]; then
        LAST_PRICES[$mi]="$lp_actual"
      fi
    fi
  else
    local msg
    msg=$(get_err_msg "$result")
    dim "${trader}: limit ${side} ${market} — ${msg:-call failed}"
    STAT_ERROR=$((STAT_ERROR + 1))
  fi
}

action_market_order() {
  local trader="$1"
  local mi=$(rand_idx ${#MARKETS[@]})
  local market="${MARKETS[$mi]}"
  local min_q="${MIN_QTYS[$mi]}"
  local max_q="${MAX_QTYS[$mi]}"

  # Random side
  local side
  if [ $((RANDOM % 2)) -eq 0 ]; then side="buy"; else side="sell"; fi

  # Use smaller quantities for market orders (30% of max)
  local small_max
  small_max=$(awk -v m="$max_q" 'BEGIN { printf "%.4f", m * 0.3 }')
  local qty slip result
  qty=$(rand_float "$min_q" "$small_max" 4)
  slip=$(rand_float "0.02" "0.10" 2)

  result=$(call placeMarketOrder "(\"$market\", variant { $side }, $(e8 $qty), $(e8 $slip), false)" --identity "$trader")

  if is_ok "$result" && ! is_err "$result"; then
    # Extract average price from MatchResult
    local avg filled
    avg=$(echo "$result" | tr -d '_' | grep -oE 'avgPrice = [0-9.]+' | grep -oE '[0-9.]+' | head -1)
    filled=$(echo "$result" | tr -d '_' | grep -oE 'totalFilled = [0-9.]+' | grep -oE '[0-9.]+' | head -1)
    # avg/filled are Nat base units (underscores already stripped above) — show human.
    ok "${trader}: ${BOLD}MARKET ${side}${NC} ${market} filled $(d8 ${filled:-0}) @ avg $(d8 ${avg:-0})"
    STAT_MARKET=$((STAT_MARKET + 1))
    # Update last price if we got an average
    if [ -n "$avg" ] && [ "$avg" != "0" ] && [ "$avg" != "0.0" ]; then
      LAST_PRICES[$mi]=$(d8 "$avg")
    fi
  else
    local msg
    msg=$(get_err_msg "$result")
    dim "${trader}: market ${side} ${market} — ${msg:-call failed}"
    STAT_ERROR=$((STAT_ERROR + 1))
  fi
}

action_cancel_order() {
  local trader="$1"

  local orders_result
  orders_result=$(call getMyOrders --identity "$trader")

  local ids
  ids=$(extract_order_ids "$orders_result")

  if [ -z "$ids" ]; then
    dim "${trader}: no open orders to cancel"
    STAT_SKIP=$((STAT_SKIP + 1))
    return
  fi

  # Pick a random order ID
  local id_arr=($ids)
  local idx=$(( RANDOM % ${#id_arr[@]} ))
  local order_id="${id_arr[$idx]}"

  local result
  result=$(call cancelMyOrder "($order_id)" --identity "$trader")

  if is_ok "$result" && ! is_err "$result"; then
    ok "${trader}: ${YELLOW}CANCEL${NC} order #${order_id}"
    STAT_CANCEL=$((STAT_CANCEL + 1))
  else
    local msg
    msg=$(get_err_msg "$result")
    dim "${trader}: cancel #${order_id} — ${msg:-call failed}"
    STAT_ERROR=$((STAT_ERROR + 1))
  fi
}

action_swap() {
  local trader="$1"
  local tokens=("BTC" "ETH" "ICP" "ICPUSD")

  # Pick two different tokens
  local fi ti from_token to_token
  fi=$(rand_idx 4)
  from_token="${tokens[$fi]}"
  while true; do
    ti=$(rand_idx 4)
    to_token="${tokens[$ti]}"
    [ "$to_token" != "$from_token" ] && break
  done

  # Determine a reasonable amount based on the from-token
  local amount
  case "$from_token" in
    BTC)    amount=$(rand_float 0.005 0.1 4) ;;
    ETH)    amount=$(rand_float 0.1 2.0 4) ;;
    ICP)    amount=$(rand_float 10.0 500.0 2) ;;
    ICPUSD) amount=$(rand_float 50.0 5000.0 2) ;;
  esac

  local result
  result=$(call swap "(record { fromToken = \"$from_token\"; toToken = \"$to_token\"; amount = $(e8 $amount) : nat; mode = variant { marketOrder = record { maxSlippage = $(e8 0.05) : nat } }; noPartialFill = false })" --identity "$trader")

  if is_ok "$result" && ! is_err "$result"; then
    local to_amt
    to_amt=$(echo "$result" | tr -d '_' | grep -oE 'toAmount = [0-9.]+' | grep -oE '[0-9.]+' | head -1)
    ok "${trader}: ${CYAN}SWAP${NC} ${amount} ${from_token} -> $(d8 ${to_amt:-0}) ${to_token}"
    STAT_SWAP=$((STAT_SWAP + 1))
  else
    local msg
    msg=$(get_err_msg "$result")
    dim "${trader}: swap ${from_token}->${to_token} — ${msg:-call failed}"
    STAT_ERROR=$((STAT_ERROR + 1))
  fi
}

# ── Verification ──────────────────────────────────────────────────

run_verification() {
  echo ""
  echo -e "${BOLD}${CYAN}┌──────────────────────────────────────────────────┐${NC}"
  printf "${BOLD}${CYAN}│  Verification Check — Round %-22s│${NC}\n" "$STAT_ROUNDS"
  echo -e "${BOLD}${CYAN}└──────────────────────────────────────────────────┘${NC}"

  # ── Balance checks ──
  log "Checking balances..."
  local total_icpusd=0 total_btc=0 total_eth=0 total_icp=0
  local bal_ok=true

  for idx in $(seq 0 $((NUM_TRADERS - 1))); do
    local trader="${TRADER_NAMES[$idx]}"
    local p="${TRADER_PRINCIPALS[$idx]}"
    for tok in ICPUSD BTC ETH ICP; do
      local bal_result bal
      # Controller identity: getTestBalance is scoped to self-or-controller, and
      # this loop reads EVERY trader's balance, not trader_01's own.
      bal_result=$(call getTestBalance "(principal \"$p\", \"$tok\")" --identity anonymous)
      bal=$(extract_float "$bal_result")
      [ -z "$bal" ] && bal="0.0"

      # Check for negative
      local is_neg
      is_neg=$(awk -v b="$bal" 'BEGIN { print (b < -0.0001) ? "yes" : "no" }')
      if [ "$is_neg" = "yes" ]; then
        warn "NEGATIVE BALANCE: ${trader} has ${bal} ${tok}"
        bal_ok=false
      fi

      # Accumulate totals
      case "$tok" in
        ICPUSD) total_icpusd=$(awk -v a="$total_icpusd" -v b="$bal" 'BEGIN { printf "%.4f", a + b }') ;;
        BTC)    total_btc=$(awk -v a="$total_btc" -v b="$bal" 'BEGIN { printf "%.4f", a + b }') ;;
        ETH)    total_eth=$(awk -v a="$total_eth" -v b="$bal" 'BEGIN { printf "%.4f", a + b }') ;;
        ICP)    total_icp=$(awk -v a="$total_icp" -v b="$bal" 'BEGIN { printf "%.4f", a + b }') ;;
      esac
    done
  done

  if $bal_ok; then
    ok "All balances non-negative"
  fi

  # ── Order book checks ──
  log "Checking order books..."
  for mi in 0 1 2; do
    local market="${MARKETS[$mi]}"
    local ob
    ob=$(call getOrderBook "(\"$market\")" --identity trader_01)
    ob=$(echo "$ob" | tr -d '_')

    # Extract best bid and best ask prices
    local best_bid best_ask spread

    # Bids: highest price first (first record in bids vec)
    best_bid=$(echo "$ob" | tr -d '_' | sed -n 's/.*bids = vec {[[:space:]]*record {[[:space:]]*price = \([0-9.]*\).*/\1/p' | head -1)
    # If that didn't work, try a more permissive grep
    if [ -z "$best_bid" ]; then
      best_bid=$(echo "$ob" | tr -d '_' | tr ';' '\n' | grep -A2 'bids' | grep -oE 'price = [0-9.]+' | head -1 | grep -oE '[0-9.]+')
    fi

    best_ask=$(echo "$ob" | tr -d '_' | tr ';' '\n' | grep -A20 'asks' | grep -oE 'price = [0-9.]+' | head -1 | grep -oE '[0-9.]+')

    spread=$(echo "$ob" | tr -d '_' | grep -oE 'spread = [0-9.]+' | grep -oE '[0-9.]+' | head -1)

    # Candid Nat output is base units (10^8); the greps above strip `_` grouping —
    # now convert the non-empty parses to human prices (empty stays empty so the
    # downstream presence checks still work).
    [ -n "$best_bid" ] && best_bid=$(d8 "$best_bid")
    [ -n "$best_ask" ] && best_ask=$(d8 "$best_ask")
    [ -n "$spread" ]   && spread=$(d8 "$spread")

    if [ -n "$best_bid" ] && [ -n "$best_ask" ]; then
      local crossed
      crossed=$(awk -v bid="$best_bid" -v ask="$best_ask" 'BEGIN { print (bid >= ask) ? "yes" : "no" }')
      if [ "$crossed" = "yes" ]; then
        warn "CROSSED BOOK: ${market} bid=${best_bid} >= ask=${best_ask}"
      else
        ok "${market}: bid=${best_bid}  ask=${best_ask}  spread=${spread:-?}"
        # Update last price to midpoint
        LAST_PRICES[$mi]=$(awk -v b="$best_bid" -v a="$best_ask" 'BEGIN { printf "%.2f", (b + a) / 2 }')
      fi

      # Check spread reasonableness
      if [ -n "$spread" ] && [ -n "$best_bid" ]; then
        local mid pct
        mid=$(awk -v b="$best_bid" -v a="$best_ask" 'BEGIN { printf "%.2f", (b+a)/2 }')
        pct=$(awk -v s="$spread" -v m="$mid" 'BEGIN { if (m > 0) printf "%.2f", s/m*100; else print "0" }')
        local wide
        wide=$(awk -v p="$pct" 'BEGIN { print (p > 5) ? "yes" : "no" }')
        if [ "$wide" = "yes" ]; then
          dim "${market}: spread is ${pct}% (wide)"
        fi
      fi
    elif [ -z "$best_bid" ] && [ -z "$best_ask" ]; then
      dim "${market}: empty order book"
    else
      ok "${market}: bid=${best_bid:-none}  ask=${best_ask:-none}"
    fi
  done

  # ── Summary ──
  echo ""
  echo -e "  ${DIM}--- Stats ---${NC}"
  echo -e "  Rounds: ${BOLD}${STAT_ROUNDS}${NC}  |  Limits: ${STAT_LIMIT}  |  Markets: ${STAT_MARKET}  |  Cancels: ${STAT_CANCEL}  |  Swaps: ${STAT_SWAP}"
  echo -e "  Skipped: ${STAT_SKIP}  |  Errors: ${RED}${STAT_ERROR}${NC}  |  Warnings: ${YELLOW}${STAT_WARNINGS}${NC}"
  echo -e "  ${DIM}--- Balances (all traders) ---${NC}"
  echo -e "  ICPUSD: ${total_icpusd}  |  BTC: ${total_btc}  |  ETH: ${total_eth}  |  ICP: ${total_icp}"
  echo ""
}

# ── Signal Handler ────────────────────────────────────────────────
cleanup() {
  echo ""
  section "Simulation Stopped"
  echo ""
  echo -e "  Rounds completed:  ${BOLD}${STAT_ROUNDS}${NC}"
  echo -e "  Limit orders:      ${GREEN}${STAT_LIMIT}${NC}"
  echo -e "  Market orders:     ${GREEN}${STAT_MARKET}${NC}"
  echo -e "  Cancellations:     ${YELLOW}${STAT_CANCEL}${NC}"
  echo -e "  Swaps:             ${CYAN}${STAT_SWAP}${NC}"
  echo -e "  Skipped:           ${DIM}${STAT_SKIP}${NC}"
  echo -e "  Errors:            ${RED}${STAT_ERROR}${NC}"
  echo -e "  Warnings:          ${YELLOW}${STAT_WARNINGS}${NC}"
  echo ""
  local total=$((STAT_LIMIT + STAT_MARKET + STAT_CANCEL + STAT_SWAP))
  echo -e "  ${GREEN}Total actions: ${BOLD}${total}${NC}"
  echo ""
  # Teardown: remove the trader_NN identities from the global icp-cli
  # store. Every stored identity gets seeded at each `icp network start`,
  # and >~150 identities trip the CMC mint cap and break network start
  # machine-wide (see scripts/cleanup_identities.sh). Recreated fresh
  # (new principals) on the next run — balances are re-set then anyway.
  log "Deleting ${NUM_TRADERS} trader identities..."
  for i in $(seq -w 1 $NUM_TRADERS); do
    echo "y" | icp identity delete "trader_$i" >/dev/null 2>&1 || true
  done
  exit 0
}
trap cleanup SIGINT SIGTERM

# ══════════════════════════════════════════════════════════════════
# Phase 1: Initialization
# ══════════════════════════════════════════════════════════════════

section "Phase 1: Initialization"
echo ""

# Create identities
log "Creating ${NUM_TRADERS} trader identities..."
for i in $(seq -w 1 $NUM_TRADERS); do
  name="trader_$i"
  icp identity new "$name" --storage plaintext 2>/dev/null || true
  TRADER_NAMES+=("$name")
  TRADER_PRINCIPALS+=("$(icp identity principal --identity "$name" 2>/dev/null)")
done
ok "${NUM_TRADERS} identities ready"

# Reset if requested
# Admin endpoints (resetExchange, setTestBalance) require the caller to
# be a canister controller. cold_start.sh promotes `alice` to controller
# at deploy time so admin scripts can keep using --identity alice.
if $RESET_FIRST; then
  log "Resetting exchange..."
  call resetExchange --identity alice > /dev/null
  ok "Exchange reset"
fi

# Set balances — $100k VALUE per trader, parity with real players (whose
# play-mode deposit allowance is $100k lifetime): $40k ICPUSD cash + $15k
# of each asset, quantities derived from the startup prices so the parity
# holds wherever the market happens to be trading.
BOT_CASH_USD=40000
BOT_ALLOC_USD=15000
Q_BTC=$(awk -v a="$BOT_ALLOC_USD" -v p="${LAST_PRICES[0]}" 'BEGIN{printf "%.6f", a/p}')
Q_ETH=$(awk -v a="$BOT_ALLOC_USD" -v p="${LAST_PRICES[1]}" 'BEGIN{printf "%.6f", a/p}')
Q_SOL=$(awk -v a="$BOT_ALLOC_USD" -v p="${LAST_PRICES[2]}" 'BEGIN{printf "%.6f", a/p}')
Q_ICP=$(awk -v a="$BOT_ALLOC_USD" -v p="${LAST_PRICES[3]}" 'BEGIN{printf "%.6f", a/p}')
log "Setting balances for all traders (~\$100k value each: \$${BOT_CASH_USD} cash + \$${BOT_ALLOC_USD}/asset)..."
for idx in $(seq 0 $((NUM_TRADERS - 1))); do
  trader="${TRADER_NAMES[$idx]}"
  p="${TRADER_PRINCIPALS[$idx]}"
  call setTestBalance "(principal \"$p\", \"ICPUSD\", $(e8 $BOT_CASH_USD))" --identity alice > /dev/null
  call setTestBalance "(principal \"$p\", \"BTC\", $(e8 $Q_BTC))" --identity alice > /dev/null
  call setTestBalance "(principal \"$p\", \"ETH\", $(e8 $Q_ETH))" --identity alice > /dev/null
  call setTestBalance "(principal \"$p\", \"SOL\", $(e8 $Q_SOL))" --identity alice > /dev/null
  call setTestBalance "(principal \"$p\", \"ICP\", $(e8 $Q_ICP))" --identity alice > /dev/null
  # Materialise the friendly username (lazy-created on first getMyProfile) so
  # the trader shows as "Adjective-Noun-NN" on the leaderboard / OQL, not a
  # principal stub.
  call getMyProfile "()" --identity "$trader" > /dev/null 2>&1 || true
done
ok "Balances set for ${NUM_TRADERS} traders (BTC=$Q_BTC ETH=$Q_ETH SOL=$Q_SOL ICP=$Q_ICP each)"

# Seed initial order book ladders.
# Uses LAST_PRICES (live oracle/canister value, captured at startup),
# NOT DEFAULT_PRICES (which is a stale fallback for offline testing).
# A previous version of this loop hardcoded DEFAULT_PRICES, which
# meant SOL ladders got placed around the fallback $200 instead of
# the real ~$83, producing visible price-drop artefacts as the AMM
# arbitraged the simulator's bad book back to oracle.
# Loop covers all four markets (was three — ICP was being skipped).
log "Placing initial order book ladders..."
INIT_ORDERS=0
for mi in 0 1 2 3; do
  market="${MARKETS[$mi]}"
  base_price="${LAST_PRICES[$mi]}"
  min_q="${MIN_QTYS[$mi]}"
  max_q="${MAX_QTYS[$mi]}"
  for i in 1 2 3 4 5; do
    trader="trader_$(printf '%02d' $i)"
    # Two levels/side (was three): with $100k wallets a 3-level ladder across
    # four markets could outrun a trader's cash/inventory and spray
    # insufficient-balance skips.
    for level in 1 2; do
      # Ask (sell) above current price
      ask_price=$(awk -v bp="$base_price" -v l="$level" -v t="$i" \
        'BEGIN { printf "%.2f", bp * (1 + 0.002 * l + 0.0005 * t) }')
      qty=$(rand_float "$min_q" "$max_q" 4)
      call placeLimitOrder "(\"$market\", variant { sell }, $(e8 $ask_price), $(e8 $qty))" --identity "$trader" > /dev/null
      INIT_ORDERS=$((INIT_ORDERS + 1))

      # Bid (buy) below current price
      bid_price=$(awk -v bp="$base_price" -v l="$level" -v t="$i" \
        'BEGIN { printf "%.2f", bp * (1 - 0.002 * l - 0.0005 * t) }')
      qty=$(rand_float "$min_q" "$max_q" 4)
      call placeLimitOrder "(\"$market\", variant { buy }, $(e8 $bid_price), $(e8 $qty))" --identity "$trader" > /dev/null
      INIT_ORDERS=$((INIT_ORDERS + 1))
    done
  done
done
ok "${INIT_ORDERS} initial orders placed across ${#MARKETS[@]} markets"

# ══════════════════════════════════════════════════════════════════
# Phase 2: Continuous Trading Loop
# ══════════════════════════════════════════════════════════════════

section "Phase 2: Trading Simulation"
limit_label="infinite"
[ "$MAX_ROUNDS" -gt 0 ] 2>/dev/null && limit_label="$MAX_ROUNDS"
echo -e "  Speed: ${BOLD}${SPEED}${NC}  |  Rounds: ${BOLD}${limit_label}${NC}  |  Verify every: ${VERIFY_EVERY}"
echo -e "  ${DIM}Press Ctrl+C to stop${NC}"

ROUND=0

while true; do
  ROUND=$((ROUND + 1))
  STAT_ROUNDS=$ROUND

  # Check round limit
  if [ "$MAX_ROUNDS" -gt 0 ] 2>/dev/null && [ "$ROUND" -gt "$MAX_ROUNDS" ]; then
    break
  fi

  echo -e "\n${CYAN}-- Round ${ROUND} --${NC}"

  # Select 5-12 random traders for this round
  num_active=$(rand_int 5 12)
  # Build shuffled subset
  active_indices=""
  for _attempt in $(seq 1 50); do
    local_idx=$((RANDOM % NUM_TRADERS))
    # Check if already selected
    case " $active_indices " in
      *" $local_idx "*) continue ;;
    esac
    active_indices="$active_indices $local_idx"
    count=$(echo $active_indices | wc -w | tr -d ' ')
    [ "$count" -ge "$num_active" ] && break
  done

  for tidx in $active_indices; do
    trader="${TRADER_NAMES[$tidx]}"

    # Weighted random action. Cancels sit near the limit rate on purpose:
    # unfilled GTC orders otherwise accumulate on the book forever (the
    # backend's per-user cap bounds it server-side; matching the rates here
    # keeps the sim off that guardrail and the book turnover realistic).
    roll=$((RANDOM % 100))
    if   [ "$roll" -lt 35 ]; then
      action_limit_order "$trader"
    elif [ "$roll" -lt 60 ]; then
      action_market_order "$trader"
    elif [ "$roll" -lt 85 ]; then
      action_cancel_order "$trader"
    elif [ "$roll" -lt 95 ]; then
      action_swap "$trader"
    else
      dim "${trader}: skip"
      STAT_SKIP=$((STAT_SKIP + 1))
    fi
  done

  # Verification every N rounds
  if [ $((ROUND % VERIFY_EVERY)) -eq 0 ]; then
    run_verification
  fi

  random_sleep
done

# If we reached the round limit, run final verification and exit
run_verification
cleanup
