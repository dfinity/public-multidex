#!/bin/bash
# W4-24 (R5(c)) — the graceful unfunded-maker cancel is REPORTED, and the
# fill walks on.
#
# Resting orders hold no reservation (documented design), so a maker whose
# balance moved can be resting unfunded. Every fill path re-checks and
# cancels such makers GRACEFULLY (no solvency hole — the taker walks to the
# next level), but the cancel used to be SILENT — against the "never silent"
# doctrine that cancelPoolRestingOrder and cancelSelfMaker both follow. The
# engine now reports through ProtectionCtx.onUnfundedMaker and the owner
# gets a release-rejection notice.
#
#   §1 fresh pool; maker rests a bid AT ref (inside the AMM spread)
#   §2 maker's backing balance is drained (setTestBalance 0)
#   §3 a taker sell crosses: the maker's order is cancelled GRACEFULLY, the
#      taker's fill continues to the AMM bid behind it
#   §4 the maker's getMyReleaseRejections gained the mid-match notice
#
# H-10 (F13, hardening plan 2026-09) — the one fill path that RE-RESTED an
# unfunded maker instead of removing it: ammSweepResting cancels a crossing
# resting order and re-submits it as the aggressor; pre-fix an aggressor that
# could not fund its slice broke the walk silently and re-created the full
# quantity under a fresh id with the ORIGINAL timestamp, so every requote
# (~2 s) re-swept it — cancel/create churn, a stagedReleasedAs link per
# cycle, a permanent #orderClosed row per reaper pass, forever.
#   §5 an unfunded CROSSING bid is removed on its FIRST sweep: nothing
#      re-rests, exactly ONE notice, the handle resolves to a closed order,
#      two more requotes add nothing, and the reaper seals exactly ONE closure
#   §6 a HALF-funded crossing bid fills the funded half and drops the rest
#      (one notice, one adjustment-free cancel, no re-rest)
#   §7 balance-reducing actions re-validate the resting book: stakeInsurance
#      shrinks a bid to what remains, then a spend-all stake cancels it;
#      fundMarginPool (whole wallet) cancels; depositLp (quote leg) shrinks
#
# Venue physics — the release gate is PRICE-FRESHNESS, not a delay: a staged
# entry releases only once a fresh ref price POSTDATES it (anti-snipe,
# processDeferred: d.ts < refPriceUpdatedNs). With timers paused there is no
# GEPTOR keeper to fetch one, so the test RE-STAMPS setAmmRefPrice (same
# price — the dev override, which also clears any pending-jump entry) before
# each releasing requote. The first red-cycle of this fixture stalled with
# both orders staged-open because it slept for the mythical "~2s anti-free-
# look" instead of re-stamping — getMyOrders shows staged entries too, so
# the §1 "rests" check even passed. getMyStagedOrderIds is the discriminator.
# Needs #dev. ⚠️ resetExchange for a deterministic book.

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
mdx_identity_new ufm_m; M=$(principal_of ufm_m); mdx_identity_new ufm_t; T=$(principal_of ufm_t)

STOPPER="$SCRIPT_DIR/../scripts/stop_bots_local.sh"
[ -f "$STOPPER" ] && { bash "$STOPPER" >/dev/null 2>&1 || true; sleep 2; }
adm resetExchange "()" >/dev/null 2>&1 || true
adm setTestTimersPaused '(true)' >/dev/null 2>&1
mdx_identity_new ufm_seed; SEED=$(principal_of ufm_seed)
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmConfig "(\"ICP-ICPUSD\", 20:nat, $(e8 300.0) : nat, 5:nat, 10:nat)" >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICP\", $(e8 20000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 300000.0) : nat)" >/dev/null
mdx_lp_deposit ufm_seed "ICP-ICPUSD" "$(e8 20000.0)" "$(e8 200000.0)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null

# ── H-10 helpers ──────────────────────────────────────────────────────
# first integer of a named field (underscore-stripped); "" when absent
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "[0-9]+$"; }
# OCCURRENCE counts (grep -o | wc -l), never `grep -c` — the CLI prints one
# record per line-group and `-c` counts LINES, so it saturates at 1 and the
# "exactly one" assertions below would pass on any positive count. Each
# pattern is a field that appears exactly once per record.
# §4's before/after pair (R0/R1) routes through notice_count for the same
# reason (task 1788520600 — hygiene §6aj pins the rule across tests/*.sh).
occ() { grep -o "$1" | wc -l | tr -d ' '; }
open_count()  { icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyOrders '()' --query | tr -d '_\n' | occ 'originalQuantity = '; }
notice_count(){ icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyReleaseRejections '()' --query | tr -d '\n' | occ 'mid-match'; }
closed_count(){ icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyClosedOrders '()' --query | tr -d '_\n' | occ 'closedAt = '; }
adj_count()   { icp canister call --candid "$MDX_CANDID" --identity "$1" backend getMyAdjustments '()' --query | tr -d '_\n' | occ 'oldQuantity = '; }
# rest a plain limit bid: place, re-stamp the SAME ref (fresh price postdates
# the entry), requote → releases → rests. Echoes the placement (staged) id.
rest_bid() {  # $1 identity, $2 price, $3 qty, $4 ref price to re-stamp
  local R; R=$(icp canister call --candid "$MDX_CANDID" --identity "$1" backend placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 "$2") : nat, $(e8 "$3") : nat)" 2>&1)
  adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 "$4") : nat)" >/dev/null
  adm requoteAmm '("ICP-ICPUSD")' >/dev/null
  fld id "$R"
}

echo "── §1 maker rests a bid AT ref (inside the spread) ──"
adm setTestBalance "(principal \"$M\", \"ICPUSD\", $(e8 20000.0) : nat)" >/dev/null
icp canister call --candid "$MDX_CANDID" --identity ufm_m backend placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 10.00) : nat, $(e8 1000.0) : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null   # re-stamp: fresh price postdates the entry
adm requoteAmm '("ICP-ICPUSD")' >/dev/null                           # → releases → rests
MO=$(icp canister call --candid "$MDX_CANDID" --identity ufm_m backend getMyOrders '()' --query | tr -d '_\n' | grep -c 'id = ')
STG=$(icp canister call --candid "$MDX_CANDID" --identity ufm_m backend getMyStagedOrderIds '()' --query | tr -d ' \n_')
if [ "${MO:-0}" -ge 1 ] && [ "$STG" = "(vec{})" ]; then ok "maker's bid RESTS at 10.00 (released — staged set empty; AMM bid ≈9.98, ask ≈10.02)"; else nok "maker's bid did not rest (fixture)" "open=$MO staged=$STG $(icp canister call --candid "$MDX_CANDID" --identity ufm_m backend getMyReleaseRejections '()' --query | tr -d '\n' | head -c 150)"; fi
R0=$(notice_count ufm_m)   # occurrence count: a line count over the one-line vec saturates at 1 (task 1788520600)

echo "── §2 the backing balance is drained out from under it ──"
adm setTestBalance "(principal \"$M\", \"ICPUSD\", 0 : nat)" >/dev/null
ok "maker balance forced to 0 (resting order holds no reservation, by design)"

echo "── §3 a taker crosses: graceful cancel, fill walks on ──"
adm setTestBalance "(principal \"$T\", \"ICP\", $(e8 2000.0) : nat)" >/dev/null
icp canister call --candid "$MDX_CANDID" --identity ufm_t backend placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 9.90) : nat, $(e8 500.0) : nat)" >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null   # re-stamp → the crossing sell releases
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
TT=$(icp canister call --candid "$MDX_CANDID" --identity ufm_t backend getMyTradesSinceId '(0 : nat, 5 : nat)' --query | tr -d '\n' | occ 'trade = record')
if [ "${TT:-0}" -ge 1 ]; then ok "taker filled anyway ($TT fill(s) — walked past the unfunded maker to real liquidity)"; else nok "taker did not fill (graceful-walk broken?)" "$(icp canister call --candid "$MDX_CANDID" --identity ufm_t backend getMyOrders '()' --query | tr -d '\n' | head -c 120)"; fi
MO2=$(icp canister call --candid "$MDX_CANDID" --identity ufm_m backend getMyOrders '()' --query | tr -d '_\n' | grep -c 'id = ' || true)
[ "${MO2:-9}" = "0" ] && ok "unfunded maker's order is off the book" || nok "unfunded order still resting" "open=$MO2"

echo "── §4 the owner got the notice (the W4-24 fix) ──"
R1=$(notice_count ufm_m)   # occurrence count (see R0)
if [ "${R1:-0}" -gt "${R0:-0}" ]; then
  ok "release-rejection notice recorded: 'cancelled mid-match — balance no longer covers it'"
else nok "cancel was SILENT (the finding — no notice recorded)" "before=$R0 after=$R1 $(icp canister call --candid "$MDX_CANDID" --identity ufm_m backend getMyReleaseRejections '()' --query | tr -d '\n' | head -c 150)"; fi

echo "── §5 H-10: an unfunded CROSSING bid is removed on its FIRST sweep ──"
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
mdx_identity_new ufm_x; X=$(principal_of ufm_x)
adm setTestBalance "(principal \"$X\", \"ICPUSD\", $(e8 30000.0) : nat)" >/dev/null
XID=$(rest_bid ufm_x 9.60 1100.0 10.0)
XO=$(open_count ufm_x); XS=$(icp canister call --candid "$MDX_CANDID" --identity ufm_x backend getMyStagedOrderIds '()' --query | tr -d ' \n_')
if [ "${XO:-0}" -ge 1 ] && [ "$XS" = "(vec{})" ] && [ -n "$XID" ]; then ok "bid 1100 @ 9.60 RESTS (placement id $XID; ask ≈10.02 — not crossing yet)"; else nok "§5 fixture: bid did not rest" "open=$XO staged=$XS id=$XID"; fi
adm setTestBalance "(principal \"$X\", \"ICPUSD\", 0 : nat)" >/dev/null
N0=$(notice_count ufm_x); C0=$(closed_count ufm_x)
ok "owner's whole balance moved out (notices=$N0 closed=$C0 before the sweep)"
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 9.40) : nat)" >/dev/null   # −6%: the 9.60 bid now crosses the fresh ask ≈9.42 → swept
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
XO1=$(open_count ufm_x); N1=$(notice_count ufm_x)
XT=$(icp canister call --candid "$MDX_CANDID" --identity ufm_x backend getMyTradesSinceId '(0 : nat, 5 : nat)' --query | tr -d '\n' | grep -c 'trade = record' || true)
[ "${XO1:-9}" = "0" ] && ok "swept unfunded bid is OFF the book — nothing re-rested" || nok "unfunded bid RE-RESTED after the sweep (the F13 loop)" "open=$XO1"
[ "${XT:-9}" = "0" ] && ok "no trade settled (nothing was fundable)" || nok "a trade settled for an unfunded owner" "trades=$XT"
[ "${N1:-0}" = "$((N0 + 1))" ] && ok "exactly ONE mid-match notice for the owner" || nok "notice count wrong (want $((N0 + 1)))" "before=$N0 after=$N1 $(icp canister call --candid "$MDX_CANDID" --identity ufm_x backend getMyReleaseRejections '()' --query | tr -d '\n' | tail -c 200)"
ST=$(icp canister call --candid "$MDX_CANDID" --identity ufm_x backend getMyOrderStatus "($XID : nat)" --query 2>&1 | tr -d '\n' | tr -s ' ')
if echo "$ST" | grep -q 'phase = variant { closed }' && echo "$ST" | grep -q 'status = variant { cancelled }'; then ok "the placement handle resolves to a CLOSED (#cancelled) order — not 'not found', not resting"; else nok "handle does not resolve to a cancelled order" "$(echo "$ST" | head -c 220)"; fi
for i in 1 2; do adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 9.40) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; done
XO2=$(open_count ufm_x); N2=$(notice_count ufm_x)
if [ "${XO2:-9}" = "0" ] && [ "${N2:-0}" = "$((N0 + 1))" ]; then ok "two more requotes: still off the book, still ONE notice (no churn)"; else nok "requotes keep churning the dead order" "open=$XO2 notices=$N2"; fi
adm devTickReap '()' >/dev/null 2>&1; adm devTickReap '()' >/dev/null 2>&1
C1=$(closed_count ufm_x)
CR=$(icp canister call --candid "$MDX_CANDID" --identity ufm_x backend getMyClosedOrders '()' --query | tr -d '_\n' | tr -s ' ')
if [ "${C1:-0}" = "$((C0 + 1))" ] && echo "$CR" | grep -q 'status = variant { cancelled }'; then ok "the reaper sealed exactly ONE closure (#cancelled) for the swept order"; else nok "closure count wrong (want $((C0 + 1)) — pre-fix each sweep cycle left one)" "before=$C0 after=$C1 $(echo "$CR" | head -c 200)"; fi

echo "── §6 H-10: a HALF-funded crossing bid fills what it can, drops the rest ──"
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
mdx_identity_new ufm_h; H=$(principal_of ufm_h)
adm setTestBalance "(principal \"$H\", \"ICPUSD\", $(e8 30000.0) : nat)" >/dev/null
HID=$(rest_bid ufm_h 9.60 1000.0 10.0)
[ "$(open_count ufm_h)" -ge 1 ] && ok "bid 1000 @ 9.60 rests (id $HID)" || nok "§6 fixture: bid did not rest" "$(icp canister call --candid "$MDX_CANDID" --identity ufm_h backend getMyOrders '()' --query | tr -d '\n' | head -c 150)"
adm setTestBalance "(principal \"$H\", \"ICPUSD\", $(e8 4000.0) : nat)" >/dev/null   # covers ≈424 ICP at the ≈9.42 sweep price, not 1000
HN0=$(notice_count ufm_h)
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 9.40) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
HROWS=$(icp canister call --candid "$MDX_CANDID" --identity ufm_h backend getMyTradesSinceId '(0 : nat, 5 : nat)' --query | tr -d '_\n' | tr -s ' ')
HT=$(echo "$HROWS" | occ 'trade = record'); HQ=$(fld quantity "$HROWS")
HB=$(adm getTestBalance "(principal \"$H\", \"ICPUSD\")" --query | tr -d '_' | grep -oE '[0-9]+' | head -1)
if [ "${HT:-0}" -ge 1 ] && [ -n "$HQ" ] && [ "$HQ" -gt 0 ] && [ "$HQ" -lt "$(e8 1000.0)" ]; then ok "the FUNDED part filled ($HT fill(s), qty $HQ base units < 1000 ICP) at the AMM's fresh ask"; else nok "half-funded sweep did not fill the fundable part" "trades=$HT qty=$HQ $(echo "$HROWS" | head -c 160)"; fi
[ "${HB:-999999}" -lt "$(e8 10.0)" ] && ok "owner's quote spent down to dust (< 10 ICPUSD left: $HB)" || nok "owner's quote not spent" "bal=$HB"
[ "$(open_count ufm_h)" = "0" ] && ok "the unfundable remainder is OFF the book (not re-rested)" || nok "remainder re-rested" "open=$(open_count ufm_h)"
[ "$(notice_count ufm_h)" = "$((HN0 + 1))" ] && ok "exactly ONE notice for the dropped remainder" || nok "notice count wrong" "before=$HN0 after=$(notice_count ufm_h)"

echo "── §7 H-10: balance-reducing actions re-validate the resting book ──"
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 10.0) : nat)" >/dev/null
adm requoteAmm '("ICP-ICPUSD")' >/dev/null
# (a) stakeInsurance — partial stake SHRINKS the bid, a spend-all stake CANCELS it
mdx_identity_new ufm_d; D=$(principal_of ufm_d)
adm setTestBalance "(principal \"$D\", \"ICPUSD\", $(e8 20000.0) : nat)" >/dev/null
DID=$(rest_bid ufm_d 9.50 1000.0 10.0)
[ "$(open_count ufm_d)" -ge 1 ] && ok "bid 1000 @ 9.50 (value 9500) rests (id $DID)" || nok "§7a fixture: bid did not rest" ""
DA0=$(adj_count ufm_d)
SR=$(icp canister call --candid "$MDX_CANDID" --identity ufm_d backend stakeInsurance "($(e8 15000.0) : nat)" 2>&1)
if mdx_ok "$SR"; then ok "stakeInsurance 15000 → wallet keeps 5000 (< the 9500 the bid needs)"; else nok "stakeInsurance refused (fixture)" "$SR"; fi
DO=$(icp canister call --candid "$MDX_CANDID" --identity ufm_d backend getMyOrders '()' --query | tr -d '_\n' | tr -s ' ')
DQ=$(fld quantity "$DO")
if [ -n "$DQ" ] && [ "$DQ" -gt 0 ] && [ "$DQ" -le "$(e8 526.32)" ]; then ok "the bid SHRANK to what 5000 covers at 9.50 (qty $DQ ≤ 526.32 ICP)"; else nok "bid not re-validated after the stake (want ≤ 526.32 ICP)" "qty=${DQ:-none} $(echo "$DO" | head -c 160)"; fi
DA1=$(adj_count ufm_d)
[ "${DA1:-0}" = "$((DA0 + 1))" ] && ok "one adjustment recorded (shrink, #balanceShrank)" || nok "adjustment not recorded" "before=$DA0 after=$DA1"
SR2=$(icp canister call --candid "$MDX_CANDID" --identity ufm_d backend stakeInsurance "($(e8 5000.0) : nat)" 2>&1)
if mdx_ok "$SR2"; then ok "spend-all stake of the remaining 5000 accepted"; else nok "spend-all stake refused (fixture)" "$SR2"; fi
[ "$(open_count ufm_d)" = "0" ] && ok "wallet empty → the bid is CANCELLED" || nok "bid still resting on an empty wallet" "open=$(open_count ufm_d) $(icp canister call --candid "$MDX_CANDID" --identity ufm_d backend getMyOrders '()' --query | tr -d '\n' | head -c 150)"
DA2=$(adj_count ufm_d)
DL=$(icp canister call --candid "$MDX_CANDID" --identity ufm_d backend getMyAdjustments '()' --query | tr -d '\n' | tr -s ' ')
if [ "${DA2:-0}" = "$((DA0 + 2))" ] && echo "$DL" | grep -q 'cancelled = true'; then ok "a cancel adjustment recorded (cancelled = true)"; else nok "cancel adjustment missing" "before=$DA1 after=$DA2 $(echo "$DL" | head -c 160)"; fi
# (b) fundMarginPool — moving the WHOLE wallet into a pool cancels the wallet's bid
mdx_identity_new ufm_f; F=$(principal_of ufm_f)
adm setTestBalance "(principal \"$F\", \"ICPUSD\", $(e8 20000.0) : nat)" >/dev/null   # (setTestBalance registers — createMarginPool needs it)
FID=$(rest_bid ufm_f 9.50 1000.0 10.0)
[ "$(open_count ufm_f)" -ge 1 ] && ok "bid 1000 @ 9.50 rests (id $FID)" || nok "§7b fixture: bid did not rest" ""
PR=$(icp canister call --candid "$MDX_CANDID" --identity ufm_f backend createMarginPool '("h10", false)' 2>&1); PID=$(fld ok "$PR")
FR=$(icp canister call --candid "$MDX_CANDID" --identity ufm_f backend fundMarginPool "(${PID:-0} : nat, $(e8 20000.0) : nat)" 2>&1)
if [ -n "$PID" ] && mdx_ok "$FR"; then ok "fundMarginPool moved the whole wallet into pool $PID"; else nok "fundMarginPool fixture" "pool=$PR fund=$FR"; fi
[ "$(open_count ufm_f)" = "0" ] && ok "wallet empty → the wallet's bid is CANCELLED" || nok "bid still resting after funding the pool with the whole wallet" "open=$(open_count ufm_f)"
# (c) depositLp — the quote leg leaving the wallet SHRINKS the bid
mdx_identity_new ufm_l; L=$(principal_of ufm_l)
adm setTestBalance "(principal \"$L\", \"ICPUSD\", $(e8 20000.0) : nat)" >/dev/null
LID=$(rest_bid ufm_l 9.50 1000.0 10.0)
[ "$(open_count ufm_l)" -ge 1 ] && ok "bid 1000 @ 9.50 rests (id $LID)" || nok "§7c fixture: bid did not rest" ""
# (staged door since apiVersion 6.0.0: the helper settles the request, and
# the settlement's mint is what moves the quote leg out of the wallet)
if LR=$(mdx_lp_deposit ufm_l "ICP-ICPUSD" 0 "$(e8 15000.0)"); then ok "depositLp took 15000 ICPUSD from the wallet at settlement (5000 left)"; else nok "depositLp refused (fixture — concentration cap?)" "$LR"; fi
LQ=$(fld quantity "$(icp canister call --candid "$MDX_CANDID" --identity ufm_l backend getMyOrders '()' --query | tr -d '_\n' | tr -s ' ')")
if [ -n "$LQ" ] && [ "$LQ" -gt 0 ] && [ "$LQ" -le "$(e8 526.32)" ]; then ok "the bid SHRANK to what 5000 covers (qty $LQ ≤ 526.32 ICP)"; else nok "bid not re-validated after the LP deposit" "qty=${LQ:-none}"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1
echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_unfunded_maker_notice ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_unfunded_maker_notice ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
