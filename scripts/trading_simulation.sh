#!/usr/bin/env bash
# trading_simulation.sh — strategy-driven trading simulation for MULTI/DEX.
#
# Supersedes the two older simulators (simulate_trading.sh, sim_trading.sh),
# which are kept for now because sim_trading.sh is still driving the live
# subnet. THIS script is the one to run locally; switch the subnet over at
# the next reset.
#
# WHAT'S DIFFERENT: the old bots were all the same bot — random side,
# random market, random size, spot only. A venue populated by coin-flippers
# has no open interest, no directional flow, and (the real gap) NEVER
# touches margin: the borrow engine, the liquidation batch, the 5% penalty
# → insurance accrual and the liquidation heatmap were unexercised in play
# mode, so the map could only ever render empty.
#
# Here each bot runs ONE archetype from scripts/bot_strategies.sh, and by
# default 8 of 12 trade on MARGIN:
#
#   market maker  spot    two-sided quotes near the mark (the liquidity)
#   scalper       spot    small fast takers (the volume floor)
#   trend         2.0×    follows the last hour — builds one-sided interest
#   mean-revert   2.0×    fades stretch — takes the OTHER side of the trend
#   swing         1.5×    slow, patient, holds — populates the outer bands
#   degen         2.4×    rides the maintenance edge, gets liquidated,
#                         re-arms — keeps the liquidation machinery live
#
# The trend/revert pairing matters: opposed cohorts give the heatmap two
# populated wings (long AND short open interest) instead of one.
#
# ON THE LIQUIDATION HEATMAP AND BOT COUNT. The map's headline figures
# (positionsTotal, total long/short notional) populate as soon as bots hold
# positions. Its per-BAND detail is k-anonymised: a 1% band is disclosed
# only once at least HEAT_K_FULL = 5 positions share it (10 on the "coarse"
# tier), so individual traders can't be reverse-engineered from it. With a
# 12-bot fleet spread over 4 markets × 60 bands nothing clusters that
# densely, so `buckets` comes back empty even though the totals are right —
# that is the privacy floor doing its job, not a fault. Raise --bots (or
# wait for real players) to see bands fill; clusters form fastest among
# same-archetype bots on the same market, which share a leverage and
# therefore a liquidation band.
#
# Usage:
#   bash scripts/trading_simulation.sh [--bots N] [--interval S] [--no-margin]
#   IC_ENV=subnet BOT_IDENTITY=multidex bash scripts/trading_simulation.sh 12 2
#
# Local: the anonymous controller seeds balances. Remote: set IC_ENV and
# BOT_IDENTITY (a controller) — the self-serve faucet is dead on #play.
#
set -u
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."

BOTS=12
INTERVAL=4
USE_MARGIN=true
POOL_FUND_USD=${POOL_FUND_USD:-25000}     # collateral each margin bot commits
POOL_FLOOR_USD=${POOL_FLOOR_USD:-6000}    # below this, top the pool back up
REFILL_CHECK_S=${REFILL_CHECK_S:-60}
MONITOR_S=${MONITOR_S:-20}

while [ $# -gt 0 ]; do
  case "$1" in
    # Recorded so the VENUE is visible in `ps`. The functional target still
    # comes from IC_ENV/BOT_IDENTITY (set by scripts/lib/bots.sh); this flag
    # exists so a running fleet can be identified without guessing, which a
    # bare pattern could never do — it is why the live subnet fleet was
    # pattern-killed twice. Start via scripts/start_bots_<target>.sh.
    --target)    MDX_TARGET="$2"; shift 2 ;;
    --bots)      BOTS="$2"; shift 2 ;;
    --interval)  INTERVAL="$2"; shift 2 ;;
    --no-margin) USE_MARGIN=false; shift ;;
    --help|-h)   sed -n '3,/^set -u/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    # Positional, for parity with the old runner's `sim_trading.sh 12 2`.
    ''|*[!0-9]*) echo "Unknown flag: $1" >&2; exit 1 ;;
    *) if [ "$BOTS" = 12 ]; then BOTS="$1"; else INTERVAL="$1"; fi; shift ;;
  esac
done

# ── Target network / funding posture (mirrors sim_trading.sh) ──────
ENV_FLAG=""; REMOTE=false
if [ -n "${IC_ENV:-}" ]; then ENV_FLAG="-e ${IC_ENV}"; REMOTE=true; fi
CE_IDENTITY=""
[ -f scripts/.cloud-engine.conf ] && . scripts/.cloud-engine.conf 2>/dev/null
[ -n "${BOT_IDENTITY:-}" ] && CE_IDENTITY="$BOT_IDENTITY"
# The FUNDING identity (task 1789609263): fund_call and bal_of sign as
# FUND_IDENTITY — the controller-designated funding authority handed in as
# MDX_FUNDING_IDENTITY by scripts/lib/bots.sh (the operator's `mdex-bots`
# key) — and only fall back to the controller identity above when none is
# set. Local: anonymous unless overridden. Nothing below reads CE_IDENTITY /
# BOT_IDENTITY for a refill.
if $REMOTE; then FUND_IDENTITY="${MDX_FUNDING_IDENTITY:-$CE_IDENTITY}"
else             FUND_IDENTITY="${MDX_FUNDING_IDENTITY:-anonymous}"; fi
if $REMOTE && [ -n "${MDX_FUNDING_IDENTITY:-}" ]; then
  echo "funding: refills sign as the FUNDING AUTHORITY '$FUND_IDENTITY' (the controller key signs no refill)"
elif $REMOTE && [ -n "$FUND_IDENTITY" ]; then
  echo "funding: no MDX_FUNDING_IDENTITY — refills sign as the CONTROLLER identity '$FUND_IDENTITY'; designate a funding authority (setFundingAuthority, task 1789609263)"
fi

MARKETS=("BTC-ICPUSD" "ETH-ICPUSD" "SOL-ICPUSD" "ICP-ICPUSD")
export ENV_FLAG INTERVAL
# shellcheck source=scripts/bot_strategies.sh
. scripts/bot_strategies.sh

# Distinct identity prefix: the older simulators own trader_NN / simbot_N,
# and one of them may be running against another target from this same
# checkout. Sharing principals would mean two schedulers fighting over one
# wallet (and one set of margin pools).
# Per-TARGET by default (scripts/lib/bots.sh passes BOT_PREFIX=<target>bot), so
# a local fleet and an engine fleet — both running THIS script — cannot share
# principals either; whichever stopped first would otherwise delete the other's
# identities in its cleanup trap. Falls back to a fixed name when run directly.
BOT_PREFIX="${BOT_PREFIX:-mdxbot}"

# ── Roster ────────────────────────────────────────────────────────
# Repeating pattern so ANY bot count keeps a sane mix (every prefix of this
# list contains liquidity, volume and both directional cohorts).
# HALF MARGIN, HALF SPOT. Every 12-slot cycle: 3 maker + 3 scalper (spot,
# the liquidity and the volume floor) and 2 trend + 2 revert + 1 swing +
# 1 degen (margin, the open interest and the liquidation machinery). Any
# prefix of the list keeps roughly that mix, so a short fleet is still
# balanced. The trend/revert pairing is deliberate: opposed cohorts give the
# heatmap two populated wings instead of one.
ARCHETYPES=(maker trend scalper revert maker swing scalper degen maker trend scalper revert)
archetype_of() { echo "${ARCHETYPES[$(( ($1 - 1) % ${#ARCHETYPES[@]} ))]}"; }
uses_margin()  { case "$1" in trend|revert|swing|degen) return 0 ;; *) return 1 ;; esac; }
leverage_of()  {
  case "$1" in
    trend)  echo 2.0 ;;
    revert) echo 2.0 ;;
    swing)  echo 1.5 ;;
    degen)  echo 2.4 ;;
    *)      echo 0   ;;
  esac
}

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; DIM='\033[0;90m'; NC='\033[0m'
log() { echo -e "${CYAN}▶${NC} $1"; }
ok()  { echo -e "  ${GREEN}✓${NC} $1"; }

# ── Funding ───────────────────────────────────────────────────────
# $100k VALUE per bot — parity with a real player's lifetime deposit
# allowance, so bots can't dwarf humans on the leaderboard. Refills are
# absolute SETs, which record as external flow and raise the bot's
# leaderboard baseline: a refilled bot cannot show the top-up as profit.
# SPOT bots keep the $100k parity ($40k cash + $15k x 4 assets).
SEED_CASH=${SEED_CASH:-40000}
SEED_ASSET_USD=${SEED_ASSET_USD:-15000}
FLOOR_CASH=${FLOOR_CASH:-10000}
FLOOR_ASSET_USD=${FLOOR_ASSET_USD:-4000}
# MARGIN bots additionally have to fund a pool with POOL_FUND_USD of
# collateral, so their cash leg is sized to cover that plus a working buffer;
# without this they fund the pool and have nothing left to trade the spot leg
# with. Deliberate departure from the flat $100k: bots carry no leaderboard
# weight (leaderRowFor excludes principals with no profile — the sim bots are
# controller-funded and never sign in through a browser), and a production-
# scale venue needs production-scale open interest.
MARGIN_SEED_CASH=${MARGIN_SEED_CASH:-$(awk -v p="${POOL_FUND_USD:-25000}" 'BEGIN{ printf "%.0f", p + 25000 }')}
MARGIN_FLOOR_CASH=${MARGIN_FLOOR_CASH:-$(awk -v p="${POOL_FUND_USD:-25000}" 'BEGIN{ printf "%.0f", p * 0.35 }')}

fund_call() {   # setTestBalance as the FUNDING identity (never the controller key)
  icp canister call --identity "${FUND_IDENTITY:-anonymous}" $ENV_FLAG backend "$@" >/dev/null 2>&1 || true
}
bal_of() {      # the refill loop's read — same identity as fund_call (getTestBalance is scoped to self / controller / the funding authority)
  icp canister call --query --identity "${FUND_IDENTITY:-anonymous}" $ENV_FLAG backend getTestBalance \
    "(principal \"$1\", \"$2\")" 2>&1 | grep -oE "[0-9][0-9_]*" | head -1 | tr -d '_'
}

fund_bot() {
  local p="$1" mode="$2" id="$3" arche="${4:-}" m t px seed_q bal val cash floor
  # Margin bots need the pool collateral on top of a working float — see
  # MARGIN_SEED_CASH. Archetype is passed by the caller; absent (an old call
  # site) falls back to the spot numbers, which are never too large.
  if [ -n "$arche" ] && uses_margin "$arche"; then
    cash="$MARGIN_SEED_CASH"; floor="$MARGIN_FLOOR_CASH"
  else
    cash="$SEED_CASH"; floor="$FLOOR_CASH"
  fi
  if [ "$mode" = seed ]; then
    fund_call setTestBalance "(principal \"$p\", \"ICPUSD\", $(e8 $cash))"
  else
    bal=$(bal_of "$p" ICPUSD)
    if [ -n "$bal" ] && [ "$bal" -lt "$(e8 $floor)" ] 2>/dev/null; then
      fund_call setTestBalance "(principal \"$p\", \"ICPUSD\", $(e8 $cash))"
      echo "$(date +%H:%M:%S)  ⛽ $id refilled ICPUSD"
    fi
  fi
  for m in "${MARKETS[@]}"; do
    t=$(base_of "$m"); px=$(mid "$m"); [ -z "$px" ] && continue
    seed_q=$(awk -v p="$px" -v u="$SEED_ASSET_USD" 'BEGIN{ printf "%.6f", u/p }')
    if [ "$mode" = seed ]; then
      fund_call setTestBalance "(principal \"$p\", \"$t\", $(e8 "$seed_q"))"
    else
      bal=$(bal_of "$p" "$t"); [ -z "$bal" ] && continue
      val=$(awk -v b="$bal" -v px="$px" 'BEGIN{ printf "%.0f", (b/100000000)*px }')
      if [ "$val" -lt "$FLOOR_ASSET_USD" ] 2>/dev/null; then
        fund_call setTestBalance "(principal \"$p\", \"$t\", $(e8 "$seed_q"))"
        echo "$(date +%H:%M:%S)  ⛽ $id refilled $t (~\$$val left)"
      fi
    fi
  done
}

# ── Bot loop ──────────────────────────────────────────────────────
# One process per bot. Each owns its margin pool id as ordinary shell
# state, so no IPC and no shared files.
bot_loop() {
  local i="$1" id="$2" arch="$3" lev="$4" pool="" market
  # Each margin bot concentrates on ONE market: a real leveraged trader
  # carries a book, not a lottery ticket, and per-bot concentration is what
  # makes the heatmap's per-market bands meaningful.
  #
  # The extra (i-1)/4 term rotates the pairing every four bots. Without it,
  # a plain (i-1) % 4 aliases against the 12-entry archetype pattern (both
  # cycle on a multiple of 4), which pins each archetype to the same markets
  # forever — measured: BTC got no trend or degen bot at all, and ICP only a
  # degen. The rotation spreads every archetype across all four books.
  market="${MARKETS[$(( ((i - 1) + (i - 1) / ${#MARKETS[@]}) % ${#MARKETS[@]} ))]}"

  if uses_margin "$arch" && $USE_MARGIN; then
    pool=$(mg_ensure_pool "$id" "$arch-$i" false)
    [ -n "$pool" ] && mg_fund "$id" "$pool" "$POOL_FUND_USD"
  fi

  while true; do
    case "$arch" in
      maker)   strat_market_maker "$id" ;;
      scalper) strat_scalper "$id" ;;
      trend|revert|swing|degen)
        if [ -n "$pool" ]; then
          # A liquidation seizes collateral; top the pool back up from the
          # wallet so the bot keeps trading instead of going quiet forever.
          mg_maintain_pool "$id" "$pool" "$POOL_FLOOR_USD" "$POOL_FUND_USD" >/dev/null
          case "$arch" in
            trend)  strat_trend       "$id" "$pool" "$lev" "$market" ;;
            revert) strat_mean_revert "$id" "$pool" "$lev" "$market" ;;
            swing)  strat_swing       "$id" "$pool" "$lev" "$market" ;;
            degen)  strat_degen       "$id" "$pool" "$lev" "$market" ;;
          esac
        else
          # Pool creation failed (margin disabled / unfunded) — stay useful.
          strat_scalper "$id"
        fi ;;
    esac
    # Directional bots think slowly; liquidity/volume bots act fast. Both
    # still breathe with the shared activity regime.
    case "$arch" in
      maker|scalper) bot_sleep "$INTERVAL" 0.3 ;;
      *)             bot_sleep "$((INTERVAL * 3))" 2.0 ;;
    esac
  done
}

PIDS=()
cleanup() {
  echo ""; echo "stopping bots…"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  pkill -P $$ 2>/dev/null
  # Every stored identity is re-seeded at each `icp network start`, and
  # >~150 of them trip the CMC mint cap and break network start machine-wide
  # (scripts/cleanup_identities.sh). Drop ours on the way out.
  echo "deleting $BOTS $BOT_PREFIX identities…"
  for i in $(seq 1 "$BOTS"); do
    echo "y" | icp identity delete "${BOT_PREFIX}_$i" >/dev/null 2>&1 || true
  done
  exit 0
}
trap cleanup INT TERM

# ── Bring-up ──────────────────────────────────────────────────────
echo ""
log "MULTI/DEX trading simulation — $BOTS bots, interval ${INTERVAL}s$($REMOTE && echo " (remote: ${IC_ENV})")"
$USE_MARGIN || log "margin DISABLED (--no-margin) — spot archetypes only"

BOT_PRINCIPALS=()
log "creating + funding identities (spot ~\$100k; margin ~\$$(awk -v c="$MARGIN_SEED_CASH" 'BEGIN{printf "%.0fk", (c+60000)/1000}') incl. \$${POOL_FUND_USD:-25000} pool collateral)…"
for i in $(seq 1 "$BOTS"); do
  id="${BOT_PREFIX}_$i"
  icp identity new "$id" --storage plaintext >/dev/null 2>&1 || true
  p=$(icp identity principal --identity "$id" 2>/dev/null | tail -1)
  BOT_PRINCIPALS+=("$p")
  fund_bot "$p" seed "$id" "$(archetype_of "$i")"
  # NO getMyProfile here — deliberately. A profile is what marks an account
  # as a COMPETITOR: leaderRowFor ranks profiled accounts and treats
  # profileless ones as operator machinery, and resetSeason's finalTop
  # applies the same rule. The old "materialise the friendly username" call
  # put every bot on the public leaderboard and, worse, into the permanent
  # season record. Bots trade; they do not compete.
done
ok "$BOTS identities funded"

log "launching bots…"
for i in $(seq 1 "$BOTS"); do
  arch=$(archetype_of "$i")
  bot_loop "$i" "${BOT_PREFIX}_$i" "$arch" "$(leverage_of "$arch")" &
  PIDS+=($!)
  printf "  ${DIM}%-10s${NC} %-8s %s\n" "${BOT_PREFIX}_$i" "$arch" \
    "$(uses_margin "$arch" && $USE_MARGIN && echo "margin $(leverage_of "$arch")×" || echo spot)"
done

replenisher_loop() {
  while true; do
    sleep "$REFILL_CHECK_S"
    for i in $(seq 1 "$BOTS"); do fund_bot "${BOT_PRINCIPALS[$((i - 1))]}" refill "${BOT_PREFIX}_$i" "$(archetype_of "$i")"; done
  done
}
replenisher_loop & PIDS+=($!)
ok "${#PIDS[@]} loops running (refill check every ${REFILL_CHECK_S}s). Ctrl-C to stop."
echo ""

# ── Monitor ───────────────────────────────────────────────────────
# Reports the two things this rewrite exists to produce: trade throughput,
# and whether the MARGIN machinery is actually being exercised — open
# positions, notional split long/short, and cumulative liquidations.
last_trade_id() {
  icp canister call --query --identity anonymous $ENV_FLAG backend getMarketStatus "(\"$1\")" 2>&1 \
    | grep -oE "lastTradeId = [0-9_]+" | grep -oE "[0-9_]+" | sed 's/_//g' | head -1
}
LAST_IDS=(0 0 0 0)
read_ids() { local i v; for i in "${!MARKETS[@]}"; do v=$(last_trade_id "${MARKETS[$i]}"); [ -n "$v" ] && LAST_IDS[$i]=$v; done; }
sum_ids() { local s=0 v; for v in "${LAST_IDS[@]}"; do s=$((s + v)); done; echo "$s"; }

# Heatmap occupancy across all markets — positions and long/short notional.
heat_summary() {
  local m raw pos long short tp=0 tl=0 ts=0
  for m in "${MARKETS[@]}"; do
    raw=$(icp canister call --query --identity anonymous $ENV_FLAG backend getMarginHeatmap "(\"$m\")" 2>&1 | tr -d '_')
    pos=$(echo "$raw"   | grep -oE 'positionsTotal = [0-9]+'        | grep -oE '[0-9]+' | head -1)
    long=$(echo "$raw"  | grep -oE 'totalLongNotionalUsd = [0-9]+'  | grep -oE '[0-9]+' | head -1)
    short=$(echo "$raw" | grep -oE 'totalShortNotionalUsd = [0-9]+' | grep -oE '[0-9]+' | head -1)
    tp=$((tp + ${pos:-0}))
    tl=$(awk -v a="$tl" -v b="${long:-0}"  'BEGIN{ printf "%.0f", a + b/100000000 }')
    ts=$(awk -v a="$ts" -v b="${short:-0}" 'BEGIN{ printf "%.0f", a + b/100000000 }')
  done
  echo "$tp $tl $ts"
}
liq_count() {
  icp canister call --query --identity anonymous $ENV_FLAG backend getRecentEvents "(400 : nat)" 2>&1 \
    | grep -ciE "liquidat" || true
}

read_ids; prev=$(sum_ids)
while true; do
  sleep "$MONITOR_S"
  read_ids; cur=$(sum_ids)
  rate=$(awk -v d="$((cur - prev))" -v w="$MONITOR_S" 'BEGIN{ printf "%.1f", d/w }')
  read -r hp hl hs <<<"$(heat_summary)"
  printf "%s  fills %s in %ss → %s/s  |  margin: %s positions, \$%s long / \$%s short  |  liq events %s  |  mood ×%s\n" \
    "$(date +%H:%M:%S)" "$((cur - prev))" "$MONITOR_S" "$rate" "${hp:-0}" "${hl:-0}" "${hs:-0}" "$(liq_count)" "$(activity)"
  prev=$cur
done

# NOTE ON LIVE EDITS: bash reads this file incrementally from a shared inode.
# Editing it IN PLACE while a fleet is executing it corrupts the running
# parse at whatever offset the interpreter has reached (observed 2026-08-01:
# the Phase II starter died at a shifted token mid-funding). Edit via
# write-temp + atomic rename (mv/os.replace), or stop the fleet first.
