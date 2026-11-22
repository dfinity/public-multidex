#!/bin/bash
# H-36 (F33, D4 (a′)) — pre-registration profile/preference records live in a
# HARD-CAPPED, self-expiring store: a flood of fresh principals never grows it
# past the cap (the least-recently-seen UNREGISTERED entry — index slot AND its
# profile/preferences — is evicted at write time); entries past the grace
# period are aged out by the heartbeat's `prereg` subtask with NO admin call;
# registration promotes the record to the permanent maps, where neither cap
# nor expiry ever touches it.
#
#   §0 the bound is observable: getPreRegStoreStats (anonymous query) reports
#      size / cap / counters; the default cap is the PREREG_CAP constant
#   §1 REAL principals through the live path (getMyProfile + setUserPreferences)
#      at cap 4: six fresh identities → size == 4; the two least-recently-seen
#      lost their preferences (defaults come back), the four newest kept
#      theirs; re-touching the newest never evicts itself (same username back)
#   §2 registration PROMOTES: the #dev faucet lifts one out (promoted +1, a
#      slot frees), a further flood leaves the registered user's profile and
#      preferences untouched, and a registered caller never re-enters the store
#   §3 AUTONOMOUS EXPIRY: grace 3 s, cadence 2 s — the store drains to 0 on the
#      heartbeat alone (this section makes no admin call between the bound-set
#      and the read), the breaker shows the `prereg` subtask healthy (streak 0),
#      the registered user survives, an unregistered one's preferences are gone
#   §4 THE MEASUREMENT (W5-19: a bound is a number, not a claim): synthetic
#      floods through the same insertion primitive, 3× the cap at cap 500 and
#      2× at cap 5,000 — size == cap both times, the permanent maps grew by at
#      most the cap, and the at-capacity insert cost is flat across a 10× cap
#      (O(log n) pops; an O(n) scan would be ≥ 10×); then expiry drains 5,000
#      entries at the per-tick budget within a minute, with no admin call
#   §5 adjacent: the H-30 gate still refuses an unregistered principal's
#      createMarginPool; a brand-new identity is admitted again after the
#      floods; the registered user's username is what it was in §1
#
# Needs #dev (setTestPreRegBounds, devSeedPreRegFlood, the faucet). State-
# light: no resetExchange; the bounds are restored on exit. Pre-fix RED: the
# stats/bounds methods do not exist and Map.size grows one record per keypair.

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
stats() { adm getPreRegStoreStats '()' --query | flat; }
sfld() { fld "$1" "$(stats)"; }
uname_of() { echo "$1" | grep -oE 'username = "[^"]+"' | head -1 | cut -d'"' -f2; }
hbfield() { adm getHbHealth '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "\"$2\"; record \{[^}]*" | grep -oE "$1 = [0-9]+" | awk '{print $3}'; }
gate_refused() { echo "$1" | grep -qiE "refus|inspect|403"; }
refused() { gate_refused "$1" || echo "$1" | grep -q "Registration required"; }
PREFS='(record { recentMarkets = vec { "ICP-ICPUSD" }; lastMarket = opt "ICP-ICPUSD" })'
# getUserPreferences is an UPDATE (not a query) in the pre-registration set;
# it reads only, so probing it never stamps the store.
has_prefs() { as "$1" getUserPreferences '()' | flat | grep -q 'ICP-ICPUSD'; }

[ "$(venue_posture)" = "dev" ] || skip_posture "test_h36_prereg_bound" "dev hooks (setTestPreRegBounds, devSeedPreRegFlood, the faucet)"

SUF="${RANDOM}$$"
# newid <tag> — a per-run virgin identity, name in $NEWID. A STATEMENT, never
# $(newid …): mdx_identity_new registers the delete through _scratch.sh's
# on_exit hook, which a command-substitution subshell would drop (hygiene §6ad/§6ae).
newid() { NEWID="h36_$1_$SUF"; mdx_identity_new "$NEWID"; }
# Whatever happens, the constants come back (the overrides are transient, but
# the next suite on this venue should not inherit a 4-entry cap).
on_exit "icp canister call --candid \"$MDX_CANDID\" --identity anonymous backend setTestPreRegBounds '(null, null, null)' >/dev/null 2>&1 || true"

echo "── §0 the bound is observable and the default cap is the constant ──"
ST=$(stats)
echo "$ST" | grep -q "size = " && ok "getPreRegStoreStats answers anonymously (size present)" || nok "getPreRegStoreStats missing/failed — no bound is observable" "$(echo "$ST" | head -c 200)"
CAP0=$(fld cap "$ST")
[ "${CAP0:-0}" = "10000" ] && ok "default cap is PREREG_CAP = 10,000 (no override in force)" || nok "default cap reads ${CAP0:-none} (expected 10000 — an earlier suite left an override, or the constant moved: update this pin with it)" "$ST"
adm setTestPreRegBounds '(null, null, null)' >/dev/null

echo "── §1 six REAL principals through the live path at cap 4 → size 4, LRU two lose their drafts ──"
R=$(adm setTestPreRegBounds '(opt (4 : nat), null, null)')
echo "$R" | grep -q "()" && ok "cap pinned to 4 (setTestPreRegBounds)" || nok "setTestPreRegBounds failed" "$(echo "$R" | head -c 200)"
S0=$(sfld size); E0=$(sfld evicted)
[ "${S0:-99}" -le 4 ] && ok "a lowered cap is applied at once (size $S0 ≤ 4)" || nok "store over the cap right after lowering it ($S0 > 4)" ""
US=""; UN=""
for i in 1 2 3 4 5 6; do
  newid "u$i"; US="$US $NEWID"
  R=$(as "$NEWID" getMyProfile '()')
  N=$(uname_of "$R"); [ -n "$N" ] || nok "u$i: getMyProfile returned no username" "$(echo "$R" | head -c 200)"
  UN="$UN $N"
  as "$NEWID" setUserPreferences "$PREFS" >/dev/null
done
U1=$(echo $US | awk '{print $1}'); U2=$(echo $US | awk '{print $2}'); U5=$(echo $US | awk '{print $5}'); U6=$(echo $US | awk '{print $6}')
N6=$(echo $UN | awk '{print $6}')
S1=$(sfld size); E1=$(sfld evicted)
[ "${S1:-99}" = "4" ] && ok "after 6 fresh principals the store holds exactly the cap (size 4)" || nok "store size $S1 after 6 fresh principals at cap 4 — the count is unbounded (F33)" "$(stats)"
[ $(( ${E1:-0} - ${E0:-0} )) -ge 2 ] && ok "≥ 2 evictions recorded ($E0 → $E1)" || nok "evictions $E0 → $E1 (expected ≥ 2)" ""
has_prefs "$U1" && nok "u1 (least-recently-seen) still holds its preferences — nothing was evicted" "" || ok "u1's preferences were evicted with its slot (defaults come back)"
has_prefs "$U2" && nok "u2 still holds its preferences" "" || ok "u2's preferences were evicted too"
has_prefs "$U5" && ok "u5 (recent) kept its preferences" || nok "u5 lost its preferences — eviction is not least-recently-seen first" ""
has_prefs "$U6" && ok "u6 (newest) kept its preferences" || nok "u6 lost its preferences" ""
R=$(as "$U6" getMyProfile '()')
[ "$(uname_of "$R")" = "$N6" ] && ok "re-touching the newest entry returns the SAME profile (a write never evicts its own caller)" || nok "u6's username changed on re-touch ($N6 → $(uname_of "$R"))" ""
[ "$(sfld size)" = "4" ] && ok "a re-touch does not grow the store (size 4)" || nok "size moved on a re-touch" "$(stats)"
# An evicted principal that comes back is admitted again — with a fresh draft.
R=$(as "$U1" getMyProfile '()')
[ -n "$(uname_of "$R")" ] && ok "an evicted principal is served again on return (fresh profile — the accepted degradation)" || nok "an evicted principal cannot get a profile any more" "$(echo "$R" | head -c 200)"
[ "$(sfld size)" = "4" ] && ok "…and the store is still exactly at the cap" || nok "size left the cap on re-entry" "$(stats)"

echo "── §2 registration PROMOTES: the record leaves the bounded store and is untouchable afterwards ──"
P0=$(sfld promoted)
R=$(as "$U6" addTestTokens '("ICPUSD", 10_000_000_000_000 : nat)')
gate_refused "$R" && nok "the #dev faucet was refused for u6" "$(echo "$R" | head -c 200)" || ok "u6 registered through the #dev faucet"
P1=$(sfld promoted)
[ $(( ${P1:-0} - ${P0:-0} )) -eq 1 ] && ok "promoted counter +1 ($P0 → $P1)" || nok "promoted $P0 → $P1 (expected +1)" ""
[ "$(sfld size)" = "3" ] && ok "promotion freed u6's slot (size 3)" || nok "size after promotion $(sfld size) (expected 3)" ""
VS=""
for i in 1 2 3 4 5; do newid "v$i"; VS="$VS $NEWID"; as "$NEWID" getMyProfile '()' >/dev/null; as "$NEWID" setUserPreferences "$PREFS" >/dev/null; done
V5=$(echo $VS | awk '{print $5}')
[ "$(sfld size)" = "4" ] && ok "a further flood of 5 fills back to the cap (size 4), not past it" || nok "size $(sfld size) after the second flood" ""
has_prefs "$U6" && ok "the REGISTERED user's preferences survived the flood" || nok "the registered user's preferences were evicted — promotion did not protect the record" ""
R=$(as "$U6" getMyProfile '()')
[ "$(uname_of "$R")" = "$N6" ] && ok "the registered user's username is unchanged ($N6)" || nok "registered user's profile was replaced ($N6 → $(uname_of "$R"))" ""
[ "$(sfld size)" = "4" ] && ok "a registered caller's getMyProfile does not re-enter the store (size 4)" || nok "a registered call moved the store size" "$(stats)"

echo "── §3 AUTONOMOUS EXPIRY on the heartbeat: grace 3 s, cadence 2 s, no admin call ──"
X0=$(sfld expired)
adm setTestPreRegBounds '(opt (4 : nat), opt (3_000_000_000 : int), opt (2_000_000_000 : int))' >/dev/null
# From here to the size read: QUERIES ONLY. The drain below is the heartbeat's.
if wait_for '[ "$(sfld size)" = "0" ]' 45 2; then ok "the store drained to 0 on the heartbeat alone (grace 3 s)"; else nok "store still holds $(sfld size) after 45 s — expiry is not running autonomously" "$(stats)"; fi
X1=$(sfld expired)
[ $(( ${X1:-0} - ${X0:-0} )) -ge 4 ] && ok "≥ 4 expiries recorded ($X0 → $X1)" || nok "expired $X0 → $X1 (expected ≥ 4)" ""
D=$(hbfield dispatches prereg); SK=$(hbfield streak prereg)
[ "${D:-0}" -gt 0 ] && ok "the 'prereg' heartbeat subtask dispatched ($D)" || nok "no 'prereg' subtask in getHbHealth — expiry is not a heartbeat job" ""
[ "${SK:-1}" = "0" ] && ok "'prereg' streak is 0 (no lost run — the step never trapped)" || nok "'prereg' streak is $SK" "the step trapped"
has_prefs "$V5" && nok "an unregistered principal's preferences survived past the grace" "" || ok "an unregistered principal's preferences were aged out"
has_prefs "$U6" && ok "the REGISTERED user's preferences survived expiry" || nok "expiry removed a registered user's preferences" ""
R=$(as "$U6" getMyProfile '()')
[ "$(uname_of "$R")" = "$N6" ] && ok "the registered user's profile survived expiry ($N6)" || nok "expiry replaced a registered user's profile" ""

echo "── §4 THE MEASUREMENT: synthetic floods at cap 500 and cap 5,000 — size == cap, growth ≤ cap, flat insert cost ──"
adm setTestPreRegBounds '(opt (500 : nat), opt (3_600_000_000_000 : int), opt (2_000_000_000 : int))' >/dev/null
PR0=$(sfld profiles)
R=$(adm devSeedPreRegFlood "(1_500 : nat, $RANDOM : nat)" | flat)
SZ=$(fld size "$R"); IA=$(fld lastInsertInstr "$R")
[ "${SZ:-0}" = "500" ] && ok "1,500 synthetic fresh principals at cap 500 → size 500 (in-message)" || nok "size $SZ after a 3× flood at cap 500" "$(echo "$R" | head -c 200)"
PR1=$(sfld profiles)
[ $(( ${PR1:-0} - ${PR0:-0} )) -le 500 ] && ok "userProfiles grew by at most the cap (+$(( ${PR1:-0} - ${PR0:-0} )) ≤ 500) under a 1,500-principal flood" || nok "userProfiles grew by $(( ${PR1:-0} - ${PR0:-0} )) > 500 — the permanent map is not bounded by the cap" ""
adm setTestPreRegBounds '(opt (5_000 : nat), opt (3_600_000_000_000 : int), opt (2_000_000_000 : int))' >/dev/null
R=$(adm devSeedPreRegFlood "(10_000 : nat, $RANDOM : nat)" | flat)
SZ=$(fld size "$R"); IB=$(fld lastInsertInstr "$R")
[ "${SZ:-0}" = "5000" ] && ok "10,000 synthetic fresh principals at cap 5,000 → size 5,000" || nok "size $SZ after a 2× flood at cap 5,000" "$(echo "$R" | head -c 200)"
PR2=$(sfld profiles)
[ $(( ${PR2:-0} - ${PR0:-0} )) -le 5000 ] && ok "userProfiles grew by at most the cap (+$(( ${PR2:-0} - ${PR0:-0} )) ≤ 5,000) across both floods" || nok "userProfiles grew by $(( ${PR2:-0} - ${PR0:-0} )) > 5,000" ""
# At-capacity insert cost: measured at 500 and at 5,000 entries. A pop-from-
# oldest is O(log n) — ~1.4× across this 10×; a scan for the oldest would be
# ≥ 10×. The pin is 4× (headroom for GC-slice noise a cold message carries).
if [ -n "$IA" ] && [ -n "$IB" ] && [ "$IA" -gt 0 ] && [ "$IB" -le $(( IA * 4 )) ]; then ok "at-capacity insert cost is flat across a 10× cap ($IA instr @500 → $IB instr @5,000, ≤ 4×)"
else nok "at-capacity insert cost scaled with the store ($IA @500 → $IB @5,000) — eviction walks the store" ""; fi
# Drain 5,000 at the per-tick budget (1,000) on a 2 s cadence: ~10 s + slack.
adm setTestPreRegBounds '(opt (5_000 : nat), opt (1_000_000_000 : int), opt (2_000_000_000 : int))' >/dev/null
if wait_for '[ "$(sfld size)" = "0" ]' 90 3; then ok "5,000 entries aged out on the heartbeat within 90 s (budgeted pops, no admin call)"; else nok "store still holds $(sfld size) after 90 s" "$(stats)"; fi
PR3=$(sfld profiles)
[ "${PR3:-99999}" -le "${PR0:-0}" ] && ok "userProfiles is back to its pre-flood size ($PR0 → $PR3): no synthetic residue" || nok "userProfiles $PR0 → $PR3 after the drain — residue survives" ""
SK=$(hbfield streak prereg)
[ "${SK:-1}" = "0" ] && ok "'prereg' streak still 0 after draining 5,000" || nok "'prereg' streak $SK after the drain" ""

echo "── §5 adjacent: the H-30 gate is unchanged, admission resumes, the registered user is intact ──"
adm setTestPreRegBounds '(null, null, null)' >/dev/null
[ "$(sfld cap)" = "10000" ] && ok "bounds restored to the constants (cap 10,000)" || nok "cap after restore: $(sfld cap)" ""
newid w; W=$NEWID
R=$(as "$W" createMarginPool '("h36", false)')
if refused "$R" && ! mdx_ok "$R"; then ok "H-30: an unregistered principal's createMarginPool is still refused"; else nok "createMarginPool admitted an unregistered principal" "$(echo "$R" | head -c 200)"; fi
R=$(as "$W" getMyProfile '()')
[ -n "$(uname_of "$R")" ] && ok "a brand-new identity is admitted to the store after the floods" || nok "getMyProfile failed for a fresh identity" "$(echo "$R" | head -c 200)"
R=$(as "$U6" getMyProfile '()')
[ "$(uname_of "$R")" = "$N6" ] && ok "the registered user's username is what it was in §1 ($N6)" || nok "registered user's profile changed by the end ($N6 → $(uname_of "$R"))" ""

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_h36_prereg_bound ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_h36_prereg_bound ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
