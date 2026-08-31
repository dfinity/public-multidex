#!/usr/bin/env bash
#
# MULTI/DEX — THE deploy script: one consistent flow for every target.
#
# First install → deploy + wire + SEED (the $1M AMM vault and the $50k
# insurance fund — a deployed exchange must never come up with those empty).
# Later runs → update the wasm in place (upgrade install; state preserved;
# seeding self-skips because the AMM pools already exist). The posture is the
# repo default, #play, on every target. Three targets:
#
#   local    the pocket-ic replica. First install (no AMM pools yet) → the
#            full #play bring-up via scripts/cold_start.sh (network, deploy,
#            cycles, play_start.sh seeding + bots). Already seeded → wasm
#            update only (cold_start --no-seed: build, upgrade, re-wire —
#            trading state, vault and insurance preserved).
#   engine   an OpenCloud cloud engine (alias: `cloud`). Guided: links the engine identity,
#            remembers the subnet, deploys backend→bridge→frontend, wires,
#            injects AI keys, seeds (idempotent), offers bots. The ENGINE
#            holds the cycles and pays for compute, so the canister's own
#            balance reads ~0 and the in-app "low / out of cycles" warning is
#            a false alarm — ONLY this target builds the frontend with
#            VITE_CLOUD_ENGINE=true to suppress it (memory warnings stay).
#   subnet   a dedicated IC subnet (runbook: docs/deploy-to-subnet.md). The
#            canister pays its OWN cycles, so cycles checking stays ON
#            (VITE_CLOUD_ENGINE=false), the backend is endowed at first
#            install (SUBNET_CYCLES, default 5000t), and scripts/topup.sh
#            keeps it fed afterwards. setFuelRoute + setXrcCanister stay
#            UNWIRED (#play launch policy) — this script never touches them.
#
# Usage:
#   ./scripts/deploy.sh                    # asks for the target, then guides you
#   ./scripts/deploy.sh local              # first time: seeded bring-up · else: update wasm
#   ./scripts/deploy.sh engine             # cloud engine (guided; config remembered; `cloud` = alias)
#   ./scripts/deploy.sh subnet             # dedicated subnet (guided; config remembered)
#   ./scripts/deploy.sh <target> frontend  # FRONTEND-ONLY: rebuild + sync assets with the
#                                          # target's ids baked in (no backend/bridge/seed)
#   ./scripts/deploy.sh frontend --identity anonymous   # legacy: plain `icp deploy` passthrough
#   ./scripts/deploy.sh -e subnet --subnet <id>         # legacy: plain mainnet deploy (no guidance)
#                                          # NOTE: use a DECLARED environment (`subnet`/`engine`) —
#                                          # the shared `ic` mapping was retired (icp.yaml: it made
#                                          # cross-stack deploys a one-file-swap accident).
#
# Flags:
#   --reconfigure        re-ask the target identity + subnet (overwrites saved config)
#   --seed / --no-seed   seed the play dataset — $1M AMM vault + $50k insurance
#                        fund included (or skip) — without asking. Default: seed;
#                        idempotent (bails when AMM pools already exist), so an
#                        UPDATE deploy never reseeds. On local, --seed forces a
#                        fresh reseed (REINSTALLS backend+bridge) and --no-seed
#                        forces the update path.
#   --bots / --no-bots   run background trading bots (or skip) without asking.
#                        Cloud only — on a subnet the bots belong on an operator
#                        box (tmux/systemd); the script prints the command.
#   --target=X           alternative to the positional target keyword
#   Anything else is forwarded to `icp deploy`.
#
# Seeding runs on the #dev/#play postures (production is never seeded) and is
# full: balances, price history, an order book, a funded AMM vault, AND the
# insurance fund. It defaults to YES and only runs on a first deploy / after a
# reset (skipped if the exchange already has AMM pools).
#
# Non-interactive (CI): pre-set DEPLOY_TARGET=local|engine|subnet (legacy
# CLOUD_ENGINE=true|false still means engine|plain-passthrough), SEED /
# RUN_BOTS = true|false, and pre-populate the conf files below. Subnet env
# knobs: SUBNET_CYCLES (backend endowment at CREATE, default 5000t), and
# TRUSTED_ATTRIBUTE_SIGNERS / FRONTEND_ORIGINS (anti-sybil canister env vars,
# applied via `icp canister settings update` whenever set — they do NOT apply
# on plain redeploys).
# Seed depth: SEED_TRADERS (default 3), HISTORY_DAYS (default 9, 0 to skip).
# Bot fleet size/pace: BOT_COUNT (default 6), BOT_INTERVAL seconds (default 4).
#
# Config is remembered in scripts/.cloud-engine.conf (cloud) and
# scripts/.subnet.conf (subnet), both git-ignored. The one-time CLOUD identity
# link opens a browser to sign in — see the deploy-to-cloud-engine skill
# (.claude/skills/deploy-to-cloud-engine — auto-synced from skills.internetcomputer.org). A SUBNET deploy instead uses a
# normal funded wallet identity you already hold locally (no console link).

set -euo pipefail
cd "$(dirname "$0")/.."

# Scratch-file locations (.run/, not a fixed name under sticky /tmp) — see
# scripts/lib/runfiles.sh for why. Exported, so inject_history.sh and the
# other children this script spawns land on the same paths.
# shellcheck source=scripts/lib/runfiles.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/runfiles.sh"
# Target table + the shared posture reader (mdx_posture_of). Sourced, not
# copied: four hand-rolled DEPLOY_MODE greps with four different blind spots
# is how a commented decoy could beat every deploy gate at once (W1-02).
# shellcheck source=scripts/lib/targets.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/targets.sh"

CONF="scripts/.cloud-engine.conf"
# $CE_ENV — which icp ENVIRONMENT remote calls target. The two mainnet stacks
# are separate icp.yaml environments with their OWN canister-id mappings —
# `engine` (cloud engine) and `subnet` (the dedicated subnet serving
# multidex.ai) — so a deploy can never land on the other stack's canisters
# (they also carry different controllers, but don't rely on that). The two
# remote branches set it (`subnet` / `cloud`); the `local` and `plain` targets
# exec out before anything reads it.
#
# DELIBERATELY NOT INITIALISED HERE. It used to default to `ic`, which was
# dead — every reachable path overwrote it — but a stale default is the wrong
# kind of safety net: `ic` is a bare network alias, not one of our declared
# environments, and it is exactly what the environment split moved away from —
# "the old shared `ic` mapping made that a one-file-swap accident" (icp.yaml).
# With no default, a branch that forgets to set CE_ENV dies on `set -u` naming
# the variable, instead of quietly aiming at an unmapped environment.
TOKENS="ICPUSD BTC ETH SOL ICP"
# market : indicative mid price, used only to lay a non-crossing seed ladder.
MARKETS="BTC-ICPUSD:67500 ETH-ICPUSD:3500 SOL-ICPUSD:180 ICP-ICPUSD:12"

info()  { printf '\033[0;36m▶\033[0m %s\n' "$1"; }
ok()    { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!\033[0m %s\n' "$1"; }
die()   { printf '\033[0;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }
# Integer-money: the backend ledger is Nat base units (10^8). Money args
# (balances, prices, qtys) go on the wire as base-unit integers.
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }

# Prompt on stderr, answer on stdout (safe inside $(...)). Reads the terminal so
# it still works when stdin is otherwise occupied.
ask() {
  local prompt="$1" def="${2:-}" reply
  if [ -n "$def" ]; then printf '%s [%s] ' "$prompt" "$def" >&2; else printf '%s ' "$prompt" >&2; fi
  read -r reply </dev/tty 2>/dev/null || reply=""
  printf '%s' "${reply:-$def}"
}
yesno() {
  local reply
  printf '%s [y/N] ' "$1" >&2
  read -r reply </dev/tty 2>/dev/null || reply=""
  case "$reply" in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
# Like yesno but DEFAULTS TO YES (bare Enter / no tty = yes) — for steps the
# default deployment must include, like seeding the AMM vault + insurance fund.
yesnoY() {
  local reply
  printf '%s [Y/n] ' "$1" >&2
  read -r reply </dev/tty 2>/dev/null || reply=""
  case "$reply" in [nN] | [nN][oO]) return 1 ;; *) return 0 ;; esac
}
truthy() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in true | 1 | yes) return 0 ;; *) return 1 ;; esac; }

load_conf() {
  CE_IDENTITY=""; CE_SUBNET=""; CE_CONSOLE="https://opencloud.org"; CE_FRONTEND_ORIGINS=""
  # if-form, not `[ -f ] && .` — a missing conf as the function's last
  # command would return non-zero and set -e would kill the script SILENTLY.
  # shellcheck disable=SC1090
  if [ -f "$CONF" ]; then . "$CONF"; fi
}
save_conf() {
  printf 'CE_IDENTITY=%q\nCE_SUBNET=%q\nCE_CONSOLE=%q\nCE_FRONTEND_ORIGINS=%q\n' \
    "$CE_IDENTITY" "$CE_SUBNET" "$CE_CONSOLE" "$CE_FRONTEND_ORIGINS" > "$CONF"
}

# Dedicated-subnet config — a separate file so a subnet launch never clobbers
# a saved cloud-engine identity (both may exist on one operator machine).
SUBNET_CONF="scripts/.subnet.conf"
load_subnet_conf() {
  SN_IDENTITY=""; SN_SUBNET=""; SN_FRONTEND_ORIGINS=""
  # if-form, not `[ -f ] && .` — same silent set -e exit as load_conf.
  # shellcheck disable=SC1090
  if [ -f "$SUBNET_CONF" ]; then . "$SUBNET_CONF"; fi
}
save_subnet_conf() {
  printf 'SN_IDENTITY=%q\nSN_SUBNET=%q\nSN_FRONTEND_ORIGINS=%q\n' \
    "$SN_IDENTITY" "$SN_SUBNET" "$SN_FRONTEND_ORIGINS" > "$SUBNET_CONF"
}

# Latest CoinGecko price for a market's base asset (written by inject_history.sh
# to $MDX_ORACLE_PRICES during the history step), falling back to the
# indicative price from MARKETS when history didn't run or that asset wasn't
# fetched. Always emitted as a float literal (the icp CLI rejects a bare integer
# for a Float arg).
#
# THE SNAPSHOT FILE IS INPUT, NOT CODE. Field 2 used to be spliced straight
# into an awk PROGRAM: `awk "BEGIN{printf \"%.4f\", $p}"`. awk has system(), so
# a value of `1; system("curl …|sh")` ran as the operator — on the mainnet
# deploy path. Two independent fixes, both kept:
#   1. VALIDATE — accept only a plain decimal; anything else falls back.
#   2. BIND with -v — `p` is then an awk DATA variable and can never be parsed
#      as program text, whatever it contains.
# (`p+0` forces numeric context so an empty/odd value prints 0.0000 rather
# than tripping printf's type coercion.)
seed_px() {
  local base="${1%-ICPUSD}" fallback="$2" p=""
  [ -f "$MDX_ORACLE_PRICES" ] && \
    p=$(awk -v a="$base" '$1==a{print $2; exit}' "$MDX_ORACLE_PRICES")
  [[ "$p" =~ ^[0-9]+(\.[0-9]+)?$ ]] || p=""
  [ -z "$p" ] && p="$fallback"
  awk -v p="$p" 'BEGIN{ printf "%.4f", p+0 }'
}

# Seed a freshly deployed (or reset) canister with the full play dataset. We
# seed on #dev/#play — production is never seeded — and we seed EVERYTHING the
# local play flow does: operator balances, N days of CoinGecko-derived price
# history, a limit-order book, a funded + enabled AMM vault per market, and
# the insurance fund. The engine
# deploy identity (a controller) runs the admin/AMM calls; the faucet funds it +
# the test traders. No-ops in production mode (faucet disabled).
#
# IDEMPOTENT — only seeds on a first deploy / after a reset: if the exchange
# already has AMM pools it is treated as seeded and skipped (reset to re-seed).
cloud_seed() {
  local n="${SEED_TRADERS:-3}" hist_days="${HISTORY_DAYS:-9}"
  local traders=() t tok m market px base quote k bid ask qty
  # AMM sizing: the vault is funded to AMM_TVL_TOTAL worth of assets ACROSS
  # all markets (default $1,000,000 — the play-mode spec: a $1M AMM as the
  # players' standing counterparty), half base / half ICPUSD per market.
  local tvl_total="${AMM_TVL_TOTAL:-5125000}" nmarkets tvl
  nmarkets=$(echo $MARKETS | wc -w | tr -d ' ')
  tvl=$(( tvl_total / (nmarkets > 0 ? nmarkets : 1) ))

  # First-deploy / post-reset guard. Full seeding (the AMM vault deposits
  # especially) is NOT repeatable, so bail if the exchange already looks seeded.
  if icp canister call backend getAmmPools "()" -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | grep -q "record"; then
    info "AMM pools already exist — the exchange is already seeded; skipping. (Reset the exchange to re-seed.)"
    return 0
  fi

  warn "Seeding the play dataset: balances + price history + order book + AMM vault + insurance fund."
  warn "On mainnet every call is ~2s, so this takes several minutes — leave it running."
  rm -f "$MDX_ORACLE_PRICES"   # don't let a stale history snapshot leak in

  # 0) Posture check. Seeding mints test balances, which only #dev and #play
  #    allow: the CONTROLLER-only setTestBalance survives on #play (the cloud
  #    posture), while the self-serve faucet (addTestTokens) is dev-only —
  #    hard no-op on any public deploy. So fund as the controller, never via
  #    the faucet. #production kills both → skip.
  local mode
  mode=$(icp canister call backend getDeployMode "()" -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"')
  if [ "$mode" = "production" ]; then
    warn "Canister posture is PRODUCTION — test balances are disabled by design. Skipping seed."
    return 0
  fi
  [ -n "$mode" ] && info "Canister posture: $mode"

  # 1) Identities + engine QUOTE funding. The engine is the AMM LP + the
  #    insurance backer (seedAmmPool/seedInsuranceFund draw FROM the caller's
  #    balance), so fund it to the ROLE, not a fortune: half the AMM TVL in
  #    ICPUSD (the vault quote legs) + $50k insurance + slack. Its base legs
  #    are sized per market at LIVE prices in step 2b. A previous 5M-of-every-
  #    token seed (~\$330B at marks — 5M BTC!) made the engine an absurd
  #    permanent leaderboard #1 before controllers were excluded from the
  #    board; the balance itself was also ~1000× the need.
  for k in $(seq 1 "$n"); do traders+=("mdex-seed-$k"); done
  for t in "${traders[@]}"; do icp identity new "$t" --storage plaintext >/dev/null 2>&1 || true; done
  [ -n "${PRINCIPAL:-}" ] || PRINCIPAL="$(icp identity principal --identity "$CE_IDENTITY" 2>/dev/null | tail -1)"
  local engine_quote=$(( tvl_total / 2 + 150000 ))
  icp canister call backend setTestBalance "(principal \"$PRINCIPAL\", \"ICPUSD\", $(e8 $engine_quote))" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
  ok "Engine identity funded (\$$engine_quote ICPUSD — vault quote legs + insurance + slack)"

  # 2) Price history — CoinGecko-derived hourly trades for the chart backdrop.
  #    inject_history.sh writes the latest price per asset to a temp file that
  #    seed_px reads, so the book + AMM start where the history ends.
  #    GENESIS-GATED on #play (docs/deployment-modes.md): the canister accepts
  #    injection only until the venue's first enableAmm — fine on a fresh
  #    install (pools are enabled in step 4, after this), refused fast on an
  #    already-live venue (inject_history.sh probes the gate before fetching
  #    and names the refusal; seeding then continues on live prices).
  if [ "$hist_days" -gt 0 ]; then
    info "Injecting $hist_days days of price history (CoinGecko → injectHistoricalTrades)…"
    IC_ENV="$CE_ENV" bash scripts/inject_history.sh --days "$hist_days" --identity "$CE_IDENTITY" \
      || warn "History injection had failures — see the lines above for the real cause (posture/genesis refusal or rate limits). The chart backdrop may be partial; seeding continues on live prices."
  fi

  # 2b) AMM pools + LIVE prices. Create + configure each pool, then price it
  #     with fetchAndSetRefPrice — the multi-source feed is the ONLY price
  #     authority on #play (setAmmRefPrice is a dev-only override, #err
  #     there), and the fetched price is upserted into the seed_px snapshot
  #     so trader funding, the ladder, and the vault all anchor on the SAME
  #     live price even when an asset's history injection was rate-limited.
  info "Creating AMM pools + fetching live reference prices…"
  local px_e8 base_fund
  for m in $MARKETS; do
    market="${m%%:*}"
    icp canister call backend createAmmPool "(\"$market\")" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    icp canister call backend setAmmConfig "(\"$market\", 20:nat, $(e8 1.0):nat, 15:nat, 35:nat, 8:nat)" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    icp canister call backend fetchAndSetRefPrice "(\"$market\")" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    px_e8=$(icp canister call backend getAmmPool "(\"$market\")" -e "$CE_ENV" --identity "$CE_IDENTITY" --query 2>/dev/null | grep -oE 'refPrice = [0-9_]+' | head -1 | tr -d '_' | awk '{print $3}')
    if [ -n "${px_e8:-}" ] && [ "$px_e8" != "0" ]; then
      px=$(awk -v p="$px_e8" 'BEGIN{ printf "%.4f", p/100000000 }')
      { grep -v "^${market%%-*} " "$MDX_ORACLE_PRICES" 2>/dev/null; echo "${market%%-*} $px"; } > "$MDX_ORACLE_PRICES.new" \
        && mv "$MDX_ORACLE_PRICES.new" "$MDX_ORACLE_PRICES"
      # Engine base leg for this market's vault deposit: half the per-market
      # TVL in base at the live price, +5% slack (role-sized — see step 1).
      base_fund=$(awk -v t="$tvl" -v p="$px" 'BEGIN{ printf "%.6f", t/p/2*1.05 }')
      icp canister call backend setTestBalance "(principal \"$PRINCIPAL\", \"${market%%-*}\", $(e8 $base_fund))" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
      ok "$market — live price \$$px (engine base leg $base_fund ${market%%-*})"
    else
      warn "$market — no live price yet (feed unreachable?); seeding will fall back to history/indicative"
    fi
  done

  # 2c) Seed traders — $100k VALUE each at post-history prices ($40k ICPUSD
  #     cash + $15k of each asset): PARITY with real players' $100k deposit
  #     allowance, so seed identities can't dwarf humans on the leaderboard.
  info "Funding ${#traders[@]} seed trader(s) at ~\$100k value each (setTestBalance)"
  local tp
  for t in "${traders[@]}"; do
    tp=$(icp identity principal --identity "$t" 2>/dev/null | tail -1)
    [ -n "$tp" ] || { warn "no principal for $t — skipping it"; continue; }
    icp canister call backend setTestBalance "(principal \"$tp\", \"ICPUSD\", $(e8 40000.0))" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    for m in $MARKETS; do
      px=$(seed_px "${m%%:*}" "${m##*:}")
      qty=$(awk -v p="$px" 'BEGIN{ printf "%.6f", 15000/p }')
      icp canister call backend setTestBalance "(principal \"$tp\", \"${m%%-*}\", $(e8 $qty))" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    done
  done
  ok "Seed traders funded (\$40k cash + \$15k/asset each)"

  # 3) Order book — a non-crossing limit spread per market around the seed
  #    price. Two levels/side at ~\$2500·k so the ladder fits the traders'
  #    \$100k wallets across all four markets.
  for m in $MARKETS; do
    market="${m%%:*}"; px=$(seed_px "$market" "${m##*:}")
    for t in "${traders[@]}"; do
      for k in 1 2; do
        bid=$(awk -v p="$px" -v k="$k" 'BEGIN{ printf "%.4f", p*(1-0.004*k) }')
        ask=$(awk -v p="$px" -v k="$k" 'BEGIN{ printf "%.4f", p*(1+0.004*k) }')
        qty=$(awk -v p="$px" -v k="$k" 'BEGIN{ printf "%.6f", (2500*k)/p }')
        icp canister call backend placeLimitOrder "(\"$market\", variant { buy },  $(e8 $bid), $(e8 $qty))" -e "$CE_ENV" --identity "$t" >/dev/null 2>&1 || true
        icp canister call backend placeLimitOrder "(\"$market\", variant { sell }, $(e8 $ask), $(e8 $qty))" -e "$CE_ENV" --identity "$t" >/dev/null 2>&1 || true
      done
    done
    ok "$market — order book seeded"
  done

  # 4) AMM vault — fund and enable each pool (created in 2b), as the
  #    controller. RE-fetch the live price right before each vault deposit:
  #    the funding + ladder steps above take minutes at mainnet call latency
  #    and seedAmmPool has a refPrice-freshness gate. Timers stay paused for
  #    the block so the requoter doesn't act on half-funded pools.
  info "Seeding the AMM vault per market (controller calls)…"
  local seed_out
  icp canister call backend setTestTimersPaused "(true)" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
  for m in $MARKETS; do
    market="${m%%:*}"
    icp canister call backend fetchAndSetRefPrice "(\"$market\")" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    px_e8=$(icp canister call backend getAmmPool "(\"$market\")" -e "$CE_ENV" --identity "$CE_IDENTITY" --query 2>/dev/null | grep -oE 'refPrice = [0-9_]+' | head -1 | tr -d '_' | awk '{print $3}')
    if [ -z "${px_e8:-}" ] || [ "$px_e8" = "0" ]; then
      warn "$market — no live price; SKIPPING its vault (re-run seeding once the feed reaches the canister)"
      continue
    fi
    px=$(awk -v p="$px_e8" 'BEGIN{ printf "%.4f", p/100000000 }')
    base=$(awk -v t="$tvl" -v p="$px" 'BEGIN{ printf "%.6f", t/p/2 }')
    quote=$(awk -v t="$tvl" 'BEGIN{ printf "%.2f", t/2 }')
    seed_out=$(icp canister call backend seedAmmPool "(\"$market\", $(e8 $base):nat, $(e8 $quote):nat)" -e "$CE_ENV" --identity "$CE_IDENTITY" 2>&1)
    if echo "$seed_out" | grep -q "err"; then
      warn "$market — AMM vault seed FAILED: $(echo "$seed_out" | head -2 | tr '\n' ' ')"
    else
      ok "$market — AMM vault funded ($base base + $quote ICPUSD @ \$$px live)"
    fi
    icp canister call backend setAmmSkewConfig "(\"$market\", $(e8 $base):nat, 200:nat)" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    icp canister call backend enableAmm "(\"$market\", true)" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
  done
  icp canister call backend setAmmAutoInventory "(true)" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
  icp canister call backend setTestTimersPaused "(false)" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
  ok "AMM vault seeded + enabled (auto-inventory on)."

  # 5) Insurance fund — genesis backstop for liquidation shortfalls. Mints
  #    pool ICPUSD and attributes the shares to the engine identity.
  seed_ins_out="$(icp canister call backend seedInsuranceFund "($(e8 "${INSURANCE_USD:-144000}"):nat)" -e "$CE_ENV" --identity "$CE_IDENTITY" 2>&1)"
  if mdx_call_ok "$seed_ins_out"; then
    ok "Insurance fund seeded (\$50k ICPUSD, shares → $CE_IDENTITY)"
  else
    warn "Insurance fund seed failed"
  fi

  ok "Seed complete — balances, ${hist_days}d price history, order book, AMM vault, and insurance fund."
  info "To remove the test identities later: for i in \$(seq 1 $n); do icp identity delete mdex-seed-\$i; done"
}

# Launch the trading-bot load generator against the deployed engine so the
# market keeps trading after the deploy. The bots run detached in the
# background (logging to scripts/sim_cloud.log) and self-fund via the faucet
# (test mode only). IC_ENV=$CE_ENV points sim_trading.sh at the deployed canister.
cloud_bots() {
  local n="${BOT_COUNT:-6}" interval="${BOT_INTERVAL:-4}" log="scripts/sim_cloud.log"
  if [ ! -f scripts/sim_trading.sh ]; then warn "scripts/sim_trading.sh not found — skipping bots."; return 0; fi
  # Pre-fund the bots as the CONTROLLER: the script's own faucet path
  # (addTestTokens) is dev-only — a hard no-op on the #play posture a public
  # engine runs — so without this the bots trade with zero balances and every
  # action fails. Each bot holds $100k VALUE at seed prices ($40k ICPUSD cash
  # + $15k of each asset) — PARITY with real players' $100k deposit
  # allowance, so bots and humans compete from the same footing (their seed
  # is extNetFlow-baselined as capital, not profit).
  info "Pre-funding $n bot identities via setTestBalance (controller, ~\$100k value each)…"
  local i id bp m px q
  for i in $(seq 1 "$n"); do
    id="simbot_$i"
    icp identity new "$id" --storage plaintext >/dev/null 2>&1 || true
    bp=$(icp identity principal --identity "$id" 2>/dev/null | tail -1)
    [ -n "$bp" ] || { warn "no principal for $id — skipping it"; continue; }
    icp canister call backend setTestBalance "(principal \"$bp\", \"ICPUSD\", $(e8 40000.0))" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    for m in $MARKETS; do
      px=$(seed_px "${m%%:*}" "${m##*:}")
      q=$(awk -v p="$px" 'BEGIN{ printf "%.6f", 15000/p }')
      icp canister call backend setTestBalance "(principal \"$bp\", \"${m%%-*}\", $(e8 $q))" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || true
    done
  done
  warn "Launching $n trading bot(s) against the engine (background). On mainnet each call is ~2s, so fills are slow but continuous."
  IC_ENV="$CE_ENV" nohup bash scripts/sim_trading.sh "$n" "$interval" > "$log" 2>&1 &
  local pid=$!
  ok "Bots running (PID $pid). Live output: tail -f $log"
  # By PID only. `pkill -f sim_trading.sh` also matches a fleet pointed at the
  # LIVE subnet (the target comes from IC_ENV, which is not in argv), which is
  # how real volume on multidex.ai was stopped twice by accident.
  info "Stop them anytime with:  kill $pid"
  warn "The bots run from THIS machine, not on-chain — players only have a live"
  warn "counterparty while it stays awake. If they die (sleep/reboot), relaunch:"
  warn "  IC_ENV="$CE_ENV" nohup bash scripts/sim_trading.sh $n $interval > $log 2>&1 &"
}

command -v icp >/dev/null 2>&1 || die "icp CLI not found — install it (https://cli.internetcomputer.org), then re-run."

# ── Decide target ────────────────────────────────────────────────
# Positional keyword (local|engine|subnet), --target=X, or DEPLOY_TARGET env;
# legacy CLOUD_ENGINE=true|false still maps to engine|plain-passthrough. Bare
# canister names / icp flags with no target keep the historical behavior: a
# plain `icp deploy` passthrough (no wiring, no seeding).
#
# ── ONE VOCABULARY ──
# `local | engine | subnet` — the same spelling scripts/lib/targets.sh uses
# (its table is the single source of truth for what a target IS), the same
# names icp.yaml gives its environments, and the same words in the
# deploy_to_<target>.sh filenames. This script used to say `cloud` where
# everything else said `engine`, and that mismatch WAS the deploy_to_engine.sh
# bug: that wrapper execs `deploy.sh engine`, `engine` was not in this keyword
# list, so it fell through to PASS[] as if it were a canister name, TARGET
# resolved to "plain", and the deploy became a bare `icp deploy` passthrough
# that SKIPS apply_anti_sybil_settings and apply_memory_settings. The skipped
# frontend_origins re-stamp is what took multidex.ai sign-in down on
# 2026-07-11 — silently, because a passthrough deploy still succeeds.
# `cloud` stays accepted as an alias (docs, CI, muscle memory) but everything
# downstream compares against the canonical name only.
# W5-22: did a canister call RETURN #ok? A Candid #err is a successful call
# (exit 0), so gates must parse the variant, not the exit status. Methods
# audited as exit-status-safe stay as they are: getAmmPools (:216) pipes to
# its own grep; setGoogleApiKey/setAnthropicApiKey (:633/:646) return () —
# no #err arm to miss. seedInsuranceFund (:363) converted below too.
mdx_call_ok() {  # $1 = full call output
  printf '%s' "$1" | grep -qE 'variant[[:space:]]*\{[[:space:]]*ok'
}

canonical_target() {
  case "${1:-}" in
    local)        printf 'local' ;;
    engine|cloud) printf 'engine' ;;
    subnet)       printf 'subnet' ;;
    plain)        printf 'plain' ;;   # internal: the legacy `icp deploy` passthrough
    *)            return 1 ;;
  esac
}
TARGET="${DEPLOY_TARGET:-}"
RECONFIGURE=false; SEED="${SEED:-}"; RUN_BOTS="${RUN_BOTS:-}"; PASS=(); SAW_FRONTEND=false
while [ $# -gt 0 ]; do
  case "$1" in
    local|cloud|engine|subnet) if [ -z "$TARGET" ]; then TARGET="$1"; else PASS+=("$1"); fi ;;
    frontend)      SAW_FRONTEND=true ;;   # `<target> frontend` = frontend-only; bare = legacy passthrough (restored below)
    --target)      TARGET="${2:-}"; shift ;;
    --target=*)    TARGET="${1#--target=}" ;;
    --reconfigure) RECONFIGURE=true ;;
    --seed)        SEED=true ;;
    --no-seed)     SEED=false ;;
    --bots)        RUN_BOTS=true ;;
    --no-bots)     RUN_BOTS=false ;;
    --help|-h)     sed -n '3,/^# Config is remembered/p' "$0" | sed -E 's/^# ?//'; exit 0 ;;
    *)             PASS+=("$1") ;;
  esac
  shift
done
# `frontend` without a target keyword is the historical plain passthrough
# (`deploy.sh frontend --identity anonymous`): restore it as the positional
# canister arg. WITH a target it selects frontend-only mode (see below).
FRONTEND_ONLY=false
if $SAW_FRONTEND; then
  if [ -n "$TARGET" ]; then FRONTEND_ONLY=true; else PASS=("frontend" ${PASS[@]+"${PASS[@]}"}); fi
fi
if [ -z "$TARGET" ] && [ -n "${CLOUD_ENGINE:-}" ]; then
  if truthy "$CLOUD_ENGINE"; then TARGET="engine"; else TARGET="plain"; fi
fi
if [ -z "$TARGET" ]; then
  if [ ${#PASS[@]} -gt 0 ]; then
    TARGET="plain"
  else
    case "$(ask 'Deploy target — [l]ocal replica, cloud [e]ngine, dedicated [s]ubnet:' 'l')" in
      e*|E*|c*|C*) TARGET="engine" ;;
      s*|S*)       TARGET="subnet" ;;
      *)           TARGET="local" ;;
    esac
  fi
fi

# HARD ERROR on anything we don't recognise — never a silent fall-through to
# the passthrough. A typo'd or renamed target must stop the deploy, not
# quietly downgrade it to a bare `icp deploy` that skips the safety steps.
# This also normalises the `cloud` alias, so every comparison below is against
# the canonical name.
TARGET_GIVEN="$TARGET"
TARGET="$(canonical_target "$TARGET_GIVEN")" || die "Unknown deploy target '$TARGET_GIVEN' — expected: local | engine | subnet ('cloud' is accepted as an alias for engine). Nothing was deployed."

# ── Candid freshness: never ship a lying interface (W5-20) ───────────
#
# mops.toml embeds src/backend/backend.did as the canister's PUBLIC
# candid:service metadata, and gen-did.sh is its only writer. A deploy after
# an API edit without gen-did.sh ships the STALE interface: the CLI then
# silently drops new fields from display and prints raw hash variants for
# new methods (reproduced live during W1-03), and remote tooling reads an
# interface that does not match the deployed code — on the subnet, a public
# artefact of a transparency-doctrine venue telling lies. gen-did.sh is
# idempotent and cheap relative to any deploy, so just run it; refuse only
# if it cannot be run (its own failure text says why). The lint-ratchet
# CANDID section stays the commit-time gate; this is the deploy-time one.
info "Regenerating candid interface (gen-did.sh) so the deploy ships what the source says"
bash scripts/gen-did.sh >/dev/null   || die "scripts/gen-did.sh failed — refusing to deploy a stale candid:service interface. Run it by hand to see why."

# ── Posture gate: never ship #dev to a value-bearing target ──────────
#
# DEPLOY_MODE lives in src/backend/main.mo and is edited by hand — a local
# testing flip to #dev is normal and expected (the dev-gated hooks and the
# seed.sh fixtures need it). What must never happen is that flip reaching a
# public venue: on #dev the open faucet is live (addTestTokens mints spendable
# balance to ANY caller), every setTest* hook is callable, requireDevHook
# passes, and the deposit verification gate is off.
#
# Relying on whoever flipped it to remember to flip back is not a control. It
# already failed once: a temporary #dev flip was committed (1f409d1,
# 2026-07-29) and sat in HEAD until it was caught by eye. So the deploy refuses
# instead — the check costs nothing and removes the whole class.
#
# Checked against the WORKING TREE, because that is what gets compiled — HEAD
# being clean is no comfort if the file on disk is not. Local deploys are
# unaffected: #dev is the point of them.
# Resolution is delegated to mdx_posture_of (lib/targets.sh): the ONE
# comment-aware reader, which refuses to answer unless exactly one
# uncommented declaration exists. `|| true`: its refusal (empty output,
# non-zero) must fall through to the refuse-branch below for the full
# remediation text — under set -e a bare failed substitution would exit
# with only the helper's terse diagnostic.
posture_of() { mdx_posture_of "src/backend/main.mo" || true; }
case "$TARGET" in
  local) : ;;   # #dev is legitimate here
  *)
    POSTURE="$(posture_of)"
    if [ "$POSTURE" != "play" ] && [ "$POSTURE" != "production" ]; then
      echo ""
      echo "  ✗ REFUSING to deploy to '$TARGET': src/backend/main.mo posture is '${POSTURE:-unresolved — diagnostic above}', not #play."
      echo ""
      echo "    On a public venue #dev means:"
      echo "      · addTestTokens mints spendable balance to any caller (open faucet)"
      echo "      · every setTest* hook is callable by anyone"
      echo "      · the Google-verification deposit gate is OFF"
      echo ""
      echo "    Fix: set 'transient let DEPLOY_MODE : DeployMode = #play;' in"
      echo "    src/backend/main.mo, rebuild, and re-run. To deploy a genuinely"
      echo "    value-bearing #production build, that posture is accepted too."
      echo ""
      exit 1
    fi
    ok "source posture is #$POSTURE (safe for '$TARGET')"
    # W3-09: one-directional Bridge rule on the deploy path (not just in the
    # test suite): a value-bearing DEX must never ship beside a Bridge whose
    # posture still answers the unbacked-credit dev hooks.
    if [ "$POSTURE" = "production" ]; then
      BRIDGE_POSTURE="$(mdx_posture_of src/bridge/main.mo || true)"
      if [ "$BRIDGE_POSTURE" != "production" ]; then
        echo ""
        echo "  ✗ REFUSING to deploy to '$TARGET': the DEX is #production but src/bridge/main.mo"
        echo "    resolves to '#${BRIDGE_POSTURE:-unresolved}'. The stub Bridge's unbacked-credit hooks must"
        echo "    not answer against a value-bearing DEX — deploy the real chain-key Bridge first."
        echo ""
        exit 1
      fi
      ok "bridge posture is #$BRIDGE_POSTURE (not more permissive than the DEX)"
    fi
    ;;
esac

# ── frontend-only: rebuild + sync the asset canister, nothing else ────
# `deploy.sh <target> frontend` — for UI-only changes (main.js, CSS, docs,
# index.html). No backend/bridge upgrade, no seeding, no settings churn.
# The build is fed the target's deployed canister ids (AI_CONNECT_*) so the
# ai-connect meta and /.well-known/ic-app.json bake correctly — without
# them vite falls back to the LOCAL replica's mapping, silently shipping
# local ids in the discovery surfaces of a mainnet frontend.
if $FRONTEND_ONLY; then
  FO_SUBNET=()
  case "$TARGET" in
    local)
      FO_ENV="local"; FO_ID="anonymous"
      ;;
    engine)
      load_conf
      [ -n "$CE_IDENTITY" ] || die "No cloud-engine conf — run a full 'deploy.sh engine' once first."
      icp identity principal --identity "$CE_IDENTITY" >/dev/null 2>&1 \
        || die "Identity '$CE_IDENTITY' unusable (web delegation expired?) — run: icp identity reauth $CE_IDENTITY"
      FO_ENV="engine"; FO_ID="$CE_IDENTITY"; FO_SUBNET=(--subnet "$CE_SUBNET")
      export VITE_CLOUD_ENGINE=true
      ;;
    subnet)
      load_subnet_conf
      [ -n "$SN_IDENTITY" ] || die "No subnet conf — run a full 'deploy.sh subnet' once first."
      FO_ENV="subnet"; FO_ID="$SN_IDENTITY"; FO_SUBNET=(--subnet "$SN_SUBNET")
      export VITE_CLOUD_ENGINE=false
      ;;
    *) die "frontend-only needs a real target: deploy.sh local|engine|subnet frontend" ;;
  esac
  if [ "$TARGET" != "local" ]; then
    # Ids from the target's own environment (same resolution `icp deploy`
    # uses); local builds read the local mapping inside vite instead.
    for c in backend bridge frontend; do
      id="$(icp canister status "$c" -e "$FO_ENV" --identity "$FO_ID" 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')"
      [ -n "$id" ] || die "Could not read the $c canister id on '$FO_ENV' — full 'deploy.sh $TARGET' first?"
      case "$c" in
        backend)  export AI_CONNECT_BACKEND_ID="$id" ;;
        bridge)   export AI_CONNECT_BRIDGE_ID="$id" ;;
        frontend) export AI_CONNECT_FRONTEND_ID="$id" ;;
      esac
    done
  fi
  info "Frontend-only deploy → $TARGET (env $FO_ENV, identity $FO_ID)"
  icp deploy frontend -e "$FO_ENV" ${FO_SUBNET[@]+"${FO_SUBNET[@]}"} --identity "$FO_ID" ${PASS[@]+"${PASS[@]}"} \
    || die "Frontend deploy failed."
  ok "Frontend synced — backend, bridge, seed and settings untouched."
  exit 0
fi

# AI assistant keys — injected at deploy time, NEVER committed. Google
# (Gemini) key from GOOGLE_API_KEY env (legacy alias AI_API_KEY) or the
# git-ignored scripts/.google-api-key; Anthropic from ANTHROPIC_API_KEY or
# scripts/.anthropic-api-key. Held in backend stable state (survives
# upgrades, wiped on reinstall — re-applied on every deploy). Anthropic is
# injected AFTER Gemini on purpose: the backend uses whichever key was set
# last, so when both are present the assistant runs on Anthropic. Absent →
# the assistant stays disabled, which is the correct default.
inject_ai_keys() {
  GOOGLE_KEY="${GOOGLE_API_KEY:-${AI_API_KEY:-}}"
  if [ -z "$GOOGLE_KEY" ] && [ -f scripts/.google-api-key ]; then
    GOOGLE_KEY="$(tr -d '[:space:]' < scripts/.google-api-key)"
  fi
  if [ -n "$GOOGLE_KEY" ]; then
    if icp canister call backend setGoogleApiKey "(\"$GOOGLE_KEY\")" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1; then
      ok "Google AI key wired (${#GOOGLE_KEY} chars)"
    else
      warn "setGoogleApiKey failed — the assistant will be unavailable."
    fi
  else
    info "No Google AI key (GOOGLE_API_KEY env / scripts/.google-api-key) — Gemini not wired."
  fi
  ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
  if [ -z "$ANTHROPIC_KEY" ] && [ -f scripts/.anthropic-api-key ]; then
    ANTHROPIC_KEY="$(tr -d '[:space:]' < scripts/.anthropic-api-key)"
  fi
  if [ -n "$ANTHROPIC_KEY" ]; then
    if icp canister call backend setAnthropicApiKey "(\"$ANTHROPIC_KEY\")" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1; then
      ok "Anthropic key wired (${#ANTHROPIC_KEY} chars) — assistant on Anthropic"
    else
      warn "setAnthropicApiKey failed."
    fi
  fi
}

# Anti-sybil canister env vars — re-asserted after EVERY remote deploy.
# icp.yaml deliberately carries LOCAL-DEV frontend_origins only (128-char
# env-value cap), and a create-class install (first install OR --mode
# reinstall) re-stamps yaml values onto the canister — silently replacing the
# production origins and making Verify-with-Google fail closed for every
# player (#FrontendOriginMismatch; bit multidex.ai on 2026-07-11). So the
# production origins persist per target (CE_FRONTEND_ORIGINS /
# SN_FRONTEND_ORIGINS in the conf, seeded from the FRONTEND_ORIGINS env on
# first use) and get pushed via settings update IMMEDIATELY after the backend
# leg — not only at the end of the deploy. The end-of-script call alone left a
# gap: any later leg dying (the 2026-07-22 frontend asset-sync race did) aborts
# the script with the backend already re-stamped, i.e. sign-in down until
# someone re-asserts by hand. Same wiped-state reasoning as the AI keys and
# bridge wiring; the call is idempotent, so running it twice is free.
# TRUSTED_ATTRIBUTE_SIGNERS stays env-only: its yaml value IS the production
# value (the II canister), so a re-stamp is harmless.
# Memory settings — applied on EVERY remote deploy, so a freshly created
# canister can never come up on the IC's 3 GiB default.
#
# The limit is READ FROM main.mo's WASM_MEMORY_LIMIT_BYTES rather than
# duplicated here, because that constant is what getCanisterInfo reports and
# what Stats → Canister renders consumption against — the IC gives a canister
# no API to read its own limit. When the two drifted apart the dashboard lied
# in the DANGEROUS direction: the subnet backend was created 2026-07-11 with
# the 3 GiB default, a month after ops had raised the constant to 5.25 GiB, so
# it sat at 79% of its real ceiling while reporting a comfortable 45%. Deriving
# the setting from the constant makes that drift impossible.
#
# The THRESHOLD is what actually arms the alarm: main.mo implements a
# lowmemory() system hook (and surfaces lowMemoryAtNs), but the IC only fires
# it when free memory falls below wasm_memory_threshold — which defaults to 0,
# i.e. never. Default 512 MiB of headroom; override with WASM_MEMORY_THRESHOLD.
apply_memory_settings() {
  local limit thresh
  # The DECLARED ops-intent limit, applied at deploy. main.mo no longer
  # carries a constant to grep: the canister reads its REAL limit back from
  # canister_status and reports it via getCanisterInfo.wasmMemoryLimitBytes,
  # so dashboard drift is structurally impossible — what remains here is the
  # value ops WANTS applied (5.25 GiB; wasm64 hard wall is 6 GiB, keep margin).
  # Override per-deploy with WASM_MEMORY_LIMIT.
  limit="${WASM_MEMORY_LIMIT:-5637144576}"
  thresh="${WASM_MEMORY_THRESHOLD:-536870912}"
  if icp canister settings update backend -e "$CE_ENV" --identity "$CE_IDENTITY" \
       --wasm-memory-limit "$limit" --wasm-memory-threshold "$thresh" 2>/dev/null; then
    ok "memory settings applied (limit $(awk -v b="$limit" 'BEGIN{printf "%.2f", b/1073741824}') GiB, lowmemory() at $(awk -v b="$thresh" 'BEGIN{printf "%.0f", b/1048576}') MiB free)"
  else
    warn "memory settings update failed — check: icp canister status backend -e $CE_ENV --identity $CE_IDENTITY | grep -i 'wasm memory'"
  fi
}

apply_anti_sybil_settings() {
  local EV=()
  [ -n "${TRUSTED_ATTRIBUTE_SIGNERS:-}" ] && EV+=(--add-environment-variable "trusted_attribute_signers=${TRUSTED_ATTRIBUTE_SIGNERS}")
  [ -n "$CE_FRONTEND_ORIGINS" ]           && EV+=(--add-environment-variable "frontend_origins=${CE_FRONTEND_ORIGINS}")
  if [ ${#EV[@]} -gt 0 ]; then
    if icp canister settings update backend -e "$CE_ENV" --identity "$CE_IDENTITY" ${EV[@]+"${EV[@]}"} 2>/dev/null; then
      ok "anti-sybil env vars re-asserted (frontend_origins=${CE_FRONTEND_ORIGINS:-<unchanged>})"
    else
      warn "settings update failed — apply frontend_origins manually or Verify-with-Google fails closed (runbook §3b)"
    fi
  else
    warn "No production frontend_origins on record — the backend now trusts icp.yaml's LOCAL-DEV list only,"
    warn "so Verify-with-Google fails closed on this deployment. Set it once and it is remembered:"
    warn "  FRONTEND_ORIGINS=\"https://<frontend-id>.icp0.io,https://<frontend-id>.icp.net,https://<domain>\" \\"
    warn "    bash scripts/deploy.sh $TARGET"
  fi
}

# ── Shared remote deploy (cloud engine + dedicated subnet) ───────
# Deploys backend → bridge → frontend onto $CE_SUBNET as $CE_IDENTITY, wires
# setBridge/setDex, injects the AI keys. CE_* here is "the ACTIVE remote
# identity/subnet": the cloud branch loads it from .cloud-engine.conf, the
# subnet branch copies it from .subnet.conf (save_conf only runs on cloud).
# CREATE_CYCLES, when non-empty, endows the backend CREATE (subnet first
# install) — empty on updates, and always on engines (the engine pays).
remote_deploy() {
  # Backend FIRST so its canister id exists, then substitute that id into the
  # App Connect bridge page (ai-connect.html) via AI_CONNECT_BACKEND_ID before
  # the frontend builds. A connector reads the RAW served HTML, so the deployed
  # id must be in the static markup — the page ships as a template with a
  # placeholder that the frontend build (vite.config.js) replaces with this id.
  local wc=()
  [ -n "${CREATE_CYCLES:-}" ] && wc=(--cycles "$CREATE_CYCLES")
  info "Deploying backend: icp deploy backend -e "$CE_ENV" --subnet $CE_SUBNET --identity $CE_IDENTITY${CREATE_CYCLES:+ --cycles $CREATE_CYCLES}"
  icp deploy backend -e "$CE_ENV" --subnet "$CE_SUBNET" --identity "$CE_IDENTITY" ${wc[@]+"${wc[@]}"} ${PASS[@]+"${PASS[@]}"} \
    || die "Backend deploy failed. If it was rejected as unauthorized, this identity doesn't control the canisters (cloud engine: it may be linked to the wrong console — re-run with --reconfigure; skill: Pitfall 2)."
  BACKEND_ID="$(icp canister status backend -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')"
  if [ -n "$BACKEND_ID" ]; then
    export AI_CONNECT_BACKEND_ID="$BACKEND_ID"
    ok "Backend canister id $BACKEND_ID — substituting it into ai-connect.html"
  else
    warn "Could not read the backend canister id; ai-connect.html will rely on its runtime cookie resolver only."
  fi

  # Re-assert the production origins NOW, while the backend leg is the only
  # thing that has run — the deploy above just re-stamped icp.yaml's LOCAL-DEV
  # frontend_origins onto the live backend, and if a later leg dies the
  # end-of-script re-assert never happens (2026-07-22: the frontend asset-sync
  # race aborted here and production sign-in failed closed until fixed by hand).
  apply_anti_sybil_settings
  apply_memory_settings

  # Bridge BEFORE the frontend: on #play the Deposit page is the ONLY on-ramp,
  # and the frontend build bakes the bridge's canister id into its env
  # (PUBLIC_CANISTER_ID:bridge) — so the bridge must already exist on ic when
  # the frontend builds. Wire both directions (idempotent) right away — the
  # pointers live in stable vars, so re-asserting them on an UPDATE is a no-op
  # and heals a reinstall.
  info "Deploying bridge: icp deploy bridge -e "$CE_ENV" --subnet $CE_SUBNET --identity $CE_IDENTITY"
  icp deploy bridge -e "$CE_ENV" --subnet "$CE_SUBNET" --identity "$CE_IDENTITY" ${PASS[@]+"${PASS[@]}"} \
    || die "Bridge deploy failed."
  # No setBridge/setDex leg: both canisters discover each other from the
  # PUBLIC_CANISTER_ID:* env vars icp injects on every deploy (icp-cli
  # pitfall 22) — the setters remain only as a break-glass override.
  BRIDGE_ID="$(icp canister status bridge -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')"
  [ -n "$BRIDGE_ID" ] && ok "Bridge deployed (auto-wired via canister env: bridge=$BRIDGE_ID)"

  # Arbitrageur (simulated cross-venue arb — docs/amm-vault-design.md): pins
  # the venue price to the oracle mark, so it ships WITH the venue. Deploy →
  # wire both ways → fund (GUARDED: only when its ICPUSD is zero, so an
  # update deploy never re-mints working capital) → enable. On a self-funded
  # subnet a FIRST install gets a cycles endowment (ARB_CYCLES, default 2t);
  # from then on the backend's tickArbFuel keeps it between 1T–2T out of its
  # own reservoir. Engine canisters draw on the engine — no endowment.
  local arb_create=()
  if [ "$TARGET" = "subnet" ] && ! icp canister status arb -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1; then
    arb_create=(--cycles "${ARB_CYCLES:-2t}")
  fi
  info "Deploying arb: icp deploy arb -e $CE_ENV --subnet $CE_SUBNET --identity $CE_IDENTITY${arb_create[0]:+ --cycles ${ARB_CYCLES:-2t}}"
  if icp deploy arb -e "$CE_ENV" --subnet "$CE_SUBNET" --identity "$CE_IDENTITY" ${arb_create[@]+"${arb_create[@]}"} ${PASS[@]+"${PASS[@]}"}; then
    ARB_ID="$(icp canister status arb -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')"
    if [ -n "$ARB_ID" ] && [ -n "$BACKEND_ID" ]; then
      # auto-wired via PUBLIC_CANISTER_ID:* env vars (icp-cli pitfall 22)
      # Guarded fund — getTestBalance is scoped to self-or-controller; this
      # reads the ARB's balance, so it must run as CE_IDENTITY (it does).
      arb_bal="$(icp canister call backend getTestBalance "(principal \"$ARB_ID\", \"ICPUSD\")" --query -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | grep -oE "[0-9][0-9_]*" | head -1 | tr -d '_')"
      if [ -z "${arb_bal:-}" ] || [ "$arb_bal" = "0" ]; then
        # W5-22: a Candid #err return is a SUCCESSFUL call (the CLI exits 0),
        # so testing the exit status printed a FALSE "ok arb funded" on any
        # posture where fundArbitrageur refuses (#production does, by
        # design). Test the returned VARIANT via mdx_call_ok — never the
        # exit status — for any method with an #err arm.
        fund_out="$(icp canister call backend fundArbitrageur "($(e8 "${ARB_USD:-1281250}"):nat)" -e "$CE_ENV" --identity "$CE_IDENTITY" 2>&1)"
        if mdx_call_ok "$fund_out"; then
          ok "arb funded: \$${ARB_USD:-1281250} ICPUSD working capital"
        else
          warn "fundArbitrageur did NOT fund — fund it manually before enabling: $(printf '%s' "$fund_out" | tr -d '\n' | head -c 160)"
        fi
      else
        ok "arb already funded ($(awk -v b="$arb_bal" 'BEGIN{printf "%.0f", b/1e8}') ICPUSD) — skipping fund"
      fi
      icp canister call arb setEnabled "(true)" -e "$CE_ENV" --identity "$CE_IDENTITY" >/dev/null 2>&1 || warn "arb enable failed"
      ok "Arbitrageur wired (arb=$ARB_ID)"
    else
      warn "Could not read arb/backend ids — arbitrageur not wired"
    fi
  else
    warn "arb deploy failed — venue prices lose their external anchor (deploy + wire it manually)"
  fi

  inject_ai_keys

  # Feed the OTHER canister ids to the frontend build too: vite emits
  # /.well-known/ic-app.json (all canisters + roles, for agent discovery by
  # domain) from AI_CONNECT_{BACKEND,BRIDGE,FRONTEND}_ID. The frontend id
  # exists before its own deploy on every UPDATE; on a true first install it
  # is absent and vite emits the manifest without the frontend row (loudly).
  [ -n "$BRIDGE_ID" ] && export AI_CONNECT_BRIDGE_ID="$BRIDGE_ID"
  FRONTEND_ID="$(icp canister status frontend -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')"
  [ -n "$FRONTEND_ID" ] && export AI_CONNECT_FRONTEND_ID="$FRONTEND_ID"

  info "Deploying frontend: icp deploy frontend -e "$CE_ENV" --subnet $CE_SUBNET --identity $CE_IDENTITY"
  icp deploy frontend -e "$CE_ENV" --subnet "$CE_SUBNET" --identity "$CE_IDENTITY" ${PASS[@]+"${PASS[@]}"} \
    || die "Frontend deploy failed. Backend/bridge/arb are already deployed and the origins re-asserted — retry just this leg with: bash scripts/deploy.sh $TARGET frontend. (Unauthorized? re-run with --reconfigure; skill: Pitfall 2.)"
  ok "Deploy complete."
}

# Seed — DEFAULT YES: a freshly deployed exchange must come up with a funded
# AMM vault and insurance fund (an empty AMM/insurance pool is the classic
# silent misdeploy). cloud_seed is idempotent (bails if pools exist — so an
# UPDATE deploy sails through without reseeding) and a hard skip on
# #production, so defaulting on is safe on every target.
maybe_seed() {
  if [ -z "$SEED" ]; then
    if yesnoY "Seed the play dataset (balances, price history, order book, \$1M AMM vault, \$50k insurance fund)?"; then SEED=true; else SEED=false; fi
  fi
  if truthy "$SEED"; then cloud_seed; fi
}

# ── plain: legacy `icp deploy` passthrough ───────────────────────
if [ "$TARGET" = "plain" ]; then
  # Zombie-network check (LOCAL targets only — skip when deploying remotely).
  # A launcher restart can leave two pocket-ic MASTERS (`--ttl` in argv);
  # the gateway still answers, but inter-canister calls and HTTPS outcalls
  # fail (oracles die, archive shipping stalls). Deploying onto that network
  # "works" and then misbehaves confusingly. This script must not wipe a
  # network it doesn't own, so it warns and defers to cold_start.sh, which
  # restarts the network cleanly. Seen 2026-07-06.
  # The remote environments are the two declared mainnet stacks; anything else
  # (`local`, `test`, or no -e at all) is the local replica and gets the check.
  # (The old `-e ic` pattern matched NOTHING after the engine/subnet split, so
  # this check misfired on every remote plain deploy.)
  if ! printf '%s ' ${PASS[@]+"${PASS[@]}"} | grep -qE '(-e|--environment) *(subnet|engine)\b'; then
    # Detection is mdx_stray_masters (lib/targets.sh, W1-06): repo-scoped by
    # process cwd AND owner-scoped by the gateway `icp network status`
    # records for this checkout. The old inline version compared every
    # pocket-ic on the machine against the :8000 listener — no cwd filter at
    # all — so with other projects' replicas running (a normal machine
    # state) EVERY local deploy tripped this warning on a foreign master.
    for pid in $(mdx_stray_masters || true); do
      warn "zombie pocket-ic master (pid $pid) — the local network is half-alive:"
      warn "outcalls/inter-canister calls will fail even though deploys succeed."
      warn "Run 'bash scripts/cold_start.sh' to restart the network cleanly first."
      yesno "Deploy anyway onto the degraded network?" || die "Aborted — clean the network first."
      break
    done
  fi
  export VITE_CLOUD_ENGINE=false
  # A plain deploy never seeds. The consistent first-install/update flow is
  # `./scripts/deploy.sh local|cloud|subnet`.
  # Passthrough args are the caller's own; if they name no identity, icp
  # falls back to the machine-global default — which other sessions and
  # connectors move at will (mdex-process-safety §5). Warn, don't die: the
  # legacy interface stays, but inheriting the default silently is how a
  # deploy ends up signed by whatever identity the last tool left active.
  case " ${PASS[*]:-} " in
    *" --identity "*) ;;
    *) warn "no --identity in the passthrough args — icp will sign as the machine-global default identity; pass --identity explicitly (mdex-process-safety §5)" ;;
  esac
  info "Plain passthrough (cycles warning active; no wiring/seeding). Running: icp deploy ${PASS[*]:-}"
  exec icp deploy ${PASS[@]+"${PASS[@]}"}
fi

# ── local: the pocket-ic replica ─────────────────────────────────
# First install (no AMM pools yet — fresh replica, wiped or half-seeded
# exchange) → the full #play bring-up: cold_start.sh brings the network up,
# deploys, tops up cycles, and runs play_start.sh (reinstall + $1M AMM vault +
# $50k insurance fund + maker ladder + bots + frontend). Pools already seeded
# → update only: cold_start --no-seed rebuilds and UPGRADE-installs, re-wires,
# tops up — trading state, vault and insurance are preserved.
if [ "$TARGET" = "local" ]; then
  export VITE_CLOUD_ENGINE=false
  if [ -z "$SEED" ]; then
    if echo "y" | icp canister call backend getAmmPools "()" --query --identity anonymous 2>/dev/null | grep -q "record"; then
      SEED=false; info "Local target: AMM pools exist — updating the wasm in place (state preserved)."
    else
      SEED=true;  info "Local target: no AMM pools yet — first install, full #play bring-up (deploy + seed)."
    fi
  fi
  if truthy "$SEED"; then
    exec bash scripts/cold_start.sh ${PASS[@]+"${PASS[@]}"}
  else
    exec bash scripts/cold_start.sh --no-seed ${PASS[@]+"${PASS[@]}"}
  fi
fi

# ── subnet: dedicated IC subnet — guided, all-in-one ─────────────
# The canister pays its OWN cycles here (docs/deploy-to-subnet.md §0), so
# unlike the cloud engine: cycles checking stays ON (VITE_CLOUD_ENGINE=false —
# on a subnet the low-cycles warning is the alarm you WANT), the backend is
# endowed at CREATE time (runbook §1's "huge buffer"), and scripts/topup.sh
# keeps backend + archives + bridge fed afterwards. setFuelRoute and
# setXrcCanister stay UNWIRED per the launch policy (§3/§4) — never touched.
if [ "$TARGET" = "subnet" ]; then
  export VITE_CLOUD_ENGINE=false
  CE_ENV="subnet"   # icp.yaml environment: the multidex.ai stack's own id mapping
  info "Subnet mode: the canister pays its own cycles; cycles checking stays ON."
  load_subnet_conf
  $RECONFIGURE && { SN_IDENTITY=""; SN_SUBNET=""; }

  # Identity: a normal funded wallet identity that already exists locally —
  # NOT a console-linked engine identity (that flow is cloud-only).
  if [ -z "$SN_IDENTITY" ] || ! icp identity principal --identity "$SN_IDENTITY" >/dev/null 2>&1; then
    [ -n "$SN_IDENTITY" ] && warn "saved identity '$SN_IDENTITY' no longer resolves — re-asking."
    SN_IDENTITY="$(ask 'Funded wallet identity to deploy with (icp identity list):')"
    [ -n "$SN_IDENTITY" ] || die "A wallet identity is required for a subnet deploy."
    icp identity principal --identity "$SN_IDENTITY" >/dev/null 2>&1 \
      || die "Identity '$SN_IDENTITY' not found — create/import it first, then re-run."
  fi
  PRINCIPAL="$(icp identity principal --identity "$SN_IDENTITY" 2>/dev/null | tail -1)"
  ok "Deploying as '$SN_IDENTITY' ($PRINCIPAL)"

  if [ -z "$SN_SUBNET" ]; then
    SN_SUBNET="$(ask 'Dedicated subnet id:')"
    [ -n "$SN_SUBNET" ] || die "A subnet id is required for a subnet deploy."
  fi
  # Production origins: the FRONTEND_ORIGINS env both applies now AND becomes
  # the remembered value; otherwise the conf's saved value is used.
  [ -n "${FRONTEND_ORIGINS:-}" ] && SN_FRONTEND_ORIGINS="$FRONTEND_ORIGINS"
  save_subnet_conf
  ok "Saved config to $SUBNET_CONF (identity=$SN_IDENTITY, subnet=$SN_SUBNET)"

  # First install vs update: probe the backend. Only a CREATE gets the cycle
  # endowment (--cycles applies at creation; an upgrade keeps its balance).
  CE_IDENTITY="$SN_IDENTITY"; CE_SUBNET="$SN_SUBNET"; CE_FRONTEND_ORIGINS="$SN_FRONTEND_ORIGINS"
  CREATE_CYCLES=""
  if icp canister status backend -e "$CE_ENV" --identity "$SN_IDENTITY" >/dev/null 2>&1; then
    info "Backend exists — UPDATE deploy: upgrade install, state preserved, seeding will self-skip."
  else
    CREATE_CYCLES="${SUBNET_CYCLES:-5000t}"
    info "First install — backend will be created with a $CREATE_CYCLES endowment (runbook §1)."
  fi

  remote_deploy

  # Anti-sybil canister env vars (runbook §3b) — re-asserted on every deploy
  # from the conf's remembered production origins; see apply_anti_sybil_settings.
  apply_anti_sybil_settings
  # W6-09: read the env var BACK and diff it against II_PINNED_ORIGINS.
  # apply_anti_sybil_settings warns-and-continues when its update fails, and
  # a warn in a deploy scroll is how sign-in stayed down (2026-07-11).
  bash "$(cd "$(dirname "$0")" && pwd)/check_origins.sh" --env "$CE_ENV" --identity "$CE_IDENTITY" \
    || die "deployed frontend_origins do not match II_PINNED_ORIGINS (main.js) — Verify-with-Google fails closed; re-assert per runbook §3b"
  # W4-20: verify the DEPLOYED asset canister actually serves the security
  # headers the config promises — configuration is not a response header.
  for origin in $(printf '%s' "${SN_FRONTEND_ORIGINS:-}" | tr ',' ' '); do
    case "$origin" in
      https://*) bash "$(cd "$(dirname "$0")" && pwd)/check_headers.sh" "$origin" \
                   || die "security headers missing on $origin — the shipped CSP is not what the config promised" ;;
    esac
    break   # the first https origin is the canonical public one
  done

  maybe_seed

  # Bots run from an operator box (tmux/systemd), not from this one-shot
  # script — runbook §3.6. sim_trading.sh's self-heal replenisher reads
  # CE_IDENTITY from scripts/.cloud-engine.conf, so point that at the wallet.
  FRONTEND_ID="$(icp canister status frontend -e "$CE_ENV" --identity "$SN_IDENTITY" 2>/dev/null | awk -F': ' '/^Canister Id/{print $2; exit}' | tr -d '[:space:]')"
  echo ""
  ok "Subnet deploy complete."
  info "Next steps (runbook: docs/deploy-to-subnet.md):"
  echo "  cycles cron : BACKEND=${BACKEND_ID:-<backend-id>} WALLET=<cycles-wallet> ./scripts/topup.sh   # every 15 min (§1)"
  echo "  bots        : BOT_IDENTITY=$SN_IDENTITY IC_ENV="$CE_ENV" bash scripts/sim_trading.sh 12 2   # keep alive in tmux/systemd (§3.6)"
  echo "  domain      : .well-known/ic-domains + DNS + boundary registration BEFORE announcing (§3.5)"
  echo "  env vars    : re-run with FRONTEND_ORIGINS=… after the domain lands (§3b, per-origin II!)"
  [ -n "$FRONTEND_ID" ] && echo "  frontend    : https://$FRONTEND_ID.icp0.io"
  exit 0
fi

# ── engine: OpenCloud cloud engine — guided, all-in-one ──────────
# Unreachable as a rejection now (canonical_target already died on anything
# else), but kept as a belt-and-braces assert: if a new target is ever added
# to canonical_target without a branch here, this fails loudly instead of
# running the engine flow against it.
[ "$TARGET" = "engine" ] || die "Internal error: target '$TARGET' has no deploy branch (expected local | engine | subnet)."
export VITE_CLOUD_ENGINE=true
CE_ENV="engine"   # icp.yaml environment: the cloud-engine stack's own id mapping
info "Cloud-engine mode: the engine pays for compute; the no-cycles warning will be suppressed."
load_conf
$RECONFIGURE && { CE_IDENTITY=""; CE_SUBNET=""; }

# 1) Engine identity — link one if we don't have a usable one yet.
# Existence probe WITHOUT a pipeline: `icp identity list | grep -q` under
# `set -o pipefail` races SIGPIPE (grep exits at first match, the producer
# dies 141, pipefail fails the pipeline) and misreads a linked identity as
# missing — then the re-link dies on "identity already exists".
if [ -z "$CE_IDENTITY" ] || ! icp identity principal --identity "$CE_IDENTITY" >/dev/null 2>&1; then
  warn "No linked engine identity found — linking one now (a one-time, per-machine step)."
  CE_CONSOLE="$(ask 'Console URL you sign in to your engine with:' "$CE_CONSOLE")"
  CE_IDENTITY="$(ask 'A local name for this engine identity:' "${CE_IDENTITY:-mdex-engine}")"
  info "Linking '$CE_IDENTITY' against $CE_CONSOLE — press Enter when prompted, then sign in with Internet Identity in the browser."
  icp identity link web "$CE_IDENTITY" --auth "$CE_CONSOLE" \
    || die "Identity link did not complete. First time? Enable 'CLI access' for your identity in the II settings, then re-run. (Skill: Step 1 / Pitfall 1.)"
fi
# No global "activation" step: setting the CLI's default identity here flips
# machine-shared state under every other session, checkout, and connector on
# this box (mdex-process-safety §5 — observed rug-pulling parallel
# workstreams, 2026-08-06). Every icp command in this flow names --identity
# explicitly, so all we need is proof the identity resolves.
PRINCIPAL="$(icp identity principal --identity "$CE_IDENTITY" 2>/dev/null || true)"
[ -n "$PRINCIPAL" ] || die "Identity '$CE_IDENTITY' unusable (web delegation expired?) — run: icp identity reauth $CE_IDENTITY"
ok "Deploying as '$CE_IDENTITY' ($PRINCIPAL)"

# 2) Subnet id — required; remembered once given.
if [ -z "$CE_SUBNET" ]; then
  warn "Your engine's subnet id is on its App Center / Applications page in the console."
  CE_SUBNET="$(ask 'Engine subnet id:')"
  [ -n "$CE_SUBNET" ] || die "A subnet id is required for a cloud-engine deploy."
fi
# Production origins: the FRONTEND_ORIGINS env both applies now AND becomes
# the remembered value; otherwise the conf's saved value is used.
[ -n "${FRONTEND_ORIGINS:-}" ] && CE_FRONTEND_ORIGINS="$FRONTEND_ORIGINS"
save_conf
ok "Saved config to $CONF (identity=$CE_IDENTITY, subnet=$CE_SUBNET)"

# 3) Deploy backend → bridge (wired) → keys → frontend. Shared with the
#    subnet branch; the engine pays for compute, so no CREATE endowment.
CREATE_CYCLES=""
remote_deploy

# 3b) Re-assert the production frontend_origins (a reinstall re-stamps the
#     yaml's local-dev list — see apply_anti_sybil_settings).
apply_anti_sybil_settings
# W6-09: read-back gate, same as the subnet flow — but the engine's origins
# live only in its conf (main.js pins the subnet's), so diff against those;
# skip when none are recorded (apply_anti_sybil_settings already warned).
if [ -n "${CE_FRONTEND_ORIGINS:-}" ]; then
  bash "$(cd "$(dirname "$0")" && pwd)/check_origins.sh" --env "$CE_ENV" --identity "$CE_IDENTITY" --expect "$CE_FRONTEND_ORIGINS" \
    || die "deployed frontend_origins do not match the conf's recorded origins — Verify-with-Google fails closed; re-assert per runbook §3b"
fi
# W4-20: same header verification as the subnet flow, when a public origin
# is recorded for the engine.
for origin in $(printf '%s' "${CE_FRONTEND_ORIGINS:-}" | tr ',' ' '); do
  case "$origin" in
    https://*) bash "$(cd "$(dirname "$0")" && pwd)/check_headers.sh" "$origin" \
                 || die "security headers missing on $origin — the shipped CSP is not what the config promised" ;;
  esac
  break
done

# 4) Seed (default YES, idempotent — see maybe_seed).
maybe_seed

# 5) Optional trading bots — keep the market live with continuous fills.
if [ -z "$RUN_BOTS" ]; then
  if yesno "Run trading bots so the market keeps trading (background; TEST mode only)?"; then RUN_BOTS=true; else RUN_BOTS=false; fi
fi
if truthy "$RUN_BOTS"; then cloud_bots; fi

ok "All done — open your app from the engine console's Applications page (the frontend canister's “Open” button)."
