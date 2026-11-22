#!/bin/bash
# Verifies a deep market order walks the whole AMM ask ladder at release
# instead of stopping on the first level.
#
# History: this suite was written for the locked-maker walk-through — a
# market buy for 10 ETH would lock the best AMM ask into one pending match,
# re-find the same maker, see availableForFill == 0 and break at ~1.5 ETH;
# the fix marked the exhausted maker visited and advanced. The PendingMatch
# machinery is RETIRED (task 1788516198, after 1788515326 recorded it dormant
# under the sealed model), so the Σ pendingMatches term is gone and the
# assertion is carried by the settled fill alone: the walk under test is the
# release-time ladder walk (the taker soaks successive AMM ask levels at the
# fresh requote).

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
# W5-01: this file used to be unable to fail — fail() echoed and nothing
# else, no counter, no exit code — so a broken locked-maker walk-through
# printed ✗ and recorded PASS. The standard 36-test idiom:
pass=0; fail=0
pass() { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
fail() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

ID=walk_locked
mdx_identity_new $ID
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }

# Self-contained venue: an ETH market whose AMM ladder is the row of
# makers the walk must traverse (every AMM quote still RECORDS a protection
# window, but under sealing no fill consults it — see the header — so the
# levels fill outright at release). W5-01 repair note: this file
# still passed FLOAT args from before the integer-money migration — the
# dead verdict hid full bitrot, not just a broken assertion.
mdx_identity_new walk_seed; SEEDW=$(principal_of walk_seed)
adm setTestTimersPaused '(true)' >/dev/null 2>&1
# TIMER HYGIENE: this test pauses the venue's timers; a failure path that
# exits before the resume strands the finaliser OFF for every later suite
# (found live: matching_engine's staged releases never fired). Resume on ANY
# exit — registered through _scratch.sh's on_exit (a bare `trap … EXIT` would
# replace the scratch-dir cleanup now that this suite sources _lib.sh).
on_exit 'adm setTestTimersPaused "(false)" >/dev/null 2>&1'

# VENUE-CALM (2026-08-15): depositLp/seedAmmPool is vault-GLOBAL — it pauses
# if ANY held asset has an unconfirmed price jump (M1: don't mint against a
# stale basket). A predecessor suite that moved a price (e.g. margin_staleness
# on ICP) strands that pause for everyone. Clear the pend directly for every
# market's base token (setTestPendingJump(_, null, _) deletes it) so our seed
# isn't blocked by another market's leftover breaker.
# VENUE-FRESH (2026-09-04, task 1788485999): the same vault-global gate also
# refuses while ANY held leg's mark is older than the quoting staleness grace
# (LP_DEPOSIT_MAX_REF_AGE_NS) — "LP deposit paused: ICP refPrice is stale".
# That is the ordinary state of a venue whose feed is not running: timers
# paused by a predecessor, a wiped venue re-priced by a test minutes ago, or
# the DEX stopped/started by test_bridge_deposit_claim §12 — and this fixture
# pauses the timers itself, so nothing refreshes the marks underneath it. The
# old fixture tolerated the refusal ("relying on existing inventory") and gated
# only on "≥ 1 ask": the AMM then quoted its ~3 ETH remnant at the inventory
# floor barrier (+29%), outside the 25% collar, and the walk soaked 0 ETH —
# read as a matcher regression. Re-stamp every pool's mark with its CURRENT
# value (fresh, no price move, so no vol-regime spike) so the seed lands, and
# gate on LIFTABLE depth below (the walk's real precondition).
for MKT in $(adm getAmmPools '()' --query | tr -d '_\n' | grep -oE 'marketId = "[A-Z]+-ICPUSD"' | grep -oE '"[A-Z]+-ICPUSD"' | tr -d '"' | sort -u); do
  adm setTestPendingJump "(\"${MKT%-ICPUSD}\", null, null)" >/dev/null 2>&1
  REF=$(adm getAmmPool "(\"$MKT\")" --query | tr -d '_\n' | grep -oE 'refPrice = [0-9]+' | awk '{print $3}')
  [ "${REF:-0}" -gt 0 ] && adm setAmmRefPrice "(\"$MKT\", $REF : nat)" >/dev/null 2>&1
done
adm setTestPendingJump '("ICP", null, null)' >/dev/null 2>&1   # ICP is held even if its pool is gone
# LIVE-MARK PIN (2026-09-04, task 1788485999; via mdx_pin_mark since task
# 1788541235): a #dev seat venue runs the REAL multi-source feed (cold_start:
# "oracle feed is live") — the periodic tick every 30s and, decisively, the
# GEPTOR fetch that staging an order ARMS. So the venue's ETH mark converges
# on the live price whatever a fixture stamps, and a synthetic $2000 mark 25%
# off a live ~$2500 turns the next fetch into a >2.5% jump: the circuit
# breaker PENDS it (ref frozen, refPriceUpdatedNs NOT advanced — the
# price-postdates-entry release gate stays shut) and widens the ask ladder by
# the full proposed gap, so every ask sits outside the taker's 25% collar;
# the staged buy walks 5 requotes against nothing and is dropped: "0 ETH —
# locked-maker walk-through broken", with the matcher innocent. Pin the
# fixture's price to the feed's last aggregate when it has one (a fetch then
# agrees with the mark: no jump, no pend, no widening). A predecessor's wipe
# CLEARS lastAggregates (resetExchange), which used to leave this fixture on
# the synthetic $2000 — a pend magnet for any fetch that lands — so
# mdx_pin_mark now PRIMES the aggregate with one admin fetch first and falls
# back to $2000 only on a feed-less venue, where no fetch can move the mark
# either. The pool must exist before the pin (createAmmPool is idempotent).
adm createAmmPool '("ETH-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ETH-ICPUSD\", 20:nat, $(e8 3.0) : nat, 5:nat, 10:nat)" >/dev/null
read -r PX_E8 PX_SRC <<EOF_PIN
$(mdx_pin_mark ETH ETH-ICPUSD "$(e8 2000)")
EOF_PIN
PX=$(awk -v p="${PX_E8:-0}" 'BEGIN { if (p + 0 > 0) printf "%.2f", p / 100000000; else print "2000.00" }')
case "${PX_SRC:-fallback}" in
  aggregate) PX_WHY="the feed's last aggregate" ;;
  primed)    PX_WHY="the feed's aggregate, primed by one admin fetch after a predecessor's wipe" ;;
  pool)      PX_WHY="the pool's standing mark (no feed)" ;;
  *)         PX_WHY="no live aggregate, synthetic" ;;
esac
echo "  (ETH mark pinned at \$$PX — $PX_WHY)"
# Sized in DOLLARS so the vault weights hold at any price: ~$200k of ETH
# (capped at 100 ETH) against 600k ICPUSD, and a taker budget that covers the
# 10 ETH buy at the collar with room to spare.
SEEDQ=$(awk -v p="$PX" 'BEGIN { q = 200000 / p; if (q > 100) q = 100; printf "%.4f", q }')
TAKER_USD=$(awk -v p="$PX" 'BEGIN { b = 10 * p * 1.3; if (b < 100000) b = 100000; printf "%.0f", b }')
adm setTestBalance "(principal \"$SEEDW\", \"ETH\", $(e8 100.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEEDW\", \"ICPUSD\", $(e8 650000.0) : nat)" >/dev/null
# RERUN HYGIENE: reclaim any LP a prior run's seed left behind, so the
# vault this run measures starts near ambient (a second same-shape seed on
# top of the first one skews the weights and trips the concentration cap).
LPBAL=$(icp canister call --candid "$MDX_CANDID" --identity walk_seed backend getMyVaultLp '()' --query 2>/dev/null | tr -d '_' | grep -oE "[0-9]+" | head -1)
[ "${LPBAL:-0}" -gt 0 ] && mdx_lp_withdraw walk_seed "$LPBAL" >/dev/null 2>&1

# Quote-heavy seed: a 50/50 basket ($200k ETH / $200k ICPUSD) breaches the
# vault's per-token concentration cap whenever the ambient vault is small
# (the pre-repair green rode the $1M play vault). 100 ETH against 600k
# ICPUSD keeps the ETH leg ≈25% of the post-deposit vault on ANY ambient
# state — self-contained for real this time.
# A refusal is fatal ONLY if it leaves no ladder: on a rerun the prior
# seed's inventory is still in the vault (locked under its own resting
# quotes, so the LP reclaim above may no-op) and the requote below rebuilds
# the ladder from it. The real gate is "are there asks", asserted after the
# requote. (Staged door since apiVersion 6.0.0: the helper settles before
# returning; rc ≠ 0 is the refusal, its text the reason.)
SEED_R=$(mdx_lp_deposit walk_seed "ETH-ICPUSD" "$(e8 "$SEEDQ")" "$(e8 600000.0)" 2>&1) \
  || echo "  (seed refused — relying on existing inventory: $(echo "$SEED_R" | tr -d '\n' | head -c 100))"
adm enableAmm '("ETH-ICPUSD", true)' >/dev/null
adm requoteAmm '("ETH-ICPUSD")' >/dev/null
# The honest precondition is LIFTABLE depth: ≥ 10 ETH of asks at or under the
# buy's collar (ref × 1.25), not "some ask exists" — an ask the collar cannot
# reach is nothing to walk. On a rerun the seed may be refused for the
# concentration cap while the prior inventory still quotes fine, so the gate
# reads the book, not the seed's reply; a short ladder fails LOUDLY with both.
BOOK=$(adm getOrderBook '("ETH-ICPUSD")' --query | tr -d '_\n' | tr -s ' ')
ASKS=$(echo "$BOOK" | awk '{ i = index($0, "asks = vec {"); if (!i) { print ""; exit }; s = substr($0, i); j = index(s, "bids = vec {"); if (j) s = substr(s, 1, j - 1); print s }')
ASKQ=$(echo "$ASKS" | grep -oE 'quantity = [0-9]+ : nat; price = [0-9]+' | awk -v cap="$(e8 "$(awk -v p="$PX" 'BEGIN { printf "%.4f", p * 1.25 }')")" '{ if ($8 + 0 <= cap + 0) s += $3 } END { printf "%.0f", s + 0 }')
[ "${ASKQ:-0}" -ge "$(e8 10.0)" ] || { fail "only $(awk -v q="${ASKQ:-0}" 'BEGIN{print q/100000000}') ETH of asks inside the 25% collar after seed+requote — nothing to walk (seed reply: $(echo "$SEED_R" | tr -d '\n' | head -c 160))" "$(echo "$ASKS" | head -c 300)"; exit $fail; }

# Plenty of ICPUSD so taker budget isn't the constraint. ETH zeroed so the
# balance IS this run's fill (a prior run's staged order may release with ours).
adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 "$TAKER_USD") : nat)" >/dev/null
adm setTestBalance "(principal \"$P\", \"ETH\", 0 : nat)" >/dev/null

# A deep market buy: 10 ETH across a 5-level x 3-ETH protected ladder.
# 25% slippage (the maximum the range check allows) so the walk, not the
# collar, is what stops it.
RES=$(icp canister call --candid "$MDX_CANDID" --identity $ID backend placeMarketOrder \
  "(\"ETH-ICPUSD\", variant { buy }, $(e8 10.0) : nat, 25_000_000 : nat, false)" 2>&1)
# Sealed model: the order STAGES; the walk happens at RELEASE (fresh fetch +
# requote). Release it, then measure what actually settled.
adm setAmmRefPrice "(\"ETH-ICPUSD\", $(e8 "$PX") : nat)" >/dev/null
adm requoteAmm '("ETH-ICPUSD")' >/dev/null
sleep 1

# Settled = the taker's ETH balance (started at zero). (The Σ pendingMatches
# term that used to be added here is retired with the machinery — header.)
FILLED=$(adm getTestBalance "(principal \"$P\", \"ETH\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+" | awk '{print $1/100000000}')

echo "Response (head):"
echo "$RES" | head -c 600
echo ""
echo "--- summary ---"
echo "totalFilled (settled):   $FILLED"
TOTAL=$(awk -v a="$FILLED" 'BEGIN { print a + 0 }')

# Expect ≥ 9 ETH soaked up (allow a bit of slop for slippage cutoff).
OK=$(awk -v t="$TOTAL" 'BEGIN { print (t >= 9.0) ? 1 : 0 }')
if [ "$OK" = "1" ]; then
  pass "market buy soaked >= 9 ETH across the AMM ask ladder at release. Was: $TOTAL"
else
  fail "Engine stopped after only $TOTAL ETH — the release-time ladder walk broke" "$RES"
fi

exit $fail
