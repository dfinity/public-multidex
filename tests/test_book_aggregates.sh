#!/bin/bash
# Incremental order-book aggregates + resting-book bounds.
#
# The book's price-level depth and per-user exposure totals are maintained
# incrementally at every order transition (place/cancel/partial fill/full
# fill, plus the AMM's requote cancel/repost churn) instead of being
# re-walked per query — adminVerifyBookAggregates re-walks the raw orders
# and diffs both directions, so the single strong assertion after every
# workload stage is "verifier returns empty".
#   §1  place + cross + partial fill → aggregates consistent, trades printed
#   §2  getOrderBook depth param: opt N caps levels per side, null = full
#   §3  cancel keeps aggregates consistent
#   §4  per-user open-order cap: placement at the cap evicts oldest
#   §5  GTC TTL: adminSweepStaleOrders retires orders older than the TTL
#   §6  aggregates still consistent after reset
# Timers PAUSED; staged orders release via the explicit release() pattern
# (setAmmRefPrice + requoteAmm). Sim killed. ⚠️ Calls resetExchange.

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
mdx_identity_new bookagg_a; A_P=$(principal_of bookagg_a); mdx_identity_new bookagg_b; B_P=$(principal_of bookagg_b)
M="BTC-ICPUSD"
place() { # identity side price qty  (prices/qtys already in e8)
  icp canister call --candid "$MDX_CANDID" --identity "$1" backend placeLimitOrder "(\"$M\", variant { $2 }, $3 : nat, $4 : nat)" 2>&1
}
release() { adm setAmmRefPrice "(\"$M\", $(e8 60000.0) : nat)" >/dev/null; adm requoteAmm "(\"$M\")" >/dev/null; }
verify_clean() { # label
  local V; V=$(adm adminVerifyBookAggregates '()' --query)
  if echo "$V" | grep -q 'vec {}'; then ok "aggregates consistent: $1"; else nok "aggregate drift: $1" "$(echo "$V" | head -c 300)"; fi
}
open_count() { # identity — resting only (call after release(), staged queue empty)
  icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyOrders '()' --query 2>/dev/null | grep -c "id ="
}

# The sim must be dead (header: its churn would move the book mid-assertion).
# Stop it via the PID-file stopper — NEVER a pattern kill: `pkill -f` cannot
# tell a local simulator from one driving multidex.ai and took the live fleet
# down three times (run_all.sh's stopper comment + scripts/lib/bots.sh).
# run_all.sh already stops the fleet for suite runs; this covers standalone.
STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
if [ -f "$STOPPER" ]; then
  bash "$STOPPER" >/dev/null 2>&1 || true
  sleep 2
else
  echo "⚠ stop_bots_local.sh not found at $STOPPER — the local fleet was NOT stopped."
  echo "  Red results below may be simulator noise rather than regressions."
fi
adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestOrderCap '(null)' >/dev/null
adm setTestOrderTtl '(null)' >/dev/null
adm createAmmPool "(\"$M\")" >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"$M\", $(e8 60000.0) : nat)" >/dev/null
adm enableAmm "(\"$M\", true)" >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$AMM\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$A_P\", \"ICPUSD\", $(e8 100000000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$B_P\", \"BTC\",    $(e8 100.0) : nat)"      >/dev/null
adm setTestBalance "(principal \"$B_P\", \"ICPUSD\", $(e8 10000.0) : nat)"    >/dev/null

echo "── §1 place / cross / partial fill ──"
# A: bids at 50k ×2 (same level) + 50.1k; one marketable bid at 60k.
place bookagg_a buy  $(e8 50000.0) $(e8 1.0) >/dev/null
place bookagg_a buy  $(e8 50000.0) $(e8 2.0) >/dev/null
place bookagg_a buy  $(e8 50100.0) $(e8 1.0) >/dev/null
place bookagg_a buy  $(e8 60000.0) $(e8 1.0) >/dev/null
# B: far asks (rest) + one crossing sell that partially fills A's 60k bid.
place bookagg_b sell $(e8 90000.0) $(e8 1.0) >/dev/null
place bookagg_b sell $(e8 90100.0) $(e8 1.0) >/dev/null
place bookagg_b sell $(e8 59000.0) $(e8 0.4) >/dev/null
release; sleep 2; release; sleep 1
BOOK=$(adm getOrderBook "(\"$M\")" --query)
LEVELS=$(echo "$BOOK" | grep -c "price =")
TRADES=$(adm getRecentTrades "(\"$M\")" --query | grep -c "price =")
if [ "$TRADES" -ge 1 ]; then ok "crossing sell traded ($TRADES fill(s))"; else nok "no trade printed" "$(echo "$BOOK" | head -c 200)"; fi
if [ "$LEVELS" -ge 4 ]; then ok "book holds the resting levels ($LEVELS incl. AMM ladder)"; else nok "book too shallow" "$LEVELS levels"; fi
verify_clean "after place + partial fill"

echo "── §2 depth parameter ──"
FULL=$(adm getOrderBook "(\"$M\")" --query | grep -c "price =")
CAP1=$(adm getOrderBookDepth "(\"$M\", opt (1 : nat))" --query | grep -c "price =")
if [ "$CAP1" -le 2 ] && [ "$CAP1" -ge 1 ]; then ok "depth 1 returns ≤1 level per side ($CAP1 total, full=$FULL)"; else nok "depth cap ignored" "cap1=$CAP1 full=$FULL"; fi
if [ "$FULL" -gt "$CAP1" ]; then ok "null depth returns the whole book"; else nok "full ≤ capped" "cap1=$CAP1 full=$FULL"; fi

echo "── §3 cancel ──"
OID=$(icp canister call --candid "$MDX_CANDID" --identity bookagg_a backend getMyOrders '()' --query | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+")
if [ -n "${OID:-}" ]; then
  icp canister call --candid "$MDX_CANDID" --identity bookagg_a backend cancelMyOrder "($OID : nat)" >/dev/null 2>&1
  verify_clean "after cancel #$OID"
else
  nok "no order id to cancel" "getMyOrders empty"
fi

echo "── §4 per-user open-order cap (oldest evicted) ──"
adm setTestOrderCap '(opt (3 : nat))' >/dev/null
i=0
while [ $i -lt 5 ]; do
  place bookagg_a buy $((4000000000000 + i * 100000000)) $(e8 0.01) >/dev/null
  release   # rest it before the next placement counts it
  i=$((i+1))
done
release; sleep 1
CNT=$(open_count bookagg_a)
if [ "$CNT" -le 3 ]; then ok "open orders bounded by the cap (count=$CNT ≤ 3)"; else nok "cap not enforced" "count=$CNT"; fi
EV=$(adm getRecentEvents '(80 : nat)' --query 2>/dev/null)
if echo "$EV" | grep -q "open-order cap"; then ok "eviction event logged"; else nok "no eviction event" "$(echo "$EV" | grep -c cancelled) cancel events"; fi
verify_clean "after evictions"

echo "── §5 GTC time-to-live sweep ──"
adm setTestOrderCap '(null)' >/dev/null
adm setTestOrderTtl '(opt (3 : nat))' >/dev/null
place bookagg_b sell $(e8 95000.0) $(e8 0.5) >/dev/null
place bookagg_b sell $(e8 95100.0) $(e8 0.5) >/dev/null
release; sleep 4   # rest on the book, then age past the 3s TTL
SWEPT=$(adm adminSweepStaleOrders '()' | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ "${SWEPT:-0}" -ge 2 ]; then ok "TTL sweep retired stale orders (swept=$SWEPT)"; else nok "TTL sweep missed" "swept=${SWEPT:-?}"; fi
BCNT=$(open_count bookagg_b)
if [ "$BCNT" -eq 0 ]; then ok "all of B's resting orders swept (count=0)"; else nok "B still has resting orders" "count=$BCNT"; fi
EV=$(adm getRecentEvents '(40 : nat)' --query 2>/dev/null)
if echo "$EV" | grep -q "time-to-live"; then ok "TTL event logged"; else nok "no TTL event" "$(echo "$EV" | head -c 200)"; fi
adm setTestOrderTtl '(null)' >/dev/null
verify_clean "after TTL sweep"

echo "── §6 reset leaves aggregates clean ──"
adm resetExchange "()" >/dev/null 2>&1
POST=$(adm getOrderBook "(\"$M\")" --query | grep -c "price =")
if [ "$POST" -eq 0 ]; then ok "book empty after reset"; else nok "levels survived reset" "$POST"; fi
verify_clean "after reset"
adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true

echo ""
echo "════════════════════════════════════"
echo -e "  ${GREEN}pass: $pass${NC}  ${RED}fail: $fail${NC}"
echo "════════════════════════════════════"
[ "$fail" -eq 0 ]
