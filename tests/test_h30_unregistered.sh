#!/bin/bash
# H-30 (F37 + F43) — unregistered principals are admitted only to the
# pre-registration method set; state-writing methods require registration;
# dead-man fires are capped per pass; the five per-user pool scans use the
# owner index; the heat/risk scans count only pools that can carry a position.
#
#   §1 a FRESH unregistered principal: createMarginPool / cancelAllAfter /
#      an entry method / an exit-set method are all refused; the six
#      pre-registration methods reach their bodies; whyAmIRefused agrees
#      (admittedNow = false, exitsAdmitted = false, preRegistrationAdmitted =
#      true, preRegistrationMethods names the set); no pool residue
#   §2 under a raised shed floor the pre-registration set still passes and a
#      non-allowlisted update is shed (test_load_shed_exits pattern)
#   §3 registration (the #dev faucet, itself pre-registration on #dev) flips
#      the verdict: createMarginPool and cancelAllAfter reach #ok
#   §4 N ≫ cap due dead-man switches fire across beats: the fires land on ≥ 3
#      distinct beats (cap 2, six due), the `deadman` streak stays 0, an
#      order-less principal gets NO version bump, one holding an order does
#   §5 thousands of EMPTY pools owned by an unrelated identity: the four
#      per-user reads' instruction cost is unchanged (devSweepCostProbe) and
#      the heat map / risk summary do not report truncated. "Unchanged" is
#      pinned RELATIVE to the probe's negative control (`poolsWalk`, the naive
#      marginPools walk, ~3.2k instr/pool → ~19M at 6,000): a read may grow
#      by at most a tenth of what the walk grew by. A raw ±10% ratio flaked
#      on fresh venues (task 1788523970): a cold read's count carries GC
#      increment slices (a fixed ~20k, once 150k) that no walk explains and
#      no walk could hide in — a read that walks costs AT LEAST the walk.
#   §6 the operator prune removes the unregistered residue without touching
#      a registered user's pools, and the season survives
#
# Sizing: 6,000 empty pools are minted in ONE message by the #dev seeder
# (devSeedEmptyPools) — registry writes only, ~seconds — instead of 6,000
# createMarginPool calls (~hours). The dead-man cohort is six switches at a
# cap pinned to 2 (setTestDeadmanMaxFires), forced due in the same beat by
# setTestDeadmanDeadline, so "N ≫ cap" is 3× and deterministic.
# State-light: no resetExchange; the seeded pools are pruned in §6. Needs #dev.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
as()  { local id="$1"; shift; icp canister call --candid "$MDX_CANDID" --identity "$id" backend "$@" 2>&1; }
flat() { tr -d '\n' | tr -s ' '; }
# a named nat/int field out of a candid reply (underscores stripped)
fld() { echo "$2" | tr -d '_' | grep -oE "$1 = -?[0-9]+" | head -1 | grep -oE "\-?[0-9]+"; }
# The gate refusal is a pre-consensus ingress reject; the agent surfaces it
# with wording distinct from any candid body reply.
gate_refused() { echo "$1" | grep -qiE "refus|inspect|403"; }
# A refusal of either kind: the gate, or the body's registration guard.
refused() { gate_refused "$1" || echo "$1" | grep -q "Registration required"; }
body_reached() { ! gate_refused "$1" && echo "$1" | grep -qE "err|record|\(|[0-9]"; }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_h30_unregistered" "dev hooks (faucet, setTestShedFloor, devSeedEmptyPools, setTestDeadman*)"

SUF="${RANDOM}$$"
# newid <tag> — a per-run virgin identity, name in $NEWID. A STATEMENT, never
# $(newid …): mdx_identity_new registers the delete through _scratch.sh's
# on_exit hook, which a command-substitution subshell would drop (hygiene §6ad/§6ae).
newid() { NEWID="h30_$1_$SUF"; mdx_identity_new "$NEWID"; }

newid u; U=$NEWID; UP=$(principal_of "$U")

echo "── §1 a fresh unregistered principal reaches the pre-registration set and nothing else ──"
WHY=$(as "$U" whyAmIRefused '()' --query | flat)
echo "$WHY" | grep -q "registered = false" && ok "fresh principal is unregistered" || nok "identity already registered — rerun with a fresh store" "$WHY"

R=$(as "$U" createMarginPool '("h30", false)')
if refused "$R" && ! mdx_ok "$R"; then ok "createMarginPool refused for an unregistered principal"; else nok "createMarginPool ADMITTED an unregistered principal (F37: a permanent registry record per keypair)" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" cancelAllAfter '(opt (60 : nat))')
if refused "$R" && ! mdx_ok "$R"; then ok "cancelAllAfter refused for an unregistered principal"; else nok "cancelAllAfter ADMITTED an unregistered principal (F43: the dead-man switch armable by throwaways)" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" placeLimitOrder '("ICP-ICPUSD", variant { buy }, 100_000_000 : nat, 1_000_000_000 : nat)')
if gate_refused "$R"; then ok "adjacent: an ENTRY method (placeLimitOrder) is refused at the gate"; else nok "placeLimitOrder reached its body for an unregistered principal" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" cancelMyOrder '(999_999_999 : nat)')
if gate_refused "$R"; then ok "adjacent: an EXIT-SET method (cancelMyOrder) is refused too — the exit exemption is for registered callers under the floor, not a door for unknown principals"; else nok "cancelMyOrder reached its body for an unregistered principal" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" aiComplete '("hi")')
if refused "$R" && ! mdx_ok "$R"; then ok "adjacent: aiComplete refused (the shared registration guard's third site)"; else nok "aiComplete admitted an unregistered principal" "$(echo "$R" | head -c 200)"; fi

R=$(as "$U" getMyProfile '()')
if ! gate_refused "$R" && echo "$R" | grep -q "username"; then ok "getMyProfile reaches its body (pre-registration set)"; else nok "getMyProfile refused — the frontend's sign-in surface is broken" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" getUserPreferences '()')
if body_reached "$R"; then ok "getUserPreferences reaches its body"; else nok "getUserPreferences refused" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" setUserPreferences '(record { lastMarket = opt "ICP-ICPUSD"; recentMarkets = vec { "ICP-ICPUSD" } })')
if ! gate_refused "$R" && echo "$R" | grep -q "()"; then ok "setUserPreferences reaches its body"; else nok "setUserPreferences refused" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" regenerateUsername '()')
if body_reached "$R"; then ok "regenerateUsername reaches its body"; else nok "regenerateUsername refused" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" _internet_identity_sign_in_start '()')
if ! gate_refused "$R"; then ok "_internet_identity_sign_in_start reaches its body (nonce mint)"; else nok "II sign-in start refused" "$(echo "$R" | head -c 200)"; fi

WHY=$(as "$U" whyAmIRefused '()' --query | flat)
echo "$WHY" | grep -q "admittedNow = false" && ok "whyAmIRefused: admittedNow = false (sheddable updates need registration)" || nok "diagnostic says an unregistered principal is admitted to order entry" "$WHY"
echo "$WHY" | grep -q "exitsAdmitted = false" && ok "whyAmIRefused: exitsAdmitted = false (nothing to exit before registration)" || nok "diagnostic says exits admitted for an unregistered principal while the gate refused cancelMyOrder" "$WHY"
echo "$WHY" | grep -q "preRegistrationAdmitted = true" && ok "whyAmIRefused: preRegistrationAdmitted = true" || nok "diagnostic lacks/denies preRegistrationAdmitted" "$WHY"
PR_MISSING=""
for m in getMyProfile setUserPreferences getUserPreferences regenerateUsername _internet_identity_sign_in_start _internet_identity_sign_in_finish; do
  echo "$WHY" | grep -q "\"$m\"" || PR_MISSING="$PR_MISSING $m"
done
[ -z "$PR_MISSING" ] && ok "whyAmIRefused: preRegistrationMethods names the six" || nok "preRegistrationMethods is missing$PR_MISSING" "$WHY"
R=$(as "$U" getMyMarginPools '()' --query | flat)
[ "$R" = "(vec {})" ] && ok "no pool residue for the refused principal" || nok "the refused principal owns pools" "$R"

echo "── §2 under a raised floor: the pre-registration set passes, everything else is shed ──"
adm setTestShedFloor '(opt (4 : nat))' >/dev/null
R=$(as "$U" getMyProfile '()')
if ! gate_refused "$R" && echo "$R" | grep -q "username"; then ok "floor 4: getMyProfile still reaches its body"; else nok "floor 4 shed the pre-registration set" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" createMarginPool '("h30", false)')
if refused "$R"; then ok "floor 4: createMarginPool refused"; else nok "floor 4: createMarginPool admitted" "$(echo "$R" | head -c 200)"; fi
R=$(as "$U" placeLimitOrder '("ICP-ICPUSD", variant { buy }, 100_000_000 : nat, 1_000_000_000 : nat)')
if gate_refused "$R"; then ok "floor 4: placeLimitOrder shed at the gate"; else nok "floor 4: placeLimitOrder admitted" "$(echo "$R" | head -c 200)"; fi
adm setTestShedFloor '(null)' >/dev/null

echo "── §3 registration flips the verdict ──"
R=$(as "$U" addTestTokens '("ICPUSD", 10_000_000_000_000 : nat)')
if ! gate_refused "$R"; then ok "the #dev faucet is reachable pre-registration (it IS the dev registration path)"; else nok "faucet refused at the gate — no identity can register on #dev" "$(echo "$R" | head -c 200)"; fi
WHY=$(as "$U" whyAmIRefused '()' --query | flat)
echo "$WHY" | grep -q "registered = true" && ok "faucet registered the caller" || nok "not registered after the faucet" "$WHY"
echo "$WHY" | grep -q "admittedNow = true" && ok "whyAmIRefused: admittedNow = true once registered" || nok "registered principal still reads refused" "$WHY"
R=$(as "$U" createMarginPool '("h30", false)')
if mdx_ok "$R"; then ok "createMarginPool #ok once registered"; else nok "createMarginPool refused a registered principal" "$(echo "$R" | head -c 200)"; fi
UPOOLS0=$(as "$U" getMyMarginPools '()' --query | flat | grep -o "id = " | wc -l | tr -d ' ')
R=$(as "$U" cancelAllAfter '(opt (60 : nat))')
if mdx_ok "$R"; then ok "cancelAllAfter #ok once registered"; else nok "cancelAllAfter refused a registered principal" "$(echo "$R" | head -c 200)"; fi
as "$U" cancelAllAfter '(null)' >/dev/null

echo "── §4 N ≫ cap due dead-man switches fire across beats, streak 0, no bump without orders ──"
hbfield() { adm getHbHealth '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "\"$2\"; record \{[^}]*" | grep -oE "$1 = [0-9]+" | awk '{print $3}'; }
DM=""
for i in 1 2 3 4 5 6; do newid "d$i"; DM="$DM $NEWID"; done
for n in $DM; do as "$n" addTestTokens '("ICPUSD", 10_000_000_000_000 : nat)' >/dev/null; done
D1=$(echo $DM | awk '{print $1}'); D6=$(echo $DM | awk '{print $6}')
# D6 holds an order: the fire must cancel it and bump D6's version; D1 holds none.
R=$(as "$D6" placeLimitOrder '("ICP-ICPUSD", variant { buy }, 100_000_000 : nat, 1_000_000_000 : nat)')
mdx_ok "$R" && ok "D6 placed a resting/staged order" || nok "D6 could not place an order" "$(echo "$R" | head -c 200)"
V1_0=$(fld version "$(as "$D1" getUserStatus '()' --query)")
V6_0=$(fld version "$(as "$D6" getUserStatus '()' --query)")
T0=$(fld lastHeartbeatNs "$(adm getCanisterInfo '()' --query)")
for n in $DM; do R=$(as "$n" cancelAllAfter '(opt (3600 : nat))'); mdx_ok "$R" || nok "arming $n failed" "$(echo "$R" | head -c 150)"; done
R=$(adm setTestDeadmanMaxFires '(opt (2 : nat))')
echo "$R" | grep -q "()" && ok "cap pinned to 2 (setTestDeadmanMaxFires)" || nok "setTestDeadmanMaxFires failed" "$(echo "$R" | head -c 200)"
for n in $DM; do
  P=$(icp identity principal --identity "$n" 2>/dev/null | tail -1)
  R=$(adm setTestDeadmanDeadline "(principal \"$P\", 1 : int)")
  echo "$R" | grep -q "()" || nok "setTestDeadmanDeadline failed for $n" "$(echo "$R" | head -c 150)"
done
# wait until every switch has fired (cap 2 → three beats)
armed=6; i=0
while [ "$armed" -gt 0 ] && [ "$i" -lt 30 ]; do
  sleep 1; armed=0
  for n in $DM; do as "$n" getMyCancelAllAfter '()' --query | grep -q "record" && armed=$((armed+1)); done
  i=$((i+1))
done
[ "$armed" -eq 0 ] && ok "all six switches fired within ${i}s" || nok "$armed switch(es) still armed after ${i}s" "cap 2, six due"
EV=$(adm getRecentEvents '(400 : nat)' --query | tr -d '\n' | sed 's/record {/\
record {/g' | grep "order.deadman" | tr -d '_')
TS=$(echo "$EV" | grep -oE "ts = [0-9]+" | awk -v t0="${T0:-0}" '{ if ($3+0 >= t0+0) print $3 }')
NFIRE=$(echo "$TS" | grep -c . || true)
NBEATS=$(echo "$TS" | sort -u | grep -c . || true)
[ "${NFIRE:-0}" -ge 6 ] && ok "six dead-man fire events on the tape since T0 ($NFIRE)" || nok "expected ≥ 6 fire events since T0" "got $NFIRE: $(echo "$EV" | head -c 300)"
[ "${NBEATS:-0}" -ge 3 ] && ok "the fires span ≥ 3 distinct beats ($NBEATS) — the cap spread the cohort" || nok "the fires landed on $NBEATS beat(s) — an uncapped cohort fires in one message (F43)" "ts: $(echo $TS)"
ST=$(hbfield streak deadman)
[ "${ST:-0}" = "0" ] && ok "deadman streak is 0 (no lost run)" || nok "deadman streak rose to $ST" "the sweep trapped or was lost"
V1_1=$(fld version "$(as "$D1" getUserStatus '()' --query)")
[ "${V1_1:-x}" = "${V1_0:-y}" ] && ok "an order-less principal's version is untouched by the fire ($V1_0 → $V1_1): no userStatuses row per throwaway" || nok "order-less principal bumped $V1_0 → $V1_1 (a permanent userStatuses row per fired throwaway)" ""
V6_1=$(fld version "$(as "$D6" getUserStatus '()' --query)")
[ "${V6_1:-0}" -gt "${V6_0:-0}" ] 2>/dev/null && ok "adjacent: the principal that HELD an order was bumped ($V6_0 → $V6_1)" || nok "D6 held an order but was not bumped ($V6_0 → $V6_1)" ""
O6=$(as "$D6" getMyOrders '()' --query | flat)
[ "$O6" = "(vec {})" ] && ok "adjacent: D6's order was cancelled by the fire" || nok "D6 still has orders after the fire" "$O6"
adm setTestDeadmanMaxFires '(null)' >/dev/null

echo "── §5 thousands of empty pools: per-user read cost unchanged, heat/risk scans not truncated ──"
newid x; X=$NEWID; XP=$(principal_of "$X")
P1=$(adm devSweepCostProbe '()' --query | flat)
POOLS0=$(fld poolsTotal "$P1")
R=$(adm devSeedEmptyPools "(principal \"$XP\", 6_000 : nat)" | tr -d '_')
TOTAL=$(echo "$R" | grep -oE "[0-9]+" | head -1)
[ "${TOTAL:-0}" -ge 6000 ] && ok "6,000 empty pools seeded in one message (venue total $TOTAL)" || nok "devSeedEmptyPools failed" "$(echo "$R" | head -c 200)"
P2=$(adm devSweepCostProbe '()' --query | flat)
# The negative control grounds the tolerance: `poolsWalk` IS a marginPools
# walk, so its growth under the 6,000 pools is what one walk costs here and
# now. A read whose growth stays under a tenth of that did not walk (a
# walking read pays the whole walk, growth ≥ 1×); a tenth (~1.9M instr at
# 6,000 pools) still absorbs any GC-slice noise a cold read carries. The
# control must itself move — a probe build without it, or one where it did
# not grow, cannot ground anything and reds rather than passing vacuously.
W1=$(fld poolsWalk "$P1"); W2=$(fld poolsWalk "$P2")
WGROW=$(( ${W2:-0} - ${W1:-0} ))
if [ -n "$W1" ] && [ -n "$W2" ] && [ "$WGROW" -ge 600000 ]; then ok "negative control: the naive marginPools walk moved with the pool count ($W1 → $W2 instr, +$WGROW)"
else nok "negative control did not move ($W1 → $W2 instr) — poolsWalk missing (build predates 1788523970?) or the walk stopped walking; the read pins below are ungrounded" ""; fi
TOL=$(( WGROW / 10 ))
for f in myMarginPools myPositionFills myPoolLiquidations myArchivePrincipals; do
  A=$(fld "$f" "$P1"); B=$(fld "$f" "$P2")
  G=$(( ${B:-0} - ${A:-0} )); [ "$G" -lt 0 ] && G=0
  if [ -n "$A" ] && [ -n "$B" ] && [ "$WGROW" -ge 600000 ] && [ "$G" -le "$TOL" ]; then ok "$f cost unchanged by 6,000 unrelated pools ($A → $B instr, +$G ≤ walk/10 = $TOL)"
  else nok "$f cost moved with the GLOBAL pool count ($A → $B instr, +$G > walk/10 = $TOL) — the read still walks marginPools" ""; fi
done
adm devTickHeatmaps '()' >/dev/null
HM=$(adm getMarginHeatmap '("BTC-ICPUSD")' --query | flat)
echo "$HM" | grep -q "truncated = false" && ok "heat map not truncated with $TOTAL pools (empty pools do not count toward HEAT_MAX_POOLS)" || nok "heat map truncated by EMPTY pools" "$(echo "$HM" | grep -oE 'truncated = [a-z]+')"
RS=$(adm getMarginRiskSummary '()' --query | flat)
echo "$RS" | grep -q "truncated = false" && ok "risk summary not truncated" || nok "risk summary truncated by EMPTY pools" "$(echo "$RS" | grep -oE 'truncated = [a-z]+')"

echo "── §6 the operator prune removes the unregistered residue and nothing else ──"
# The prune is bounded per call (PRUNE_MAX_POOLS examined; more = true means
# call again) — loop it, summing, as an operator would.
PRUNED=0; CALLS=0; MORE=true
while [ "$MORE" = "true" ] && [ "$CALLS" -lt 12 ]; do
  R=$(adm adminPruneUnregisteredResidue '()' | tr -d '_' | flat)
  N=$(fld pools "$R"); PRUNED=$(( PRUNED + ${N:-0} )); CALLS=$((CALLS+1))
  echo "$R" | grep -q "more = true" && MORE=true || MORE=false
  echo "$R" | grep -q "pools = " || { nok "adminPruneUnregisteredResidue failed" "$(echo "$R" | head -c 200)"; break; }
done
[ "${PRUNED:-0}" -ge 6000 ] && ok "prune removed the 6,000 empty pools of the unregistered owner (pools = $PRUNED over $CALLS bounded call(s))" || nok "prune removed $PRUNED pools" "$R"
[ "$MORE" = "false" ] && ok "prune reports more = false once the walk completes" || nok "prune still reports more = true after $CALLS calls" ""
P3=$(adm devSweepCostProbe '()' --query | flat)
POOLS3=$(fld poolsTotal "$P3")
# before + seeded − pruned = after (an earlier run's un-pruned residue is
# pruned too, so "back to POOLS0" would be the wrong identity)
EXPECT3=$(( ${POOLS0:-0} + 6000 - ${PRUNED:-0} ))
[ "${POOLS3:-x}" = "$EXPECT3" ] && ok "venue pool count reconciles: $POOLS0 + 6000 − $PRUNED = $POOLS3" || nok "pool count $POOLS0 + 6000 − $PRUNED ≠ $POOLS3 after prune" ""
[ "${POOLS3:-999999}" -le "${POOLS0:-0}" ] && ok "no unregistered residue survives ($POOLS3 ≤ $POOLS0)" || nok "pool count grew across seed+prune ($POOLS0 → $POOLS3)" ""
UPOOLS1=$(as "$U" getMyMarginPools '()' --query | flat | grep -o "id = " | wc -l | tr -d ' ')
[ "$UPOOLS1" = "$UPOOLS0" ] && ok "the registered user's pool survived the prune ($UPOOLS0)" || nok "registered user's pools $UPOOLS0 → $UPOOLS1" ""
XPOOLS=$(as "$X" getMyMarginPools '()' --query | flat)
[ "$XPOOLS" = "(vec {})" ] && ok "the unregistered owner has no pools left" || nok "unregistered owner still owns pools" "${XPOOLS:0:120}"
POOLS_AMM=$(adm getAmmPools '()' --query | grep -c "baseToken" || true)
[ "${POOLS_AMM:-0}" -ge 1 ] && ok "the season survived the prune (AMM pools intact: $POOLS_AMM)" || nok "AMM pools gone after the prune — it wiped the venue" ""
adm devTickHeatmaps '()' >/dev/null

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_h30_unregistered ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_h30_unregistered ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
