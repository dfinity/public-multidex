#!/bin/bash
# Heavy-handed test: run a battery of trades + AMM activity and then
# assert global state coherence. Catches accounting drift, balance
# leaks, double-spends, and zombie orders that creep in under load.
#
# Different from the per-test invariant check (which runs after every
# test): this test EXISTS specifically to drive the system through
# diverse activity then check the invariants hold. Slow (~30s of
# fixture activity) but worth it as a regression backstop.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_invariants_battery ──"
setup_mode full

# Sanity-check the seed itself.
INITIAL_VAULT=$(call getVaultValue '()')
INITIAL_LP=$(extract_float "lpSupply" "$INITIAL_VAULT")
assert_gt "seeded with vault LP supply" "${INITIAL_LP:-0}" "0"

# ── Run a battery of taker activity ──────────────────────────────
mdx_identity_new battery
B=$(principal_of battery)
call setTestBalance "(principal \"$B\", \"ICPUSD\", $(e8 500000.0))" --identity alice > /dev/null
call setTestBalance "(principal \"$B\", \"BTC\",     $(e8 2.0))"     --identity alice > /dev/null
call setTestBalance "(principal \"$B\", \"ETH\",    $(e8 50.0))"     --identity alice > /dev/null
call setTestBalance "(principal \"$B\", \"SOL\",   $(e8 200.0))"     --identity alice > /dev/null
call setTestBalance "(principal \"$B\", \"ICP\", $(e8 10000.0))"     --identity alice > /dev/null

# Mix of limit + market orders across all four markets. Each call
# might cross or rest depending on book state; we don't care which.
echo "  ... running 20 mixed orders ..."
for i in $(seq 1 5); do
  call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 75500.0), $(e8 0.01))" --identity battery > /dev/null
  call placeMarketOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 0.01), $(e8 0.05), false)" --identity battery > /dev/null
  call placeLimitOrder "(\"ETH-ICPUSD\", variant { buy }, $(e8 2280.0), $(e8 0.5))" --identity battery > /dev/null
  call placeMarketOrder "(\"SOL-ICPUSD\", variant { sell }, $(e8 1.0), $(e8 0.05), false)" --identity battery > /dev/null
done

# Let any pending matches settle and timer-driven AMM activity tick.
echo "  ... waiting 12s for timer-driven settlement ..."
sleep 12

# ── Invariants ────────────────────────────────────────────────────

# I-A: Sum of LP balances == vaultLPSupply (this is also in the
# global assert_invariants but we re-verify here as a smoke test on
# the helper — with the SAME absolute base-unit tolerance, i1_tol_e8 from
# _lib.sh: a 1% relative band here let ~300 whole tokens of drift through
# in the very file that smoke-tests the fix (#51.5 second site).
VAULT=$(call getVaultValue '()')
LP_SUPPLY=$(extract_nat "lpSupply" "$VAULT")
SUM=0
for ident in alice bob charlie dave eve battery; do
  PRI=$(principal_of "$ident" 2>/dev/null) || continue
  [ -z "$PRI" ] && continue
  BAL=$(call getMyVaultLp '()' --identity "$ident" | tr -d '_' | grep -oE "[0-9]+" | head -1)
  [ -z "$BAL" ] && BAL=0
  SUM=$(python3 -c "print($SUM + $BAL)")
done
assert_abs_close "Σ user LP == vaultLPSupply (base units, ±${i1_tol_e8})" "${LP_SUPPLY:-0}" "$SUM" "$i1_tol_e8"

# I-B: No 0-qty orders on any book (zombie regression).
ZOMBIES=0
for m in BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD; do
  BOOK=$(call getOrderBook "(\"$m\")")
  # Integer money: a zeroed quantity now renders as `quantity = 0 : nat`.
  N=$(echo "$BOOK" | grep -c "quantity = 0 :" || true)
  ZOMBIES=$(( ZOMBIES + N ))
done
assert_eq "no 0-qty zombie orders post-battery" "0" "$ZOMBIES"

# I-C: All AMM pools still have positive refPrice (silent "refPrice
# went to zero" failure mode).
POOLS=$(call getAmmPools '()')
# Integer money: a zero refPrice now renders as `refPrice = 0 : nat`.
ZERO_REF=$(echo "$POOLS" | grep -c "refPrice = 0 :" || true)
assert_eq "no AMM pool with refPrice=0" "0" "$ZERO_REF"

# I-D: Vault refPrice mark-to-market is consistent with itself —
# totalQuoteValue should equal Σ basket × prices + cash.
COMPUTED=$(echo "$VAULT" | python3 -c "
import sys, re
t = sys.stdin.read().replace('_', '')
# Integer money: every basket qty, price, and cash figure is a base-unit Nat
# (10^8). Convert each to human units (÷1e8) before multiplying so the product
# stays in human ICPUSD (a raw qty_e8 × price_e8 would be scaled 10^16).
E8 = 100000000.0
def f(name):
  m = re.search(rf'    {name}\s*=\s*([0-9]+)', t)
  return (int(m.group(1)) / E8) if m else 0.0
basket_vals = [
  ('btc', f('btc')), ('eth', f('eth')), ('sol', f('sol')), ('icp', f('icp'))
]
# Prices are in a sub-record; parse from the text after 'prices ='.
prices_text = t.split('prices =')[1] if 'prices =' in t else ''
def fp(name):
  m = re.search(rf'{name}\s*=\s*([0-9]+)', prices_text)
  return (int(m.group(1)) / E8) if m else 0.0
total = 0.0
for token, qty in basket_vals:
  total += qty * fp(token)
# Cash is the icpusd in basket (base-unit Nat → human).
icpusd = re.search(r'icpusd\s*=\s*([0-9]+)', t.split('basket =')[1] if 'basket =' in t else t)
total += (int(icpusd.group(1)) / E8) if icpusd else 0.0
print(total)
")
TQV=$(from_e8 "$(extract_nat "totalQuoteValue" "$VAULT")")
assert_float_close "totalQuoteValue == Σ basket × prices + cash" "$COMPUTED" "$TQV" 0.01

# I-E: Reserved balances empty for all named identities (everything
# settled in the 12s wait).
for ident in alice bob; do
  R=$(call getMyReservedBalance '("ICPUSD")' --identity "$ident" \
      | grep -oE "[0-9]+" | head -1)
  R=$(from_e8 "${R:-0}")
  assert_float_close "$ident ICPUSD reserved cleared" "0" "${R:-0}" 0.01
done

finish_test "test_invariants_battery"
