#!/bin/bash
# Property-based fuzz test. Runs N rounds of randomized order
# placement against a fresh canister, then asserts global invariants.
#
# Goal: catch the kind of accounting drift that example-based tests
# miss because they exercise only specific code paths. Random orders
# of mixed sides + qty + price across all four markets exercise many
# combinations that we'd never enumerate by hand.
#
# What's a property here?
#   1. Total token supply per token is conserved
#      (no money created/destroyed across all the random trades).
#   2. No 0-qty zombie orders left on any book at the end.
#   3. Every "ok" placeLimitOrder either rests as a real order
#      (>0 qty) or settles into trades or pending matches — no
#      ghost state.
#
# Seed = derived from script start time, so reruns differ. If you
# want to reproduce a flaky failure, set FUZZ_SEED in the env.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_property_fuzz ──"
setup_mode empty

# Pin the auto-fuel loop off for the conservation window. Its Stage-1
# (tickAutoFuel, src/backend/main.mo) BUYS ICP on ICP-ICPUSD with the
# treasury's fee-accrued ICPUSD whenever cycle headroom drops below
# max(2T, burnPerDay) — and a fresh cold-start's seeding burst inflates the
# burnPerDay EMA enough to arm that trigger for the following ~half hour.
# The buy is a legitimate flow, but it lifts the fuzz traders' resting ICP
# asks into treasuryIcpE8s, which the per-token trader sums below exclude —
# and no summation closes the set while the loop is live, because Stage-2
# then BURNS internal ICP outright (backed by the chain spend). Seen once
# mid-suite 2026-08-06 (~05:55): ICP short by exactly one Stage-1 tranche,
# 771,457,372 e8s ≈ the treasury's ~$18.5 accrual at the 2.40±2% band;
# reproduced deterministically by timing a run across the loop's 10-min
# cooldown lapse (deficit == treasuryIcpE8s to the base unit). ICPUSD never
# breaks: the tranche the treasury spends lands on the sellers, both inside
# the quote frame. Restored before finish_test.
call setAutoFuel "(false)" --identity alice > /dev/null

ROUNDS="${FUZZ_ROUNDS:-50}"
SEED="${FUZZ_SEED:-$(date +%s)}"
echo "  seed=$SEED  rounds=$ROUNDS"

# Bootstrap traders and a tight book for the AMM-less scenario. We
# avoid AMM here because the AMM tick injects asynchronous activity
# that confuses the conservation accounting (counts only test-trader
# balances, not the live AMM ones — adding the AMM principal makes
# the math tractable but also widens the test surface beyond what
# we want to fuzz).

TRADERS=(alice bob charlie dave eve)
# All five are the venue's STANDING fixtures (scripts/seed.sh ensure_identity
# seeds them; run_tests.sh / deploy.sh mint alice/bob/charlie; 20+ suites sign
# with them) — ensured, never deleted. A name added here that is NOT a seed
# fixture belongs in the mdx_identity_new arm so it leaves with the run.
for t in "${TRADERS[@]}"; do case "$t" in alice|bob|charlie|dave|eve) mdx_identity_ensure "$t" ;; *) mdx_identity_new "$t" ;; esac; done

# Generous initial balances — orders are randomly sized but capped
# below 1 BTC / 5 ETH / 25 SOL / 1000 ICP so plenty of headroom.
# (setTestBalance takes a base-unit Nat now → e8.)
for t in "${TRADERS[@]}"; do
  P=$(principal_of "$t")
  call setTestBalance "(principal \"$P\", \"BTC\",        $(e8 20.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$P\", \"ETH\",       $(e8 400.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$P\", \"SOL\",      $(e8 4000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$P\", \"ICP\",     $(e8 50000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 2000000.0))" --identity alice > /dev/null
done

MARKETS=(BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD)
TOKENS=(BTC ETH SOL ICP)
MIDS=(75000 2300 85 2.40)
QTY_MAX=(0.5 5 25 1000)
PCT_RANGE=2  # ±2% around mid for random pricing

# Helper: sum supply of `token` across all traders. getTestBalance returns a
# base-unit Nat now — strip Candid underscores and read the integer. The sum
# stays in base units; before/after snapshots use the same scale so the
# conservation comparison is exact.
#
# For ICPUSD we ALSO fold in the treasury AND the AMM vault balances: the
# symmetric maker/taker fee skims quote-leg ICPUSD out of the trading parties
# and SPLITS it — half to the LP vault (the AMM principal; drain fix 4), half
# to the treasury — on every fill. Including both closes the accounting set so
# the quote total stays conserved exactly. (`setup_mode empty` runs
# resetExchange, which zeroes both, so they start at 0. Base tokens are
# transferred whole and are fee-free, so they need no such terms.)
#
# Base tokens have exactly one venue-side sink — auto-fuel Stage-1 buying
# ICP into the treasury — and that loop is pinned off above for the window.
#
# getTestBalance is scoped to self-or-controller and every read here is
# cross-principal, so call as anonymous (the local controller) — the bare
# ambient identity would read silent zeros and gut the conservation check.
total_of() {
  local token="$1"
  local sum=0
  for t in "${TRADERS[@]}"; do
    P=$(principal_of "$t")
    BAL=$(call getTestBalance "(principal \"$P\", \"$token\")" --identity anonymous \
          | tr -d '_' | grep -oE "[0-9]+" | head -1)
    sum=$(python3 -c "print($sum + ${BAL:-0})")
  done
  if [ "$token" = "ICPUSD" ]; then
    TREAS=$(call getTreasury '()' | tr -d '_' \
            | grep -oE "balanceUsd = [0-9]+" | grep -oE "[0-9]+")
    AMMP=$(call getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
    VAULT=$(call getTestBalance "(principal \"$AMMP\", \"$token\")" --identity anonymous \
            | tr -d '_' | grep -oE "[0-9]+" | head -1)
    sum=$(python3 -c "print($sum + ${TREAS:-0} + ${VAULT:-0})")
  fi
  echo "$sum"
}

# Snapshot supply of every token before the fuzz run.
declare -a BEFORE
for tk in "${TOKENS[@]}" ICPUSD; do
  BEFORE+=( "$(total_of "$tk")" )
done

# Use python for deterministic seeded RNG so a failing seed is
# replayable across runs.
ORDERS_FILE=$(mktemp)
python3 - "$SEED" "$ROUNDS" "${MARKETS[@]}" "${MIDS[@]}" "${QTY_MAX[@]}" <<'PY' > "$ORDERS_FILE"
import sys, random
seed = int(sys.argv[1]); rounds = int(sys.argv[2])
markets = sys.argv[3:7]
mids    = [float(x) for x in sys.argv[7:11]]
qty_max = [float(x) for x in sys.argv[11:15]]
random.seed(seed)
for _ in range(rounds):
    i = random.randint(0, 3)
    side = random.choice(["buy", "sell"])
    pct = random.uniform(-2.0, 2.0)
    px = mids[i] * (1 + pct / 100)
    qty = random.uniform(qty_max[i] * 0.05, qty_max[i])
    trader = f"trader_{random.randint(0, 4)}"
    print(f"{trader}\t{markets[i]}\t{side}\t{px:.6f}\t{qty:.6f}")
PY

# Map trader_N → real identity name.
trader_for() {
  case "$1" in
    trader_0) echo alice ;;
    trader_1) echo bob ;;
    trader_2) echo charlie ;;
    trader_3) echo dave ;;
    *)        echo eve ;;
  esac
}

ACCEPTED=0
REJECTED=0
while IFS=$'\t' read -r tr market side px qty; do
  ident=$(trader_for "$tr")
  # px/qty come out of the generator as human floats → e8 to base-unit Nats.
  RES=$(call placeLimitOrder "(\"$market\", variant { $side }, $(e8 "$px") : nat, $(e8 "$qty") : nat)" \
    --identity "$ident" 2>&1)
  if echo "$RES" | grep -q '"ok"\|ok ='; then
    ACCEPTED=$((ACCEPTED + 1))
  else
    REJECTED=$((REJECTED + 1))
  fi
done < "$ORDERS_FILE"
rm -f "$ORDERS_FILE"

echo "  $ACCEPTED accepted, $REJECTED rejected of $ROUNDS"
assert_gt "majority of fuzz orders accepted" "$ACCEPTED" "$(( ROUNDS / 2 ))"

# Sealed matching: crossing orders stage off-book and settle on the heartbeat's
# deferred-expiry cadence (no AMM pool in empty mode), so settlements trickle in
# for many seconds after the last placement. The conservation sums below are
# NON-ATOMIC (one query per trader per token) — if a trade settles between
# summing the buyer and summing the seller, one side is double-counted and a
# token "leaks" into (or out of) the snapshot. QUIESCE first: wait until no
# trader has a staged order left, then let the final settlement commit.
quiesced() {
  local t
  for t in "${TRADERS[@]}"; do
    if call getMyStagedOrderIds '()' --identity "$t" | grep -qE "[0-9] : nat"; then return 1; fi
  done
  return 0
}
echo "  ... draining the deferred queue (until no trader has staged orders) ..."
DRAIN=0
until quiesced || [ "$DRAIN" -ge 90 ]; do sleep 3; DRAIN=$((DRAIN+3)); done
quiesced || echo "  (warning: still staged after ${DRAIN}s — sums may race)"
sleep 2

# ── Property 1: per-token supply conserved ──────────────────────
# Trades transfer between traders, no minting or burning. With integer base
# units and pure transfers, the post-fuzz sum must equal the pre-fuzz snapshot
# EXACTLY (no float drift left to tolerate).
i=0
for tk in "${TOKENS[@]}" ICPUSD; do
  AFTER=$(total_of "$tk")
  assert_eq "supply of $tk conserved" "${BEFORE[$i]}" "$AFTER"
  i=$((i + 1))
done

# ── Property 2: no zombie 0-qty orders ──────────────────────────
# quantity is a Nat now — a zeroed level prints as `quantity = 0 :`, not `0.0`.
ZOMBIES=0
for m in "${MARKETS[@]}"; do
  BOOK=$(call getOrderBook "(\"$m\")")
  N=$(echo "$BOOK" | grep -c "quantity = 0 :" || true)
  ZOMBIES=$((ZOMBIES + N))
done
assert_eq "no zombie orders after fuzz" "0" "$ZOMBIES"

# ── Property 3: every open order has positive remaining qty ─────
# Walk every trader's open orders and check `quantity > filled`.
BAD_REMAINING=0
for t in "${TRADERS[@]}"; do
  ORDERS=$(call getMyOrders '()' --identity "$t")
  # `(qty - filled) > 0` for each order. Use python to walk the candid
  # output via a regex over `quantity = X; filled = Y`. quantity/filled are
  # base-unit Nats now (strip Candid underscores first); "positive remaining"
  # means remaining >= 1 base unit, so a non-positive remaining is <= 0.
  N=$(echo "$ORDERS" | python3 -c "
import sys, re
text = sys.stdin.read().replace('_', '')
records = re.findall(r'quantity = ([\d.eE+-]+);[^;]*filled = ([\d.eE+-]+)', text.replace(chr(10), ''))
bad = sum(1 for q, f in records if float(q) - float(f) <= 0)
print(bad)
")
  BAD_REMAINING=$((BAD_REMAINING + N))
done
assert_eq "every open order has positive remaining qty" "0" "$BAD_REMAINING"

# Restore the auto-fuel loop (pinned off at setup for the conservation
# frame). Assertion failures don't exit early (_lib.sh counts them), so
# this runs on the failure path too; only a mid-run kill skips it, and the
# next #play bring-up reinstalls the default anyway.
call setAutoFuel "(true)" --identity alice > /dev/null

finish_test "test_property_fuzz"
