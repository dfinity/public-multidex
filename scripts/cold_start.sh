#!/bin/bash
# UPLANDS DEX — Cold-Start Orchestrator
#
# Takes UPLANDS from zero (empty replica OR no replica at all) to a
# running, populated exchange. The DEFAULT is the repo's canonical
# deployment: posture #play — deploy, then hand seeding to
# scripts/play_start.sh, which reinstalls backend+bridge fresh and seeds
# the $1M AMM vault, the $50k insurance fund, price history, a maker
# ladder, and the sim bots. Replaces the old manual sequence:
#   icp network start && icp deploy && bash scripts/seed_exchange.sh \
#     && <manual AMM setup> && bash scripts/simulate_trading.sh
#
# Usage:
#   bash scripts/cold_start.sh [OPTIONS]
#
# Options:
#   --mode MODE          Seed mode (default: play)
#                          play       DEFAULT. #play bring-up via
#                                     scripts/play_start.sh: seeded AMM
#                                     vault + insurance fund, live-feed
#                                     prices, maker ladder, sim bots.
#                                     Source must be on #play (the repo
#                                     default posture).
#                          full       Rich #dev state: 5 named traders,
#                                     lots of orders, AMM pools enabled,
#                                     14d of oracle-derived history.
#                          empty      Deploy only; no data.
#                          matching   Minimal matching-engine fixture
#                                     (2 traders, 1 market, known book).
#                          amm        AMM fixture (seeded pool, oracle
#                                     price set, quoting enabled).
#                          pending    Pending-match fixture (1 protected
#                                     maker on the book, ready for a
#                                     taker to cross).
#                          load       Load-test fixture (N bulk-seeded
#                                     principals, sparse book, no AMM).
#                        The fixture modes (full/matching/amm/pending/
#                        load) drive #dev-only surfaces and refuse to run
#                        against a #play source — flip DEPLOY_MODE to
#                        #dev in src/backend/main.mo for those.
#   --traders N          Number of load-test trader principals (default:
#                        100; only used with --mode load or as the upper
#                        bound when --mode full pads the crowd).
#   --history-days N     Days of hourly oracle-derived price history to
#                        inject (default: 9 for play, 14 for full;
#                        0 = disable).
#   --no-deploy          Skip icp deploy (use the currently-installed wasm).
#   --no-top-up          Skip the cycle top-up step.
#   --top-up-amount AMT  Cycles to deposit (default: 100t). Suffixes k/m/b/t.
#   --no-seed            Skip the seed step entirely. Combined with
#                        --no-deploy this turns cold_start into a pure
#                        cycle top-up; combined with deploy enabled it
#                        reinstalls code without wiping trading state.
#   --no-simulate        Don't start the simulation after seeding (default:
#                        started for --mode full only; --mode play's bots
#                        are launched by play_start.sh itself).
#   --simulate           Force-start the simulation even for test modes.
#   --help               Show this message and exit.
#
# Exit code: 0 on full success, non-zero if any deploy / seed / verify step fails.

# -e as well as -o pipefail. This script's job is a SEQUENCE — network, deploy,
# wire, top up, seed — where a silent failure early leaves a half-built
# exchange that looks deployed. Every site that is ALLOWED to fail was audited
# when -e was added and now says so explicitly with `|| true` (the ones that
# matter: the two `lsof` probes in zombie_masters, the DEPLOY_MODE grep, the
# xrc-/fuel-mock status probes, and the read-only diagnostic calls in §5 — all
# of them tolerate absence by design and every one of them is a PIPELINE, which
# under `pipefail` fails the whole assignment). `a && b` lists are exempt from
# -e by the shell's own rules and were left alone.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
DIM='\033[0;90m'
NC='\033[0m'

MODE="play"
TRADERS=100
HISTORY_DAYS=""
DO_DEPLOY=true
DO_TOP_UP=true
DO_SEED=true
TOP_UP_AMOUNT="100t"
SIMULATE=""
while [ $# -gt 0 ]; do
  # Under `set -u` a bare "$2" on a value-less flag aborts with an unbound-
  # variable message that names nothing useful, and `shift 2` with one arg
  # left aborts under -e. Name the mistake instead.
  case "$1" in
    --mode|--traders|--history-days|--top-up-amount)
      [ $# -ge 2 ] || { echo "Flag $1 requires a value" >&2; exit 1; } ;;
  esac
  case "$1" in
    --mode)           MODE="$2";          shift 2 ;;
    --traders)        TRADERS="$2";       shift 2 ;;
    --history-days)   HISTORY_DAYS="$2";  shift 2 ;;
    --no-deploy)      DO_DEPLOY=false;    shift ;;
    --no-top-up)      DO_TOP_UP=false;    shift ;;
    --top-up-amount)  TOP_UP_AMOUNT="$2"; shift 2 ;;
    --no-seed)        DO_SEED=false;      shift ;;
    --no-simulate)    SIMULATE="no";      shift ;;
    --simulate)       SIMULATE="yes";     shift ;;
    --help|-h)        sed -n '3,/^# Exit code/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Sensible default for --simulate if the user didn't set it explicitly.
# (play mode never needs it: play_start.sh launches its own bot fleet.)
if [ -z "$SIMULATE" ]; then
  if [ "$MODE" = "full" ]; then SIMULATE="yes"; else SIMULATE="no"; fi
fi

# History-depth default: play_start.sh's 9 days for the play bring-up,
# the richer 14-day backdrop for the #dev full fixture.
if [ -z "$HISTORY_DAYS" ]; then
  if [ "$MODE" = "play" ]; then HISTORY_DAYS=9; else HISTORY_DAYS=14; fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Scratch-file locations (.run/, not fixed names under sticky /tmp) — see
# scripts/lib/runfiles.sh.
# shellcheck source=scripts/lib/runfiles.sh
. "$SCRIPT_DIR/lib/runfiles.sh"
# Target table + the shared posture reader (mdx_posture_of) — see W1-02.
# shellcheck source=scripts/lib/targets.sh
. "$SCRIPT_DIR/lib/targets.sh"

log()  { echo -e "${CYAN}▶${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1" >&2; }
hdr()  { echo -e "\n${YELLOW}═══ $1 ═══${NC}"; }

# ── Posture ↔ mode guard ─────────────────────────────────────────
# The repo's default posture is #play (DEPLOY_MODE in src/backend/main.mo):
# the faucet and the setAmmRefPrice/setTest* behavior overrides are dead
# there, and the dev fixtures drive exactly those surfaces. Run against a
# #play build they HALF-work in silence — pools get created, enabled and
# skew-configured while seedAmmPool's refPrice gate rejects the actual
# vault deposit — leaving an enabled-but-EMPTY AMM and no insurance fund.
# Refuse up front instead. Only guards runs that will actually SEED:
# --no-seed (pure code update) and `empty` are posture-agnostic.
if $DO_SEED; then
  # Resolved by mdx_posture_of (lib/targets.sh): comment-aware, and it
  # REFUSES unless exactly one uncommented declaration exists. `|| true`: the
  # refusal is re-raised by the -z check with seeding-specific text — a bare
  # failed substitution under -e would exit before that handling ran. (The
  # old grep here tolerated an EMPTY read and seeded anyway — an unreadable
  # posture is exactly when seeding must not proceed.)
  SRC_POSTURE=$(mdx_posture_of src/backend/main.mo || true)
  if [ -z "$SRC_POSTURE" ]; then
    err "seeding needs an unambiguous DEPLOY_MODE in src/backend/main.mo (diagnostic above)"
    exit 1
  fi
  if [ "$MODE" = "play" ]; then
    if [ "$SRC_POSTURE" != "play" ]; then
      err "--mode play needs DEPLOY_MODE = #play in src/backend/main.mo (found #$SRC_POSTURE)"
      exit 1
    fi
  elif [ "$MODE" != "empty" ] && [ "$SRC_POSTURE" != "dev" ]; then
    err "--mode $MODE is a #dev fixture, but src/backend/main.mo is on #$SRC_POSTURE"
    echo "  → default #play bring-up (seeded AMM + insurance fund): bash scripts/cold_start.sh" >&2
    echo "  → for dev fixtures: set DEPLOY_MODE = #dev in src/backend/main.mo, then rerun" >&2
    exit 1
  fi
fi

START_TS=$(date +%s)

# ── 1. Ensure the replica is running (and not a ZOMBIE pair) ─────
hdr "Replica"

# A launcher restart can leave a previous pocket-ic MASTER alive while a new
# one takes the gateway. The gateway then answers 200 and ingress/queries/the
# sim all keep working — but INTER-CANISTER calls fail: HTTPS outcalls reject
# "could not perform remote call", self-calls reject IC0406, and archive
# shipping stalls. Killing the zombie repairs call routing but NOT the
# outcall adapter (it binds once at master startup), so the only clean
# remedy is a full network restart. Detect BEFORE trusting a 200 from the
# gateway. Masters carry `--ttl`; sandboxes carry `--run-as-canister-sandbox`.
# Seen 2026-07-06.
#
# Detection is mdx_stray_masters (lib/targets.sh, W1-06): repo-scoped by
# process cwd (never widen back to every pocket-ic on the machine — the
# unscoped version reaped ~/Projects/open-saas's replica), and the OWNER is
# whoever holds the gateway `icp network status` records for THIS checkout —
# 8000 on the canonical checkout, a random port under the worktree-parallel
# workflow. The old hardwired :8000 owner test killed a worktree's own
# healthy master. Judgment and the `icp network stop` below now share one
# scope: both resolve through the ambient ICP_HOME + this cwd, so the
# network being stopped is provably the one whose master is being reaped.
STRAYS=$(mdx_stray_masters || true)
if [ -n "$STRAYS" ]; then
  warn "zombie pocket-ic master(s): $(echo $STRAYS | tr '\n' ' ')— network is half-alive (calls/outcalls break); restarting it cleanly"
  icp network stop > /dev/null 2>&1 || true
  sleep 1
  kill -9 $STRAYS 2>/dev/null || true
  # NO belt-and-braces `pkill -f pocket-ic` here. It used to be, and it would
  # SIGKILL every pocket-ic on the machine — including other projects' local
  # networks, which are separate masters rooted at their own checkouts. Kill
  # by the PIDs mdx_stray_masters resolved for THIS repo, and nothing else.
  sleep 1
fi

# Health-check against THIS checkout's recorded gateway, not a hardwired
# port (W1-06). Re-resolve after a start: a fresh worktree network binds a
# random port.
GW_PORT=$(mdx_local_gateway || true); GW_PORT=${GW_PORT##* }
if [ -n "$GW_PORT" ] && curl -s --max-time 2 "http://127.0.0.1:$GW_PORT/api/v2/status" > /dev/null 2>&1; then
  ok "replica already running at 127.0.0.1:$GW_PORT (single master owns the gateway)"
else
  log "starting local replica (background)"
  icp network start --background > "$MDX_NETWORK_START_LOG" 2>&1 || true
  # Give it a moment to come up.
  for i in $(seq 1 15); do
    GW_PORT=$(mdx_local_gateway || true); GW_PORT=${GW_PORT##* }
    if [ -n "$GW_PORT" ] && curl -s --max-time 1 "http://127.0.0.1:$GW_PORT/api/v2/status" > /dev/null 2>&1; then
      ok "replica ready on :$GW_PORT"
      break
    fi
    sleep 1
  done
  if [ -z "$GW_PORT" ] || ! curl -s --max-time 2 "http://127.0.0.1:$GW_PORT/api/v2/status" > /dev/null 2>&1; then
    err "replica failed to start — check $MDX_NETWORK_START_LOG"
    exit 1
  fi
fi

# ── 2. Deploy ────────────────────────────────────────────────────
if $DO_DEPLOY; then
  hdr "Deploy"
  # Deploy requires controller identity. Anonymous is the controller in
  # local dev (see icp canister status <name> → Controllers).
  #
  # PASS --identity EXPLICITLY on every icp invocation; never set the CLI's
  # global default identity (mdex-process-safety §5). That default is GLOBAL
  # state this script does not own: any other tool on the operator's machine
  # (another checkout, an editor integration, an MCP connector holding its
  # own principal) can move it between a default-flip and the command a line
  # later. When that happens the deploy runs as a non-controller and every
  # canister fails with IC0512 on update_settings, which reads like a
  # permissions bug in the project rather than a race on shared state. The
  # flag scopes the identity to the one command and cannot be raced. The
  # probe below only VERIFIES the anonymous identity resolves — it writes
  # no CLI state.
  if ! icp identity principal --identity anonymous > /dev/null 2>&1; then
    err "anonymous identity missing; cannot deploy as controller"
    exit 1
  fi
  log "icp deploy"
  if ! icp deploy --identity anonymous 2>&1 | tail -20; then
    err "deploy failed"
    exit 1
  fi
  ok "backend + frontend deployed"

  # Phase-6 hardening: admin endpoints (resetExchange, setTestBalance,
  # setAmm*, fetchAndSetRefPrice, etc.) now reject any caller that
  # isn't a canister controller. seed.sh and friends call those as
  # `--identity alice`, so we promote alice to a controller here.
  # Without this, every admin call after deploy would trap.
  ALICE_PRINCIPAL=$(icp identity principal --identity alice 2>/dev/null || true)
  if [ -n "$ALICE_PRINCIPAL" ]; then
    log "adding alice as canister controller (admin scripts use --identity alice)"
    icp canister settings update backend --add-controller "$ALICE_PRINCIPAL" --force --identity anonymous > /dev/null 2>&1 || true
    icp canister settings update frontend --add-controller "$ALICE_PRINCIPAL" --force --identity anonymous > /dev/null 2>&1 || true
    ok "alice promoted to controller ($ALICE_PRINCIPAL)"
  else
    warn "alice identity not found; admin scripts that use --identity alice will fail"
  fi

  # Bridge ↔ DEX discover each other from the PUBLIC_CANISTER_ID:* env vars
  # icp injects on every deploy (icp-cli pitfall 22) — no setBridge/setDex
  # leg needed; a fresh install or reinstall comes up wired. The setters
  # remain as a break-glass override (tests wire mock siblings through them).
  ok "Bridge ↔ DEX auto-wire via canister env vars (setters = break-glass override)"
  # XRC fallback anchor: wire the DEX at the local xrc-mock so the REAL call
  # path (cycles attach, candid decode, e8 conversion) runs in dev. Same
  # stable-var re-assert rationale as the Bridge wiring above. Mock RATES stay
  # unset here on purpose — the anchor loop then gets CryptoBaseAssetNotFound
  # and stores nothing, keeping the sim's oracle quiet; tests set rates
  # explicitly. On mainnet this wiring targets the REAL XRC
  # (uf6dk-hyaaa-aaaaq-qaaaq-cai) — see docs/pre-mainnet-checklist.md.
  # `|| true`: the mock is OPTIONAL — `icp canister status` exits non-zero when
  # it isn't deployed, and the `if [ -n … ]` below is the intended handling.
  XRC_MOCK_ID=$(icp canister status xrc-mock --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]' || true)
  if [ -n "$XRC_MOCK_ID" ]; then
    icp canister call backend setXrcCanister "(opt principal \"$XRC_MOCK_ID\")" --identity anonymous > /dev/null 2>&1 || true
    ok "XRC mock wired (xrc-mock=$XRC_MOCK_ID)"
  fi
  # Fuel route: wire the DEX's treasury→cycles Stage 2 at the local fuel-mock
  # (it plays BOTH the ICP ledger and the CMC, and really deposit_cycles the
  # DEX). On mainnet this wiring targets the real ledger + CMC — see
  # docs/pre-mainnet-checklist.md.
  # `|| true`: optional mock, same reasoning as XRC_MOCK_ID above.
  FUEL_MOCK_ID=$(icp canister status fuel-mock --identity anonymous 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]' || true)
  if [ -n "$FUEL_MOCK_ID" ]; then
    icp canister call backend setFuelRoute "(opt principal \"$FUEL_MOCK_ID\", opt principal \"$FUEL_MOCK_ID\")" --identity anonymous > /dev/null 2>&1 || true
    # The mock forwards REAL cycles on notify_top_up, so it needs a mintable
    # balance well above any single deposit — and the ceiling deposit is an
    # auto-fuel tranche, AUTO_FUEL_ICP_TRANCHE (100 ICP) × 10k cycles/e8s
    # = 100T, not the ~1.5T a test burns. At 20T that tranche was refused
    # (pre-2026-08-06: it TRAPPED and wedged the notify saga); 120T covers
    # one full tranche + the mock's 1T refusal margin + a suite run's burns.
    icp canister top-up --amount 120t fuel-mock --identity anonymous > /dev/null 2>&1 || true
    ok "fuel route wired (fuel-mock=$FUEL_MOCK_ID as ledger+CMC, topped 120T)"
  fi
  # Google (Gemini) assistant key — from GOOGLE_API_KEY env (legacy alias
  # AI_API_KEY) or the git-ignored scripts/.google-api-key (never committed).
  # Same stable-var re-assert rationale as the wiring above. Absent → the
  # assistant stays disabled, which is fine for local dev.
  GOOGLE_KEY="${GOOGLE_API_KEY:-${AI_API_KEY:-}}"
  [ -z "$GOOGLE_KEY" ] && [ -f scripts/.google-api-key ] && GOOGLE_KEY="$(tr -d '[:space:]' < scripts/.google-api-key)"
  if [ -n "$GOOGLE_KEY" ]; then
    icp canister call backend setGoogleApiKey "(\"$GOOGLE_KEY\")" --identity anonymous > /dev/null 2>&1 \
      && ok "Google AI key wired" || warn "setGoogleApiKey failed"
  fi
  # Anthropic key — mirror of the above (ANTHROPIC_API_KEY env or git-ignored
  # scripts/.anthropic-api-key). Injected LAST on purpose: the backend uses
  # whichever key was set last, so both present → assistant runs on Anthropic.
  ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
  [ -z "$ANTHROPIC_KEY" ] && [ -f scripts/.anthropic-api-key ] && ANTHROPIC_KEY="$(tr -d '[:space:]' < scripts/.anthropic-api-key)"
  if [ -n "$ANTHROPIC_KEY" ]; then
    icp canister call backend setAnthropicApiKey "(\"$ANTHROPIC_KEY\")" --identity anonymous > /dev/null 2>&1 \
      && ok "Anthropic key wired (assistant on Anthropic)" || warn "setAnthropicApiKey failed"
  fi
else
  hdr "Deploy (skipped)"
fi

# ── 2.5. Cycle top-up ────────────────────────────────────────────
# Run between deploy and seed so a freshly-installed canister gets
# fuel before we start hammering it with seed calls + outcalls. Also
# rescues a previously-frozen canister that was deployed but ran out.
if $DO_TOP_UP; then
  hdr "Top up cycles ($TOP_UP_AMOUNT)"
  if ! bash "$SCRIPT_DIR/top_up_cycles.sh" --amount "$TOP_UP_AMOUNT"; then
    err "top-up failed — proceeding anyway, seed may exhaust cycles"
  fi
fi

# ── 3. Seed ──────────────────────────────────────────────────────
# Both paths are destructive. `play` REINSTALLS backend+bridge (fresh play
# state) via play_start.sh; `seed.sh full`'s first step is resetExchange,
# which wipes orders, trades, AMM pools, pending matches, reserved
# balances, P&L history, and counterparty stats. Pass `--no-seed`
# to skip this step entirely (e.g. when you only want to redeploy
# code + top up cycles without losing accumulated trading state).
if $DO_SEED; then
  if [ "$MODE" = "play" ]; then
    hdr "Seed (mode: play → scripts/play_start.sh)"
    # The canonical #play bring-up: builds + reinstalls backend/bridge,
    # wires them (XRC deliberately unwired on play), injects price history,
    # seeds the AMM vault ($1M across markets) and the insurance fund
    # ($50k), lays a maker ladder, starts the sim bots, and redeploys the
    # frontend. Honors HISTORY_DAYS / AMM_TVL_TOTAL / INSURANCE_USD.
    if ! HISTORY_DAYS="$HISTORY_DAYS" bash "$SCRIPT_DIR/play_start.sh"; then
      err "play_start.sh failed"
      exit 1
    fi
  else
    hdr "Seed (mode: $MODE)"
    SEED_ARGS=( "$MODE" )
    [ -n "$TRADERS" ]      && SEED_ARGS+=( --traders "$TRADERS" )
    [ -n "$HISTORY_DAYS" ] && SEED_ARGS+=( --history-days "$HISTORY_DAYS" )

    if ! bash "$SCRIPT_DIR/seed.sh" "${SEED_ARGS[@]}"; then
      err "seed.sh failed"
      exit 1
    fi
  fi
else
  hdr "Seed (skipped — --no-seed)"
  warn "trading state preserved; book/AMM/history not touched"
fi

# ── 4. Simulate (optional) ───────────────────────────────────────
if [ "$SIMULATE" = "yes" ]; then
  hdr "Simulation"

  # ── NO PATTERN KILLS HERE. ──
  # This block used to be:
  #     pkill -f "simulate_trading.sh"
  #     pkill -KILL -f "simulate_trading.sh"
  # which is the exact pattern scripts/lib/targets.sh documents as having
  # killed the LIVE multidex.ai fleet — 2026-07-23, 2026-07-28, and again on
  # 2026-08-01. A pattern cannot tell a local simulator from one driving the
  # subnet: the target used to live only in IC_ENV, and environment
  # assignments are not part of argv, so `ps` shows the same string either
  # way. play_start.sh was migrated to the PID-file architecture; this script
  # was missed. (stop_local_bots.sh, the stopper that excluded the live
  # engine BY NAME, fell to the same class when 16137cf renamed the live
  # fleet's engine into its "local-only" pattern — retired 2026-08-14, and
  # test_deploy_hygiene.sh §3 now bans the mechanism tree-wide.)
  #
  # Bots are now started and stopped through the same wrappers play_start.sh
  # uses. mdx_bots_stop kills by ANCESTRY from the PID recorded at launch, so
  # "stop the local bots" is provably scoped to the local fleet and CANNOT
  # name a process on another target. The stale-simulator problem the old
  # comment describes (two simulators, two independently-drifting LAST_PRICES
  # anchors, trades printing far off the oracle mark) is solved better by the
  # PID file: mdx_bots_start REFUSES to start a second fleet while the
  # recorded one is alive, so they cannot stack in the first place.
  log "stopping any recorded local fleet (PID-file scoped — never by pattern)"
  bash "$SCRIPT_DIR/stop_bots_local.sh" || warn "stop_bots_local.sh reported a problem — continuing"

  log "starting the local trading fleet (scripts/start_bots_local.sh)"
  if bash "$SCRIPT_DIR/start_bots_local.sh"; then
    ok "local fleet running — stop it with: bash scripts/stop_bots_local.sh"
  else
    warn "bot start failed — start it by hand with scripts/start_bots_local.sh"
  fi
fi

ELAPSED=$(( $(date +%s) - START_TS ))

# ── 5. Diagnostic: confirm AMM oracle refresh is live ──────────────
# For the populated modes (play/full) we want visibility into whether
# the price-feed timer is actually doing its job. A cold-start that
# seeds AMM refPrices at the oracle snapshot is useless if the
# in-canister tickPriceRefresh then silently fails — the AMM would
# continue quoting on the frozen initial value while the market moves.
#
# The timer fires on a 30s interval with a 45s staleness guard:
# pools newer than 45s get skipped. Because seed_full just set the
# refPrice, we have to wait out the guard before we see a refresh.
# We wait 90s, which spans one stale-threshold crossing plus at
# least one subsequent timer tick.
if [ "$MODE" = "full" ] || [ "$MODE" = "play" ]; then
  hdr "AMM oracle health"
  log "waiting 90s for the staleness guard to lapse + one refresh cycle"

  # Capture each pool's refPrice baseline BEFORE waiting so we can
  # detect movement, not just presence. macOS ships bash 3.2 which
  # doesn't support `declare -A` — use parallel indexed arrays
  # instead (MARKETS + PX_BEFORE, indexed in lockstep).
  #
  # Candid prints Nats with underscore separators ("refPrice =
  # 6_387_980_000_000 : nat"): strip the underscores, then cut at the
  # first non-digit to drop the type suffix. Cutting at the first "_"
  # instead would keep only the leading digit group, and the before/
  # after comparison would misread most live refreshes as "unchanged".
  # Every call in this section is a READ-ONLY DIAGNOSTIC: a failure here means
  # "we couldn't measure", not "the cold start failed", so each one keeps its
  # own `|| true` and the reporting below handles the empty case. Without
  # them, -e would turn an unreachable query into a failed bring-up AFTER the
  # exchange was successfully deployed and seeded.
  MARKETS=(BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD)
  PX_BEFORE=()
  for m in "${MARKETS[@]}"; do
    POOL=$(icp canister call backend getAmmPool "(\"$m\")" --identity anonymous 2>&1 || true)
    PX=$(echo "$POOL" | awk -F' *= *' '/refPrice / {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); print $2; exit}')
    PX_BEFORE+=("$PX")
  done

  sleep 90

  STATS=$(icp canister call backend getPriceFeedStats '()' --identity anonymous 2>&1 || true)
  SUCCESS=$(echo "$STATS" | awk -F' *= *' '/successCount/ {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); print $2}')
  FAILURES=$(echo "$STATS" | awk -F' *= *' '/failureCount/ {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); print $2}')
  printf "  refreshes: %s successes · %s failures\n" "${SUCCESS:-0}" "${FAILURES:-0}"

  LIVE=0
  for i in "${!MARKETS[@]}"; do
    m="${MARKETS[$i]}"
    before="${PX_BEFORE[$i]}"
    POOL=$(icp canister call backend getAmmPool "(\"$m\")" --identity anonymous 2>&1 || true)
    PX_AFTER=$(echo "$POOL" | awk -F' *= *' '/refPrice / {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); print $2; exit}')
    if [ -n "$before" ] && [ -n "$PX_AFTER" ] && [ "$before" != "$PX_AFTER" ]; then
      printf "  %-12s  %s → %s  ${GREEN}live${NC}\n" "$m" "$before" "$PX_AFTER"
      LIVE=$(( LIVE + 1 ))
    else
      printf "  %-12s  %s (unchanged)\n" "$m" "${PX_AFTER:-—}"
    fi
  done

  if [ "$LIVE" -eq 0 ] && [ "${SUCCESS:-0}" -lt 1 ]; then
    warn "price-feed timer appears dead — no refPrice moved in 90s and no successes recorded"
    echo "  → try directly: icp canister call backend fetchAndSetRefPrice '(\"BTC-ICPUSD\")' --identity anonymous"
    echo "  → if that works, the outcall path is fine but the timer isn't firing (check postupgrade)"
  elif [ "$LIVE" -eq 0 ]; then
    # Prices very occasionally don't move in a 90s window — unusual
    # but not alarming if successCount advanced.
    echo -e "  ${YELLOW}note${NC}: successCount advanced but no price changed within 90s (quiet market)"
  else
    echo -e "  ${GREEN}oracle feed is live.${NC}"
  fi
fi

echo ""
echo -e "${GREEN}UPLANDS cold-start complete in ${ELAPSED}s (plus diagnostics).${NC}"
echo ""
echo "  Frontend: http://frontend.local.localhost:$GW_PORT/"
echo "  Backend : http://$(icp canister list 2>/dev/null | head -1).localhost:$GW_PORT/"
echo "  Mode    : $MODE"
# play mode's bots are launched by play_start.sh, logging to the same file.
# Both paths now launch the fleet through scripts/start_bots_local.sh, which
# logs to the PID-file run dir (scripts/lib/targets.sh: MDX_RUN_DIR).
{ [ "$SIMULATE" = "yes" ] || [ "$MODE" = "play" ]; } && echo "  Bot log : tail -f $MDX_RUN_DIR/bots-local.log"
echo ""
