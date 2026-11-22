#!/bin/bash
# UPLANDS DEX Integration Tests
# This script tests the exchange by:
# 1) Resetting all exchange markets
# 2) Creating dummy users (using different identities)
# 3) Setting balances for dummy users
# 4) Creating buy and sell orders across markets
# 5) Verifying results after order execution

export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics

BACKEND="tz2ag-zx777-77776-aaabq-cai"
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

pass() {
  echo -e "${GREEN}✓ PASS${NC}: $1"
  ((passed++))
}

fail() {
  echo -e "${RED}✗ FAIL${NC}: $1 — $2"
  ((failed++))
}

# Every call site MUST name its identity: the CLI's global default identity
# is machine-shared mutable state that other sessions and connectors move
# at will (mdex-process-safety §5) — an identity-less call would run the
# test as whoever happens to be active. All current uses pass --identity;
# refuse loudly if a new one doesn't.
call() {
  case " $* " in
    *" --identity "*) ;;
    *) echo -e "${RED}✗${NC} call() without --identity (mdex-process-safety §5): $*" >&2; return 1 ;;
  esac
  echo "y" | icp canister call backend "$@" 2>&1
}

# ── DEPRECATED ───────────────────────────────────────────────────
# Superseded by tests/run_all.sh (the test_*.sh suite + tests/_lib.sh). This
# script's balance/order literals are pre-integer-money DECIMAL amounts; the
# backend now takes Nat base units (10^8), so every money-bearing call fails
# candid serialization and ~16/21 checks red regardless of venue state.
# Kept only for historical reference. Use:  bash tests/run_all.sh
echo -e "${YELLOW}run_tests.sh is DEPRECATED${NC} — it sends pre-migration Float money." >&2
echo "Use the integer-money suite instead:  bash tests/run_all.sh" >&2
exit 1

echo "======================================"
echo "  UPLANDS DEX Integration Tests"
echo "======================================"
echo ""

# ── Step 0: Create test identities ─────────────────────────────
echo -e "${YELLOW}Setting up test identities...${NC}"

# Create the STANDING test identities if they don't exist (kept across runs —
# never mdx_identity_new, which would delete them on EXIT)
mdx_identity_ensure alice
mdx_identity_ensure bob
mdx_identity_ensure charlie

ALICE_PRINCIPAL=$(icp identity principal --identity alice 2>/dev/null)
BOB_PRINCIPAL=$(icp identity principal --identity bob 2>/dev/null)
CHARLIE_PRINCIPAL=$(icp identity principal --identity charlie 2>/dev/null)

echo "Alice:   $ALICE_PRINCIPAL"
echo "Bob:     $BOB_PRINCIPAL"
echo "Charlie: $CHARLIE_PRINCIPAL"
echo ""

# ── Step 1: Reset exchange ──────────────────────────────────────
echo -e "${YELLOW}Step 1: Resetting exchange...${NC}"
call resetExchange --identity alice
pass "Exchange reset"
echo ""

# ── Step 2: Set up balances ─────────────────────────────────────
echo -e "${YELLOW}Step 2: Setting up user balances...${NC}"

# Alice: Rich trader - lots of ICPUSD and some BTC/ETH
call setTestBalance "(principal \"$ALICE_PRINCIPAL\", \"ICPUSD\", 100000.0)" --identity alice
call setTestBalance "(principal \"$ALICE_PRINCIPAL\", \"BTC\", 2.0)" --identity alice
call setTestBalance "(principal \"$ALICE_PRINCIPAL\", \"ETH\", 50.0)" --identity alice
call setTestBalance "(principal \"$ALICE_PRINCIPAL\", \"ICP\", 5000.0)" --identity alice

# Bob: Medium trader
call setTestBalance "(principal \"$BOB_PRINCIPAL\", \"ICPUSD\", 50000.0)" --identity bob
call setTestBalance "(principal \"$BOB_PRINCIPAL\", \"BTC\", 1.0)" --identity bob
call setTestBalance "(principal \"$BOB_PRINCIPAL\", \"ETH\", 20.0)" --identity bob
call setTestBalance "(principal \"$BOB_PRINCIPAL\", \"ICP\", 2000.0)" --identity bob

# Charlie: Small trader
call setTestBalance "(principal \"$CHARLIE_PRINCIPAL\", \"ICPUSD\", 10000.0)" --identity charlie
call setTestBalance "(principal \"$CHARLIE_PRINCIPAL\", \"BTC\", 0.5)" --identity charlie
call setTestBalance "(principal \"$CHARLIE_PRINCIPAL\", \"ETH\", 10.0)" --identity charlie

pass "User balances set"

# Verify balances
ALICE_ICPUSD=$(call getTestBalance "(principal \"$ALICE_PRINCIPAL\", \"ICPUSD\")" --identity alice)
if echo "$ALICE_ICPUSD" | grep -q "100000"; then
  pass "Alice ICPUSD balance verified: 100000"
else
  fail "Alice ICPUSD balance" "Expected 100000, got: $ALICE_ICPUSD"
fi
echo ""

# ── Step 3: Test market listing ─────────────────────────────────
echo -e "${YELLOW}Step 3: Verifying markets...${NC}"
MARKETS=$(call getMarkets --identity alice)
if echo "$MARKETS" | grep -q "BTC-ICPUSD"; then
  pass "BTC-ICPUSD market exists"
else
  fail "BTC-ICPUSD market" "Not found in: $MARKETS"
fi
if echo "$MARKETS" | grep -q "ETH-ICPUSD"; then
  pass "ETH-ICPUSD market exists"
else
  fail "ETH-ICPUSD market" "Not found"
fi
if echo "$MARKETS" | grep -q "ICP-ICPUSD"; then
  pass "ICP-ICPUSD market exists"
else
  fail "ICP-ICPUSD market" "Not found"
fi
echo ""

# ── Step 4: Place limit orders (build the book) ────────────────
echo -e "${YELLOW}Step 4: Placing limit orders on BTC-ICPUSD...${NC}"

# Alice places sell orders (asks)
RESULT=$(call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 68000.0, 0.5)' --identity alice)
if mdx_ok "$RESULT"; then
  pass "Alice sell 0.5 BTC @ 68000"
else
  fail "Alice sell order" "$RESULT"
fi

RESULT=$(call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 69000.0, 0.3)' --identity alice)
if mdx_ok "$RESULT"; then
  pass "Alice sell 0.3 BTC @ 69000"
else
  fail "Alice sell order 2" "$RESULT"
fi

# Bob places buy orders (bids)
RESULT=$(call placeLimitOrder '("BTC-ICPUSD", variant { buy }, 67000.0, 0.4)' --identity bob)
if mdx_ok "$RESULT"; then
  pass "Bob buy 0.4 BTC @ 67000"
else
  fail "Bob buy order" "$RESULT"
fi

RESULT=$(call placeLimitOrder '("BTC-ICPUSD", variant { buy }, 66500.0, 0.6)' --identity bob)
if mdx_ok "$RESULT"; then
  pass "Bob buy 0.6 BTC @ 66500"
else
  fail "Bob buy order 2" "$RESULT"
fi
echo ""

# ── Step 5: Verify order book ──────────────────────────────────
echo -e "${YELLOW}Step 5: Checking order book...${NC}"
BOOK=$(call getOrderBook '("BTC-ICPUSD")' --identity alice)
echo "Order book: $BOOK"
if echo "$BOOK" | grep -q "68000"; then
  pass "Ask at 68000 visible"
else
  fail "Ask at 68000" "Not in book"
fi
if echo "$BOOK" | grep -q "67000"; then
  pass "Bid at 67000 visible"
else
  fail "Bid at 67000" "Not in book"
fi
echo ""

# ── Step 6: Test order matching (market order) ─────────────────
echo -e "${YELLOW}Step 6: Charlie places market buy order...${NC}"

# Charlie buys 0.2 BTC at market (should match Alice's 68000 ask)
RESULT=$(call placeMarketOrder '("BTC-ICPUSD", variant { buy }, 0.2, 0.10, false)' --identity charlie)
echo "Market order result: $RESULT"
if mdx_ok "$RESULT"; then
  pass "Charlie market buy 0.2 BTC executed"
else
  fail "Charlie market buy" "$RESULT"
fi

# Check Charlie received BTC
CHARLIE_BTC=$(call getTestBalance "(principal \"$CHARLIE_PRINCIPAL\", \"BTC\")" --identity charlie)
echo "Charlie BTC after buy: $CHARLIE_BTC"
# Charlie had 0.5 BTC and 10000 ICPUSD. At 68000/BTC, he can buy 10000/68000 ≈ 0.147 BTC
# So total should be ~0.647
if echo "$CHARLIE_BTC" | grep -q "0.647"; then
  pass "Charlie BTC balance correct after market buy (~0.647)"
else
  # Accept any increase above 0.5
  CHARLIE_BTC_VAL=$(echo "$CHARLIE_BTC" | grep -o '[0-9]*\.[0-9]*' | head -1)
  if [ "$(echo "$CHARLIE_BTC_VAL > 0.5" | bc 2>/dev/null)" = "1" ] 2>/dev/null; then
    pass "Charlie BTC balance increased from 0.5 to $CHARLIE_BTC_VAL"
  else
    fail "Charlie BTC balance" "Expected >0.5, got: $CHARLIE_BTC"
  fi
fi
echo ""

# ── Step 7: Test ETH-ICPUSD market ────────────────────────────
echo -e "${YELLOW}Step 7: Testing ETH-ICPUSD market...${NC}"

# Alice sells ETH
RESULT=$(call placeLimitOrder '("ETH-ICPUSD", variant { sell }, 3500.0, 5.0)' --identity alice)
if mdx_ok "$RESULT"; then
  pass "Alice sell 5 ETH @ 3500"
else
  fail "Alice ETH sell" "$RESULT"
fi

# Bob buys ETH (should match Alice's ask)
RESULT=$(call placeLimitOrder '("ETH-ICPUSD", variant { buy }, 3500.0, 2.0)' --identity bob)
echo "Bob ETH buy result: $RESULT"
if mdx_ok "$RESULT"; then
  pass "Bob buy 2 ETH @ 3500 (should match)"
else
  fail "Bob ETH buy" "$RESULT"
fi

# Check Bob received ETH
BOB_ETH=$(call getTestBalance "(principal \"$BOB_PRINCIPAL\", \"ETH\")" --identity bob)
echo "Bob ETH after buy: $BOB_ETH"
echo ""

# ── Step 8: Test order cancellation ────────────────────────────
echo -e "${YELLOW}Step 8: Testing order cancellation...${NC}"

# Bob places an order then cancels it
RESULT=$(call placeLimitOrder '("ICP-ICPUSD", variant { buy }, 10.0, 100.0)' --identity bob)
ORDER_ID=$(echo "$RESULT" | grep -o 'id = [0-9]*' | head -1 | awk '{print $3}')
echo "Bob placed order ID: $ORDER_ID"

if [ -n "$ORDER_ID" ]; then
  CANCEL_RESULT=$(call cancelMyOrder "($ORDER_ID)" --identity bob)
  if mdx_ok "$CANCEL_RESULT"; then
    pass "Order $ORDER_ID cancelled successfully"
  else
    fail "Cancel order" "$CANCEL_RESULT"
  fi
else
  fail "Place order for cancel test" "Could not get order ID"
fi
echo ""

# ── Step 9: Test liquidity re-use (buy orders across markets) ──
echo -e "${YELLOW}Step 9: Testing liquidity re-use...${NC}"

# Alice has 100000 ICPUSD (minus what she spent)
# She places buy orders across multiple markets that individually are OK
# but together would exceed her balance

RESULT=$(call placeLimitOrder '("BTC-ICPUSD", variant { buy }, 65000.0, 1.0)' --identity alice)
if mdx_ok "$RESULT"; then
  pass "Alice buy 1 BTC @ 65000 (65000 ICPUSD)"
else
  fail "Alice cross-market buy 1" "$RESULT"
fi

RESULT=$(call placeLimitOrder '("ETH-ICPUSD", variant { buy }, 3000.0, 15.0)' --identity alice)
if mdx_ok "$RESULT"; then
  pass "Alice buy 15 ETH @ 3000 (45000 ICPUSD)"
else
  fail "Alice cross-market buy 2" "$RESULT"
fi

# Check Alice's open orders
ORDERS=$(call getMyOrders --identity alice)
echo "Alice open orders count: $(echo "$ORDERS" | grep -c 'id =' || echo 0)"
echo ""

# ── Step 10: Test insufficient balance rejection ──────────────
echo -e "${YELLOW}Step 10: Testing balance validation...${NC}"

# Charlie tries to sell more BTC than he has
RESULT=$(call placeLimitOrder '("BTC-ICPUSD", variant { sell }, 70000.0, 100.0)' --identity charlie)
if echo "$RESULT" | grep -q "err"; then
  pass "Rejected: Charlie sell 100 BTC (insufficient)"
else
  fail "Should reject insufficient balance" "$RESULT"
fi

# Test minimum order size
RESULT=$(call placeLimitOrder '("BTC-ICPUSD", variant { buy }, 0.001, 0.5)' --identity charlie)
if echo "$RESULT" | grep -q "err"; then
  pass "Rejected: Order below minimum ICPUSD value"
else
  # May succeed if 0.001 * 0.5 = 0.0005 < 1 ICPUSD min
  echo "Note: Order may have succeeded if above minimum"
fi
echo ""

# ── Step 11: Test recent trades ───────────────────────────────
echo -e "${YELLOW}Step 11: Checking recent trades...${NC}"
TRADES=$(call getRecentTrades '("BTC-ICPUSD")' --identity alice)
if echo "$TRADES" | grep -q "price"; then
  pass "Recent trades available for BTC-ICPUSD"
else
  fail "Recent trades" "No trades found"
fi
echo ""

# ── Step 12: Verify final balances ────────────────────────────
echo -e "${YELLOW}Step 12: Final balance verification...${NC}"
echo "Alice balances:"
call getTestBalance "(principal \"$ALICE_PRINCIPAL\", \"ICPUSD\")" --identity alice
call getTestBalance "(principal \"$ALICE_PRINCIPAL\", \"BTC\")" --identity alice
call getTestBalance "(principal \"$ALICE_PRINCIPAL\", \"ETH\")" --identity alice
echo ""
echo "Bob balances:"
call getTestBalance "(principal \"$BOB_PRINCIPAL\", \"ICPUSD\")" --identity bob
call getTestBalance "(principal \"$BOB_PRINCIPAL\", \"BTC\")" --identity bob
call getTestBalance "(principal \"$BOB_PRINCIPAL\", \"ETH\")" --identity bob
echo ""
echo "Charlie balances:"
call getTestBalance "(principal \"$CHARLIE_PRINCIPAL\", \"ICPUSD\")" --identity charlie
call getTestBalance "(principal \"$CHARLIE_PRINCIPAL\", \"BTC\")" --identity charlie
echo ""

# ── Summary ────────────────────────────────────────────────────
echo "======================================"
echo "  Test Results: ${GREEN}${passed} passed${NC}, ${RED}${failed} failed${NC}"
echo "======================================"

# ── Teardown: prune throwaway identities ───────────────────────
# Standalone test_*.sh scripts create one-off identities (mpool, b2b_*,
# amm_u*, …) on demand and leave them in the GLOBAL icp-cli store.
# `icp network start` seeds every stored identity, and at ~150 of them
# the CMC's 150,000T-cycles/hour mint cap aborts every fresh network
# start on this machine. Sweep them here; they're recreated on demand.
bash "$(dirname "$0")/../scripts/cleanup_identities.sh" --yes || true

if [ $failed -gt 0 ]; then
  exit 1
fi
