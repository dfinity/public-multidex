#!/bin/bash
# UPLANDS DEX — Historical Trade Injector
#
# Fetches N days of hourly USD prices from CoinGecko for BTC / ETH /
# ICP and injects them as trades into the local canister via
# injectHistoricalTrades. Result: /markets chart has a realistic
# multi-week backdrop before the simulation takes over.
#
# Writes a side-effect file that downstream scripts read:
#   $MDX_ORACLE_PRICES  (default: <repo>/.run/oracle-prices.txt)
#     Format: "SYMBOL PRICE" per line, e.g.
#       BTC 75412.3
#       ETH 2305.01
#       ICP 2.471
#     Only assets with a successful fetch appear. seed.sh consumes
#     this so it doesn't have to hardcode stale "spot ~X" values for
#     AMM seeding — the AMM always starts at the latest oracle price.
#
# POSTURE: injectHistoricalTrades is GENESIS-gated (docs/deployment-modes.md,
# "The genesis window"): #dev always · #play only until the venue's first
# enableAmm · #production never. This script probes the gate with an empty
# batch before fetching anything and exits 2 with the canister's own refusal
# when the window is closed — so run it BEFORE AMM enable in any #play
# bring-up (play_start.sh step 4 → 5, deploy.sh step 2 → 2b already do).
#
# Usage: bash scripts/inject_history.sh [--days N] [--identity NAME]
#        IC_ENV=engine|subnet bash scripts/inject_history.sh --days 14 --identity <controller>
#          → inject into a deployed canister (e.g. a cloud engine) instead of local

set -o pipefail
export PATH="$HOME/.local/bin:$PATH"

# Scratch-file locations (.run/, not fixed names under sticky /tmp) — see
# scripts/lib/runfiles.sh. Honours an inherited MDX_RUN_DIR, so when a parent
# (deploy.sh / play_start.sh / seed.sh) spawns this script both agree on where
# the price snapshot lives.
# shellcheck source=scripts/lib/runfiles.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/runfiles.sh"

# Target network. Unset/empty = the icp default (local replica). Set
# IC_ENV=engine|subnet to inject into a DEPLOYED canister — the calls below get
# `-e <env>`. It must name a DECLARED icp.yaml environment: `ic` is a bare
# network alias, and none of our canisters are mapped under it.
# The --identity must be authorised for injectHistoricalTrades (a
# canister controller on that network).
ENV_FLAG=""
[ -n "${IC_ENV:-}" ] && ENV_FLAG="-e ${IC_ENV}"

DAYS=9
IDENTITY="alice"
while [ $# -gt 0 ]; do
  case "$1" in
    --days)     DAYS="$2";     shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${CYAN}▶${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
# warn goes to STDERR: cg_fetch/fallback_fetch run inside command
# substitution, and a stdout warn would be CAPTURED INTO THE FETCHED BODY —
# "  \x1b[1;33m!… rate-limited…\n{json}" is unparseable at char 2. This was
# why the run's FIRST asset (BTC, whose attempt 1 hits the 429 the canister's
# own oracle feed keeps warm) failed every seeding while the later, paced
# assets succeeded.
warn() { echo -e "  ${YELLOW}!${NC} $1" >&2; }
err()  { echo -e "  ${RED}✗${NC} $1" >&2; }

icp identity new "$IDENTITY" --storage plaintext 2>/dev/null || true

CG_ID_BTC="bitcoin"
CG_ID_ETH="ethereum"
CG_ID_SOL="solana"
CG_ID_ICP="internet-computer"
QTY_BTC="0.05"
QTY_ETH="0.5"
QTY_SOL="0.5"
QTY_ICP="50.0"

# Which assets to (re)inject — lets a failed asset be retried alone without
# double-injecting the ones that succeeded (duplicate trades would corrupt
# the candles). e.g.: INJECT_ASSETS=BTC bash scripts/inject_history.sh
INJECT_ASSETS="${INJECT_ASSETS:-BTC ETH SOL ICP}"
want() { case " $INJECT_ASSETS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ── Posture probe — fail fast and HONESTLY when the canister refuses ──
# An empty batch is side-effect-free (zero records injected, stats untouched)
# but still runs the full gate chain: controller check + the genesis-window
# posture gate. When the gate refuses (#err on the current build, a dev-only
# trap on pre-window builds), every chunk of every asset would fail the same
# way — historically that surfaced as per-asset chunk errors which the
# callers then blamed on "CoinGecko rate limits", after burning a minute of
# fetches. Probe first; refusal here is a posture fact, not a data problem.
FIRST_ASSET=$(echo $INJECT_ASSETS | awk '{print $1}')
probe_out=$(echo y | icp canister call $ENV_FLAG backend injectHistoricalTrades \
    "(\"${FIRST_ASSET:-BTC}-ICPUSD\", vec {})" --identity "$IDENTITY" 2>&1)
probe_rc=$?
if [ "$probe_rc" -ne 0 ] || echo "$probe_out" | grep -q "err"; then
  err "injectHistoricalTrades probe REFUSED before any data was fetched — not a CoinGecko problem. The call said:"
  err "  $(echo "$probe_out" | grep -m1 -iE 'genesis|dev-only|production|err|reject|trap' | sed 's/^[[:space:]]*//' | head -c 220)"
  err "  (posture gate — #dev: always · #play: only before the venue's first enableAmm · #production: never;"
  err "   a transport/identity failure prints its own error above instead)"
  exit 2
fi

PRICES_FILE="$MDX_ORACLE_PRICES"
# Upsert semantics: drop only the lines for assets injected THIS run — a
# selective INJECT_ASSETS run must not wipe the other assets' snapshot
# (play_start.sh and the simulator anchor from this file).
if [ -f "$PRICES_FILE" ]; then
  _pat=$(echo "$INJECT_ASSETS" | tr ' ' '|')
  grep -vE "^(${_pat}) " "$PRICES_FILE" > "${PRICES_FILE}.tmp" 2>/dev/null || true
  mv "${PRICES_FILE}.tmp" "$PRICES_FILE"
else
  > "$PRICES_FILE"
fi

# ── Inter-request delay ─────────────────────────────────────────
# CoinGecko's free tier is ~30 req/min on a shared pool. Three rapid
# calls back-to-back routinely trip the limit on busy shared IPs.
# Space them 5s apart; a 429 drops straight to the fallback sources.
CG_PACE_SEC=5

# CoinGecko API base. Overridable so a test can point cg_fetch at a stub
# (e.g. a local server that always answers 429) without touching the network.
CG_BASE="${CG_BASE:-https://api.coingecko.com/api/v3}"

# ── Per-asset history cache (machine-shared, hour-keyed) ─────────
# Every factory seat's cold_start fetches the SAME 14-day series for the same
# four assets, from a free tier that is one shared pool per machine — N seats
# reseeding means N upstream fetches and N chances at a 429. The cache makes
# it one: the first seat to fetch (from CoinGecko OR a fallback — both are in
# the normalised {"prices":[...]} shape) writes the body, later seats read it.
#   Location  $MDX_HISTORY_CACHE_DIR, default ~/.cache/multidex/history — a
#             machine-wide dir the operator owns (NOT .run/, which is per
#             worktree and so would dedupe nothing; NOT /tmp, sticky+plantable).
#             Set it EMPTY to disable (the 429 test does).
#   Key       <ASSET>-<DAYS>d-<UTC YYYYMMDDHH>.json — HOUR-keyed, not day-
#             keyed: the series' last anchor becomes the AMM opening mark
#             (seed.sh step 3 prefers this snapshot over the live aggregate),
#             and a day-stale mark can sit outside the breaker band and pend
#             every leg of the first post-seed tick (task 3088500128). Sources
#             update hourly anyway, so an hour key loses no freshness.
#   Safety    write = mktemp in the dir + mv -f (atomic on one filesystem), so
#             a concurrent seat reads a whole old file or a whole new one,
#             never a torn one; entries older than a day are pruned on start.
#             Best effort: two seats fetching in the same second both go
#             upstream — fine, that is today's behaviour.
MDX_HISTORY_CACHE_DIR="${MDX_HISTORY_CACHE_DIR-$HOME/.cache/multidex/history}"
if [ -n "$MDX_HISTORY_CACHE_DIR" ]; then
  mkdir -p "$MDX_HISTORY_CACHE_DIR" 2>/dev/null || MDX_HISTORY_CACHE_DIR=""
fi
[ -n "$MDX_HISTORY_CACHE_DIR" ] && \
  find "$MDX_HISTORY_CACHE_DIR" -maxdepth 1 -name '*.json' -mmin +1440 -delete 2>/dev/null
cache_path() { echo "${MDX_HISTORY_CACHE_DIR}/$1-${DAYS}d-$(date -u +%Y%m%d%H).json"; }
# stdout = the cached body (same contract as cg_fetch: NOTHING else on stdout).
cache_get() {
  [ -n "$MDX_HISTORY_CACHE_DIR" ] || return 1
  local f; f=$(cache_path "$1")
  [ -s "$f" ] && grep -q '"prices"' "$f" || return 1
  warn "  serving $1 from the history cache ($f)"
  cat "$f"
}
cache_put() {
  [ -n "$MDX_HISTORY_CACHE_DIR" ] || return 0
  local f tmp; f=$(cache_path "$1")
  [ -s "$f" ] && return 0
  tmp=$(mktemp "${MDX_HISTORY_CACHE_DIR}/.tmp.XXXXXX") || return 0
  printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$f" || rm -f "$tmp"
}

# Fetch with up to `tries` attempts, exponential backoff on transport errors
# and 200-but-garbage (HTML interstitials, truncation) — the cases where
# retrying the SAME source is what actually helps. A 429 (or an error_code
# body, CoinGecko's other way of saying it) is different: the free tier is one
# shared pool per machine, so on a factory host a 429 means the pool is busy
# for the next minute or more and backing off 8/16/32/64s just burns two
# minutes per asset before the fallbacks inject the identical series
# (measured 2026-09-04: ~4 min of a ~16 min reseed). So a 429 returns non-zero
# AT ONCE and the caller drops to fallback_fetch (Binance / Coinbase — keyless,
# separate rate pools). Success requires a 200 whose body actually contains
# the "prices" array. NOTE: this function runs inside command substitution, so
# it must write NOTHING but the body to stdout — see warn().
cg_fetch() {
  local url="$1" tries=4 wait_s=8
  local attempt=1
  while [ "$attempt" -le "$tries" ]; do
    local body http_code
    body=$(curl -sS --max-time 30 -w "\n%{http_code}" "$url") || body=""
    http_code=$(echo "$body" | tail -n1)
    body=$(echo "$body" | sed '$d')
    if [ "$http_code" = "200" ] && echo "$body" | grep -q '"prices"'; then
      echo "$body"
      return 0
    fi
    if [ "$http_code" = "429" ] || echo "$body" | grep -q '"error_code"'; then
      warn "  rate-limited (HTTP ${http_code:-none}, attempt $attempt/$tries) — CoinGecko pool busy, dropping to fallback sources"
      return 1
    fi
    # 200-but-garbage / transport error — log the head so the cause is
    # visible, then retry the same source with backoff.
    warn "  unexpected response (HTTP ${http_code:-none}: $(echo "$body" | head -c 80 | tr -d '\n')…) — attempt $attempt/$tries, sleeping ${wait_s}s"
    sleep "$wait_s"
    wait_s=$(( wait_s * 2 ))
    attempt=$(( attempt + 1 ))
  done
  err "  exhausted retries"
  return 1
}

# Fallback sources when CoinGecko won't serve an asset at all: Binance hourly
# klines, then Coinbase Exchange hourly candles (≤300h). Both are keyless and
# on separate rate pools. Output is transformed to the CoinGecko shape
# ({"prices":[[ts_ms, px], ...]}) so the parser below doesn't care where the
# data came from.
fallback_fetch() {
  local asset="$1" days="$2" body
  local limit=$(( days * 24 + 1 )); [ "$limit" -gt 1000 ] && limit=1000

  body=$(curl -sS --max-time 30 "https://api.binance.com/api/v3/klines?symbol=${asset}USDT&interval=1h&limit=${limit}" 2>/dev/null) || body=""
  if [ "${body:0:2}" = "[[" ]; then
    warn "  falling back to Binance klines for $asset"
    python3 - "$body" <<'PY'
import json, sys
ks = json.loads(sys.argv[1])                       # [openMs, open, high, low, close, vol, closeMs, ...]
pts = [[int(k[0]), float(k[1])] for k in ks]
if ks: pts.append([int(ks[-1][6]), float(ks[-1][4])])   # final close anchors the last hour
print(json.dumps({"prices": pts}))
PY
    return $?
  fi

  body=$(curl -sS --max-time 30 -A "uplands-seed/1.0" "https://api.exchange.coinbase.com/products/${asset}-USD/candles?granularity=3600" 2>/dev/null) || body=""
  if [ "${body:0:2}" = "[[" ]; then
    warn "  falling back to Coinbase candles for $asset (≤300h window)"
    python3 - "$body" <<'PY'
import json, sys
cs = sorted(json.loads(sys.argv[1]))               # [t_s, low, high, open, close, vol] newest-first → ascending
pts = [[c[0] * 1000, float(c[3])] for c in cs]
if cs: pts.append([cs[-1][0] * 1000 + 3_599_000, float(cs[-1][4])])
print(json.dumps({"prices": pts}))
PY
    return $?
  fi
  return 1
}

# ── Fetch + inject one asset ─────────────────────────────────────
inject_one() {
  local asset="$1" market_id="$2" coin_id="$3" qty="$4"
  log "$asset ($market_id) — fetching $DAYS days hourly from CoinGecko"

  local url="${CG_BASE}/coins/${coin_id}/market_chart?vs_currency=usd&days=${DAYS}&interval=hourly"
  local raw
  raw=$(cache_get "$asset") \
    || raw=$(cg_fetch "$url") \
    || raw=$(fallback_fetch "$asset" "$DAYS") \
    || return 1
  cache_put "$asset" "$raw"

  # CoinGecko returns `{"prices":[[ts_ms,price], ...], ...}` — ONE price per
  # hour. Injecting one trade per hour makes every 1h candle a single point
  # (open=high=low=close) with flat volume — "price levels", not candles. So we
  # treat each consecutive hourly pair as a candle's (open, close) and SYNTHESIZE
  # several intra-hour trades that walk open→close with noise (→ real bodies +
  # wicks) at VARIED quantities, shaped by a diurnal rhythm and coupled to each
  # hour's volatility (→ organic volume bars). Backend getCandles re-aggregates
  # the trade stream into OHLCV per interval, so it looks like a live exchange
  # the moment it's seeded. Output: one candid `record {...}` per line (split on
  # newline so the inner `;`s don't break batching); plus the latest HUMAN price
  # to $PRICES_FILE for seed.sh (which scales it with its own e8()).
  # injectHistoricalTrades is display-only (maker=taker=AMM, no settlement), so
  # trade size never touches balances.
  local parse_out
  parse_out=$(python3 - "$raw" "$qty" "$asset" "$PRICES_FILE" <<'PY'
import json, sys, math, random, os
raw = sys.argv[1]; base_qty = float(sys.argv[2]); asset = sys.argv[3]; prices_file = sys.argv[4]
try:
  data = json.loads(raw)
except Exception as e:
  # Keep the evidence: the head repr shows invisible bytes, and the full dump
  # answers "what did the API actually send" without re-reproducing.
  print(f"# parse error: {e}; len={len(raw)}; head={raw[:60]!r}", file=sys.stderr)
  # Alongside the price snapshot (the .run/ dir), not a fixed /tmp name.
  try: open(os.path.join(os.path.dirname(prices_file) or ".", f"inject-fail-{asset}.txt"), "w").write(raw)
  except Exception: pass
  sys.exit(1)
prices = data.get("prices", [])
if not prices:
  print("# no prices array", file=sys.stderr); sys.exit(1)

# Anchors: (ts_ms, price), ascending, positive only.
anchors = sorted((int(ts), float(p)) for ts, p in prices if p and p > 0)
if not anchors:
  print("# no positive prices", file=sys.stderr); sys.exit(1)

BASE_K   = 7        # avg trades per hourly candle (varied per bucket)
BASE_VOL = 0.0018   # 0.18% baseline intra-hour price noise (wick scale)

def rec(t_ms, px, q):
  if px <= 0: return None
  return (f"record {{ price = {int(round(px*1e8))} : nat; "
          f"quantity = {max(1, int(round(q*1e8)))} : nat; "
          f"timestamp = {int(t_ms)*1_000_000} : int }}")

recs = []
if len(anchors) < 2:
  ts, p = anchors[-1]
  recs.append(rec(ts, p, base_qty))
else:
  for i in range(len(anchors) - 1):
    ts0, o = anchors[i]
    ts1, c = anchors[i + 1]
    span = max(1, ts1 - ts0)
    hod  = (ts0 // 3_600_000) % 24                         # hour-of-day (UTC)
    diurnal = 0.7 + 0.6 * (0.5 + 0.5 * math.sin(2*math.pi*(hod - 8)/24.0))
    move = abs(c - o) / o if o else 0.0                    # this hour's move
    sigma = max(o * BASE_VOL, abs(c - o) * 0.45)           # wicks scale with move
    vol_factor = 1.0 + min(move * 12.0, 3.0)               # busier on big moves
    k = max(3, min(28, int(round(BASE_K * diurnal * vol_factor * random.uniform(0.6, 1.4)))))
    for j in range(k):
      if   j == 0:     px = o                              # candle OPEN  (first trade)
      elif j == k - 1: px = c                              # candle CLOSE (last trade)
      else:            px = o + (c - o) * (j/(k-1)) + random.gauss(0.0, sigma)
      # strictly-increasing timestamp inside the bucket (slot j gets [j, j+0.9])
      t_ms = min(ts1 - 1, ts0 + int(span * (j + random.uniform(0.0, 0.9)) / k))
      q = base_qty * diurnal * random.uniform(0.35, 2.4) * (1.0 + move * 2.0)
      r = rec(t_ms, px, q)
      if r: recs.append((t_ms, r))
  recs.sort(key=lambda x: x[0])
  recs = [r for _, r in recs]

with open(prices_file, "a") as f:
  f.write(f"{asset} {anchors[-1][1]}\n")
print("\n".join(r for r in recs if r))
PY
  )
  if [ -z "$parse_out" ]; then
    err "  no price points parsed"
    return 1
  fi

  # Split the parsed output on newline (which does NOT appear inside
  # records). The previous approach used IFS=';' which split _inside_
  # records (each record contains 3 internal `;` for price, quantity,
  # timestamp), producing malformed Candid when those fragments were
  # batched. mapfile/readarray reads the whole string into the array
  # element-per-line, regardless of macOS bash version differences.
  local REC_ARR=()
  while IFS= read -r line; do
    [ -n "$line" ] && REC_ARR+=("$line")
  done <<< "$parse_out"

  local n_records=${#REC_ARR[@]}
  log "  injecting $n_records samples"

  # Chunk the injection — Candid argument size gets unwieldy past ~500
  # records per call. 250 per call is comfortably under the limit.
  # NOTE both calls carry $ENV_FLAG: the final-chunk call used to omit it,
  # so on a remote run (IC_ENV=ic) the last ≤250 samples of EVERY asset went
  # to the LOCAL replica — where the remote identity isn't a controller —
  # and 'failed' silently. Local runs never showed it (empty ENV_FLAG makes
  # the calls identical). Failures also echo the CLI's error line now
  # instead of being swallowed.
  local batch="" batch_count=0 total=0 errors=0 out
  for r in "${REC_ARR[@]}"; do
    batch+="$r;"
    batch_count=$(( batch_count + 1 ))
    if [ "$batch_count" -ge 250 ]; then
      # Failure = a non-zero exit (reject/trap/transport) OR a typed #err in
      # the reply — the genesis-window refusal is #err, which exits 0.
      out=$(echo y | icp canister call $ENV_FLAG backend injectHistoricalTrades \
          "(\"$market_id\", vec { $batch })" --identity "$IDENTITY" 2>&1)
      if [ $? -ne 0 ] || echo "$out" | grep -q "err"; then
        err "  chunk injection failed: $(echo "$out" | grep -m1 -iE "err|reject|trap|genesis" | head -c 200)"
        errors=$(( errors + 1 ))
      fi
      total=$(( total + batch_count ))
      batch=""; batch_count=0
    fi
  done
  if [ -n "$batch" ]; then
    out=$(echo y | icp canister call $ENV_FLAG backend injectHistoricalTrades \
        "(\"$market_id\", vec { $batch })" --identity "$IDENTITY" 2>&1)
    if [ $? -ne 0 ] || echo "$out" | grep -q "err"; then
      err "  final chunk failed: $(echo "$out" | grep -m1 -iE "err|reject|trap|genesis" | head -c 200)"
      errors=$(( errors + 1 ))
    fi
    total=$(( total + batch_count ))
  fi
  if [ "$errors" -gt 0 ]; then
    warn "  $errors chunk(s) failed out of $total samples"
    return 1
  fi
  ok "  $total trades injected for $market_id"
}

# ── Main — pace requests to stay under CG's free tier ────────────
FAILURES=0
want BTC && { inject_one BTC BTC-ICPUSD "$CG_ID_BTC" "$QTY_BTC" || FAILURES=$(( FAILURES + 1 )); sleep "$CG_PACE_SEC"; }
want ETH && { inject_one ETH ETH-ICPUSD "$CG_ID_ETH" "$QTY_ETH" || FAILURES=$(( FAILURES + 1 )); sleep "$CG_PACE_SEC"; }
want SOL && { inject_one SOL SOL-ICPUSD "$CG_ID_SOL" "$QTY_SOL" || FAILURES=$(( FAILURES + 1 )); sleep "$CG_PACE_SEC"; }
want ICP && { inject_one ICP ICP-ICPUSD "$CG_ID_ICP" "$QTY_ICP" || FAILURES=$(( FAILURES + 1 )); }

echo ""
if [ -s "$PRICES_FILE" ]; then
  log "oracle snapshot → $PRICES_FILE"
  while IFS= read -r line; do echo "  $line"; done < "$PRICES_FILE"
fi

if [ "$FAILURES" -gt 0 ]; then
  # The posture probe passed at startup, so these are fetch-side failures
  # (rate limits / bad data) — or the per-chunk lines above say otherwise.
  echo -e "${YELLOW}History injection completed with $FAILURES failures (posture probe was OK — see per-asset errors above).${NC}" >&2
  exit 1
fi
echo -e "${GREEN}Historical backfill complete.${NC}"
