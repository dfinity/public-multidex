#!/bin/bash
# Round-4 private advisories (W6-07) — both live findings pinned:
#   §1 GHSA-458x: depositLp(0,0) is REFUSED before any event is written —
#      the permanent tape gains no free row (was: #ok(0) + a chained
#      #lpDeposit row shipped to the archive)
#   §2 GHSA-5rcg: archiveExecute's chain walk is hop-bounded — a caller with
#      NO archived history gets an answer without the fan-out being O(chain)
#      (observable here as: the call still answers fast and well-formed on a
#      multi-segment chain; the structural hop cap is asserted statically)
# Needs #dev.
set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
# run_all runs suites with CWD=tests/, so source greps must be REPO-relative.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINMO="$SCRIPT_DIR/../src/backend/main.mo"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
mdx_identity_new g4_u; U=$(principal_of g4_u)
adm setTestBalance "(principal \"$U\", \"ICPUSD\", 100_000_000 : nat)" >/dev/null

echo "── §1 GHSA-458x: (0,0) deposit refused, tape untouched ──"
N0=$(adm getRecentEvents '(200 : nat)' --query | grep -c "lpDeposit" || true)
R=$(icp canister call --candid "$MDX_CANDID" backend depositLp '("ICP-ICPUSD", 0 : nat, 0 : nat)' --identity g4_u 2>&1)
if echo "$R" | grep -q "Nothing to deposit"; then ok "zero-zero deposit refused loudly"; else nok "not refused (the finding)" "$(echo "$R" | tr -d '\n' | head -c 120)"; fi
N1=$(adm getRecentEvents '(200 : nat)' --query | grep -c "lpDeposit" || true)
[ "${N0:-0}" = "${N1:-x}" ] && ok "no #lpDeposit row written (tape count unchanged: $N1)" || nok "a permanent row was written for a no-op" "before=$N0 after=$N1"

# ── W3-10 (R3): (0,0) closed one point; (0,1) was one base unit away and
# behaved identically — transferred a unit, minted dust-or-zero, and STILL
# moved vaultCostBasis (corrupting gainLossPct for every LP). Entry doors
# now carry the order path's MIN_ORDER_ICPUSD floor (spend-all exempt); the
# zero-mint backstop unwinds the legs; exit doors stay uncapped. ──
# Fixture is venue-shape agnostic: first live pool wins; the insurance pool
# is bootstrapped past its own $100 first-stake floor so the DUST floor
# (not the first-stake floor) is what the dust case exercises.
MKT=$(adm getAmmPools '()' --query | grep -o 'marketId = "[^"]*"' | head -1 | cut -d'"' -f2)
if [ -z "$MKT" ]; then
  # Venue-shape agnosticism has a floor: ZERO pools. A predecessor that exits
  # on a seed.sh minimal mode (test_geptor_inflight_guard's `setup_mode
  # staged` — resetExchange, no seedAmmPool) or on a season reset
  # (test_w4_batch3's resetSeason — performWorldWipe clears the pools) leaves
  # exactly that, and the (0,1) probe then reds on "No AMM pool for
  # ICP-ICPUSD" instead of exercising the min-notional door (2026-08-31
  # full-suite red). Self-provision per the 5aab439 hygiene rule: a pool plus
  # a mark (no deposit can be priced against refPrice 0); the vault itself is
  # funded by the genesis branch below, which handles this state and the
  # pools-present-but-vault-empty state alike.
  MKT="ICP-ICPUSD"
  adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
  adm setAmmRefPrice "(\"$MKT\", 1_000_000_000 : nat)" >/dev/null 2>&1
fi
# The vault must hold LP supply BEFORE the (0,1) probe, or performLpDeposit's
# GENESIS floor ("First LP deposit must be worth at least 1000.00") fires
# ahead of the W3-10 min-notional gate and the R3 assertion cannot tell that
# venue state from a regression (task 1788497235: observed red on a seat venue
# whose vault was empty while pools existed). Gate order in performLpDeposit:
# balance -> vaultPricesStale (HELD legs only) -> genesis floor -> min-notional.
# So when lpSupply == 0, seed the vault as ALICE (the minted LP lands inside
# _lib.sh I1's declared holder set, alice..eve, so this fixture strands nothing
# for the next invariant-running suite) with a QUOTE-ONLY deposit: 10,000
# ICPUSD = $10k, ten times the $1000 first-LP floor, and — because the vault
# then holds no priced leg (BTC/ETH/SOL/ICP) — a basket on which the breaker /
# staleness gate can never fire, leaving the min-notional gate as the FIRST
# gate the probe can reach. On an empty vault the concentration cap is skipped
# (totalQuoteValue == 0), so a quote-only genesis is accepted by construction.
LPS=$(adm getVaultValue '()' --query | tr -d '\n_' | grep -oE 'lpSupply = [0-9]+' | grep -oE '[0-9]+')
if [ "${LPS:-0}" = "0" ]; then
  AL=$(icp identity principal --identity alice 2>/dev/null | tail -1)
  # Fund WELL past the deposit: alice can walk in carrying open-order
  # reservations from the predecessor's fixture (seed_staged leaves her a
  # protected BUY reserving 75k ICPUSD), and setTestBalance SETS the balance
  # while reservations persist — a tight balance then reds the seed with
  # "Insufficient available ICPUSD (staged orders reserve balance)".
  adm setTestBalance "(principal \"$AL\", \"ICPUSD\", 100_000_000_000_000 : nat)" >/dev/null 2>&1
  R=$(icp canister call --candid "$MDX_CANDID" backend seedAmmPool "(\"$MKT\", 0 : nat, 1_000_000_000_000 : nat)" --identity alice 2>&1)
  if echo "$R" | grep -q "refPrice not set"; then
    # Pools present, vault empty AND the first pool unmarked (a seed whose
    # setAmmRefPrice failed — e.g. alice not yet a controller): stamp a mark
    # so the deposit can be priced, then retry once.
    adm setAmmRefPrice "(\"$MKT\", 1_000_000_000 : nat)" >/dev/null 2>&1
    R=$(icp canister call --candid "$MDX_CANDID" backend seedAmmPool "(\"$MKT\", 0 : nat, 1_000_000_000_000 : nat)" --identity alice 2>&1)
  fi
  mdx_ok "$R" || nok "vault genesis funding failed (fixture)" "$(echo "$R" | tr -d '\n' | head -c 120)"
fi
adm setTestBalance "(principal \"$U\", \"ICPUSD\", 15_400_000_000 : nat)" >/dev/null
R=$(icp canister call --candid "$MDX_CANDID" backend stakeInsurance '(15_000_000_000 : nat)' --identity g4_u 2>&1)
mdx_ok "$R" || nok "insurance bootstrap stake failed (fixture)" "$(echo "$R" | tr -d '\n' | head -c 120)"
# On a fresh live-oracle venue whose vault HOLDS priced legs (right after
# seed.sh full: the seed marks land >2.5% off the live market and the first
# feed tick pends them) the vaultPricesStale gate (main.mo) can refuse this
# with "LP deposit paused: ... awaiting circuit-breaker confirmation" —
# legitimate venue behavior while a pending price jump awaits its confirming
# oracle tick, NOT the R3 door. Bounded retry while — and ONLY while — the
# refusal carries the stable "LP deposit paused" substring; any other outcome
# ((0,1) accepted, or refused for a different reason) exits the loop on that
# attempt and is asserted strictly below, so a genuine R3 regression still
# reds. The bound covers ONE breaker confirmation tick: the heartbeat
# dispatches a refresh every 30s (HB_PRICE_NS) but a pool is fetched only once
# its mark is >= 45s old (PRICE_STALE_AFTER_NS), so each pool's marks advance
# every ~60s (two beats — measured, task 1788503312), and a pend confirms
# only on a sample >= 30s after its first sighting
# (PRICE_JUMP_MIN_CONFIRM_GAP_NS), so pend -> clear is ~60s on a healthy
# feed — measured 2026-09-04 on a seat venue: pends at <= +30s after seed.sh
# full, cleared at +93..96s, i.e. ~65s — plus one failed-refresh cadence
# (60s) of margin: 30 x (3s + call) ~ 2 min worst case.
# The old 5 x 2s bound could not reach a single confirmation and redded on
# exactly this text (task 1788497235). Only THIS probe needs the retry: (0,0)
# is refused by "Nothing to deposit" BEFORE the pause gate, and stakeInsurance
# has no such gate.
#
# apiVersion 6.0.0 (task 1788731608): depositLp is the STAGED door, so the
# (0,1) request is ACCEPTED (one base unit is available) and the min-notional
# refusal fires AT SETTLEMENT, recorded as the #cancelled outcome
# mdx_lp_deposit returns (rc 1). That retires the 30×3 s retry above: the
# helper's re-stamp postdates the request, so a stale mark cannot flicker
# it; a breaker pend on a held leg only WAITS, and the 120 s poll covers one
# confirmation tick on the live feed.
R=$(mdx_lp_deposit g4_u "$MKT" 0 1 120)
if echo "$R" | grep -q "below the"; then ok "(0,1) dust deposit refused at settlement (min notional, W3-10)"; else nok "(0,1) accepted — the R3 door" "$(echo "$R" | tr -d '\n' | head -c 160)"; fi
N2=$(adm getRecentEvents '(200 : nat)' --query | grep -c "lpDeposit" || true)
[ "${N1:-0}" = "${N2:-x}" ] && ok "no tape row for the dust attempt (count $N2)" || nok "dust deposit wrote a permanent row" "before=$N1 after=$N2"
R=$(icp canister call --candid "$MDX_CANDID" backend stakeInsurance '(1_000 : nat)' --identity g4_u 2>&1)
if echo "$R" | grep -q "below the"; then ok "dust insurance stake refused (min notional, W3-10)"; else nok "dust stake accepted" "$(echo "$R" | tr -d '\n' | head -c 120)"; fi
AVAIL=$(icp canister call --candid "$MDX_CANDID" backend getMyAvailableBalance '("ICPUSD")' --query --identity g4_u 2>&1 | tr -d '_' | grep -oE '[0-9]+' | head -1)
R=$(icp canister call --candid "$MDX_CANDID" backend stakeInsurance "(${AVAIL:-1} : nat)" --identity g4_u 2>&1)
if mdx_ok "$R"; then ok "spend-all stake ($AVAIL) EXEMPT from the floor (mirrors placeOrder)"; else nok "spend-all exemption broken (over-tightened floor)" "$(echo "$R" | tr -d '\n' | head -c 120)"; fi
# The four W3-10 guards, pinned structurally (fundMarginPool's floor shares
# the exact shape; a pool fixture here would cost more than it proves).
for needle in "Deposit value below the" "Stake below the" "Funding below the" "mint 0 LP shares"; do
  if grep -qF "$needle" "$MAINMO"; then ok "guard present: ${needle} [structure pin]"; else nok "guard missing" "$needle"; fi
done

echo "── §2 GHSA-5rcg: sparse-history caller is hop-bounded ──"
# structural pin: the exit is no longer the bare conjunction
if grep -q "ARCHIVE_MAX_HOPS" "$MAINMO" && grep -q "hops >= ARCHIVE_MAX_HOPS" "$MAINMO"; then
  ok "hop budget present at the chain walk [structure pin]"
else nok "hop budget missing" "the conjunction exit is the only one again"; fi
# behavioural: an identity with zero archived history still gets a well-formed answer
# OQL takes `start`, and the quotes are escaped for the Candid text literal —
# the original '{"entity":…}' (unescaped, wrong key) never parsed, and the old
# "rows|ok|vec" oracle passed on the "ok" inside "Unrecognized token" (#51 follow-up).
Q='{\"start\":\"userEvent\",\"limit\":5}'
R=$(icp canister call --candid "$MDX_CANDID" backend archiveExecute "(\"$Q\")" --identity g4_u --query 2>&1)
if echo "$R" | tr -s '[:space:]' ' ' | grep -q "rows = vec"; then ok "no-history caller answered well-formed (no unbounded walk trap)"; else nok "archiveExecute failed for a fresh caller" "$(echo "$R" | tr -d '\n' | head -c 140)"; fi

echo ""
if [ $fail -eq 0 ]; then echo -e "${GREEN}PASS: test_ghsa_round4 ($pass assertions)${NC}"; exit 0
else echo -e "${RED}FAIL: test_ghsa_round4 ($fail of $((pass+fail)) failed)${NC}"; exit 1; fi
