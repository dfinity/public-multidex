#!/usr/bin/env bash
# scripts/lib/targets.sh — the ONE table that says what each deploy target is.
#
# SOURCE THIS, never execute it. Every entry point that touches a target reads
# its icp environment, identity and posture from here, so those facts exist in
# exactly one place and a new target is one row rather than a grep.
#
# WHY THIS FILE EXISTS
# The repo grew three near-identical simulators (sim_trading.sh,
# simulate_trading.sh, trading_simulation.sh), three topup scripts and three
# seed scripts, and the TARGET was chosen by an environment variable rather
# than by the command. Two consequences, both of which have bitten:
#   · `pkill -f <pattern>` could not tell a local bot from one driving
#     multidex.ai — the live fleet was killed twice (2026-07-23, 2026-07-28).
#   · run_all.sh stopped `simulate_trading.sh` while play_start.sh had started
#     `trading_simulation.sh`, so integration tests ran against a live
#     simulator and read balances that moved between assertions.
# The fix is that the target is now part of the COMMAND YOU TYPE
# (start_bots_subnet.sh), part of the process's ARGV (--target subnet), and
# recorded in a PID file — never inferred from a pattern or an env var.
set -uo pipefail

MDX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MDX_RUN_DIR="$MDX_ROOT/.run"          # PID files (gitignored)

# ── The table ──────────────────────────────────────────────────────
# target  | icp env | identity source            | posture expected on-chain
#   local | local   | anonymous                  | #dev or #play
#  engine | engine  | .cloud-engine.conf CE_*    | #play
#  subnet | subnet  | .subnet.conf   SN_*        | #play (production later)
mdx_target_valid() { case "${1:-}" in local|engine|subnet) return 0 ;; *) return 1 ;; esac; }

# icp `-e` environment for a target.
mdx_env_for() {
  case "$1" in
    local)  echo "local" ;;
    engine) echo "engine" ;;
    subnet) echo "subnet" ;;
  esac
}

# ── Fleet sizing per target ────────────────────────────────────────
# The subnet is the PRODUCTION venue and is sized for a real launch: a
# $5.125M AMM as the standing counterparty, and a bot population deep enough
# that the book, the open interest and the liquidation map look like a live
# market rather than a demo. Local and engine stay small — they run on one
# laptop / a shared engine, and every bot action is a sequential update call.
#
# Subnet targets (measured, not guessed — retune with mdx_bots_report):
#   open interest  $900k-1.1M long AND $900k-1.1M short
#   volume         ~2x the 12-bot sim_trading fleet it replaces
#   mix            50% margin / 50% spot (see ARCHETYPES)
mdx_bots_for()     { case "$1" in subnet) echo 32 ;; *) echo 12 ;; esac; }
mdx_interval_for() { case "$1" in subnet) echo  3 ;; *) echo  4 ;; esac; }
# Collateral each MARGIN bot commits to its pool — the primary lever on open
# interest (notional = equity x leverage, 1.5-2.4x by archetype).
#
# CALIBRATED, not guessed. A local run at $95k collateral measured $436k gross
# open interest across 6 margin bots = $72.7k per margin bot, once utilisation
# (not every bot is in a position at once) and the backend's initial-margin
# back-off are absorbed. Scaling that: 16 margin bots x $72.7k x (155/95)
# ~= $1.9M gross ~= $950k a side, inside the $900k-1.1M target.
#
# Headroom check: margin DEBT ran ~58% of notional, so ~$1.1M debt against the
# vault's borrow cap (50% of a $5.125M vault = $2.56M) — ~43%, leaving room
# for real players.
mdx_pool_fund_for() { case "$1" in subnet) echo 155000 ;; *) echo 25000 ;; esac; }

# Controller identity for a target. Remote identities live in gitignored conf
# files so they are never hardcoded here.
mdx_identity_for() {
  case "$1" in
    local)  echo "anonymous" ;;
    engine) [ -f "$MDX_ROOT/scripts/.cloud-engine.conf" ] && . "$MDX_ROOT/scripts/.cloud-engine.conf"
            echo "${CE_IDENTITY:-}" ;;
    subnet) [ -f "$MDX_ROOT/scripts/.subnet.conf" ] && . "$MDX_ROOT/scripts/.subnet.conf"
            echo "${SN_IDENTITY:-}" ;;
  esac
}

mdx_is_remote() { [ "$1" != "local" ]; }

# Posture of the DEPLOYED backend for a target, read from the canister. Same
# refusal, but asserted against reality rather than the working tree — see the
# note above mdx_assert_posture_for_target. Local is exempt (#dev is the point
# of a local replica). A canister that cannot be reached is NOT treated as a
# pass: an unreachable venue is not a venue to start a fleet against.
mdx_assert_runtime_posture_for_target() {
  local target="$1" env_name identity
  mdx_is_remote "$target" || { MDX_POSTURE="local"; return 0; }
  env_name=$(mdx_env_for "$target")
  identity=$(mdx_identity_for "$target")
  [ -n "$identity" ] || mdx_die "no identity configured for '$target'"
  MDX_POSTURE=$(echo y | icp canister call backend getDeployMode "()" --query \
      -e "$env_name" --identity "$identity" 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"' | head -1)
  [ -n "$MDX_POSTURE" ] || mdx_die "could not read the DEPLOYED posture of '$target' (backend unreachable, or identity '$identity' unusable — try: icp identity reauth $identity)"
  if [ "$MDX_POSTURE" = "dev" ]; then
    mdx_die "refusing to run bots against '$target': the DEPLOYED backend is #dev.
   #dev arms the open faucet and the setTest* hooks on a public venue. Redeploy it on #play."
  fi
}

# ── Guards ─────────────────────────────────────────────────────────
mdx_die()  { printf '\033[0;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
mdx_warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
mdx_ok()   { printf '\033[0;32m✓\033[0m %s\n' "$*"; }
mdx_info() { printf '\033[0;36m▶\033[0m %s\n' "$*"; }

# Refuse a #dev wasm anywhere but local. The posture is a source literal
# (DEPLOY_MODE in main.mo) that has to be flipped by hand for tests and
# flipped back — shipping the flipped build to a remote target would arm the
# open faucet and the price hooks on a public venue.
# NOTE ON SHAPE — these assert INTO GLOBALS and print nothing.
# They must never be called as `x=$(mdx_assert_…)`: a command substitution runs
# in a SUBSHELL, so the `exit` inside mdx_die kills only that subshell and the
# caller sails on with an empty value. That is not hypothetical — the first cut
# of this file did exactly that, printed "refusing to touch subnet with a #dev
# build", and then started a bot fleet against multidex.ai anyway. Assert
# first (bare call, dies in YOUR shell), then read the global.
MDX_POSTURE=""
MDX_IDENTITY=""

# WHICH POSTURE THE GATE READS depends on what the caller is about to do:
#
#   DEPLOY  — the SOURCE literal is authoritative, because the wasm about to
#             be built comes from it. That is mdx_assert_posture_for_target.
#   BOTS    — the DEPLOYED canister is authoritative. A bot fleet builds
#             nothing; it only makes calls, so what matters is the posture of
#             the venue it will call. Reading the source there couples a live
#             fleet's uptime to an unrelated local edit: the working tree sits
#             at #dev for local testing most of the time, so a supervisor
#             restart (launchd KeepAlive) would be refused and production bots
#             would stay down until someone noticed the file. That is
#             mdx_assert_runtime_posture_for_target.
# The ONE reader of the source literal. Everything that wants the working
# tree's posture — this file's deploy gate, deploy.sh, cold_start.sh,
# play_start.sh, test_deploy_hygiene.sh — resolves it HERE. Four sites used
# to hand-roll this grep in three spellings, and none stripped comments: a
# commented decoy above the real declaration defeated all four at once
# (W1-02), and the spelling without head -1 turned TWO matches into a
# two-line string that equals neither "dev" nor "play" — ambiguity silently
# read as safety.
#
# So: // comments are stripped first, and any match count other than
# EXACTLY 1 is refused — never "take the first". Block-comment decoys are
# deliberately NOT stripped: they leave the count above 1 and land in the
# same refusal (fail-closed beats a cleverer parser here).
#
# Prints the bare posture word to stdout. On refusal: diagnostic to stderr,
# NOTHING to stdout, return 1 — it never exits, so it is safe inside $()
# (see NOTE ON SHAPE above); the CALLER must treat empty output as fatal in
# its own shell.
mdx_posture_of() {
  local file="$1" matches n
  matches=$(sed 's|//.*||' "$file" 2>/dev/null \
    | grep -oE 'transient let DEPLOY_MODE : DeployMode = #[a-z]+' \
    | grep -oE '#[a-z]+$' | tr -d '#' || true)
  n=$(printf '%s' "$matches" | grep -c . || true)
  if [ "$n" -ne 1 ]; then
    printf '\033[0;31m✗\033[0m DEPLOY_MODE in %s: need exactly 1 uncommented declaration, found %s%s\n' \
      "$file" "$n" "${matches:+ (matches: $(echo $matches))}" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}

mdx_assert_posture_for_target() {
  local target="$1"
  MDX_POSTURE=$(mdx_posture_of "$MDX_ROOT/src/backend/main.mo" || true)
  [ -n "$MDX_POSTURE" ] || mdx_die "could not resolve DEPLOY_MODE from src/backend/main.mo (diagnostic above)"
  if mdx_is_remote "$target" && [ "$MDX_POSTURE" = "dev" ]; then
    mdx_die "refusing to touch '$target' with a #dev build — DEPLOY_MODE = #dev in src/backend/main.mo.
   #dev arms the open faucet and the price/scorecard hooks; on a public venue that is a
   leaderboard-rigging surface. Set it back to #play and rebuild."
  fi
  # W3-09: the Bridge carries its OWN posture literal, and the deploy path
  # never read it — only the test suite asserted the one-directional rule
  # (test_deploy_hygiene §7): the Bridge must never be MORE PERMISSIVE than
  # the DEX it credits. A #production DEX beside a #play/#dev Bridge leaves
  # the stub's unbacked-credit dev hooks answering against a value-bearing
  # venue, and nothing on the deploy path would have said a word.
  if mdx_is_remote "$target" && [ "$MDX_POSTURE" = "production" ]; then
    local bridge_posture
    bridge_posture=$(mdx_posture_of "$MDX_ROOT/src/bridge/main.mo" || true)
    if [ "$bridge_posture" != "production" ]; then
      mdx_die "refusing '$target': the DEX is #production but the Bridge resolves to '#${bridge_posture:-unresolved}'.
   The stub Bridge's unbacked-credit hooks (devSimulateDeposit/devConfirmDeposits) must not answer
   against a value-bearing DEX — deploy the real chain-key Bridge on #production first."
    fi
  fi
}

# Refuse to act without a usable controller identity for the target.
mdx_assert_identity() {
  local target="$1"
  MDX_IDENTITY=$(mdx_identity_for "$target")
  [ -n "$MDX_IDENTITY" ] || mdx_die "no identity configured for '$target' — run the full deploy once to write its scripts/.*.conf"
  if [ "$target" != "local" ]; then
    icp identity principal --identity "$MDX_IDENTITY" >/dev/null 2>&1 \
      || mdx_die "identity '$MDX_IDENTITY' unusable for '$target' (web delegation expired?) — icp identity reauth $MDX_IDENTITY"
  fi
}

# ── PID-file process control ───────────────────────────────────────
# Bots are stopped by ANCESTRY from a recorded PID, never by pattern. This is
# the property that makes "stop the local bots" provably scoped: a pattern can
# match a process that merely mentions the script's path (that is how a shell
# driving a test run got SIGTERMed on 2026-07-24), whereas a PID recorded at
# launch cannot name anything else.
mdx_pidfile() { echo "$MDX_RUN_DIR/bots-$1.pid"; }

# Every descendant of $1, deepest first, discovered via `pgrep -P` (parent),
# so nothing is matched by name.
mdx_descendants() {
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    mdx_descendants "$kid"
    echo "$kid"
  done
}

# SIGTERM the tree (children first so cleanup traps run and identities are not
# leaked), then SIGKILL whatever ignored it.
mdx_kill_tree() {
  local root="$1" p
  for p in $(mdx_descendants "$root") "$root"; do kill "$p" 2>/dev/null || true; done
  sleep 2
  for p in $(mdx_descendants "$root") "$root"; do
    kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null || true
  done
}

# ── Local gateway / stray-master resolution (W1-06) ────────────────
# The local network's "legitimate owner" used to be WHOEVER LISTENS ON TCP
# 8000, hand-rolled in three scripts. That is only true for the canonical
# checkout: the worktree-parallel workflow (fresh ICP_HOME, random gateway
# port) gives each checkout its own port, so the 8000 test made cold_start
# kill a worktree's own healthy master and play_start/deploy misclassify
# it. Resolve the owner from the CLI's OWN record instead: `icp network
# status` honours the ambient ICP_HOME and the project rooted at the cwd —
# the SAME resolution `icp network stop`/`start` use, which is what makes
# the reap and the stop provably the same scope.
#
# Prints "PID PORT" for this checkout's gateway owner; prints nothing when
# no running network is recorded or nothing listens on the recorded port —
# and a live master with a dead gateway is exactly the zombie the callers
# are hunting. (`|| true` on both probes: lsof/status exit non-zero when
# they find nothing, and pipefail + a caller's -e would turn that into a
# silent abort mid-function.)
mdx_local_gateway() {
  local url port pid
  url=$(icp network status 2>/dev/null | sed -n 's/^Api Url: //p' | head -1 || true)
  port=$(printf '%s' "$url" | sed -n 's|.*:\([0-9][0-9]*\)/*$|\1|p' || true)
  [ -n "$port" ] || return 0
  pid=$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)
  [ -n "$pid" ] || return 0
  printf '%s %s\n' "$pid" "$port"
}

# Every pocket-ic master ROOTED AT THIS CHECKOUT that is not the gateway
# owner — the callers' definition of a zombie. Detection only; never kills.
# The pgrep here is ENUMERATION (the one tolerated spelling, exempted for
# THIS FILE alone in test_deploy_hygiene §3); selection is the cwd filter —
# another project's healthy replica is not our zombie (the 2026-07-29
# open-saas lesson; a dozen foreign masters is a NORMAL machine state) —
# plus the owner test above.
mdx_stray_masters() {
  local owner repo pid pcwd
  owner=$(mdx_local_gateway || true); owner=${owner%% *}
  repo=$(pwd -P)
  for pid in $(pgrep -f "pocket-ic --ttl" 2>/dev/null || true); do
    pcwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)
    [ "$pcwd" = "$repo" ] || continue
    [ "$pid" = "${owner:-}" ] || echo "$pid"
  done
}
