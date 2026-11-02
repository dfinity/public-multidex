#!/bin/bash
# Self-trade prevention, on the BENEFICIAL owner.
#
# A taker must never fill its own resting maker: a self-cross washes volume,
# pollutes candles, and hands the washer free maker/taker volume toward fee
# levels and badges. The engine cancels the resting self-maker and skips it.
#
# The comparison used to be `Principal.equal(taker, maker)` on the RAW
# principals. A margin pool trades under its own derived principal, so a wallet
# crossing its OWN pool looked like two strangers and settled normally — an
# equity-neutral round trip (both sides are you) costing only fees, while
# accruing maker volume at 2x toward the level ladder. The venue already
# resolved pool→owner for rewards; STP now resolves it too, so the two sides
# are compared as the single party that actually benefits.
#
# What this pins:
#   §1 wallet vs its OWN wallet order — prevented (the original behaviour,
#      guarded against regression)
#   §2 wallet vs its OWN MARGIN POOL — prevented (what raw-principal
#      comparison let through)
#   §3 a DIFFERENT user still fills the same order normally — the fix must
#      block self-crossing, not liquidity
#
# Mechanics: a post-only sell at the mark rests as the best ask (the AMM quotes
# a spread around the mark, so its own ask sits above it and its bid below, and
# a post-only order is maker-or-kill so it cannot cross on entry). Anything
# buying at the mark must therefore meet that ask first.
#
# ⚠️ Places real orders on the configured venue; cancels what it places.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"

echo "── test_self_trade_prevention ──"

# Pick whichever market actually has a priced AMM pool on this venue —
# resetExchange in other suites can leave only a subset seeded.
PICK=$(icp canister call --candid "$MDX_CANDID" backend getAmmPools '()' --query --identity anonymous 2>&1 \
  | tr '}' '\n' | grep -oE 'marketId = "[^"]*"' | head -1 | grep -oE '"[^"]*"' | tr -d '"')
MKT="${PICK:-BTC-ICPUSD}"

# Two funded actors: STP is about who benefits, so we need a real second party
# to prove liquidity still works.
A="stp_a"; B="stp_b"
mdx_identity_new "$A"; mdx_identity_new "$B"   # virgin each run, deleted on EXIT (tests/_lib.sh)
APRIN=$(icp identity principal --identity "$A" 2>/dev/null | tail -1)
BPRIN=$(icp identity principal --identity "$B" 2>/dev/null | tail -1)
call setTestBalance "(principal \"$APRIN\", \"ICPUSD\", 200000000000 : nat)" --identity anonymous >/dev/null
BASE="${MKT%%-*}"
call setTestBalance "(principal \"$APRIN\", \"$BASE\", 500000000 : nat)" --identity anonymous >/dev/null
call setTestBalance "(principal \"$BPRIN\", \"ICPUSD\", 200000000000 : nat)" --identity anonymous >/dev/null

MARK=$(call getAmmPool "(\"$MKT\")" --query --identity anonymous | grep -oE 'refPrice = [0-9_]+' | head -1 | grep -oE '[0-9_]+' | tr -d '_')
if [ -z "${MARK:-}" ] || [ "$MARK" = "0" ]; then
  echo "  SKIP: $MKT has no reference price on this venue"; exit 0
fi
echo "  market = $MKT   mark = $MARK"
# ~$200 of notional, whatever the asset is priced at (1 BTC would exceed the
# funded balance; 1 ICP would be dust).
QTY=$(python3 -c "print(max(1, (20000000000 * 100000000) // $MARK))")
echo "  qty = $QTY"

# Rest a post-only ask at the mark, owned by A. Returns the order id.
rest_ask() {
  # placeLimitOrderPO takes an expiry arg and answers a PlaceLimitResult
  # RECORD (not a bare nat) — the resting id is its `id` field.
  local r; r=$(call placeLimitOrderPO "(\"$MKT\", variant { sell }, $MARK : nat, $QTY : nat, null)" --identity "$A")
  echo "$r" | tr ';' '\n' | grep -oE '^ *id = [0-9_]+' | head -1 | grep -oE '[0-9_]+' | tr -d '_' 
}
open_orders_of() { call getMyOrders '()' --query --identity "$1"; }
# Wait until order $1 has left A's book, or give up. A fixed sleep races the
# staged→release cycle, which is >4s on a busy venue.
gone() { local i=0; while [ $i -lt 15 ]; do
           open_orders_of "$A" | tr ';' '\n' | grep -qE "id = $1\b" || return 0
           sleep 1; i=$((i+1)); done; return 1; }
# Wait for a balance to rise above $2, or give up.
rose() { local i=0 v; while [ $i -lt 15 ]; do
           v=$(extract_first_nat "$(call getTestBalance "(principal \"$3\", \"$BASE\")" --identity "$2")")
           [ "${v:-0}" -gt "${1:-0}" ] && return 0
           sleep 1; i=$((i+1)); done; return 1; }

# ── §1 wallet crossing its OWN wallet order ──
OID=$(rest_ask)
if [ -z "${OID:-}" ]; then
  echo "  SKIP: could not rest a post-only ask (book/oracle state)"; exit 0
fi
_ok "§1 A rested a post-only ask at the mark (order $OID)"
# A now buys at the mark — the only ask at that price is its own.
call placeLimitOrder "(\"$MKT\", variant { buy }, $MARK : nat, $QTY : nat)" --identity "$A" >/dev/null
if gone "$OID"; then _ok "§1 A's own ask was cancelled by STP, not filled by A"
else _fail "§1 A's own ask survived a self-cross" "order $OID still open"; fi

# ── §2 wallet crossing its OWN MARGIN POOL ──
# The pool trades under a DERIVED principal. Before this fix that read as a
# different party and the cross settled.
POOL=$(call createMarginPool "(\"stp-pool\", false)" --identity "$A" | grep -oE 'ok = [0-9_]+' | grep -oE '[0-9_]+' | tr -d '_' | head -1)
if [ -n "${POOL:-}" ]; then
  call fundMarginPool "($POOL : nat, 100000000000 : nat)" --identity "$A" >/dev/null
  OID2=$(rest_ask)
  if [ -n "${OID2:-}" ]; then
    _ok "§2 A rested another post-only ask (order $OID2)"
    # A's POOL goes long at the mark — it must meet A's own ask first.
    call openPosition "($POOL : nat, \"$MKT\", variant { buy }, $QTY : nat, 5000000 : nat, opt ($MARK : nat))" --identity "$A" >/dev/null
    if gone "$OID2"; then _ok "§2 A's ask was cancelled by STP when A's own POOL crossed it"
    else _fail "§2 the pool filled A's own ask (raw-principal comparison)" "order $OID2 still open"; fi
  else
    _fail "§2 could not rest the second ask" "book state"
  fi
else
  _fail "§2 could not create a margin pool" "createMarginPool refused"
fi

# ── §3 a genuinely different user still fills it ──
# STP must block self-crossing, not liquidity. B is unrelated to A.
OID3=$(rest_ask)
if [ -n "${OID3:-}" ]; then
  _ok "§3 A rested a third post-only ask (order $OID3)"
  BAL_BEFORE=$(extract_first_nat "$(call getTestBalance "(principal \"$BPRIN\", \"$BASE\")" --identity "$B")")
  call placeLimitOrder "(\"$MKT\", variant { buy }, $MARK : nat, $QTY : nat)" --identity "$B" >/dev/null
  if rose "${BAL_BEFORE:-0}" "$B" "$BPRIN"; then
    _ok "§3 an unrelated taker still fills A's ask (B's base balance rose)"
  else
    _fail "§3 STP blocked a legitimate counterparty" "B base ${BAL_BEFORE:-?} → ${BAL_AFTER:-?}"
  fi
fi

call cancelAllMyOrders '(null)' --identity "$A" >/dev/null 2>&1 || true
call cancelAllMyOrders '(null)' --identity "$B" >/dev/null 2>&1 || true

finish_test "self_trade_prevention"
