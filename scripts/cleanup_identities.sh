#!/bin/bash
# Prune throwaway test identities from ONE icp-cli identity store.
#
# Why this matters: `icp network start` seeds EVERY identity in the store it
# runs against (1,000,000 ICP + 1000T cycles each, minted through the CMC).
# The CMC refuses to mint more than 150,000T cycles per rolling hour, so once
# a store holds ~150 identities every fresh local network start fails with:
#   Failed to seed initial balances: ... "More than 150_000_000_000_000_000
#   cycles have been minted in the last 3600 seconds"
#
# WHICH store (task 1788508000): the one `icp` itself resolves.
#   - ICP_HOME set    -> that store (a factory seat's <worktree>/.icp-home).
#                        Every seat exports it in every shell; this script
#                        inherits it and acts on the SEAT store only.
#   - ICP_HOME unset  -> the machine-GLOBAL store
#                        (~/Library/Application Support/org.dfinity.icp-cli),
#                        which other projects, connectors and the operator's
#                        remote-deploy wallets share. From inside a git
#                        WORKTREE (not the primary checkout) that is almost
#                        always a forgotten `export ICP_HOME`, so the script
#                        REFUSES unless `--global` is passed - a seat wiping
#                        the global store by accident is the mirror of the
#                        bug this file exists to fix.
# The store acted on is printed before anything else happens.
#
# WHAT goes (task 1789609264): the two stores get OPPOSITE defaults.
#   - Seat store (ICP_HOME): everything outside the KEEP set is a multidex
#     leak by construction - only this repo ever writes there - so it goes.
#   - GLOBAL store (--global): other projects' deploy identities, the
#     operator's wallets and the cold recovery key live there WITHOUT backups
#     (the 2026-09-17 dry run listed multidex-recovery, opensaas-engine,
#     opensaas-minter and ost-connector-e2e among 244 deletions). So on
#     --global the sweep is POSITIVE: it deletes ONLY names matching the
#     DOOM_GLOBAL fixture shapes below (derived from the suites' identity
#     creations) and PROTECTS everything else by default, printing the
#     protected set every run. DELETE_EXTRA="name glob*" sweeps a protected
#     name deliberately; KEEP_GLOBAL is the belt for the wallets even if a
#     shape ever widens.
#
# Test identities are throwaway plaintext PEMs: every suite mints its own
# actors through tests/_lib.sh mdx_identity_new (virgin, deleted on EXIT;
# hygiene §6ae bans inline minting), so anything a suite left behind is a
# leak from before that helper and safe to delete. What must SURVIVE is the
# KEEP set below: the standing fixtures every suite signs with, plus the
# venue-lifetime names the bring-up scripts mint and then keep signing with
# for as long as the venue lives (ladder makers with resting orders, seed
# traders, fleet bots with funded balances) - deleting one of those orphans
# its on-venue positions and the next bring-up mints a stranger under the
# same name.
#
# Usage: bash scripts/cleanup_identities.sh [--dry-run] [--yes] [--global]
#   --dry-run  list what would be deleted (and what is kept), delete nothing
#   --yes      skip the confirmation prompt (run_tests.sh teardown)
#   --global   allow acting on the GLOBAL store from inside a worktree
#              (positive-pattern deletion there: only multidex fixture
#              shapes go, everything else is protected and listed)
#   KEEP_EXTRA="name other-*"    env: extra names/globs to keep (space-separated)
#   DELETE_EXTRA="name other-*"  env: --global only - names/globs to sweep
#              although they match no fixture shape (an ad hoc probe you
#              minted by hand); KEEP always wins over DELETE_EXTRA
#
# Exit codes: 0 swept or already clean; 1 store unreadable / still >=140
# left; 2 refused (global store from a worktree without --global).
set -u
export PATH="$HOME/.local/bin:$PATH"

# ── The KEEP set ──────────────────────────────────────────────────
# Exact names: the standing fixtures. anonymous is the built-in local
# controller; alice is promoted to a controller by cold_start.sh and is the
# admin identity every ops script signs with; alice/bob/charlie are minted by
# run_tests.sh / deploy.sh and 20+ suites sign with them; dave/eve complete
# scripts/seed.sh's five-trader set (seed_full / seed_book_around mint, fund
# and place the resting book as all five - hygiene §6ae calls the five the
# standing names). NOT here any more: swapper buyer taker battery - the
# suites that used them mint per run via mdx_identity_new now.
KEEP=(anonymous alice bob charlie dave eve)

# Globs: venue-lifetime names the bring-up scripts and fleet engines mint
# and keep signing with while the venue lives.
#   mdex-play-mm-*   play_start.sh LADDER_MAKERS (mdex-play-mm-1/2): the
#                    #play maker ladder's resting orders are theirs
#   mdex-seed-*      deploy.sh cloud_seed traders (mdex-seed-1..n)
#   simbot_*         deploy.sh cloud_bots / sim_trading.sh default BOT_PREFIX
#   localbot_* enginebot_* subnetbot_*
#                    scripts/lib/bots.sh passes BOT_PREFIX=<target>bot to the
#                    fleet engine (start_bots_<target>.sh)
#   mdxbot_*         trading_simulation.sh default BOT_PREFIX
#   trader_*         simulate_trading.sh's trader_NN (deleted by its own
#                    teardown; a live fleet's while it runs)
#   mb_*             seed_margin_book.sh's ID_PFX default - the positions it
#                    opens belong to these principals
KEEP_GLOB=('mdex-play-mm-*' 'mdex-seed-*' 'simbot_*' 'localbot_*' 'enginebot_*' 'subnetbot_*' 'mdxbot_*' 'trader_*' 'mb_*')

# Global-store only: the remote-deploy / fleet wallet identities the operator
# holds (BOT_IDENTITY=multidex, the engine and bots deploy identities), the
# cold recovery controller key (multidex-recovery), and the other projects'
# deploy identities that share the machine store (opensaas*, ost-*, any
# *-connector-*). None of these match a DOOM_GLOBAL shape, so the positive
# list already protects them; this is the BELT - kept unconditionally
# (exact names or globs) so no widened shape or DELETE_EXTRA can take them.
KEEP_GLOBAL=(multidex mdex-engine mdex-bots multidex-recovery 'opensaas*' 'ost-*' '*-connector-*')

# ── The positive DELETE list for the GLOBAL store ─────────────────
# On --global a name is deleted ONLY if it matches one of these anchored
# extended regexes (bash [[ =~ ]]) - or a DELETE_EXTRA glob - and never if
# keep_name() claims it first. Everything else is PROTECTED. Derived from the
# suites' identity creations (tests/*.sh; hygiene §6ah pins the list against
# every literal a suite mints):
#   <pfx>_<role>   the mdx_identity_new convention - a short lowercase prefix,
#                  an underscore, the role: amm_seed, ins_liq1, escape_seed,
#                  slip_whale, attr_maker, probe_u, h30_virgin_<suffix>,
#                  seed.sh's loadtrader_0001. Hyphenated names never match:
#                  every non-multidex identity seen on this machine is
#                  hyphenated (opensaas-engine, ost-connector-e2e).
#   hmtraderN      the retired load-test traders (hmtrader1..7 were still in
#                  the global store on 2026-09-17)
#   single words   the suites' bare $ID fixtures (test_liquidation's liqp,
#                  test_initial_margin's img*, test_insurance_fund's insf*,
#                  test_margin_pools' mpool*, ...) and the retired throwaways
#                  swapper/buyer/taker/battery - an explicit alternation, so
#                  a NEW bare name in a suite must be added here (or, better,
#                  renamed to the <pfx>_<role> shape) before --global sweeps it.
DOOM_GLOBAL=(
  '^[a-z0-9]{1,12}_[A-Za-z0-9_]+$'
  '^hmtrader[0-9]+$'
  '^(swapper|buyer|taker|battery|dusty|lvlu|b2bp|bunwind[0-9a-z]*|capm|cesc|creditslice|img[a-z]*|insf[0-9a-z]*|liqp|liqdir|mpool[0-9]*|pclose|shld|brdgtest|brdgrogue|vaultw)$'
)

# ── Arguments ─────────────────────────────────────────────────────
YES=false; DRY_RUN=false; GLOBAL=false
for a in "$@"; do
  case "$a" in
    --yes)     YES=true ;;
    --dry-run) DRY_RUN=true ;;
    --global)  GLOBAL=true ;;
    -h|--help) sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a (usage: $0 [--dry-run] [--yes] [--global])" >&2; exit 2 ;;
  esac
done

# ── Which store ───────────────────────────────────────────────────
GLOBAL_STORE="$HOME/Library/Application Support/org.dfinity.icp-cli"
if [ -n "${ICP_HOME:-}" ]; then
  STORE_KIND="ICP_HOME"; STORE_PATH="$ICP_HOME"
else
  STORE_KIND="GLOBAL"; STORE_PATH="$GLOBAL_STORE"
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || true)
  PRIMARY=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
  if [ -n "$TOPLEVEL" ] && [ -n "$PRIMARY" ] && [ "$TOPLEVEL" != "$PRIMARY" ] && ! $GLOBAL; then
    echo "refusing to sweep the GLOBAL store from inside a worktree ($TOPLEVEL):" >&2
    echo "  ICP_HOME is unset, so 'icp identity delete' would act on $GLOBAL_STORE" >&2
    echo "  - the machine-shared store, not this seat's. Export ICP_HOME=\"$TOPLEVEL/.icp-home\"" >&2
    echo "  for the seat store, or pass --global if the global store really is the target." >&2
    exit 2
  fi
fi
echo "identity store: $STORE_PATH ($STORE_KIND)"

# Current identity names; the default identity's row is marked "* name".
ALL=$(icp identity list 2>/dev/null | sed 's/^\*//' | awk '{print $1}')
if [ -z "$ALL" ]; then
  echo "no identities found in $STORE_PATH (is icp on PATH? does the store exist?)" >&2
  exit 1
fi

keep_name() {   # keep_name <identity> -> 0 iff it must survive
  local name="$1" k
  for k in "${KEEP[@]}"; do [ "$name" = "$k" ] && return 0; done
  for k in "${KEEP_GLOB[@]}"; do case "$name" in $k) return 0 ;; esac; done
  if [ "$STORE_KIND" = "GLOBAL" ]; then
    for k in "${KEEP_GLOBAL[@]}"; do case "$name" in $k) return 0 ;; esac; done
  fi
  for k in ${KEEP_EXTRA:-}; do case "$name" in $k) return 0 ;; esac; done
  return 1
}

doom_name() {   # doom_name <identity> -> 0 iff the sweep may delete it (asked only after keep_name said no)
  local name="$1" k
  [ "$STORE_KIND" = "GLOBAL" ] || return 0    # a seat store: everything outside KEEP is a multidex leak
  for k in "${DOOM_GLOBAL[@]}"; do [[ "$name" =~ $k ]] && return 0; done
  for k in ${DELETE_EXTRA:-}; do case "$name" in $k) return 0 ;; esac; done
  return 1
}

DOOMED=(); KEPT=(); PROTECTED=()
for name in $ALL; do
  if keep_name "$name"; then KEPT+=("$name")
  elif doom_name "$name"; then DOOMED+=("$name")
  else PROTECTED+=("$name"); fi
done

total=$(printf '%s\n' "$ALL" | wc -l | tr -d ' ')
echo "keeping ${#KEPT[@]}: ${KEPT[*]}"
echo "  (exact: ${KEEP[*]}; globs: ${KEEP_GLOB[*]}${KEEP_EXTRA:+; extra: $KEEP_EXTRA}$([ "$STORE_KIND" = "GLOBAL" ] && echo "; global belt: ${KEEP_GLOBAL[*]}"))"
if [ "$STORE_KIND" = "GLOBAL" ]; then
  # Always printed on the global store, even when empty: the protected set is
  # the sweep's statement of what it refused to judge.
  echo "protected ${#PROTECTED[@]} (GLOBAL store: no multidex fixture shape - left alone; DELETE_EXTRA=\"name glob*\" sweeps one deliberately):${PROTECTED[*]:+ ${PROTECTED[*]}}"
  echo "  (fixture shapes: ${DOOM_GLOBAL[*]}${DELETE_EXTRA:+; extra: $DELETE_EXTRA})"
fi
if [ ${#DOOMED[@]} -eq 0 ]; then
  echo "identity store already clean ($total identities, nothing matches a sweepable shape outside the KEEP set)"
  exit 0
fi

if $DRY_RUN; then
  echo "DRY RUN - would delete ${#DOOMED[@]} of $total identities from $STORE_PATH:"
  printf '  %s\n' "${DOOMED[@]}"
  exit 0
fi

echo "deleting ${#DOOMED[@]} of $total identities from $STORE_PATH"
if ! $YES; then
  read -p "Proceed? [y/N] " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "aborted"
    exit 0
  fi
fi

deleted=0
for name in "${DOOMED[@]}"; do
  if echo "y" | icp identity delete "$name" >/dev/null 2>&1; then
    deleted=$((deleted + 1))
  else
    echo "  ! failed to delete: $name" >&2
  fi
done

left=$(icp identity list 2>/dev/null | wc -l | tr -d ' ')
echo "deleted $deleted; $left identities remain in $STORE_PATH"
if [ "$left" -ge 140 ]; then
  echo "WARNING: still >=140 identities — fresh 'icp network start' breaks at ~150 (CMC mint cap)${PROTECTED[*]:+; ${#PROTECTED[@]} of them protected (no fixture shape) - sweep the ones you know with DELETE_EXTRA=\"...\"}" >&2
  exit 1
fi
