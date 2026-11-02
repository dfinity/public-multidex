#!/bin/bash
# #55 "sweep fills an expired order" (OhShii Labs round 18): ammSweepResting
# must CANCEL an expired crossing order, never re-submit it as the aggressor.
#
# The contract says an expired order is "never filled" — every ctx.isExpired
# site tests the MAKER, and the sweep's re-homed aggressor was never checked
# against orderExpiry before the fix. A GTD bid whose expiry lapsed while it
# rested, then had the mark drop through it, was filled by the very next
# requote's sweep (the real window: a GEPTOR requote landing after its
# outcall, before the 0.5 s finaliser beat swept the order).
#
#   §1 expired resting GTD bid + mark drops through it + requoteAmm
#        → order `cancelled`, ZERO trades, no base credited   (RED pre-fix)
#   §2 control: a LIVE GTD bid in the same shape IS swept and fills
#        (the guard must not over-cancel)
#
# "Move the clock past expiry" is setTestOrderExpiry on the order's CURRENT
# (post-release) id — the venue has no clock hook; backdating the expiry is
# the same observation from the matcher's side. Needs #dev (setAmmRefPrice,
# setTestOrderExpiry, setTestBalance). Self-seeding: resets the exchange.
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_sweep_expired_order.sh

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --candid "$MDX_CANDID" --identity swx_u backend "$@" 2>&1; }
MKT="ICP-ICPUSD"
mdx_identity_new swx_u; U=$(principal_of swx_u)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }

# The user's one order: its CURRENT id (staging id → released id via
# getMyOrderStatus's releasedAsId), and its status / filled qty.
resting_id() {  # $1 = staging id
  local st rid
  st=$(u getMyOrderStatus "($1 : nat)" --query | tr -d '\n_')
  rid=$(echo "$st" | grep -oE "releasedAsId = opt \([0-9]+" | grep -oE "[0-9]+$")
  echo "${rid:-$1}"
}
order_status() { u getMyOrderStatus "($1 : nat)" --query | tr -d '\n' | grep -oE "status = variant \{ [a-zA-Z]+" | grep -oE "[a-zA-Z]+$"; }
icp_bal()      { adm getTestBalance "(principal \"$U\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"; }
trade_count()  { u getMyTradeHistory '()' --query | tr -d '\n' | grep -o "price =" | wc -l | tr -d ' '; }
last_fill_px() { u getMyTradeHistory '()' --query | tr -d '_' | grep -oE "price = [0-9]+" | tail -1 | grep -oE "[0-9]+"; }
open_count()   { u getMyOrders '()' --query | tr -d '\n' | grep -o "status = variant { open" | wc -l | tr -d ' '; }
# NB: after ANY sweep the swept id itself reads `cancelled` — the sweep's shape
# is cancel + re-submit under a fresh id (W4-07) — so the old id's status
# cannot tell a cancel from a fill. The discriminators are the observables the
# finding named: trades, base credited, and what is left open on the book.

# Fresh venue: AMM at mid 10, 20 bps spread, 5 levels 10 bps apart, timers
# paused so only OUR requoteAmm calls sweep.
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
mdx_identity_new swx_seed; SEED=$(principal_of swx_seed)
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
adm setAmmConfig "(\"$MKT\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 10000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 200000.0) : nat)" >/dev/null
mdx_lp_deposit swx_seed "$MKT" "$(e8 10000.0)" "$(e8 100000.0)" >/dev/null 2>&1
adm enableAmm "(\"$MKT\", true)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
adm setTestBalance "(principal \"$U\", \"ICPUSD\", $(e8 100.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$U\", \"ICP\", 0 : nat)" >/dev/null

# Place a GTD bid 10% under the mark (rests, does not cross), release it with
# a fresh price stamp (the sealed pipeline's release gate is price-POSTDATES-
# entry), and return its resting id.
place_rested_gtd_bid() {  # $1 = price (human)
  local r oid rid
  r=$(u placeLimitOrderExp "(\"$MKT\", variant { buy }, $(e8 "$1") : nat, $(e8 2.0) : nat, opt (150 : nat))")
  oid=$(echo "$r" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+")
  adm setAmmRefPrice "(\"$MKT\", $(e8 10.0) : nat)" >/dev/null
  adm requoteAmm "(\"$MKT\")" >/dev/null           # release → rests below the AMM bids
  rid=$(resting_id "${oid:-0}")
  echo "$rid"
}

echo "── §1 expired GTD bid: the sweep must cancel it, not fill it ──"
RID=$(place_rested_gtd_bid 9.0)
S0=$(order_status "$RID")
[ "${S0:-x}" = "open" ] && ok "GTD bid rests (id $RID, status open)" || nok "GTD bid did not rest" "id=$RID status=${S0:-none}"
T0=$(trade_count); B0=$(icp_bal)
# Expiry lapses while it rests (timers paused: no finaliser sweep between here
# and our requote — exactly the GEPTOR race window). Backdate on the CURRENT id.
adm setTestOrderExpiry "($RID : nat, 1 : int)" >/dev/null
# Mark drops THROUGH the bid: AMM asks land at ~8.0x < 9.0, so the bid crosses.
adm setAmmRefPrice "(\"$MKT\", $(e8 8.0) : nat)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
T1=$(trade_count); B1=$(icp_bal); O1=$(open_count)
[ "${T1:-0}" = "${T0:-0}" ] && ok "zero trades from the sweep (trades $T0 → $T1)" || nok "the sweep traded an expired order (the finding)" "trades $T0 → $T1"
[ "${B1:-0}" = "${B0:-0}" ] && ok "no base credited (ICP $B0 → $B1)" || nok "base credited to an expired order (the finding)" "ICP $B0 → $B1"
[ "${O1:-9}" = "0" ] && ok "expired bid retired from the book (no open order, no re-homed remainder)" || nok "expired bid still open after the sweep" "open=$O1"

echo "── §2 control: a LIVE GTD bid in the same shape is swept and fills ──"
adm setAmmRefPrice "(\"$MKT\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null           # restore the ladder around 10
RID2=$(place_rested_gtd_bid 9.0)
S2=$(order_status "$RID2")
[ "${S2:-x}" = "open" ] && ok "live GTD bid rests (id $RID2)" || nok "live GTD bid did not rest" "id=$RID2 status=${S2:-none}"
T2=$(trade_count)
adm setAmmRefPrice "(\"$MKT\", $(e8 8.0) : nat)" >/dev/null
adm requoteAmm "(\"$MKT\")" >/dev/null
T3=$(trade_count); B3=$(icp_bal); PX=$(last_fill_px); O3=$(open_count)
[ "${T3:-0}" -gt "${T2:-0}" ] && ok "live bid swept and traded ($T2 → $T3 trades)" || nok "live bid not filled by the sweep (guard over-cancels?)" "trades $T2 → $T3"
[ "${B3:-0}" -gt "${B1:-0}" ] && ok "base credited for the live fill (ICP $B1 → $B3)" || nok "no base credited for the live fill" "ICP $B1 → $B3"
if [ -n "${PX:-}" ] && [ "$PX" -gt 0 ] && [ "$PX" -lt "$(e8 9.0)" ]; then ok "filled at the AMM's price ($PX < the 9.0 limit)"; else nok "fill price not the AMM's" "px=${PX:-none}"; fi
[ "${O3:-9}" = "0" ] && ok "nothing left open after the live fill" || nok "live bid left an open remainder" "open=$O3"

adm setTestTimersPaused '(false)' >/dev/null 2>&1

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_sweep_expired_order ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_sweep_expired_order ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
