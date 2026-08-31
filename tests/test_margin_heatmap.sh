#!/bin/bash
# tests/test_margin_heatmap.sh
#
# The aggregate margin heat map (getMarginHeatmap / getMarginHeatmaps).
#
# What it pins:
#   §1 the heartbeat computes it (computedNs > 0) and it is CACHED, not
#      computed per query — two reads inside one cache window are identical
#   §2 the price-quality tier is DERIVED from oracle health: a market with
#      real multi-source pricing is "full"/"coarse"; an asset with no
#      aggregate is "none" and publishes no buckets (the bps geometry is only
#      as meaningful as the mark)
#   §3 EXACT bands (k-anonymity removed 2026-08-01): every published bucket
#      is exactly one band wide (100bps) and carries a real position count —
#      no merging, no side-wide washes in FRESH columns (the history ring may
#      carry pre-change wide bands for ~4h after the upgrade)
#   §4 bands are ordered low→high, non-overlapping, and sit inside +/-30%
#   §5 totals are consistent: positionsTotal >= the sum of bucket positions
#      (positions liquidating outside the window, or with no finite
#      liquidation price, count in totals only)
#   §6 notionals are rounded to $100 steps (display tidiness — the exact
#      figures are derivable from the public tape regardless)
#
# PRECONDITION: a PRICED market (an AMM pool with refPrice > 0) and the
# heartbeat running — everything here reads caches the 30s tick populates,
# and §8's history ring only appends columns while markPrice > 0. A warm
# venue (cold_start --mode play/full) satisfies it already; on a cold venue
# (full-suite runs: the destructive tests reset at exit) §0 provisions the
# minimum itself — pool + refPrice, no LP, no positions. Beyond that the
# test stays read-only: places no orders, opens no positions, never calls
# resetExchange, so it is safe against a live venue.

source "$(dirname "$0")/_lib.sh"

echo "── test_margin_heatmap ──"

MKT="BTC-ICPUSD"

# ── §0 precondition: a priced market + a heartbeat column ────────
# Warm when the cache holds a computed map AND the history ring already has
# a column for MKT (which needs markPrice > 0 at some tick). Cold → price
# the market and wait out the 30s HB_HEAT_NS tick. markPrice is just the
# pool's refPrice, so a pool + refPrice is the whole fixture: no LP (I1
# stays trivially clean), no positions (every section holds on an
# empty-but-priced book).
CTL="--identity anonymous"   # local controller
warm() {
  local c n
  c=$(extract_nat "computedNs" "$(call getMarginHeatmap "(\"$MKT\")" --query)")
  n=$(call getMarginHeatmapHistory "(\"$MKT\", 0)" --query | grep -c "computedNs")
  [ -n "$c" ] && [ "$c" != "0" ] && [ "${n:-0}" -ge 1 ]
}
if ! warm; then
  echo "  (cold venue — pricing $MKT and waiting for the heartbeat tick)"
  call setTestTimersPaused '(false)' $CTL >/dev/null 2>&1   # an earlier failed test may have left them paused
  call createAmmPool "(\"$MKT\")" $CTL >/dev/null 2>&1      # idempotent-ish; refPrice is set NEXT (create zeroes it)
  call setAmmRefPrice "(\"$MKT\", $(e8 50000) : nat)" $CTL >/dev/null
  wait_for warm 75 5 \
    || { _fail "§0 no priced $MKT heatmap column after 75s — timers dead, or posture blocks setAmmRefPrice?"; finish_test "margin_heatmap"; }
  _ok "§0 provisioned a priced $MKT (pool + refPrice only)"
fi

HM=$(call getMarginHeatmap "(\"$MKT\")" --query)

# ── §1 computed by the heartbeat, and cached ──
COMPUTED=$(extract_nat "computedNs" "$HM")
if [ -n "$COMPUTED" ] && [ "$COMPUTED" != "0" ]; then
  _ok "§1 heartbeat computed the map (computedNs set)"
else
  _fail "§1 map never computed — is the heartbeat running? got: $(echo "$HM" | head -c 160)"
fi
HM2=$(call getMarginHeatmap "(\"$MKT\")" --query)
C2=$(extract_nat "computedNs" "$HM2")
assert_eq "§1 cached (same computedNs across two reads)" "$COMPUTED" "$C2"

# ── §2 tier derived from oracle health ──
TIER=$(echo "$HM" | grep -oE 'tier = "[a-z]+"' | grep -oE '"[a-z]+"' | tr -d '"')
case "$TIER" in
  full|coarse) _ok "§2 seeded market is oracle-priced → tier=$TIER" ;;
  none)        _ok "§2 tier=none (no oracle aggregate) — buckets must be empty" ;;
  *)           _fail "§2 unexpected tier: [$TIER]" ;;
esac
if [ "$TIER" = "none" ]; then
  NB=$(echo "$HM" | grep -c "bandLowBps")
  assert_eq "§2 tier=none publishes no buckets" "0" "$NB"
fi

# ── §3 exact bands: every FRESH bucket is one 100bps band with real counts ──
# The k-anonymity floor was removed 2026-08-01 (see
# docs/margin-heatmap-design.md — the public tape reconstructs every
# liquidation price anyway, and liquidations key on the oracle mark, so the
# floor blurred the map for casual players while protecting nobody). The
# invariant is now the opposite of the old one: the LATEST snapshot must
# contain only single-band buckets (width == 100bps) with positions >= 1 —
# merged or side-wide buckets in a fresh column would mean the old machinery
# has crept back. (The stable history RING may still carry pre-change wide
# bands until it cycles; §8 deliberately does not test bucket shape.)
# RS="}" so each RECORD is one awk record — candid prints every field on its
# own LINE, so a line-oriented pass never sees positions and the band edges
# together.
VIOL=$(echo "$HM" | awk 'BEGIN{RS="}"}
  /positions = / {
    p=$0; sub(/.*positions = /,"",p); sub(/[^0-9_].*/,"",p); gsub(/_/,"",p);
    lo=$0; sub(/.*bandLowBps = /,"",lo);  sub(/[^-0-9_].*/,"",lo);  gsub(/_/,"",lo);
    hi=$0; sub(/.*bandHighBps = /,"",hi); sub(/[^-0-9_].*/,"",hi); gsub(/_/,"",hi);
    if (lo != "" && hi != "" && ((hi-lo) != 100 || p+0 < 1)) c++ }
  END { print c+0 }')
assert_eq "§3 every bucket is one exact 100bps band with positions >= 1" "0" "$VIOL"

# ── §4 bands ordered, contiguous, within range ──
LOWS=$(echo "$HM" | tr ';' '\n' | grep -oE "bandLowBps = [-0-9_]+" | tr -d '_' | awk '{print $3}')
HIGHS=$(echo "$HM" | tr ';' '\n' | grep -oE "bandHighBps = [-0-9_]+" | tr -d '_' | awk '{print $3}')
if [ -z "$LOWS" ]; then
  _ok "§4 no buckets to order (empty/edge market) — skipped"
else
  BAD=$(paste <(echo "$LOWS") <(echo "$HIGHS") | awk '
    { if ($1 >= $2) bad++; if ($1 < -3000 || $2 > 3000) bad++;
      if (NR > 1 && $1 < prevHigh) bad++; prevHigh = $2 } END { print bad+0 }')
  assert_eq "§4 bands ordered, low<high, within ±3000bps" "0" "$BAD"
fi

# ── §5 totals consistent with buckets ──
PT=$(extract_nat "positionsTotal" "$HM"); PT=${PT:-0}
PSUM=$(echo "$HM" | tr ';' '\n' | grep -oE "positions = [0-9_]+" | tr -d '_' \
       | awk '{ s += $3 } END { print s+0 }')
if [ "$PT" -ge "$PSUM" ]; then
  _ok "§5 positionsTotal ($PT) >= Σ bucket positions ($PSUM)"
else
  _fail "§5 bucket positions ($PSUM) exceed positionsTotal ($PT)"
fi

# ── §6 notionals rounded to $100 steps (display tidiness, pinned so drift is deliberate) ──
UNROUNDED=$(echo "$HM" | tr ';' '\n' | grep -oE "(long|short)NotionalUsd = [0-9_]+" | tr -d '_' \
            | awk '{ if ($3 % 10000000000 != 0) c++ } END { print c+0 }')
assert_eq "§6 all bucket notionals rounded to \$100" "0" "$UNROUNDED"

# ── every market answers ──
ALL=$(call getMarginHeatmaps '()' --query)
NM=$(echo "$ALL" | grep -c "marketId")
if [ "$NM" -ge 1 ]; then _ok "getMarginHeatmaps covers $NM market(s)"
else _fail "getMarginHeatmaps returned nothing"; fi

# ── §7 LP risk panel: the disclosure to the people underwriting the book ──
RS=$(call getMarginRiskSummary '()' --query)
RC=$(extract_nat "computedNs" "$RS")
if [ -n "$RC" ] && [ "$RC" != "0" ]; then _ok "§7 risk summary computed"
else _fail "§7 risk summary never computed: $(echo "$RS" | head -c 120)"; fi

# It must identify NOBODY — that is what lets it publish for every market,
# including thin ones where bucket disclosure is withheld.
assert_not_contains "§7 risk summary carries no principals" "$RS" "principal"

VV=$(extract_nat "vaultValueUsd" "$RS");        VV=${VV:-0}
CAP=$(extract_nat "vaultBorrowCapUsd" "$RS");   CAP=${CAP:-0}
DEBT=$(extract_nat "totalDebtUsd" "$RS");       DEBT=${DEBT:-0}
UTIL=$(extract_nat "vaultUtilisationBps" "$RS"); UTIL=${UTIL:-0}
POS=$(extract_nat "positions" "$RS");           POS=${POS:-0}
LQP=$(extract_nat "liquidatablePositions" "$RS"); LQP=${LQP:-0}
WORST=$(extract_nat "worstCaseAbsorbUsd" "$RS"); WORST=${WORST:-0}

# borrow cap is exactly half the vault (VAULT_BORROW_FRACTION_CAP = 0.50)
EXP_CAP=$(python3 -c "print($VV // 2)")
if python3 -c "import sys; sys.exit(0 if abs($CAP - $EXP_CAP) <= 1 else 1)"; then
  _ok "§7 borrow cap == 50% of vault value"
else _fail "§7 borrow cap $CAP != half of vault $VV"; fi

# utilisation is internally consistent with debt/cap
if [ "$CAP" -gt 0 ]; then
  EXP_UTIL=$(python3 -c "print($DEBT * 10000 // $CAP)")
  assert_eq "§7 utilisation bps consistent with debt/cap" "$EXP_UTIL" "$UTIL"
else
  _ok "§7 no borrow capacity (empty vault) — utilisation check skipped"
fi

if [ "$POS" -ge "$LQP" ]; then _ok "§7 positions ($POS) >= liquidatable ($LQP)"
else _fail "§7 liquidatable ($LQP) exceeds positions ($POS)"; fi

# the vault's worst case cannot exceed what it has actually lent
if [ "$WORST" -le "$DEBT" ]; then _ok "§7 worst-case absorb ($WORST) <= total debt ($DEBT)"
else _fail "§7 worst-case absorb ($WORST) exceeds total debt ($DEBT)"; fi

# ── §8 history ring: the heat surface's time axis ──
# Each tick appends the published snapshot; the ring is what the frontend
# paints as columns. Entries must be (a) present, (b) ordered by computedNs,
# (c) filtered by the sinceNs cursor exactly as an incremental poller relies on.
HH=$(call getMarginHeatmapHistory "(\"$MKT\", 0)" --query)
NCOLS=$(echo "$HH" | grep -oE 'computedNs = [0-9_]+' | wc -l | tr -d ' ')
if [ "$NCOLS" -ge 1 ]; then _ok "§8 history holds $NCOLS column(s)"
else _fail "§8 history empty — tick not appending? $(echo "$HH" | head -c 160)"; fi

# newest column == the cached latest snapshot (same computedNs). The tick can
# legitimately recompute the snapshot between the two reads, so a mismatch is
# retried with a fresh PAIR of reads — but a mismatch that survives the
# retries is a real ring/snapshot desync and FAILS (#51.9: this used to _ok
# both branches, so the equality could never go red).
LASTNS=$(echo "$HH" | grep -oE 'computedNs = [0-9_]+' | tail -1 | grep -oE '[0-9_]+$' | tr -d '_')
NOWNS=$(extract_nat "computedNs" "$(call getMarginHeatmap "(\"$MKT\")" --query)")
for _try in 1 2 3; do
  [ "$LASTNS" = "$NOWNS" ] && break
  sleep 2
  HH=$(call getMarginHeatmapHistory "(\"$MKT\", 0)" --query)
  NCOLS=$(echo "$HH" | grep -oE 'computedNs = [0-9_]+' | wc -l | tr -d ' ')
  LASTNS=$(echo "$HH" | grep -oE 'computedNs = [0-9_]+' | tail -1 | grep -oE '[0-9_]+$' | tr -d '_')
  NOWNS=$(extract_nat "computedNs" "$(call getMarginHeatmap "(\"$MKT\")" --query)")
done
if [ "$LASTNS" = "$NOWNS" ]; then _ok "§8 newest column matches the published snapshot"
else _fail "§8 newest column $LASTNS != snapshot $NOWNS after retries — the ring is not receiving the published snapshot"; fi

# ordering: computedNs strictly increasing
ORDERED=$(echo "$HH" | grep -oE 'computedNs = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_' \
  | python3 -c "import sys; v=[int(l) for l in sys.stdin]; print('yes' if v==sorted(v) and len(set(v))==len(v) else 'no')")
assert_eq "§8 columns strictly ordered by computedNs" "yes" "$ORDERED"

# sinceNs cursor: asking from the newest timestamp returns nothing older
HH2=$(call getMarginHeatmapHistory "(\"$MKT\", $LASTNS)" --query)
N2=$(echo "$HH2" | grep -oE 'computedNs = [0-9_]+' | wc -l | tr -d ' ')
if [ "$N2" -lt "$NCOLS" ]; then _ok "§8 sinceNs cursor filters ($NCOLS -> $N2)"
else _fail "§8 sinceNs=$LASTNS returned $N2 of $NCOLS — cursor not filtering"; fi

# unknown market: empty vec, not a trap
HH3=$(call getMarginHeatmapHistory '("NO-SUCH-MKT", 0)' --query)
assert_contains "§8 unknown market returns empty history" "$HH3" "vec {}"

finish_test "margin_heatmap"
