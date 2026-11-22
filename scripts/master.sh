#!/bin/bash
# UPLANDS DEX — Master bring-up script.
#
# Single command: takes UPLANDS from any state (replica down, frozen
# canister, fresh checkout) to the repo's DEFAULT deployment — a running
# #play exchange: seeded $5,125,000 AMM vault, $144k insurance fund, live-feed
# prices, maker ladder, and the sim bots hammering it.
#
# Equivalent to:
#   icp network start
#   icp deploy
#   bash scripts/top_up_cycles.sh --amount 100t
#   bash scripts/play_start.sh          # reinstall + play seeding (AMM/insurance/bots)
#
# All driven through cold_start.sh's orchestration (default mode: play),
# just with the demo-depth 14-day history backdrop.
#
# Usage: bash scripts/master.sh
#
# (For tweakable runs — different mode, no-simulate, partial deploy —
# call scripts/cold_start.sh directly. The #dev fixture modes need
# DEPLOY_MODE = #dev in src/backend/main.mo first.)

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec bash "$SCRIPT_DIR/cold_start.sh" \
  --mode play \
  --history-days 14 \
  --top-up-amount 100t
