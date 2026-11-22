#!/bin/bash
# tests/test_liq_direction.sh
#
# #54.8 (OhShii round 18): the liquidation-distance DISPLAY surfaces take their
# direction from liqPrice's own algebra and their "already past" from the
# health verdict — never from the net-size sign, never from mark-vs-price.
#
# The fixture is the slope case of tests/MarginPools.test.mo, built LIVE on a
# margin pool and scaled by K: 10K SOL held, 9K SOL owed, cash = 2K × mark.
# The pool is NET LONG (+K SOL) yet A = heldBase·ltv − M·debtBase =
# K·(8.5 − 10.35) < 0, so it liquidates on a RISING mark at
# P = cash / 1.85K ≈ 1.081 × mark:
#   at the live mark m   → healthy (health 1.167 > 1.15), distance +8.1% UP;
#   at 1.2 × m           → liquidatable (health 1.13 < 1.15).
# K is DERIVED from the live mark (task 1793559065): K = ceil($100 / m) + 1,
# so the net leg's notional K·m ≥ $100 + m clears the Markets bar's $100
# DUST FLOOR at any mark — main.mo's tickMarketSideAgg sums each pool's
# |net| × mark into the side notional, roundUsd FLOORS it to the
# HEAT_ROUND_USD_E8 ($100) grid, and sideHealth / nearLiq disclose NOTHING
# for a side that rounds to $0 ("a side that displays as $0 must not display
# a health"). At K = 1 the single +1 SOL leg (≈ $94 at the 2026-11 marks)
# rounded to $0 and §3 redded on every FRESH venue, while a second run's
# second pool summed past the floor and greened: the health / liqPrice /
# pctToLiq algebra is scale-free, the floor is not. K = 2 at any mark
# ≥ $100, 3 at ≈ $94; the +1 keeps the floor strict after the fill's
# interest dust. Tolerated marks: from ≈ $1 up to a few thousand dollars —
# 9K SOL of bids must rest inside §0b's 5% collar (≈ 1067 SOL on a fresh
# seed; §0b reports what it found) and the vault must lend 9K SOL.
# Before the fix the Markets bar read this "Long Liq −0.0%" at m (net long ⇒
# mark − P < 0 ⇒ clamped 0) and "−9.9%" at 1.2m; the Positions row carried an
# unsigned pctToLiq under a "Long" pill. Now both surfaces publish the
# direction (#up) and the verdict (isLiquidatable / longLiquidatable).
#
# What it pins:
#   §1 fixture: a short of 9K SOL fills (owes the base token), then the pool's
#      balances are pinned to the slope shape (setTestBalance on the pool
#      principal — the same route the seeders use)
#   §2 at m: getMyPositions → size +K SOL (net long), liqDir = #up,
#      isLiquidatable = false, liqPrice ABOVE the mark, pctToLiq ≈ 8%
#   §3 at m: getMarketTele (heat beat driven by devTickHeatmaps on the paused
#      venue) → SOL long side: longNotionalUsd ≥ $100 (past the dust floor),
#      longLiquidatable = false, longNearLiqBps > 0
#   §4 at 1.2m: getMyPositions → isLiquidatable = true (the row prints
#      "liquidatable" on this, not on mark-vs-liqPrice)
#   §5 at 1.2m: getMarketTele → longLiquidatable = true (the bar prints
#      "liquidatable" on this)
#
# Needs the #dev hooks (setAmmRefPrice, setTestBalance, setTestTimersPaused,
# devTickHeatmaps) → posture-skips loudly elsewhere. Timers are PAUSED for the
# fixture's life so the liquidation batch (dispatched ahead of the heat beat in
# the same heartbeat) cannot eat the liquidatable pool before the bar sees it,
# and so the real price feed cannot re-stamp the mark mid-section; the mark is
# restored to the live value and timers resumed on exit. Non-destructive: no
# resetExchange, one new pool for a throwaway identity, left healthy.
#
# PRECONDITION (§0): a SEEDED SOL-ICPUSD — an enabled, priced pool AND SOL in
# the vault basket, because §1's short BORROWS the base from the vault and
# sells it into the AMM's bid ladder (a pool + refPrice alone cannot fill
# it). A fresh seed satisfies it; in run_all order it is never true — every
# predecessor that resetExchanges rebuilds only its own market (leaderboard,
# breaker_widening, audit_2026_08_fixes, …), so the suite redded "§0 no
# priced SOL-ICPUSD pool" in place while greening alone (task 1788523488).
# A cold venue is therefore provisioned HERE, the way scripts/seed.sh does
# it and as ALICE — a standing identity inside assert_invariants' default
# I1 holder set, so the LP this mints is countable by every successor's I1
# (a throwaway seeder is deleted with the run and strands its shares — the
# very shape the two predecessors above were fixed for). The mark comes from
# the live oracle aggregate when one exists, else a $100 fixture mark: the
# algebra below is scale-free, and the fixture's scale K (header) is
# re-derived from whichever mark §0b finally pins.
#
# And on BOTH paths (§0b) the suite then re-applies its OWN ladder, inventory
# floor and mark — `seeded` only proves a priced pool with SOL behind it, not
# WHICH ladder: test_initial_margin §E rebuilds SOL-ICPUSD with a 0.5 × 8
# ladder (4 SOL a side) and a synthetic $150 mark, so in run_all order §1's
# 9 SOL short part-filled at ≈5, the deleverage repaid the tail's borrow and
# the pinned "10 held − 9 owed = +1" read 4.95 — eight ✗ that looked like a
# derived-size regression (task 1788556083). The re-apply is the seed's
# config (20bps · 1 SOL · 15 levels · 35bps · 8s), a zero-lean skew target
# at the AMM's CURRENT holding, a FRESH mark (mdx_restamp_mark: pinned to
# the aggregate only when the feed agrees or the pool is unpriced — a one-
# stamp jump to live blows the AMM's volRegime and parks §1's short outside
# its collar; otherwise the pool's own mark, pend cleared), an inventory
# floor through the dev balance hook — which mints NO LP, so I1's Σ holders
# == supply reads exactly what the predecessors left — and a calm gate
# (mdx_calm_ladder) before the bids inside §1's collar are counted. On a
# fresh seed every line is a no-op re-stamp (the floors sit far under the
# seed's $250k legs).

source "$(dirname "$0")/_lib.sh"

echo "── test_liq_direction ──"

[ "$(venue_posture)" = "dev" ] || skip_posture "liq_direction" "setAmmRefPrice / setTestBalance / devTickHeatmaps dev hooks"

MKT="SOL-ICPUSD"
BASE="SOL"
ID=liqdir
mdx_identity_new $ID
P=$(principal_of $ID | tail -1)
[ -n "$P" ] || { _fail "no principal for identity $ID"; finish_test "liq_direction"; }

usr() { call "$@" --identity $ID; }
# first integer of a named field (underscore-stripped); opt nats print as `f = opt (N : nat)`
fld()     { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }
opt_nat() { echo "$2" | tr -d '_' | grep -oE "$1 = opt \([0-9]+" | head -1 | grep -oE "[0-9]+$"; }
# the pool's refPrice for MKT — one record per pool, vec fields nested, so
# split on the record opener (same reader as test_margin_heatmap §0)
pool_ref() {
  call getAmmPools '()' --query | tr -d '_\n' | python3 -c '
import re, sys
mkt = sys.argv[1]
for rec in sys.stdin.read().split("record {"):
    if "marketId = \"" + mkt + "\"" in rec:
        m = re.search(r"refPrice = (\d+)", rec)
        print(m.group(1) if m else 0); sys.exit(0)
print(0)' "$MKT"
}
# one candid record (the one carrying "$1 = $2") out of a vec — getMyPositions /
# getMyMarginPools list EVERY pool of the identity, and a re-run inherits the
# previous run's pool, so every read below is scoped to THIS run's pool id
# Nested-aware (task 1788730982): the pool view now carries vec-of-record
# fields (loans/repayable) beside the nested health record, so a split on
# every `record {` cut the pool record short — this walks braces and returns
# the WHOLE top-level (depth-2) record, nested records included.
rec_with() {
  tr -d '\n' | python3 -c '
import sys
key, val = sys.argv[1], sys.argv[2]
s = sys.stdin.read(); depth = 0; start = None
for i, c in enumerate(s):
    if c == "{":
        depth += 1
        if depth == 2: start = i
    elif c == "}":
        if depth == 2 and start is not None:
            rec = s[start:i + 1]; flat = rec.replace("_", "")
            if (key + " = " + val + " ") in flat or (key + " = " + val + ";") in flat:
                print(rec); sys.exit(0)
        depth -= 1
print("")' "$1" "$2"
}
my_pos()  { usr getMyPositions '()' | rec_with poolId "$PID"; }
my_pool() { usr getMyMarginPools '()' | rec_with id "$PID"; }
stamp() { call setAmmRefPrice "(\"$MKT\", $1 : nat)" >/dev/null; }
release() { stamp "$1"; call requoteAmm "(\"$MKT\")" >/dev/null; }
# the vault basket's SOL leg (base units) — getVaultValue prints
# `basket = record { btc = …; sol = N : nat; … }`
vault_sol() {
  call getVaultValue '()' --query | tr -d '\n' | grep -oE "basket = record \{[^}]*\}" \
    | grep -oE "sol = [0-9_]+" | tr -d '_' | grep -oE "[0-9]+$"
}
# live oracle mark for SOL in e8, or nothing — the same depth-1 `price`
# reader scripts/seed.sh uses (per-source readings nest one level deeper).
# resetExchange clears the aggregates, so a cold venue usually has none.
live_mark_e8() {
  local px
  px=$(call getLastAggregate '("SOL")' --query | awk '
    depth == 1 && $1 == "price" { px = $3 }
    { depth += gsub(/\{/, "{") - gsub(/\}/, "}") }
    END { if (px + 0 > 0) print px }')
  [ -n "$px" ] && e8 "$px"
}
seeded() {
  local m s
  m=$(pool_ref); s=$(vault_sol)
  [ -n "$m" ] && [ "$m" -gt 0 ] && [ -n "$s" ] && [ "$s" -gt 0 ]
}

# Timers are paused for the whole fixture (header) — including the cold-venue
# provisioning below, where the feed would otherwise pend the seed mark as a
# price jump and the LP-deposit freshness gate would then refuse the mint
# (scripts/seed.sh pauses for the same reason). LIFO: resume timers LAST,
# after the mark is restored and the book requoted (registered further down).
call setTestTimersPaused '(true)' >/dev/null
on_exit "call setTestTimersPaused '(false)' >/dev/null 2>&1"

if ! seeded; then
  echo "  (cold venue — $MKT unpriced or no $BASE in the vault (refPrice=$(pool_ref), vault sol=$(vault_sol)): provisioning a seeded pool as alice, seed.sh-style)"
  mdx_identity_ensure alice
  ALICE=$(principal_of alice)
  [ -n "$ALICE" ] || { _fail "§0 no principal for the standing identity alice"; finish_test "liq_direction"; }
  # The pool first, enabled at a provisional mark: the price feed refreshes
  # only ENABLED pools' base tokens (main.mo tickPriceRefresh), so without a
  # SOL market no SOL aggregate ever lands. seed.sh's config; create zeroes
  # refPrice, so it is stamped next.
  call createAmmPool "(\"$MKT\")" >/dev/null 2>&1 || true
  call setAmmConfig "(\"$MKT\", 20:nat, $(e8 1.0):nat, 15:nat, 35:nat)" >/dev/null
  stamp "$(e8 100)"
  call enableAmm "(\"$MKT\", true)" >/dev/null
  # §3/§5 read the Markets bar, and the heatmap DISCLOSES nothing for a market
  # whose base has no oracle aggregate (heatTierFor → "none": longNearLiqBps
  # null, longLiquidatable false) — and resetExchange clears the aggregates,
  # only the price-feed timer ever writes them (main.mo lastAggregates). So a
  # cold venue lets the heartbeat tick once: timers unpaused, a bounded wait
  # for the SOL aggregate (HB_PRICE_NS 30s cadence + outcall latency), then
  # paused again. That live price becomes the seed mark, so the feed never
  # sees the fixture as a jump. No tick (an offline replica) → the $100 mark
  # stays and a loud note: §3/§5 then fail on the missing tier, honestly,
  # rather than skipping.
  call setTestTimersPaused '(false)' >/dev/null
  if wait_for '[ -n "$(live_mark_e8)" ]' 100 5; then
    M0=$(live_mark_e8)
    echo "  (feed ticked — SOL aggregate live at $(from_e8 "$M0"))"
  else
    M0=$(e8 100)
    echo "  ⚠ no SOL oracle aggregate within 100s of unpausing the timers — seeding at a \$100 fixture mark; §3/§5 need an oracle tier and will not disclose"
  fi
  call setTestTimersPaused '(true)' >/dev/null
  stamp "$M0"
  call setTestPendingJump '("SOL", null, null)' >/dev/null 2>&1   # a tick that pended the provisional mark as a jump would freeze the LP-deposit gate
  # seed.sh's per-pool recipe: $500k TVL split 50/50 base/quote at the mark
  # (toward-balance, so the concentration cap never refuses it), skew as
  # seeded, then requote so the bid ladder exists for §1's short to hit.
  QUOTE_E8=$(e8 250000)
  BASE_E8=$(python3 -c "print(int($QUOTE_E8 * 100000000 // $M0))")
  call setTestBalance "(principal \"$ALICE\", \"$BASE\", $BASE_E8 : nat)" >/dev/null
  call setTestBalance "(principal \"$ALICE\", \"ICPUSD\", $QUOTE_E8 : nat)" >/dev/null
  SEEDR=$(call seedAmmPool "(\"$MKT\", $BASE_E8 : nat, $QUOTE_E8 : nat)" --identity alice)
  if ! mdx_ok "$SEEDR"; then
    _fail "§0 could not provision $MKT: seedAmmPool as alice refused — $(echo "$SEEDR" | tr -d '\n' | head -c 240)"
    finish_test "liq_direction"
  fi
  call setAmmSkewConfig "(\"$MKT\", $BASE_E8 : nat, 200:nat)" >/dev/null
  release "$M0"
  if seeded; then
    _ok "§0 provisioned a seeded $MKT as alice: mark $(from_e8 "$M0") · $(from_e8 "$BASE_E8") $BASE + $(from_e8 "$QUOTE_E8") ICPUSD in the vault (LP held by alice, inside I1's default holder set)"
  else
    _fail "§0 provisioning left $MKT unseeded (refPrice=$(pool_ref), vault sol=$(vault_sol))"
    finish_test "liq_direction"
  fi
fi

# ── §0b the fixture's OWN ladder, inventory floor and mark — both paths ──
# (header: `seeded` proves a pool, not a ladder — initial_margin §E's 0.5 × 8
# residue part-fills the 9 SOL short.) Config first, then the mark pinned
# where the feed agrees (clears any pend a live tick left on SOL), then the
# floors, then a zero-lean skew target at what the AMM actually holds, and a
# requote so §1's short meets THIS ladder. setTestBalance SETS a balance, so
# the floors only ever raise a short leg — a seeded vault is never touched.
assert_ok "§0b the suite's ladder re-applied: 20bps · 1 $BASE · 15 levels · 35bps · 8s (the seed's config, over whatever a predecessor left)" \
  "$(call setAmmConfig "(\"$MKT\", 20:nat, $(e8 1.0):nat, 15:nat, 35:nat)")"
# The mark is NOT moved to the live aggregate unless the feed already agrees
# with the pool (mdx_restamp_mark, _lib.sh): a one-stamp −32% move blew the
# AMM's volRegime and quoted the bids 8.7% under the mark — outside §1's 5%
# collar (measured while fixing this). The algebra is scale-free; freshness
# and a cleared pend are all §1 needs.
PIN=$(mdx_restamp_mark "$BASE" "$MKT" "$(e8 100)") \
  || { _fail "§0b could not pin a $MKT mark (no aggregate, no pool price, no fallback accepted)"; finish_test "liq_direction"; }
M=$(pool_ref)
if [ -z "$M" ] || [ "$M" -le 0 ]; then
  _fail "§0 no priced $MKT pool (refPrice=$M) after the seeded-venue check"
  finish_test "liq_direction"
fi
echo "  live $MKT mark: $(from_e8 "$M") (mark ${PIN#* })"
# ── the fixture's scale K, from the live mark (header; task 1793559065) ──
# K = ceil($100 / m) + 1 in whole SOL: the net +K SOL leg's notional is then
# ≥ $100 + m, strictly past the Markets bar's $100 dust floor even after the
# fill's interest dust — 2 at any mark ≥ $100, 3 at ≈ $94. Every $-figure of
# the fixture (held / owed / cash / funding / the floors below) scales with
# it; the health, liqPrice and pctToLiq algebra does not. (M > 0 here.)
K=$(( (10000000000 + M - 1) / M + 1 ))
echo "  fixture scale K = $K (ceil(\$100 / $(from_e8 "$M")) + 1): net +$K $BASE ≈ \$$(from_e8 "$(( K * M ))") clears the \$100 dust floor"
AMM_P=$(call getAmmPrincipal '()' --query | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
[ -n "$AMM_P" ] || { _fail "§0b no AMM principal (getAmmPrincipal)"; finish_test "liq_direction"; }
# the vault basket IS the AMM principal's balances (main.mo currentVaultValue)
vault_quote() {
  call getVaultValue '()' --query | tr -d '\n' | grep -oE "basket = record \{[^}]*\}" \
    | grep -oE "icpusd = [0-9_]+" | tr -d '_' | grep -oE "[0-9]+$"
}
SOL_FLOOR=$(( (100 + 9 * K) * 100000000 ))   # §1 borrows 9K from the vault; 15 × 1 quotes the ask side
QUOTE_FLOOR=$(( M * (200 + 9 * K) ))         # quote to buy 200 + 9K SOL of bids — the ladder §1's short sells into
SOL_HAVE=$(vault_sol); QUOTE_HAVE=$(vault_quote)
if [ "${SOL_HAVE:-0}" -lt "$SOL_FLOOR" ]; then
  call setTestBalance "(principal \"$AMM_P\", \"$BASE\", $SOL_FLOOR : nat)" >/dev/null
  echo "  (AMM held $(from_e8 "${SOL_HAVE:-0}") $BASE — floored to $(from_e8 "$SOL_FLOOR") through the dev balance hook; no LP minted)"
fi
if [ "${QUOTE_HAVE:-0}" -lt "$QUOTE_FLOOR" ]; then
  call setTestBalance "(principal \"$AMM_P\", \"ICPUSD\", $QUOTE_FLOOR : nat)" >/dev/null
  echo "  (AMM held $(from_e8 "${QUOTE_HAVE:-0}") ICPUSD — floored to $(from_e8 "$QUOTE_FLOOR") through the dev balance hook; no LP minted)"
fi
call setAmmSkewConfig "(\"$MKT\", $(vault_sol) : nat, 200:nat)" >/dev/null   # zero lean at the current holding (auto-inventory, when on, re-derives it)
release "$M"
# Calm gate, then the precondition §1 actually consumes: a predecessor can
# leave the vol regime blown (its own mark jumps), and the ladder then quotes
# outside the short's 5% collar until enough requotes decay it — drive the
# requotes (bounded) rather than let §1 wait 30s on a parked order, and count
# only the bids a 5%-collared 9K SOL sell can reach.
mdx_calm_ladder "$MKT" "$M" 400 40 \
  || _fail "§0b the ladder never calmed to within 4% of the mark after 40 requotes (volRegime blown by a predecessor?): $(call getOrderBookDepth "(\"$MKT\", opt (1 : nat))" --query | tr -d '\n' | tr -s ' ' | head -c 240)"
collar_bids() {   # SOL of resting bids priced at or above $1 (e8) — candid field order is not guaranteed, so cut the bids vec out
  call getOrderBookDepth "(\"$MKT\", opt (25 : nat))" --query | tr -d '_\n' | python3 -c '
import re, sys
floor = int(sys.argv[1]); txt = sys.stdin.read()
bids = txt.split("bids = vec", 1)[1] if "bids = vec" in txt else ""
bids = bids.split("asks = vec", 1)[0]
tot = 0
for rec in bids.split("record {")[1:]:
    p = re.search(r"price = (\d+)", rec); q = re.search(r"quantity = (\d+)", rec)
    if p and q and int(p.group(1)) >= floor: tot += int(q.group(1))
print(tot)' "$1"
}
BD=$(collar_bids "$(( M * 95 / 100 ))")
if [ "${BD:-0}" -ge "$(( 9 * K * 100000000 ))" ]; then
  _ok "§0b fixture ready: $(from_e8 "$BD") $BASE of bids inside the 5% collar at $(from_e8 "$M") — §1's $(( 9 * K )) $BASE short fits (AMM holds $(from_e8 "$(vault_sol)") $BASE + $(from_e8 "$(vault_quote)") ICPUSD)"
else
  _fail "§0b only $(from_e8 "${BD:-0}") $BASE of bids inside the 5% collar — §1's $(( 9 * K )) $BASE short cannot fill (AMM holds $(from_e8 "$(vault_sol)") $BASE + $(from_e8 "$(vault_quote)") ICPUSD)"
fi

on_exit "call setAmmRefPrice '(\"$MKT\", $M : nat)' >/dev/null 2>&1; call requoteAmm '(\"$MKT\")' >/dev/null 2>&1"

# ── §1 fixture: short 9K SOL, then pin the slope shape ──
HELD=$(( 10 * K )); OWED=$(( 9 * K ))
echo "── §1 fixture: pool shorts $OWED $BASE, balances pinned to $HELD held / $OWED owed / cash $(( 2 * K ))m (K = $K) ──"
# The funding only has to ADMIT the short — openPosition's borrowCheck wants
# the pool's cash ≥ 0.4 × the short's notional (initial 1.25 against LTV
# 0.85) — so it scales with K·m too: 3 × the short's notional in the pool,
# 4 × that on the identity. The pin below overwrites the pool's balances.
FUND=$(( 27 * K * M ))
call setTestBalance "(principal \"$P\", \"ICPUSD\", $(( 4 * FUND )) : nat)" >/dev/null
R=$(usr createMarginPool '("liq-dir slope", false)')
PID=$(fld ok "$R")
[ -n "$PID" ] || { _fail "§1 createMarginPool: $R"; finish_test "liq_direction"; }
assert_ok "§1 fund the pool with $(from_e8 "$FUND") ICPUSD (3 × the $OWED $BASE short's notional)" "$(usr fundMarginPool "($PID, $FUND : nat)")"
O=$(usr openPosition "($PID, \"$MKT\", variant { sell }, $(e8 "$OWED") : nat, $(e8 0.05) : nat, null)")
assert_ok "§1 short $OWED $BASE staged (borrows the base from the vault)" "$O"
release "$M"
if wait_for "my_pos | grep -q 'size = -'" 30 2; then
  _ok "§1 short filled (size negative)"
else
  _fail "§1 short did not fill within 30s: $(my_pos | head -c 300)"
  finish_test "liq_direction"
fi
# candid quotes the key: `"principal" = "mgw6p-…"`
POOLP=$(my_pool | grep -oE '"?principal"? = "[^"]+"' | head -1 | sed -E 's/.*= "(.+)"/\1/')
[ -n "$POOLP" ] || { _fail "§1 pool principal not found: $(my_pool | head -c 300)"; finish_test "liq_direction"; }
C=$(( M * 2 * K ))
call setTestBalance "(principal \"$POOLP\", \"$BASE\", $(e8 "$HELD") : nat)" >/dev/null
call setTestBalance "(principal \"$POOLP\", \"ICPUSD\", $C : nat)" >/dev/null
stamp "$M"   # re-stamp so the marks are fresh after the balance pin
# 1788730982: a short's debt is BASE — the view's per-token figures say so
# (loans lists the base only; repayable[base] = the free base, no exit
# resting to earmark it), which is what the Repay row previews from.
# pool_vec_amt FIELD TOKEN — the TOKEN entry's amount in THIS run's pool's
# FIELD vec (my_pool is nested-aware); empty when the token is not listed.
pool_vec_amt() {
  my_pool | tr -d '_' | python3 -c '
import re, sys
field, tok = sys.argv[1:3]
r = sys.stdin.read(); j = r.find(field + " = vec {")
if j >= 0:
    k = j + len(field) + 8; d = 1; out = ""
    while k < len(r):
        c = r[k]
        if c == "{": d += 1
        elif c == "}":
            d -= 1
            if d == 0: break
        out += c; k += 1
    for piece in out.split("record"):
        if ("\"" + tok + "\"") in piece:
            m = re.search(r"amount = ([0-9]+)", piece)
            if m: print(m.group(1))
            break
print("")' "$1" "$2"
}
LNB=$(pool_vec_amt loans "$BASE"); RPB=$(pool_vec_amt repayable "$BASE"); LNQ=$(pool_vec_amt loans ICPUSD)
if [ "${LNB:-0}" -ge "$(e8 "$OWED")" ] && [ -z "$LNQ" ]; then _ok "§1/1788730982: the view's loans lists the BASE only ($(from_e8 "$LNB") $BASE owed; no ICPUSD entry)"; else _fail "§1/1788730982: a short's loans should list its base only: loans[$BASE]=$LNB loans[ICPUSD]=$LNQ"; fi
if [ "${RPB:-x}" = "$(e8 "$HELD")" ]; then _ok "§1/1788730982: repayable[$BASE] = the $HELD $BASE held (nothing resting earmarks it)"; else _fail "§1/1788730982: repayable[$BASE] should be the $HELD $BASE pinned: $RPB"; fi
POS=$(my_pos)
SZ=$(echo "$POS" | tr -d '_' | grep -oE 'size = -?[0-9]+' | head -1 | grep -oE '\-?[0-9]+$')
# 10K held − 9K owed = +K SOL less the base-loan interest that accrued since
# the fill (a unit or two of dust) — the sign is the point: NET LONG — and
# K × mark ≥ $100 + mark, so the leg clears the Markets bar's dust floor
# (header) for §3 on a FRESH venue.
KE8=$(e8 "$K")
if [ -n "$SZ" ] && [ "$SZ" -gt "$(( KE8 - 100000 ))" ] && [ "$SZ" -le "$KE8" ]; then
  _ok "§1 derived size is +$K $BASE less interest dust ($HELD held − $OWED owed: NET LONG, got $SZ; ≈ \$$(from_e8 "$(( K * M ))") notional)"
else
  _fail "§1 derived size should be ≈ +$K $BASE: got $SZ"
fi

# ── §2 at m: healthy, direction UP, positive distance ──
echo "── §2 at the live mark: healthy, liquidates on a RISING mark ──"
assert_contains "§2 isLiquidatable = false at m (health 1.167 > 1.15)" "$POS" "isLiquidatable = false"
assert_contains "§2 liqDir = #up — from A = heldLtv − M·debtBase < 0, not from the long size" "$POS" "liqDir = opt variant { up }"
LP=$(opt_nat liqPrice "$POS")
if [ -n "$LP" ] && [ "$LP" -gt "$M" ]; then
  _ok "§2 liqPrice $(from_e8 "$LP") lies ABOVE the mark $(from_e8 "$M") (≈ 1.081 × mark)"
else
  _fail "§2 liqPrice should lie above the mark: liqPrice=$LP mark=$M"
fi
PTL=$(opt_nat pctToLiq "$POS")
if [ -n "$PTL" ] && [ "$PTL" -gt 7000000 ] && [ "$PTL" -lt 9000000 ]; then
  _ok "§2 pctToLiq ≈ 8% (got $(from_e8 "$PTL")) — a POSITIVE distance, where the size-sign convention read 0"
else
  _fail "§2 pctToLiq expected ≈ 0.081 e8: got $PTL"
fi

# ── §3 at m: the Markets bar's long side ──
echo "── §3 Markets bar at m: long side healthy with a positive distance ──"
call devTickHeatmaps '()' >/dev/null
T=$(call getMarketTele "(\"$MKT\")" --query)
# The dust floor first (header): the long side's ROUNDED notional must be
# ≥ $100 or sideHealth / nearLiq publish nothing and the two checks below
# red for a reason that has nothing to do with #54.8 — this pin names it.
LN=$(fld longNotionalUsd "$T")
if [ -n "$LN" ] && [ "$LN" -ge 10000000000 ]; then
  _ok "§3 longNotionalUsd = \$$(from_e8 "$LN") ≥ \$100: the +$K $BASE leg (≈ \$$(from_e8 "$(( K * M ))")) clears the Markets bar's dust floor on a FRESH venue"
else
  _fail "§3 longNotionalUsd = ${LN:-?} rounds under the \$100 dust floor (HEAT_ROUND_USD_E8) — the +$K $BASE leg at $(from_e8 "$M") is dust and nothing below can publish: $(echo "$T" | tr -d '\n' | head -c 300)"
fi
assert_contains "§3 longLiquidatable = false at m" "$T" "longLiquidatable = false"
LB=$(opt_nat longNearLiqBps "$T")
if [ -n "$LB" ] && [ "$LB" -gt 0 ]; then
  _ok "§3 longNearLiqBps = $LB > 0 (the bar read '−0.0%' here before #54.8)"
else
  _fail "§3 longNearLiqBps should be a positive distance: $(echo "$T" | tr -d '\n' | head -c 400)"
fi

# ── §4 at 1.2m: liquidatable — the verdict, not mark-vs-price ──
echo "── §4 at 1.2 × mark: the pool is past maintenance ──"
M12=$(( M * 12 / 10 ))
stamp "$M12"
POS2=$(my_pos)
assert_contains "§4 isLiquidatable = true at 1.2m (health 1.13 < 1.15) — the row prints 'liquidatable' on this" "$POS2" "isLiquidatable = true"
assert_contains "§4 liqDir stays #up (same A)" "$POS2" "liqDir = opt variant { up }"

# ── §5 at 1.2m: the Markets bar's long side reads liquidatable ──
echo "── §5 Markets bar at 1.2 × mark: long side liquidatable ──"
call devTickHeatmaps '()' >/dev/null
T2=$(call getMarketTele "(\"$MKT\")" --query)
assert_contains "§5 longLiquidatable = true — the bar prints 'liquidatable', not '−9.9%'" "$T2" "longLiquidatable = true"

# ── leave the pool healthy: back to the live mark, cash topped up ──
stamp "$M"
call setTestBalance "(principal \"$POOLP\", \"ICPUSD\", $(( M * 20 * K )) : nat)" >/dev/null
assert_contains "§6 restored: pool healthy at the live mark" "$(my_pos)" "isLiquidatable = false"

finish_test "liq_direction"
