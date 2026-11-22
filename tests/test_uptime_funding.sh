#!/bin/bash
# H-14 (F26) fixture — the uptime sampler credits only the depth the owner's
# AVAILABLE balances could honour at sample time.
#
# Pre-fix, sampleUptime summed (quantity − filled) × price per side straight
# off the order record: a player who rested $500/side within ±1% and then
# moved the backing away (or soft-locked it under a staged order) kept
# PASSING samples — and with them L4's behavioural half (0 bps maker fee +
# the quote shield) — on quotes that could never fill. Now each side's
# credit is capped per market at the owner's available QUOTE (bids) / the
# owner's available BASE valued at the order's price (asks); the ±1% / $500
# rule itself is unchanged.
#
#   §1 funded two-sided book within ±1% → PASS (fixture + positive control)
#   §2 backing moves away → FAIL, with the boundaries: quote 499 → FAIL,
#      500 → PASS (≥); base 49 → FAIL (49 × 10.08 = $493.92), 50 → PASS
#      ($504); zero balances → FAIL
#   §3 cannot reach L4: W = $100k (L3) + 20 unfunded samples → still L3, not
#      qualified; the SAME quotes funded → 20 passes → L4
#   §4 loses L4 once backing moves away: 21 fail samples take 20/20 to 20/41
#      (48%) → L3
#   §5 the user-reachable path: a STAGED order's soft-lock (reserved, not
#      debited) shrinks the available balance below the resting quotes → FAIL
#      on the bid side, then on the ask side; releasing the staged orders
#      restores the credit → PASS
#
# Samples land on demand through devTickTier (#dev, controller) with timers
# paused; setTestScorecard(…, 0, 0) resets the uptime counters between
# sections so every verdict reads as samples = 1, pct ∈ {0, 100}.
#
# Venue physics (test_po_sweep_fee.sh's five traps apply): the pool is built
# at ref 10.0 with a 20 bps AMM ladder (ask ≈ 10.02 / bid ≈ 9.98); the bid
# rests at 9.92 and the ask at 10.08 — 80 bps off ref, inside the ±100 bps
# uptime window, outside the ladder, so neither crosses at release. GEPTOR
# staging releases only once a FRESH ref price postdates the entry, so the
# fixture re-stamps setAmmRefPrice (same price) before the releasing requote;
# §5's staged orders deliberately get NO re-stamp so they stay staged.
# Needs #dev. ⚠️ resetExchange for a deterministic book (reset again at exit).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { echo y | icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
mdx_identity_new uf_p; P=$(principal_of uf_p)
usr() { echo y | icp canister call --candid "$MDX_CANDID" --identity uf_p backend "$@" 2>&1; }

if [ "$(venue_posture)" != "dev" ]; then skip_posture "test_uptime_funding" "devTickTier / setTestScorecard (#dev hooks)"; fi

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
mdx_identity_new uf_seed; SEED=$(principal_of uf_seed)
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 300.0) : nat, 5:nat, 10:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 20000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
mdx_lp_deposit uf_seed "ICP-ICPUSD" "$(e8 20000.0)" "$(e8 200000.0)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null

# ── helpers ──
fund()   { adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 "$1") : nat)" >/dev/null; adm setTestBalance "(principal \"$P\", \"ICP\", $(e8 "$2") : nat)" >/dev/null; }
# reset the uptime counters (and pin W): samples=0 deletes the uptimeStats entry
score()  { adm setTestScorecard "(principal \"$P\", $(e8 "$1") : nat, 0 : nat, 0 : nat, 0 : nat)" >/dev/null; }
tick()   { local n=${1:-1}; local i; for ((i=0; i<n; i++)); do adm devTickTier '()' >/dev/null || return 1; done; }
pol()    { usr getAccessPolicy '()' --query | tr -d '_\n' | tr -s ' '; }
samples(){ echo "$1" | grep -oE 'myUptimeSamples = [0-9]+' | grep -oE '[0-9]+$'; }
pct()    { echo "$1" | grep -oE 'myUptimePct = (opt \(|null)[0-9]*' | grep -oE '[0-9]+$|null'; }
level()  { echo "$1" | grep -oE 'myLevel = [0-9]+' | grep -oE '[0-9]+$'; }
qual()   { echo "$1" | grep -oE 'myUptimeQualified = (true|false)' | grep -oE 'true|false'; }
# one clean sample: reset counters, tick once, expect pct 0 (FAIL) or 100 (PASS)
sample_is() {   # $1 = expected 0|100, $2 = label
  score 0; tick 1
  local pl; pl=$(pol); local s; s=$(samples "$pl"); local c; c=$(pct "$pl")
  if [ "${s:-x}" = "1" ] && [ "${c:-x}" = "$1" ]; then ok "$2 (samples=1 pct=$c)"
  else nok "$2" "expected 1 sample at pct=$1, got samples=${s:-?} pct=${c:-?}"; fi
}

echo "── §1 funded two-sided book within ±1% → PASS (fixture) ──"
fund 700 70
R1=$(usr placeLimitOrder "(\"ICP-ICPUSD\", variant { buy },  $(e8 9.92)  : nat, $(e8 60.0) : nat)")
R2=$(usr placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.08) : nat, $(e8 60.0) : nat)")
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null   # re-stamp: fresh price postdates both entries
adm requoteAmm '("ICP-ICPUSD")' >/dev/null                           # → releases; nothing crosses → both rest
MO=$(usr getMyOrders '()' --query | tr -d '_\n' | grep -o 'id = [0-9]' | wc -l | tr -d ' ')
STG=$(usr getMyStagedOrderIds '()' --query | tr -d ' \n_')
if [ "${MO:-0}" = "2" ] && [ "$STG" = "(vec{})" ]; then ok "bid 60 @ 9.92 (\$595.20) and ask 60 @ 10.08 (\$604.80) REST, 80 bps off ref"
else nok "two-sided book did not rest (fixture)" "open=$MO staged=$STG place=$(echo "$R1 $R2" | tr -d '\n' | head -c 200)"; fi
sample_is 100 "funded \$595/\$605 two-sided book passes the sample"

echo "── §2 backing moves away → FAIL; the boundaries ──"
fund 100 5
sample_is 0   "quote 100 / base 5 behind the same resting quotes → FAIL (pre-fix: PASS forever)"
fund 499 70
sample_is 0   "quote 499 < \$500 caps the bid credit → FAIL"
fund 500 70
sample_is 100 "quote 500 credits exactly the \$500 bar (≥) → PASS"
fund 700 49
sample_is 0   "base 49 × 10.08 = \$493.92 caps the ask credit → FAIL"
fund 700 50
sample_is 100 "base 50 × 10.08 = \$504 → PASS"
fund 0 0
sample_is 0   "zero balances → FAIL"

echo "── §3 cannot reach L4 on unfunded quotes; the same quotes funded do ──"
score 50000                                                           # W = 2 × $50k = $100k → L3 without uptime
fund 100 5
tick 19
P3=$(pol)
if [ "$(samples "$P3")" = "19" ] && [ "$(pct "$P3")" = "0" ] && [ "$(level "$P3")" = "3" ]; then ok "19 unfunded samples: 0% uptime, L3"
else nok "unfunded samples counted as passes" "samples=$(samples "$P3") pct=$(pct "$P3") level=$(level "$P3")"; fi
tick 1                                                                # 20th fail sample: a 0-pass entry past the dwell is pruned
P3=$(pol)
if [ "$(level "$P3")" = "3" ] && [ "$(qual "$P3")" = "false" ]; then ok "20 unfunded samples: still L3, not uptime-qualified (pre-fix: L4)"
else nok "unfunded quotes reached L4" "level=$(level "$P3") qualified=$(qual "$P3") samples=$(samples "$P3")"; fi
fund 700 70
tick 20
P3=$(pol)
if [ "$(level "$P3")" = "4" ] && [ "$(qual "$P3")" = "true" ] && [ "$(pct "$P3")" = "100" ]; then ok "the SAME quotes, funded: 20/20 → uptime-qualified → L4 (positive control)"
else nok "funded quotes did not qualify" "level=$(level "$P3") qualified=$(qual "$P3") samples=$(samples "$P3") pct=$(pct "$P3")"; fi

echo "── §4 loses L4 once the backing moves away ──"
fund 100 5
tick 21                                                               # 20/41 = 48% < 50%
P4=$(pol)
if [ "$(level "$P4")" = "3" ] && [ "$(qual "$P4")" = "false" ] && [ "$(samples "$P4")" = "41" ] && [ "$(pct "$P4")" = "48" ]; then ok "21 unfunded samples: 20/41 = 48% → L4 lost, back to L3 (pre-fix: L4 forever)"
else nok "L4 survived unfunded quotes" "level=$(level "$P4") qualified=$(qual "$P4") samples=$(samples "$P4") pct=$(pct "$P4")"; fi

echo "── §5 the user-reachable path: a staged order's soft-lock ──"
fund 700 70
sample_is 100 "re-funded: PASS again (control)"
usr placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.90) : nat, $(e8 60.0) : nat)" >/dev/null   # stages: reserves $594 of the 700, NO re-stamp → stays staged
STG=$(usr getMyStagedOrderIds '()' --query | tr -d ' \n_')
[ "$STG" != "(vec{})" ] && ok "a new bid 60 @ 9.90 (\$594) is STAGED — its reservation soft-locks the quote balance" || nok "staged bid did not stage (fixture)" "staged=$STG"
sample_is 0   "available quote 700 − 594 = \$106 behind the resting \$595 bid → FAIL"
fund 10000 70                                                         # bid side comfortably funded again (available 10000 − 594)
usr placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.10) : nat, $(e8 60.0) : nat)" >/dev/null  # stages: reserves 60 of the 70 ICP
sample_is 0   "available base 70 − 60 = 10 ICP (\$100.80) behind the resting 60-ICP ask → FAIL"
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null   # re-stamp + requote: both staged orders release and rest
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
STG=$(usr getMyStagedOrderIds '()' --query | tr -d ' \n_')
[ "$STG" = "(vec{})" ] && ok "both staged orders released (reservations gone)" || nok "staged orders did not release (fixture)" "staged=$STG"
sample_is 100 "released: bids \$1189 vs available \$10000, asks 70 ICP of 120 quoted (\$705.80) → PASS"

adm setTestTimersPaused '(false)' >/dev/null 2>&1
# Fixture hygiene (the 5aab439 rule): this suite seeded the vault as the
# ad-hoc identity uf_seed, whom _lib.sh's I1 frame can never account for —
# reset at exit so the next invariant-running suites do not inherit it.
adm resetExchange "()" >/dev/null 2>&1 || true
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_uptime_funding ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_uptime_funding ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
