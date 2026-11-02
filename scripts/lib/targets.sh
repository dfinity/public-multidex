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
mdx_env_for() {  # pure: a case table — prints the env name, never fails
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

# ── The FUNDING identity (task 1789609263 — keychain hardening F17) ──
# Every refill path (sim_trading.sh / trading_simulation.sh `fund_call` +
# `bal_of`, deploy.sh's cloud_bots pre-fund) signs with THIS identity, never
# with the target's CONTROLLER key (SN_IDENTITY / CE_IDENTITY): on the subnet
# that key is the sole human-held controller of the live exchange, and a
# refill loop signing with it kept it in the keychain's unattended grant.
# The backend admits the principal a controller designated via
# setFundingAuthority (setTestBalance / bulkSetTestBalances + the scoped
# getTestBalance read, #play/#dev only). The operator's key for that role is
# `mdex-bots` (a plain `icp identity new mdex-bots`, NOT a controller).
#
# Resolution, first hit wins:
#   1. MDX_FUNDING_IDENTITY in the environment (a one-off override, and how
#      the fleet wrappers hand the resolved name to the engine);
#   2. the target conf: SN_FUNDING_IDENTITY (.subnet.conf) /
#      CE_FUNDING_IDENTITY (.cloud-engine.conf) — deploy.sh's load/save keep
#      the line across re-deploys;
#   3. nothing — the engine then FALLS BACK to the controller identity it was
#      handed (BOT_IDENTITY) and says so in its banner. Local prints nothing:
#      a local venue funds as anonymous, its controller, by construction.
# Prints the name (or nothing); never fails. The refusal for a MISSING
# authority is the backend's (the refill traps "not the designated funding
# authority"), which the engine's `|| true` swallows exactly as before —
# so the operator half of 1789609263 (designate, then flip the conf) is
# ordered: designate FIRST.
mdx_funding_identity_for() {
  if [ -n "${MDX_FUNDING_IDENTITY:-}" ]; then echo "$MDX_FUNDING_IDENTITY"; return 0; fi
  case "$1" in
    local)  echo "" ;;
    engine) [ -f "$MDX_ROOT/scripts/.cloud-engine.conf" ] && . "$MDX_ROOT/scripts/.cloud-engine.conf"
            echo "${CE_FUNDING_IDENTITY:-}" ;;
    subnet) [ -f "$MDX_ROOT/scripts/.subnet.conf" ] && . "$MDX_ROOT/scripts/.subnet.conf"
            echo "${SN_FUNDING_IDENTITY:-}" ;;
  esac
}

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
# So: the file is reduced to its CODE IMAGE first — // line comments,
# NESTED /* */ block comments and "…"/'…' literals stripped (H-02 / F20:
# the first cut stripped `//` only, so a canonical `#play` decoy inside a
# block comment or a Text literal was the only declaration the regex saw
# when the REAL one was re-spaced by a single character; tested on a
# scratch fixture — every remote gate read that as play). Then TWO counts
# must both be exactly 1: the canonical spelling
# (`transient let DEPLOY_MODE : DeployMode = #x`) and `let DEPLOY_MODE` in
# ANY spelling. A declaration the canonical regex cannot read is refused,
# never guessed — the wasm is built from it, so "unreadable" is not "safe".
# Any other count is refused too — never "take the first".
#
# Prints the bare posture word to stdout. On refusal: diagnostic to stderr,
# NOTHING to stdout, return 1 — it never exits, so it is safe inside $()
# (see NOTE ON SHAPE above); the CALLER must treat empty output as fatal in
# its own shell.
#
# The code image of a Motoko file: line structure kept, comments and
# literals blanked. Persistent state across lines (a block comment or a
# string may span lines; nesting depth honoured). Lines with no `/`, `"`
# or `'` take the fast path — main.mo is ~1MB and this runs on every gate.
mdx_mo_code_image() {  # $1 = file → stdout
  awk '
    BEGIN { bc = 0; instr = 0; inchr = 0 }
    {
      line = $0
      if (bc == 0 && !instr && !inchr && index(line, "/") == 0 && index(line, "\"") == 0 && index(line, "\x27") == 0) { print line; next }
      out = ""; i = 1; n = length(line)
      while (i <= n) {
        ch = substr(line, i, 1); nx = substr(line, i, 2)
        if (bc > 0) {
          if (nx == "/*") { bc++; i += 2; continue }
          if (nx == "*/") { bc--; i += 2; continue }
          i++; continue
        }
        if (instr) {
          if (ch == "\\") { i += 2; continue }
          if (ch == "\"") { instr = 0 }
          i++; continue
        }
        if (inchr) {
          if (ch == "\\") { i += 2; continue }
          if (ch == "\x27") { inchr = 0 }
          i++; continue
        }
        if (nx == "//") { break }
        if (nx == "/*") { bc = 1; i += 2; continue }
        if (ch == "\"") { instr = 1; i++; continue }
        if (ch == "\x27") { inchr = 1; i++; continue }
        out = out ch; i++
      }
      print out
    }' "$1" 2>/dev/null
}

mdx_posture_of() {
  local file="$1" img matches n loose
  img=$(mdx_mo_code_image "$file" || true)
  matches=$(printf '%s\n' "$img" \
    | grep -oE 'transient let DEPLOY_MODE : DeployMode = #[a-z]+' \
    | grep -oE '#[a-z]+$' | tr -d '#' || true)
  n=$(printf '%s' "$matches" | grep -c . || true)
  loose=$(printf '%s\n' "$img" | grep -cE '(^|[^A-Za-z0-9_])let[[:space:]]+DEPLOY_MODE([^A-Za-z0-9_]|$)' || true)
  if [ "$n" -ne 1 ] || [ "$loose" -ne 1 ]; then
    printf '\033[0;31m✗\033[0m DEPLOY_MODE in %s: need exactly 1 canonical declaration outside comments and literals, found %s canonical / %s in any spelling%s\n' \
      "$file" "$n" "$loose" "${matches:+ (matches: $(echo $matches))}" >&2
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

# ── Bridge posture LAG note (task 1788488022) ─────────────────────
# The Bridge carries its OWN DEPLOY_MODE literal (src/bridge/main.mo) and
# three of its hooks gate on it (devTestStrandAdmission, devTestHoldAdmission,
# getDeployMode). The seat posture rhythm flips BOTH literals; a tree (or a
# venue) whose DEX resolves #dev while the Bridge still reads #play is the
# ONE-file flip. It is LEGAL under the W3-09 direction — the Bridge is LESS
# permissive than its DEX there, never more — so this is a NOTE, not a
# refusal: nothing on the deploy path breaks, but every Bridge dev-hook
# section (test_bridge_deposit_claim §14-15, test_bridge_write_ahead §1-2,
# test_season_wipe_fence §1-2) loud-skips on that venue, and before this
# note nothing on the deploy path said a word. Silent for every other pair
# (dev/dev, play/play, production/*: the last is the refusal above).
#   mdx_note_bridge_posture_lag <dex> <bridge> [tree|live]
# `tree` (default) names the two source files and the both-files flip;
# `live` names the two getDeployMode answers and the redeploy. Always
# returns 0 (callers run under set -e).
mdx_note_bridge_posture_lag() {
  local dex="$1" bridge="$2" where="${3:-tree}" src fix
  { [ "$dex" = "dev" ] && [ "$bridge" = "play" ]; } || return 0
  if [ "$where" = "live" ]; then
    src="live: backend getDeployMode = dev, bridge getDeployMode = play"
    fix="redeploy under the posture rhythm with BOTH literals flipped (bash scripts/deploy.sh local), then restore #play in both"
  else
    src="tree: src/backend/main.mo = #dev, src/bridge/main.mo = #play"
    fix="flip BOTH literals — perl -pi -e 's/^(\\s*transient let DEPLOY_MODE : DeployMode = )#play;/\$1#dev;/' src/backend/main.mo src/bridge/main.mo — then restore #play in both after the deploy"
  fi
  printf '\n\033[0;31m  ✗ BRIDGE POSTURE LAG\033[0m: the DEX resolves #dev but the Bridge resolves #play (%s).\n' "$src" >&2
  printf '    The Bridge dev hooks (devTestStrandAdmission / devTestHoldAdmission) stay OFF on this venue, so\n' >&2
  printf '    test_bridge_deposit_claim §14-15, test_bridge_write_ahead §1-2 and test_season_wipe_fence §1-2 will skip.\n' >&2
  printf '    The seat posture rhythm flips BOTH literals (skill mdex-software-factory, "The posture rhythm"):\n' >&2
  printf '      %s\n' "$fix" >&2
  printf '    Not refused: a Bridge LESS permissive than its DEX is the W3-09 direction (never MORE).\n\n' >&2
  return 0
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

# ── Remote pre-flight: pinned ids + the controller set (H-02 / F8) ──
# deploy.sh installed onto whatever .icp/data/mappings/<env>.ids.json named.
# Nothing in the tree held an EXPECTED id, no step read the target's
# controllers before inject_ai_keys / apply_anti_sybil_settings, and no gate
# read ids.json at all — so one poisoned mapping line (an attacker's
# canister in place of ours) would receive the AI keys and the production
# origins from a routine rollout, and factory_guard.sh (seat-keyed) never
# sees an OPERATOR's deploy. The ids below are PUBLIC (they are on the
# dashboard and in the frontend's discovery manifest); pinning them here
# is what turns the mapping from an authority into a claim to be checked.
#
# Editing this table or the mappings is OPERATOR-LANE work (factory.sh's
# merge gate refuses a seat branch that touches the mappings; this table
# is tracked so any edit shows in review). When a target is re-created the
# operator updates BOTH, in the same commit.
mdx_expected_id() {  # pure: a case table — $1 = env, $2 = canister name → the pinned id, or nothing
  case "$1:$2" in
    subnet:backend)  echo "hmxr2-pqaaa-aaabq-qaaaa-cai" ;;
    subnet:bridge)   echo "hlwxo-ciaaa-aaabq-qaaaq-cai" ;;
    subnet:arb)      echo "hxsn7-viaaa-aaabq-qaacq-cai" ;;
    subnet:frontend) echo "hcv4s-uaaaa-aaabq-qaaba-cai" ;;
    engine:backend)  echo "topnd-iyaaa-aaaa6-qaalq-cai" ;;
    engine:bridge)   echo "sdbjn-hqaaa-aaaa6-qaama-cai" ;;
    engine:arb)      echo "xn4er-aiaaa-aaaa6-qaaqq-cai" ;;
    engine:frontend) echo "seapz-kiaaa-aaaa6-qaamq-cai" ;;
  esac
}
# The canisters a remote environment carries (icp.yaml environments:).
MDX_REMOTE_CANISTERS="backend bridge arb frontend"
# Controllers EXPECTED on every canister of an environment beyond the
# deploying identity's own principal (space-separated principals; empty =
# the deployer alone). The first refusal prints the observed set verbatim —
# pin a legitimate extra (a backup operator key, a console principal) here,
# in a reviewed commit, never by re-running until it passes.
# Pinned 2026-10-31 (task 1788482118) from the OBSERVED sets, each principal
# accounted for: `tvc2q…` is the cold recovery key `multidex-recovery` (held
# offline by the operator; added to the subnet 2026-09-17); `cpbhu…cai` is the
# wallet canister that created the subnet's backend/bridge/frontend; the
# subnet's arb was created BY THE BACKEND (`hmxr2…cai`), which stays its
# controller — hence the per-canister arm. The ENGINE keeps NO extra
# controller by ruling (operator, 2026-10-31): the engine's console can
# (re)assign controllers of the canisters it hosts, so the deploying web
# identity is its only controller and no cold key is parked there.
mdx_expected_extra_controllers() {  # $1 = env, $2 = canister (optional) → space-separated principals
  case "$1" in
    subnet)
      case "${2:-}" in
        arb) echo "hmxr2-pqaaa-aaabq-qaaaa-cai tvc2q-tjog5-srj2m-sbqgx-mbcsr-ozjgj-fn75c-pugxc-6arur-3n3kf-zae" ;;
        *)   echo "cpbhu-5iaaa-aaaad-aalta-cai tvc2q-tjog5-srj2m-sbqgx-mbcsr-ozjgj-fn75c-pugxc-6arur-3n3kf-zae" ;;
      esac ;;
    engine) echo "" ;;
  esac
}

# Sorted, space-separated, de-duplicated set from a comma/space list.
mdx_principal_set() { printf '%s' "$1" | tr ',' ' ' | tr -s ' ' '\n' | sed '/^$/d' | sort -u | tr '\n' ' ' | sed 's/ $//'; }  # pure: text pipeline — normalises a principal list, never fails

# mdx_assert_deploy_target <env> <identity> — dies in the CALLER's shell
# (bare call, never inside $() — NOTE ON SHAPE above) unless:
#   1. the tracked mapping .icp/data/mappings/<env>.ids.json names EXACTLY
#      the pinned id for every canister — checked FIRST, from the file,
#      before any icp call, so a poisoned mapping never reaches the network;
#   2. icp-cli resolves every canister name on <env> to the pinned id
#      (`icp canister status <name> -e <env>` — the same resolution
#      `icp deploy` uses, so what the CLI would install onto IS what is
#      checked, not merely what the file says);
#   3. every canister's controller set equals {deployer principal} ∪
#      mdx_expected_extra_controllers <env> — a foreign controller means
#      the target is not ours to configure, keys and origins included.
# On success sets MDX_TARGET_VERIFIED=<env>; deploy.sh's remote_deploy
# refuses to run unless it matches, so the pre-flight cannot be skipped by
# a code path that forgets to call it.
MDX_TARGET_VERIFIED=""
mdx_assert_deploy_target() {
  local env_name="$1" identity="$2" map c want have status ctl expect observed principal
  mdx_is_remote "$env_name" || mdx_die "pre-flight: '$env_name' is not a remote environment (subnet | engine)"
  [ -n "$identity" ] || mdx_die "pre-flight: no identity given for '$env_name'"
  map="$MDX_ROOT/.icp/data/mappings/$env_name.ids.json"
  [ -f "$map" ] || mdx_die "pre-flight: mapping $map is missing — a remote deploy needs the tracked id mapping (operator-lane to restore)"
  # 1) the mapping file against the pinned table — no icp call yet
  for c in $MDX_REMOTE_CANISTERS; do
    want="$(mdx_expected_id "$env_name" "$c")"
    [ -n "$want" ] || mdx_die "pre-flight: no pinned id for $env_name:$c in scripts/lib/targets.sh (mdx_expected_id) — refusing to deploy onto an unpinned target"
    have="$(sed -n "s/.*\"$c\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$map" | head -1)"
    if [ "$have" != "$want" ]; then
      mdx_die "pre-flight REFUSED: .icp/data/mappings/$env_name.ids.json names $c = '${have:-<missing>}' but the pinned id is '$want'.
   The mapping is a CLAIM, not an authority: a deploy onto an unpinned canister would hand it the AI keys and the
   production origins. Restore the mapping (git diff .icp/data/mappings/), or — only for a deliberately re-created
   target — update the pinned table in scripts/lib/targets.sh and the mapping in ONE reviewed commit (operator-lane)."
    fi
  done
  mdx_ok "pre-flight: mapping $env_name.ids.json matches the pinned ids ($MDX_REMOTE_CANISTERS)"
  # 2 + 3) what icp-cli resolves each name to, and who controls it
  principal="$(icp identity principal --identity "$identity" 2>/dev/null | tail -1 || true)"
  [ -n "$principal" ] || mdx_die "pre-flight: identity '$identity' has no principal (web delegation expired?) — icp identity reauth $identity"
  for c in $MDX_REMOTE_CANISTERS; do
    expect="$(mdx_principal_set "$principal $(mdx_expected_extra_controllers "$env_name" "$c")")"
    want="$(mdx_expected_id "$env_name" "$c")"
    status="$(icp canister status "$c" -e "$env_name" --identity "$identity" 2>&1 || true)"
    have="$(printf '%s\n' "$status" | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')"
    [ -n "$have" ] || mdx_die "pre-flight: could not read the status of $c on '$env_name' as '$identity' — refusing to deploy blind (a canister we cannot read is not one we control): $(printf '%s' "$status" | tr '\n' ' ' | head -c 240)"
    [ "$have" = "$want" ] || mdx_die "pre-flight REFUSED: icp-cli resolves $c on '$env_name' to '$have' but the pinned id is '$want' — the environment's id store disagrees with the tracked table; refusing to deploy onto it."
    # icp ≤1.1 printed `Controllers: a b`; icp 1.2 prints `Controllers:` then one
    # `controller: <principal>` line each — accept both shapes.
    ctl="$(printf '%s\n' "$status" | awk '
      /^[[:space:]]*Controllers:/ { f=1; sub(/^[[:space:]]*Controllers:[[:space:]]*/, ""); if (length($0)) printf "%s ", $0; next }
      f && /^[[:space:]]*controller:[[:space:]]*/ { sub(/^[[:space:]]*controller:[[:space:]]*/, ""); printf "%s ", $0; next }
      f { f=0 }')"
    observed="$(mdx_principal_set "$ctl")"
    [ -n "$observed" ] || mdx_die "pre-flight: no 'Controllers:' line in the status of $c on '$env_name' — refusing to deploy onto a canister whose controllers cannot be read."
    if [ "$observed" != "$expect" ]; then
      mdx_die "pre-flight REFUSED: the controller set of $c ($have) on '$env_name' is [$observed] but the expected set is [$expect]
   (deployer '$identity' = $principal; pinned extras for $c: [$(mdx_expected_extra_controllers "$env_name" "$c")]). A controller we did not pin means the target is not ours alone to
   configure — the keys and origins this deploy injects would be readable/rewritable by it. If that controller is legitimate,
   pin it in mdx_expected_extra_controllers ($env_name) in scripts/lib/targets.sh in a reviewed commit; otherwise stop and investigate."
    fi
  done
  mdx_ok "pre-flight: $env_name resolves every canister to its pinned id and every controller set is {deployer} ∪ its pinned extras"
  MDX_TARGET_VERIFIED="$env_name"
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
  # bash 3.2 does NOT enforce -e inside a function invoked within $(…) (task
  # 1788550974): had this read failed, the walk would have continued with
  # repo='' and any pid whose cwd lsof cannot read (pcwd='') would have matched
  # it — reported as OUR zombie, then kill -9ed by the caller. Explicit return:
  # no repo, no strays (the reaper's conservative direction).
  repo=$(pwd -P 2>/dev/null) || return 0
  [ -n "$repo" ] || return 0
  for pid in $(pgrep -f "pocket-ic --ttl" 2>/dev/null || true); do
    pcwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)
    [ "$pcwd" = "$repo" ] || continue
    [ "$pid" = "${owner:-}" ] || echo "$pid"
  done
}

# ── The LOCAL cycle floor (task 1788665638) ────────────────────────
# Every long-lived seat venue drifts into IC0207. `icp deploy` on the local
# replica endows the sidecars (arb, bridge) ONCE, at create time, and the
# only later feeding — cold_start's phase-2.5 top-up — reaches the backend
# alone (play_start adds fuel-mock). The arb burns ~1-8B/day idle (its
# heartbeat), the Bridge ~1B/day, so after enough days the in-place update
# fails AT INSTALL — `Failed to install canister 'arb' … is out of cycles:
# please top up … IC0207` — while `canister status` still shows hundreds of
# B: an install needs headroom above the freezing reserve. The cure by hand
# was `scripts/top_up_cycles.sh --canister arb --amount 10t --identity
# anonymous`; this is that cure applied BEFORE the deploy, for every
# canister in MDX_LOCAL_CYCLE_FLOOR_CANISTERS (default `arb bridge`) whose
# balance reads below MDX_LOCAL_CYCLE_FLOOR (default 5t; the top-up deposits
# the floor itself, so a topped canister lands in [floor, 2·floor)), and it
# PRINTS both balances (plus idle burn/day) as deploy diagnostics so a seat
# sees the drift before it bites.
#
# LOCAL ONLY, structurally: the sole caller is cold_start.sh (the local
# orchestrator both `deploy.sh local` branches exec); every icp call here
# names NO environment (`-e`), so it can only ever address the ambient local
# network; and `anonymous` — the local controller, auto-seeded with cycles at
# network start — pays. deploy.sh's remote branches keep scripts/topup.sh
# (ARB_TOPUP=true) and never call this. NEVER FAILS: an unreadable balance
# WARNS by name and continues (the deploy then fails with the replica's own
# text and cold_start's failure arm names this cure); a failed top-up warns
# with the by-hand command. Read-only apart from the top-up itself.
mdx_cycles_to_int() {  # pure: "5t" / "138b" / "1_399_205_717_302" → plain integer cycles (bash 3.2 64-bit arithmetic); prints nothing on garbage, never fails
  local s n mul
  s="$(printf '%s' "${1:-}" | tr -d '_ ' | tr '[:upper:]' '[:lower:]')"
  case "$s" in
    *k) n="${s%k}"; mul=1000 ;;
    *m) n="${s%m}"; mul=1000000 ;;
    *b) n="${s%b}"; mul=1000000000 ;;
    *t) n="${s%t}"; mul=1000000000000 ;;
    *)  n="$s";     mul=1 ;;
  esac
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$((n * mul))"
}
mdx_fmt_cycles() {  # pure: 1399205717302 → "1_399_205_717_302 (1.40T)"; anything non-numeric is echoed unchanged, never fails
  case "${1:-}" in ''|*[!0-9]*) printf '%s' "${1:-}"; return 0 ;; esac
  awk -v n="$1" 'BEGIN { t = n / 1e12; s = ""; while (length(n) > 3) { s = "_" substr(n, length(n) - 2) s; n = substr(n, 1, length(n) - 3) }; printf "%s%s (%.2fT)", n, s, t }'
}
# $1 = canister name → "<cycles> <idle-cycles-burned-per-day>" as plain
# integers (underscores stripped); prints NOTHING when the status read fails
# (frozen, absent, replica down) or shows no `Cycles:` line. `|| true` inside
# the capture: `status` exits non-zero for a frozen or absent canister, and
# the caller gates on the (empty) output by name (hygiene §6ao/§6ap shapes).
mdx_canister_cycles() {
  local out cyc burn
  out="$(icp canister status "$1" --identity anonymous 2>/dev/null || true)"
  cyc="$(printf '%s\n' "$out" | awk '/^ *Cycles:/ { gsub(/_/, "", $2); print $2; exit }')"
  burn="$(printf '%s\n' "$out" | awk '/^ *Idle cycles burned per day:/ { gsub(/_/, "", $NF); print $NF; exit }')"
  case "$cyc" in ''|*[!0-9]*) return 0 ;; esac
  case "$burn" in ''|*[!0-9]*) burn=0 ;; esac
  printf '%s %s' "$cyc" "$burn"
}
mdx_local_cycle_floor() {
  local floor floor_int scripts_dir c reading cyc burn tu_out tu_rc after
  floor="${MDX_LOCAL_CYCLE_FLOOR:-5t}"
  floor_int="$(mdx_cycles_to_int "$floor")"
  if [ -z "$floor_int" ]; then
    mdx_warn "MDX_LOCAL_CYCLE_FLOOR='$floor' is not a cycles amount (a plain integer or a k/m/b/t suffix) — local cycle floor SKIPPED"
    return 0
  fi
  scripts_dir="${MDX_SCRIPTS_DIR:-$MDX_ROOT/scripts}"
  for c in ${MDX_LOCAL_CYCLE_FLOOR_CANISTERS:-arb bridge}; do
    reading="$(mdx_canister_cycles "$c" || true)"
    if [ -z "$reading" ]; then
      mdx_warn "$c cycles: UNREADABLE (icp canister status $c printed no Cycles line — ${c}_cycles='') — floor NOT applied to $c; if the deploy fails IC0207: bash scripts/top_up_cycles.sh --canister $c --amount $floor --identity anonymous"
      continue
    fi
    cyc="${reading%% *}"; burn="${reading##* }"
    if [ "$cyc" -ge "$floor_int" ]; then
      mdx_ok "$c cycles: $(mdx_fmt_cycles "$cyc"), idle burn/day $(mdx_fmt_cycles "$burn") — at or above the floor $floor (MDX_LOCAL_CYCLE_FLOOR)"
      continue
    fi
    mdx_info "$c cycles: $(mdx_fmt_cycles "$cyc"), idle burn/day $(mdx_fmt_cycles "$burn") — BELOW the floor $floor (MDX_LOCAL_CYCLE_FLOOR); topping up $floor via scripts/top_up_cycles.sh"
    tu_out="$(bash "$scripts_dir/top_up_cycles.sh" --canister "$c" --amount "$floor" --identity anonymous 2>&1)" && tu_rc=0 || tu_rc=$?
    if [ "$tu_rc" -ne 0 ]; then
      mdx_warn "$c top-up FAILED (exit $tu_rc): $(printf '%s' "$tu_out" | tr '\n' ' ' | tail -c 200) — the deploy may fail IC0207; by hand: bash scripts/top_up_cycles.sh --canister $c --amount $floor --identity anonymous"
      continue
    fi
    after="$(mdx_canister_cycles "$c" || true)"; after="${after%% *}"
    mdx_ok "$c cycles: $(mdx_fmt_cycles "${after:-unreadable}") after topping up $floor (was $(mdx_fmt_cycles "$cyc"))"
  done
  return 0
}

# ── The frontend recipe migration (task 1793503326) ─────────────────
# $1 = environment (local|engine|subnet), $2 = identity → exit 0 when the
# deployed `frontend` canister still runs the LEGACY @dfinity/asset-canister
# wasm, non-zero otherwise (certified-assets installed, canister absent,
# replica down, unreadable). The probe is the one query only the legacy
# canister answers: `api_version : () -> (nat16) query` (the SDK asset
# canister's interface); certified-assets refuses it (IC0536, no such query
# method) and exposes `version '()'` instead. Why it matters: the two wasms
# have UNRELATED Candid interfaces, so icp's pre-install compatibility check
# refuses a plain `icp deploy` of the static-site recipe over a legacy
# frontend as BREAKING — before installing anything — and `--yes` must never
# be the answer (it pushes the upgrade through onto stable memory the new
# wasm cannot read). The one cure is `icp deploy frontend --mode reinstall`:
# the frontend holds no state. cold_start.sh and `deploy.sh local frontend`
# run it themselves on a LOCAL venue; deploy.sh names it for a remote one
# (law 8 — the operator runs it). `echo y |` answers the call's interactive
# confirmation, as every ad hoc call in this repo does. Never fails the
# caller: an unreadable canister reads as "not legacy", and icp's own check
# still refuses the bad upgrade.
mdx_frontend_is_legacy_asset_canister() {  # $1 = env, $2 = identity → 0 = the legacy asset-canister wasm answers
  echo y | icp canister call frontend api_version '()' --query -e "$1" --identity "$2" >/dev/null 2>&1
}
