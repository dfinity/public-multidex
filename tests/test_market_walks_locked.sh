#!/bin/bash
# Verifies a market order walks past AMM-protected makers as their slices
# get locked by pending matches, instead of stopping on the first level.
#
# Before this fix: market buy for 10 ETH would lock the best AMM ask (say
# 1.5 ETH) into one pending match, then the matcher would re-find the same
# maker, see availableForFill == 0, and break — returning ~1.5 ETH instead
# of 10. After: matcher marks the exhausted maker as visited, advances to
# the next-best AMM ask, repeats until either the request is satisfied or
# slippage / book runs out.

set -u
export PATH="$HOME/.local/bin:$PATH"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
# W5-01: this file used to be unable to fail — fail() echoed and nothing
# else, no counter, no exit code — so a broken locked-maker walk-through
# printed ✗ and recorded PASS. The standard 36-test idiom:
pass=0; fail=0
pass() { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
fail() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

ID=walk_locked
icp identity new $ID --storage plaintext 2>/dev/null || true
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }

# Self-contained venue: an ETH market whose AMM ladder is the row of
# protected makers the walk must traverse (every AMM quote carries a
# protection window, so fills lock slices into pending matches — exactly
# the visited-maker machinery under test). W5-01 repair note: this file
# still passed FLOAT args from before the integer-money migration — the
# dead verdict hid full bitrot, not just a broken assertion.
SEEDW=$(icp identity new walk_seed --storage plaintext >/dev/null 2>&1; icp identity principal --identity walk_seed 2>/dev/null | tail -1)
adm setTestTimersPaused '(true)' >/dev/null 2>&1
# TIMER HYGIENE: this test pauses the venue's timers; a failure path that
# exits before the resume strands the finaliser OFF for every later suite
# (found live: matching_engine's staged releases never fired). Resume on ANY
# exit.
trap 'adm setTestTimersPaused "(false)" >/dev/null 2>&1' EXIT

# VENUE-CALM (2026-08-15): depositLp/seedAmmPool is vault-GLOBAL — it pauses
# if ANY held asset has an unconfirmed price jump (M1: don't mint against a
# stale basket). A predecessor suite that moved a price (e.g. margin_staleness
# on ICP) strands that pause for everyone. Clear the pend directly for every
# market's base token (setTestPendingJump(_, null, _) deletes it) so our seed
# isn't blocked by another market's leftover breaker.
for BASE in $(adm getAmmPools '()' --query | tr -d '_\n' | grep -oE 'marketId = "[A-Z]+-ICPUSD"' | grep -oE '"[A-Z]+-ICPUSD"' | tr -d '"' | sed 's/-ICPUSD//' | sort -u); do
  adm setTestPendingJump "(\"$BASE\", null, null)" >/dev/null 2>&1
done
adm setTestPendingJump '("ICP", null, null)' >/dev/null 2>&1   # ICP is held even if its pool is gone
adm createAmmPool '("ETH-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ETH-ICPUSD\", 20:nat, $(e8 3.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ETH-ICPUSD\", $(e8 2000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEEDW\", \"ETH\", $(e8 100.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEEDW\", \"ICPUSD\", $(e8 650000.0) : nat)" >/dev/null
# RERUN HYGIENE: reclaim any LP a prior run's seed left behind, so the
# vault this run measures starts near ambient (a second same-shape seed on
# top of the first one skews the weights and trips the concentration cap).
LPBAL=$(icp canister call --identity walk_seed backend getMyVaultLp '()' --query 2>/dev/null | tr -d '_' | grep -oE "[0-9]+" | head -1)
[ "${LPBAL:-0}" -gt 0 ] && icp canister call --identity walk_seed backend withdrawLp "(${LPBAL} : nat)" >/dev/null 2>&1

# Quote-heavy seed: a 50/50 basket ($200k ETH / $200k ICPUSD) breaches the
# vault's per-token concentration cap whenever the ambient vault is small
# (the pre-repair green rode the $1M play vault). 100 ETH against 600k
# ICPUSD keeps the ETH leg ≈25% of the post-deposit vault on ANY ambient
# state — self-contained for real this time.
SEED_R=$(icp canister call --identity walk_seed backend seedAmmPool "(\"ETH-ICPUSD\", $(e8 100.0) : nat, $(e8 600000.0) : nat)" 2>&1)
# A refusal is fatal ONLY if it leaves no ladder: on a rerun the prior
# seed's inventory is still in the vault (locked under its own resting
# quotes, so the LP reclaim above may no-op) and the requote below rebuilds
# the ladder from it. The real gate is "are there asks", asserted after the
# requote.
echo "$SEED_R" | grep -q "ok" || echo "  (seed refused — relying on existing inventory: $(echo "$SEED_R" | tr -d '\n' | head -c 100))"
adm enableAmm '("ETH-ICPUSD", true)' >/dev/null
adm requoteAmm '("ETH-ICPUSD")' >/dev/null
ASKN=$(adm getOrderBook '("ETH-ICPUSD")' --query | tr -d '\n' | grep -oE 'asks = vec \{[^}]*' | grep -c "price" || true)
[ "${ASKN:-0}" -ge 1 ] || { fail "no asks on the ETH ladder after seed+requote — nothing to walk" "$(adm getOrderBook '("ETH-ICPUSD")' --query | head -c 200)"; exit $fail; }

# Plenty of ICPUSD so taker budget isn't the constraint. ETH zeroed so the
# balance IS this run's fill (a prior run's staged order may release with ours).
adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$P\", \"ETH\", 0 : nat)" >/dev/null

# A deep market buy: 10 ETH across a 5-level x 3-ETH protected ladder.
# 25% slippage (the maximum the range check allows) so the walk, not the
# collar, is what stops it.
RES=$(icp canister call --identity $ID backend placeMarketOrder \
  "(\"ETH-ICPUSD\", variant { buy }, $(e8 10.0) : nat, 25_000_000 : nat, false)" 2>&1)
# Sealed model: the order STAGES; the walk happens at RELEASE (fresh fetch +
# requote). Release it, then measure what actually settled.
adm setAmmRefPrice "(\"ETH-ICPUSD\", $(e8 2000.0) : nat)" >/dev/null
adm requoteAmm '("ETH-ICPUSD")' >/dev/null
sleep 1

# Sum totalFilled (immediate fills) + Σ pendingMatches.quantity.
# Settled = the taker's ETH balance (started at zero); pending = locked
# slices awaiting their protection windows.
FILLED=$(adm getTestBalance "(principal \"$P\", \"ETH\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+" | awk '{print $1/100000000}')
PENDING=$(icp canister call --identity $ID backend getMyPendingMatches '()' --query 2>&1)
PENDING_SUM=$(echo "$PENDING" | tr -d '_' | awk '
  /pendingMatches = vec \{/ { inpm = 1; next }
  inpm && /quantity = [0-9]+/ { gsub(/[^0-9]/, "", $0); print $0/100000000; }
' | awk '{s+=$1} END {print s+0}')
[ -z "$PENDING_SUM" ] && PENDING_SUM=0

echo "Response (head):"
echo "$RES" | head -c 600
echo ""
echo "--- summary ---"
echo "totalFilled (immediate): $FILLED"
echo "Σ pendingMatches.qty:    $PENDING_SUM"
TOTAL=$(awk -v a="$FILLED" -v b="$PENDING_SUM" 'BEGIN { print a + b }')
echo "Σ all settled+pending:   $TOTAL"

# Expect ≥ 9 ETH soaked up (allow a bit of slop for slippage cutoff).
OK=$(awk -v t="$TOTAL" 'BEGIN { print (t >= 9.0) ? 1 : 0 }')
if [ "$OK" = "1" ]; then
  pass "market buy soaked >= 9 ETH (across immediate + pending). Was: $TOTAL"
else
  fail "Engine stopped after only $TOTAL ETH — locked-maker walk-through broken" "$RES"
fi

exit $fail
