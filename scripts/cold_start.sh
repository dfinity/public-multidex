#!/bin/bash
# UPLANDS DEX — Cold-Start Orchestrator
#
# Takes UPLANDS from zero (empty replica OR no replica at all) to a
# running, populated exchange. The DEFAULT is the repo's canonical
# deployment: posture #play — deploy, then hand seeding to
# scripts/play_start.sh, which reinstalls backend+bridge fresh and seeds
# the $5,125,000 (AMM_TVL_TOTAL) AMM vault, the $144k (INSURANCE_USD) insurance fund, price history, a maker
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
#                          staged     Staged-order fixture (alice's sealed
#                                     BUY staged on BTC-ICPUSD, bob funded
#                                     to sell; the settlement, cancel-refund,
#                                     zombie and GEPTOR-inflight suites
#                                     build on it).
#                          load       Load-test fixture (N bulk-seeded
#                                     principals, sparse book, no AMM).
#                        seed.sh modes: full/empty/matching/amm/staged/load
#                        (its dispatch). All but `empty` drive #dev-only
#                        surfaces and refuse to run against a #play
#                        source — flip DEPLOY_MODE to #dev in
#                        src/backend/main.mo for those. `empty` (deploy
#                        only, no data) is not posture-gated.
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
#   --no-simulate        Don't start a bot fleet after seeding (default:
#                        started for --mode full only). Reaches --mode play
#                        too: play_start.sh normally launches its own fleet
#                        in its step 7, and an explicit --no-simulate is
#                        forwarded to it as MDX_NO_SIMULATE=1 so the seeded
#                        #play bring-up runs with NO fleet (a stale recorded
#                        fleet is still stopped). This is how a factory seat
#                        runs `deploy.sh local --seed --no-simulate`.
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
# An EXPLICIT --no-simulate is distinguishable from the play-mode default
# (also "no") because only the explicit one must reach play_start.sh: a bare
# `cold_start.sh` keeps launching play's fleet as it always has.
NO_SIMULATE_EXPLICIT=false
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
    --no-simulate)    SIMULATE="no";  NO_SIMULATE_EXPLICIT=true;  shift ;;
    --simulate)       SIMULATE="yes"; NO_SIMULATE_EXPLICIT=false; shift ;;
    --help|-h)        sed -n '3,/^# Exit code/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Sensible default for --simulate if the user didn't set it explicitly.
# (play mode never needs §4's launcher: play_start.sh launches its own bot
# fleet — unless an explicit --no-simulate is forwarded to it, §3 below.)
if [ -z "$SIMULATE" ]; then
  if [ "$MODE" = "full" ]; then SIMULATE="yes"; else SIMULATE="no"; fi
fi

# History-depth default: play_start.sh's 9 days for the play bring-up,
# the richer 14-day backdrop for the #dev full fixture.
if [ -z "$HISTORY_DAYS" ]; then
  if [ "$MODE" = "play" ]; then HISTORY_DAYS=9; else HISTORY_DAYS=14; fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Law-5 tripwire (scripts/factory_guard.sh, local mode - fail-open without a
# seat identity): a consumer seat never cold-starts the PRIMARY checkout's venue.
. "$SCRIPT_DIR/factory_guard.sh"
factory_primary_guard "cold_start.sh" local
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

# ── Verify-with-Google on THIS venue ─────────────────────────────
# The backend trusts only the origins in its frontend_origins env var, and
# icp.yaml's LOCAL-DEV value names the primary's :8000 and vite's :3100 only
# (128-char env-value cap). A seat venue serves the app from its OWN
# OS-assigned gateway port, so its origin is never on that list: Internet
# Identity's sign-in finish refuses it (#FrontendOriginMismatch) and the
# Deposit page's unlock card fails closed - "operator: add
# http://frontend.local.localhost:<port> to frontend_origins" - which is how
# no seat venue could fund a play account (2026-11-03). So the deploy phase
# appends the venue's own origin to the canister's list. It has to ride EVERY
# deploy: `icp deploy` re-stamps the yaml value on each install (the CLI says
# so - "overridden on next settings sync"), so a one-off hand edit dies with
# the next upgrade. Idempotent (:8000 is already listed, so the primary's
# venue is a no-op); `--identity anonymous` is the local controller (law 10);
# the yaml pair plus one seat origin is 96 characters, inside the cap.
stamp_local_frontend_origin() {
  local port origin yaml_list
  port=$(mdx_local_gateway || true); port=${port##* }
  if [ -z "$port" ]; then
    warn "frontend_origins: gateway port unknown - Verify-with-Google works on the :8000 origin only"
    return 0
  fi
  origin="http://frontend.local.localhost:${port}"
  yaml_list=$(sed -n 's/^[[:space:]]*frontend_origins:[[:space:]]*"\([^"]*\)".*/\1/p' icp.yaml | head -1 || true)
  case ",${yaml_list}," in
    *",${origin},"*) ok "frontend_origins: ${origin} already listed in icp.yaml"; return 0 ;;
  esac
  if icp canister settings update backend --identity anonymous \
       --add-environment-variable "frontend_origins=${yaml_list:+${yaml_list},}${origin}" > /dev/null 2>&1; then
    ok "frontend_origins: + ${origin} (Verify-with-Google and play deposits work on this venue)"
  else
    warn "frontend_origins: settings update failed - Verify-with-Google refuses this venue's origin (${origin}); by hand: icp canister settings update backend --identity anonymous --add-environment-variable \"frontend_origins=${yaml_list:+${yaml_list},}${origin}\""
  fi
}

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

# ── Banner truth (task 3088509465) ──────────────────────────────
# The completion banner used to print `Mode    : $MODE` — the SEED-mode
# default ("play", :86) — so `deploy.sh local` on a seeded venue (which is
# `exec cold_start.sh --no-seed`) ended with "Mode : play" while the tree
# AND the canister were on #dev: the guard above resolves SRC_POSTURE only
# when seeding, and the no-seed update path never read the posture at all.
# Read it HERE, before anything builds, so a tree edit mid-run cannot
# recolour the banner; the banner itself prefers the LIVE getDeployMode and
# falls back to this. `|| true`: the no-seed path is posture-agnostic by
# design, so an unreadable posture is reported as "unresolved", not refused.
BUILD_POSTURE="${SRC_POSTURE:-$(mdx_posture_of src/backend/main.mo || true)}"
# Bridge posture LAG (task 1788488022): the Bridge has its OWN literal and
# the seat posture rhythm flips BOTH. Read it here too — before anything
# builds — so a one-file flip (DEX #dev, Bridge #play) is named while a
# Ctrl-C still saves the deploy. A NOTE, never a refusal: the pair is legal
# under W3-09 (the Bridge is LESS permissive), only the Bridge dev-hook suite
# sections lose coverage. Only when this run deploys (the tree is what ships).
BUILD_BRIDGE_POSTURE=$(mdx_posture_of src/bridge/main.mo || true)
if $DO_DEPLOY; then mdx_note_bridge_posture_lag "${BUILD_POSTURE:-}" "${BUILD_BRIDGE_POSTURE:-}" tree; fi
# Set ONLY at the two fleet launch sites below (§3 play seed via
# play_start.sh, §4 the --simulate launcher) and read by the banner (tasks
# 3088507290 + 3088509465 — two seats hit the same lie the same day): the
# "Bot log" line is printed when THIS run launched a fleet, never inferred
# from the seed mode (the old gate keyed on MODE=play, so --no-seed named a
# stale log from an earlier bring-up as if a fleet were trading).
FLEET_STARTED=false
# A RECORDED local fleet whose supervisor PID is live — the PID file
# scripts/lib/bots.sh writes, checked by `kill -0` on that one PID. Never a
# process pattern (mdex-process-safety §2).
fleet_alive() {
  local pf; pf=$(mdx_pidfile local)
  [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null
}

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
  # The CLI used to run in the FOREGROUND here. In the 2026-09-05 launcher
  # wedge (docs/seat-venue-bring-up.md, task 1788580163) `icp network start
  # --background` itself never returns — it awaits a status.json the parked
  # launcher never writes — so this line hung indefinitely, silent, with
  # nothing recognising the state. Bound it (task 1788581044): run the CLI
  # backgrounded, capture ITS pid, and watchdog that one pid with `kill -0`
  # up to REPLICA_START_GRACE_S — the start doctor's own env name, default
  # 90, so cold_start and the doctor agree on what "past the grace" means.
  # bash 3.2, no `timeout` binary on this machine, never a process pattern
  # (mdex-process-safety §1-2). On the deadline, or on a start that returned
  # without a reachable gateway, the REAL doctor (replica-doctor.sh
  # --start-wedge, read-only, no icp calls) reports and gives the verdict —
  # WEDGED names the PIDs to kill, NO LAUNCHER is the self-inflicted shape —
  # and cold_start exits 1. It kills NOTHING itself: the CLI child is left
  # running and named, and the human/seat decides (the bring-up note's
  # "WEDGED twice in a row -> HUMAN NEEDED" rule).
  REPLICA_START_GRACE_S="${REPLICA_START_GRACE_S:-90}"
  case "$REPLICA_START_GRACE_S" in ''|*[!0-9]*)
    err "REPLICA_START_GRACE_S must be a whole number of seconds (got '$REPLICA_START_GRACE_S')"; exit 1 ;;
  esac
  export REPLICA_START_GRACE_S
  icp network start --background > "$MDX_NETWORK_START_LOG" 2>&1 &
  START_PID=$!
  START_RETURNED=false
  START_WAITED=0
  while [ "$START_WAITED" -lt "$REPLICA_START_GRACE_S" ]; do
    if ! kill -0 "$START_PID" 2>/dev/null; then START_RETURNED=true; break; fi
    sleep 1
    START_WAITED=$((START_WAITED + 1))
  done
  if ! kill -0 "$START_PID" 2>/dev/null; then START_RETURNED=true; fi
  if $START_RETURNED; then
    # Reap it; its exit status is not the signal (the old line was `|| true`
    # too) — the gateway probe below is.
    wait "$START_PID" 2>/dev/null || true
  else
    err "icp network start has not returned after ${REPLICA_START_GRACE_S}s (REPLICA_START_GRACE_S) — the launcher wedge signature"
    err "the CLI child (pid $START_PID) is LEFT RUNNING — cold_start never kills on its own; act on the doctor's verdict below by PID"
    bash "$SCRIPT_DIR/replica-doctor.sh" --start-wedge "$(pwd)" || true
    err "replica did not start within the grace — see the start doctor's report above and docs/seat-venue-bring-up.md (WEDGED twice in a row -> HUMAN NEEDED)"
    exit 1
  fi
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
    bash "$SCRIPT_DIR/replica-doctor.sh" --start-wedge "$(pwd)" || true
    err "replica returned from start but the gateway is unreachable — see the start doctor's report above and docs/seat-venue-bring-up.md"
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
  # ── Candid freshness: never ship a lying interface (W5-20) ───────
  # mops.toml embeds src/backend/backend.did as the canister's PUBLIC
  # candid:service metadata and gen-did.sh is its only writer. deploy.sh has
  # gated on it since W5-20, but this script called `icp deploy` directly —
  # so every cold start after an API edit shipped the PREVIOUS interface
  # (found live on a factory seat, task 1788483105: the new method's reply
  # printed as a raw hash variant, "WARN could not fetch candid type", and
  # candid/backend.did showed no diff). Every seat brings its venue up
  # through this path, so it carries the same gate, same wording; gen-did
  # is idempotent and cheap relative to the deploy. Absolute path via
  # SCRIPT_DIR — `$(dirname "$0")` is wrong after a cd (process-safety §3).
  log "regenerating candid interface (gen-did.sh) so the deploy ships what the source says"
  if ! bash "$SCRIPT_DIR/gen-did.sh" > /dev/null; then
    err "scripts/gen-did.sh failed — refusing to deploy a stale candid:service interface. Run it by hand to see why."
    exit 1
  fi
  # ── The LOCAL cycle floor (task 1788665638) ────────────────────
  # The sidecars (arb, bridge) are endowed once, at CREATE time, and the
  # phase-2.5 top-up below feeds the backend alone — so on a seat venue a
  # week old THIS install fails IC0207 ("Failed to install canister 'arb' …
  # is out of cycles") while `canister status` still shows hundreds of B (an
  # install needs headroom above the freezing reserve). mdx_local_cycle_floor
  # (lib/targets.sh) reads each balance, tops any below MDX_LOCAL_CYCLE_FLOOR
  # (5t) up through scripts/top_up_cycles.sh, and prints both lines here as
  # the deploy's diagnostics. Local only by construction (no -e; anonymous,
  # the local controller, pays — free); never fails: an unreadable balance
  # warns by name, and the failure arm below names the cure if it bites.
  mdx_local_cycle_floor
  # ── The frontend recipe migration (task 1793503326) ─────────────
  # A venue whose `frontend` still runs the legacy @dfinity/asset-canister
  # wasm cannot be UPGRADED to the certified-assets wasm the static-site
  # recipe installs — unrelated Candid interfaces, so icp's pre-install check
  # would refuse the WHOLE deploy below as BREAKING before installing
  # anything (and `--yes` is not the answer: it pushes the upgrade onto
  # stable memory the new wasm cannot read). The frontend holds no state, so
  # on this LOCAL venue reinstall it first; the plain deploy then upgrades it
  # in place like every later one. Detection: the legacy-only `api_version`
  # query (mdx_frontend_is_legacy_asset_canister, lib/targets.sh).
  if mdx_frontend_is_legacy_asset_canister local anonymous; then
    warn "frontend still runs the legacy asset-canister wasm — reinstalling it on the certified-assets wasm first (stateless; icp would refuse the upgrade as BREAKING)"
    if icp deploy frontend --mode reinstall --identity anonymous > "$MDX_COLD_DEPLOY_LOG" 2>&1; then
      ok "frontend reinstalled on the static-site (certified-assets) recipe"
    else
      tail -20 "$MDX_COLD_DEPLOY_LOG"
      err "frontend reinstall failed — by hand: icp deploy frontend --mode reinstall --identity anonymous"
      exit 1
    fi
  fi
  log "icp deploy"
  # The output lands in MDX_COLD_DEPLOY_LOG (runfiles.sh — .run/, never a
  # fixed /tmp name) so the failure arm can READ it back: an `out of cycles`
  # / IC0207 reject then names the frozen canister and the one-line cure
  # instead of leaving the raw replica text as the whole diagnosis.
  # MDX_DEPLOY_BREAKING (set non-empty by hand, never by a script): the one deploy
  # that carries an apiVersion MAJOR bump is, by definition, not a Candid
  # subtype of what the venue runs, and icp refuses such an upgrade unless
  # told `--yes`. The ratchet already made the declaration (the committed
  # major rose); this forwards it to icp for THAT deploy, loudly. Every
  # later deploy is compatible again and must not carry it.
  if [ -n "${MDX_DEPLOY_BREAKING:-}" ]; then warn "MDX_DEPLOY_BREAKING set: bypassing icp's Candid compatibility check (an apiVersion MAJOR bump is being installed)"; fi
  if icp deploy --identity anonymous ${MDX_DEPLOY_BREAKING:+--yes} > "$MDX_COLD_DEPLOY_LOG" 2>&1; then
    tail -20 "$MDX_COLD_DEPLOY_LOG"
  else
    tail -20 "$MDX_COLD_DEPLOY_LOG"
    if grep -qE 'out of cycles|IC0207' "$MDX_COLD_DEPLOY_LOG"; then
      # `|| true` inside; gated by name below (an unnamed canister still gets the cure text)
      FROZEN="$(grep -oE "canister '[a-z0-9-]+'" "$MDX_COLD_DEPLOY_LOG" | head -1 | sed "s/canister '//; s/'//" || true)"
      err "deploy failed — ${FROZEN:-a canister} is out of cycles (IC0207). Cure: bash scripts/top_up_cycles.sh --canister ${FROZEN:-<name>} --amount ${MDX_LOCAL_CYCLE_FLOOR:-5t} --identity anonymous  — then re-run. The pre-deploy floor covers '${MDX_LOCAL_CYCLE_FLOOR_CANISTERS:-arb bridge}' at ${MDX_LOCAL_CYCLE_FLOOR:-5t} (MDX_LOCAL_CYCLE_FLOOR); raise it, or add the canister to MDX_LOCAL_CYCLE_FLOOR_CANISTERS, if this recurs."
    else
      err "deploy failed"
    fi
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
  # This venue's own gateway origin into the backend's frontend_origins
  # (the function's comment says why; re-applied on every deploy because the
  # install re-stamps icp.yaml's list).
  stamp_local_frontend_origin
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
# which wipes the books and the trade tape, the AMM pools + LP balances +
# vault (value histories included), staged orders / swaps / LP requests
# and their soft-locked reservations, margin accounts / loans / pools,
# rolling stats, levels / badges / volumes, the event log, the last-oracle
# aggregates and the archive chain — wallet balances survive (the doc
# comment above `resetExchange` in src/backend/main.mo is the authority).
# Pass `--no-seed` to skip this step entirely (e.g. when you only want to
# redeploy code + top up cycles without losing accumulated trading state).
if $DO_SEED; then
  if [ "$MODE" = "play" ]; then
    hdr "Seed (mode: play → scripts/play_start.sh)"
    # The canonical #play bring-up: builds + reinstalls backend/bridge,
    # wires them (XRC deliberately unwired on play), injects price history,
    # seeds the AMM vault ($5,125,000 across markets) and the insurance fund
    # ($144k, INSURANCE_USD), lays a maker ladder, starts the sim bots, and redeploys the
    # frontend. Honors HISTORY_DAYS / AMM_TVL_TOTAL / INSURANCE_USD.
    # An explicit --no-simulate is forwarded as MDX_NO_SIMULATE=1: play_start's
    # step 7 then stops any recorded fleet but starts none (task 1788479256 —
    # the knob that lets a factory seat run this bring-up at all).
    if $NO_SIMULATE_EXPLICIT; then
      export MDX_NO_SIMULATE=1
      warn "--no-simulate: play_start.sh will NOT start the bot fleet (MDX_NO_SIMULATE=1)"
    fi
    if ! HISTORY_DAYS="$HISTORY_DAYS" bash "$SCRIPT_DIR/play_start.sh"; then
      err "play_start.sh failed"
      exit 1
    fi
    # play_start's step 7 stops any recorded fleet (PID file removed) and,
    # unless the knob held it back, starts a fresh one through
    # start_bots_local.sh — so a live PID file after it returns is THIS
    # run's fleet, and the banner may name its log.
    if ! $NO_SIMULATE_EXPLICIT && fleet_alive; then FLEET_STARTED=true; fi
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
    FLEET_STARTED=true
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
# Condition-driven, not a fixed sleep (task 3088502787; this used to be a
# flat `sleep 90` "for the staleness guard to lapse + one refresh cycle").
# Both seed paths zero the feed counters first (seed.sh full → resetExchange,
# play_start.sh → reinstall) and resume the timers last, and the seed's own
# setAmmRefPrice stamps never touch them — so getPriceFeedStats.successCount
# ≥ 1 after the seed phase is proof that tickPriceRefresh fired AND applied
# a live aggregate to a pool after the unpause (a pended/rejected sample
# counts as a failure and moves nothing). `seed.sh full` already waits for
# exactly that tick (its MDX_SEED_FEED_WAIT_SEC wait ends once every pool's
# refPriceUpdatedNs has moved past its stamps, 45-70s measured), so on the
# full path this phase sees successCount ≥ 4 on its FIRST sample and costs
# ~0s where it used to add 90s on top of the seed's wait. play_start.sh runs
# no such wait, so on the play path this poll IS the wait, and it ends at
# the first applied tick (~45-70s after the unpause: PRICE_STALE_AFTER_NS 45s
# on the HB_PRICE_NS 30s grid, then outcall latency) instead of always 90s.
# The 90s bound is the one both waits share; a second price MOVE would need
# a whole further cadence (the steady-state per-pool cadence is 60s by code —
# age ≥ 45s at a 30s beat quantises to two beats, measured in task
# 1788503312 — plus latency ≈ 60-90s), so
# no shorter fixed residual exists — the "did a price change in my window"
# check was dropped: since 3088500128 the seed stamps the marks AT the live
# aggregate, so the first tick usually re-writes the same price. The counter
# is the liveness evidence; the mark's AGE is what the LP-mint gate reads
# (LP_DEPOSIT_MAX_REF_AGE_NS = 60s), so that is what gets printed per pool.
if [ "$MODE" = "full" ] || [ "$MODE" = "play" ]; then
  hdr "AMM oracle health"
  HEALTH_MAX=90
  log "waiting up to ${HEALTH_MAX}s for the first applied feed refresh since the seed (successCount ≥ 1)"

  # Every call in this section is a READ-ONLY DIAGNOSTIC: a failure here means
  # "we couldn't measure", not "the cold start failed", so each one keeps its
  # own `|| true` and the reporting below handles the empty case. Without
  # them, -e would turn an unreachable query into a failed bring-up AFTER the
  # exchange was successfully deployed and seeded.
  #
  # Candid prints Nats with underscore separators ("successCount =
  # 1_234 : nat"): strip the underscores, then cut at the first non-digit to
  # drop the type suffix. Cutting at the first "_" instead would keep only
  # the leading digit group.
  HEALTH_T0=$(date +%s)
  SUCCESS=""
  FAILURES=""
  while :; do
    STATS=$(icp canister call backend getPriceFeedStats '()' --identity anonymous 2>&1 || true)
    SUCCESS=$(echo "$STATS" | awk -F' *= *' '/successCount/ {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); print $2; exit}')
    FAILURES=$(echo "$STATS" | awk -F' *= *' '/failureCount/ {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); print $2; exit}')
    if [ "${SUCCESS:-0}" -ge 1 ] 2>/dev/null; then break; fi
    if [ $(( $(date +%s) - HEALTH_T0 )) -ge "$HEALTH_MAX" ]; then break; fi
    sleep 5
  done
  HEALTH_WAITED=$(( $(date +%s) - HEALTH_T0 ))
  printf "  refreshes: %s successes · %s failures (sampled after %ss)\n" "${SUCCESS:-0}" "${FAILURES:-0}" "$HEALTH_WAITED"

  # Per-pool mark age against the LP-mint staleness grace. macOS ships bash
  # 3.2 (no `declare -A`), and refPriceUpdatedNs is a ~1.8e18 Nat — parse and
  # subtract in awk rather than in shell arithmetic.
  MARKETS=(BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD)
  NOW_S=$(date +%s)
  for m in "${MARKETS[@]}"; do
    POOL=$(icp canister call backend getAmmPool "(\"$m\")" --identity anonymous 2>&1 || true)
    PX=$(echo "$POOL" | awk -F' *= *' '/refPrice / {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); print $2; exit}')
    AGE=$(echo "$POOL" | awk -F' *= *' -v now="$NOW_S" '/refPriceUpdatedNs/ {gsub(/_/,"",$2); sub(/[^0-9].*/,"",$2); if ($2 + 0 > 0) printf "%d", now - $2 / 1000000000; exit}')
    if [ -n "$PX" ] && [ -n "$AGE" ] && [ "$AGE" -le 60 ] 2>/dev/null; then
      printf "  %-12s  refPrice %s  mark age %ss  ${GREEN}fresh${NC}\n" "$m" "$PX" "$AGE"
    else
      printf "  %-12s  refPrice %s  mark age %ss  ${YELLOW}stale${NC} (LP mints refuse past 60s)\n" "$m" "${PX:-—}" "${AGE:-—}"
    fi
  done

  if [ "${SUCCESS:-0}" -ge 1 ] 2>/dev/null; then
    echo -e "  ${GREEN}oracle feed is live.${NC} (${SUCCESS} refresh(es) applied since the seed)"
  else
    warn "price-feed timer appears dead — no refresh applied within ${HEALTH_MAX}s of the seed (successCount 0, failures ${FAILURES:-0})"
    echo "  → try directly: icp canister call backend fetchAndSetRefPrice '(\"BTC-ICPUSD\")' --identity anonymous"
    echo "  → if that works, the outcall path is fine but the timer isn't firing (check postupgrade)"
    echo "  → failures > 0 with 0 successes: the feed ticks but every sample is pended/rejected (circuit breaker / quality floor)"
  fi
fi

echo ""
echo -e "${GREEN}UPLANDS cold-start complete in ${ELAPSED}s (plus diagnostics).${NC}"
echo ""
echo "  Frontend: http://frontend.local.localhost:$GW_PORT/"
echo "  Backend : http://$(icp canister list 2>/dev/null | head -1).localhost:$GW_PORT/"
# Posture: the LIVE canister's word first (getDeployMode — what was actually
# deployed, whatever the tree says now), the pre-build read as the fallback
# (a replica that stopped answering), never the seed-mode default. The
# no-seed update path is labelled as such: `Mode : dev (update, no seed; …)`.
LIVE_POSTURE=$(echo y | icp canister call backend getDeployMode '()' --query --identity anonymous 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"' | head -1 || true)
POSTURE_SHOWN="${LIVE_POSTURE:-${BUILD_POSTURE:-unresolved}}"
if [ -n "$LIVE_POSTURE" ]; then POSTURE_SRC="live getDeployMode"; else POSTURE_SRC="pre-build read of src/backend/main.mo"; fi
if $DO_SEED; then
  echo "  Mode    : $POSTURE_SHOWN (seed: $MODE; $POSTURE_SRC)"
else
  echo "  Mode    : $POSTURE_SHOWN (update, no seed; $POSTURE_SRC)"
fi
if [ -n "$LIVE_POSTURE" ] && [ -n "$BUILD_POSTURE" ] && [ "$LIVE_POSTURE" != "$BUILD_POSTURE" ]; then
  warn "live posture #$LIVE_POSTURE differs from the tree's #$BUILD_POSTURE (--no-deploy, or the tree moved mid-run)"
fi
# The Bridge's own word (task 1788488022): its literal is separate, the
# rhythm flips both, and a venue whose Bridge lags at #play behind a #dev
# DEX skips every Bridge dev-hook suite section — say so LOUDLY here, from
# the LIVE answers, not the tree (the tree note above fires pre-build).
LIVE_BRIDGE_POSTURE=$(echo y | icp canister call bridge getDeployMode '()' --query --identity anonymous 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"' | head -1 || true)
echo "  Bridge  : ${LIVE_BRIDGE_POSTURE:-unresolved} (live getDeployMode)"
mdx_note_bridge_posture_lag "${LIVE_POSTURE:-}" "${LIVE_BRIDGE_POSTURE:-}" live
# Bot log: only for a fleet THIS run launched (FLEET_STARTED is set at the
# two launch sites). Both launch paths go through scripts/start_bots_local.sh,
# which logs to the PID-file run dir (scripts/lib/targets.sh: MDX_RUN_DIR).
# Otherwise say so — and if a fleet recorded by an EARLIER run is still
# trading, name it rather than pretend the venue is quiet.
if $FLEET_STARTED; then
  echo "  Bot log : tail -f $MDX_RUN_DIR/bots-local.log"
else
  if $NO_SIMULATE_EXPLICIT; then FLEET_WHY="--no-simulate"
  elif ! $DO_SEED; then FLEET_WHY="the --no-seed update path launches none"
  else FLEET_WHY="not requested for --mode $MODE"; fi
  if fleet_alive; then
    echo "  Bots    : fleet NOT started by this run ($FLEET_WHY) — a fleet recorded by an earlier run is still trading (pid $(cat "$(mdx_pidfile local)")): tail -f $MDX_RUN_DIR/bots-local.log"
  else
    echo "  Bots    : fleet NOT started ($FLEET_WHY) — bash scripts/start_bots_local.sh"
  fi
fi
echo ""
