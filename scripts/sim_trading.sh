#!/bin/bash
# sim_trading.sh — parallel load generator for the DEX (TEST MODE ONLY).
#
# Targets a sustained trade-EXECUTION rate (default ~5 fills/sec on a local
# replica) across every market by running many bots in parallel:
#   • MAKER bots continuously post UNPROTECTED limit liquidity near the
#     touch (cancel-and-replace, so the book stays bounded), giving takers
#     something to fill against immediately.
#   • TAKER bots fire market orders + cross-market swaps that hit that
#     liquidity → immediate trades.
# A monitor prints the achieved executions/sec (per-market lastTradeId
# delta) every few seconds so you can tune the rate. Ctrl-C stops all bots.
#
#   usage: bash scripts/sim_trading.sh [total_bots] [per_bot_interval_s]
#          bash scripts/sim_trading.sh           # defaults 10/3 → ~5 fills/s
#          bash scripts/sim_trading.sh 12 1      # hotter: ~25 fills/s
#
# Local replica (default): the anonymous controller seeds bot balances.
# Remote/cloud engine: set IC_ENV=<environment> (engine | subnet) to target a deployed canister;
# bots self-fund via the public faucet (addTestTokens) — e.g.
#          IC_ENV=engine bash scripts/sim_trading.sh 6 4   # or IC_ENV=subnet
# On mainnet each update call is ~2s, so expect a far lower fill rate and use
# a larger interval. The faucet (and so the whole sim) only works while the
# backend is in test mode; in production the bots can't fund themselves.
#
set -u
export PATH="$HOME/.local/bin:$PATH"

# Target network. Unset/empty = the icp default (local replica). Set IC_ENV=<env>
# (or any env name) to point the bots at a deployed canister — e.g. a cloud
# engine: `IC_ENV=engine|subnet bash scripts/sim_trading.sh`. On a remote/cloud target the
# bots self-fund via the faucet (addTestTokens, test mode only) since the
# controller-only setTestBalance isn't available to them.
ENV_FLAG=""; REMOTE=false
if [ -n "${IC_ENV:-}" ]; then ENV_FLAG="-e ${IC_ENV}"; REMOTE=true; fi

# Funding identity for remote targets: on a #play target the self-serve
# faucet is DEAD (dev-only), so remote bots must be funded by a controller.
# BOT_IDENTITY (env) wins — set it when one checkout serves several stacks
# (cloud engine + dedicated subnet) so the bots don't have to inherit the
# cloud-engine conf's owner:  BOT_IDENTITY=multidex IC_ENV=subnet bash scripts/sim_trading.sh 12 2
# Falls back to the conf's CE_IDENTITY (the engine owner). Without either,
# the remote path self-funds via the faucet (fine on a dev-postured remote).
CE_IDENTITY=""
[ -f "$(dirname "$0")/.cloud-engine.conf" ] && . "$(dirname "$0")/.cloud-engine.conf" 2>/dev/null
[ -n "${BOT_IDENTITY:-}" ] && CE_IDENTITY="$BOT_IDENTITY"

# The FUNDING identity (task 1789609263): every refill (fund_call) and every
# balance read the refill loop makes (bal_of) signs as FUND_IDENTITY — the
# controller-designated funding authority (setFundingAuthority; the
# operator's `mdex-bots` key) handed in as MDX_FUNDING_IDENTITY by
# scripts/lib/bots.sh — and only FALLS BACK to the controller identity above
# when none is set (the pre-1789609263 posture, named in the banner below).
# Local: anonymous, the local controller, unless overridden. Nothing below
# this line reads CE_IDENTITY / BOT_IDENTITY for a refill.
if $REMOTE; then FUND_IDENTITY="${MDX_FUNDING_IDENTITY:-$CE_IDENTITY}"
else             FUND_IDENTITY="${MDX_FUNDING_IDENTITY:-anonymous}"; fi

# Identity namespace for THIS fleet. Two fleets (e.g. the live subnet and a
# cloud engine) must not share one: the names are global to the icp identity
# store, so they would trade as the SAME principals and — worse — whichever
# fleet stops first DELETES the shared identities in its cleanup trap and
# breaks the other. Give each fleet its own: BOT_PREFIX=enginebot …
BOT_PREFIX="${BOT_PREFIX:-simbot}"

# Defaults tuned for ~5 executions/sec across the 4 markets. The achieved
# fill rate scales roughly with bots/interval (each order tends to produce
# >1 fill — sweeping market orders + crossing maker quotes + swaps), so for
# a hotter feed drop the interval or add bots: `sim_trading.sh 12 1` ≈ 25/s.
# Flag form, so the VENUE this fleet drives is visible in `ps` (the functional
# target still comes from IC_ENV). Positional form is preserved for anything
# that still calls `sim_trading.sh 12 2` directly. Start via
# scripts/start_bots_<target>.sh, which sets both and records a PID file —
# this fleet drives multidex.ai and must never be pattern-killed.
MDX_TARGET="${MDX_TARGET:-}"
_pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --target)   MDX_TARGET="$2"; shift 2 ;;
    --bots)     _pos[0]="$2";    shift 2 ;;
    --interval) _pos[1]="$2";    shift 2 ;;
    *)          _pos+=("$1");    shift ;;
  esac
done
BOTS=${_pos[0]:-10}
INTERVAL=${_pos[1]:-3}
# Per-bot sleep is jittered (0.5×–1.5× INTERVAL) so the bots desync and the
# aggregate fill rate is smooth rather than bursty.
jitter() { awk -v i="$INTERVAL" -v r="$RANDOM" 'BEGIN{printf "%.2f", i*(0.5 + (r%100)/100.0)}'; }

# ── Activity model: volume that breathes like a real venue ─────────────
# A shared, deterministic function of WALL-CLOCK time (no IPC needed), so
# every bot speeds up and slows down together — correlation is what makes
# aggregate volume look organic rather than a flat line with noise:
#   • regime: each 5-min bucket hashes to calm ×0.25 (30%), normal ×1 (40%),
#     busy ×2.2 (20%), or frenzy ×5 (10%) — quiet spells and bursts arrive
#     in blocks, like sessions on a real exchange;
#   • tide: two slow sines (1h + 14m) undulate underneath, so even a long
#     "normal" stretch drifts rather than plateaus.
# Result is a multiplier ~0.15–7×: sleeps divide by it, taker size scales
# mildly with it (bursts print bigger tape), frenzies double-fire.
activity() {
  awk -v t="$(date +%s)" 'BEGIN{
    b = int(t / 300);
    h = (b * 2654435761) % 4294967296; p = (h % 1000) / 10.0;
    if (p < 30) r = 0.25; else if (p < 70) r = 1.0; else if (p < 90) r = 2.2; else r = 5.0;
    w = 1 + 0.45 * sin(2 * 3.14159265 * t / 3600) + 0.25 * sin(2 * 3.14159265 * t / 840);
    m = r * w; if (m < 0.15) m = 0.15;
    printf "%.3f", m }'
}
# Activity-scaled sleep: INTERVAL × jitter ÷ activity.
asleep() { awk -v i="$INTERVAL" -v r="$RANDOM" -v a="$(activity)" 'BEGIN{
  s = i * (0.5 + (r % 100) / 100.0) / a; if (s < 0.2) s = 0.2; printf "%.2f", s }'; }
MAKER_FRACTION_DENOM=3          # ~1 in 3 bots is a maker; rest are takers
MARKETS=("BTC-ICPUSD" "ETH-ICPUSD" "SOL-ICPUSD" "ICP-ICPUSD")

adm() { icp canister call --identity anonymous $ENV_FLAG backend "$@" 2>&1; }
# Integer-money: backend ledger is Nat base units (10^8). Send money args as
# base-unit integers (e8); mid() divides the parsed Nat markPrice back to human.
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
unit_for() { case "$1" in
  "BTC-ICPUSD") echo 0.02 ;; "ETH-ICPUSD") echo 0.5 ;;
  "SOL-ICPUSD") echo 20   ;; "ICP-ICPUSD") echo 200 ;; *) echo 1 ;;
esac; }
base_of() { echo "${1%-ICPUSD}"; }
# Reads MUST pass --query: these are query methods, and without the flag the
# CLI sends them as UPDATE calls — which a cloud engine's inspect gate REFUSES
# for the anonymous caller (locally anonymous is the controller, masking it).
# Seen on OpenCloud 2026-07-08: makers never quoted (mid() empty) and the
# stats monitor read 0 trades forever while takers were actually trading.
mid() { icp canister call --query --identity anonymous $ENV_FLAG backend getMarkets "()" 2>&1 \
          | tr -d '\n' | tr '}' '\n' | grep "\"$1\"" \
          | grep -oE "markPrice = [0-9_.]+" | grep -oE "[0-9][0-9_.]*" | sed 's/_//g' | head -1 \
          | awk 'NF{ printf "%.8f", $1/100000000 }'; }   # Nat base units -> human
last_trade_id() { icp canister call --query --identity anonymous $ENV_FLAG backend getMarketStatus "(\"$1\")" 2>&1 \
          | grep -oE "lastTradeId = [0-9_]+" | grep -oE "[0-9_]+" | sed 's/_//g' | head -1; }

PIDS=()
cleanup() {
  echo ""; echo "stopping bots…"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  pkill -P $$ 2>/dev/null
  # Teardown: drop the simbot identities from the global icp-cli store.
  # Every stored identity gets seeded at each `icp network start`, and
  # >~150 identities trip the CMC mint cap and break network start
  # machine-wide (see scripts/cleanup_identities.sh). Next run recreates
  # them (fresh principals) and re-funds them anyway.
  echo "deleting $BOTS ${BOT_PREFIX} identities…"
  for i in $(seq 1 "$BOTS"); do
    echo "y" | icp identity delete "${BOT_PREFIX}_$i" >/dev/null 2>&1 || true
  done
  exit 0
}
trap cleanup INT TERM

# ── Funding: seed once, then REPLENISH forever ─────────────────────────
# Bots bleed by construction — every fill pays taker fees to the treasury and
# random-walk trading against an oracle-anchored AMM pays the spread — so a
# one-shot seed decays to empty wallets, silently-failing orders, and a
# volume cliff (seen on the engine). A background replenisher polls each
# bot's balances (getTestBalance is a public query) and RESETS any token that
# falls below its floor back to the seed level. setTestBalance is an absolute
# SET whose delta records as an external flow, so refills raise the bot's
# leaderboard baseline too — bots can't fake profit by being refilled.
#
# Posture: remote funds as FUND_IDENTITY (the funding authority, else the
# controller it fell back to); local as anonymous; a dev-postured remote with
# NO funding identity self-funds via the faucet AS each bot.
SEED_CASH_REMOTE=40000;    FLOOR_CASH_REMOTE=10000     # $ (player-parity mix)
SEED_ASSET_USD_REMOTE=15000; FLOOR_ASSET_USD_REMOTE=4000
SEED_CASH_LOCAL=50000000;  FLOOR_CASH_LOCAL=12000000
SEED_ASSET_UNITS_LOCAL=100000; FLOOR_ASSET_UNITS_LOCAL=25000
REFILL_CHECK_S=${REFILL_CHECK_S:-60}

fund_call() {   # setTestBalance as the FUNDING identity (never the controller key)
  [ -n "$FUND_IDENTITY" ] || return 0   # remote, no funding identity: the faucet path in fund_bot applies
  icp canister call --identity "$FUND_IDENTITY" $ENV_FLAG backend "$@" >/dev/null 2>&1 || true
}
bal_of() {      # e8 balance of ($1=principal, $2=token)
  # getTestBalance is scoped to self, a controller, or the funding authority
  # (it used to be an open public query, which leaked every principal's
  # holdings). We read OTHER principals here — the bots' — so we call as the
  # same FUND_IDENTITY fund_call signs with: an identity that could mint but
  # not read would get 0 back, read it as "below floor", and refill forever.
  icp canister call --query --identity "${FUND_IDENTITY:-anonymous}" $ENV_FLAG backend getTestBalance \
    "(principal \"$1\", \"$2\")" 2>&1 | grep -oE "[0-9][0-9_]*" | head -1 | tr -d '_'
}

# Seed OR refill one bot to full. $2 = "seed" (unconditional) | "refill"
# (only tokens below floor, with a log line so ops sees the drip).
fund_bot() {
  local p="$1" mode="$2" id="$3"
  if $REMOTE && [ -z "$FUND_IDENTITY" ]; then
    # Faucet posture: ADDs, so only top up on refill when below floor.
    if [ "$mode" = seed ]; then
      icp canister call --identity "$id" $ENV_FLAG backend addTestTokens "(\"ICPUSD\", $(e8 50000000.0))" >/dev/null 2>&1 || true
      for t in BTC ETH SOL ICP; do
        icp canister call --identity "$id" $ENV_FLAG backend addTestTokens "(\"$t\", $(e8 100000.0))" >/dev/null 2>&1 || true
      done
    else
      local bal; bal=$(bal_of "$p" ICPUSD)
      [ -n "$bal" ] && [ "$bal" -lt "$(e8 10000000)" ] && \
        icp canister call --identity "$id" $ENV_FLAG backend addTestTokens "(\"ICPUSD\", $(e8 40000000.0))" >/dev/null 2>&1 || true
    fi
    return
  fi
  local seed_cash floor_cash
  if $REMOTE; then seed_cash=$SEED_CASH_REMOTE; floor_cash=$FLOOR_CASH_REMOTE
  else             seed_cash=$SEED_CASH_LOCAL;  floor_cash=$FLOOR_CASH_LOCAL; fi
  # Cash leg.
  if [ "$mode" = seed ]; then
    fund_call setTestBalance "(principal \"$p\", \"ICPUSD\", $(e8 $seed_cash))"
  else
    local bal; bal=$(bal_of "$p" ICPUSD)
    if [ -n "$bal" ] && [ "$bal" -lt "$(e8 $floor_cash)" ]; then
      fund_call setTestBalance "(principal \"$p\", \"ICPUSD\", $(e8 $seed_cash))"
      echo "$(date +%H:%M:%S)  ⛽ $id refilled ICPUSD (was $(awk -v b="$bal" 'BEGIN{printf "%.0f", b/100000000}'))"
    fi
  fi
  # Asset legs — remote sizes by USD at current mid; local by fixed units.
  for m in "${MARKETS[@]}"; do
    local t; t=$(base_of "$m")
    if $REMOTE; then
      local px; px=$(mid "$m"); [ -n "$px" ] || continue
      local seed_q; seed_q=$(awk -v p="$px" -v u="$SEED_ASSET_USD_REMOTE" 'BEGIN{printf "%.6f", u/p}')
      if [ "$mode" = seed ]; then
        fund_call setTestBalance "(principal \"$p\", \"$t\", $(e8 $seed_q))"
      else
        local bal; bal=$(bal_of "$p" "$t"); [ -n "$bal" ] || continue
        local val; val=$(awk -v b="$bal" -v px="$px" 'BEGIN{printf "%.0f", (b/100000000)*px}')
        if [ "$val" -lt "$FLOOR_ASSET_USD_REMOTE" ]; then
          fund_call setTestBalance "(principal \"$p\", \"$t\", $(e8 $seed_q))"
          echo "$(date +%H:%M:%S)  ⛽ $id refilled $t (~\$$val left)"
        fi
      fi
    else
      if [ "$mode" = seed ]; then
        fund_call setTestBalance "(principal \"$p\", \"$t\", $(e8 $SEED_ASSET_UNITS_LOCAL))"
      else
        local bal; bal=$(bal_of "$p" "$t"); [ -n "$bal" ] || continue
        if [ "$bal" -lt "$(e8 $FLOOR_ASSET_UNITS_LOCAL)" ]; then
          fund_call setTestBalance "(principal \"$p\", \"$t\", $(e8 $SEED_ASSET_UNITS_LOCAL))"
          echo "$(date +%H:%M:%S)  ⛽ $id refilled $t"
        fi
      fi
    fi
  done
}

# The replenisher: one pass over every bot each REFILL_CHECK_S.
BOT_PRINCIPALS=()
replenisher_loop() {
  while true; do
    sleep "$REFILL_CHECK_S"
    for i in $(seq 1 "$BOTS"); do
      fund_bot "${BOT_PRINCIPALS[$((i - 1))]}" refill "${BOT_PREFIX}_$i"
    done
  done
}

echo "── funding $BOTS bots ──"
if $REMOTE; then
  if [ -n "${MDX_FUNDING_IDENTITY:-}" ]; then
    echo "  (remote target ${IC_ENV} — funding as the FUNDING AUTHORITY '$FUND_IDENTITY' at ~\$100k value each; the controller key signs no refill)"
  elif [ -n "$FUND_IDENTITY" ]; then
    echo "  (remote target ${IC_ENV} — funding as the CONTROLLER identity '$FUND_IDENTITY' at ~\$100k value each — no MDX_FUNDING_IDENTITY set; designate a funding authority (setFundingAuthority, task 1789609263))"
  else
    echo "  (remote target ${IC_ENV} — self-funding via the faucet; dev posture only)"
  fi
fi
for i in $(seq 1 "$BOTS"); do
  id="${BOT_PREFIX}_$i"
  icp identity new "$id" --storage plaintext >/dev/null 2>&1 || true
  p=$(icp identity principal --identity "$id" 2>/dev/null | tail -1)
  BOT_PRINCIPALS+=("$p")
  fund_bot "$p" seed "$id"
done

# ── Maker loop: keep fresh unprotected limit liquidity on a market ──
maker_loop() {
  local id="$1"
  while true; do
    local m=${MARKETS[$((RANDOM % ${#MARKETS[@]}))]}
    # Cancel prior orders on this market (replace, don't accumulate).
    for oid in $(icp canister call --query --identity "$id" $ENV_FLAG backend getMyOrdersOnMarket "(\"$m\")" 2>&1 \
                 | grep -oE "id = [0-9_]+" | grep -oE "[0-9_]+" | sed 's/_//g'); do
      icp canister call --identity "$id" $ENV_FLAG backend cancelMyOrder "($oid : nat)" >/dev/null 2>&1
    done
    local px; px=$(mid "$m"); [ -z "$px" ] && { sleep "$(msleep)"; continue; }
    local u; u=$(unit_for "$m")
    # Post a bid just below and an ask just above mid (±0.1–0.4%).
    local bid ask; bid=$(awk -v p="$px" -v r="$RANDOM" 'BEGIN{printf "%.4f", p*(1-0.001*(1+(r%4)))}')
    ask=$(awk -v p="$px" -v r="$RANDOM" 'BEGIN{printf "%.4f", p*(1+0.001*(1+(r%4)))}')
    icp canister call --identity "$id" $ENV_FLAG backend placeLimitOrder "(\"$m\", variant { buy },  $(e8 $bid), $(e8 $u))" >/dev/null 2>&1
    icp canister call --identity "$id" $ENV_FLAG backend placeLimitOrder "(\"$m\", variant { sell }, $(e8 $ask), $(e8 $u))" >/dev/null 2>&1
    sleep "$(msleep)"
  done
}
# Makers scale gently (√activity): books must stay alive in lulls, and
# requoting too hard in a frenzy would just churn cancels.
msleep() { awk -v i="$INTERVAL" -v r="$RANDOM" -v a="$(activity)" 'BEGIN{
  s = i * (0.5 + (r % 100) / 100.0) / sqrt(a); if (s < 0.3) s = 0.3; printf "%.2f", s }'; }

# ── Taker loop: fire market orders / swaps that hit standing liquidity ──
taker_loop() {
  local id="$1"
  while true; do
    local m=${MARKETS[$((RANDOM % ${#MARKETS[@]}))]}
    local base; base=$(base_of "$m")
    local u; u=$(unit_for "$m")
    # Size breathes with the regime (√activity, capped ×2): frenzies print
    # bigger tape as well as faster tape, like real bursts do.
    local act; act=$(activity)
    local qty; qty=$(awk -v u="$u" -v r="$RANDOM" -v a="$act" 'BEGIN{
      s = sqrt(a); if (s > 2) s = 2; printf "%.4f", u * (0.4 + (r % 80) / 100.0) * s}')
    local side; side=$([ $((RANDOM % 2)) -eq 0 ] && echo buy || echo sell)
    if [ $((RANDOM % 4)) -eq 0 ]; then
      # cross-market swap (base→ICPUSD or ICPUSD→base)
      if [ "$side" = sell ]; then
        icp canister call --identity "$id" $ENV_FLAG backend swap \
          "(record { fromToken=\"$base\"; toToken=\"ICPUSD\"; amount=$(e8 $qty):nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.2):nat } }; noPartialFill=false })" >/dev/null 2>&1
      else
        local spend; spend=$(awk -v q="$qty" -v p="$(mid "$m")" 'BEGIN{printf "%.2f", q*p}')
        icp canister call --identity "$id" $ENV_FLAG backend swap \
          "(record { fromToken=\"ICPUSD\"; toToken=\"$base\"; amount=$(e8 $spend):nat; mode=variant { marketOrder=record { maxSlippage=$(e8 0.2):nat } }; noPartialFill=false })" >/dev/null 2>&1
      fi
    else
      icp canister call --identity "$id" $ENV_FLAG backend placeMarketOrder \
        "(\"$m\", variant { $side }, $(e8 $qty), $(e8 0.2), false)" >/dev/null 2>&1
    fi
    # Frenzy clustering: in a hot regime, sometimes fire again immediately —
    # trades arrive in flurries, not on a metronome.
    if awk -v a="$act" 'BEGIN{exit !(a > 3)}' && [ $((RANDOM % 3)) -eq 0 ]; then continue; fi
    sleep "$(asleep)"
  done
}

echo ""
echo "── launching bots (interval ${INTERVAL}s each) ──"
for i in $(seq 1 "$BOTS"); do
  if [ $((i % MAKER_FRACTION_DENOM)) -eq 0 ]; then maker_loop "simbot_$i" & else taker_loop "simbot_$i" & fi
  PIDS+=($!)
done
replenisher_loop & PIDS+=($!)
echo "  ${#PIDS[@]} loops running ($BOTS bots + replenisher, refill check every ${REFILL_CHECK_S}s). Ctrl-C to stop."
echo ""

# ── Monitor: report achieved executions/sec every 5s ──
# Per-market last-KNOWN ids: a failed read keeps the previous value instead
# of contributing 0 — with ${v:-0} one flaky query used to swing the sum by
# that market's ENTIRE trade id, printing phantom ±1500-trade "bursts".
WINDOW=5
LAST_IDS=(0 0 0 0)
read_ids() {
  local i v
  for i in "${!MARKETS[@]}"; do
    v=$(last_trade_id "${MARKETS[$i]}")
    [ -n "$v" ] && LAST_IDS[$i]=$v
  done
}
sum_ids() { local s=0 v; for v in "${LAST_IDS[@]}"; do s=$((s + v)); done; echo "$s"; }
read_ids; prev=$(sum_ids)
while true; do
  sleep "$WINDOW"
  read_ids; cur=$(sum_ids)
  rate=$(awk -v d="$((cur - prev))" -v w="$WINDOW" 'BEGIN{printf "%.1f", d/w}')
  echo "$(date +%H:%M:%S)  executions: $((cur - prev)) in ${WINDOW}s  →  ${rate}/s  (cumulative: $cur, mood ×$(activity))"
  prev=$cur
done
