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
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money migration: trading/admin methods take Nat BASE UNITS (10^8), and
# getTestBalance now RETURNS base units. e8 converts human→base for call args;
# from_e8 converts base→human so the human-scale assertions below stay unchanged.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }
mkid() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; icp identity principal --identity "$1" 2>/dev/null | tail -1; }
adm()  { icp canister call --identity anonymous backend "$@" 2>&1; }
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

S=$(mkid amm_seed); UA=$(mkid amm_uA)
u() { icp canister call --identity amm_uA backend "$@" 2>&1; }

adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1   # quiesce background timers for a deterministic run
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
# 5 levels × 100 ICP within ~1.25% → ~500 ICP of ask depth, all under a 5% cap.
# (quoteDepthBase is a base-unit Nat quantity now; spread/levels/spacing/window stay plain nats.)
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 100.0) : nat, 5:nat, 10:nat, 5:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$S\", \"ICP\", $(e8 10000.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$S\", \"ICPUSD\", $(e8 100000.0) : nat)" >/dev/null
icp canister call --identity amm_seed backend seedAmmPool "(\"ICP-ICPUSD\", $(e8 10000.0) : nat, $(e8 100000.0) : nat)" >/dev/null 2>&1
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
MA=$(mkid amm_mA); MB=$(mkid amm_mB)
ma() { icp canister call --identity amm_mA backend "$@" 2>&1; }
mb() { icp canister call --identity amm_mB backend "$@" 2>&1; }
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
ME=$(mkid amm_mE)
me() { icp canister call --identity amm_mE backend "$@" 2>&1; }
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
UM=$(mkid amm_uM)
um() { icp canister call --identity amm_uM backend "$@" 2>&1; }
adm setTestBalance "(principal \"$UM\", \"ICPUSD\", $(e8 500.0) : nat)" >/dev/null
freshrequote   # pin the mark back to 10.0 for a deterministic entry
PID9=$(um createMarginPool '("fok95", false)' | tr -d '_' | grep -oE "[0-9]+" | head -1)
um fundMarginPool "(${PID9:-0} : nat, $(e8 500.0) : nat)" >/dev/null
R9=$(um openPosition "(${PID9:-0} : nat, \"ICP-ICPUSD\", variant { sell }, $(e8 100.0) : nat, $(e8 0.05) : nat, null)")
if echo "$R9" | grep -q "ok"; then
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
if echo "$R9B" | grep -q "ok"; then
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
RJ9=$(um getMyReleaseRejections '()' --query | grep -c "Fill-or-kill" || true)
if [ "${RJ9:-0}" -ge 1 ]; then
  ok "kill recorded in getMyReleaseRejections (Fill-or-kill ... initial-margin)"
else nok "the margin-clamp FOK kill must be recorded, never silent" "no Fill-or-kill rejection for the pool owner"; fi

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
UC=$(mkid amm_uC)
uc() { icp canister call --identity amm_uC backend "$@" 2>&1; }
adm setTestBalance "(principal \"$UC\", \"ICPUSD\", $(e8 100.0) : nat)" >/dev/null
R1=$(uc placeMarketOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 50.0) : nat, $(e8 0.05) : nat, false)")
if echo "$R1" | grep -q "ok"; then
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
