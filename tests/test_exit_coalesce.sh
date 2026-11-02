#!/bin/bash
# H-32 (F12) — one principal's tape inflow through the EXIT SET is bounded
# without refusing a genuine exit; the drain scales with backlog.
#
# The exit set is admitted at every shed floor (W1-05) and the D2 decision
# (task 1788467594) keeps it that way: exits are NEVER refused. What was
# unbounded was the TAPE: withdraw / withdrawMarginPool / unstakeInsurance /
# withdrawLp each write 2–11 permanent events, bounded only by amount == 0,
# so one registered principal issuing DUST exits at ingress speed out-ran a
# healthy archive's fixed 200 ev/s drain and reached the size-only L3 shear —
# everyone's unshipped history dropped, by one user, with nothing wrong.
#
# The fix, three parts (main.mo: exitFolds / foldDustExit / flushExitWindows,
# SHIP_BURST_MAX + shipBatchTo, shearMemoryPressure):
#   • per-principal DUST COALESCING — the first exit of a 30 s window writes
#     its rows live; a later DUST exit (< 10 ICPUSD of value, not spend-all)
#     inside the window still EXECUTES (#ok, balance moves) but its #delta
#     rows and its semantic row are summed into the window and written once
#     at the window's end; a genuine (non-dust / spend-all / spaced) exit is
#     live as before;
#   • the ship drain BURSTS above the soft admission tier (up to 8 further
#     batches per tick) instead of one fixed batch;
#   • the L3 shear needs memory pressure, not size alone
#     (test_archive_failover.sh §F pins that half — it sheds, this suite
#     never does).
#
#   §1 a burst of 12 dust withdraws from ONE principal: every call is #ok and
#      the balance moves in full (never refused), yet the tape grows by the
#      first exit's rows only; exitCoalesced counts the other eleven; no shed,
#      no gap
#   §2 the window elapses → the heartbeat flushes the sums (≤ 2 rows: one
#      #delta, one #withdrawal), exitRowsWithheld returns to 0
#   §3 genuine exits are live: a fresh principal's first (dust) exit, a
#      non-dust exit inside its window, a spaced dust repeat — each grows the
#      tape at once and coalesces nothing
#   §4 the other three exits are windowed the same way (withdrawMarginPool,
#      unstakeInsurance, withdrawLp — dust repeats coalesce, spend-all is live)
#   §5 backlog-scaled drain: batch pinned to 5, soft tier pinned to 10, 30
#      events queued → ONE ship tick drains to the tier (≤ 10 left; pre-fix
#      25); with the real tier (50k) one tick drains exactly one batch
#
# State-light: no resetExchange, no seeding; leaves bands/pins/timers as
# found. Needs #dev (setTestExitCoalesceWindow, setTestShipFailover,
# setTestShipShedBands, setTestTimersPaused, addTestTokens).

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_exit_coalesce" "setTestExitCoalesceWindow / setTestShipFailover / setTestShipShedBands (#dev backend)"

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
u()   { icp canister call --candid "$MDX_CANDID" --identity xc_u backend "$@" 2>&1; }
v()   { icp canister call --candid "$MDX_CANDID" --identity xc_v backend "$@" 2>&1; }
mdx_identity_new xc_u; U=$(principal_of xc_u)
mdx_identity_new xc_v; V=$(principal_of xc_v)

info()  { adm getCanisterInfo '()' --query | tr -d '_\n' | tr -s ' '; }
field() { echo "$1" | grep -oE "$2 = [0-9]+" | head -1 | grep -oE "[0-9]+"; }
# Rows bound for the tape: acked + queued + journaled (drained next beat).
# Withheld rows are NOT counted — they are what the window holds back.
tape_bound() { local I; I=$(info); echo $(( $(field "$I" archivedEvents) + $(field "$I" journalUnshipped) + $(field "$I" ledgerJournalPending) )); }
coalesced() { field "$(info)" exitCoalesced; }
withheld()  { field "$(info)" exitRowsWithheld; }
bal() { adm getTestBalance "(principal \"$1\", \"$2\")" --query 2>/dev/null | tr -d '_' | grep -oE '[0-9]+' | head -1; }
E8=100000000
WINDOW_S=20

restore() {  # always leave the venue as found
  adm setTestExitCoalesceWindow '(null)' >/dev/null 2>&1
  adm setTestShipFailover '(false, null, null, null, null, null, null)' >/dev/null 2>&1
  adm setTestShipShedBands '(null)' >/dev/null 2>&1
  adm setTestTimersPaused '(false)' >/dev/null 2>&1
}
on_exit restore   # registered, not installed directly: _scratch.sh (via _lib.sh) owns the one exit hook, and the identity + scratch cleanups ride it

echo "── §0 fixtures: two registered principals, a 20 s window ──"
refused() { echo "$1" | grep -qiE "refus|reject|error|trap"; }
R=$(u addTestTokens "(\"ICPUSD\", $((100000 * E8)) : nat)")     # faucet registers the caller (dev); replies ()
refused "$R" && nok "faucet refused xc_u" "$R" || ok "xc_u registered via the faucet (100k ICPUSD)"
R=$(v addTestTokens "(\"ICPUSD\", $((1000 * E8)) : nat)")
refused "$R" && nok "faucet refused xc_v" "$R" || ok "xc_v registered via the faucet (1k ICPUSD)"
adm setTestTimersPaused '(false)' >/dev/null
R=$(adm setTestExitCoalesceWindow "(opt ($WINDOW_S : nat))")
if echo "$R" | grep -qiE 'error|reject|trap|Unknown method|unrecognized'; then nok "setTestExitCoalesceWindow missing (pre-H-32 build?)" "$(echo "$R" | head -c 160)"; else ok "exit window pinned to ${WINDOW_S}s"; fi
I0=$(info); SHED0=$(field "$I0" shedEvents); GAPS0=$(field "$I0" ledgerGaps)

echo "── §1 a dust burst from one principal: every exit passes, the tape grows once ──"
T0=$(tape_bound); C0=$(coalesced); B0=$(bal "$U" ICPUSD)
OKS=0; i=0
while [ $i -lt 12 ]; do
  R=$(u withdraw "(\"ICPUSD\", $E8 : nat, \"xc-dust-$i\")")   # 1 ICPUSD — dust (bar = 10)
  mdx_ok "$R" && OKS=$((OKS+1))
  i=$((i+1))
done
T1=$(tape_bound); C1=$(coalesced); B1=$(bal "$U" ICPUSD)
[ "$OKS" -eq 12 ] && ok "all 12 dust withdraws returned #ok (never refused — W1-05 / D2)" || nok "a dust exit was refused" "ok=$OKS of 12"
[ $((B0 - B1)) -eq $((12 * E8)) ] && ok "the balance moved in full (12 ICPUSD out: $B0 → $B1)" || nok "balance did not move by 12 ICPUSD" "before=$B0 after=$B1"
GROW1=$((T1 - T0))
if [ "$GROW1" -le 6 ]; then ok "tape-bound rows grew by $GROW1 for 12 exits (the first exit's rows only; pre-fix 24)"
else nok "the burst wrote $GROW1 rows — the exit set is unbounded per principal (the finding)" "T $T0 → $T1"; fi
[ $((C1 - C0)) -eq 11 ] && ok "exitCoalesced counted the eleven in-window dust exits ($C0 → $C1)" || nok "exitCoalesced did not count 11" "$C0 → $C1"
W1=$(withheld)
[ "${W1:-0}" -ge 1 ] && ok "exitRowsWithheld = $W1 while the window is open" || nok "nothing withheld" "withheld=$W1"
I1=$(info)
if [ "$(field "$I1" shedEvents)" = "$SHED0" ] && [ "$(field "$I1" ledgerGaps)" = "$GAPS0" ]; then ok "no shed, no gap from the burst (shedEvents=$SHED0, ledgerGaps=$GAPS0)"
else nok "the burst caused a shed" "shed $SHED0 → $(field "$I1" shedEvents) gaps $GAPS0 → $(field "$I1" ledgerGaps)"; fi

echo "── §2 the window elapses → the heartbeat flushes the sums ──"
if wait_for '[ "$(withheld)" = "0" ]' $((WINDOW_S + 25)) 2; then ok "exitRowsWithheld back to 0 (flushed by the drain)"; else nok "withheld rows never flushed" "withheld=$(withheld)"; fi
T2=$(tape_bound)
GROW2=$((T2 - T1))
if [ "$GROW2" -ge 1 ] && [ "$GROW2" -le 4 ]; then ok "the flush wrote $GROW2 row(s): one summed #delta + one summed #withdrawal, not 22"
else nok "flush wrote $GROW2 rows" "T $T1 → $T2"; fi
[ "$(coalesced)" = "$C1" ] && ok "the flush coalesced nothing further ($C1)" || nok "exitCoalesced moved on the flush" "$(coalesced)"

echo "── §3 genuine exits are live ──"
T3=$(tape_bound); C3=$(coalesced)
R=$(v withdraw "(\"ICPUSD\", $E8 : nat, \"xc-v-first\")")     # a fresh principal's FIRST exit — dust, but first
T4=$(tape_bound)
mdx_ok "$R" && [ $((T4 - T3)) -ge 2 ] && ok "a fresh principal's first (dust) exit wrote live (+$((T4 - T3)))" || nok "first exit not live" "r=$(echo "$R" | head -c 80) grow=$((T4 - T3))"
R=$(v withdraw "(\"ICPUSD\", $((50 * E8)) : nat, \"xc-v-genuine\")")   # non-dust INSIDE the window
T5=$(tape_bound)
mdx_ok "$R" && [ $((T5 - T4)) -ge 2 ] && ok "a non-dust exit inside the window wrote live (+$((T5 - T4)))" || nok "non-dust in-window exit not live" "grow=$((T5 - T4))"
[ "$(coalesced)" = "$C3" ] && ok "neither coalesced anything (exitCoalesced still $C3)" || nok "a genuine exit was coalesced" "$(coalesced)"
R=$(v withdraw "(\"ICPUSD\", $E8 : nat, \"xc-v-dust2\")")     # dust inside the window → coalesces
[ "$(coalesced)" = "$((C3 + 1))" ] && ok "control: a second dust exit inside the window coalesced" || nok "in-window dust did not coalesce" "$(coalesced)"
echo "   (waiting ${WINDOW_S}s for xc_v's window to elapse)"
perl -e "select(undef,undef,undef,$((WINDOW_S + 2)))"
T6=$(tape_bound); C6=$(coalesced)
R=$(v withdraw "(\"ICPUSD\", $E8 : nat, \"xc-v-spaced\")")    # dust, but WELL-SPACED
T7=$(tape_bound)
mdx_ok "$R" && [ $((T7 - T6)) -ge 2 ] && [ "$(coalesced)" = "$C6" ] && ok "a well-spaced dust repeat wrote live (+$((T7 - T6)), nothing coalesced)" || nok "spaced repeat was coalesced or refused" "grow=$((T7 - T6)) c=$(coalesced) r=$(echo "$R" | head -c 80)"
# The remainder: spend-all is genuine at ANY size (the order path's own rule).
BV=$(bal "$V" ICPUSD)
R=$(v withdraw "(\"ICPUSD\", $((BV - E8)) : nat, \"xc-v-drain\")")    # leave exactly 1 ICPUSD (non-dust: 947 ICPUSD)
mdx_ok "$R" || nok "drain withdraw refused" "$R"
C8=$(coalesced)
R=$(v withdraw "(\"ICPUSD\", $E8 : nat, \"xc-v-spendall\")")           # 1 ICPUSD = the whole remaining balance
mdx_ok "$R" && [ "$(coalesced)" = "$C8" ] && [ "$(bal "$V" ICPUSD)" = "0" ] && ok "spend-all dust (the whole remaining 1 ICPUSD) wrote live — genuine at any size" || nok "spend-all was coalesced or refused" "c=$C8 → $(coalesced) bal=$(bal "$V" ICPUSD) r=$(echo "$R" | head -c 80)"

echo "── §4 the other three exits are windowed the same way ──"
# withdrawMarginPool: fund a pool with 100 ICPUSD, then dust withdrawals.
adm setTestExitCoalesceWindow "(opt ($WINDOW_S : nat))" >/dev/null
PID=$(u createMarginPool '("xc pool", false)' | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "$PID" ] && mdx_ok "$(u fundMarginPool "($PID : nat, $((100 * E8)) : nat)")"; then
  perl -e "select(undef,undef,undef,$((WINDOW_S + 2)))"    # xc_u's §1 window is long gone; be explicit anyway
  C9=$(coalesced); T9=$(tape_bound)
  R1=$(u withdrawMarginPool "($PID : nat, $E8 : nat)"); R2=$(u withdrawMarginPool "($PID : nat, $E8 : nat)"); R3=$(u withdrawMarginPool "($PID : nat, $E8 : nat)")
  T10=$(tape_bound)
  if mdx_ok "$R1" && mdx_ok "$R2" && mdx_ok "$R3" && [ "$(coalesced)" = "$((C9 + 2))" ]; then ok "withdrawMarginPool: three dust withdrawals all #ok, two coalesced (tape +$((T10 - T9)))"
  else nok "withdrawMarginPool dust repeats not coalesced / refused" "c=$C9 → $(coalesced) r=$(echo "$R1$R2$R3" | tr -d '\n' | head -c 120)"; fi
  C11=$(coalesced)
  R=$(u withdrawMarginPool "($PID : nat, $((97 * E8)) : nat)")     # the whole remaining free balance — spend-all
  mdx_ok "$R" && [ "$(coalesced)" = "$C11" ] && ok "withdrawMarginPool: emptying the pool (spend-all) wrote live" || nok "pool spend-all coalesced or refused" "c=$C11 → $(coalesced) r=$(echo "$R" | head -c 100)"
else nok "could not create/fund a margin pool for §4" "pid=${PID:-none}"; fi
# unstakeInsurance: stake 100 ICPUSD, unstake dust-sized share slices. The
# window is PER PRINCIPAL across all four exits, so xc_u's pool window above
# must elapse first or all three unstakes would fold into it.
echo "   (waiting ${WINDOW_S}s for xc_u's pool window to elapse)"
perl -e "select(undef,undef,undef,$((WINDOW_S + 2)))"
ST=$(u stakeInsurance "($((100 * E8)) : nat)")
# H-35: a fresh stake is locked for 10 min; the #dev re-stamp hook crosses the
# cooldown so the dust unstakes below probe the exit window, not the lock.
adm setTestInsuranceStakedAt "(principal \"$U\", 1 : int)" >/dev/null 2>&1 || true
SH=$(echo "$ST" | tr -d '_' | grep -oE 'ok = [0-9]+' | grep -oE '[0-9]+' | head -1)
if [ -n "$SH" ] && [ "$SH" -gt 0 ]; then
  SLICE=$((SH / 100))     # ≈ 1 ICPUSD of payout
  C12=$(coalesced); T12=$(tape_bound)
  R1=$(u unstakeInsurance "($SLICE : nat)"); R2=$(u unstakeInsurance "($SLICE : nat)"); R3=$(u unstakeInsurance "($SLICE : nat)")
  T13=$(tape_bound)
  if mdx_ok "$R1" && mdx_ok "$R2" && mdx_ok "$R3" && [ "$(coalesced)" = "$((C12 + 2))" ]; then ok "unstakeInsurance: three dust unstakes all #ok, two coalesced (tape +$((T13 - T12)))"
  else nok "unstakeInsurance dust repeats not coalesced / refused" "c=$C12 → $(coalesced) r=$(echo "$R1$R2$R3" | tr -d '\n' | head -c 120)"; fi
  C14=$(coalesced)
  R=$(u unstakeInsurance "($((SH - 3 * SLICE)) : nat)")             # every remaining share — spend-all
  mdx_ok "$R" && [ "$(coalesced)" = "$C14" ] && ok "unstakeInsurance: the full remaining stake (spend-all) wrote live" || nok "insurance spend-all coalesced or refused" "c=$C14 → $(coalesced) r=$(echo "$R" | head -c 100)"
else nok "stakeInsurance did not mint shares for §4" "$(echo "$ST" | head -c 120)"; fi
# withdrawLp: a small quote-heavy vault deposit, then dust LP redemptions
# (same per-principal window: let the insurance one elapse first).
echo "   (waiting ${WINDOW_S}s for xc_u's insurance window to elapse)"
perl -e "select(undef,undef,undef,$((WINDOW_S + 2)))"
u addTestTokens "(\"ICP\", $((100 * E8)) : nat)" >/dev/null
# (staged doors since apiVersion 6.0.0: each mdx_lp_* call stages, re-stamps
# and settles before returning, so the three redemptions still land inside
# one 30 s exit window — ~5 s apart — and the fold runs at settlement.)
LP=$(mdx_lp_deposit xc_u "ICP-ICPUSD" "$((10 * E8))" "$((200 * E8))")
if [ -n "$LP" ] && [ "$LP" -gt 0 ] 2>/dev/null; then
  SLICE=$((LP / 200))     # ≈ 1 ICPUSD of NAV
  C15=$(coalesced); T15=$(tape_bound)
  ALL3=0
  R1=$(mdx_lp_withdraw xc_u "$SLICE") && R2=$(mdx_lp_withdraw xc_u "$SLICE") && R3=$(mdx_lp_withdraw xc_u "$SLICE") && ALL3=1
  T16=$(tape_bound)
  if [ "$ALL3" = "1" ] && [ "$(coalesced)" = "$((C15 + 2))" ]; then ok "withdrawLp: three dust redemptions all settled, two coalesced (tape +$((T16 - T15)) for up to 33 rows)"
  else nok "withdrawLp dust repeats not coalesced / refused" "c=$C15 → $(coalesced) r=$(echo "${R1:-}${R2:-}${R3:-}" | tr -d '\n' | head -c 160)"; fi
else
  skip_section "withdrawLp leg: depositLp on ICP-ICPUSD did not mint on this venue (the fold path is shared with §1; test_vault_lp covers the exit)"
fi
if wait_for '[ "$(withheld)" = "0" ]' $((WINDOW_S + 25)) 2; then ok "§4's windows flushed (exitRowsWithheld = 0)"; else nok "§4 rows never flushed" "withheld=$(withheld)"; fi

echo "── §5 backlog-scaled drain: one tick drains to the soft tier ──"
adm setTestTimersPaused '(true)' >/dev/null                       # step shipping by hand
R=$(adm setTestShipFailover '(false, null, null, null, null, opt (5 : nat), null)')   # batch = 5 (H-32's 6th arg)
mdx_ok "$R" && ok "ship batch pinned to 5 (setTestShipFailover's 6th arg)" || nok "batch pin unavailable (pre-H-32 build?) — the burst assertion below would be vacuous" "$(echo "$R" | head -c 120)"
adm setTestShipShedBands '(opt record { 0 = 10 : nat; 1 = 1_000 : nat; 2 = 7 : nat; 3 = 700 : nat })' >/dev/null   # soft tier = 10
adm adminForceShipTick '()' >/dev/null 2>&1                        # start from a drained queue
i=0; while [ $i -lt 30 ]; do u withdraw "(\"ICPUSD\", $((10 * E8)) : nat, \"xc-burst-$i\")" >/dev/null 2>&1; i=$((i+1)); done   # 10 ICPUSD each — genuine, live
Q0=$(field "$(info)" journalUnshipped); BB0=$(field "$(info)" shipBurstBatches)
[ "${Q0:-0}" -ge 30 ] && ok "30 genuine withdrawals queued 30 tape events under a paused shipper (queue=$Q0)" || nok "queue did not grow by 30" "queue=$Q0"
Q1=$(adm adminForceShipTick '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)
if [ "${Q1:-99}" -le 10 ]; then ok "ONE ship tick drained $Q0 → $Q1 (≤ the soft tier 10) — the burst sent $(( $(field "$(info)" shipBurstBatches) - BB0 )) extra batches; pre-fix one batch of 5 left 25"
else nok "one tick drained only to $Q1 — the drain is still one fixed batch per tick (the finding)" "queue $Q0 → $Q1"; fi
adm setTestShipShedBands '(null)' >/dev/null                       # real tier (50k) — a tiny queue is BELOW it
i=0; while [ $i -lt 10 ]; do u withdraw "(\"ICPUSD\", $((10 * E8)) : nat, \"xc-quiet-$i\")" >/dev/null 2>&1; i=$((i+1)); done
Q2=$(field "$(info)" journalUnshipped)
Q3=$(adm adminForceShipTick '()' | tr -d '_' | grep -oE '[0-9]+' | head -1)
[ "$((Q2 - ${Q3:-0}))" -eq 5 ] && ok "below the soft tier one tick drains exactly one batch ($Q2 → $Q3; a quiet venue is unchanged)" || nok "below-tier drain is not one batch" "queue $Q2 → $Q3"
restore
adm adminForceShipTick '()' >/dev/null 2>&1
ok "pins released, timers restored"

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_exit_coalesce ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_exit_coalesce ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
