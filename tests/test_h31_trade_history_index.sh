#!/bin/bash
# H-31 (F48): per-principal trade history costs O(own fills), never O(tape).
# getMyTradeHistory / getMyTradeHistorySince / getMyTradesSinceId (and
# getMarketChanges' user-trade leg, getMyPositionFills per owned pool) read the
# transient principal → fills index (OrderBook.UserTradeIndex, the
# poolIdsByOwner shape: written at the refreshRolling24h choke point, pruned
# with the global trim, rebuilt at init) instead of walking orderStore.trades —
# which getUserTrades did forward in full (two Principal.equal per record, up
# to TRADES_GLOBAL_TRIM_AT) and the Since/SinceId pair backward with no scan
# ceiling, once per owned pool for position fills. Anonymous returns inside
# the lookup before anything is touched.
#   §1 devTradeHistoryCostProbe at a SATURATED tape (synthetic fills appended
#      in query state up to TRADES_GLOBAL_CAP = 600k): the three lookups for a
#      never-traded principal, the anonymous read, the live principal with the
#      MOST fills, and a 64-pool synthetic owner's position fills (every pool
#      ≥200 fills) each sit inside a fixed budget sized from `tapeWalk`, the
#      NEGATIVE CONTROL (the legacy full walk at the same tape size) — a real
#      walk can never hide in GC noise, noise can never fail the pin. RED on
#      the pre-fix build: the probe does not exist (recorded 2026-09-04: every
#      lookup was the tapeWalk shape, getMyPositionFills 64× it).
#   §2 the index is CONSISTENT with the live tape (entries == parties over the
#      tape) — the choke-point invariant, on fills that came through the
#      venue's real flows. Equivalence against the legacy walks per principal,
#      limit and cursor, plus prune-after-trim, is tests/UserTradeIndex.test.mo
#      (mops test).
#   §3 the public queries end to end at live: a virgin identity and anonymous
#      both get `(vec {})` from all four (--query; H-30's inspect gate refuses
#      unregistered UPDATE-mode calls, which is not what is measured here).
# Needs #dev (devTradeHistoryCostProbe). State-light: read-only against the
# venue (the probe's seeding is query state); the virgin identity is deleted
# at exit.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
as()  { local id="$1"; shift; icp canister call --candid "$MDX_CANDID" --identity "$id" backend "$@" 2>&1; }
flat() { tr -d '\n' | tr -s ' '; }
# a named nat/int field out of a candid reply (underscores stripped)
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | sed -E 's/.*= //'; }   # sed, not a second grep: field names carry digits (Since0)

[ "$(venue_posture)" = "dev" ] || skip_posture "test_h31_trade_history_index" "dev hooks (devTradeHistoryCostProbe)"

echo "── test_h31_trade_history_index ──"

echo "── §1 every per-principal lookup is bounded at a saturated (600k) tape (devTradeHistoryCostProbe) ──"
PR=$(adm devTradeHistoryCostProbe '()' --query | flat)
TAPE_LIVE=$(fld tapeLive "$PR"); TAPE_AT=$(fld tapeAtProbe "$PR"); SYNTH=$(fld tapeSynthAtProbe "$PR")
PARTIES=$(fld tapePartiesLive "$PR"); ENTRIES=$(fld indexEntriesLive "$PR")
V_HIST=$(fld virginHistory "$PR"); V_SINCE=$(fld virginHistorySince0 "$PR"); V_SID=$(fld virginSinceId0 "$PR")
ANON=$(fld anonHistory "$PR")
S_OWN=$(fld sampledOwn "$PR"); S_HIST=$(fld sampledHistory "$PR"); S_SID=$(fld sampledSinceId0 "$PR")
O_POOLS=$(fld ownerPools "$PR"); O_SEEN=$(fld ownerFillsSeen "$PR"); O_COST=$(fld ownerPositionFills "$PR")
WALK=$(fld tapeWalk "$PR")
SAMPLE=$(echo "$PR" | grep -oE 'sampledPrincipal = "[^"]+"' | head -1)
echo "  (tape $TAPE_LIVE live → $TAPE_AT at probe, +$SYNTH synthetic · $SAMPLE own $S_OWN · walk $WALK instr)"
echo "  (virgin: history $V_HIST · since0 $V_SINCE · sinceId0 $V_SID · anonymous $ANON · sampled: history $S_HIST · sinceId0 $S_SID · owner $O_POOLS pools: $O_COST instr, $O_SEEN rows)"
if [ -z "$TAPE_AT" ] || [ -z "$WALK" ] || [ -z "$V_HIST" ] || [ -z "$O_COST" ]; then
  nok "devTradeHistoryCostProbe answers with the H-31 fields" "$(echo "$PR" | head -c 300)"
else
  [ "$TAPE_AT" -ge 600000 ] && ok "the probe measured at a saturated tape ($TAPE_AT ≥ 600,000 fills, $SYNTH synthetic in query state)" || nok "the probe's tape is below TRADES_GLOBAL_CAP ($TAPE_AT)" ""
  # The negative control: one full walk over ≥600k records with two Principal
  # compares each — measured 2026-09-04 (pinned in the task log). If it ever
  # reads tiny the probe stopped saturating, and every ratio below is void.
  [ "$WALK" -ge 30000000 ] && ok "negative control: the legacy full walk costs $WALK instr at $TAPE_AT fills (≥ 3×10^7)" || nok "the legacy walk measured only $WALK instr — the tape is not saturated, the pins below mean nothing" ""
  # Index reads for a principal with no fills: one map lookup (a Principal
  # compare per level of a ~hundreds-key map). Tolerance: 1/1000 of the walk
  # (a walk over 0.1% of the tape is not "bounded"), with a 20k floor for GC
  # increment noise on a cold read.
  VB=$(awk -v w="$WALK" 'BEGIN { b = w / 1000; if (b < 20000) b = 20000; printf "%.0f", b }')
  for pair in "getMyTradeHistory:$V_HIST" "getMyTradeHistorySince(0):$V_SINCE" "getMyTradesSinceId(0):$V_SID" "anonymous getMyTradeHistory:$ANON"; do
    NAME=${pair%%:*}; COST=${pair##*:}
    [ "${COST:-999999999}" -le "$VB" ] && ok "$NAME for a never-traded principal: $COST instr (bound $VB = walk/1000)" || nok "$NAME for a never-traded principal costs $COST instr (bound $VB) — still tape-shaped" ""
  done
  # The busiest live principal: O(min(own, 200)) — ≤200 rows copied and
  # flipped. Tolerance 1/100 of the walk, 500k floor.
  SB=$(awk -v w="$WALK" 'BEGIN { b = w / 100; if (b < 500000) b = 500000; printf "%.0f", b }')
  [ "${S_HIST:-999999999}" -le "$SB" ] && ok "getMyTradeHistory for the busiest live principal (own $S_OWN): $S_HIST instr (bound $SB = walk/100)" || nok "busiest principal's history costs $S_HIST instr (bound $SB)" ""
  [ "${S_SID:-999999999}" -le "$SB" ] && ok "getMyTradesSinceId(0) for the busiest live principal: $S_SID instr (bound $SB)" || nok "busiest principal's sinceId read costs $S_SID instr (bound $SB)" ""
  # 64 pools × 200 fills each = 12,800 rows off the index — must stay far
  # inside ONE walk (the pre-fix shape was 64 walks), and every pool's 200
  # rows must be present (the index serves the pool principals).
  [ "${O_POOLS:-0}" -eq 64 ] && ok "the probe minted $O_POOLS pools for the synthetic owner" || nok "the probe minted $O_POOLS pools, not 64" ""
  EXPECT=$((64 * 200))
  [ "${O_SEEN:-0}" -eq "$EXPECT" ] && ok "getMyPositionFills returns 200 fills per pool ($O_SEEN rows) — the index serves the pool principals" || nok "getMyPositionFills returned $O_SEEN rows, expected $EXPECT" ""
  [ "${O_COST:-999999999}" -lt "$WALK" ] && ok "a 64-pool owner's getMyPositionFills: $O_COST instr, inside one walk ($WALK; the pre-fix shape was 64 walks)" || nok "64-pool getMyPositionFills costs $O_COST instr — not inside one walk ($WALK)" ""
  [ "${O_COST:-999999999}" -le 200000000 ] && ok "…and well inside the query limit (≤ 2×10^8 of 5×10^9)" || nok "64-pool getMyPositionFills costs $O_COST instr — over the 2×10^8 ceiling" ""
fi

echo "── §2 the index is consistent with the live tape (the choke-point invariant) ──"
if [ -z "$PARTIES" ] || [ -z "$ENTRIES" ]; then
  nok "probe carries the consistency fields" ""
else
  [ "$ENTRIES" -eq "$PARTIES" ] && ok "index entries == tape parties at live ($ENTRIES over $TAPE_LIVE fills)" || nok "index entries $ENTRIES ≠ tape parties $PARTIES — a fill-producing path bypasses refreshRolling24h" ""
fi

echo "── §3 the public queries end to end: a virgin identity and anonymous get (vec {}) ──"
SUF="${RANDOM}$$"
mdx_identity_new "h31_virgin_$SUF"; X="h31_virgin_$SUF"
for q in "getMyTradeHistory:()" "getMyTradeHistorySince:(0 : int)" "getMyTradesSinceId:(0 : nat, 200 : nat)" "getMyPositionFills:()"; do
  M=${q%%:*}; A=${q#*:}
  XR=$(as "$X" "$M" "$A" --query | flat)
  [ "$XR" = "(vec {})" ] && ok "virgin $M is (vec {})" || nok "virgin $M returned rows" "$(echo "$XR" | head -c 200)"
  AR=$(adm "$M" "$A" --query | flat)
  [ "$AR" = "(vec {})" ] && ok "anonymous $M is (vec {})" || nok "anonymous $M returned rows" "$(echo "$AR" | head -c 200)"
done

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_h31_trade_history_index ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_h31_trade_history_index ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
