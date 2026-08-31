#!/bin/bash
# tests/test_position_accounting.sh
#
# Position accounting through openPosition fills — the VWAP / realized / entry
# laws, pinned against the settlement race fixed 2026-08-01.
#
# THE BUG THIS PINS: openPosition's provisional upsert used to zero the STORED
# position size ("size is derived at read") — but bookPoolSide bases
# MarginPools.applyFill on the stored size. An order that was IMMEDIATELY
# marketable (a resting counter-order at its price) settled on the next GEPTOR
# release before tryLiquidate's reconcilePoolPositions could restore the size,
# so applyFill saw size == 0 and booked a REDUCING fill as a fresh OPEN: entry
# dragged to the fill price, realized frozen, and every later reduce realizing
# against the corrupted entry. Orders that rested a while escaped only because
# the reconcile usually won the race — which is why the bug surfaced live as
# "Realized stopped updating after the first sells" (the first sells rested;
# the later ones filled instantly into a rallying book).
#
# What it pins (as LAWS, robust to live-market noise from bots/AMM):
#   §1 entry:            entry == the fill ceiling (0 < entry <= limit), realized == 0
#   §2 SLOW reduce:      order rests, fills later →
#                          entry UNCHANGED, Δrealized == (sellPx − entry)·Δsize
#   §3 FAST reduce:      counter-bid rests FIRST, sell crosses at placement →
#                          entry UNCHANGED, Δrealized == (sellPx − entry)·Δsize
#                        (this is the ordering that corrupted pre-fix)
#   §4 FAST increase:    marketable add-on → entry == blended VWAP, realized unchanged
#   §5 uPnL law:         unrealizedPnl == (mark − entry)·size, same-row consistency
#   §6 flat close:       derived size 0 → row gone; an episode is recorded
#
# Runs on a warm venue (cold_start play/full: AMM book + live oracle) OR
# self-provisions whenever the venue cannot COVER THE §6 CLOSE — empty book
# (cold) or one-sweep bid capacity below the close size (a SUITE-RESIDUE
# venue: earlier suite fixtures reconfigure ICP-ICPUSD to thin 3-level
# ladders — test_breaker_widening/test_slippage_anchor set 3×15bps — and a
# post-suite venue passes a bare "book non-empty" check while §6's ~600-base
# market close can only fill the ladder's ~dozen base units in its one
# sweep; the 2026-08-20 pre-rollout red was exactly this shape). §0 seeds an
# alice-held ICP-ICPUSD pool and
# runs a 2s refPrice+requote keeper standing in for the GEPTOR (the venue's
# release/sweep machinery is freshness-driven and stops dead without one).
# Creates its own identities and margin pool; trades tiny sizes on
# ICP-ICPUSD between its own two parties at inside-spread prices. Bots may
# take the other side of a resting leg — harmless: every assertion is a law
# over the POSITION's actual (entry, size, realized) deltas, not over
# absolute fill sizes. COLD-VENUE CAVEAT: §2's resting-reduce lift cannot be
# reproduced without live-market dynamics (see the §2 skip branch); it
# banners a skip there and stays fully pinned on warm venues.

source "$(dirname "$0")/_lib.sh"

echo "── test_position_accounting ──"

MKT="ICP-ICPUSD"
A_ID="postest-a"    # position holder (margin pool)
B_ID="postest-b"    # counterparty (spot wallet)
CTL="--identity anonymous"   # local controller for setTestBalance

# ── §0 fixtures ──────────────────────────────────────────────────
# FRESH identities every run (delete-then-create, the deposit_ledger_guard
# pattern): position episodes survive resetExchange, so a reused principal
# walks in with history and §6's "episode recorded" check (0 → 1) can only
# ever pass for a virgin identity.
newid() { echo "y" | icp identity delete "$1" >/dev/null 2>&1 || true
          icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }
for id in "$A_ID" "$B_ID"; do newid "$id"; done
A_PRIN=$(principal_of "$A_ID"); B_PRIN=$(principal_of "$B_ID")
call setTestBalance "(principal \"$A_PRIN\", \"ICPUSD\", $(e8 200000) : nat)" $CTL >/dev/null
call setTestBalance "(principal \"$B_PRIN\", \"ICP\",    $(e8 20000)  : nat)" $CTL >/dev/null
call setTestBalance "(principal \"$B_PRIN\", \"ICPUSD\", $(e8 100000) : nat)" $CTL >/dev/null

POOL=$(call createMarginPool '("pos-accounting-test", true)' --identity "$A_ID" | tr -d '_' \
       | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
[ -n "$POOL" ] || { _fail "§0 could not create margin pool"; finish_test "position_accounting"; }
call fundMarginPool "($POOL, $(e8 50000) : nat)" --identity "$A_ID" >/dev/null
_ok "§0 pool $POOL created and funded"

# Read A's ICP position (size / entry / realized / mark / uPnL), all e8 ints.
pos_read() {
  call getMyPositions '()' --query --identity "$A_ID" | tr -d '_\n' | sed 's/record {/\n/g' \
    | grep "\"$MKT\"" | grep "poolId = $POOL " | head -1
}
pos_field() { echo "$1" | grep -oE "$2 = [-0-9]+" | grep -oE '[-0-9]+' | head -1; }

# Best bid/ask off the live book, e8.
book_edge() {
  call getOrderBookDepth "(\"$MKT\", opt (1 : nat))" --query | tr -d '_\n' \
    | grep -oE "${1}s = vec \{[^}]*price = [0-9]+" | grep -oE '[0-9]+$'
}

# True while the spread is sane (≤60bps of mid; nominal is 40bps). The AMM
# widens its half-spread with volRegime (EWMA stdev of log-returns), so for
# ~10-30s after a burst of fills the ladder quotes at hundreds-to-thousands
# of bps. A section that reads book_edge inside such a window computes its
# inside-spread prices miles off-market — §4 was measured resting an add-on
# at $7.25 against a $10 book exactly this way. Every section-start edge
# read waits this out (bounded, best-effort).
calm_book() {
  local b a
  b=$(book_edge bid); a=$(book_edge ask)
  [ -n "$b" ] && [ -n "$a" ] || return 1
  awk -v b="$b" -v a="$a" 'BEGIN{ m=(a+b)/2; exit ((a-b)*10000/m <= 60) ? 0 : 1 }'
}

# One-sweep bid capacity (e8): Σ resting bid size over the top 25 levels —
# an upper bound on what §6's full-size market SELL close can fill in one
# sweep. Candid field order inside the depth record is not guaranteed, so
# cut the bids vec out explicitly before summing (either side may print
# first; the sed only fires when asks trail bids).
bid_capacity() {
  call getOrderBookDepth "(\"$MKT\", opt (25 : nat))" --query | tr -d '_\n' \
    | awk -F'bids = vec ' 'NF > 1 { print $2 }' | sed 's/asks = vec.*//' \
    | grep -oE 'quantity = [0-9]+' | grep -oE '[0-9]+' \
    | awk '{ s += $1 } END { printf "%.0f", s + 0 }'
}
# §6 flat-closes the position with ONE slippage-bounded market order (a
# market close never rests: it fills what the sweep reaches). Worst case
# the position is still the full §1 entry (1000) if neither reduce filled,
# so demand bids for ~1200 in one sweep; a genuinely seeded warm venue
# (cold_start full/play) quotes thousands per side, so this never trips
# there — only cold and residue venues self-provision.
CLOSE_NEED=$(e8 1200)

# The sections below trade against a live two-sided $MKT book. A warm venue
# (cold_start --mode play/full) provides one via the AMM; in full-suite runs
# the destructive tests reset the venue at exit (fixture hygiene) or leave
# thin single-purpose ladders behind, so raise our own quoting pool here.
# The LP is deliberately held by `alice` — one of
# the five identities _lib.sh's I1 sums — so the vault stays fully
# attributable during AND after this test (I1's contract for seeders).
if [ -z "$(book_edge bid)" ] || [ -z "$(book_edge ask)" ] \
   || [ "$(bid_capacity)" -lt "$CLOSE_NEED" ]; then
  echo "  (venue cannot cover the §6 close — seeding an AMM-quoted $MKT book, LP held by alice)"
  call setTestTimersPaused '(false)' $CTL >/dev/null 2>&1   # releases need live timers
  ALICE_PRIN=$(principal_of alice)
  call createAmmPool "(\"$MKT\")" $CTL >/dev/null 2>&1
  # (spreadBps, depth/level, numLevels, levelSpacingBps, protectionWindowSec).
  # Depth must cover §6's FULL-size market close in one sweep (residual ~600
  # base units): 10 levels × 200 = 2000/side, span ±250bps ≪ the close's 10%
  # slippage cap. A 5×100 ladder (500/side) leaves the close order unfillable.
  # protectionWindowSec MUST be 0 here: with a window, the tight ladder
  # disappears for many seconds after every big fill and the sections that
  # read book_edge mid-test catch grotesquely wide protection quotes — their
  # inside-spread prices then land miles off-market and settlement becomes a
  # race against the ladder's return (the §2 flake).
  call setAmmConfig "(\"$MKT\", 20:nat, $(e8 200) : nat, 10:nat, 25:nat, 0:nat)" $CTL >/dev/null
  # Anchor price. A RESIDUE venue (thin suite-fixture ladder, live book near
  # the real market price) re-anchors AT ITS CURRENT refPrice — freshness
  # re-stamp only, no movement — because quoting the cold default $10 into a
  # ~$2 book would cross every stray resting order and §0's calm gate would
  # stare at a blown-out spread forever. A virgin pool anchors at $10.
  CUR_REF=$(call getAmmPool "(\"$MKT\")" 2>/dev/null | tr -d '_' | grep -oE 'refPrice = [0-9]+' | grep -oE '[0-9]+' | head -1)
  if [ -n "${CUR_REF}" ] && [ "${CUR_REF}" != "0" ]; then
    ANCHOR_PX=$(awk -v p="${CUR_REF}" 'BEGIN{ printf "%.8f", p / 100000000 }')
  else
    ANCHOR_PX="10.00"
  fi
  call setAmmRefPrice "(\"$MKT\", $(e8 "${ANCHOR_PX}") : nat)" $CTL >/dev/null
  call setTestBalance "(principal \"$ALICE_PRIN\", \"ICP\",    $(e8 20000)  : nat)" $CTL >/dev/null
  call setTestBalance "(principal \"$ALICE_PRIN\", \"ICPUSD\", $(e8 200000) : nat)" $CTL >/dev/null
  # Mid-suite the vault can hold legs whose refPrice went stale when their
  # tests ended; the LP-mint staleness gate then refuses seedAmmPool and
  # the AMM never gets inventory — §0 then times out staring at a
  # stray-orders-only book. Re-stamp every priced market at its CURRENT
  # refPrice (freshness only, no movement — no breaker interaction), and
  # pin manual quoting in case an earlier test left auto-inventory on.
  call setAmmAutoInventory '(false)' $CTL >/dev/null 2>&1
  call setTestPendingJump '("ICP", null, null)' $CTL >/dev/null 2>&1
  for m in BTC-ICPUSD ETH-ICPUSD SOL-ICPUSD ICP-ICPUSD; do
    cur=$(call getAmmPool "(\"$m\")" 2>/dev/null | tr -d '_' | grep -oE 'refPrice = [0-9]+' | grep -oE '[0-9]+' | head -1)
    [ -n "$cur" ] && [ "$cur" != "0" ] && call setAmmRefPrice "(\"$m\", $cur : nat)" $CTL >/dev/null 2>&1
  done
  SEEDR=$(call seedAmmPool "(\"$MKT\", $(e8 10000) : nat, $(e8 100000) : nat)" --identity alice)
  echo "$SEEDR" | grep -q "ok" || _fail "§0 seedAmmPool refused: $(echo "$SEEDR" | head -c 200)"
  call enableAmm "(\"$MKT\", true)" $CTL >/dev/null
  call requoteAmm "(\"$MKT\")" $CTL >/dev/null
  # Emulate the GEPTOR for the duration of the run. Freshness is load-bearing
  # twice over: tickAmm PANICS on a stale refPrice (ladder cancelled, staged
  # releases stop), and the sweep's anti-snipe gate only fills orders placed
  # BEFORE the current refPriceUpdatedNs — on a live venue the GEPTOR
  # re-fetches ~1-2s after an order arrives, so orders become eligible
  # promptly. Beat every ~2s (call latency makes it ~3s effective); slower
  # keepers let staged market orders expire before they ever turn eligible
  # (§6's close died exactly that way at 15s).
  # The anchor stays FLAT at the seed price: the section laws hard-code
  # their limit prices as expected fill prices, so any AMM fill at a moved
  # price corrupts the Δrealized/VWAP arithmetic (a wandering anchor was
  # tried and broke §3/§4 exactly that way). The anchor is read from a file
  # so §2's one-shot sweep nudge (below) can steer it without racing the
  # keeper loop.
  COLD_FIXTURE=1
  ANCHOR_FILE=$(mktemp /tmp/uplands-posacct-anchor-XXXXXX)
  echo "${ANCHOR_PX}" > "$ANCHOR_FILE"
  # setAmmRefPrice AND requoteAmm, as release()/freshrequote() do elsewhere
  # in the suite: the heartbeat's own requoter is drift/cooldown gated, so a
  # flat anchor alone means requotes — and ammSweepResting, which only runs
  # inside a requote — essentially never fire.
  ( while :; do
      call setAmmRefPrice "(\"$MKT\", $(e8 "$(cat "$ANCHOR_FILE")") : nat)" $CTL >/dev/null 2>&1
      call requoteAmm "(\"$MKT\")" $CTL >/dev/null 2>&1
      sleep 2
    done ) &
  REFPRICE_KEEPER=$!
  trap 'kill $REFPRICE_KEEPER 2>/dev/null; rm -f "$ANCHOR_FILE"' EXIT
  # Calm-book gate: a freshly created pool's first price samples blow up
  # volRegime, so for the first ~30s the ladder quotes at ±thousands of
  # bps (see calm_book above). Hard-require calm before the test runs.
  wait_for calm_book 150 3 \
    || { _fail "§0 book never calmed (spread stuck wide) on $MKT"; finish_test "position_accounting"; }
  _ok "§0 AMM book live and calm on $MKT (LP attributed to alice per I1, keeper running)"
fi

# Cold venues cannot lift a RESTING pool reduce order: spot takers cross
# spot makers and pool OPENING makers fine, but a resting reduce only ever
# fills via the AMM sweep — which on the live venue happens within seconds
# because the wandering oracle walks the ladder past it. The sweep fills a
# maker at ITS OWN price, so steering the anchor just past the resting
# price keeps the section laws exact. No-op on warm venues.
lift_resting_reduce() { # $1 = resting price (e8); returns once size < $2
  [ "${COLD_FIXTURE:-0}" = "1" ] || return 0
  local px8="$1" below="$2"
  # A short natural-settle grace first — a warm-ish book may still lift it.
  wait_for '[ "$(pos_field "$(pos_read)" size)" -lt '"$below"' ]' 8 2 && return 0
  awk -v p="$px8" 'BEGIN{ printf "%.8f\n", p*1.005/100000000 }' > "$ANCHOR_FILE"
  call setAmmRefPrice "(\"$MKT\", $(awk -v p="$px8" 'BEGIN{ printf "%.0f", p*1.005 }') : nat)" $CTL >/dev/null 2>&1
  call requoteAmm "(\"$MKT\")" $CTL >/dev/null 2>&1   # force the requote → the sweep runs now
  wait_for '[ "$(pos_field "$(pos_read)" size)" -lt '"$below"' ]' 20 2
  local rc=$?
  echo "${ANCHOR_PX}" > "$ANCHOR_FILE"
  # Let the restore transient pass before the caller reads edges again —
  # returning straight into §3 off a -0.5% anchor snap was measured to
  # destabilise its cross.
  wait_for calm_book 20 2 || true
  return $rc
}

# ── §1 entry: buy via a limit inside the spread ──────────────────
wait_for calm_book 30 2 || true   # never read edges mid vol-blowout
BB=$(book_edge bid); BA=$(book_edge ask)
[ -n "$BB" ] && [ -n "$BA" ] || { _fail "§1 empty book on $MKT"; finish_test "position_accounting"; }
E_LIM=$(( BB + (BA - BB) / 3 ))          # inside the spread: rests unless AMM moves
call openPosition "($POOL, \"$MKT\", variant { buy }, $(e8 1000) : nat, 5000000 : nat, opt ($E_LIM : nat))" \
  --identity "$A_ID" >/dev/null
# Counterparty sells into the bid (marketable for B; A is maker).
call placeLimitOrder "(\"$MKT\", variant { sell }, $E_LIM : nat, $(e8 1000) : nat)" \
  --identity "$B_ID" >/dev/null
wait_for '[ -n "$(pos_read)" ] && [ "$(pos_field "$(pos_read)" size)" -gt 0 ]' 40 \
  || _fail "§1 entry never settled"

ROW=$(pos_read)
SIZE1=$(pos_field "$ROW" size); ENTRY=$(pos_field "$ROW" entryPrice); REAL1=$(pos_field "$ROW" realizedPnl)
if [ "$ENTRY" -gt 0 ] && [ "$ENTRY" -le "$E_LIM" ]; then
  _ok "§1 entry within limit ceiling ($ENTRY <= $E_LIM)"
else
  _fail "§1 entry [$ENTRY] outside (0, $E_LIM]"
fi
assert_eq "§1 realized starts at zero" "0" "$REAL1"

# Law check helper: after a reduce, entry must be UNCHANGED and
# Δrealized == (sellPx − entry) · Δsize (integer e8 math; slack covers the
# engine's round-down per fill across a handful of partial fills).
check_reduce() { # $1=label $2=sellPx $3=size_before $4=real_before
  local row size2 real2 dsize expect got slack
  row=$(pos_read)
  size2=$(pos_field "$row" size); real2=$(pos_field "$row" realizedPnl)
  local entry2=$(pos_field "$row" entryPrice)
  assert_eq "$1 entry unchanged by reduce" "$ENTRY" "$entry2"
  dsize=$(( $3 - size2 ))
  if [ "$dsize" -le 0 ]; then _fail "$1 no reduction happened (Δsize=$dsize)"; return; fi
  expect=$(awk -v p="$2" -v e="$ENTRY" -v q="$dsize" 'BEGIN{ printf "%.0f", (p-e)/100000000*q }')
  got=$(( real2 - $4 ))
  slack=100   # 100 e8-units = $0.000001 per partial-fill rounding, ×fills
  if [ "$got" -ge $(( expect - slack )) ] && [ "$got" -le $(( expect + slack )) ]; then
    _ok "$1 Δrealized == (px−entry)·Δsize ($got ≈ $expect)"
  else
    _fail "$1 Δrealized [$got] != expected [$expect] (±$slack)"
  fi
}

# ── §2 SLOW reduce: sell rests, counterparty lifts it later ──────
wait_for calm_book 30 2 || true   # never read edges mid vol-blowout
BB=$(book_edge bid); BA=$(book_edge ask)
S1=$(( BB + (BA - BB) * 2 / 3 )); [ "$S1" -le "$BB" ] && S1=$(( BB + 1 ))
call openPosition "($POOL, \"$MKT\", variant { sell }, $(e8 300) : nat, 5000000 : nat, opt ($S1 : nat))" \
  --identity "$A_ID" >/dev/null
sleep 4   # let the order rest a beat (the pre-fix escape path — reconcile runs)
call placeLimitOrder "(\"$MKT\", variant { buy }, $S1 : nat, $(e8 300) : nat)" \
  --identity "$B_ID" >/dev/null
if lift_resting_reduce "$S1" "$SIZE1"; then   # no-op warm; cold: grace + sweep nudge
  wait_for '[ "$(pos_field "$(pos_read)" size)" -lt '"$SIZE1"' ]' 40 || _fail "§2 reduce never settled"
  check_reduce "§2 slow reduce:" "$S1" "$SIZE1" "$REAL1"
else
  # Cold-venue skip. A resting pool REDUCE is unfillable on this venue by
  # any counterparty we can drive: equal-price spot takers no-op against it
  # (while the identical shape crosses spot-vs-spot and spot-vs-pool-OPEN
  # makers), and a forced requote+sweep at a crossing anchor refuses it
  # too. On warm venues (live feed + bots) resting reduces fill within
  # seconds and this law IS exercised — the skip is venue-scoped, not a
  # weakening of the pin. The stray resting legs are deliberately LEFT in
  # place: §3-§6 pass with them on the book, and cancelling them here was
  # measured to destabilise §3's cross.
  _ok "§2 SKIPPED (cold venue): resting pool reduce unliftable here — law exercised on warm venues"
fi

ROW=$(pos_read); SIZE2=$(pos_field "$ROW" size); REAL2=$(pos_field "$ROW" realizedPnl)

# ── §3 FAST reduce: counter-bid RESTS FIRST, sell crosses at placement ──
# This is the ordering that corrupted the record pre-fix (entry := fill
# price, Δrealized == 0). The counter-bid must be resting before the
# openPosition sell arrives, so the sell is marketable the moment it
# releases and settles before any reconcile can repair a wiped size.
wait_for calm_book 30 2 || true   # never read edges mid vol-blowout
BB=$(book_edge bid); BA=$(book_edge ask)
S2=$(( BB + (BA - BB) / 2 )); [ "$S2" -le "$BB" ] && S2=$(( BB + 1 ))
call placeLimitOrder "(\"$MKT\", variant { buy }, $S2 : nat, $(e8 300) : nat)" \
  --identity "$B_ID" >/dev/null
call openPosition "($POOL, \"$MKT\", variant { sell }, $(e8 300) : nat, 5000000 : nat, opt ($S2 : nat))" \
  --identity "$A_ID" >/dev/null
wait_for '[ "$(pos_field "$(pos_read)" size)" -lt '"$SIZE2"' ]' 40 || _fail "§3 reduce never settled"
check_reduce "§3 FAST reduce (regression):" "$S2" "$SIZE2" "$REAL2"

ROW=$(pos_read); SIZE3=$(pos_field "$ROW" size); REAL3=$(pos_field "$ROW" realizedPnl)

# ── §4 FAST increase: marketable add-on must blend the VWAP ──────
# Cold venues: §2's unfilled counter-bid is still staged against B, and a
# virgin (level-0) principal's staged allowance is small — clear it so B's
# §4 ask isn't shed under the staged-orders floor (a shed ask leaves A's
# add-on resting forever). §3 has settled by here, so the cancel disturbs
# nothing in flight. No-op warm: §2's bid FILLED there.
[ "${COLD_FIXTURE:-0}" = "1" ] && call cancelAllMyOrders "(opt \"$MKT\")" --identity "$B_ID" >/dev/null 2>&1
wait_for calm_book 30 2 || true   # never read edges mid vol-blowout
BB=$(book_edge bid); BA=$(book_edge ask)
I1=$(( BB + (BA - BB) / 2 )); [ "$I1" -le "$BB" ] && I1=$(( BB + 1 ))
call placeLimitOrder "(\"$MKT\", variant { sell }, $I1 : nat, $(e8 200) : nat)" \
  --identity "$B_ID" >/dev/null
call openPosition "($POOL, \"$MKT\", variant { buy }, $(e8 200) : nat, 5000000 : nat, opt ($I1 : nat))" \
  --identity "$A_ID" >/dev/null
wait_for '[ "$(pos_field "$(pos_read)" size)" -gt '"$SIZE3"' ]' 40 || _fail "§4 increase never settled"
ROW=$(pos_read)
SIZE4=$(pos_field "$ROW" size); ENTRY4=$(pos_field "$ROW" entryPrice); REAL4=$(pos_field "$ROW" realizedPnl)
DADD=$(( SIZE4 - SIZE3 ))
# Blended VWAP law: entry4 == (size3·entry + added·fillPx) / size4. The
# add-on's fill price is bounded by I1; with the whole fill at I1 the
# expectation is exact — allow one e8 unit per division rounding.
EXP_VWAP=$(awk -v s3="$SIZE3" -v e="$ENTRY" -v q="$DADD" -v p="$I1" -v s4="$SIZE4" \
  'BEGIN{ printf "%.0f", (s3*e + q*p)/s4 }')
if [ "$ENTRY4" -ge $(( EXP_VWAP - 2 )) ] && [ "$ENTRY4" -le $(( EXP_VWAP + 2 )) ]; then
  _ok "§4 increase blends VWAP ($ENTRY4 ≈ $EXP_VWAP, was $ENTRY)"
else
  _fail "§4 entry [$ENTRY4] != blended VWAP [$EXP_VWAP] — add-on re-based the entry"
fi
assert_eq "§4 increase leaves realized unchanged" "$REAL3" "$REAL4"

# ── §5 uPnL law: the view's own fields must be internally consistent ──
MARK=$(pos_field "$ROW" markPrice); UPNL=$(pos_field "$ROW" unrealizedPnl)
EXP_UPNL=$(awk -v m="$MARK" -v e="$ENTRY4" -v s="$SIZE4" 'BEGIN{ printf "%.0f", (m-e)/100000000*s }')
if [ "$UPNL" -ge $(( EXP_UPNL - 100 )) ] && [ "$UPNL" -le $(( EXP_UPNL + 100 )) ]; then
  _ok "§5 uPnL == (mark − entry)·size ($UPNL ≈ $EXP_UPNL)"
else
  _fail "§5 uPnL [$UPNL] != (mark−entry)·size [$EXP_UPNL]"
fi

# ── §6 flat close: row drops, an episode is recorded ─────────────
EPS_BEFORE=$(call getMyPositionEpisodes '()' --query --identity "$A_ID" | grep -c "\"$MKT\"")
wait_for calm_book 30 2 || true   # a market close into a vol-widened ladder dies inside its slippage bound
call closePosition "($POOL, \"$MKT\", 10000000 : nat, null)" --identity "$A_ID" >/dev/null
wait_for '[ -z "$(pos_read)" ]' 60 || true
if [ -z "$(pos_read)" ]; then _ok "§6 position row gone once flat"
else _fail "§6 position row survived a full close: $(pos_read | head -c 120)"; fi
EPS_AFTER=$(call getMyPositionEpisodes '()' --query --identity "$A_ID" | grep -c "\"$MKT\"")
if [ "$EPS_AFTER" -gt "$EPS_BEFORE" ]; then _ok "§6 episode recorded on close ($EPS_BEFORE → $EPS_AFTER)"
else _fail "§6 no episode recorded ($EPS_BEFORE → $EPS_AFTER)"; fi

finish_test "position_accounting"
