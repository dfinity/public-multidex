#!/bin/bash
# openPosition borrow UNWIND (review L1, fixed in 3de29fe).
#
# H-34 / D5 option (d) (2026-09-05): openPosition no longer borrows at
# placement at all — it CHECKS the shortfall (BorrowEngine.borrowCheck, sized
# at the ceiling, reserving nothing) and stages; each FILL borrows exactly its
# own shortfall (poolFundForFill). The original L1 shape (a placement borrow
# stranded by a refused park, 3de29fe) is now unreachable by construction:
# a refused park leaves the loan book untouched because nothing was taken.
#
# Deterministic trigger: the per-owner staged-queue cap (32). Fill the pool's
# 32 staged slots with tiny entries that need NO borrow (pool equity covers
# them), then attempt a 33rd big enough to force a borrow:
#   the borrow CHECK passes (small vs the health cap) → parkDeferred returns
#   null at the cap → the pool's debt must be EXACTLY 0: no borrow was taken.
# (Pre-3de29fe it stayed at ≈ the borrowed amount; pre-H-34 a borrow-then-
# exact-repay left it at 0 too — the pin now guards the no-borrow shape.)
# ⚠️ Calls resetExchange.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
ID=bunwind; mdx_identity_new $ID
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --candid "$MDX_CANDID" --identity $ID backend "$@" 2>&1; }
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+"; }
# vec_amt FIELD TOKEN REPLY — the `amount` of the TOKEN entry in a vec-of-
# record field (MarginPoolView.loans / .repayable, task 1788730982); empty
# when the token is not listed. Brace-depth walk (candid nests the records).
vec_amt() { echo "$3" | tr -d '_\n' | awk -v f="$1" -v t="$2" '{ m=f " = vec {"; i=index($0, m); if (!i) exit; s=substr($0, i+length(m)); d=1; o="";
  for (j=1; j<=length(s); j++) { c=substr(s,j,1); if (c=="{") d++; else if (c=="}") { d--; if (d==0) break }; o=o c }
  n=split(o, r, "record"); for (k=1; k<=n; k++) if (index(r[k], "\"" t "\"") && match(r[k], /amount = [0-9]+/)) { print substr(r[k], RSTART+9, RLENGTH-9); exit } }'; }

# The sim must be DEAD: its trading fires GEPTORs that would RELEASE the
# staged entries below (they'd rest on the book), deflating the staged count
# this test builds up to the cap. cold_start relaunches it later.
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
adm createAmmPool '("BTC-ICPUSD")' >/dev/null 2>&1 || true
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm enableAmm '("BTC-ICPUSD", true)' >/dev/null 2>&1 || true
AMM=$(adm getAmmPrincipal "()" | grep -oE 'principal "[^"]+"' | head -1 | sed -E 's/principal "(.+)"/\1/')
adm setTestBalance "(principal \"$AMM\", \"ICPUSD\", $(e8 10000000.0) : nat)" >/dev/null   # vault = lender
adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 50000.0) : nat)" >/dev/null

echo "── setup: cross pool funded \$10k ──"
R=$(usr createMarginPool '("unwind", false)')
PID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr fundMarginPool "($PID, $(e8 10000.0) : nat)" >/dev/null
[ -n "${PID:-}" ] && ok "pool created + funded (id=$PID)" || nok "pool setup" "$R"

echo "── fill all 32 staged slots with tiny NO-borrow entries ──"
OKS=0
for i in $(seq 1 32); do
  O=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.0003) : nat, $(e8 0.05) : nat, opt ($(e8 50000.0) : nat))")
  mdx_ok "$O" && OKS=$((OKS+1))
done
if [ "$OKS" -eq 32 ]; then ok "32 tiny limit entries staged (pool equity covered them — no borrow)"; else nok "expected 32 staged entries" "got $OKS"; fi

D0=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ "${D0:-x}" = "0" ]; then ok "pool debt is 0 before the capped attempt (control)"; else nok "pre-attempt debt should be 0" "debt=$D0"; fi

# Non-vacuity guard: the 33rd entry needs $10,500 of quote; prove the pool's
# free quote is LESS, so openPosition provably had to borrow before parking.
F0=$(fld freeQuote "$(usr getMyMarginPools '()')")
if [ -n "${F0:-}" ] && awk -v f="$F0" -v need="$(e8 10500.0)" 'BEGIN{exit (f < need ? 0 : 1)}'; then
  ok "free quote \$$(awk -v f="$F0" 'BEGIN{printf "%.0f", f/100000000}') < \$10,500 needed — the borrow branch WILL fire"
else nok "precondition broken: pool could cover the 33rd entry without borrowing (test would be vacuous)" "freeQuote=$F0"; fi

echo "── 33rd entry: forces a borrow, then hits the staged cap at parkDeferred ──"
# 0.25 BTC @ 42,000 limit = \$10,500 quote needed; available ≈ \$9,519 after the
# 32 locks → borrows ≈ \$981 (well under the health cap) → park refuses (cap).
O33=$(usr openPosition "($PID, \"BTC-ICPUSD\", variant { buy }, $(e8 0.25) : nat, $(e8 0.05) : nat, opt ($(e8 42000.0) : nat))")
if echo "$O33" | grep -q "Could not stage"; then
  ok "33rd open refused at the staged cap (the borrow was only CHECKED — nothing taken)"
else nok "expected 'Could not stage' from the cap" "$O33"; fi

D1=$(fld debtUsd "$(usr getMyMarginPools '()')")
if [ "${D1:-x}" = "0" ]; then
  ok "no placement borrow to unwind: pool debt is exactly 0 after the failed staging"
else nok "a placement borrow leaked — pool left holding debt with no order" "debtUsd=$D1"; fi


# ═══════════════════════════════════════════════════════════════════════════
# H-07 (F31): a pool order that ends with NO staged and NO resting remainder
# repays its idle pre-borrow AT RELEASE. Before the fix releaseDeferred's
# #market drop arm only recorded the rejection: a zero fill at the slippage
# cap (users-only fallback on an empty book, or the AMM ladder past a 1% cap)
# left the pool holding the whole pre-borrow — accruing interest against
# nothing, with no user-facing repay. Every sibling kill path (expiry, FOK,
# post-only, margin #none) already called repayIdlePoolBorrow.
# Adjacent cases: §H2 fresh-AMM zero fill (ladder beyond the cap); §H3 a
# PARTIAL fill whose tail drops leaves debt equal to the filled leg only
# (settlePoolFills' deleverage already covered this — pinned so it stays);
# §H4 control: a RESTING limit remainder KEEPS its borrow (the earmark is
# excluded from repayment) and its cancel repays it.
# §H5 (task 1788523828) the owner's repayPoolDebt: refused while every free
# dollar is earmarked by a resting order (control), retires idle debt whole
# once free quote exists (the liquidation batch is pinned NOT to reconcile).
# ═══════════════════════════════════════════════════════════════════════════
ID2=bunwind2; mdx_identity_new $ID2
P2=$(icp identity principal --identity $ID2 2>/dev/null | tail -1)
MM=bunwindmm; mdx_identity_new $MM
PM=$(icp identity principal --identity $MM 2>/dev/null | tail -1)
usr2() { icp canister call --candid "$MDX_CANDID" --identity $ID2 backend "$@" 2>&1; }
mmc()  { icp canister call --candid "$MDX_CANDID" --identity $MM backend "$@" 2>&1; }
bal()  { adm getTestBalance "(principal \"$1\", \"$2\")" | tr -d '_' | grep -oE "[0-9]+" | head -1; }
# Re-stamp the reference price (fresh → openPosition's F1 gate passes) and
# requote: the requote releases every eligible staged entry against the fresh
# AMM ladder (the normal GEPTOR path).
requote() { adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 $1) : nat)" >/dev/null; adm requoteAmm '("BTC-ICPUSD")' >/dev/null; }
# The pool's ONE staged/resting order id (getPoolOrders lists staged entries
# under their placement id and resting orders under their book id).
pool_oid() { usr2 getPoolOrders "($1 : nat)" | tr -d '_' | grep -oE "id = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
pool_nord() { usr2 getPoolOrders "($1 : nat)" | grep -c "id ="; }
dollars() { awk -v x="$1" 'BEGIN{ printf "%.2f", x/100000000 }'; }
usd_between() { awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN{ x=x/100000000; exit (x>=lo && x<=hi ? 0 : 1) }'; }
# H-05 (F1): a pool #market remainder now RE-STAGES for MAX_REDEFER (5)
# requotes like a spot market order before it drops — while staged it keeps
# the borrow that backs it (the re-park arm), and the DROP is what repays.
# Drive the users-only expiry pass until no staged entry remains (≤ 7 passes).
drain_walks() {   # drain_walks <poolId>
  local i oid
  for i in 1 2 3 4 5 6 7; do
    oid=$(pool_oid "$1"); [ -z "${oid:-}" ] && return 0
    adm setTestDeferredExpiry "($oid : nat, 1 : int)" >/dev/null 2>&1
    adm adminRunDeferredExpiry "()" >/dev/null 2>&1
  done
}

# AMM: quote both sides (BTC inventory for asks) with a tight ladder.
adm setTestBalance "(principal \"$AMM\", \"BTC\", $(e8 100.0) : nat)" >/dev/null
adm setAmmConfig "(\"BTC-ICPUSD\", 30:nat, $(e8 0.5) : nat, 8:nat, 25:nat)" >/dev/null 2>&1 || true
adm setTestBalance "(principal \"$P2\", \"ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$PM\", \"BTC\", $(e8 10.0) : nat)" >/dev/null
requote 50000.0

echo ""
echo "── H1. setup: second cross pool funded \$10k (no debt) ──"
R2=$(usr2 createMarginPool '("h07", false)')
PID2=$(echo "$R2" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
usr2 fundMarginPool "($PID2, $(e8 10000.0) : nat)" >/dev/null
DH0=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ -n "${PID2:-}" ] && [ "${DH0:-x}" = "0" ]; then ok "pool $PID2 funded, debt 0"; else nok "pool-2 setup" "id=$PID2 debt=$DH0"; fi
V0=$(bal "$AMM" ICPUSD)

echo "── H1. #market long 0.4 BTC at the 1% cap, users-only fallback on an EMPTY book → zero fill, remainder dropped ──"
# 0.4 BTC × cap 50,500 = $20,200 needed against $10k free → borrows ≈ $10,200
# (health ≈ 1.98, clears the 1.25 initial gate so the release clamp is #full).
O=$(usr2 openPosition "($PID2, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.01) : nat, null)")
if mdx_ok "$O"; then ok "market long staged at a 1% cap"; else nok "openPosition #market" "$O"; fi
DH1=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ "${DH1:-x}" = "0" ]; then ok "H-34: the staged entry holds NO debt (leverage is borrowed at the fill, not at placement)"; else nok "H-34: a staged entry must hold no vault debt" "debt=$DH1"; fi
V1=$(bal "$AMM" ICPUSD)
if [ "${V1:-0}" = "${V0:-1}" ]; then ok "H-34: the vault lent nothing at placement (balance unchanged at \$$(dollars "$V1"))"; else nok "H-34: the vault must not move at placement" "V0=$V0 V1=$V1"; fi
SID=$(pool_oid "$PID2")
# Backdate the staged entry's expiry → the users-only fallback releases it
# (AMM sidelined; no user asks rest) → nothing fills within the cap → dropped.
adm setTestDeferredExpiry "(${SID:-0} : nat, 1 : int)" >/dev/null 2>&1
adm adminRunDeferredExpiry "()" >/dev/null 2>&1
drain_walks "$PID2"   # H-05: the zero-fill remainder walks MAX_REDEFER passes before it drops
NREC=$(usr2 getMyReleaseRejections '()' 2>/dev/null | grep -c "remainder dropped" || true)
if [ "$(pool_nord "$PID2")" = "0" ]; then ok "no staged and no resting pool order remains (the whole remainder dropped)"; else nok "pool-2 should hold no order after the drop" "$(usr2 getPoolOrders "($PID2 : nat)" | head -c 300)"; fi
if [ "${NREC:-0}" -ge 1 ]; then ok "release record says 'Market order remainder dropped' (zero fill within the cap)"; else nok "expected the drop record" "$(usr2 getMyReleaseRejections '()' | head -c 300)"; fi
DH2=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ "${DH2:-x}" = "0" ]; then
  ok "H-07 / H-34: pool debt exactly 0 after the zero-fill drop (no borrow was ever taken — the drop has nothing to repay)"
else nok "H-07: pre-borrow stranded — pool holds debt with no order to deploy it" "debtUsd=$DH2 (≈ the borrow)"; fi
V2=$(bal "$AMM" ICPUSD)
if [ "${V2:-0}" -ge "${V0:-0}" ]; then ok "vault balance restored (\$$(dollars "$V2") ≥ \$$(dollars "$V0") — principal + any interest dust back)"; else nok "vault still short" "V0=$V0 V2=$V2"; fi
POS=$(usr2 getMyPositions "()")
if ! echo "$POS" | grep -q "BTC-ICPUSD"; then ok "no position from the zero fill"; else nok "zero fill left a position" "$POS"; fi

echo ""
echo "── H2. adjacent: fresh-AMM release with the ladder PAST the 1% cap (ref re-stamped +4%) → zero fill, borrow repaid ──"
requote 50000.0
O=$(usr2 openPosition "($PID2, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.01) : nat, null)")
mdx_ok "$O" || nok "H2 openPosition" "$O"
DH3=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ "${DH3:-x}" = "0" ]; then ok "H2: staged again with zero debt (H-34)"; else nok "H2: a staged entry must hold no debt" "debt=$DH3"; fi
# The staged cap is 50,500 (1% over 50,000). A fresh price at 52,000 puts the
# AMM's tightest ask (≥ 52,000 + half-spread) beyond it: the normal GEPTOR
# release finds nothing takeable within the cap; H-05: the remainder walks
# MAX_REDEFER (5) requotes, then the sixth drops the whole size.
for _ in 1 2 3 4 5 6 7; do requote 52000.0; done
if [ "$(pool_nord "$PID2")" = "0" ]; then ok "H2: no pool order remains after the fresh-AMM zero fill"; else nok "H2: pool-2 should hold no order" "$(usr2 getPoolOrders "($PID2 : nat)" | head -c 300)"; fi
DH4=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ "${DH4:-x}" = "0" ]; then ok "H2: debt exactly 0 after the fresh-AMM zero-fill drop"; else nok "H2: pre-borrow stranded on the fresh-AMM drop" "debtUsd=$DH4"; fi
POS=$(usr2 getMyPositions "()")
if ! echo "$POS" | grep -q "BTC-ICPUSD"; then ok "H2: no position from the zero fill"; else nok "H2: zero fill left a position" "$POS"; fi

echo ""
echo "── H3. adjacent: PARTIAL fill (user ask for 0.25 of 0.4 within the cap, users-only), tail dropped → debt = the filled leg only ──"
requote 50000.0
# A wallet maker rests an ask INSIDE the pool's cap (50,300 < 50,500) and
# inside the users-only ±2% clamp; released to the book by a requote BEFORE
# the pool stages (so the pool's own release is the only taker of it).
A=$(mmc placeLimitOrder "(\"BTC-ICPUSD\", variant { sell }, $(e8 50300.0) : nat, $(e8 0.25) : nat)")
mdx_ok "$A" || nok "H3 maker ask" "$A"
requote 50000.0
if mmc getMyOrders '()' | grep -q "status = variant { open }"; then ok "maker ask 0.25 @ 50,300 rests"; else nok "maker ask should rest" "$(mmc getMyOrders '()' | head -c 300)"; fi
O=$(usr2 openPosition "($PID2, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.01) : nat, null)")
mdx_ok "$O" || nok "H3 openPosition" "$O"
DH5=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
SID=$(pool_oid "$PID2")
adm setTestDeferredExpiry "(${SID:-0} : nat, 1 : int)" >/dev/null 2>&1
adm adminRunDeferredExpiry "()" >/dev/null 2>&1
drain_walks "$PID2"   # H-05: the 0.15 tail re-stages and walks before it drops
SZ=$(fld size "$(usr2 getMyPositions '()')")
if [ "${SZ:-0}" = "$(e8 0.25)" ]; then ok "filled 0.25 BTC against the resting ask; 0.15 dropped"; else nok "expected a 0.25 BTC fill" "size=$SZ"; fi
if [ "$(pool_nord "$PID2")" = "0" ]; then ok "H3: no pool order remains (tail dropped)"; else nok "H3: pool-2 should hold no order" "$(usr2 getPoolOrders "($PID2 : nat)" | head -c 300)"; fi
DH6=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
FQ6=$(fld freeQuote "$(usr2 getMyMarginPools '()')")
# Filled leg: 0.25 × 50,300 = $12,575 + taker fee (10 bps ≈ $12.6) against
# $10,000 of own quote → ≈ $2,588 of debt is REAL; the ≈ $7,612 of unspent
# borrow is idle and must be gone. Pinned as a band (fee tier may move a few
# dollars) plus the sharp invariant: no free quote sits against debt.
if usd_between "${DH6:-0}" 2500 2700; then ok "H3: debt \$$(dollars "$DH6") = the filled leg's shortfall only (≈\$2,588)"; else nok "H3: debt should be the filled leg only (≈\$2,588)" "debtUsd=$DH6 (pre-release \$$(dollars "${DH5:-0}"))"; fi
if usd_between "${FQ6:-0}" 0 1; then ok "H3: free quote \$$(dollars "$FQ6") — nothing idle against the debt"; else nok "H3: idle quote left against debt" "freeQuote=$FQ6"; fi
# Flatten pool-2 for the control below (sell the 0.25 into the fresh AMM bid).
C=$(usr2 closePosition "($PID2, \"BTC-ICPUSD\", $(e8 0.05) : nat, null)")
requote 50000.0
DH7=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ "${DH7:-x}" = "0" ] && ! usr2 getMyPositions '()' | grep -q "BTC-ICPUSD"; then ok "pool-2 flattened via closePosition, debt 0"; else nok "flatten for the control" "debt=$DH7 close=$C"; fi

echo ""
echo "── H4. H-34 / D5 (d): a #limit entry whose remainder RESTS holds NO debt; cancel repays nothing ──"
requote 50000.0
# Limit bid at 49,000: below the AMM's asks → releases and RESTS as the pool.
# Pre-H-34 this rested with ≈ $9.8k of vault debt (the placement pre-borrow,
# earmarked while resting, repaid by the cancel); now the entry carries no
# debt at all until it fills.
O=$(usr2 openPosition "($PID2, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.01) : nat, opt ($(e8 49000.0) : nat))")
mdx_ok "$O" || nok "H4 openPosition #limit" "$O"
DH8=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
V3b=$(bal "$AMM" ICPUSD)   # the AMM's balance moved with H1–H3's fills; pin against NOW, not V0
requote 50000.0
NO=$(pool_nord "$PID2")
DH9=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
V4=$(bal "$AMM" ICPUSD)
if [ "${NO:-0}" = "1" ] && [ "${DH8:-x}" = "0" ] && [ "${DH9:-x}" = "0" ]; then
  ok "H4: resting limit entry holds ZERO debt (staged 0 → resting 0; 1 resting pool order)"
else nok "H4: a staged/resting entry must hold no vault debt (H-34)" "orders=$NO debt: staged=$DH8 resting=$DH9"; fi
if [ "${V4:-0}" = "${V3b:-1}" ]; then ok "H4: the vault's balance is untouched by the resting entry (\$$(dollars "$V4"))"; else nok "H4: the vault lent for a resting entry" "before=$V3b after=$V4"; fi
OID=$(pool_oid "$PID2")
X=$(usr2 cancelPoolOrder "($PID2 : nat, ${OID:-0} : nat)")
DH10=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if mdx_ok "$X" && [ "${DH10:-x}" = "0" ] && [ "$(pool_nord "$PID2")" = "0" ]; then ok "H4: cancel repays nothing (there is nothing) — debt 0 → 0, order gone"; else nok "H4: cancel of a debt-free entry" "cancel=$X debt=$DH10 orders=$(pool_nord "$PID2")"; fi

echo ""
echo "── H5. the owner's lever (1788523828): repayPoolDebt retires IDLE debt; the batch never reconciles; a resting entry needs no earmark ──"
# Debt now only ever comes from a FILL (H-34): a #market long released
# against the fresh AMM ladder borrows its shortfall at the fill. A resting
# limit entry beside it earmarks nothing (it borrows at its own fill), so the
# owner's repay is bounded only by what is free — and right after the fill
# nothing is (the borrow was exact): the repay is refused on "No free".
requote 50000.0
O=$(usr2 openPosition "($PID2, \"BTC-ICPUSD\", variant { buy }, $(e8 0.4) : nat, $(e8 0.01) : nat, null)")
mdx_ok "$O" || nok "H5 openPosition #market" "$O"
requote 50000.0   # fresh ladder (4 BTC a side) → the 0.4 fills in one release
drain_walks "$PID2"
SZ5=$(fld size "$(usr2 getMyPositions '()')")
DH11=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
FQ11=$(fld freeQuote "$(usr2 getMyMarginPools '()')")
if [ "${SZ5:-0}" = "$(e8 0.4)" ] && usd_between "${DH11:-0}" 9800 10500; then ok "H5: filled long 0.4 BTC — the fill borrowed \$$(dollars "$DH11") (≈ 0.4 × 50k + fee − \$10k own)"; else nok "H5 fixture: filled leveraged long" "size=$SZ5 debt=$DH11"; fi
if usd_between "${FQ11:-0}" 0 1; then ok "H5: free quote \$$(dollars "${FQ11:-0}") right after the fill — the borrow was exact, nothing idle"; else nok "H5: idle quote after an exact borrow" "freeQuote=$FQ11"; fi
O=$(usr2 openPosition "($PID2, \"BTC-ICPUSD\", variant { buy }, $(e8 0.1) : nat, $(e8 0.01) : nat, opt ($(e8 49000.0) : nat))")
mdx_ok "$O" || nok "H5 openPosition #limit (resting beside the position)" "$O"
requote 50000.0
NO=$(pool_nord "$PID2")
DH12=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ "${NO:-0}" = "1" ] && [ "${DH12:-0}" -ge "${DH11:-0}" ] && [ "${DH12:-0}" -le $(( ${DH11:-0} + 1000000 )) ]; then ok "H5: a limit entry rests beside the position with the debt unchanged (\$$(dollars "$DH12"); it borrows at ITS fill, earmarks nothing)"; else nok "H5 fixture: resting limit beside the position" "orders=$NO debt=${DH11}→${DH12}"; fi
R=$(usr2 repayPoolDebt "($PID2 : nat, \"ICPUSD\", $(e8 1000000.0) : nat)")
if ! mdx_ok "$R" && echo "$R" | grep -q "No free"; then ok "H5 control: repay refused while nothing is free (the fill's borrow was exact; the resting entry holds no cash back)"; else nok "H5 control: a pool with no free quote must refuse" "$(echo "$R" | head -c 160)"; fi
# 1788730982: the view's per-token figures ARE repayPoolDebt's min() legs —
# loans[token] the accrued debt, repayable[token] = available − the resting
# earmark. Read in ONE reply so the figures share an accrual.
MP=$(usr2 getMyMarginPools '()')
LN12=$(vec_amt loans ICPUSD "$MP"); RP12=$(vec_amt repayable ICPUSD "$MP"); DQ12=$(fld debtUsd "$MP")
if [ "${LN12:-x}" = "${DQ12:-y}" ] && [ "${LN12:-0}" -gt 0 ]; then ok "H5/1788730982: loans[ICPUSD] = \$$(dollars "$LN12") = the same reply's debtUsd (a quote-only debt, one accrual)"; else nok "H5/1788730982: loans[ICPUSD] should equal debtUsd" "loans=$LN12 debtUsd=$DQ12"; fi
if [ "${RP12:-x}" = "0" ]; then ok "H5/1788730982: repayable[ICPUSD] = 0 exactly where the repay was refused on 'No free'"; else nok "H5/1788730982: repayable must be 0 when nothing is free" "repayable=$RP12"; fi
# The free-capped leg: hand the pool \$3,000 (< the ~\$10k debt). repayable
# must say exactly that (the resting ENTRY earmarks nothing, so it equals
# freeQuote here), and the repay must pay exactly repayable — to the unit.
PP2=$(echo "$MP" | grep -oE '"principal" = "[^"]+"' | head -1 | grep -oE '"[a-z0-9-]+"$' | tr -d '"')
PB0=$(bal "$PP2" ICPUSD)
adm setTestBalance "(principal \"$PP2\", \"ICPUSD\", $((PB0 + $(e8 3000.0))) : nat)" >/dev/null
MP=$(usr2 getMyMarginPools '()')
LN13=$(vec_amt loans ICPUSD "$MP"); RP13=$(vec_amt repayable ICPUSD "$MP"); FQ13=$(fld freeQuote "$MP")
if [ "${RP13:-x}" = "${FQ13:-y}" ] && [ "${RP13:-0}" -ge "$(e8 3000.0)" ] && [ "${RP13:-0}" -lt "${LN13:-0}" ]; then ok "H5/1788730982: repayable[ICPUSD] = \$$(dollars "$RP13") = freeQuote (no exit resting → no earmark) and < the debt"; else nok "H5/1788730982: repayable after the \$3k top-up" "repayable=$RP13 freeQuote=$FQ13 loans=$LN13"; fi
R=$(usr2 repayPoolDebt "($PID2 : nat, \"ICPUSD\", $(e8 1000000.0) : nat)")
PAIDA=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
if mdx_ok "$R" && [ "${PAIDA:-x}" = "${RP13:-y}" ]; then ok "H5/1788730982: repayPoolDebt paid EXACTLY the view's repayable (\$$(dollars "${PAIDA:-0}") — free-capped, to the unit)"; else nok "H5/1788730982: the repay must pay exactly repayable[ICPUSD]" "reply=$(echo "$R" | head -c 160) repayable=$RP13 paid=$PAIDA"; fi
DH12B=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
if [ "${DH12B:-0}" -gt 0 ] && [ "${DH12B:-0}" -lt "${DH12:-0}" ]; then ok "H5/1788730982: the debt is down to \$$(dollars "$DH12B") (the rest stays idle for the legs below)"; else nok "H5/1788730982: a partial repay should leave a smaller debt" "debt=${DH12}→${DH12B}"; fi
V5=$(bal "$AMM" ICPUSD)
# The stranded-loan shape: hand the pool extra FREE quote (#dev balance
# write) — debt against free funds through a path that never repays.
# (candid prints the reserved word as a quoted key: "principal" = "…".)
PP2=$(usr2 getMyMarginPools '()' | grep -oE '"principal" = "[^"]+"' | head -1 | grep -oE '"[a-z0-9-]+"$' | tr -d '"')
PB=$(bal "$PP2" ICPUSD)
adm setTestBalance "(principal \"$PP2\", \"ICPUSD\", $((PB + $(e8 20000.0))) : nat)" >/dev/null
adm adminRunLiquidationBatch '()' >/dev/null 2>&1
MP=$(usr2 getMyMarginPools '()')
DH13=$(fld debtUsd "$MP"); LN13B=$(vec_amt loans ICPUSD "$MP"); RP13B=$(vec_amt repayable ICPUSD "$MP")
if [ "${DH13:-0}" -ge "${DH12B:-0}" ]; then ok "H5 control: idle debt persists across a liquidation pass (\$$(dollars "$DH13") — the batch does not reconcile; the owner holds the lever)"; else nok "H5: the batch must leave idle debt alone (shape (b), not (a))" "debt=${DH12B}→${DH13}"; fi
R=$(usr2 repayPoolDebt "($PID2 : nat, \"ICPUSD\", $(e8 1000000.0) : nat)")
PAID=$(echo "$R" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
DH14=$(fld debtUsd "$(usr2 getMyMarginPools '()')")
V6=$(bal "$AMM" ICPUSD)
NO3=$(pool_nord "$PID2")
if mdx_ok "$R" && [ "${DH14:-x}" = "0" ] && [ "${PAID:-0}" -ge "${DH13:-0}" ]; then ok "H5: repayPoolDebt retired the whole debt (paid \$$(dollars "${PAID:-0}") incl. the accrued interest; debt 0)"; else nok "H5: repayPoolDebt should retire the idle debt" "reply=$(echo "$R" | head -c 160) debt=$DH14 paid=$PAID"; fi
# 1788730982, the debt-capped leg: paid = min(loans, repayable) — ≥ the
# view's loans (interest accrues between the query and the update: the
# preview is a floor by at most that) and ≤ its repayable (what was free).
if [ "${PAID:-0}" -ge "${LN13B:-0}" ] && [ "${PAID:-0}" -le "${RP13B:-0}" ] && [ "${RP13B:-0}" -gt "${LN13B:-0}" ]; then ok "H5/1788730982: debt-capped: paid \$$(dollars "${PAID:-0}") ≥ loans[ICPUSD] \$$(dollars "${LN13B:-0}") (+ the in-flight interest) and ≤ repayable \$$(dollars "${RP13B:-0}")"; else nok "H5/1788730982: paid must sit between the view's loans and repayable" "paid=$PAID loans=$LN13B repayable=$RP13B"; fi
MP=$(usr2 getMyMarginPools '()')
if ! echo "$MP" | tr -d '\n' | grep -qE 'loans = vec \{ *record'; then ok "H5/1788730982: a debt-free pool publishes loans = vec {} (no Repay row)"; else nok "H5/1788730982: loans should be empty once the debt is retired" "$(echo "$MP" | tr -d '\n' | grep -oE 'loans = vec \{[^}]*' | head -c 160)"; fi
if [ "${V6:-0}" -ge "${V5:-0}" ] && [ $((${V6:-0} - ${V5:-0})) -eq "${PAID:-0}" ] && [ "${PAID:-0}" -gt 0 ]; then ok "H5: vault balance restored by exactly the amount paid (+\$$(dollars $((V6 - V5))))"; else nok "H5: the vault should receive the repayment" "V5=$V5 V6=$V6 paid=$PAID"; fi
if [ "${NO3:-0}" = "1" ]; then ok "H5: the resting entry survived the repay (it never needed an earmark)"; else nok "H5: repay must not touch the resting order" "orders=$NO3"; fi
R=$(usr2 repayPoolDebt "($PID2 : nat, \"ICPUSD\", 1 : nat)")
if ! mdx_ok "$R" && echo "$R" | grep -q "No ICPUSD debt"; then ok "H5: a repay on a debt-free pool is refused, not a silent no-op"; else nok "H5: debt-free repay should #err" "$(echo "$R" | head -c 160)"; fi
R=$(usr repayPoolDebt "($PID2 : nat, \"ICPUSD\", 1 : nat)")
if ! mdx_ok "$R" && echo "$R" | grep -q "Not your pool"; then ok "H5: another user cannot repay (or probe) someone else's pool"; else nok "H5: owner gate" "$(echo "$R" | head -c 160)"; fi
OID=$(pool_oid "$PID2")
X=$(usr2 cancelPoolOrder "($PID2 : nat, ${OID:-0} : nat)")
mdx_ok "$X" && ok "H5: cleanup — resting order cancelled" || nok "H5 cleanup cancel" "$X"

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
