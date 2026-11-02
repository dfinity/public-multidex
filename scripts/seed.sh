#!/bin/bash
# UPLANDS DEX — Unified Seed Dispatcher
#
# One script, many seeding modes. Each mode produces a known state that
# either (a) makes UPLANDS usable for manual exploration, or (b) sets up
# a deterministic fixture that a regression test can assert against.
#
# Usage: bash scripts/seed.sh MODE [--traders N] [--history-days N]
#
# Modes:
#   full        Rich production-like state (everything on, full history).
#   empty       No-op; just verifies markets are initialized.
#   matching    2 traders, 1 market, known book. For matching-engine tests.
#   amm         1 trader, AMM seeded + enabled + oracle price set. For AMM tests.
#   staged      2 traders, 1 BUY staged (sealed), counterparty funded. For the staged-order suites.
#   load        N bulk-seeded principals + sparse book. For load testing.
#
# Env knobs (full mode):
#   MDX_ORACLE_PRICES       history snapshot inject_history writes and step 3/4 read
#   MDX_SEED_FEED_WAIT_SEC  cap on the post-seed wait for the first feed tick to
#                           refresh the AMM marks (default 90; 0 disables). cold_start's
#                           AMM-oracle-health phase polls the same evidence and ends
#                           at once when this wait already landed the tick. The AMM
#                           marks come from the live aggregate when the feed has
#                           ticked on the venue, else the history snapshot, else
#                           hardcoded defaults.
#
# Design note:
#   Test modes (matching / amm / staged) are deliberately *minimal*. A
#   test that asserts "there are exactly 2 open orders" should not break
#   when the default seed adds a 3rd. Keep each fixture small and
#   orthogonal to the others.

set -o pipefail
export PATH="$HOME/.local/bin:$PATH"

MODE="${1:-}"
shift || true
TRADERS=100
HISTORY_DAYS=9
while [ $# -gt 0 ]; do
  case "$1" in
    --traders)      TRADERS="$2"; shift 2 ;;
    --history-days) HISTORY_DAYS="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Usage: bash scripts/seed.sh MODE [--traders N] [--history-days N]" >&2
  echo "Modes: full | empty | matching | amm | staged | load" >&2
  exit 1
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

log()   { echo -e "${CYAN}▶${NC} $1"; }
ok()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()  { echo -e "  ${YELLOW}!${NC} $1"; }
err()   { echo -e "  ${RED}✗${NC} $1" >&2; }

# Pipe "y" into icp canister call so the interactive confirm is
# auto-accepted when candid can't be inferred.
# Every call carries the checked-in Candid contract (`--candid`, icp 1.2.0):
# icp then encodes arguments and decodes replies BY NAME from the file
# instead of fetching the canister's candid:service metadata per call. That
# fetch failed transiently on 2026-09-04 (task 1788507289) — "WARN could not
# fetch candid type, serializing arguments with inferred types." — and icp
# spelled a successful createAmmPool's unit `#ok` by its Candid field HASH,
# `(variant { 24_860 })`, which the name-only matcher read as a refusal and
# aborted a half-seeded venue. A stripped checkout without the file falls
# back to the fetch; mdx_reply_ok's hashed spellings then still carry the verdict.
SEED_CANDID="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../candid/backend.did"
# Every call site MUST name its identity: the CLI's global default identity
# is machine-shared mutable state that other sessions and connectors move at
# will (mdex-process-safety §5), so an identity-less call here would sign as
# whoever happens to be active. All fixtures seed as a KNOWN identity —
# refuse loudly rather than half-seed as the wrong principal.
call() {
  case " $* " in
    *" --identity "*) ;;
    *) err "call() without --identity (mdex-process-safety §5): $*"; return 1 ;;
  esac
  if [ -f "$SEED_CANDID" ]; then
    echo "y" | icp canister call backend "$@" --candid "$SEED_CANDID" 2>&1
  else
    echo "y" | icp canister call backend "$@" 2>&1
  fi
}

# ── Reply oracles (task 1788501249; the predicates live in scripts/lib/reply.sh) ──
# `call` returns icp's exit status, and a Candid REFUSAL — `variant { err =
# "..." }` — is a successful call as far as icp is concerned: exit 0. With
# every seeding line's reply sent to /dev/null, a refused money-moving step
# printed its ✓ anyway. Observed 2026-09-04: a `seed.sh full` whose
# resetExchange never took effect printed all four "<market> enabled" lines
# and "Seed 'full' complete." over four refused seedAmmPool deposits ("at
# its vault concentration cap"), and cold_start — whose seed step this is —
# handed over an enabled-but-hollow venue. The money-moving steps below now
# assert their reply through the shared predicates (mdx_reply_ok /
# mdx_reply_unit / mdx_reply_nat, plus the extractors mdx_one_line /
# mdx_vault_nat / mdx_reply_nat_value): the `variant { ok }`
# shape, named or HASH-spelled (`24_860` when icp's candid fetch misses —
# task 1788507289; `err` = 5_048_165 is refused like the named form), see
# scripts/lib/reply.sh for the whole doctrine. ONE copy for seed.sh,
# play_start.sh and deploy.sh (task 1788503030) — hygiene §3d pins the source
# line and the absence of a private copy; §6af unit-tests the lib.
# A refusal is a ✗ line carrying the reply text and a non-zero exit — every
# caller (cold_start's seed step, tests/_scratch.sh's seed_logged) aborts
# on it instead of trusting a hollow venue.
# shellcheck source=scripts/lib/reply.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/reply.sh"

# seed_fail <what> <reply> — the loud exit. Resumes the timers if a fixture
# had paused them, so an aborted seed does not strand a paused venue.
SEED_TIMERS_PAUSED=false
seed_fail() {
  err "$1: $(mdx_one_line "$2")"
  if [ "$SEED_TIMERS_PAUSED" = "true" ]; then
    call setTestTimersPaused "(false)" --identity alice > /dev/null 2>&1 || true
  fi
  err "seed '$MODE' ABORTED — the venue is NOT seeded (see the ✗ line above)"
  exit 1
}

# must_ok <label> <call args...>   — the call must answer `variant { ok ... }`
must_ok() {
  local label="$1"; shift
  local out rc
  out=$(call "$@"); rc=$?
  if [ "$rc" -ne 0 ] || ! mdx_reply_ok "$out"; then
    seed_fail "$label refused (rc=$rc)" "$out"
  fi
}
# must_unit <label> <call args...> — a unit-returning admin call must answer `()`
# (a trap — e.g. "Caller is not a canister controller" — is a non-zero exit
# with the reject text on stdout+stderr, which the ✗ line then carries).
must_unit() {
  local label="$1"; shift
  local out rc
  out=$(call "$@"); rc=$?
  if [ "$rc" -ne 0 ] || ! mdx_reply_unit "$out"; then
    seed_fail "$label failed (rc=$rc)" "$out"
  fi
}
# bulk_fund <batch entries> <entry count> — ONE bulkSetTestBalances call, its
# reply READ. The method answers the number of balance rows it wrote
# (`-> (nat)`; the lib's mdx_reply_nat gates the shape and its
# mdx_reply_nat_value reads the N — task 1793496257), so the verdict is the
# count: exactly entries × 4 (the four tokens every padded trader holds).
# Anything else — a Candid parser error
# (the CLI refuses the bare keyword `principal` as a record label: task
# 1788536324 found every padded trader unfunded behind a "✓ balances seeded"
# line because the reply went to /dev/null), a trap, a short count — aborts
# through seed_fail. Never trust the ✓ line to a discarded reply again.
bulk_fund() {
  local batch="$1" entries="$2"
  local want out rc got
  want=$(( entries * 4 ))
  out=$(call bulkSetTestBalances "(vec { $batch })" --identity alice); rc=$?
  if [ "$rc" -ne 0 ] || ! mdx_reply_nat "$out"; then
    seed_fail "bulkSetTestBalances ($entries accounts) did not answer (N : nat) (rc=$rc)" "$out"
  fi
  got=$(mdx_reply_nat_value "$out")
  if [ "$got" != "$want" ]; then
    seed_fail "bulkSetTestBalances wrote $got balance rows for $entries accounts (expected $want)" "$out"
  fi
  ok "bulkSetTestBalances: $got balance rows written for $entries accounts"
}

# vault_value — getVaultValue as one whitespace-normalized line.
vault_value() {
  echo "y" | icp canister call backend getVaultValue '()' --query --identity anonymous 2>&1 \
    | tr -s '[:space:]' ' '
}

# reset_exchange — resetExchange answers unit, so its exit status alone
# cannot tell "wiped" from "never delivered": assert the post-condition the
# fixtures rely on (lpSupply 0, no AMM pools) before seeding on top of it.
reset_exchange() {
  must_unit "resetExchange" resetExchange '()' --identity alice
  local vault lp pools
  vault=$(vault_value)
  lp=$(mdx_vault_nat "$vault" lpSupply)
  [ "$lp" = "0" ] || seed_fail "resetExchange did not wipe the vault (lpSupply = ${lp:-unreadable}, expected 0)" "$vault"
  pools=$(echo "y" | icp canister call backend getAmmPools '()' --query --identity anonymous 2>&1 | tr -s '[:space:]' ' ')
  printf '%s' "$pools" | grep -qE '^\( ?vec \{ ?\},? ?\) ?$' \
    || seed_fail "resetExchange did not wipe the AMM pools (expected (vec {}))" "$pools"
}

# assert_vault_seeded <base tokens...> — the post-condition an AMM seed
# promises: LP supply minted AND every seeded pool's base leg present in the
# basket. A refused deposit that somehow slipped past must_ok (or a vault
# that survived the reset) shows up here as lpSupply 0 / an empty leg.
assert_vault_seeded() {
  local vault lp basket tok fld amt
  vault=$(vault_value)
  lp=$(mdx_vault_nat "$vault" lpSupply)
  case "$lp" in
    ''|0) seed_fail "post-seed lpSupply = ${lp:-unreadable} (expected > 0) — the vault deposits did not land" "$vault" ;;
  esac
  basket=$(printf '%s' "$vault" | sed -n 's/.*basket = record {\([^}]*\)}.*/\1/p')
  for tok in "$@"; do
    fld=$(printf '%s' "$tok" | tr 'A-Z' 'a-z')
    amt=$(mdx_vault_nat "$basket" "$fld")
    case "$amt" in
      ''|0) seed_fail "post-seed basket has no $tok leg (${fld} = ${amt:-unreadable}) — the $tok pool's deposit did not land" "$vault" ;;
    esac
  done
  ok "vault post-condition: lpSupply $lp · base legs present: $*"
}

# Integer-money: human decimal -> integer base units (10^8 / e8s). Money
# args (balances, prices, qtys, amounts) are now Nat base units on the wire.
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

# Live-feed mark for one asset: prints "<price> <age-seconds>" from the
# top-level fields of getLastAggregate(<asset>) — `price` is a float64 in
# quote units, the same human-decimal shape e8() takes — or nothing when no
# aggregate exists yet (feed never ticked on this venue, or the venue was
# reset since: resetExchange CLEARS lastAggregates, so a fixture that wants
# the live mark must read it BEFORE it resets). The awk tracks brace depth
# because every per-source record inside `readings = vec { ... }` carries its
# own `price =` one level deeper than the aggregate's; the price is passed
# through as text (awk's %.6g OFMT would round 80922.84 to 80922.8).
live_aggregate_mark() {
  local asset="$1" out
  out=$(call getLastAggregate "(\"$asset\")" --query --identity anonymous) || return 0
  printf '%s\n' "$out" | awk -v now="$(date +%s)" '
    depth == 1 && $1 == "price"     { px = $3 }
    depth == 1 && $1 == "timestamp" { ts = $3; gsub(/_/, "", ts); age = now - int(ts / 1000000000) }
    { depth += gsub(/\{/, "{") - gsub(/\}/, "}") }
    END { if (px + 0 > 0) print px, age + 0 }'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Scratch-file locations (.run/, not fixed names under sticky /tmp) — see
# scripts/lib/runfiles.sh.
# shellcheck source=scripts/lib/runfiles.sh
. "$SCRIPT_DIR/lib/runfiles.sh"

# ── Posture guard ────────────────────────────────────────────────
# Every fixture below leans on #dev-only surfaces (setAmmRefPrice, test
# overrides). On #play those #err — and because this script discards call
# output, seeding then HALF-completes in silence: pools get created,
# enabled and skew-configured while seedAmmPool's refPrice gate rejects
# the actual vault deposit, leaving an enabled-but-EMPTY AMM and no
# insurance fund (only play_start.sh seeds that). Refuse loudly instead.
# `empty` is a pure verify pass, allowed on any posture. No reachable
# backend (empty POSTURE) falls through to the modes' own errors.
if [ "$MODE" != "empty" ]; then
  POSTURE=$(icp canister call backend getDeployMode "()" --query --identity anonymous 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"')
  if [ -n "$POSTURE" ] && [ "$POSTURE" != "dev" ]; then
    err "backend posture is #$POSTURE — seed.sh fixtures are #dev-only."
    echo "     → #play bring-up (seeded AMM vault + insurance fund): bash scripts/cold_start.sh   (the default mode)" >&2
    echo "     → dev fixtures: set DEPLOY_MODE = #dev in src/backend/main.mo and redeploy first" >&2
    exit 1
  fi
fi

# ── Identity helpers ─────────────────────────────────────────────
ensure_identity() {
  local name="$1"
  icp identity new "$name" --storage plaintext 2>/dev/null || true
  icp identity principal --identity "$name" 2>/dev/null
}

# Create N "phantom" principals for load-test seeding. These aren't real
# identities (no keys generated), just deterministic Principal values
# that setTestBalance / bulkSetTestBalances accept.
# Format: self-check principals like "aaaaa-aa" won't work; we need
# well-formed text. Easiest path: derive N principals from disposable
# identities — created, read, and deleted in one pass. Only the
# principal text is used downstream (bulk admin endpoints; these users
# never sign anything), and identities must NOT linger in the global
# store: `icp network start` seeds every stored identity, and at ~150
# identities the CMC's 150,000T-cycles/hour mint cap aborts every fresh
# network start on this machine (see scripts/cleanup_identities.sh).
generate_phantom_principals() {
  local n="$1"
  local out="$2"
  > "$out"
  local i=0
  while [ "$i" -lt "$n" ]; do
    local name=$(printf "loadtrader_%04d" "$i")
    # Create identity silently; capture principal; delete immediately.
    icp identity new "$name" --storage plaintext 2>/dev/null || true
    local p=$(icp identity principal --identity "$name" 2>/dev/null)
    if [ -n "$p" ]; then echo "$p" >> "$out"; fi
    echo "y" | icp identity delete "$name" >/dev/null 2>&1 || true
    i=$(( i + 1 ))
  done
}

# ── Wait for any previous icp calls to settle ────────────────────
# Sanity-ping the backend; aborts early if the replica isn't responding.
if ! icp canister call backend getMarkets '()' --identity anonymous > /dev/null 2>&1; then
  # Maybe ensureInit hasn't run yet; try an update call to trigger it.
  alice=$(ensure_identity alice)
  if ! call resetExchange --identity alice > /dev/null 2>&1; then
    err "backend not responding; is the replica running and deployed?"
    exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# MODE: empty
# ═══════════════════════════════════════════════════════════════════
seed_empty() {
  log "mode=empty — clean slate (reset + market init only)"
  local alice
  alice=$(ensure_identity alice)
  # `empty` MUST reset. Tests rely on this mode to start from a known-
  # zero vault/orderbook/oracle state. A previous version of this
  # function only touched setTestBalance, leaving prior state intact —
  # which silently broke test_vault_lp's LP-anchor assertions.
  reset_exchange
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 0.0))" --identity alice > /dev/null
  ok "markets initialized · reset complete"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: matching   (minimal matching-engine fixture)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   BTC-ICPUSD book:
#     asks: [ (67600, 1.0) @ ask_alice ]
#     bids: [ (67400, 1.0) @ bid_bob   ]
#   Neither order should cross. Alice has enough BTC to sell; Bob has
#   enough ICPUSD to buy. Tests can cross them with a fresh taker.
seed_matching() {
  log "mode=matching — 2 traders, one known book on BTC-ICPUSD"
  local alice bob
  alice=$(ensure_identity alice)
  bob=$(ensure_identity bob)
  reset_exchange
  call setTestBalance "(principal \"$alice\", \"BTC\",    $(e8 10.0))"      --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 1000000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",   \"BTC\",    $(e8 10.0))"      --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",   \"ICPUSD\", $(e8 1000000.0))" --identity alice > /dev/null
  call placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 67600.0), $(e8 1.0))" --identity alice > /dev/null
  call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy  }, $(e8 67400.0), $(e8 1.0))" --identity bob   > /dev/null
  ok "alice: ask 1.0 BTC @ 67600 · bob: bid 1.0 BTC @ 67400"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: amm   (AMM pool + oracle, no extra traders)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   AMM pool on BTC-ICPUSD, enabled, seeded with 2 BTC + 150000 ICPUSD,
#   refPrice set to 75000 (stable, no external outcall needed). Pool
#   has NOT been requoted yet — tests that want live quotes must call
#   requoteAmm explicitly to observe deterministic placement.
seed_amm() {
  log "mode=amm — AMM pool on BTC-ICPUSD, refPrice=75000"
  local alice
  alice=$(ensure_identity alice)
  reset_exchange
  call setTestBalance "(principal \"$alice\", \"BTC\",    $(e8 50.0))"       --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 10000000.0))" --identity alice > /dev/null
  must_ok "createAmmPool BTC-ICPUSD"  createAmmPool '("BTC-ICPUSD")' --identity alice
  must_ok "setAmmRefPrice BTC-ICPUSD" setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 75000.0))" --identity alice
  must_ok "seedAmmPool BTC-ICPUSD"    seedAmmPool "(\"BTC-ICPUSD\", $(e8 2.0), $(e8 150000.0))" --identity alice
  must_ok "enableAmm BTC-ICPUSD"      enableAmm '("BTC-ICPUSD", true)' --identity alice
  assert_vault_seeded BTC
  ok "pool seeded: 2 BTC + 150,000 ICPUSD · refPrice 75000 · enabled"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: staged   (one BUY staged, a counterparty funded)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   alice has placed a placeLimitOrder BUY on BTC-ICPUSD at 75000.0 for
#   1.0 BTC (sealed: it STAGES and releases on the next GEPTOR / the
#   users-only expiry release — no AMM pool here); bob has BTC to sell.
#   The staged-order fixture the settlement, cancel/refund, zombie and
#   GEPTOR-inflight suites build on. (Was `pending`: it placed the same
#   order through placeProtectedLimitOrder with a window; that machinery
#   is retired — task 1788516198 — and placeProtectedLimitOrder is now an
#   inert alias, so the fixture names what it actually is.)
seed_staged() {
  log "mode=staged — alice stages a BUY, bob ready to cross"
  local alice bob
  alice=$(ensure_identity alice)
  bob=$(ensure_identity bob)
  reset_exchange
  call setTestBalance "(principal \"$alice\", \"ICPUSD\", $(e8 1000000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",   \"BTC\",    $(e8 5.0))"       --identity alice > /dev/null
  call placeLimitOrder "(\"BTC-ICPUSD\", variant { buy }, $(e8 75000.0), $(e8 1.0))" --identity alice > /dev/null
  ok "alice: BUY 1.0 BTC @ 75000 staged (sealed) · bob: 5 BTC loaded"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: load   (N phantom principals, sparse book, no AMM)
# ═══════════════════════════════════════════════════════════════════
# Post-condition:
#   $TRADERS phantom principals each have 1,000,000 ICPUSD + 10 BTC +
#   100 ETH + 5000 ICP. No open orders, no AMM. Ready for a benchmark
#   script to pound on placeLimitOrder / placeMarketOrder concurrently.
seed_load() {
  # NB: when invoked from seed_full we don't want to reset — the
  # caller has already set up a bunch of state (AMM pools, history,
  # orders). Set SKIP_RESET=true to bypass the reset.
  : "${SKIP_RESET:=false}"
  log "mode=load — generating $TRADERS trader principals"
  local alice
  alice=$(ensure_identity alice)
  if [ "$SKIP_RESET" != "true" ]; then
    reset_exchange
  fi

  # Principals are derived from create-read-delete throwaway identities
  # (the bulk endpoint expects Principal values, not text). Each run
  # gets FRESH principals — fine, because load mode resets the exchange
  # and re-funds them; nothing references the previous run's principals.
  local tmpfile="$MDX_RUN_DIR/loadtrader-principals.txt"
  generate_phantom_principals "$TRADERS" "$tmpfile"
  local count
  count=$(wc -l < "$tmpfile" | tr -d ' ')
  ok "$count principals ready"

  # Build a batched bulkSetTestBalances argument. Candid vecs on the
  # CLI are verbose, so we chunk into 50 accounts per call — below the
  # argument-size limit, and each call settles in well under a second.
  # The record LABEL is spelled "principal" (quoted): `principal` is a
  # Candid textual-syntax keyword and icp's parser rejects the bare form
  # ("Unrecognized token `Equals` … Expected one of \"text\""), which is
  # how every padded trader went unfunded for the script's whole life
  # (task 1788536324; candid/backend.did spells it quoted too). bulk_fund
  # reads each reply and aborts unless it counts entries × 4 rows.
  log "bulk-loading balances (50 per call)"
  local batch=""
  local n=0
  local batches=0
  local rows=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    batch+="record { \"principal\" = principal \"$p\"; balances = vec {"
    batch+="record { token = \"ICPUSD\"; amount = 100000000000000 };"
    batch+="record { token = \"BTC\";    amount = 1000000000 };"
    batch+="record { token = \"ETH\";    amount = 10000000000 };"
    batch+="record { token = \"ICP\";    amount = 500000000000 };"
    batch+="}};"
    n=$(( n + 1 ))
    if [ "$n" -ge 50 ]; then
      bulk_fund "$batch" "$n"
      rows=$(( rows + n * 4 ))
      batches=$(( batches + 1 ))
      batch=""; n=0
    fi
  done < "$tmpfile"
  if [ -n "$batch" ]; then
    bulk_fund "$batch" "$n"
    rows=$(( rows + n * 4 ))
    batches=$(( batches + 1 ))
  fi
  [ "$rows" -eq $(( count * 4 )) ] || seed_fail "padding wrote $rows balance rows for $count principals (expected $(( count * 4 )))" "rows=$rows batches=$batches"
  ok "balances seeded: $rows balance rows ($count principals × 4 tokens) across $batches batched calls, every reply counted"
}

# ═══════════════════════════════════════════════════════════════════
# MODE: full   (production-like — delegates to the legacy seed script
#               then adds AMM + oracle + historical trades)
# ═══════════════════════════════════════════════════════════════════
# ─────────────────────────────────────────────────────────────────
# Helper: seed a rich order book centred on `mid` for one market.
# Replaces the old hardcoded-price seed_exchange.sh. Prices are
# expressed as percentage offsets from mid so the distribution
# rebuilds correctly at whatever the current oracle price is.
# ─────────────────────────────────────────────────────────────────
seed_book_around() {
  local market="$1" base_token="$2" mid="$3"
  local alice bob charlie dave eve
  alice=$(ensure_identity alice); bob=$(ensure_identity bob)
  charlie=$(ensure_identity charlie); dave=$(ensure_identity dave)
  eve=$(ensure_identity eve)

  # Per-asset "small order" unit. Multipliers in the order spec below
  # scale this up — a multiplier of 20 on BTC = 0.2 BTC, on ETH = 4 ETH,
  # on ICP = 1000 ICP. Rough goal: $500-$1000 at the tight end, $5-20k at
  # the widest ends, so the book has visible structure at both scales.
  local unit
  case "$base_token" in
    BTC) unit=0.01 ;;
    ETH) unit=0.2  ;;
    SOL) unit=1.0  ;;
    ICP) unit=50   ;;
    *)   unit=1.0  ;;
  esac

  # Precompute every (identity, side, price, qty) tuple in one Python
  # call — spawning 80 subshells for individual round() calls is
  # pointlessly slow on the critical path.
  local lines
  lines=$(python3 - "$mid" "$unit" <<'PY'
import sys
mid = float(sys.argv[1]); unit = float(sys.argv[2])
# (identity, side, offset-%-from-mid, qty-multiplier).
# Structured like the original seed: 5 trader personas with distinct
# styles (tight scalper, mid-range, deep maker, wide-range).
specs = [
    # dave — tight scalper, just off the inside
    ('dave',    'sell',   0.02,  1),
    ('dave',    'sell',   0.05,  1.5),
    ('dave',    'sell',   0.08,  2),
    ('dave',    'buy',   -0.02,  1),
    ('dave',    'buy',   -0.05,  1.5),
    ('dave',    'buy',   -0.08,  2),
    # charlie — near-spot retail
    ('charlie', 'sell',   0.15,  3),
    ('charlie', 'sell',   0.35,  5),
    ('charlie', 'sell',   0.60,  8),
    ('charlie', 'buy',   -0.15,  3),
    ('charlie', 'buy',   -0.35,  5),
    ('charlie', 'buy',   -0.60,  8),
    # bob — medium swing trader
    ('bob',     'sell',   0.25,  6),
    ('bob',     'sell',   0.55,  10),
    ('bob',     'sell',   1.00,  15),
    ('bob',     'sell',   1.75,  20),
    ('bob',     'buy',   -0.25,  6),
    ('bob',     'buy',   -0.55,  10),
    ('bob',     'buy',   -1.00,  15),
    ('bob',     'buy',   -1.75,  20),
    # alice — deep maker, 6 layers each side
    ('alice',   'sell',   0.10,  10),
    ('alice',   'sell',   0.50,  20),
    ('alice',   'sell',   1.50,  30),
    ('alice',   'sell',   3.00,  40),
    ('alice',   'sell',   5.00,  50),
    ('alice',   'sell',   8.00,  80),
    ('alice',   'buy',   -0.10,  10),
    ('alice',   'buy',   -0.50,  20),
    ('alice',   'buy',   -1.50,  30),
    ('alice',   'buy',   -3.00,  40),
    ('alice',   'buy',   -5.00,  50),
    ('alice',   'buy',   -8.00,  80),
    # eve — wide-range arb
    ('eve',     'sell',   2.50,  15),
    ('eve',     'sell',   6.00,  30),
    ('eve',     'sell',  12.00,  60),
    ('eve',     'buy',   -2.50,  15),
    ('eve',     'buy',   -6.00,  30),
    ('eve',     'buy',  -12.00,  60),
]
for ident, side, off, mult in specs:
    px = round(mid * (1 + off/100), 4)
    qty = round(unit * mult, 4)
    # Tiny ICP prices can underflow to 0.00 at 4 decimals — nudge.
    if px <= 0:
        continue
    print(f"{ident}\t{side}\t{int(round(px*1e8))}\t{int(round(qty*1e8))}")
PY
  )

  local n=0
  while IFS=$'\t' read -r trader side px qty; do
    [ -z "$trader" ] && continue
    call placeLimitOrder "(\"$market\", variant { $side }, $px, $qty)" \
      --identity "$trader" > /dev/null
    n=$(( n + 1 ))
  done <<< "$lines"
  ok "$market — $n orders placed around mid $mid"
}

seed_full() {
  log "mode=full — oracle history first → book at oracle prices → AMM"

  # Step 1: reset + create named trader identities and fund them. We
  # do this BEFORE any history/book work so (a) trades exist for a
  # real Principal (used by historical injection to attribute to the
  # AMM principal — doesn't matter who alice is at that moment, but
  # ensureInit must have run so markets are in the map), and (b)
  # traders have balances ready when we place their orders.
  local alice bob charlie dave eve
  alice=$(ensure_identity alice); bob=$(ensure_identity bob)
  charlie=$(ensure_identity charlie); dave=$(ensure_identity dave)
  eve=$(ensure_identity eve)

  # Step 0: snapshot the LIVE marks before the reset below clears them.
  # A standalone `seed.sh full --history-days 0` used to stamp the four AMM
  # marks at the hardcoded fallbacks below (BTC 75000 ...) while the venue's
  # real feed sat at ~81k: the first post-seed tick (≤30s) pended every leg
  # (PRICE_JUMP_BPS 250), the pends confirmed only two ticks later, and for
  # that whole ~65-95s window vaultPricesStale refused EVERY LP mint on the
  # venue ("awaiting circuit-breaker confirmation") — task 3088500128,
  # measured 2026-09-04. Marks taken from the live aggregate sit within the
  # breaker band of the next tick, so no pend is created. Read here, not in
  # step 4: resetExchange (next) clears lastAggregates and zeroes the feed
  # counters, and the timers are paused while the pools are seeded, so no
  # aggregate exists again until after the seed ends.
  # A cached aggregate is often MISSING or STALE here, and then the fallback
  # default lays the whole venue off the market: after a resetExchange there
  # are no pools, so tickPriceRefresh fetches nothing until the next seed
  # creates them; a fresh replica has never ticked; a fixture that paused the
  # timers left the cache aging. Observed 2026-09-04 (task 3088527364): a
  # `full` seed on a just-reset venue stamped ETH at the $3500 default while
  # the feed sat at ~$2450 — the first post-unpause tick pended the -30% jump
  # and confirmed it ~30s later, so the MARK moved to $2450 while the maker
  # ladder seed_book_around had rested at $3500 stayed put, and every ETH buy
  # capped off the mid (mark × 1.10) reached nothing (test_swap route 3,
  # "swapper ETH balance grew: got 20.0"). So fetch on demand: for an asset
  # with no cached aggregate, or one older than the venue's own
  # maxRefPriceAgeSec (MDX_SEED_MARK_MAX_AGE_SEC, default 300), fire ONE
  # fetchAndSetRefPrice(<asset>-ICPUSD) — the controller hook whose
  # refreshMultiSourcePrice writes lastAggregates BEFORE the accept gate, so
  # it caches the live mark even on a pool-less venue (the apply step then
  # answers "No AMM pool", which is fine: the reset below wipes the pools
  # anyway) — and re-read. Ladder and marks both come off the same value, so
  # the book rests where the feed's next tick will confirm, inside the
  # breaker band. The fetch's reply is deliberately not asserted: a venue
  # with no reachable source answers a refusal (or a zero-priced aggregate
  # the reader below discards), and THAT is the one case that still falls
  # back to the defaults — where nothing will ever move the mark off them.
  local live_BTC live_ETH live_SOL live_ICP live_age_BTC live_age_ETH live_age_SOL live_age_ICP
  local live_how_BTC live_how_ETH live_how_SOL live_how_ICP
  local feed_stats a m px age fetched=""
  local mark_max_age="${MDX_SEED_MARK_MAX_AGE_SEC:-300}"
  feed_stats=$(call getPriceFeedStats "()" --query --identity anonymous | tr -d '\n' \
    | grep -oE '(successCount|suspendedCount) = [0-9]+' | tr '\n' ' ')
  for a in BTC ETH SOL ICP; do
    m=$(live_aggregate_mark "$a")
    read -r px age <<< "$m"
    printf -v "live_how_$a" '%s' ""
    if [ -z "$px" ] || [ "${age:-0}" -gt "$mark_max_age" ]; then
      call fetchAndSetRefPrice "(\"$a-ICPUSD\")" --identity alice > /dev/null 2>&1 || true
      m=$(live_aggregate_mark "$a")
      read -r px age <<< "$m"
      if [ -n "$px" ]; then fetched="$fetched $a"; printf -v "live_how_$a" '%s' "fetched"; fi
    fi
    printf -v "live_$a" '%s' "$px"
    printf -v "live_age_$a" '%s' "$age"
  done
  if [ -n "$live_BTC$live_ETH$live_SOL$live_ICP" ]; then
    ok "live aggregate marks snapshotted before reset (feed: ${feed_stats:-no stats}; fetched on demand:${fetched:- none})"
  else
    warn "no live aggregate on this venue and the on-demand fetch cached none (feed: ${feed_stats:-no stats}) — marks fall back to history/defaults"
  fi

  reset_exchange
  log "funding named traders"
  # Balances generous enough that the biggest order spec (80×unit for
  # alice at mid × (1+8%)) still fits with room to spare across all
  # three markets, and traders can then act as takers during sim.
  # Alice carries the AMM seed inventory across all 3 pools — at the
  # bumped tvl_target of $500k per pool that's $1.5M ICPUSD, ~10 BTC
  # equivalent, ~200 ETH equivalent, ~200k ICP equivalent. Sized
  # generously so she still has headroom to be a normal market maker
  # after the AMM is funded.
  call setTestBalance "(principal \"$alice\",   \"ICPUSD\", $(e8 5000000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"BTC\",       $(e8 200.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"ETH\",      $(e8 5000.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"SOL\",     $(e8 50000.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$alice\",   \"ICP\",   $(e8 1000000.0))"   --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"ICPUSD\",  $(e8 500000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"BTC\",        $(e8 10.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"ETH\",       $(e8 200.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"SOL\",      $(e8 2000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$bob\",     \"ICP\",     $(e8 20000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"ICPUSD\",  $(e8 100000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"BTC\",         $(e8 3.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"ETH\",        $(e8 80.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"SOL\",       $(e8 500.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$charlie\", \"ICP\",      $(e8 5000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"ICPUSD\",   $(e8 50000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"BTC\",         $(e8 1.5))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"ETH\",        $(e8 40.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"SOL\",       $(e8 200.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$dave\",    \"ICP\",      $(e8 2000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"ICPUSD\",  $(e8 250000.0))" --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"BTC\",         $(e8 8.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"ETH\",       $(e8 300.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"SOL\",      $(e8 3000.0))"  --identity alice > /dev/null
  call setTestBalance "(principal \"$eve\",     \"ICP\",     $(e8 50000.0))"  --identity alice > /dev/null
  ok "5 traders funded"

  # Step 2: fetch oracle prices + historical candles. Writes
  # $MDX_ORACLE_PRICES which steps 3 & 4 read.
  local oracle_file="$MDX_ORACLE_PRICES"
  rm -f "$oracle_file"
  if [ "$HISTORY_DAYS" -gt 0 ]; then
    log "injecting $HISTORY_DAYS days of oracle-derived price history"
    if ! bash "$SCRIPT_DIR/inject_history.sh" --days "$HISTORY_DAYS"; then
      warn "history injection had failures — missing assets fall back to sensible defaults"
    fi
  else
    ok "history injection skipped (--history-days 0)"
  fi

  # Mark precedence, per asset — prints "<price> <source>":
  #   1. the history snapshot inject_history wrote to $MDX_ORACLE_PRICES
  #      (--history-days N>0): the candles and the book are anchored at
  #      THOSE prices, so the AMM must open where the injected tape ends;
  #   2. the live aggregate snapshotted in step 0 — cached, or fetched on
  #      demand there when the cache was empty/stale (the feed's own mark,
  #      so the next tick lands inside the breaker band — see step 0);
  #   3. the hardcoded fallback — only a venue with no reachable price
  #      source gets here (the on-demand fetch cached nothing usable).
  oracle_price() {
    local asset="$1" fallback="$2" p live age how
    if [ -f "$oracle_file" ]; then
      p=$(awk -v a="$asset" '$1 == a { print $2; exit }' "$oracle_file")
      if [ -n "$p" ]; then echo "$p history-snapshot"; return; fi
    fi
    live="live_$asset"; live="${!live}"
    age="live_age_$asset"; age="${!age}"
    how="live_how_$asset"; how="${!how}"
    if [ -n "$live" ]; then echo "$live live-aggregate(${how:+$how,}${age}s-old)"; return; fi
    echo "$fallback fallback-default"
  }

  local btc_px eth_px sol_px icp_px btc_src eth_src sol_src icp_src
  read -r btc_px btc_src <<< "$(oracle_price BTC 75000)"
  read -r eth_px eth_src <<< "$(oracle_price ETH 3500)"
  read -r sol_px sol_src <<< "$(oracle_price SOL 200)"
  read -r icp_px icp_src <<< "$(oracle_price ICP 2.5)"
  ok "mark sources — BTC $btc_px ← $btc_src · ETH $eth_px ← $eth_src · SOL $sol_px ← $sol_src · ICP $icp_px ← $icp_src"

  # Step 3: seed the order book around the current oracle prices.
  log "book seeding at oracle prices (BTC $btc_px · ETH $eth_px · SOL $sol_px · ICP $icp_px)"
  seed_book_around BTC-ICPUSD BTC "$btc_px"
  seed_book_around ETH-ICPUSD ETH "$eth_px"
  seed_book_around SOL-ICPUSD SOL "$sol_px"
  seed_book_around ICP-ICPUSD ICP "$icp_px"

  # Step 4: AMM pools — refPrice already right, pool sized for
  # robustness against simulator flow. After deploy, the price-feed
  # heartbeat takes over refreshing refPrice via non-replicated outcalls —
  # every ~60s PER POOL (a 30s beat whose 45s stale gate quantises each
  # pool to two beats; measured, task 1788503312).
  #
  # tvl_target sizing: each pool needs `numLevels × quoteDepthBase`
  # of base inventory for the ask ladder AND the same value in
  # ICPUSD for the bid ladder. With 5 levels × 0.5 BTC = 2.5 BTC and
  # BTC at ~$78k that's ~$195k per side, so $500k pool gives
  # 2.5×-coverage on each side — enough headroom for the simulator
  # to flow significantly into the pool before depleting it.
  log "AMM pools"
  # Pause timers while seeding: the oracle would otherwise see the manual seed
  # refPrice as a >2.5% jump vs the live market, pend it (circuit breaker), and
  # the LP-deposit freshness gate would then block later pool seeds (it refuses
  # to mint while a HELD asset's price is frozen). Unpaused right after seeding.
  must_unit "setTestTimersPaused(true)" setTestTimersPaused "(true)" --identity alice
  SEED_TIMERS_PAUSED=true
  local tvl_target=500000
  for triplet in \
    "BTC-ICPUSD $btc_px" \
    "ETH-ICPUSD $eth_px" \
    "SOL-ICPUSD $sol_px" \
    "ICP-ICPUSD $icp_px"
  do
    local market price
    read -r market price <<< "$triplet"
    local base_amt quote_amt
    base_amt=$(python3 -c "print(round($tvl_target / $price / 2, 4))")
    quote_amt=$(python3 -c "print($tvl_target / 2)")
    must_ok "createAmmPool $market" createAmmPool "(\"$market\")" --identity alice
    # Inventory target + per-quote depth are NOT set here — auto-inventory
    # (enabled below) derives both from the live vault every requote: equal USD
    # per asset at 50% assets / 50% cash, with the ladder showing a fixed
    # fraction of that target per side. So every market quotes the same fraction
    # of reserves regardless of price. The $1.0 depth is just a placeholder until
    # the first requote derives the real value (decimal point required — the icp
    # CLI parses a bare "1" as Int and rejects the Float arg with no candid file).
    # spread 20bps · 15 levels · 35bps spacing → a ~5% quoted band each side.
    must_ok "setAmmConfig $market"   setAmmConfig "(\"$market\", 20:nat, $(e8 1.0):nat, 15:nat, 35:nat)" --identity alice
    must_ok "setAmmRefPrice $market" setAmmRefPrice "(\"$market\", $(e8 $price))" --identity alice
    # The vault deposit itself — the step the 2026-09-04 hollow seed lost
    # (refused "at its vault concentration cap" over a surviving vault).
    must_ok "seedAmmPool $market"    seedAmmPool "(\"$market\", $(e8 $base_amt), $(e8 $quote_amt))" --identity alice
    # Phase 4 skew INTENSITY (200bps) — the target it leans toward is derived by
    # auto-inventory, not this seeded base amount. When holdings drift off the
    # derived target the AMM shifts its whole ladder in the opposite direction
    # (bidding less when long, asking less when short); that feedback loop, plus
    # the rebalancer, pulls the vault back toward the equal-weight allocation.
    must_ok "setAmmSkewConfig $market" setAmmSkewConfig "(\"$market\", $(e8 $base_amt), 200:nat)" --identity alice
    must_ok "enableAmm $market"        enableAmm "(\"$market\", true)" --identity alice
    ok "$market enabled · $base_amt base + $quote_amt ICPUSD · refPrice $price · skew 200bps"
  done
  # The post-condition the comment block above promises: LP supply minted
  # and all four base legs in the basket — asserted, not assumed.
  assert_vault_seeded BTC ETH SOL ICP

  # Auto-inventory: from now on each pool derives its target + quoted depth from
  # the live vault (equal USD per asset, 50/50 assets/cash). The vault was seeded
  # at that allocation above, so it starts on-target; any drift self-corrects.
  must_unit "setAmmAutoInventory(true)" setAmmAutoInventory "(true)" --identity alice
  ok "auto-inventory enabled — AMM targets equal-weight 50/50, depth derived from vault"
  # Resume timers — the oracle now refreshes the seed prices toward live market
  # (a confirmed >2.5% gap applies after two readings; cold_start waits for it).
  must_unit "setTestTimersPaused(false)" setTestTimersPaused "(false)" --identity alice
  SEED_TIMERS_PAUSED=false
  # Re-stamp every mark AFTER the timers resume. Seeding four pools takes long
  # enough that the FIRST pool's refPriceUpdatedNs is ~30-40s old by now,
  # against LP_DEPOSIT_MAX_REF_AGE_NS = 60s, and the first post-unpause feed
  # tick lands ~45-50s after the unpause (the 30s HB_PRICE_NS beat whose 45s
  # stale gate makes the steady-state per-pool cadence 60s — task 1788503312 —
  # plus outcall latency) — measured 2026-09-04 (task 3088500128): a standalone seed
  # answered "LP deposit paused: BTC refPrice is stale" from +31s after the
  # seed until that tick, and stamps taken BEFORE the unpause still left a
  # ~7s stale gap (their own ~15s of call latency ate the margin). Stamping
  # after the unpause starts the 60s grace as late as possible, ~20s past the
  # expected tick. Same prices, so the vault's marks do not move; a tick that
  # races a stamp is harmless either way (both write the live mark, and a
  # direct set supersedes any pend). setAmmRefPrice is a #dev hook, which this
  # whole fixture already requires (posture guard above).
  for triplet in \
    "BTC-ICPUSD $btc_px" \
    "ETH-ICPUSD $eth_px" \
    "SOL-ICPUSD $sol_px" \
    "ICP-ICPUSD $icp_px"
  do
    local market price
    read -r market price <<< "$triplet"
    must_ok "setAmmRefPrice $market (re-stamp)" setAmmRefPrice "(\"$market\", $(e8 $price))" --identity alice
  done
  ok "marks re-stamped after unpause (fresh refPriceUpdatedNs for the 60s LP-deposit staleness grace)"
  # ...and wait, bounded, for that first tick to land — measured at +45..70s
  # after the unpause, so the 60s grace alone still left a ~10s "refPrice is
  # stale" gap. The wait ends the moment EVERY pool's refPriceUpdatedNs has
  # moved past the stamps (only a feed tick can do that), which is exactly
  # the freshness vaultPricesStale checks; it is skipped when the marks came
  # from the fallback defaults (no feed has ever ticked here — nothing to
  # wait for) and on the timeout it warns and proceeds: a mint then meets the
  # gate's own refusal, not a hang. MDX_SEED_FEED_WAIT_SEC caps it (default
  # 90; 0 disables). cold_start.sh's AMM-oracle-health phase is condition-
  # driven on successCount, so it adds ~0s once this wait has seen the tick.
  local wait_max="${MDX_SEED_FEED_WAIT_SEC:-90}" t_stamped waited=0 fresh=0
  t_stamped=$(date +%s)
  case "$btc_src$eth_src$sol_src$icp_src" in
    *live-aggregate*|*history-snapshot*) ;;
    *) wait_max=0; ok "no live feed on this venue — skipping the first-tick wait" ;;
  esac
  while [ "$wait_max" -gt 0 ]; do
    fresh=$(call getAmmPools "()" --query --identity anonymous | tr -d '\n_' \
      | grep -oE 'refPriceUpdatedNs = [0-9]+' \
      | awk -v t="$t_stamped" '{ if ($3 + 0 > t * 1000000000) n++ } END { print n + 0 }')
    waited=$(( $(date +%s) - t_stamped ))
    if [ "$fresh" -ge 4 ]; then
      ok "first post-unpause feed tick refreshed all 4 marks after ${waited}s — LP mints are unblocked"
      break
    fi
    if [ "$waited" -ge "$wait_max" ]; then
      warn "feed refreshed only $fresh/4 marks within ${wait_max}s — LP mints on the stale legs refuse until it does"
      break
    fi
    sleep 3
  done

  # Step 5: pad with load-test trader principals.
  if [ "$TRADERS" -gt 5 ]; then
    log "padding to $TRADERS trader principals"
    SKIP_RESET=true seed_load
  fi
}

# ── Dispatch ─────────────────────────────────────────────────────
case "$MODE" in
  full)     seed_full     ;;
  empty)    seed_empty    ;;
  matching) seed_matching ;;
  amm)      seed_amm      ;;
  staged)   seed_staged   ;;
  load)     seed_load     ;;
  *) err "unknown mode: $MODE"; exit 1 ;;
esac

echo ""
echo -e "${GREEN}Seed '$MODE' complete.${NC}"
