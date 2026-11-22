#!/bin/bash
# Price collar: tight on MARKETABLE orders, loose on RESTING ones.
#
# The 100x band (PRICE_BAND_FACTOR) is a fat-finger guard — its own error text
# says "likely an input error" — and it permits a print anywhere from mark/100
# to mark*100. Two colluding accounts could therefore move value at will: one
# rests far off the mark, the other takes it, and thousands of dollars cross on
# a trade that is not a trade. The board ranks on profit, so a bought print is
# a bought rank. Self-trade prevention does not see this: the two sides are
# genuinely different beneficiaries.
#
# The collar binds only orders that would EXECUTE NOW, and stays wide for
# orders that merely rest. The asymmetry is the point:
#
#   * A RESTING order priced absurdly is an OFFER to the whole venue, not a
#     transfer. Anyone can take it — including the protocol arbitrageur, which
#     exists to take exactly this — so the attacker cannot choose who fills it.
#     Far-from-market resting orders are also a legitimate strategy (a bid far
#     below, waiting for a crash), so banning them would cost real function to
#     prevent nothing.
#   * A MARKETABLE order names the price AND the counterparty, because it
#     executes against a specific resting order in the same instant. That is
#     where the transfer actually happens, so that is what the collar binds.
#
# What this pins:
#   §1 a marketable buy far ABOVE the mark is REFUSED (the wash take)
#   §2 a marketable sell far BELOW the mark is REFUSED (the other direction)
#   §3 a RESTING sell far above the mark is ALLOWED (waiting for a rally)
#   §4 a RESTING buy far below the mark is ALLOWED (waiting for a crash)
#   §5 ordinary trading at the mark is untouched
#   §6 the loose fat-finger band still catches genuinely absurd input
#
# NOTE on direction, which is easy to get backwards: a SELL far BELOW the mark
# is marketable (it crosses the bid and executes at once), and a SELL far ABOVE
# it rests. Buys are the mirror. "Far from the mark" alone does not say which.
#
# ⚠️ Places real orders on the configured venue; cancels what it places.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_price_collar ──"

PICK=$(icp canister call --candid "$MDX_CANDID" backend getAmmPools '()' --query --identity anonymous 2>&1 \
  | tr '}' '\n' | grep -oE 'marketId = "[^"]*"' | head -1 | grep -oE '"[^"]*"' | tr -d '"')
MKT="${PICK:-BTC-ICPUSD}"
BASE="${MKT%%-*}"

U="collar_u"; mdx_identity_new "$U"   # virgin each run, deleted on EXIT (tests/_lib.sh)
UPRIN=$(icp identity principal --identity "$U" 2>/dev/null | tail -1)

MARK=$(call getAmmPool "(\"$MKT\")" --query --identity anonymous | grep -oE 'refPrice = [0-9_]+' | head -1 | grep -oE '[0-9_]+' | tr -d '_')
if [ -z "${MARK:-}" ] || [ "$MARK" = "0" ]; then
  echo "  ⊘ SKIP: $MKT has no reference price on this venue"; exit 0
fi
QTY=$(python3 -c "print(max(1, (20000000000 * 100000000) // $MARK))")
HIGH=$(python3 -c "print($MARK * 50)")      # 50x — inside the 100x band, far outside 5%
LOW=$(python3 -c "print($MARK // 50)")
ABSURD=$(python3 -c "print($MARK * 500)")   # outside the 100x fat-finger band too
# Largest quantity this test ever places. Defined HERE because the funding
# below has to be sized from it — see the note on the base leg.
QTY_LOW=$(python3 -c "print($QTY * 60)")
echo "  market=$MKT mark=$MARK qty=$QTY"

# Fund generously: a resting bid 50x above the mark reserves 50x the notional,
# and these assertions must fail on the COLLAR, never on the balance.
# The BASE leg is sized from QTY_LOW rather than a fixed amount because QTY
# scales INVERSELY with the mark — on a cheap base asset QTY_LOW runs to
# thousands of units, and the old hardcoded 50 made every sell fail on
# insufficient balance instead of on the collar under test.
BASE_FUND=$(python3 -c "print($QTY_LOW * 4)")
call setTestBalance "(principal \"$UPRIN\", \"ICPUSD\", 900000000000000 : nat)" --identity anonymous >/dev/null
call setTestBalance "(principal \"$UPRIN\", \"$BASE\", $BASE_FUND : nat)" --identity anonymous >/dev/null

# PRECONDITION: the book's touch must lie INSIDE the collar band.
#
# Two different reference points are in play, and the test is only meaningful
# when they agree. The collar is measured from the AMM pool's refPrice
# (priceBandCheck, main.mo), but MARKETABILITY is measured against the BOOK
# (isMarketable → findBestMatch). If the touch sits outside refPrice ± the
# band, then a probe at ±6% cannot cross anything, is therefore not
# marketable, and the collar is never consulted — the assertion then fails
# saying "not refused" when the collar was simply never reached.
#
# This is not hypothetical: on a #dev venue seeded by cold_start the BTC book
# has been observed resting near $75,000 against a pool refPrice of $64,179
# (17% apart). Nor can the test paper over it by quoting its own maker inside
# the band — a post-only order there crosses the far-side book and is killed
# at release, which is exactly what happens. So detect it and say so.
# Range-based parse (`/asks = /,/}/p`), NOT the old single-line substitute-
# print: candid pretty-prints the depth record across lines, and a parse that
# only reads text on the `asks = vec {` line comes back empty on a multi-line
# response — which made this precondition exit "no two-sided book" as a
# SILENT pass on venues that had a perfectly good book.
DEPTH=$(call getOrderBookDepth "(\"$MKT\", null)" --query --identity anonymous 2>&1 | tr -d '_')
side_prices() { echo "$DEPTH" | sed -n "/$1 = /,/}/p" | grep -oE 'price = [0-9]+' | grep -oE '[0-9]+'; }
BEST_ASK=$(side_prices asks | sort -n  | head -1)   # lowest ask
BEST_BID=$(side_prices bids | sort -rn | head -1)   # highest bid
echo "  book: best ask=${BEST_ASK:-none} best bid=${BEST_BID:-none}"
if [ -z "${BEST_ASK:-}" ] || [ -z "${BEST_BID:-}" ]; then
  echo "  ⊘ SKIP: $MKT has no two-sided book — the collar cannot be exercised"; exit 0
fi
BAND_HI=$(python3 -c "print(int($MARK * 1.05))")
BAND_LO=$(python3 -c "print(int($MARK * 0.95))")
if [ "$BEST_ASK" -gt "$BAND_HI" ] || [ "$BEST_BID" -lt "$BAND_LO" ]; then
  echo "  ⊘ SKIP: $MKT book touch (bid $BEST_BID / ask $BEST_ASK) is outside the collar band"
  echo "        [$BAND_LO..$BAND_HI] around refPrice $MARK — no ±6% probe can be marketable,"
  echo "        so the collar is unreachable. Book and pool refPrice have diverged on this venue."
  exit 0
fi

# crosses <price> <side> — 0 if an order at that price would execute at once.
# Mirrors isMarketable EXACTLY rather than approximating it: a buy at P is
# marketable <=> P >= best ask; a sell at P <=> P <= best bid. "An ask exists"
# is NOT the condition — §1 at 50x crosses almost any ask, but §5's +6% probe
# does not cross an ask resting higher than that, and a coarse gate would let
# §5 through to fail for a reason the collar never promised.
crosses() {
  case "$2" in
    buy)  [ -n "$BEST_ASK" ] && [ "$1" -ge "$BEST_ASK" ] ;;
    sell) [ -n "$BEST_BID" ] && [ "$1" -le "$BEST_BID" ] ;;
  esac
}

place()   { call placeLimitOrder   "(\"$MKT\", variant { $1 }, $2 : nat, ${3:-$QTY} : nat)" --identity "$U"; }
placePO() { call placeLimitOrderPO "(\"$MKT\", variant { $1 }, $2 : nat, ${3:-$QTY} : nat, null)" --identity "$U"; }
# QTY_LOW (defined above, next to QTY) exists because a far-BELOW price makes
# the notional tiny (price x qty), so a fixed quantity falls under the venue's
# minimum order value and is refused for THAT reason — nothing to do with the
# collar. Scaling the quantity keeps the notional constant wherever the price is.
COLLAR="must be within"
FATFINGER="likely an input error"

# ── §1/§2 marketable, far from the mark → refused ──
# MARKETABILITY IS A PROPERTY OF THE BOOK, not of the price: the tight collar
# applies only to orders that would execute NOW, so each refusal assertion is
# gated on the probe actually crossing the touch. The band precondition above
# guarantees the ±6% probes cross; the 50x/÷50 probes additionally need the
# relevant side to exist at all.
if crosses "$HIGH" buy; then
  assert_contains "§1 marketable buy 50x ABOVE the mark is refused" "$(place buy "$HIGH")" "$COLLAR"
else
  echo "  ⊘ §1 skipped: a buy at $HIGH does not cross the best ask (${BEST_ASK:-none}) — not marketable."
fi
if crosses "$LOW" sell; then
  assert_contains "§2 marketable sell 50x BELOW the mark is refused" "$(place sell "$LOW" "$QTY_LOW")" "$COLLAR"
else
  echo "  ⊘ §2 skipped: a sell at $LOW does not cross the best bid (${BEST_BID:-none}) — not marketable."
fi

# ── §3/§4 resting, far from the mark → allowed ──
# Post-only guarantees these REST (maker-or-kill), so reaching an id proves the
# collar let them through rather than the book happening to be empty.
R=$(placePO sell "$HIGH")
assert_not_contains "§3 resting sell far ABOVE the mark is not collared" "$R" "$COLLAR"
assert_contains     "§3 ...and actually rests" "$R" "id ="
R=$(placePO buy "$LOW" "$QTY_LOW")
assert_not_contains "§4 resting buy far BELOW the mark is not collared" "$R" "$COLLAR"
assert_contains     "§4 ...and actually rests" "$R" "id ="

# ── §5 ordinary trading is untouched ──
R=$(place buy "$MARK")
assert_not_contains "§5 a buy AT the mark is not collared" "$R" "$COLLAR"
R=$(place sell "$MARK")
assert_not_contains "§5 a sell AT the mark is not collared" "$R" "$COLLAR"
# Just inside the collar must pass; just outside must not.
IN=$(python3 -c "print(int($MARK * 1.04))")
OUT=$(python3 -c "print(int($MARK * 1.06))")
assert_not_contains "§5 marketable buy +4% (inside the collar) passes" "$(place buy "$IN")" "$COLLAR"
# Same book dependency as §1: +6% is only refused if it is MARKETABLE, which
# needs a resting ask at or below it to cross.
if crosses "$OUT" buy; then
  assert_contains   "§5 marketable buy +6% (outside) is refused"       "$(place buy "$OUT")" "$COLLAR"
else
  echo "  ⊘ §5 +6% refusal skipped: a buy at $OUT does not cross the best ask (${BEST_ASK:-none})."
fi

# ── §6 the loose fat-finger band still applies to everything ──
# 500x is outside the 100x band, so even a RESTING order is refused — and by
# the fat-finger rule, not the collar.
assert_contains "§6 a resting sell 500x above the mark still hits the 100x band" \
  "$(placePO sell "$ABSURD")" "$FATFINGER"

call cancelAllMyOrders '(null)' --identity "$U" >/dev/null 2>&1 || true

finish_test "price_collar"
