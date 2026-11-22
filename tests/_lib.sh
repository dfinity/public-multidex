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
#   ── Reply oracles ──
#     mdx_ok            pass iff a call reply is the Result success shape
#                       (`variant { ok` or icp's hash-spelled `variant { 24_860`
#                       — never a bare "ok" substring); the verdict is
#                       scripts/lib/reply.sh's mdx_reply_ok (sourced below)
#     assert_ok         the assertion form of mdx_ok (name, reply)
#
#   ── Candid extractors ──
#     extract_float     pull a `name = N.NNN : float64` value out of output
#     extract_nat       pull a `name = N : nat` out of output
#     extract_first_nat extract the first `<digits> : nat` token
#
#   ── Identity / principal helpers ──
#     principal_of      get principal-text for a given identity
#     mdx_identity_new  a VIRGIN throwaway identity, deleted on EXIT
#     mdx_identity_rm   delete a throwaway identity (the spelling that deletes)
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

# Scratch files: a private per-run mktemp -d under .run/, never a fixed name
# under /tmp (H-04). Provides TEST_SCRATCH, scratch_new, seed_logged,
# MDX_TEST_SEED_LOG — see tests/_scratch.sh for why.
source "$SCRIPT_DIR/tests/_scratch.sh"

# The Candid reply predicates — mdx_reply_ok and friends — are the ONE copy
# in scripts/lib/reply.sh (task 1788503030), shared with seed.sh,
# play_start.sh and deploy.sh; mdx_ok below routes through it rather than
# carrying a second needle that could drift (task 1788508007). Pure function
# definitions, so sourcing it here is harmless to any suite that already has
# it. (scripts/simulate_trading.sh is the deliberate exception: live fleets
# run it, so it keeps a self-contained is_ok — hygiene §7i pins that copy.)
# SCRIPT_DIR is the repo root here (redefined above), so the path is fixed.
source "$SCRIPT_DIR/scripts/lib/reply.sh"

# The checked-in Candid contract every backend call hands icp (`--candid`,
# icp 1.2.0): icp then decodes replies BY NAME from the file instead of
# fetching the canister's candid:service metadata per call — a fetch that
# missed transiently on 2026-09-04 (task 1788507289) and made icp spell a
# successful unit `#ok` by its field HASH, `(variant { 24_860 })`. A method
# absent from the file degrades to the fetch (WARN + hash), never a CLI
# refusal, and mdx_ok accepts the hashed ok besides — two belts.
MDX_CANDID="$SCRIPT_DIR/candid/backend.did"

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

# ── Reply oracles ─────────────────────────────────────────────────
# The ONLY sanctioned success oracle for a `{ #ok; #err : Text }` call: the
# reply is judged by its VARIANT TAG, never by the substring "ok". A bare
# grep for "ok" matches the product's own refusals — baseToken, sellToken,
# buyToken, debtToken all contain it, and so does the word "hook" in a
# dev-hook refusal ("... is a dev-only hook (posture: play/production)") —
# so an #err at the owner cap, or a refused devTestHoldAdmission, read as the
# assertion's opposite (OhShii #51 follow-up items 2+3; H-26, 2026-09-04).
# icp pretty-prints replies across lines (`(\n  variant {\n    ok = record {`),
# so the reply is whitespace-normalized first, then matched on
# `variant { ok }` / `variant { ok = …` — or the hash-spelled twin
# `variant { 24_860 …` icp prints when its candid fetch misses (idl_hash(ok)
# = 24_860; `err` = 5_048_165 and `Err` = 3_456_837 still refuse). The
# needle itself lives ONCE, in scripts/lib/reply.sh's mdx_reply_ok
# (`grep -c … >/dev/null`, not `-q`: -q exits at the first match without
# draining and the pipefail above would promote the SIGPIPE into a false
# negative — the W5-10 item 3 shape); this wrapper adds the stdin form.
# Takes the reply as $1 or on stdin. Hygiene §7i bans the bare form in
# tests/*.sh; §6aa pins the behaviour on the refusal / unit / valued /
# record shapes; §6af slices this function and drives it with the named AND
# hashed ok / err spellings.
#   if mdx_ok "$R"; then ok "staged"; else nok "refused" "$R"; fi
mdx_ok() {
  local reply
  if [ $# -gt 0 ]; then reply="$1"; else reply="$(cat)"; fi
  mdx_reply_ok "$reply"
}

# assert_ok <name> <reply> — the assertion form of mdx_ok for _lib.sh suites.
# Replaces `assert_contains <name> "$R" "ok"`, which passed any refusal whose
# text contains "ok" (…Token, hook, …) — hygiene §7i bans that spelling too.
assert_ok() {
  local name="$1" reply="$2"
  if mdx_ok "$reply"; then
    _ok "$name"
  else
    _fail "$name: expected a #ok reply, got: $(printf '%s' "$reply" | tr -s '[:space:]' ' ' | head -c 160)"
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

# ── Identity lifecycle ────────────────────────────────────────────
# Suites mint throwaway identities into the store the run uses ($ICP_HOME — a
# seat's private .icp-home, or the machine-global store). They MUST leave
# again: the global store already sits near the ~300-identity CMC mint-cap
# abort at network start, and a persisted identity carries the previous run's
# activity into the next run's "virgin" assertions (a "B has no season-N
# history" check read the prior run's B). `icp identity delete` takes NO --yes
# flag — that spelling fails on argument parsing (rc 2) and an `|| true`
# swallowed it in eight suites, so their "cleanup" never deleted anything
# (task 1788502454). The CLI confirms on stdin: `echo y |` is the spelling
# that deletes. A missing name is rc 1, swallowed, so the helper is idempotent
# and safe to register on_exit. Hygiene §6ad pins both helpers and bans the
# --yes spelling across tests/.
#
#   mdx_identity_rm  <name>   delete <name> from the store (no-op if absent)
#   mdx_identity_ensure <name>  a STANDING identity (alice / bob / charlie / dave /
#                             eve — scripts/seed.sh's ensure_identity fixtures;
#                             run_tests.sh and deploy.sh mint the first three
#                             and 20+ suites sign with them): create it if
#                             absent, KEEP its principal, never delete. Only
#                             for those shared names (hygiene §6ae); a suite's
#                             own actors use mdx_identity_new so they leave
#                             with the run.
#   mdx_identity_new <name>   a VIRGIN identity: delete any leftover first (a
#                             stale name would make `identity new` no-op and
#                             hand back the previous run's principal), create
#                             it with plaintext storage, and register the
#                             delete through on_exit so a mid-suite `exit`
#                             still cleans up. Prints nothing — read the
#                             principal with principal_of afterwards.
#
# Call mdx_identity_new as a STATEMENT, never inside $(...): a command
# substitution is a subshell, and an on_exit registered there dies with it
# (the identity would then outlive the run exactly as before). The helper
# refuses that shape out loud instead of leaking silently.
mdx_identity_rm() { echo y | icp identity delete "$1" >/dev/null 2>&1 || true; }
mdx_identity_ensure() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }
mdx_identity_new() {
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
    echo "mdx_identity_new $1: called in a subshell (\$(...)) — the on_exit cleanup would be lost; call it as a statement, then principal_of $1" >&2
    return 1
  fi
  mdx_identity_rm "$1"
  on_exit "mdx_identity_rm $(printf '%q' "$1")"
  icp identity new "$1" --storage plaintext >/dev/null 2>&1 \
    || { echo "mdx_identity_new: could not create identity '$1' in ${ICP_HOME:-the global icp store}" >&2; return 1; }
}

# ── Backend call wrapper ──────────────────────────────────────────
# Auth-sensitive calls pass their own --identity. Calls that omit it get
# `--identity anonymous` appended — NEVER the CLI's global default identity,
# which is machine-shared mutable state that other sessions and connectors
# move at will (mdex-process-safety §5). Anonymous signs queries fine and is
# a canister controller on a local network anyway, so the identity-less
# reads and admin probes throughout the suite stay deterministic.
# Every call hands icp the checked-in contract (`--candid "$MDX_CANDID"`, see
# the top of this file) when the file is present; a stripped checkout falls
# back to the per-call metadata fetch, and mdx_ok's hashed spelling then
# still carries the verdict.
call() {
  case " $* " in
    *" --identity "*) ;;
    *) set -- "$@" --identity anonymous ;;
  esac
  if [ -f "$MDX_CANDID" ]; then
    echo "y" | icp canister call backend "$@" --candid "$MDX_CANDID" 2>&1
  else
    echo "y" | icp canister call backend "$@" 2>&1
  fi
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
# Fixture rule — a created pool that HOLDS a priced leg must be ENABLED
# (task 1788500129; pinned by test_deploy_hygiene §6ab). tickPriceRefresh
# (src/backend/main.mo) refreshes ENABLED pools only, so a pool a fixture
# creates with createAmmPool + setAmmRefPrice and never enableAmm keeps the
# stamped mark forever. Once the vault holds that pool's base leg
# (seedAmmPool / mdx_lp_deposit with a non-zero base amount), vaultPricesStale
# refuses EVERY LP mint on the venue from 60s after the stamp ("LP deposit
# paused: <asset> refPrice is stale") — for the suite's own later sections
# and for every suite that follows without a reset. Either
# `adm enableAmm "(\"<mkt>\", true)"` right after the seed (the feed then
# keeps the mark fresh; with timers running the seed mark may pend ~65-95s
# behind the circuit breaker first), or deposit QUOTE-ONLY (`0 : nat` base)
# when the suite does not need the base leg — a leg the vault does not hold
# is never gated. Re-stamping with setAmmRefPrice before each mint covers
# the run itself, never the venue afterwards.

# ── Live-mark pin (task 1788541235) ──────────────────────────────
# A #dev seat venue runs the REAL multi-source feed, so whatever a fixture
# stamps, the next fetch that lands compares the live reading against it: a
# synthetic mark >2.5% off the live price is PENDED by the jump breaker (ref
# frozen, refPriceUpdatedNs not advanced, ammBreakerWidenBps widening both
# ladder sides by the full gap), and a predecessor that leaves a synthetic
# mark on an ENABLED pool with the timers running hands the next suite a
# pended asset (partial_close's $25,700 BTC at a live ~$80k → the periodic
# tick pends it → play_deposit_cap §8 "held pending a price-jump
# confirmation"). setTestTimersPaused is no wall either: a fetch already in
# flight when the pause lands still applies (and under H-37's fan-out a
# dispatch made before the pause finalizes at the deadline sweep, above the
# pause gate). A fixture that needs a mark the live feed AGREES with pins
# it here (#dev hooks — call under a dev posture only; the pool must exist
# — createAmmPool first):
#
#   mdx_live_aggregate_e8 <asset>   → the feed's last aggregate price (e8),
#       or nothing when the venue holds none (the feed never ticked, or a
#       wipe cleared lastAggregates — resetExchange does).
#   mdx_pin_mark <asset> <market> [<fallback_e8>]   → "<price_e8> <source>"
#       1. read the last aggregate; none → PRIME it with one admin fetch
#          (fetchAndSetRefPrice — the callee writes lastAggregates before
#          the accept gate decides anything about the mark) and read again;
#          still none (a feed-less venue, where no fetch can move the mark
#          either) → the pool's current refPrice, else <fallback_e8>;
#       2. clear the asset's breaker pend (setTestPendingJump) and stamp the
#          mark NOW at that price (setAmmRefPrice: clears the pend, stamps
#          the release reference).
#       Prints the pinned price (e8) and where it came from (aggregate |
#       primed | pool | fallback); prints nothing and returns 1 when no price
#       could be found. Pins the run, not the venue afterwards — a wipe or a
#       synthetic re-stamp by the next suite starts the clock again.
mdx_live_aggregate_e8() {
  call getLastAggregate "(\"$1\")" --query 2>/dev/null | awk '
    depth == 1 && $1 == "price"     { px = $3 }
    { depth += gsub(/\{/, "{") - gsub(/\}/, "}") }
    END { if (px + 0 > 0) printf "%.0f\n", px * 100000000 }'
}
mdx_pin_mark() {
  local asset="$1" mkt="$2" fb="${3:-}" px src="aggregate"
  px=$(mdx_live_aggregate_e8 "$asset")
  if [ -z "$px" ]; then
    call fetchAndSetRefPrice "(\"$mkt\")" >/dev/null 2>&1 || true
    px=$(mdx_live_aggregate_e8 "$asset"); src="primed"
  fi
  if [ -z "$px" ]; then
    px=$(call getAmmPool "(\"$mkt\")" --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE 'refPrice = [0-9]+' | head -1 | awk '{print $3}'); src="pool"
    if ! [ "${px:-0}" -gt 0 ] 2>/dev/null; then px="$fb"; src="fallback"; fi
  fi
  [ -n "$px" ] && [ "$px" -gt 0 ] 2>/dev/null || return 1
  call setTestPendingJump "(\"$asset\", null, null)" >/dev/null 2>&1
  call setAmmRefPrice "(\"$mkt\", $px : nat)" >/dev/null 2>&1
  echo "$px $src"
}
#   mdx_restamp_mark <asset> <market> [<fallback_e8>] [<agree_bps>]  → "<price_e8> <source>"
#       mdx_pin_mark MOVES the mark to the aggregate — right for a fixture
#       the feed must agree with, wrong for one that only needs a FRESH mark
#       it will stamp again itself: a residue mark tens of percent from live
#       (initial_margin's $150 SOL over a $101 feed) moved in ONE stamp is a
#       −32% "return" to the AMM's EWMA, volRegime blows (71 → 1,691 bps
#       measured), the ladder quotes ±9% and decays only ~5% a requote — a
#       5%-collared taker reaches no bid for dozens of requotes (task
#       1788556083: liq_direction §1 "short did not fill" right after the
#       pin). So: an UNPRICED pool, or one whose mark the aggregate agrees
#       with (within <agree_bps>, default 250 — the jump breaker's own bar),
#       pins through mdx_pin_mark (no move the feed would pend); any other
#       priced pool KEEPS its mark — pend cleared, mark re-stamped at its own
#       price (freshness only) — and the source reads "kept". Same output
#       shape and return code as mdx_pin_mark.
#   mdx_calm_ladder <market> <mark_e8> <max_bps> [<tries>]   → 0 once both
#       sides of the AMM ladder quote within <max_bps> of <mark_e8>, 1 after
#       <tries> (default 30) rounds without it. A blown volRegime (above)
#       decays only per requote, and a paused venue requotes only when asked,
#       so this READS and DRIVES: each miss re-stamps the mark at <mark_e8>
#       (freshness, no movement) and requotes, then waits a second. A one-
#       sided or empty book counts as a miss (a withdrawn side is what an
#       inventory / cash floor does).
mdx_restamp_mark() {
  local asset="$1" mkt="$2" fb="${3:-}" agree="${4:-250}" cur agg
  cur=$(call getAmmPool "(\"$mkt\")" --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE 'refPrice = [0-9]+' | head -1 | awk '{print $3}')
  if [ "${cur:-0}" -gt 0 ] 2>/dev/null; then
    agg=$(mdx_live_aggregate_e8 "$asset")
    if [ -z "$agg" ] || ! python3 -c 'import sys; c, a, b = map(int, sys.argv[1:]); sys.exit(0 if abs(a - c) * 10000 <= c * b else 1)' "$cur" "$agg" "$agree"; then
      call setTestPendingJump "(\"$asset\", null, null)" >/dev/null 2>&1
      call setAmmRefPrice "(\"$mkt\", $cur : nat)" >/dev/null 2>&1
      echo "$cur kept"; return 0
    fi
  fi
  mdx_pin_mark "$asset" "$mkt" "$fb"
}
mdx_calm_ladder() {
  local mkt="$1" mark="$2" maxbps="$3" tries="${4:-30}" i=0 depth b a
  while [ "$i" -lt "$tries" ]; do
    depth=$(call getOrderBookDepth "(\"$mkt\", opt (1 : nat))" --query 2>/dev/null | tr -d '_\n')
    b=$(printf '%s' "$depth" | grep -oE 'bids = vec \{[^}]*price = [0-9]+' | grep -oE '[0-9]+$')
    a=$(printf '%s' "$depth" | grep -oE 'asks = vec \{[^}]*price = [0-9]+' | grep -oE '[0-9]+$')
    if [ -n "$b" ] && [ -n "$a" ] \
       && python3 -c 'import sys; m, b, a, x = map(int, sys.argv[1:]); sys.exit(0 if (m - b) * 10000 <= m * x and (a - m) * 10000 <= m * x else 1)' "$mark" "$b" "$a" "$maxbps"; then
      return 0
    fi
    call setAmmRefPrice "(\"$mkt\", $mark : nat)" >/dev/null 2>&1
    call requoteAmm "(\"$mkt\")" >/dev/null 2>&1
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# ── Staged LP doors (apiVersion 6.0.0, task 1788731608) ──────────────
# depositLp / withdrawLp are SEALED requests (docs/amm-vault-design.md §5
# "Sealed LP requests"): the reply is the REQUEST, and the mint / redemption
# settles at the first NAV whose basket marks ALL postdate it — releaseRefs'
# dispatch clock, which #dev's setAmmRefPrice stamps like a fetch — through
# the same body the immediate doors used to run, every refusal evaluated AT
# SETTLEMENT and recorded as a #cancelled outcome. seedAmmPool (controller-
# only) is the one immediate door left; a fixture identity mints through
# these. They retire test_ghsa_round4's 30×3 s "LP deposit paused" retry: a
# staged request cannot flicker stale — the re-stamp below postdates it.
#
#   mdx_lp_deposit  <identity> <market> <base_e8> <quote_e8> [<wait_s>]
#   mdx_lp_withdraw <identity> <lp_e8> [<wait_s>]
#       stage as <identity>; re-stamp every market the request is waiting on
#       at its OWN current price (setAmmRefPrice — freshness only, no move;
#       it also clears a breaker pend on that asset, so a suite that pins
#       pend or stale-mark semantics stages RAW — `u depositLp …` — and
#       drives `adm adminRunStagedLp` by hand instead); requote the
#       deposit's market (the releasing pass) and run adminRunStagedLp (the
#       driver when the pool is disabled or the timers are paused); then
#       read the outcome off getMyStagedLpRequests. Prints and returns:
#         rc 0  the minted LP (e8 integer) | the `redeemed = record {…}` basket
#         rc 1  the refusal — at the request (the #err reply, flattened) or
#               at settlement (the `cancelled = "…"` outcome, verbatim)
#         rc 2  still pending after <wait_s> (default 0) seconds of 3 s polls
#               — a held leg is breaker-pended, or no mark postdated it; the
#               text names the request with its waitingOn list
#   mdx_lp_view <identity>              → getMyStagedLpRequests, flattened
#   mdx_lp_outcome <identity> <id>      → that request's settled outcome record
#                                         (nothing while it is pending)
#   mdx_lp_pending <identity> <id>      → that request's pending record (nothing
#                                         once settled / cancelled)
#       — the building blocks for hand-driven pins (a pend that must hold, a
#       stale mark that must NOT settle, the TTL backstop).
mdx_lp_view()    { call getMyStagedLpRequests '()' --query --identity "$1" 2>/dev/null | tr -d '_\n' | tr -s ' '; }
mdx_lp_records() { mdx_lp_view "$1" | sed 's/record { id = /\
record { id = /g' | grep -E "^record \{ id = $2[; :]"; }
mdx_lp_outcome() { mdx_lp_records "$1" "$2" | grep 'settledNs' | head -1; }
mdx_lp_pending() { mdx_lp_records "$1" "$2" | grep -v 'settledNs' | head -1; }
mdx_lp_reqid()   { printf '%s' "$1" | tr -d '_\n' | tr -s ' ' | grep -oE 'record \{ id = [0-9]+' | grep -oE '[0-9]+' | head -1; }
mdx_lp_settle() {  # <identity> <request id> <request reply> <requote market or ""> <wait_s>
  local who="$1" rid="$2" reply="$3" mkt="$4" wait="${5:-0}" m cur out waited=0
  for m in $(printf '%s' "$reply" | tr -d '\n' | tr -s ' ' | grep -oE 'waitingOn = vec \{[^}]*\}' | grep -oE '"[A-Z]+-ICPUSD"' | tr -d '"'); do
    cur=$(call getAmmPool "(\"$m\")" --query 2>/dev/null | tr -d '_\n' | tr -s ' ' | grep -oE 'refPrice = [0-9]+' | head -1 | awk '{print $3}')
    if [ "${cur:-0}" -gt 0 ] 2>/dev/null; then call setAmmRefPrice "(\"$m\", $cur : nat)" >/dev/null 2>&1; fi
  done
  [ -n "$mkt" ] && call requoteAmm "(\"$mkt\")" >/dev/null 2>&1
  call adminRunStagedLp '()' >/dev/null 2>&1
  out=$(mdx_lp_outcome "$who" "$rid")
  while [ -z "$out" ] && [ "$waited" -lt "$wait" ]; do
    perl -e 'select(undef,undef,undef,3)'; waited=$((waited + 3))
    call adminRunStagedLp '()' >/dev/null 2>&1
    out=$(mdx_lp_outcome "$who" "$rid")
  done
  if [ -z "$out" ]; then
    echo "staged LP request #$rid still pending: $(mdx_lp_pending "$who" "$rid")"; return 2
  fi
  case "$out" in
    *"minted = "*)   printf '%s\n' "$out" | grep -oE 'minted = [0-9]+' | grep -oE '[0-9]+' | head -1; return 0 ;;
    *"redeemed = "*) printf '%s\n' "$out" | grep -oE 'redeemed = record \{[^}]*\}' | head -1; return 0 ;;
    *)               printf '%s\n' "$out" | grep -oE 'cancelled = "[^"]*"' | head -1; return 1 ;;
  esac
}
mdx_lp_deposit() {
  local who="$1" mkt="$2" base="$3" quote="$4" wait="${5:-0}" r
  r=$(call depositLp "(\"$mkt\", $base : nat, $quote : nat)" --identity "$who")
  if ! mdx_ok "$r"; then printf '%s\n' "$r" | tr -d '\n' | tr -s ' '; return 1; fi
  mdx_lp_settle "$who" "$(mdx_lp_reqid "$r")" "$r" "$mkt" "$wait"
}
mdx_lp_withdraw() {
  local who="$1" lp="$2" wait="${3:-0}" r
  r=$(call withdrawLp "($lp : nat)" --identity "$who")
  if ! mdx_ok "$r"; then printf '%s\n' "$r" | tr -d '\n' | tr -s ' '; return 1; fi
  mdx_lp_settle "$who" "$(mdx_lp_reqid "$r")" "$r" "" "$wait"
}

setup_mode() {
  local mode="$1"
  seed_logged "$mode"
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

# ── The Bridge's posture, and in-suite Bridge upgrades ────────────
# The Bridge carries its OWN DEPLOY_MODE (src/bridge/main.mo). On a factory
# seat the tree sits at #play between deploys while the venue runs #dev, so
# an in-suite rebuild from the tree (`icp deploy bridge`, or `icp build` +
# `icp canister install --mode upgrade`) silently flips the venue's Bridge to
# #play, and every later suite that needs a Bridge dev hook
# (devTestHoldAdmission, devTestStrandAdmission) reds for a reason that is
# not code. Every suite that upgrades the Bridge in place goes through this
# ONE guard: rebuild + upgrade only when the tree's posture equals the venue
# Bridge's; otherwise a loud ⊘ naming both. (`icp canister install` does NOT
# rebuild — it installs the LAST build output, whatever posture that was
# built at — so the build step is load-bearing: the wasm that lands must be
# the tree's, whose posture was just compared.)
bridge_posture() {   # the VENUE Bridge's posture: dev | play | production | "" (unanswered)
  echo y | icp canister call bridge getDeployMode '()' --query --identity anonymous 2>/dev/null \
    | grep -oE 'dev|play|production' | head -1
}
bridge_tree_posture() {   # the TREE's Bridge literal, via the one comment-aware reader
  bash -c '. "$1/scripts/lib/targets.sh" && mdx_posture_of "$1/src/bridge/main.mo"' _ "$SCRIPT_DIR" 2>/dev/null
}
# bridge_upgrade_if_posture_matches [label]
#   returns 0  rebuilt + upgraded in place        (BRIDGE_UPGRADE_NOTE says so)
#           1  skipped — the postures differ      (⊘ printed; the note names both)
#           2  build or install failed            (the note names the class)
BRIDGE_UPGRADE_NOTE=""
bridge_upgrade_if_posture_matches() {
  local label="${1:-in-place Bridge upgrade}" venue tree
  venue=$(bridge_posture); tree=$(bridge_tree_posture)
  if [ -z "$venue" ] || [ "$venue" != "$tree" ]; then
    BRIDGE_UPGRADE_NOTE="skipped (tree #${tree:-?} vs venue Bridge #${venue:-?})"
    skip_section "$label (tree is #${tree:-?}, venue Bridge is #${venue:-?} — the rebuild would flip the venue's posture; run from a matching tree to exercise it)"
    return 1
  fi
  if (cd "$SCRIPT_DIR" && icp build bridge >/dev/null 2>&1 \
        && icp canister install bridge --mode upgrade -y --identity anonymous >/dev/null 2>&1); then
    BRIDGE_UPGRADE_NOTE="bridge rebuilt + upgraded in place (tree #$tree == venue #$venue)"
    return 0
  fi
  BRIDGE_UPGRADE_NOTE="build/install error (tree #$tree == venue #$venue)"
  return 2
}

# ── Global invariants ─────────────────────────────────────────────
# I1 tolerance, in BASE UNITS (absolute). Both sides of I1 are integer
# base-unit Nats (10^8/token), so the equality is exact in principle; the
# tolerance exists only for float-printing edge cases in the extractors.
# 100 base units = 1e-6 of one token: dust that cannot mask a real leak,
# where the old RELATIVE 0.01 allowed 1% of the whole supply (#51.5).
# Shared: assert_invariants below AND test_invariants_battery.sh's smoke
# test of the same property use this one number (#51 follow-up item 3).
i1_tol_e8=100
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
    # exact in principle; the shared i1_tol_e8 (file scope, above) is the
    # only slack — test_invariants_battery.sh asserts the same property with
    # the same tolerance (#51.5 second site).
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
