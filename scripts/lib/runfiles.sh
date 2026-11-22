#!/usr/bin/env bash
# scripts/lib/runfiles.sh — where the deploy/seed scripts put scratch files.
#
# SOURCE THIS, never execute it.
#
# WHY THIS FILE EXISTS
# Every one of these paths used to be a FIXED NAME directly under /tmp:
# /tmp/uplands-oracle-prices.txt, /tmp/uplands-sim.log, and friends. Two
# properties of /tmp make that dangerous rather than merely untidy:
#
#   · it is world-writable, so any local user can create the name first, and
#   · it is STICKY (mode 1777), so a file another user owns CANNOT be removed
#     or replaced by us — our own `rm -f` fails silently. A plant is therefore
#     PERSISTENT, not a race we might win by running first.
#
# That mattered because deploy.sh read field 2 of the price snapshot straight
# into an awk PROGRAM TEXT, and awk has system(): arbitrary code execution as
# the operator, on the mainnet deploy path. The awk call sites are fixed
# separately (bind with -v, validate the value); this file removes the plant.
#
# .run/ lives inside the checkout (gitignored, see .gitignore), is owned by
# the operator and is not world-writable — so nobody else can pre-create these
# names and `rm -f` means what it says.
#
# WHY NOT `mktemp -d` PER RUN. Some of these files are the interface BETWEEN
# processes: inject_history.sh (a child process) writes the price snapshot,
# and deploy.sh / seed.sh / play_start.sh / simulate_trading.sh read it back.
# A per-run directory that only the parent knows about would silently break
# that hand-off — the readers would find nothing and fall back to stale
# hardcoded prices, which is exactly the failure play_start.sh's own comment
# describes (the sim walking a fresh AMM off its real price). One stable,
# operator-owned directory is the correct shape here; MDX_RUN_DIR is honoured
# from the environment and exported so a parent and its children always agree.

MDX_ROOT="${MDX_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MDX_RUN_DIR="${MDX_RUN_DIR:-$MDX_ROOT/.run}"
mkdir -p "$MDX_RUN_DIR" 2>/dev/null || true
export MDX_ROOT MDX_RUN_DIR

# ── Canonical scratch paths ────────────────────────────────────────
# Latest per-asset price snapshot, "SYMBOL PRICE" per line. Written by
# inject_history.sh (and upserted by deploy.sh / play_start.sh); read by
# deploy.sh, seed.sh, play_start.sh and simulate_trading.sh. UNTRUSTED as far
# as the readers are concerned — validate before use, never interpolate into
# program text.
MDX_ORACLE_PRICES="${MDX_ORACLE_PRICES:-$MDX_RUN_DIR/oracle-prices.txt}"
export MDX_ORACLE_PRICES

# Log/scratch files with a single writer and a single reader (the operator).
MDX_SIM_LOG="${MDX_SIM_LOG:-$MDX_RUN_DIR/sim.log}"
MDX_NETWORK_START_LOG="${MDX_NETWORK_START_LOG:-$MDX_RUN_DIR/network-start.log}"
MDX_PLAY_BUILD_LOG="${MDX_PLAY_BUILD_LOG:-$MDX_RUN_DIR/play-build.log}"
MDX_PLAY_FRONTEND_LOG="${MDX_PLAY_FRONTEND_LOG:-$MDX_RUN_DIR/play-frontend.log}"
# cold_start.sh's `icp deploy` output — written here so the failure arm can READ it
# back (an IC0207 reject names the frozen canister and its cure; task 1788665638).
MDX_COLD_DEPLOY_LOG="${MDX_COLD_DEPLOY_LOG:-$MDX_RUN_DIR/cold-start-deploy.log}"
export MDX_SIM_LOG MDX_NETWORK_START_LOG MDX_PLAY_BUILD_LOG MDX_PLAY_FRONTEND_LOG MDX_COLD_DEPLOY_LOG
