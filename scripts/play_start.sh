#!/usr/bin/env bash
#
# MULTI/DEX — start the LOCAL exchange in #play mode with play-appropriate seeding.
#
# What "play" means (docs/deployment-modes.md): players sign on with NOTHING
# and on-ramp only via capped Bridge deposits ($100,000 lifetime, mark-valued);
# the self-serve faucet and the setAmmRefPrice/setTest* behavior overrides are
# dead; prices come from the real multi-source feed. So this script seeds ONLY
# through the surface that stays alive on #play:
#   - setTestBalance          controller-only operator funding (bots, ladder
#                             makers, the AMM LP) — recorded in extNetFlow so
#                             the profit leaderboard stays honest
#   - injectHistoricalTrades  chart backdrop (via inject_history.sh) —
#                             GENESIS-GATED on #play: the canister accepts it
#                             only until the venue's first enableAmm, #err
#                             after (one-way; reinstall re-arms, season resets
#                             do not). Works here because step 4 (history)
#                             runs on the fresh reinstall, before step 5's
#                             enableAmm. See docs/deployment-modes.md.
#   - createAmmPool / setAmmConfig / seedAmmPool / setAmmSkewConfig /
#     enableAmm / setAmmAutoInventory   controller AMM lifecycle
#   - fetchAndSetRefPrice     REAL prices; setAmmRefPrice returns #err on #play
#
# This is the repo's DEFAULT seeding path: scripts/cold_start.sh (default
# mode `play`) ensures the network + canisters + cycles exist, then runs
# this script — you rarely need to call it directly.
#
# Contract: the local network is up and healthy and the canisters exist
# (run scripts/cold_start.sh once first if not). This script then:
#   1. verifies src/backend/main.mo says DEPLOY_MODE = #play, builds, and
#      REINSTALLS backend + bridge — fresh play state; ALL dev data is wiped
#   2. wiring: Bridge ↔ DEX auto-wire from the PUBLIC_CANISTER_ID:* env vars
#      icp injects on every deploy (setBridge/setDex stay break-glass — this
#      script does NOT call them), sets the fuel-mock route, and UNWIRES XRC:
#      play keeps XRC unwired by design, and locally the xrc-mock's canned
#      prices would diverge from the live feed and trip the oracle banner
#   3. seeds: price history, a $5.125M AMM ($1,281,250/market, half base half
#      ICPUSD — production-launch scale), a small non-crossing maker ladder so
#      the book isn't empty, and a $144k insurance fund (INSURANCE_USD overrides)
#   4. relaunches trading_simulation.sh (strategy bots — half margin, half
#      spot; spot bots hold $100k VALUE, parity with the players' deposit
#      allowance, margin bots additionally fund a pool) and redeploys the
#      frontend
#
# Usage: bash scripts/play_start.sh
# Env:   HISTORY_DAYS (default 9, 0 skips)  AMM_TVL_TOTAL (default 5125000)
#        INSURANCE_USD (default 144000)  ARB_USD (default 1281250)
#        MDX_NO_SIMULATE=1  skip step 7's fleet START (a recorded local fleet
#                           is still STOPPED first). cold_start.sh exports it
#                           for an explicit --no-simulate in play mode, so a
#                           factory seat can run the canonical #play bring-up
#                           without a bot fleet (task 1788479256).
#        MDX_PLAY_MIN_SEEDED  how many of the $MARKETS must come up with a
#                           seeded, enabled vault before step 5 counts as
#                           done (default: ALL of them). Below it the script
#                           dies — the demo venue never silently comes up
#                           with one pool (task 1788502351).

set -uo pipefail
cd "$(dirname "$0")/.."

# Scratch-file locations (.run/, not fixed names under sticky /tmp) — see
# scripts/lib/runfiles.sh. Exported, so inject_history.sh lands on the same
# price-snapshot path this script then reads back.
# shellcheck source=scripts/lib/runfiles.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/runfiles.sh"
# Target table + the shared posture reader (mdx_posture_of) — see W1-02.
# shellcheck source=scripts/lib/targets.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"
# The Candid reply predicates (mdx_reply_ok / mdx_reply_unit / mdx_reply_nat /
# mdx_one_line / mdx_vault_nat) — ONE copy shared with seed.sh and deploy.sh
# (task 1788503030); the doctrine lives in the lib's header.
# shellcheck source=scripts/lib/reply.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/reply.sh"
export PATH="$HOME/.local/bin:$PATH"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}▶${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
die()  { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
hdr()  { echo -e "\n${YELLOW}═══ $1 ═══${NC}"; }

MARKETS="BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD"
TOKENS="ICPUSD BTC ETH SOL ICP"
TVL_TOTAL="${AMM_TVL_TOTAL:-5125000}"
HIST_DAYS="${HISTORY_DAYS:-9}"
NMARKETS=$(echo $MARKETS | wc -w | tr -d ' ')
TVL=$(( TVL_TOTAL / NMARKETS ))          # per-market vault target (half base, half quote)
LADDER_MAKERS="mdex-play-mm-1 mdex-play-mm-2"

# Integer-money: ledger amounts go on the wire as Nat base units (10^8).
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

# Every backend call carries the checked-in Candid contract (`--candid`, icp
# 1.2.0): icp encodes arguments and decodes replies BY NAME from the file
# instead of fetching the canister's candid:service metadata per call — a
# fetch that missed transiently on 2026-09-04 (task 1788507289, seed.sh's
# twin of this block) and made icp spell a successful unit `#ok` by its field
# HASH, `(variant { 24_860 })`, so the name-only matcher aborted a half-seeded
# venue. A checkout without the file falls back to the fetch; mdx_reply_ok's
# hashed spelling then still carries the verdict.
PLAY_CANDID="$(cd "$(dirname "$0")" && pwd)/../candid/backend.did"
adm() {
  if [ -f "$PLAY_CANDID" ]; then icp canister call backend "$@" --candid "$PLAY_CANDID" --identity anonymous 2>&1
  else icp canister call backend "$@" --identity anonymous 2>&1; fi
}

# ── Reply oracles (task 1788502351; predicates in scripts/lib/reply.sh) ──
# A Candid REFUSAL — `variant { err = "..." }` — is a SUCCESSFUL call as far
# as icp is concerned (exit 0), and a controller trap ("Caller is not a
# canister controller") is a non-zero exit with the reject text on stdout —
# so `adm … > /dev/null || true` discarded both, and a refused
# createAmmPool / setAmmConfig / enableAmm printed "markets live" over a
# hollow venue. Every money-moving / lifecycle reply (step 3's operator
# funding, step 5's AMM lifecycle) now goes through must_ok / must_unit,
# which assert the reply SHAPE via the shared mdx_reply_ok / mdx_reply_unit
# (named or hash-spelled ok; err refused — scripts/lib/reply.sh) and die
# loudly with the reply text otherwise; the two wiring calls in step 2 warn
# with the reply. Same helper names and semantics as seed.sh, so the two
# seeding paths read alike.
call() {   # call <method> <args> … --identity <name>  (the pin is mandatory: mdex-process-safety §5)
  case " $* " in
    *" --identity "*) ;;
    *) echo -e "  ${RED}✗${NC} call() without --identity (mdex-process-safety §5): $*" >&2; return 1 ;;
  esac
  if [ -f "$PLAY_CANDID" ]; then
    echo "y" | icp canister call backend "$@" --candid "$PLAY_CANDID" 2>&1
  else
    echo "y" | icp canister call backend "$@" 2>&1
  fi
}

# seed_fail <what> <reply> — the loud exit. Resumes the timers if step 5 had
# paused them, so an aborted bring-up does not strand a paused venue.
TIMERS_PAUSED=false
seed_fail() {
  echo -e "  ${RED}✗${NC} $1: $(mdx_one_line "$2")" >&2
  if [ "$TIMERS_PAUSED" = "true" ]; then
    call setTestTimersPaused "(false)" --identity anonymous > /dev/null 2>&1 || true
    TIMERS_PAUSED=false
  fi
  die "play bring-up ABORTED — the venue is NOT seeded (see the ✗ line above)"
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
must_unit() {
  local label="$1"; shift
  local out rc
  out=$(call "$@"); rc=$?
  if [ "$rc" -ne 0 ] || ! mdx_reply_unit "$out"; then
    seed_fail "$label failed (rc=$rc)" "$out"
  fi
}
# vault_value — getVaultValue as one whitespace-normalized line.
vault_value() {
  echo "y" | icp canister call backend getVaultValue '()' --query --identity anonymous 2>&1 \
    | tr -s '[:space:]' ' '
}
# assert_vault_seeded <base tokens...> — the post-condition the AMM seed
# promises: LP supply minted AND every seeded pool's base leg present in the
# basket. A refused deposit that somehow slipped past the per-market gate
# shows up here as lpSupply 0 / an empty leg.
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

# ── 0. Preflight ──────────────────────────────────────────────────
hdr "Preflight"

# mdx_posture_of (lib/targets.sh) — comment-aware, refuses ambiguity. The
# old `grep -q` here matched the #play literal INSIDE a comment, so a
# commented copy of the declaration passed the gate over a real #dev.
SRC_POSTURE=$(mdx_posture_of src/backend/main.mo || true)
[ "$SRC_POSTURE" = "play" ] \
  || die "src/backend/main.mo must resolve to #play (got '${SRC_POSTURE:-unresolved — see above}') — set: transient let DEPLOY_MODE : DeployMode = #play;"
ok "source posture is #play"

# Gateway resolved from the CLI's own record (mdx_local_gateway, W1-06) —
# 8000 on the canonical checkout, a random port under the worktree-parallel
# workflow. The old hardwired :8000 probe refused to run from a worktree.
GW=$(mdx_local_gateway || true); GW_PORT=${GW##* }
{ [ -n "$GW" ] && curl -s --max-time 2 "http://127.0.0.1:$GW_PORT/api/v2/status" > /dev/null 2>&1; } \
  || die "local network is not answering — run scripts/cold_start.sh first"
# Zombie-master check (same signature cold_start heals): a second pocket-ic
# master leaves the gateway answering while inter-canister calls + outcalls
# fail — and this script NEEDS outcalls (fetchAndSetRefPrice). Detection is
# mdx_stray_masters: repo-scoped by cwd (another project's healthy replica
# is not our zombie — the 2026-07-29 open-saas lesson), owner-scoped by the
# recorded gateway above.
for pid in $(mdx_stray_masters || true); do
  die "zombie pocket-ic master ($pid) for this repo — run scripts/cold_start.sh (it restarts the network cleanly), then rerun this"
done
ok "replica healthy (single master owns the gateway on :$GW_PORT)"

BACKEND_ID=$(icp canister status backend --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
BRIDGE_ID=$(icp canister status bridge  --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
[ -n "$BACKEND_ID" ] && [ -n "$BRIDGE_ID" ] || die "backend/bridge canisters not found — run scripts/cold_start.sh first"
ok "canisters present (backend=$BACKEND_ID bridge=$BRIDGE_ID)"

# ── 1. Build + reinstall (fresh play state) ───────────────────────
hdr "Build + reinstall"
# Candid freshness (W5-20, task 1788483105): mops.toml embeds
# src/backend/backend.did as PUBLIC candid:service metadata and gen-did.sh is
# its only writer, so a build here after an API edit would ship the previous
# interface. Same gate and wording as deploy.sh/cold_start.sh. The cwd is the
# repo root (the cd at the top), so the script path is stable.
log "regenerating candid interface (gen-did.sh) so the build ships what the source says"
bash scripts/gen-did.sh > /dev/null \
  || die "scripts/gen-did.sh failed — refusing to deploy a stale candid:service interface. Run it by hand to see why."
log "icp build (backend + bridge wasm)"
icp build > "$MDX_PLAY_BUILD_LOG" 2>&1 || die "build failed — see $MDX_PLAY_BUILD_LOG"
ok "built"

log "reinstalling backend (wipes ALL exchange state)"
icp canister install backend --mode reinstall -y --identity anonymous > /dev/null 2>&1 \
  || die "backend reinstall failed"
log "reinstalling bridge (wipes the stub's deposit ledgers)"
icp canister install bridge --mode reinstall -y --identity anonymous > /dev/null 2>&1 \
  || die "bridge reinstall failed"
ok "reinstalled"

MODE=$(adm getDeployMode "()" | grep -oE '"[a-z]+"' | tr -d '"')
[ "$MODE" = "play" ] || die "backend reports posture '$MODE', expected 'play' — stale build?"
ok "backend posture: play"

# ── 2. Wiring ─────────────────────────────────────────────────────
hdr "Wiring"
# Bridge ↔ DEX discover each other from the PUBLIC_CANISTER_ID:* env vars icp
# injects on every deploy (icp-cli pitfall 22); env vars are canister SETTINGS,
# so they survive the reinstalls above. setBridge/setDex stay as break-glass.
ok "Bridge ↔ DEX auto-wired via canister env vars"

FUEL_MOCK_ID=$(icp canister status fuel-mock --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
if [ -n "$FUEL_MOCK_ID" ]; then
  # Wiring, not money: setFuelRoute answers `()`, so anything else (a trap's
  # reject text, a CLI error) is a warn that NAMES the reply, not a die.
  fr_out=$(adm setFuelRoute "(opt principal \"$FUEL_MOCK_ID\", opt principal \"$FUEL_MOCK_ID\")"); fr_rc=$?
  icp canister top-up --amount 20t fuel-mock --identity anonymous > /dev/null 2>&1 || true
  if [ "$fr_rc" -eq 0 ] && mdx_reply_unit "$fr_out"; then
    ok "fuel route wired (fuel-mock as ledger+CMC, topped 20T)"
  else
    warn "setFuelRoute did not answer () (rc=$fr_rc) — auto-fuel Stage 2 may be unwired: $(mdx_one_line "$fr_out")"
  fi
else
  warn "fuel-mock not found — auto-fuel Stage 2 unwired"
fi

# Play posture: NO XRC fallback (mainnet-play would use none; locally the mock
# would fight the live feed). Explicit unwire in case a dev run left it set.
xrc_out=$(adm setXrcCanister "(null)"); xrc_rc=$?
if [ "$xrc_rc" -eq 0 ] && mdx_reply_unit "$xrc_out"; then
  ok "XRC unwired (play uses the multi-source feed only)"
else
  warn "setXrcCanister (null) did not answer () (rc=$xrc_rc) — a dev XRC wiring may survive: $(mdx_one_line "$xrc_out")"
fi

# Google (Gemini) assistant key — from GOOGLE_API_KEY env (legacy alias
# AI_API_KEY) or the git-ignored scripts/.google-api-key. Wiped by the
# reinstall above, so re-apply. Absent → assistant stays disabled.
GOOGLE_KEY="${GOOGLE_API_KEY:-${AI_API_KEY:-}}"
[ -z "$GOOGLE_KEY" ] && [ -f scripts/.google-api-key ] && GOOGLE_KEY="$(tr -d '[:space:]' < scripts/.google-api-key)"
if [ -n "$GOOGLE_KEY" ]; then
  adm setGoogleApiKey "(\"$GOOGLE_KEY\")" > /dev/null && ok "Google AI key wired" || warn "setGoogleApiKey failed"
else
  ok "Google AI key not wired (no GOOGLE_API_KEY / scripts/.google-api-key)"
fi
# Anthropic key — mirror (ANTHROPIC_API_KEY env or scripts/.anthropic-api-key).
# Injected LAST on purpose: backend uses whichever key was set last, so both
# present → assistant runs on Anthropic.
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
[ -z "$ANTHROPIC_KEY" ] && [ -f scripts/.anthropic-api-key ] && ANTHROPIC_KEY="$(tr -d '[:space:]' < scripts/.anthropic-api-key)"
if [ -n "$ANTHROPIC_KEY" ]; then
  adm setAnthropicApiKey "(\"$ANTHROPIC_KEY\")" > /dev/null && ok "Anthropic key wired (assistant on Anthropic)" || warn "setAnthropicApiKey failed"
fi

# ── 3. Operator funding (controller setTestBalance) ───────────────
hdr "Operator funding"
# Ladder makers get the SAME $100k value as every other bot (parity with
# real players' deposit allowance): $40k ICPUSD cash here, plus $15k of
# each base token — funded inside the market loop below, where the live
# price is known. The 2-level ladder they host fits comfortably ($7.5k of
# buys per market ≤ $30k total cash-side; $7.5k of sells ≤ $15k held).
for t in $LADDER_MAKERS; do icp identity new "$t" --storage plaintext >/dev/null 2>&1 || true; done
for t in $LADDER_MAKERS; do
  tp=$(icp identity principal --identity "$t" 2>/dev/null | tail -1)
  [ -n "$tp" ] || { warn "no principal for $t"; continue; }
  # setTestBalance answers `()` — asserted (a controller trap or a CLI
  # failure is a die carrying the reply, not a warn a refused seedAmmPool
  # would re-report one screen later).
  must_unit "fund $t ICPUSD" setTestBalance "(principal \"$tp\", \"ICPUSD\", $(e8 40000.0))" --identity anonymous
done
ok "ladder makers funded (\$40k cash each; base legs sized per market below)"

# The AMM LP is alice: seedAmmPool deposits the vault liquidity FROM the
# caller's balance and attributes the LP shares to the caller — and its
# requireAuth sheds the anonymous principal, so the LP must be a real
# (non-anonymous) controller identity. alice is promoted at cold_start.
# Quote leg funded once (all markets draw on it); base legs are sized per
# market once the real price is known.
LP_IDENTITY="alice"
LP_PRINCIPAL=$(icp identity principal --identity "$LP_IDENTITY" 2>/dev/null | tail -1)
[ -n "$LP_PRINCIPAL" ] || die "identity '$LP_IDENTITY' not found — run scripts/cold_start.sh once first"
# setTestBalance answers `()`: asserted like the other funding lines — a
# controller trap ("is anonymous a controller?") or a CLI failure is a die
# carrying the reply text.
must_unit "fund LP ICPUSD quote leg" setTestBalance "(principal \"$LP_PRINCIPAL\", \"ICPUSD\", $(e8 $(( TVL_TOTAL / 2 + 50000 )).0))" --identity anonymous
ok "LP quote leg funded (\$$(( TVL_TOTAL / 2 + 50000 )) ICPUSD)"

# ── 4. Price history (chart backdrop) ─────────────────────────────
# ORDER MATTERS: injectHistoricalTrades is genesis-gated on #play — accepted
# only until the FIRST enableAmm of the install, then #err forever (a season
# reset does not re-arm it; the reinstall in step 1 is what re-armed it for
# this run). Keep this step ahead of step 5's enableAmm.
hdr "Price history"
rm -f "$MDX_ORACLE_PRICES"
if [ "$HIST_DAYS" -gt 0 ]; then
  log "injecting $HIST_DAYS days of CoinGecko history (this takes a minute)…"
  bash scripts/inject_history.sh --days "$HIST_DAYS" --identity anonymous \
    || warn "history injection had failures — see inject_history.sh's lines above for the real cause (it probes the posture gate first, so a refusal is named as such, not blamed on rate limits); chart backdrop may be partial"
else
  warn "HISTORY_DAYS=0 — skipping the chart backdrop"
fi

# ── 5. AMM + order book, per market ───────────────────────────────
# Timers paused for the whole block so the heartbeat requoter/rebalancer
# doesn't act on half-configured pools mid-seed. Every lifecycle reply in
# this block is asserted (must_ok / must_unit, above); a per-market shortfall
# (no live price, a refused vault deposit) is warned and COUNTED, and the
# final gate below dies unless at least MDX_PLAY_MIN_SEEDED markets (default:
# all of them) came up seeded + enabled.
hdr "AMM vault + maker ladder"
MIN_SEEDED="${MDX_PLAY_MIN_SEEDED:-$NMARKETS}"
case "$MIN_SEEDED" in
  ''|*[!0-9]*) die "MDX_PLAY_MIN_SEEDED must be an integer in 1..$NMARKETS (got '$MIN_SEEDED')" ;;
esac
{ [ "$MIN_SEEDED" -ge 1 ] && [ "$MIN_SEEDED" -le "$NMARKETS" ]; } \
  || die "MDX_PLAY_MIN_SEEDED must be an integer in 1..$NMARKETS (got '$MIN_SEEDED')"
must_unit "setTestTimersPaused(true)" setTestTimersPaused "(true)" --identity anonymous
TIMERS_PAUSED=true
SEEDED=0; SEEDED_TOKS=""; SHORTFALL=""
for market in $MARKETS; do
  base_tok="${market%%-*}"
  must_ok "createAmmPool $market" createAmmPool "(\"$market\")" --identity anonymous
  must_ok "setAmmConfig $market"  setAmmConfig "(\"$market\", 20:nat, $(e8 1.0):nat, 15:nat, 35:nat)" --identity anonymous

  # REAL price: on #play the manual override is dead by design; the multi-source
  # feed (HTTPS outcalls) is the only price authority.
  # RETRY the price fetch: each fetch fires 8 parallel outcalls, and after
  # three markets back-to-back the local replica's outcall adapter is
  # saturated — the LAST market's fetch then fails wholesale and the market
  # used to get skipped (and never healed: only ENABLED pools join the
  # refresh cycle). A short breather recovers it. Seen 2026-07-11: ICP,
  # always fourth, skipped on three consecutive bring-ups while all eight
  # sources answered fine from the same machine.
  px_e8=""
  for attempt in 1 2 3; do
    fetch_out=$(adm fetchAndSetRefPrice "(\"$market\")")
    px_e8=$(adm getAmmPool "(\"$market\")" | grep -oE 'refPrice = [0-9_]+' | head -1 | tr -d '_' | awk '{print $3}')
    [ -n "${px_e8:-}" ] && [ "$px_e8" != "0" ] && break
    [ "$attempt" -lt 3 ] && { warn "$market — no live price yet (attempt $attempt/3), pausing for the outcall adapter…"; sleep 6; }
  done
  if [ -z "${px_e8:-}" ] || [ "$px_e8" = "0" ]; then
    warn "$market — no live price after 3 attempts (fetchAndSetRefPrice said: $(echo "$fetch_out" | head -1)); SKIPPING this market"
    SHORTFALL="$SHORTFALL $market: no live price (fetchAndSetRefPrice said: $(mdx_one_line "$fetch_out"));"
    continue
  fi
  px=$(awk -v p="$px_e8" 'BEGIN{ printf "%.8f", p/100000000 }')

  # Anchor the simulator: it bootstraps per-market prices from getMarkets
  # lastPrice, falling back to this snapshot file, falling back to HARDCODED
  # defaults. A market whose history injection failed (CoinGecko rate limit)
  # has lastPrice=0 and no snapshot line — the sim would then trade at the
  # stale default and walk the fresh AMM off its real price (seen with BTC:
  # default 78000 vs live 63200). Upsert the live price for every market.
  { grep -v "^$base_tok " "$MDX_ORACLE_PRICES" 2>/dev/null; echo "$base_tok $px"; } > "$MDX_ORACLE_PRICES.new" \
    && mv "$MDX_ORACLE_PRICES.new" "$MDX_ORACLE_PRICES"

  # Makers' base inventory: $15k of this market's base each (the $100k
  # parity mix) — sized here because the quantity needs the live price.
  mm_base=$(awk -v p="$px" 'BEGIN{ printf "%.6f", 15000/p }')
  for t in $LADDER_MAKERS; do
    tp=$(icp identity principal --identity "$t" 2>/dev/null | tail -1)
    [ -n "$tp" ] && must_unit "fund $t $base_tok" setTestBalance "(principal \"$tp\", \"$base_tok\", $(e8 $mm_base))" --identity anonymous
  done

  # Non-crossing maker ladder: 2 makers × 2 levels/side at ±0.4%·k, ~$2500·k
  # notional — sized to fit the makers' $100k wallets across all 4 markets.
  for t in $LADDER_MAKERS; do
    for k in 1 2; do
      bid=$(awk -v p="$px" -v k="$k" 'BEGIN{ printf "%.4f", p*(1-0.004*k) }')
      ask=$(awk -v p="$px" -v k="$k" 'BEGIN{ printf "%.4f", p*(1+0.004*k) }')
      qty=$(awk -v p="$px" -v k="$k" 'BEGIN{ printf "%.6f", (2500*k)/p }')
      icp canister call backend placeLimitOrder "(\"$market\", variant { buy },  $(e8 $bid), $(e8 $qty))" --identity "$t" > /dev/null 2>&1 || true
      icp canister call backend placeLimitOrder "(\"$market\", variant { sell }, $(e8 $ask), $(e8 $qty))" --identity "$t" > /dev/null 2>&1 || true
    done
  done

  # Vault: $TVL split half base / half ICPUSD at the live price.
  base_amt=$(awk -v t="$TVL" -v p="$px" 'BEGIN{ printf "%.6f", t/p/2 }')
  quote_amt=$(awk -v t="$TVL" 'BEGIN{ printf "%.2f", t/2 }')
  base_fund=$(awk -v b="$base_amt" 'BEGIN{ printf "%.6f", b*1.05 }')
  # The LP's base leg: setTestBalance answers `()`, so the funding is asserted
  # here instead of surfacing one line later as a refused seedAmmPool.
  must_unit "fund LP $base_tok leg" setTestBalance "(principal \"$LP_PRINCIPAL\", \"$base_tok\", $(e8 $base_fund))" --identity anonymous
  # The deposit's reply is asserted by SHAPE (`variant { ok = <lpMinted> }`):
  # a refusal (`variant { err }`, exit 0) or a trap (non-zero exit, reject
  # text on stdout) is a warn here and a counted shortfall for the gate below
  # — the market's pool is left DISABLED, never enabled over an empty vault.
  seed_out=$(call seedAmmPool "(\"$market\", $(e8 $base_amt):nat, $(e8 $quote_amt):nat)" --identity "$LP_IDENTITY"); seed_rc=$?
  if [ "$seed_rc" -ne 0 ] || ! mdx_reply_ok "$seed_out"; then
    warn "$market — vault seed REFUSED (rc=$seed_rc): $(mdx_one_line "$seed_out")"
    SHORTFALL="$SHORTFALL $market: seedAmmPool refused (rc=$seed_rc): $(mdx_one_line "$seed_out");"
  else
    must_ok "setAmmSkewConfig $market" setAmmSkewConfig "(\"$market\", $(e8 $base_amt):nat, 200:nat)" --identity anonymous
    must_ok "enableAmm $market"        enableAmm "(\"$market\", true)" --identity anonymous
    SEEDED=$((SEEDED + 1)); SEEDED_TOKS="$SEEDED_TOKS $base_tok"
    ok "$market — book laddered, vault \$$TVL ($base_amt $base_tok + $quote_amt ICPUSD @ $px)"
  fi
done
must_unit "setAmmAutoInventory(true)"  setAmmAutoInventory "(true)" --identity anonymous
must_unit "setTestTimersPaused(false)" setTestTimersPaused "(false)" --identity anonymous
TIMERS_PAUSED=false
# The honest gate: a shortfall below the knob is a die carrying every skipped
# market's reason, never a "markets live" over a one-pool venue.
[ "$SEEDED" -ge "$MIN_SEEDED" ] \
  || seed_fail "only $SEEDED/$NMARKETS markets seeded (MDX_PLAY_MIN_SEEDED=$MIN_SEEDED)" "$SHORTFALL"
# Post-seed vault: LP supply minted and every seeded market's base leg in the
# basket — the deposits actually landed, not merely answered ok.
assert_vault_seeded $SEEDED_TOKS
ok "$SEEDED/$NMARKETS markets live (auto-inventory on, timers running)"

# ── 6. Insurance fund ─────────────────────────────────────────────
# Genesis backstop for liquidation shortfalls. seedInsuranceFund mints the
# pool's ICPUSD and attributes the shares to the caller (alice, like the
# AMM LP position) — never un-owned free value for a later staker.
hdr "Insurance fund"
INS_USD="${INSURANCE_USD:-144000}"
# seedInsuranceFund is `async Nat` — a bare `(N : nat)`, never a variant —
# so the gate is the (N : nat) shape (deploy.sh's mdx_call_nat), not a
# substring `nat` that a reject text could also carry.
ins_out=$(call seedInsuranceFund "($(e8 $INS_USD):nat)" --identity "$LP_IDENTITY")
if mdx_reply_nat "$ins_out"; then
  ok "insurance fund seeded (\$$INS_USD ICPUSD, shares → $LP_IDENTITY)"
else
  warn "insurance fund seed failed: $(mdx_one_line "$ins_out")"
fi

# ── 6b. Arbitrage canister ────────────────────────────────────────
# The simulated cross-venue arbitrageur (docs/amm-vault-design.md): pins the
# venue price to the oracle mark, since synthetic assets have no real arbs.
# Reinstalled fresh (its journal/state is disposable), wired both ways, funded
# with ICPUSD working capital (an external inflow, like a bridge deposit),
# then enabled — its heartbeat trades autonomously from there.
hdr "Arbitrage canister"
ARB_USD="${ARB_USD:-1281250}"
icp canister install arb --mode reinstall -y --identity anonymous > /dev/null 2>&1 \
  || warn "arb reinstall failed (icp deploy arb first?)"
ARB_ID=$(icp canister status arb --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')
if [ -n "$ARB_ID" ]; then
  # auto-wired via PUBLIC_CANISTER_ID:* env vars (icp-cli pitfall 22)
  adm fundArbitrageur "($(e8 $ARB_USD):nat)" > /dev/null || warn "fundArbitrageur failed"
  icp canister call arb setEnabled "(true)" --identity anonymous > /dev/null 2>&1 || warn "arb enable failed"
  ok "arbitrageur wired + funded (\$$ARB_USD ICPUSD working capital, 5s tick)"
else
  warn "arb canister not found — venue prices have no external anchor"
fi

# ── 7. Trading bots ───────────────────────────────────────────────
# scripts/trading_simulation.sh (strategy archetypes, most of them trading on
# MARGIN) supersedes the old spot-only simulate_trading.sh locally: a venue of
# coin-flippers leaves the borrow engine, the liquidation batch and the
# liquidation heat map completely unexercised in play mode.
#
# Delegate to the target-scoped runners (scripts/lib/bots.sh): they stop the
# LOCAL fleet by its recorded PID and start the replacement with this target's
# sizing (mdx_bots_for / mdx_interval_for / mdx_pool_fund_for).
#
# NOT a pattern kill. The previous version pgrep'd "trading_simulation.sh",
# which matches an ENGINE or SUBNET fleet running from this same checkout —
# the env vars that choose the venue (IC_ENV) are NOT in argv, so no pattern
# can tell the fleets apart. It killed the live engine fleet on 2026-08-01,
# the fourth loss to this bug class.
#
# MDX_NO_SIMULATE=1 (cold_start --no-simulate in play mode, task 1788479256)
# skips only the START. The stop stays unconditional: a stale recorded fleet
# trading under the reinstall above is exactly what this step exists to
# prevent, and stopping goes by recorded PID, so it can touch nothing else.
hdr "Trading bots"
bash scripts/stop_bots_local.sh >/dev/null 2>&1 || true
if [ "${MDX_NO_SIMULATE:-0}" = "1" ]; then
  BOTS_STARTED=false
  warn "fleet NOT started (MDX_NO_SIMULATE=1) — start it by hand with: bash scripts/start_bots_local.sh"
else
  BOTS_STARTED=true
  bash scripts/start_bots_local.sh || warn "bot start failed — run scripts/start_bots_local.sh by hand"
fi

# ── 8. Frontend ───────────────────────────────────────────────────
hdr "Frontend"
log "icp deploy frontend (build + certified asset sync)"
icp deploy frontend --identity anonymous > "$MDX_PLAY_FRONTEND_LOG" 2>&1 \
  || warn "frontend deploy failed — see $MDX_PLAY_FRONTEND_LOG"
ok "frontend deployed"

# ── 9. Summary ────────────────────────────────────────────────────
hdr "Play mode is up"
allowance=$(icp canister call backend getPlayDepositAllowance "()" --identity mdex-play-mm-1 2>/dev/null | tr -d '_' | grep -oE 'capUsd = [0-9]+' | awk '{printf "%.0f", $3/100000000}')
echo "  Posture          : play (faucet dead; sign-ons start with nothing)"
echo "  Deposit allowance: \$${allowance:-?} per user, lifetime, mark-valued at claim"
echo "  AMM              : $SEEDED markets × \$$TVL vault (live-feed prices)"
echo "  Insurance fund   : \$$INS_USD ICPUSD"
echo "  Arbitrageur      : \$${ARB_USD} working capital (pins venue ↔ mark)"
if $BOTS_STARTED; then
  echo "  Bots             : 20 sim traders + 2 makers, \$100k value each (player parity)"
else
  echo "  Bots             : NOT started (MDX_NO_SIMULATE=1) — bash scripts/start_bots_local.sh"
fi
echo "  Frontend         : http://frontend.local.localhost:$GW_PORT/"
echo ""
echo "  NOTE: #play is the repo's DEFAULT posture (DEPLOY_MODE, src/backend/main.mo)."
echo "        Dev fixtures (cold_start --mode full|matching|amm|staged|load) need a"
echo "        temporary flip to #dev there; flip back to #play when done."
