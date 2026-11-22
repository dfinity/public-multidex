#!/bin/bash
# Parallel-trader stress test. Asserts that under concurrent order
# placement, the canister's internal accounting stays consistent —
# specifically, total tokens conserved across the sender + receiver of
# every trade.
#
# Why this works on a single-canister IC application: actor messages
# are processed sequentially per canister, but multiple concurrent
# clients can fill the message queue. Bugs that surface only under
# contention (e.g. read-update-write races inside a single async
# function call that awaits) get exposed by parallel injection.
#
# Strategy:
#   1. Snapshot total token supply across N traders + the AMM principal.
#   2. Fire 8 parallel `placeLimitOrder` calls (4 buys, 4 sells) at
#      crossing prices, so trades actually settle.
#   3. After settlement, recompute total token supply.
#   4. Assert: total per-token supply unchanged. Money created or
#      destroyed by a matching-engine bug would fail this immediately.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_concurrency ──"
setup_mode empty

# Six traders + the AMM principal — wide enough sample to catch
# accounting drift but small enough to stay under a minute.
TRADERS=(alice bob charlie dave eve)
# All five are the venue's STANDING fixtures (scripts/seed.sh ensure_identity
# seeds them; run_tests.sh / deploy.sh mint alice/bob/charlie; 20+ suites sign
# with them) — ensured, never deleted. A name added here that is NOT a seed
# fixture belongs in the mdx_identity_new arm so it leaves with the run.
for t in "${TRADERS[@]}"; do case "$t" in alice|bob|charlie|dave|eve) mdx_identity_ensure "$t" ;; *) mdx_identity_new "$t" ;; esac; done
AMM_PRI=$(call getAmmPrincipal '()' | grep -oE 'principal "[^"]+"' | head -1 | sed 's/principal "//; s/"//')

# Fund traders with both legs so they can cross. (setTestBalance takes a
# base-unit Nat now → e8.)
for t in "${TRADERS[@]}"; do
  P=$(principal_of "$t")
  call setTestBalance "(principal \"$P\", \"BTC\",     $(e8 5.0))"      --identity alice > /dev/null
  call setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 500000.0))"  --identity alice > /dev/null
done

# Helper: sum a token's balance across all traders + the AMM principal.
# getTestBalance returns a base-unit Nat now — strip Candid underscores and
# read the integer. The sum stays in base units; because both the before and
# after snapshots use the same scale, the conservation comparison is exact.
#
# getTestBalance is scoped to self-or-controller and every read here is
# cross-principal, so call as anonymous (the local controller) — the bare
# ambient identity would read silent zeros and gut the conservation check.
#
# For ICPUSD we ALSO fold in the treasury's balance: the symmetric maker/taker
# fee skims quote-leg ICPUSD out of the trading parties into the (distinct)
# treasury principal on every fill. Including the treasury closes the accounting
# set so the quote total is still conserved exactly. (`setup_mode empty` runs
# resetExchange, which zeroes the treasury, so it starts at 0.)
total_supply() {
  local token="$1"
  local sum=0
  for t in "${TRADERS[@]}"; do
    P=$(principal_of "$t")
    BAL=$(call getTestBalance "(principal \"$P\", \"$token\")" --identity anonymous \
          | tr -d '_' | grep -oE "[0-9]+" | head -1)
    sum=$(python3 -c "print($sum + ${BAL:-0})")
  done
  AMM_BAL=$(call getTestBalance "(principal \"$AMM_PRI\", \"$token\")" --identity anonymous \
            | tr -d '_' | grep -oE "[0-9]+" | head -1)
  sum=$(python3 -c "print($sum + ${AMM_BAL:-0})")
  if [ "$token" = "ICPUSD" ]; then
    TREAS=$(call getTreasury '()' | tr -d '_' \
            | grep -oE "balanceUsd = [0-9]+" | grep -oE "[0-9]+")
    sum=$(python3 -c "print($sum + ${TREAS:-0})")
  fi
  echo "$sum"
}

BTC_BEFORE=$(total_supply BTC)
ICPUSD_BEFORE=$(total_supply ICPUSD)
echo "  pre-trade total BTC = $(from_e8 "$BTC_BEFORE")  ICPUSD = $(from_e8 "$ICPUSD_BEFORE")"

# ── Parallel injection ───────────────────────────────────────────
# Fire 8 orders with `&` so they queue up roughly simultaneously at
# the canister. The IC will process them in queue order but our shell
# doesn't wait for one before sending the next. Crossing prices around
# 75000 with a small delta — every order should fill.

for i in 1 2 3 4 5 6 7 8; do
  LOG=$(scratch_new "conc-$i.log") || exit 1
  # 4 buys at increasing prices (75001 .. 75004), 4 sells at
  # decreasing (75004 .. 75001) — mixed, ensures crosses.
  # (price + qty are base-unit Nats now → e8.)
  if [ $((i % 2)) -eq 0 ]; then
    call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 $((75000 + i / 2 + 1))) : nat, $(e8 0.1) : nat)" \
      --identity "${TRADERS[$((i % 5))]}" > "$LOG" 2>&1 &
  else
    call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 $((75001 + i / 2))) : nat, $(e8 0.1) : nat)" \
      --identity "${TRADERS[$((i % 5))]}" > "$LOG" 2>&1 &
  fi
done

# Wait for all 8 backgrounded calls to finish.
wait

# Quick sanity: enumerate how many succeeded.
ACCEPTED=0
for i in 1 2 3 4 5 6 7 8; do
  if mdx_ok "$(cat "$TEST_SCRATCH/conc-$i.log" 2>/dev/null)"; then
    ACCEPTED=$((ACCEPTED + 1))
  fi
done
echo "  accepted $ACCEPTED of 8 concurrent orders"
assert_gt "at least 6 orders accepted" "$ACCEPTED" "5"

# Sealed matching: the crossing orders stage off-book and settle on the next
# GEPTOR release, not inline — wait for at least one trade to post before
# snapshotting balances, so the conservation check runs against settled state
# (this test exists to stress *concurrent fills*, so we want them to have run).
wait_for "call getRecentTrades '(\"BTC-ICPUSD\")' | grep -q 'id = '" 20 1

# ── Conservation check ──────────────────────────────────────────
# Total per-token supply must be exactly equal — every trade is a
# transfer between two principals already in our sum, so the total
# can't change. A double-credit or burn-on-fail bug would show up
# here immediately.

BTC_AFTER=$(total_supply BTC)
ICPUSD_AFTER=$(total_supply ICPUSD)
echo "  post-trade total BTC = $(from_e8 "$BTC_AFTER")  ICPUSD = $(from_e8 "$ICPUSD_AFTER")"

# Integer base units + pure transfers between principals already in the sum
# ⇒ the total is conserved EXACTLY (no float drift to tolerate anymore). A
# double-credit or burn-on-fail bug would make these totals differ by ≥1 unit.
assert_eq "BTC supply conserved across concurrent fills" \
  "$BTC_BEFORE" "$BTC_AFTER"
assert_eq "ICPUSD supply conserved across concurrent fills" \
  "$ICPUSD_BEFORE" "$ICPUSD_AFTER"

finish_test "test_concurrency"
