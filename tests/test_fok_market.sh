#!/bin/bash
# Fill-or-kill (noPartialFill) MARKET orders under the sealed model. A FOK market
# order now STAGES like any other, and on its first post-submission GEPTOR it
# either fully fills within the slippage cap (against fresh AMM + users) or is
# KILLED (nothing fills, reservation refunded).
#
# RUN WITH THE TRADING BOT PAUSED:
#     bash scripts/stop_bots_local.sh
#     bash tests/test_fok_market.sh

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money migration: trading/admin methods take Nat BASE UNITS (10^8), and
# getTestBalance now RETURNS base units. e8 converts human→base for call args;
# from_e8 converts base→human so the human-scale assertions below stay unchanged.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
adm()  { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
# The AMM's inventory lives under its own principal — resolve it LIVE (a
# hardcoded id goes stale on every redeploy and silently zeroes the AMM's
# side of the conservation sums).
AMM=$(adm getAmmPrincipal '()' | grep -oE '"[a-z0-9-]+"' | tr -d '"')
# bal → HUMAN units: pull the base-unit Nat (strip Candid underscores) and /1e8.
bal()  { local n; n=$(adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+ : nat" | head -1 | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
# Treasury USD (human) — the maker/taker fee skims here on every fill, so the
# ICPUSD conservation set must include it (resetExchange zeroes it at setup).
treas() { local n; n=$(adm getTreasury '()' | tr -d '_' | grep -oE "balanceUsd = [0-9]+" | grep -oE "[0-9]+"); [ -z "$n" ] && n=0; from_e8 "$n"; }
freshrequote() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }

mdx_identity_new amm_seed; S=$(principal_of amm_seed); mdx_identity_new amm_uA; UA=$(principal_of amm_uA)
u() { icp canister call --candid "$MDX_CANDID" --identity amm_uA backend "$@" 2>&1; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # quiesce background timers for a deterministic run
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
# 5 levels × 100 ICP within ~1.25% → ~500 ICP of ask depth, all under a 5% cap.
# (quoteDepthBase is a base-unit Nat quantity now; spread/levels/spacing/window stay plain nats.)
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
mdx_lp_deposit amm_seed "ICP-ICPUSD" "$(e8 10000.0)" "$(e8 100000.0)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 0.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
# Closed set = {UA, AMM, seed identity, treasury}: fees skim to the treasury and
# the AMM holds the pool inventory under its own principal.
USD_BASE=$(awk -v a="$(bal "$UA" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" -v s="$(bal "$S" ICPUSD)" -v t="$(treas)" 'BEGIN{printf "%.4f", a+b+s+t}')
ICP_BASE=$(awk -v a="$(bal "$UA" ICP)" -v b="$(bal "$AMM" ICP)" -v s="$(bal "$S" ICP)" 'BEGIN{printf "%.4f", a+b+s}')

# ── 1. FOK market buy 5 ICP (within depth) stages, then FULLY fills on GEPTOR ──
echo ""
echo "── 1. FOK market buy 5 ICP → stages, then fully fills at the AMM price ──"
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
ICP_P=$(bal "$UA" ICP)
freshrequote
ICP1=$(bal "$UA" ICP)
if awk -v p="$ICP_P" 'BEGIN{exit (p<0.0000001?0:1)}' && awk -v i="$ICP1" 'BEGIN{exit (i>4.99 && i<5.01?0:1)}'; then
  ok "staged (0 ICP at placement), then FULLY filled $ICP1 ICP on release"
else nok "FOK within depth should stage then fully fill" "atPlacement=$ICP_P afterRelease=$ICP1"; fi

# ── 2. FOK market buy 2000 ICP (exceeds ~500 depth) → KILLED on GEPTOR ──
echo ""
echo "── 2. FOK market buy 2000 ICP (> available depth) → KILLED (refunded, nothing fills) ──"
ICP_B=$(bal "$UA" ICP); USD_B=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 2000.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
freshrequote
ICP2=$(bal "$UA" ICP); USD2=$(bal "$UA" ICPUSD)
if awk -v a="$ICP_B" -v b="$ICP2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_B" -v b="$USD2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "killed: ICP unchanged (${ICP2}≈$ICP_B), ICPUSD refunded (${USD2}≈$USD_B)"
else nok "FOK beyond depth should kill + refund (nothing fills)" "icp ${ICP_B}→$ICP2, usd ${USD_B}→$USD2"; fi
# (${var}→ braces above and below: macOS bash 3.2 under a UTF-8 locale swallows the
# multibyte glyph into the variable name and `set -u` kills the script.)

# ── 4 (#48.4). FOK vs an UNDER-FUNDED maker: gate must count the maker the
# engine's way. Maker A rests SELL 600 @10.30 but is then drained to 300 ICP
# (resting orders hold no reservation — by design); maker B rests SELL 300
# @10.40, fully funded. The release engine CANCELS an under-funded maker and
# takes ZERO from it (never its funded partial), so takeable depth within a
# 5% cap is AMM(~500) + A(0) + B(300) ≈ 800 — a FOK buy of 1000 must KILL.
# Pre-fix, the gate credited A its funded partial (300): depth read ~1100,
# the gate passed, and the "fill-or-kill" order 80%-filled.
echo ""
echo "── 4. FOK vs under-funded maker → KILL, not partial fill (#48.4) ──"
mdx_identity_new amm_mA; MA=$(principal_of amm_mA); mdx_identity_new amm_mB; MB=$(principal_of amm_mB)
ma() { icp canister call --candid "$MDX_CANDID" --identity amm_mA backend "$@" 2>&1; }
mb() { icp canister call --candid "$MDX_CANDID" --identity amm_mB backend "$@" 2>&1; }
# Maker A: fund 600, rest SELL 600 @ 10.30, then drain to 300 (under-funded).
adm setTestBalance "(principal \"$MA\", \"ICP\", $(e8 600.0) : nat)" >/dev/null
ma placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.30) : nat, $(e8 600.0) : nat)" >/dev/null
freshrequote   # release A's staged limit → rests on the book
adm setTestBalance "(principal \"$MA\", \"ICP\", $(e8 300.0) : nat)" >/dev/null
# Maker B: fund 300, rest SELL 300 @ 10.40 (fully funded).
adm setTestBalance "(principal \"$MB\", \"ICP\", $(e8 300.0) : nat)" >/dev/null
mb placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.40) : nat, $(e8 300.0) : nat)" >/dev/null
freshrequote   # release B's staged limit → rests on the book
# Engine-consistent takeable depth at the taker's cap: A must count ZERO.
TKD=$(adm getTakeableDepth "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.50):nat)" | tr -d '_' | grep -oE "[0-9]+" | head -1)
TKD_H=$(from_e8 "${TKD:-0}")
if awk -v t="$TKD_H" 'BEGIN{exit (t>750 && t<850?0:1)}'; then
  ok "takeable depth counts the under-funded maker as ZERO (${TKD_H} ≈ 800)"
else nok "takeable depth must be ~800 (AMM 500 + A 0 + B 300)" "got $TKD_H (1100 = A's funded partial credited — the #48.4 bug)"; fi
# FOK taker buy 1000 (> 800 truly takeable, < 1100 partial-credited) must KILL.
ICP_F=$(bal "$UA" ICP); USD_F=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 1000.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
freshrequote
ICP_F2=$(bal "$UA" ICP); USD_F2=$(bal "$UA" ICPUSD)
if awk -v a="$ICP_F" -v b="$ICP_F2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_F" -v b="$USD_F2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "killed: ICP unchanged (${ICP_F2}≈$ICP_F), ICPUSD refunded (${USD_F2}≈$USD_F)"
else nok "FOK past an under-funded maker must KILL (engine takes 0 from it)" "icp ${ICP_F}→$ICP_F2, usd ${USD_F}→$USD_F2 (a partial fill IS the #48.4 bug)"; fi
# §2's kill already logged one "Fill-or-kill" rejection for UA — §4's must be a SECOND.
RJ4=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
if [ "${RJ4:-0}" -ge 2 ]; then
  ok "kill recorded in getMyReleaseRejections (\"Fill-or-kill ... killed at release\")"
else nok "kill must be recorded, never silent" "expected a 2nd Fill-or-kill rejection, count=$RJ4"; fi
# Clean the §4 book so it can't lean on anything after us.
ma cancelAllMyOrders "(opt \"ICP-ICPUSD\")" >/dev/null 2>&1
mb cancelAllMyOrders "(opt \"ICP-ICPUSD\")" >/dev/null 2>&1

# ── 5. Conservation ── (§4's kill moves nothing; its makers are set-external
# and only touched via setTestBalance + a no-fill book, so the set still closes)
echo ""
echo "── 5. Conservation (UA + AMM) ──"
USD_NOW=$(awk -v a="$(bal "$UA" ICPUSD)" -v b="$(bal "$AMM" ICPUSD)" -v s="$(bal "$S" ICPUSD)" -v t="$(treas)" 'BEGIN{printf "%.4f", a+b+s+t}')
ICP_NOW=$(awk -v a="$(bal "$UA" ICP)" -v b="$(bal "$AMM" ICP)" -v s="$(bal "$S" ICP)" 'BEGIN{printf "%.4f", a+b+s}')
if awk -v a="$USD_NOW" -v b="$USD_BASE" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.02?0:1)}' \
   && awk -v a="$ICP_NOW" -v b="$ICP_BASE" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.02?0:1)}'; then
  ok "ICPUSD conserved (${USD_NOW}≈$USD_BASE), ICP conserved (${ICP_NOW}≈$ICP_BASE)"
else nok "value leak" "USD $USD_NOW vs $USD_BASE ; ICP $ICP_NOW vs $ICP_BASE"; fi

# ═══ #48.5: the FOK gate's remaining divergences from release execution ═══
# The gate (fokFillableDepth) must simulate EXACTLY what the engine will do:
# it now threads the release ctx's exclusions (isNonTakeable / isExpired /
# the beneficial-owner self-trade skip) into the walk, gates at effLimit,
# and a #partial initial-margin clamp KILLS a FOK instead of releasing the
# reduced size. §7-§9 exercise the three reachable shapes. NOTE on the
# brief's "users-only fallback" worst case (gate counts the AMM ladder, the
# users-only engine skips the AMM): that path is UNREACHABLE for FOK — the
# oracle-stall expiry pass (processDeferredExpiry) kills every FOK outright
# before releaseDeferred, so no fixture can red it; the exclusion threading
# still covers it by construction (same ctx.isNonTakeable, same walk).
# (§7-§9 sit AFTER the §5 conservation check on purpose: they mint balances
# with setTestBalance, which would break the closed set. §6 stays LAST.)

# ── 7 (#48.5). FOK vs an EXPIRED maker: the engine skips it, so must the gate ──
# Maker ME rests SELL 600 @ 10.30 (fully funded), then its order is force-
# expired (setTestOrderExpiry — still ON the book until swept; the engine's
# ctx.isExpired skips it at match time). Truly takeable within a 5% cap is
# the AMM ladder only (~500), so a FOK buy of 1000 must KILL. Pre-fix the
# gate was blind to expiry: depth read ~1100, the gate passed, and the
# fill-or-kill order 50%-filled off the AMM.
echo ""
echo "── 7. FOK vs expired maker → KILL, not partial fill (#48.5) ──"
mdx_identity_new amm_mE; ME=$(principal_of amm_mE)
me() { icp canister call --candid "$MDX_CANDID" --identity amm_mE backend "$@" 2>&1; }
adm setTestBalance "(principal \"$ME\", \"ICP\", $(e8 600.0) : nat)" >/dev/null
me placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.30) : nat, $(e8 600.0) : nat)" >/dev/null
freshrequote   # release ME's staged limit → rests on the book
ME_OID=$(me getMyOrders '()' --query | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+")
if [ -n "${ME_OID:-}" ]; then
  ok "setup: maker order resting (id $ME_OID)"
else nok "setup: maker order must rest" "no order id found"; fi
adm setTestOrderExpiry "(${ME_OID:-0} : nat, 1 : int)" >/dev/null   # expired long ago
ICP_E=$(bal "$UA" ICP); USD_E=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 1000.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
freshrequote
ICP_E2=$(bal "$UA" ICP); USD_E2=$(bal "$UA" ICPUSD)
if awk -v a="$ICP_E" -v b="$ICP_E2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_E" -v b="$USD_E2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "killed: ICP unchanged (${ICP_E2}≈$ICP_E), ICPUSD refunded (${USD_E2}≈$USD_E)"
else nok "FOK past an expired maker must KILL (engine skips it)" "icp ${ICP_E}→$ICP_E2, usd ${USD_E}→$USD_E2 (a partial fill IS the #48.5 exclusion-blindness bug)"; fi
RJ7=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
if [ "${RJ7:-0}" -ge 3 ]; then
  ok "kill recorded in getMyReleaseRejections (3rd Fill-or-kill rejection)"
else nok "kill must be recorded, never silent" "expected a 3rd Fill-or-kill rejection, count=$RJ7"; fi
adm adminSweepExpiredOrders '()' >/dev/null 2>&1   # clean §7's expired order off the book

# ── 8 (#48.5). FOK vs the taker's OWN resting order: self-trade never counts ──
# UA rests SELL 300 @ 10.20, then places a FOK buy of 700 within a 5% cap.
# The engine NEVER fills a taker against its own order (it cancels the self-
# maker and walks on), so truly takeable is the AMM ~500 → must KILL, and
# UA's resting order must SURVIVE. Pre-fix the gate counted UA's own 300
# (depth ~800 ≥ 700), passed, the engine cancelled UA's resting order as a
# self-trade and 5/7-filled the "fill-or-kill" off the AMM.
echo ""
echo "── 8. FOK vs the taker's own resting order → KILL, order survives (#48.5) ──"
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 300.0) : nat)" >/dev/null
u placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 10.20) : nat, $(e8 300.0) : nat)" >/dev/null
freshrequote   # release UA's staged limit → rests on the book
OPEN_S1=$(u getMyOrders '()' --query | tr -d '_' | grep -oE "id = [0-9]+" | grep -c . || true)
ICP_S=$(bal "$UA" ICP); USD_S=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 700.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
freshrequote
ICP_S2=$(bal "$UA" ICP); USD_S2=$(bal "$UA" ICPUSD)
OPEN_S2=$(u getMyOrders '()' --query | tr -d '_' | grep -oE "id = [0-9]+" | grep -c . || true)
if awk -v a="$ICP_S" -v b="$ICP_S2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_S" -v b="$USD_S2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "killed: ICP unchanged (${ICP_S2}≈$ICP_S), ICPUSD refunded (${USD_S2}≈$USD_S)"
else nok "FOK past the taker's own order must KILL (engine self-trade-skips it)" "icp ${ICP_S}→$ICP_S2, usd ${USD_S}→$USD_S2"; fi
if [ "${OPEN_S1:-0}" -ge 1 ] && [ "${OPEN_S1:-0}" = "${OPEN_S2:-0}" ]; then
  ok "UA's resting order SURVIVED the kill (open orders: ${OPEN_S2:-0})"
else nok "the kill must not cancel the taker's resting order (pre-fix the engine's self-trade cancel ate it)" "open ${OPEN_S1:-0} → ${OPEN_S2:-0}"; fi
u cancelAllMyOrders "(opt \"ICP-ICPUSD\")" >/dev/null 2>&1   # clean §8's book

# ── 9 (#48.5). FOK whose initial-margin clamp is #partial must KILL ──
# No live placement can stage a FOK for a margin-account principal (pools
# park with fok=false; every noPartialFill caller is a wallet), so the
# invariant is exercised via the #dev hook setTestDeferredFok. Recipe: pool
# shorts 100 ICP at ~10 (borrowed base), the mark pumps to 12.5 so health
# lands in the 1.15-1.25 band (headroom < 0, above liquidation), then a BUY
# of 110 stages — clampToInitialMargin returns #partial(100): the de-lever
# escape frees the flattening 100, the re-levering 10 excess is refused.
# Marked FOK, the release must KILL (all-or-nothing), never fill the 100.
# Pre-fix it released the clamped 100 and flattened the short.
echo ""
echo "── 9. FOK + #partial margin clamp → KILL, not a reduced release (#48.5) ──"
mdx_identity_new amm_uM; UM=$(principal_of amm_uM)
um() { icp canister call --candid "$MDX_CANDID" --identity amm_uM backend "$@" 2>&1; }
adm setTestBalance "(principal \"$UM\", \"ICPUSD\", $(e8 500.0) : nat)" >/dev/null
freshrequote   # pin the mark back to 10.0 for a deterministic entry
PID9=$(um createMarginPool '("fok95", false)' | tr -d '_' | grep -oE "[0-9]+" | head -1)
um fundMarginPool "(${PID9:-0} : nat, $(e8 500.0) : nat)" >/dev/null
R9=$(um openPosition "(${PID9:-0} : nat, \"ICP-ICPUSD\", variant { sell }, $(e8 100.0) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$R9"; then
  ok "setup: short 100 ICP staged (borrowed base)"
else nok "setup: short open should stage" "$R9"; fi
freshrequote   # release → short fills against the AMM bids at ~10
SZ1=$(um getMyPositions '()' --query | tr -d '_' | grep -oE "size = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+$")
# Derived size carries a few base units of fill-derivation dust — range, not exact.
if awk -v s="${SZ1:-0}" 'BEGIN{exit (s<=-9999000000 && s>=-10001000000 ?0:1)}'; then
  ok "setup: position is short ~100 ICP (size = $SZ1)"
else nok "setup: short must have filled" "size=${SZ1:-none}"; fi
# Pump the mark 25%: the short's debt outgrows the 1.25 initial floor
# (headroom < 0) while health stays above the 1.15 liquidation line.
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 12.5) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
R9B=$(um openPosition "(${PID9:-0} : nat, \"ICP-ICPUSD\", variant { buy }, $(e8 110.0) : nat, $(e8 0.05) : nat, null)")
if mdx_ok "$R9B"; then
  ok "setup: buy 110 staged (crosses through flat — 100 de-lever + 10 re-lever)"
else nok "setup: buy should stage without a borrow" "$R9B"; fi
DID9=$(um getPoolOrders "(${PID9:-0} : nat)" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+")
adm setTestDeferredFok "(${DID9:-0} : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 12.5) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null   # fresh price postdates the entry → releases
SZ2=$(um getMyPositions '()' --query | tr -d '_' | grep -oE "size = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+$")
# Derived size accrues sub-unit borrow-interest dust between reads; the signal
# is categorical — still short ~100 (killed) vs ~flat (the clamped 100 released).
if awk -v s="${SZ2:-0}" 'BEGIN{exit (s<=-9999000000 && s>=-10001000000 ?0:1)}'; then
  ok "killed: position UNCHANGED at short ~100 (size = $SZ2)"
else nok "a FOK whose margin clamp is #partial must KILL, not release the clamped size" "size ${SZ1:-?} → ${SZ2:-?} (a flattened/reduced short IS the #48.5 margin-clamp bug)"; fi
RJ9=$(um getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
if [ "${RJ9:-0}" -ge 1 ]; then
  ok "kill recorded in getMyReleaseRejections (Fill-or-kill ... initial-margin)"
else nok "the margin-clamp FOK kill must be recorded, never silent" "no Fill-or-kill rejection for the pool owner"; fi

# ═══ H-09 (F4 · F35): the FOK gate counts every maker it passes and fails
# closed. The engine spends one of MAX_MATCH_ITERATIONS_PER_CALL (256) per
# maker it TOUCHES — fills, skips and unfunded cancels alike — so a gate that
# compares depth only passes orders the engine cannot complete in one call:
# >256 small funded makers (the taker gets 256 slices, then the call caps out)
# or ~250 unfunded dust makers AHEAD of real depth (the engine burns its
# budget cancelling dust and fills only the leftover iterations). Both are
# partial fills on a fill-or-kill order. The gate now carries the engine's
# iteration budget and KILLS when it hits it before reaching d.qty.
#
# bulk_rest <identity> <count> <price>...: rest <count> 2-ICP asks for the
# identity, round-robin over the prices, 32 per placeLimitOrdersBulk call
# (the staged cap per owner), releasing each batch with a fresh requote.
# (2 ICP: a 1-ICP ask at ≤10.00 sits under the 10 ICPUSD min-notional gate.)
bulk_rest() {
  local who=$1 n=$2; shift 2; local prices=("$@"); local placed=0 k pr items
  while [ "$placed" -lt "$n" ]; do
    items=""; k=0
    while [ "$k" -lt 32 ] && [ "$placed" -lt "$n" ]; do
      pr=${prices[$(( placed % ${#prices[@]} ))]}
      items="$items record { marketId = \"ICP-ICPUSD\"; side = variant { sell }; price = $(e8 "$pr") : nat; quantity = $(e8 2.0) : nat; expiresInSec = null; postOnly = false };"
      k=$((k+1)); placed=$((placed+1))
    done
    icp canister call --candid "$MDX_CANDID" --identity "$who" backend placeLimitOrdersBulk "(vec { ${items%;} })" >/dev/null 2>&1
    freshrequote   # release the batch → rests on the book
  done
}
resting_count() { icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyOrders '()' --query 2>&1 | grep -oE "[{ ]id = [0-9]" | wc -l | tr -d ' '; }   # icp prints big vecs on ONE line: count matches, not lines
cancel_all_of() { # cancel_all_of <identity> — loop until the owner's book is empty
  local i=0
  while [ "$i" -lt 6 ] && [ "$(resting_count "$1")" -gt 0 ]; do
    icp canister call --candid "$MDX_CANDID" --identity "$1" backend cancelAllMyOrders "(opt \"ICP-ICPUSD\")" >/dev/null 2>&1; i=$((i+1))
  done
}
adm setTestOrderCap "(opt (2000 : nat))" >/dev/null 2>&1   # the fixtures rest >100 orders per owner

# ── 10 (H-09/F35). FOK over >256 small FUNDED makers → KILL (engine cap) ──
# Maker MF rests 300 × 2 ICP asks at 9.99–10.01 (ahead of the AMM's ladder),
# fully funded. Depth-wise a FOK buy of 700 is coverable (600 + AMM ~500), but
# the engine can touch at most 256 makers in one call: it would fill 256
# slices (512 ICP) and cap out — a 73% fill on a fill-or-kill order. The
# gate must count makers and KILL.
echo ""
echo "── 10. FOK over >256 small funded makers → KILL, never a 256-slice partial (H-09) ──"
mdx_identity_new amm_mF; MF=$(principal_of amm_mF)
freshrequote   # §9 left the mark at 12.5 — pin 10.0 BEFORE resting asks at 9.99–10.01, or they cross the AMM bids and fill
adm setTestBalance "(principal \"$MF\", \"ICP\", $(e8 700.0) : nat)" >/dev/null
bulk_rest amm_mF 300 9.99 10.00 10.01
RC10=$(resting_count amm_mF)
if [ "${RC10:-0}" -ge 300 ]; then ok "fixture: $RC10 funded 2-ICP asks resting ahead of the AMM"; else nok "fixture: 300 asks must rest" "resting=$RC10"; fi
RJ10_0=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
ICP_T=$(bal "$UA" ICP); USD_T=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 700.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
freshrequote
ICP_T2=$(bal "$UA" ICP); USD_T2=$(bal "$UA" ICPUSD)
if awk -v a="$ICP_T" -v b="$ICP_T2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_T" -v b="$USD_T2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "killed: ICP unchanged (${ICP_T2}≈$ICP_T), ICPUSD refunded (${USD_T2}≈$USD_T)"
else nok "a FOK needing >256 makers must KILL (the engine caps at 256 iterations)" "icp ${ICP_T}→$ICP_T2, usd ${USD_T}→$USD_T2 (a 256-slice partial IS the F35 bug)"; fi
RJ10_1=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
if [ "${RJ10_1:-0}" -gt "${RJ10_0:-0}" ]; then
  ok "kill recorded in getMyReleaseRejections (Fill-or-kill count ${RJ10_0}→$RJ10_1)"
else nok "the maker-budget kill must be recorded, never silent" "Fill-or-kill count ${RJ10_0}→$RJ10_1"; fi
cancel_all_of amm_mF
RC10B=$(resting_count amm_mF)
[ "${RC10B:-0}" -eq 0 ] && ok "cleanup: MF's book cleared" || nok "cleanup: MF still has resting orders" "resting=$RC10B"

# ── 11 (H-09/F35). ~250 UNFUNDED dust makers ahead of sufficient AMM depth → KILL ──
# Maker MG rests 254 × 2 ICP asks at 9.99–10.01, then is drained to 0 (resting
# orders hold no reservation — by design). The AMM ladder behind them holds
# ~500. A FOK buy of 400: depth-only, the gate counts dust 0 + AMM 500 ≥ 400
# and PASSES; the engine then spends 254 iterations cancelling dust and has 2
# left for the AMM — a ~200-of-400 partial fill. The gate must count the dust
# it walks past and KILL at the budget.
echo ""
echo "── 11. FOK behind ~250 unfunded dust makers → KILL, not a leftover-iteration partial (H-09) ──"
mdx_identity_new amm_mG; MG=$(principal_of amm_mG)
adm setTestBalance "(principal \"$MG\", \"ICP\", $(e8 600.0) : nat)" >/dev/null
bulk_rest amm_mG 254 9.99 10.00 10.01
RC11=$(resting_count amm_mG)
if [ "${RC11:-0}" -ge 254 ]; then ok "fixture: $RC11 2-ICP asks resting ahead of the AMM"; else nok "fixture: 254 asks must rest" "resting=$RC11"; fi
adm setTestBalance "(principal \"$MG\", \"ICP\", 0 : nat)" >/dev/null   # drain → every MG ask is now unfunded dust
RJ11_0=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
ICP_D=$(bal "$UA" ICP); USD_D=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 400.0) : nat, $(e8 0.05) : nat, true)" >/dev/null
freshrequote
ICP_D2=$(bal "$UA" ICP); USD_D2=$(bal "$UA" ICPUSD)
if awk -v a="$ICP_D" -v b="$ICP_D2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_D" -v b="$USD_D2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "killed: ICP unchanged (${ICP_D2}≈$ICP_D), ICPUSD refunded (${USD_D2}≈$USD_D)"
else nok "a FOK behind ~250 unfunded makers must KILL (the engine burns its budget cancelling them)" "icp ${ICP_D}→$ICP_D2, usd ${USD_D}→$USD_D2 (a partial fill IS the F35 dust bug)"; fi
RJ11_1=$(u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true)
if [ "${RJ11_1:-0}" -gt "${RJ11_0:-0}" ]; then
  ok "kill recorded in getMyReleaseRejections (Fill-or-kill count ${RJ11_0}→$RJ11_1)"
else nok "the dust-budget kill must be recorded, never silent" "Fill-or-kill count ${RJ11_0}→$RJ11_1"; fi
cancel_all_of amm_mG
RC11B=$(resting_count amm_mG)
[ "${RC11B:-0}" -eq 0 ] && ok "cleanup: MG's book cleared" || nok "cleanup: MG still has resting orders" "resting=$RC11B"
adm setTestOrderCap "(null)" >/dev/null 2>&1

# ═══ 1788641149: a LEVERAGED POOL BID is takeable depth. H-34 (D5 option (d))
# made a margin pool borrow its slice AT THE FILL (poolFundForFill), so a
# resting pool entry with no cash behind it FILLS whenever the vault can lend —
# but every book-walking probe (the FOK gate's walkFillable, the engine's FOK
# pre-check simulateAvailableFill, getTakeableDepth, quoteSwap, the post-only
# probe) scored a maker by its available balance alone and counted such a bid
# as ZERO: a FOK sell whose only in-cap depth was a pool's leveraged bid was
# KILLED ("only 0 was takeable") although the live walk would have filled it.
# The probes now score a pool maker by its FUNDABLE balance — available + what
# the vault would lend it at this instant (BorrowEngine.maxBorrowable, for an
# exposure-increasing fill only, on the hook's own freshness gates) — and
# never borrow themselves; the live engine's fundForFill stays the only
# borrower.
#
# Fixture: the AMM's half-spread is widened to 400 bps so its bids (9.60) sit
# OUTSIDE a 1 % sell cap (floor 9.90) while its asks (10.40) stay clear of the
# pool's bid; pool UP ($2.5k own quote) rests a leveraged bid for 500 ICP @
# 9.95 ($4,975 + the 5 bps maker fee — ~$2,477 of it borrowed at the fill).
# That bid is the ONLY depth inside the cap. ($2.5k, not less: the release
# clamp scores a pool's re-levering excess as borrowed at the fill — equity ≥
# q × (R·price − ltv·mark) = q × 4.4375 at ICP's 0.8 LTV — so $2k would have
# clamped the bid to 450.7 ICP and the 500 FOK below would rightly kill.)
echo ""
echo "── 12. a leveraged pool bid IS takeable depth: getTakeableDepth, the FOK gate and the engine's pre-check score it by FUNDABLE balance (1788641149) ──"
mdx_identity_new amm_uP; UP=$(principal_of amm_uP)
up() { icp canister call --candid "$MDX_CANDID" --identity amm_uP backend "$@" 2>&1; }
pdebt()    { up getMyMarginPools '()' --query | tr -d '_' | grep -oE "debtUsd = [0-9]+" | head -1 | grep -oE "[0-9]+$"; }
vbal()     { adm getTestBalance "(principal \"$AMM\", \"ICPUSD\")" | tr -d '_' | grep -oE "[0-9]+" | head -1; }
tkd_sell() { adm getTakeableDepth "(\"ICP-ICPUSD\", variant { sell }, $(e8 9.90):nat)" --query | tr -d '_' | grep -oE "[0-9]+" | head -1; }
pool_orders() { up getPoolOrders "(${PID12:-0} : nat)" --query | grep -c "id ="; }
fok_count()   { u getMyReleaseRejections '()' --query | grep -oE "Fill-or-kill" | grep -c . || true; }
adm setAmmConfig "(\"ICP-ICPUSD\", 400:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
freshrequote   # the AMM re-ladders: bids at 9.60, asks at 10.40
TK0=$(tkd_sell)
if [ "${TK0:-x}" = "0" ]; then ok "fixture: no depth inside the 1% sell cap before the pool bids (the AMM's bids sit at 9.60)"; else nok "fixture: the AMM's bids must sit outside the 9.90 floor" "takeable=$(from_e8 "${TK0:-0}")"; fi
adm setTestBalance "(principal \"$UP\", \"ICPUSD\", $(e8 2500.0) : nat)" >/dev/null
PID12=$(up createMarginPool '("lev-bid", false)' | tr -d '_' | grep -oE "[0-9]+" | head -1)
up fundMarginPool "(${PID12:-0} : nat, $(e8 2500.0) : nat)" >/dev/null
R12=$(up openPosition "(${PID12:-0} : nat, \"ICP-ICPUSD\", variant { buy }, $(e8 500.0) : nat, $(e8 0.05) : nat, opt ($(e8 9.95) : nat))")
if mdx_ok "$R12"; then ok "fixture: leveraged #limit long 500 ICP @ 9.95 (\$4,975 on \$2.5k own quote) staged"; else nok "fixture: openPosition #limit" "$R12"; fi
freshrequote   # releases → 9.95 sits under the AMM's asks → RESTS as the pool's bid, debt 0
PO12=$(pool_orders); D12_0=$(pdebt); V12_0=$(vbal)
PQ12=$(up getPoolOrders "(${PID12:-0} : nat)" --query | tr -d '_' | grep -oE "quantity = [0-9]+" | head -1 | grep -oE "[0-9]+$")
if [ "${PO12:-0}" = "1" ] && [ "${D12_0:-x}" = "0" ] && [ "${PQ12:-0}" = "$(e8 500.0)" ]; then ok "fixture: the pool's bid RESTS whole (500 ICP, un-clamped) with debt exactly 0 (H-34: nothing is borrowed until the fill)"; else nok "fixture: a whole resting pool bid with zero debt" "orders=$PO12 quantity=${PQ12:-none} debt=$D12_0"; fi
# The PROBE: getTakeableDepth must report the pool's 500 — scored by what the
# vault would lend it, not by its cash.
TK1=$(tkd_sell)
if awk -v t="$(from_e8 "${TK1:-0}")" 'BEGIN{exit (t>499.99 && t<500.01?0:1)}'; then
  ok "getTakeableDepth(sell, 9.90) reports the pool's leveraged bid: $(from_e8 "${TK1:-0}") = 500 (pre-fix: 0 — scored by cash alone)"
else nok "getTakeableDepth must count the leveraged pool bid by its FUNDABLE balance" "got $(from_e8 "${TK1:-0}") (0 = the pre-fix cash-only score)"; fi
D12_1=$(pdebt); V12_1=$(vbal)
if [ "${D12_1:-x}" = "0" ] && [ "${V12_1:-x}" = "${V12_0:-y}" ]; then ok "the probe never borrows: pool debt still 0 and the vault unmoved after the depth query"; else nok "a probe must not borrow" "debt ${D12_0}→$D12_1 vault ${V12_0}→$V12_1"; fi
# CONTROL: the vault DRY → the probe follows the vault exactly as the hook
# does: depth 0, the FOK sell is KILLED, the pool's bid survives, and the gate
# (an UPDATE-context probe) borrowed nothing.
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", 0 : nat)" >/dev/null   # nothing to lend: borrow cap 0.5 × 0
TK2=$(tkd_sell)
if [ "${TK2:-x}" = "0" ]; then ok "control: vault drained → getTakeableDepth reports 0 (\$2.5k of cash cannot fund a \$4,977 slice and there is nothing to borrow)"; else nok "control: a dry vault must zero the pool's fundable depth" "takeable=$(from_e8 "${TK2:-0}")"; fi
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 500.0) : nat)" >/dev/null
RJ12_0=$(fok_count)
ICP_L=$(bal "$UA" ICP); USD_L=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 500.0) : nat, $(e8 0.01) : nat, true)" >/dev/null
freshrequote
ICP_L2=$(bal "$UA" ICP); USD_L2=$(bal "$UA" ICPUSD); RJ12_1=$(fok_count)
if awk -v a="$ICP_L" -v b="$ICP_L2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_L" -v b="$USD_L2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}' && [ "${RJ12_1:-0}" -gt "${RJ12_0:-0}" ]; then
  ok "control: FOK sell 500 KILLED with a record while the vault is dry (ICP ${ICP_L2}≈$ICP_L; Fill-or-kill ${RJ12_0}→$RJ12_1) — the live hook would have refused the borrow too"
else nok "control: a dry vault must kill the FOK (the probe must follow the vault)" "icp ${ICP_L}→$ICP_L2, usd ${USD_L}→$USD_L2, rejections ${RJ12_0}→$RJ12_1"; fi
PO12b=$(pool_orders); D12_2=$(pdebt)
if [ "${PO12b:-0}" = "1" ] && [ "${D12_2:-x}" = "0" ]; then ok "control: the pool's bid survives the kill and its debt is still 0 (the gate probed it in an update and borrowed nothing)"; else nok "control: the kill must leave the pool bid resting, debt-free" "orders=$PO12b debt=$D12_2"; fi
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", ${V12_0:-0} : nat)" >/dev/null   # the vault can lend again
# The FILL: the FOK sell 500 must FILL against the pool's bid ALONE — the gate
# and the pre-check pass on the fundable score, and the pool borrows exactly
# its shortfall AT the fill (the only borrow in this section).
RJ12_2=$(fok_count)
ICP_M=$(bal "$UA" ICP); USD_M=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 500.0) : nat, $(e8 0.01) : nat, true)" >/dev/null
freshrequote
ICP_M2=$(bal "$UA" ICP); USD_M2=$(bal "$UA" ICPUSD); RJ12_3=$(fok_count)
# proceeds 500 × 9.95 = $4,975 − the 10 bps taker fee ($4.975) = $4,970.025
if awk -v a="$ICP_M" -v b="$ICP_M2" 'BEGIN{d=a-b; exit (d>499.99 && d<500.01?0:1)}' \
   && awk -v a="$USD_M" -v b="$USD_M2" 'BEGIN{d=b-a; exit (d>4969 && d<4971?0:1)}'; then
  ok "FOK sell 500 FILLED against the leveraged pool bid alone (ICP ${ICP_M}→$ICP_M2, ICPUSD +$(awk -v a="$USD_M" -v b="$USD_M2" 'BEGIN{printf "%.2f", b-a}')) — pre-fix: killed 'only 0 was takeable'"
else nok "a FOK whose only in-cap depth is a leveraged pool bid must FILL (the live walk funds it at the fill)" "icp ${ICP_M}→$ICP_M2, usd ${USD_M}→$USD_M2 (unchanged = the pre-fix kill)"; fi
if [ "${RJ12_3:-0}" = "${RJ12_2:-0}" ]; then ok "no kill recorded for the fill (Fill-or-kill count unchanged at $RJ12_3)"; else nok "the fill must not record a kill" "Fill-or-kill ${RJ12_2}→$RJ12_3"; fi
D12_3=$(pdebt); PO12c=$(pool_orders)
# the fill borrowed cost + maker fee − own quote = 4,975 + 2.4875 − 2,500 = $2,477.49 (± interest dust)
if [ -n "${D12_3:-}" ] && [ "$D12_3" -ge "$(e8 2477.0)" ] && [ "$D12_3" -le "$(e8 2478.5)" ]; then ok "the FILL borrowed exactly the pool's shortfall (debt \$$(from_e8 "$D12_3") ≈ \$2,477.49) — the engine's hook is the only borrower"; else nok "the fill should borrow cost + maker fee − own quote at the fill" "debtUsd=${D12_3:-none}"; fi
SZ12=$(up getMyPositions '()' --query | tr -d '_' | grep -oE "size = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+$")
if [ "${PO12c:-1}" = "0" ] && awk -v s="${SZ12:-0}" 'BEGIN{exit (s>=49999000000 && s<=50001000000?0:1)}'; then ok "the pool's bid is consumed (no pool order left) and its position is long ~500 ICP (size = $SZ12)"; else nok "the pool should now hold the long and no resting order" "orders=$PO12c size=${SZ12:-none}"; fi
TK3=$(tkd_sell)
if [ "${TK3:-x}" = "0" ]; then ok "getTakeableDepth(sell, 9.90) is 0 again with the bid gone (the depth WAS the pool's bid)"; else nok "no depth should remain inside the cap" "takeable=$(from_e8 "${TK3:-0}")"; fi
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null   # restore the suite's ladder
freshrequote

# ═══ 1788652744: ONE pool, TWO leveraged bids — the probe re-scores the pool's
# room per SLICE "as if settled". 1788641149 scored a pool maker by the closed
# form a ≤ (C − R·D)/(R − ltv) at CURRENT marks, memoised at its first slice
# and drawn down like cash. The live hook borrows per SLICE, and each settled
# slice turns quote (LTV 1.0) into base valued at ITS LTV (ICP 0.8), so the
# pool's health after slice 1 is worse than the closed form assumed and slice
# 2's borrowCheck refuses where the probe credited it: a FOK spanning two
# entries of the same pool passed the gate, filled the first, had the second
# REFUSED (the pool's bid cancelled with the vault notice) and ended PARTIALLY
# filled — the #48.4 shape, narrowly. The probes now carry a per-pool
# (collateralUsd, debtUsd, net) ledger through the walk and recompute the room
# per slice from the settled state (MatchingEngine.FundableScorer /
# poolFundableScorer), so the gate agrees with what the fill-time borrowCheck
# will decide — still read-only, still never a borrower.
#
# Fixture (ICP LTV 0.8, R 1.25, mark 10, 5 bps maker fee): pool UQ holds
# $2.5k own quote and rests 500 @ 9.96 then 500 @ 9.95. Placement admits both
# (each alone borrows ≤ 4 × equity; the release clamp allows 561/563 each),
# and the CLOSED FORM admits both at once: fundable = 2,500 + 4 × 2,500 =
# $12,500 ≥ 4,982.49 + 4,977.49. As SETTLED: slice 1 borrows 2,482.49 and
# leaves collateral 500 × 10 × 0.8 = $4,000 against debt $2,482.49, so slice
# 2's room is (4,000 − 1.25 × 2,482.49) ÷ 0.25 = $3,587.5 < $4,977.49 — the
# second bid is NOT fully fundable (health after it would be 1.204 < 1.25).
# ~$7.5k borrowed across the two = 3 × own quote.
echo ""
echo "── 13. one pool, two leveraged bids: the probe re-scores the room per slice — a FOK spanning both KILLS, one sized to the settled room FILLS (1788652744) ──"
mdx_identity_new amm_uQ; UQ=$(principal_of amm_uQ)
uq() { icp canister call --candid "$MDX_CANDID" --identity amm_uQ backend "$@" 2>&1; }
qdebt()   { uq getMyMarginPools '()' --query | tr -d '_' | grep -oE "debtUsd = [0-9]+" | head -1 | grep -oE "[0-9]+$"; }
q_orders() { uq getPoolOrders "(${PID13:-0} : nat)" --query | grep -c "id ="; }
q_vault_notices() { uq getMyReleaseRejections '()' --query | grep -oE "vault could not lend" | grep -c . || true; }
adm setAmmConfig "(\"ICP-ICPUSD\", 400:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
freshrequote   # bids at 9.60 (outside the 9.90 floor), asks at 10.40 (clear of the pool's bids)
TQ0=$(tkd_sell)
if [ "${TQ0:-x}" = "0" ]; then ok "fixture: no depth inside the 1% sell cap before the pool bids"; else nok "fixture: the AMM's bids must sit outside the 9.90 floor" "takeable=$(from_e8 "${TQ0:-0}")"; fi
adm setTestBalance "(principal \"$UQ\", \"ICPUSD\", $(e8 2500.0) : nat)" >/dev/null
PID13=$(uq createMarginPool '("two-bids", false)' | tr -d '_' | grep -oE "[0-9]+" | head -1)
uq fundMarginPool "(${PID13:-0} : nat, $(e8 2500.0) : nat)" >/dev/null
R13a=$(uq openPosition "(${PID13:-0} : nat, \"ICP-ICPUSD\", variant { buy }, $(e8 500.0) : nat, $(e8 0.05) : nat, opt ($(e8 9.96) : nat))")
R13b=$(uq openPosition "(${PID13:-0} : nat, \"ICP-ICPUSD\", variant { buy }, $(e8 500.0) : nat, $(e8 0.05) : nat, opt ($(e8 9.95) : nat))")
if mdx_ok "$R13a" && mdx_ok "$R13b"; then ok "fixture: two leveraged #limit longs staged (500 @ 9.96, 500 @ 9.95 on \$2.5k own quote — placement admits each alone)"; else nok "fixture: openPosition ×2" "a=$(echo "$R13a" | head -c 160) b=$(echo "$R13b" | head -c 160)"; fi
freshrequote   # both release under the AMM's asks → REST as the pool's bids, debt 0
QO0=$(q_orders); QD0=$(qdebt); QV0=$(vbal)
if [ "${QO0:-0}" = "2" ] && [ "${QD0:-x}" = "0" ]; then ok "fixture: both bids REST whole (2 pool orders) with debt exactly 0 (nothing is borrowed until a fill)"; else nok "fixture: two whole resting pool bids with zero debt" "orders=$QO0 debt=$QD0"; fi
# The PROBE: all-or-nothing depth is the FIRST bid alone — the second cannot be
# funded in full once the first has settled (the closed form counted both).
TQ1=$(tkd_sell)
if awk -v t="$(from_e8 "${TQ1:-0}")" 'BEGIN{exit (t>499.99 && t<500.01?0:1)}'; then
  ok "getTakeableDepth(sell, 9.90) = $(from_e8 "${TQ1:-0}") — exactly the first bid; the second is not fundable in full after slice 1 settles (pre-fix: 1000, the closed form at current marks)"
else nok "getTakeableDepth must re-score the pool's room per slice: first bid only" "got $(from_e8 "${TQ1:-0}") (1000 = the pre-fix closed form; 500 expected)"; fi
# quoteSwap walks the SAME all-or-nothing scoring as the gate (1788660963):
# a maker is credited iff it can fund the slice the engine would size for it
# — min(taker remaining, order remaining) — else ZERO, because the live loop
# CANCELS an under-funded maker and takes nothing (there is no engine path
# that fills "whatever the maker can honour"). Slice 1 spends 4,980 + its
# 5 bps maker fee = $4,982.49 (borrowing $2,482.49), so slice 2's settled room
# is (4,000 − 1.25 × 2,482.49) ÷ 0.25 = $3,587.55: a 1,000 sell asks the
# second bid for its FULL 500 (needs $4,977.49) → not fundable → 500 total,
# exhausted; an 800 sell asks it for 300 (needs $2,986.49 ≤ the room) → both
# slices count → 800, not exhausted — exactly the two FOK outcomes below.
# History of this number: pre-1788652744 1000 (closed form at current marks);
# fee-blind #fundedPartial 861.81; fee-inclusive #fundedPartial 860.38 — the
# retired mode credited a PART (360.38 ICP) the engine's cancel never delivers.
QS=$(uq quoteSwap "(\"ICP\", \"ICPUSD\", $(e8 1000.0) : nat, $(e8 0.01) : nat)" --query | tr -d '_\n' | tr -s ' ')
QS_C=$(echo "$QS" | grep -oE "consumedFrom = [0-9]+" | grep -oE "[0-9]+$")
if echo "$QS" | grep -q "exhausted = true" && [ "${QS_C:-0}" = "$(e8 500.0)" ]; then
  ok "quoteSwap(sell 1000 ICP) consumes exactly 500, exhausted: the first bid alone — the second cannot fund the full 500 the engine would size for it (#fundedPartial credited 860.38: a part the fill cancels outright)"
else nok "quoteSwap must score the second bid all-or-nothing on the engine's fillQty (500 total, exhausted; 860.38 = the retired #fundedPartial part)" "consumedFrom=$(from_e8 "${QS_C:-0}") $(echo "$QS" | head -c 200)"; fi
QS8=$(uq quoteSwap "(\"ICP\", \"ICPUSD\", $(e8 800.0) : nat, $(e8 0.01) : nat)" --query | tr -d '_\n' | tr -s ' ')
QS8_C=$(echo "$QS8" | grep -oE "consumedFrom = [0-9]+" | grep -oE "[0-9]+$")
if echo "$QS8" | grep -q "exhausted = false" && [ "${QS8_C:-0}" = "$(e8 800.0)" ]; then
  ok "quoteSwap(sell 800 ICP) consumes all 800, not exhausted: the taker's REMAINING 300 is within the second bid's settled room, so the slice the engine would size is fundable and counts in full (the FOK-800 fill below is the engine's word)"
else nok "a maker funded for the taker's remaining slice must count fully (800 of 800)" "consumedFrom=$(from_e8 "${QS8_C:-0}") $(echo "$QS8" | head -c 200)"; fi
QD1=$(qdebt); QV1=$(vbal)
if [ "${QD1:-x}" = "0" ] && [ "${QV1:-x}" = "${QV0:-y}" ]; then ok "the probes never borrow: pool debt still 0 and the vault unmoved"; else nok "a probe must not borrow" "debt ${QD0}→$QD1 vault ${QV0}→$QV1"; fi
# A FOK sell spanning BOTH bids must KILL — not fill the first and have the
# second refused at the fill (pre-fix: ICP −500, one pool bid cancelled with
# the vault notice, debt ≈ $2,482 — a partial fill on an all-or-nothing order).
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 1000.0) : nat)" >/dev/null
RJ13_0=$(fok_count); QN0=$(q_vault_notices)
ICP_Q=$(bal "$UA" ICP); USD_Q=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 1000.0) : nat, $(e8 0.01) : nat, true)" >/dev/null
freshrequote
ICP_Q2=$(bal "$UA" ICP); USD_Q2=$(bal "$UA" ICPUSD); RJ13_1=$(fok_count)
if awk -v a="$ICP_Q" -v b="$ICP_Q2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0001?0:1)}' \
   && awk -v a="$USD_Q" -v b="$USD_Q2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}' && [ "${RJ13_1:-0}" -gt "${RJ13_0:-0}" ]; then
  ok "FOK sell 1000 spanning both bids KILLED with a record, nothing settled (ICP ${ICP_Q2}≈$ICP_Q; Fill-or-kill ${RJ13_0}→$RJ13_1)"
else nok "a FOK spanning two entries the pool cannot fund in sequence must KILL, never partial-fill (#48.4)" "icp ${ICP_Q}→$ICP_Q2, usd ${USD_Q}→$USD_Q2, rejections ${RJ13_0}→$RJ13_1"; fi
QO1=$(q_orders); QD2=$(qdebt); QN1=$(q_vault_notices)
if [ "${QO1:-0}" = "2" ] && [ "${QD2:-x}" = "0" ] && [ "${QN1:-0}" = "${QN0:-0}" ]; then ok "both pool bids survive the kill, debt still 0, no vault notice for the pool (nothing of it was cancelled mid-match)"; else nok "the kill must leave both bids resting, debt-free, without a mid-match cancel" "orders=$QO1 debt=$QD2 vault-notices ${QN0}→$QN1"; fi
# A FOK sized to the SETTLED room fills BOTH slices: 500 off the first bid,
# 300 off the second (its borrow 300 × 9.95 × 1.0005 = $2,986.5 < the
# $3,587.5 room; health after that slice = 1.278). First-slice-only scoring
# (option (b)) would score the second slice by cash — zero — and wrongly
# kill this one too.
RJ13_2=$(fok_count)
ICP_P=$(bal "$UA" ICP); USD_P=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 800.0) : nat, $(e8 0.01) : nat, true)" >/dev/null
freshrequote
ICP_P2=$(bal "$UA" ICP); USD_P2=$(bal "$UA" ICPUSD); RJ13_3=$(fok_count)
# proceeds 500 × 9.96 + 300 × 9.95 = $7,965 − the 10 bps taker fee ($7.965) = $7,957.04
if awk -v a="$ICP_P" -v b="$ICP_P2" 'BEGIN{d=a-b; exit (d>799.99 && d<800.01?0:1)}' \
   && awk -v a="$USD_P" -v b="$USD_P2" 'BEGIN{d=b-a; exit (d>7956 && d<7958.5?0:1)}' && [ "${RJ13_3:-0}" = "${RJ13_2:-0}" ]; then
  ok "FOK sell 800 FILLED across both bids (ICP ${ICP_P}→$ICP_P2, ICPUSD +$(awk -v a="$USD_P" -v b="$USD_P2" 'BEGIN{printf "%.2f", b-a}'), no kill) — the second slice's room was re-scored from the settled first"
else nok "a FOK within the pool's settled room must FILL both slices (first-slice-only scoring would kill it)" "icp ${ICP_P}→$ICP_P2, usd ${USD_P}→$USD_P2, rejections ${RJ13_2}→$RJ13_3"; fi
QD3=$(qdebt); QO2=$(q_orders); QN2=$(q_vault_notices)
QF2=$(uq getMyReleaseRejections '()' --query | grep -oE "below the initial-margin floor" | grep -c . || true)
# borrowed at the fills: (4,982.49 − 2,500) + 2,986.49 = $5,468.98 (± interest
# dust). The settled pool (800 ICP × 10 × 0.8 = $6,400 against $5,469 of debt)
# sits at health 1.17 — BELOW the 1.25 initial floor, which is exactly why the
# 1,000 FOK could not fund its second slice — so the second bid's 200 ICP
# remainder is shed by the initial-margin floor sweep with ITS notice, not a
# mid-match vault refusal.
if [ -n "${QD3:-}" ] && [ "$QD3" -ge "$(e8 5467.0)" ] && [ "$QD3" -le "$(e8 5471.0)" ]; then ok "the fills borrowed each slice's shortfall (debt \$$(from_e8 "$QD3") ≈ \$5,468.98) — two per-slice borrows, the engine's hook the only borrower"; else nok "two per-slice borrows" "debtUsd=${QD3:-none}"; fi
if [ "${QO2:-1}" = "0" ] && [ "${QF2:-0}" = "1" ] && [ "${QN2:-0}" = "${QN0:-0}" ]; then ok "the second bid's remainder is shed by the initial-margin floor (health 1.17 < 1.25) with that notice — no mid-match vault refusal anywhere in this section"; else nok "the settled pool sits below the initial floor: its remainder is swept with the floor notice, never a vault refusal" "orders=$QO2 floor-notices=$QF2 vault-notices ${QN0}→$QN2"; fi
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null   # restore the suite's ladder
freshrequote

# ═══ 1788658533 / 1788660963: a WALLET bid funded for exactly its cost — no
# maker fee — is NO depth for a taker whose slice needs the whole bid. The
# engine's gate for a maker-buy slice is tradeCost + the maker's fee
# (MatchingEngine's makerNeeds); the live loop cancels a maker short of it with
# the mid-match notice and takes ZERO. walkFillable's retired #fundedPartial
# arm (quoteSwap, the cross-swap preview) credited such a maker its funded
# PART — first fee-blind (the whole bid), then fee-inclusive (1788658533:
# q × 10,000 ÷ 10,005 = 99.95 of 100 ICP) — a part NO engine path delivers:
# the fill cancels the maker outright. quoteSwap now walks the gate's
# all-or-nothing scoring (1788660963): a maker counts iff it can fund
# min(taker remaining, order remaining) — so the same cost-only bid is ZERO
# for a 100 ICP sell and counts IN FULL for a 50 ICP sell (the engine sizes
# fillQty = 50, needs $497.75 ≤ $995, and fills it).
echo ""
echo "── 14. a wallet bid funded for exactly cost (no maker fee): quoteSwap credits it ZERO for a slice it cannot fund, fully for one it can; the live fill cancels it with the notice (1788658533 / 1788660963) ──"
mdx_identity_new amm_uW; UW=$(principal_of amm_uW)
uw() { icp canister call --candid "$MDX_CANDID" --identity amm_uW backend "$@" 2>&1; }
w_notices() { uw getMyReleaseRejections '()' --query | tr -d '\n' | grep -oE "mid-match" | grep -c . || true; }
adm setAmmConfig "(\"ICP-ICPUSD\", 400:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
freshrequote   # bids at 9.60 (outside the 9.90 floor), asks at 10.40 (clear of the wallet's bid)
TW0=$(tkd_sell)
if [ "${TW0:-x}" = "0" ]; then ok "fixture: no depth inside the 1% sell cap before the wallet bids"; else nok "fixture: the AMM's bids must sit outside the 9.90 floor" "takeable=$(from_e8 "${TW0:-0}")"; fi
adm setTestBalance "(principal \"$UW\", \"ICPUSD\", $(e8 1500.0) : nat)" >/dev/null
uw placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.95) : nat, $(e8 100.0) : nat)" >/dev/null
freshrequote   # releases → 9.95 sits under the AMM's asks → RESTS as the wallet's bid
RCW=$(resting_count amm_uW)
if [ "${RCW:-0}" = "1" ]; then ok "fixture: the wallet's bid 100 ICP @ 9.95 rests (cost \$995.00; the engine's gate wants \$995.4975 — cost + the 5 bps maker fee)"; else nok "fixture: the wallet's bid must rest" "resting=$RCW"; fi
# Drain to EXACTLY cost (resting orders hold no reservation — by design).
adm setTestBalance "(principal \"$UW\", \"ICPUSD\", $(e8 995.0) : nat)" >/dev/null
QW=$(u quoteSwap "(\"ICP\", \"ICPUSD\", $(e8 100.0) : nat, $(e8 0.01) : nat)" --query | tr -d '_\n' | tr -s ' ')
QW_C=$(echo "$QW" | grep -oE "consumedFrom = [0-9]+" | grep -oE "[0-9]+$")
# the engine sizes fillQty = 100 for this taker and needs $995.4975 of the
# maker; $995 is short → cancel + zero. (#fundedPartial credited the part
# ⌊⌊995 × 10,000 ÷ 10,005⌋ ÷ 9.95⌋ = 99.95002498 ICP; fee-blind, all 100.)
if echo "$QW" | grep -q "exhausted = true" && [ "${QW_C:-x}" = "0" ]; then
  ok "quoteSwap(sell 100) credits the cost-only bid ZERO, exhausted — the engine cancels a maker short of cost + fee for the slice it sizes (retired #fundedPartial: 99.95; fee-blind: 100.00)"
else nok "a bid that cannot fund the taker's whole slice must be credited ZERO (the fill cancels it), never a part" "consumedFrom=$(from_e8 "${QW_C:-0}") $(echo "$QW" | head -c 200)"; fi
# The REMAINING-slice case: a 50 ICP sell sizes fillQty = 50 off the same
# bid (cost 497.50 + fee 0.24875 = $497.75 ≤ $995) — fundable, so the maker
# counts in full for THIS taker. All-or-nothing is per engine slice, not
# per resting order (fokFillableDepth's takerQty note).
QW5=$(u quoteSwap "(\"ICP\", \"ICPUSD\", $(e8 50.0) : nat, $(e8 0.01) : nat)" --query | tr -d '_\n' | tr -s ' ')
QW5_C=$(echo "$QW5" | grep -oE "consumedFrom = [0-9]+" | grep -oE "[0-9]+$")
if echo "$QW5" | grep -q "exhausted = false" && [ "${QW5_C:-0}" = "$(e8 50.0)" ]; then ok "quoteSwap(sell 50) against the same cost-only bid consumes all 50, not exhausted — the maker funds the taker's REMAINING slice, which is what the engine sizes"; else nok "a maker funded for the taker's remaining slice counts fully" "consumedFrom=$(from_e8 "${QW5_C:-0}") $(echo "$QW5" | head -c 200)"; fi
# Control: cost + fee EXACTLY ($995.4975) funds the whole bid — the arm sizes
# from the fee-inclusive price itself, not from a cruder bound.
adm setTestBalance "(principal \"$UW\", \"ICPUSD\", 99549750000 : nat)" >/dev/null
QW2=$(u quoteSwap "(\"ICP\", \"ICPUSD\", $(e8 100.0) : nat, $(e8 0.01) : nat)" --query | tr -d '_\n' | tr -s ' ')
QW2_C=$(echo "$QW2" | grep -oE "consumedFrom = [0-9]+" | grep -oE "[0-9]+$")
if [ "${QW2_C:-0}" = "$(e8 100.0)" ]; then ok "control: funded for cost + fee exactly (\$995.4975) → the whole 100 ICP is credited (consumedFrom = 100)"; else nok "control: cost + fee must fund the whole bid" "consumedFrom=$(from_e8 "${QW2_C:-0}")"; fi
# The LIVE fill at cost-only funding: a limit sell crossing the bid has the
# engine CANCEL the maker (one mid-match notice) and take ZERO — the taker's
# remainder rests whole and no proceeds settle.
adm setTestBalance "(principal \"$UW\", \"ICPUSD\", $(e8 995.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 100.0) : nat)" >/dev/null
NW0=$(w_notices); USD_W=$(bal "$UA" ICPUSD); RCA0=$(resting_count amm_uA)
u placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 9.95) : nat, $(e8 100.0) : nat)" >/dev/null
freshrequote
NW1=$(w_notices); USD_W2=$(bal "$UA" ICPUSD); RCW2=$(resting_count amm_uW); RCA1=$(resting_count amm_uA)
if [ "${RCW2:-1}" = "0" ] && [ "${NW1:-0}" = "$(( ${NW0:-0} + 1 ))" ] && awk -v a="$USD_W" -v b="$USD_W2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.01?0:1)}'; then
  ok "the live fill CANCELS the cost-only bid with one mid-match notice and settles nothing (taker ICPUSD ${USD_W2}≈$USD_W) — the preview and the engine now agree on the fee"
else nok "the engine must cancel a maker short of cost + fee and take zero from it" "maker-orders=$RCW2 notices ${NW0}→$NW1 usd ${USD_W}→$USD_W2"; fi
if [ "${RCA1:-0}" = "$(( ${RCA0:-0} + 1 ))" ]; then ok "the taker's limit remainder rests whole (nothing was taken from the cancelled maker)"; else nok "the taker's limit remainder should rest" "resting ${RCA0}→$RCA1"; fi
cancel_all_of amm_uA   # before the ladder narrows: the AMM's 9.98 bid would sweep the resting 9.95 ask
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null   # restore the suite's ladder
freshrequote

# ═══ 1788660964: the FOK gate's MAKER gate rounds EXACTLY the way the release
# engine does — to the quote unit. releaseDeferred settles every staged order
# (FOK market orders included) through MatchingEngine.executeLimitOrderProtected,
# whose only maker-BUY gate is the settlement one: tradeCost = ⌊qty × price⌋
# plus the maker's fee on THAT (fundForFill / availableBalance < tradeCost +
# buyerFee → the mid-match cancel), and the same tradeCost + buyerFee is what
# the fill DEBITS. walkFillable (one all-or-nothing arm for every consumer since
# 1788660963: fokFillableDepth — the FOK release gate — getTakeableDepth,
# quoteSwap, fokCrossGate) scores the slice as floor-cost + fee
# too, so a bid funded to exactly that is full depth AND fills whole with a
# zero residue, while one quote unit less is zero depth: the FOK is killed at
# the gate before anything reaches the engine, and a limit that does cross it
# has the engine cancel the maker with the notice. (The task that filed this
# section expected the gate to be one unit LOOSE — it assumed the engine ceils
# the maker's cost. It does, but only in executeMarketOrderProtected's early
# makerNeeds pre-gate and simulateAvailableFill — the cross-swap legs — one
# unit ABOVE their own settlement debit; that engine-internal crumb is filed
# separately. Ceiling the gate here would have killed FOKs the release engine
# fills and under-reported takeable depth by one funded maker.)
echo ""
echo "── 15. the FOK gate is exact to the quote unit: a wallet bid with non-integral cost funded to floor-cost + fee is full depth and fills whole (residue 0); one unit less is zero depth, the FOK kills at the gate, the bid survives, and the engine agrees (1788660964) ──"
mdx_identity_new amm_uR; UR=$(principal_of amm_uR)
ur() { icp canister call --candid "$MDX_CANDID" --identity amm_uR backend "$@" 2>&1; }
r_notices() { ur getMyReleaseRejections '()' --query | tr -d '\n' | grep -oE "mid-match" | grep -c . || true; }
adm setAmmConfig "(\"ICP-ICPUSD\", 400:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null
freshrequote   # bids at 9.60 (outside the 9.90 floor), asks at 10.40 (clear of the wallet's bid)
TR0=$(tkd_sell)
if [ "${TR0:-x}" = "0" ]; then ok "fixture: no depth inside the 1% sell cap before the wallet bids"; else nok "fixture: the AMM's bids must sit outside the 9.90 floor" "takeable=$(from_e8 "${TR0:-0}")"; fi
# 33.33333333 ICP @ 9.95: cost 331.6666666335 — NOT integral at e8. The
# engine's tradeCost floors to 33,166,666,663; the 5 bps maker fee on it is
# 16,583,333; the maker's need — gate AND debit — is 33,183,249,996 quote
# units. (The ceil would be 33,166,666,664 → 33,183,249,997: one unit more.)
adm setTestBalance "(principal \"$UR\", \"ICPUSD\", $(e8 1500.0) : nat)" >/dev/null
ur placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.95) : nat, 3333333333 : nat)" >/dev/null
freshrequote   # releases → 9.95 sits under the AMM's asks → RESTS as the wallet's bid
RCR=$(resting_count amm_uR)
if [ "${RCR:-0}" = "1" ]; then ok "fixture: the wallet's bid 33.33333333 ICP @ 9.95 rests (cost \$331.6666666335 — floor 331.66666663, +fee 0.16583333 = the engine's need \$331.83249996)"; else nok "fixture: the wallet's bid must rest" "resting=$RCR"; fi
# (a) EXACTLY floor-cost + fee (resting orders hold no reservation — by design):
# full depth, and the FOK sell fills the bid whole, leaving the maker 0.
adm setTestBalance "(principal \"$UR\", \"ICPUSD\", 33183249996 : nat)" >/dev/null
TR1=$(tkd_sell)
if [ "${TR1:-x}" = "3333333333" ]; then ok "getTakeableDepth(sell, 9.90) at exactly floor-cost + fee reports the bid whole (33.33333333) — the gate's rounding is the release engine's"; else nok "a maker funded to exactly the release engine's tradeCost + fee is FULL depth" "takeable=$(from_e8 "${TR1:-0}") (0 = a ceil-rounded gate, one unit stricter than the engine that fills — 1788660964)"; fi
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 100.0) : nat)" >/dev/null
RJ15_0=$(fok_count); NR0=$(r_notices); ICP_R=$(bal "$UA" ICP); USD_R=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { sell }, 3333333333 : nat, $(e8 0.01) : nat, true)" >/dev/null
freshrequote
ICP_R2=$(bal "$UA" ICP); USD_R2=$(bal "$UA" ICPUSD); RJ15_1=$(fok_count); NR1=$(r_notices); RCR2=$(resting_count amm_uR); USD_UR=$(bal "$UR" ICPUSD)
if awk -v a="$ICP_R" -v b="$ICP_R2" 'BEGIN{d=a-b; exit ((d>33.3333333 && d<33.3333334)?0:1)}' && [ "${RCR2:-1}" = "0" ] && [ "${NR1:-0}" = "${NR0:-0}" ] && [ "${RJ15_1:-0}" = "${RJ15_0:-0}" ]; then
  ok "the FOK sell FILLS the bid whole (UA ICP ${ICP_R}→$ICP_R2, ICPUSD ${USD_R}→$USD_R2); no kill, no notice"
else nok "at exactly the engine's need the FOK must fill the bid whole" "icp ${ICP_R}→$ICP_R2 resting=$RCR2 notices ${NR0}→$NR1 kills ${RJ15_0}→$RJ15_1"; fi
if [ "${USD_UR:-x}" = "0.00000000" ]; then ok "the maker is debited EXACTLY floor-cost + fee: residue 0.00000000 ICPUSD (the settlement debit is ⌊qty × price⌋ + fee — no ceil anywhere on this path)"; else nok "the release debit must be floor-cost + fee to the unit" "maker residue=$USD_UR"; fi
# (b) ONE quote unit less: zero depth, the FOK is KILLED AT THE GATE (a record
# for the taker, nothing reaches the engine — the bid survives with no notice),
# and the engine AGREES: a limit sell that does cross it cancels the maker
# with the mid-match notice and takes zero.
adm setTestBalance "(principal \"$UR\", \"ICPUSD\", $(e8 1500.0) : nat)" >/dev/null   # (a) left the maker at 0: fund → rest → drain
ur placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 9.95) : nat, 3333333333 : nat)" >/dev/null
freshrequote
adm setTestBalance "(principal \"$UR\", \"ICPUSD\", 33183249995 : nat)" >/dev/null
RCR3=$(resting_count amm_uR); TR2=$(tkd_sell)
if [ "${RCR3:-0}" = "1" ] && [ "${TR2:-x}" = "0" ]; then ok "one unit short (\$331.83249995): the second bid rests and getTakeableDepth reports 0 — exact to the quote unit"; else nok "a maker one quote unit short of tradeCost + fee must count ZERO depth" "resting=$RCR3 takeable=$(from_e8 "${TR2:-0}")"; fi
adm setTestBalance "(principal \"$UA\", \"ICP\", $(e8 100.0) : nat)" >/dev/null
RJ15_2=$(fok_count); NR2=$(r_notices); ICP_S=$(bal "$UA" ICP); USD_S=$(bal "$UA" ICPUSD)
u placeMarketOrder "(\"ICP-ICPUSD\", variant { sell }, 3333333333 : nat, $(e8 0.01) : nat, true)" >/dev/null
freshrequote
ICP_S2=$(bal "$UA" ICP); USD_S2=$(bal "$UA" ICPUSD); RJ15_3=$(fok_count); NR3=$(r_notices); RCR4=$(resting_count amm_uR)
if awk -v a="$ICP_S" -v b="$ICP_S2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0000001?0:1)}' \
   && awk -v a="$USD_S" -v b="$USD_S2" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.00000001?0:1)}' && [ "${RJ15_3:-0}" = "$(( ${RJ15_2:-0} + 1 ))" ]; then
  ok "FOK sell 33.33333333 KILLED with a record (Fill-or-kill ${RJ15_2}→$RJ15_3; ICP ${ICP_S2}≈$ICP_S, ICPUSD unchanged)"
else nok "a FOK sized to a bid the engine cannot take must KILL with a record" "icp ${ICP_S}→$ICP_S2, usd ${USD_S}→$USD_S2, rejections ${RJ15_2}→$RJ15_3"; fi
if [ "${RCR4:-0}" = "1" ] && [ "${NR3:-0}" = "${NR2:-0}" ]; then ok "the bid survives the kill untouched — the GATE killed it (no mid-match cancel, no notice)"; else nok "a gate kill must leave the maker's bid resting with no notice" "resting=$RCR4 notices ${NR2}→$NR3"; fi
RCA15=$(resting_count amm_uA)
u placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 9.95) : nat, 3333333333 : nat)" >/dev/null
freshrequote
NR4=$(r_notices); RCR5=$(resting_count amm_uR); ICP_S3=$(bal "$UA" ICP); RCA15b=$(resting_count amm_uA)
if [ "${RCR5:-1}" = "0" ] && [ "${NR4:-0}" = "$(( ${NR3:-0} + 1 ))" ] && awk -v a="$ICP_S2" -v b="$ICP_S3" 'BEGIN{d=a-b; exit ((d<0?-d:d)<0.0000001?0:1)}' && [ "${RCA15b:-0}" = "$(( ${RCA15:-0} + 1 ))" ]; then
  ok "the engine agrees: a limit sell crossing the one-unit-short bid CANCELS it with one mid-match notice and takes zero (the sell rests whole) — gate and engine disagree on no maker"
else nok "the engine must cancel a maker one unit short of tradeCost + fee and take zero" "maker-orders=$RCR5 notices ${NR3}→$NR4 icp ${ICP_S2}→$ICP_S3 taker-resting ${RCA15}→$RCA15b"; fi
cancel_all_of amm_uA   # before the ladder narrows: the AMM's 9.98 bid would sweep the resting 9.95 ask
cancel_all_of amm_uR
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat)" >/dev/null   # restore the suite's ladder
freshrequote

# ── 6 (#49.3). placeMarketOrder must propagate parkDeferred failure ──
# UC holds 100 ICPUSD RAW but a first spend-all staged buy reserves ~all of it.
# A second market buy passes the raw-balance pre-check (balance != 0) yet
# parkDeferred computes zero parkable qty (AVAILABLE exhausted) and returns
# null. Pre-fix, placeMarketOrder ignored that and replied #ok with
# remainingQty = quantity — a phantom resting order the caller would wait on.
# (Runs LAST: UC's staged spend-all order sits inside its 3s commit window and
# is left to release/expire after the suite — cancel would be refused, and a
# release here would move value across the section-5 conservation set.)
echo ""
echo "── 6. placeMarketOrder → #err when nothing could be staged (#49.3) ──"
mdx_identity_new amm_uC; UC=$(principal_of amm_uC)
uc() { icp canister call --candid "$MDX_CANDID" --identity amm_uC backend "$@" 2>&1; }
adm setTestBalance "(principal \"$UC\", \"ICPUSD\", $(e8 100.0) : nat)" >/dev/null
R1=$(uc placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 50.0) : nat, $(e8 0.05) : nat, false)")
if mdx_ok "$R1"; then
  ok "spend-all buy staged (#ok; reservation consumes the full available balance)"
else nok "setup: spend-all buy should stage" "$R1"; fi
ST1=$(uc getMyStagedOrderIds '()' --query | grep -oE "[0-9_]+ : nat" | grep -c . || true)
R2=$(uc placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 5.0) : nat, $(e8 0.05) : nat, false)")
if echo "$R2" | grep -q "Could not stage the order"; then
  ok "second buy (available exhausted) → #err(\"Could not stage the order\")"
else nok "exhausted-available buy must return #err, not a phantom #ok (#49.3)" "$R2"; fi
ST2=$(uc getMyStagedOrderIds '()' --query | grep -oE "[0-9_]+ : nat" | grep -c . || true)
if [ "${ST1:-0}" = "${ST2:-0}" ]; then
  ok "no phantom entry staged (staged count unchanged: ${ST2:-0})"
else nok "no entry may be created on the failure path" "staged ${ST1:-0} → ${ST2:-0}"; fi

echo ""
adm setTestTimersPaused '(false)' >/dev/null 2>&1   # resume background timers
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
