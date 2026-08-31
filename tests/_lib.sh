#!/bin/bash
# tests/_lib.sh — shared helpers for regression + invariant tests.
#
# Each test sources this file. It provides:
#
#   ── Assertions ──
#     assert_eq         pass if two strings match
#     assert_contains   pass if haystack contains substring
#     assert_not_contains
#     assert_float_close  numeric equality with tolerance
#     assert_lt / assert_gt
#
#   ── Candid extractors ──
#     extract_float     pull a `name = N.NNN : float64` value out of output
#     extract_nat       pull a `name = N : nat` out of output
#     extract_first_nat extract the first `<digits> : nat` token
#
#   ── Identity / principal helpers ──
#     principal_of      get principal-text for a given identity
#
#   ── Fixtures + global-state checks ──
#     setup_mode        wipe state and apply a seed.sh mode
#     assert_invariants verify global state coherence after a test
#                       (called automatically by finish_test)
#
#   ── Timer-driven assertions ──
#     wait_for          poll a predicate until true or timeout
#
# `finish_test` must be called at the very end of each test; it prints
# the pass/fail banner, runs the global-invariants check, and exits
# with the right code.

set -o pipefail
export PATH="$HOME/.local/bin:$PATH"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_TEST_ERRORS=0

_fail() {
  echo -e "${RED}  ✗ $1${NC}" >&2
  _TEST_ERRORS=$(( _TEST_ERRORS + 1 ))
}
_ok() {
  echo -e "${GREEN}  ✓ $1${NC}"
}

# ── Basic assertions ──────────────────────────────────────────────

assert_eq() {
  if [ "$2" = "$3" ]; then _ok "$1 == $2"
  else _fail "$1: expected [$2], got [$3]"; fi
}

assert_contains() {
  # Strip underscores from haystack — Candid sometimes formats nats as
  # "75_000" and sometimes "75000". Tests write needles as plain digits.
  local stripped
  stripped=$(echo "$2" | tr -d '_')
  if echo "$stripped" | grep -q -- "$3"; then _ok "$1 contains '$3'"
  else _fail "$1 did NOT contain '$3'; got:\n$2"; fi
}

assert_not_contains() {
  # Same underscore-strip as assert_contains (#51.9): Candid prints nats both
  # as "75_000" and "75000", and a digit needle written plain could NEVER
  # match an underscored haystack — so the ban it expressed was vacuous
  # (test_play_deposit_cap's "pending = $B" pins were exactly that shape).
  # Call-site audit at the change (2026-08-20): no needle contains an
  # underscore, and no text needle can be manufactured by deleting
  # underscores from these haystacks — the strip only arms the digit pins.
  local stripped
  stripped=$(echo "$2" | tr -d '_')
  if echo "$stripped" | grep -q -- "$3"; then _fail "$1: unexpected '$3' in:\n$2"
  else _ok "$1 lacks '$3'"; fi
}

# Absolute-tolerance comparison — for BASE-UNIT (integer) money, where a
# RELATIVE tolerance scales the allowed error with the balance sheet itself
# (#51.5: 1% of a seeded vault's lpSupply was ~300 whole tokens of invisible
# drift). `tol` is in the same units as the operands.
assert_abs_close() {
  local name="$1" expected="$2" actual="$3" tol="$4"
  if [ -z "$actual" ]; then
    _fail "$name: actual is empty"
    return
  fi
  local verdict
  verdict=$(python3 -c "
e=$expected; a=$actual; t=$tol
print('PASS' if abs(e - a) <= t else f'FAIL diff={abs(e-a)}')
")
  if [ "$verdict" = "PASS" ]; then
    _ok "$name ≈ $expected (got $actual, abs tol $tol)"
  else
    _fail "$name: expected ≈$expected (abs tol $tol), got $actual ($verdict)"
  fi
}

# Tolerance comparison — for any quantity that can drift due to live
# AMM activity, simulator noise, or floating-point. Default tol=0.0001.
assert_float_close() {
  local name="$1" expected="$2" actual="$3" tol="${4:-0.0001}"
  if [ -z "$actual" ] || [ "$actual" = "" ]; then
    _fail "$name: actual is empty"
    return
  fi
  local diff
  diff=$(python3 -c "
e=$expected; a=$actual; t=$tol
print('PASS' if abs(e - a) <= t * max(1.0, abs(e)) else f'FAIL diff={abs(e-a)}')
")
  if [ "$diff" = "PASS" ]; then
    _ok "$name ≈ $expected (got $actual)"
  else
    _fail "$name: expected ≈$expected (tol $tol), got $actual ($diff)"
  fi
}

assert_lt() {
  local name="$1" actual="$2" upper="$3"
  if python3 -c "import sys; sys.exit(0 if $actual < $upper else 1)"; then
    _ok "$name: $actual < $upper"
  else
    _fail "$name: expected < $upper, got $actual"
  fi
}

assert_gt() {
  local name="$1" actual="$2" lower="$3"
  if python3 -c "import sys; sys.exit(0 if $actual > $lower else 1)"; then
    _ok "$name: $actual > $lower"
  else
    _fail "$name: expected > $lower, got $actual"
  fi
}

# ── Candid extractors ─────────────────────────────────────────────
# These exist because Candid's textual format is regular but not nice
# to grep — fields are `name = value : type` with optional underscores
# in numbers and arbitrary whitespace. Centralizing the parsing here
# means a Candid format change touches one file, not 30 test scripts.

# extract_float "lpSupply" "$response"  → "1500000.5"
extract_float() {
  local field="$1" body="$2"
  echo "$body" \
    | tr -d '_' \
    | awk -v f="$field" '
        $0 ~ f " *=" {
          for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9.eE+-]+$/) { print $i; exit }
          }
        }'
}

# extract_nat "id" "$response"  → "242345"
extract_nat() {
  local field="$1" body="$2"
  echo "$body" \
    | tr -d '_' \
    | awk -v f="$field" '
        $0 ~ f " *=" {
          for (i=1; i<=NF; i++) {
            if ($i ~ /^[0-9]+$/) { print $i; exit }
          }
        }'
}

extract_first_nat() {
  echo "$1" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"
}

# ── Identity / principal ──────────────────────────────────────────

# principal_of alice → "ewhvm-...-pae"
principal_of() {
  icp identity principal --identity "$1" 2>/dev/null
}

# ── Backend call wrapper ──────────────────────────────────────────
# Auth-sensitive calls pass their own --identity. Calls that omit it get
# `--identity anonymous` appended — NEVER the CLI's global default identity,
# which is machine-shared mutable state that other sessions and connectors
# move at will (mdex-process-safety §5). Anonymous signs queries fine and is
# a canister controller on a local network anyway, so the identity-less
# reads and admin probes throughout the suite stay deterministic.
call() {
  case " $* " in
    *" --identity "*) echo "y" | icp canister call backend "$@" 2>&1 ;;
    *)                echo "y" | icp canister call backend "$@" --identity anonymous 2>&1 ;;
  esac
}

# ── Money helpers (integer-money migration) ───────────────────────
# The trading methods (placeLimitOrder/placeMarketOrder/openPosition/…) take Nat
# BASE UNITS (10^8), not Float. `e8` converts a human amount → base units so the
# tests stay readable:
#   call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 67600) : nat, $(e8 0.5) : nat)"
# (setTestBalance still takes a Float literal — it is boundary-normalized server-side.)
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
# from_e8: base units → human float (for reading money out of query results).
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

# ── Fixtures ──────────────────────────────────────────────────────

setup_mode() {
  local mode="$1"
  bash "$SCRIPT_DIR/scripts/seed.sh" "$mode" > /tmp/uplands-test-seed.log 2>&1 \
    || { echo "seed.sh $mode failed — see /tmp/uplands-test-seed.log" >&2; exit 1; }
}

# ── Polling helper ────────────────────────────────────────────────
# Poll predicate until it succeeds OR timeout.
#   wait_for "icp canister call backend foo '()' | grep -q done" 30 1
# Returns 0 on success, 1 on timeout.
wait_for() {
  local pred="$1" timeout="${2:-30}" interval="${3:-1}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if eval "$pred" > /dev/null 2>&1; then return 0; fi
    sleep "$interval"
    elapsed=$(( elapsed + interval ))
  done
  return 1
}

# ── Posture skips ─────────────────────────────────────────────────
# Posture doctrine (DEPLOY_MODE in src/backend/main.mo): #dev runs the same
# user-facing code as #play — dev-only hooks are the single divergence. A
# test (or section) that NEEDS a hook self-skips on hookless postures,
# loudly: the ⊘ marker is counted by run_all.sh as a posture-skip, so a
# #play/engine/subnet run shows exactly which coverage it is trusting the
# #dev suite for. Never skip silently, and never fake a pass.

venue_posture() {
  if [ -z "${_VENUE_POSTURE:-}" ]; then
    _VENUE_POSTURE=$(call getDeployMode '()' --query 2>/dev/null | grep -oE 'dev|play|production' | head -1)
  fi
  echo "${_VENUE_POSTURE:-unknown}"
}

# Whole-test skip: marker + SKIP banner, exits 0 (the runner counts the ⊘).
skip_posture() {  # $1 = test name, $2 = the hook/behaviour it needs
  echo -e "${YELLOW}  ⊘ SKIP (posture $(venue_posture)): $2 — assumed exercised on #dev${NC}"
  echo -e "\n${YELLOW}SKIP: $1 (posture)${NC}"
  exit 0
}

# Section skip: same marker, the rest of the test continues.
skip_section() {  # $1 = what is being skipped and why
  echo -e "${YELLOW}  ⊘ skipped: $1${NC}"
}

# ── Global invariants ─────────────────────────────────────────────
# Run after every test by `finish_test`. These are properties that
# MUST hold regardless of what the test was exercising. Adding new
# invariants here is the cheapest way to catch new classes of bugs.
#
#   I1: vaultLPSupply == sum of vaultLpBalances entries
#       (LP-balance sheet sanity)
#   I2: No 0-qty open orders on any market
#       (zombie-order regression — this is the bug we fixed)
#   I3: For every enabled pool, refPrice > 0
#       (a pool with refPrice=0 is silent-broken; getVaultValue returns 0)
#
# Each invariant is a fast query call. Total runtime for the whole
# suite is well under 1 second.

assert_invariants() {
  local marker="${1:-default}"
  echo -e "  ${DIM}── invariants ($marker) ──${NC}"

  # Every invariant below must PROVE IT OBSERVED something before it may
  # pass (#38.2 / W5-14): each one's failure shape used to be identical to
  # its pass shape — a trapped, renamed, or stopped query produced the same
  # green tick as a coherent venue, because grep over an error message
  # counts zero. A vacuous pass is now a FAIL; "observed empty" is labeled
  # as such and passes only when the response was well-formed.

  # I0: liveness positive control. If the surface cannot answer this, the
  # three invariants below cannot observe anything — refuse them all rather
  # than letting three vacuous ticks into the count.
  local info
  info=$(call getCanisterInfo '()' --query)
  if ! echo "$info" | grep -q "journalUnshipped"; then
    _fail "I0: backend not answering (getCanisterInfo) — invariants cannot pass unobserved: $(echo "$info" | tr -d '\n' | head -c 140)"
    return
  fi
  _ok "I0: surface alive (positive control observed)"

  # I1: LP balance sheet.
  local vault
  vault=$(call getVaultValue '()')
  local lpSupply
  lpSupply=$(extract_float "lpSupply" "$vault")
  if ! echo "$vault" | grep -q "lpSupply"; then
    _fail "I1: getVaultValue malformed/unanswered — refusing the vacuous pass: $(echo "$vault" | tr -d '\n' | head -c 140)"
  elif [ -z "$lpSupply" ] || [ "$lpSupply" = "0.0" ] || [ "$lpSupply" = "0" ]; then
    _ok "I1: vault OBSERVED empty (lpSupply=0, well-formed response)"
  else
    # Sum LP across the identities we can actually ask. There is NO backend
    # query that enumerates LP holders — only getMyVaultLp, which is per-caller
    # — so "Σ over everyone" is not something this helper can compute; it sums
    # the five seed fixtures by default. That equality holds because the tests
    # that fund the vault under ad-hoc identities now resetExchange at exit
    # (fixture-hygiene rule) — a test that legitimately leaves other holders
    # behind declares the complete set in MDX_LP_IDENTITIES instead.
    local idents="${MDX_LP_IDENTITIES:-alice bob charlie dave eve}"
    local sum=0.0
    for ident in $idents; do
      local pri
      pri=$(principal_of "$ident" 2>/dev/null) || continue
      [ -z "$pri" ] && continue
      local bal
      bal=$(call getMyVaultLp '()' --identity "$ident" \
            | tr -d '_' | grep -oE "[0-9]+" | head -1)   # LP is a base-unit Nat (underscore-separated)
      [ -z "$bal" ] && bal=0
      sum=$(python3 -c "print($sum + $bal)")
    done
    # Both sides are integer base-unit Nats (10^8/token), so the equality is
    # exact in principle; the tolerance exists only for float-printing edge
    # cases in the extractors. 100 base units = 1e-6 of one token: dust that
    # cannot mask a real leak, where the old RELATIVE 0.01 allowed 1% of the
    # whole supply (#51.5).
    local i1_tol_e8=100
    if [ -n "${MDX_LP_IDENTITIES:-}" ]; then
      assert_abs_close "I1: Σ LP over the declared holder set == vaultLPSupply" "$lpSupply" "$sum" "$i1_tol_e8"
    else
      assert_abs_close "I1: Σ LP balances == vaultLPSupply" "$lpSupply" "$sum" "$i1_tol_e8"
    fi
  fi

  # I2: No zombie orders — and each book must actually ANSWER: an error
  # string contains no "quantity = 0 :" either, which used to read as clean.
  local zombies=0
  local dead_books=""
  for m in BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD; do
    local book
    book=$(call getOrderBook "(\"$m\")" 2>&1)
    if ! echo "$book" | grep -q "bids = vec"; then
      dead_books="$dead_books $m"
      continue
    fi
    local n
    n=$(echo "$book" | grep -c "quantity = 0 :" || true)   # Nat zero prints as `0`, not `0.0`
    zombies=$(( zombies + n ))
  done
  if [ -n "$dead_books" ]; then
    _fail "I2: getOrderBook unanswered/malformed for:$dead_books — refusing the vacuous pass"
  else
    assert_eq "I2: no 0-qty zombie orders across markets (4 books observed)" "0" "$zombies"
  fi

  # I3: Enabled pools have non-zero refPrice — on a WELL-FORMED pool listing.
  local pools
  pools=$(call getAmmPools '()' 2>&1)
  if ! echo "$pools" | grep -q "vec"; then
    _fail "I3: getAmmPools malformed/unanswered — refusing the vacuous pass: $(echo "$pools" | tr -d '\n' | head -c 140)"
  elif echo "$pools" | tr -d ' \n' | grep -q "^(vec{})"; then
    _ok "I3: OBSERVED no pools (well-formed empty listing)"
  else
    local zero_ref
    zero_ref=$(echo "$pools" | tr ';' '\n' \
               | awk '/enabled = true/{e=1} /refPrice = 0 :/{r=1} /marketId/{if (e && r) print "1"; e=0; r=0}' \
               | wc -l | tr -d ' ')
    assert_eq "I3: no enabled pool with refPrice=0" "0" "$zero_ref"
  fi
}

# ── Lifecycle ────────────────────────────────────────────────────

finish_test() {
  local name="$1"
  # Run global invariants. They might fail even if the per-test
  # asserts passed — that's the point: invariants catch what the
  # test author didn't think to check.
  assert_invariants "$name"

  if [ "$_TEST_ERRORS" -eq 0 ]; then
    echo -e "\n${GREEN}PASS: $name${NC}"
    exit 0
  else
    echo -e "\n${RED}FAIL: $name ($_TEST_ERRORS failing assertions)${NC}" >&2
    exit 1
  fi
}
