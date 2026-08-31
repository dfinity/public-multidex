#!/bin/bash
# W3-06 / W3-07 — the oracle pipeline judges time on OBSERVATION clocks.
#
# Three time-base defects, one pass:
#   · the jump breaker judged independence on continuation (arrival) clocks
#   · a >50bps candidate replacement reset the aging clock, so a sustained
#     move never confirmed (livelock) — fixed: same-direction keeps the clock
#   · the XRC anchor aged from OUR receipt, not XRC's pricing minute, and a
#     fallback-applied mark was re-stamped as instantaneous
#
# Driven deterministically through the XRC FALLBACK path: setTestMinSources
# forces the primary floor unreachable, so every fetchAndSetRefPrice routes
# the controllable setTestXrcRate anchor into the breaker.
#
#   §1 a fresh-RECEIVED anchor with an OLD XRC minute is refused by the gate
#   §2 a fallback-applied mark carries the anchor's age, not `now`
#   §3 livelock: a same-direction >50bps replacement keeps the aging clock,
#      so the follow-up confirms; a direction FLIP resets it, so it does not
#
# Needs #dev. Uses ICP-ICPUSD; restores min-sources and clears test anchors.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }
MKT="ICP-ICPUSD"

refpx() { adm getAmmPool "(\"$MKT\")" | tr -d '_\n' | tr -s ' ' | grep -oE "refPrice = [0-9]+" | head -1 | awk '{print $3}'; }
refns() { adm getAmmPool "(\"$MKT\")" | tr -d '_\n' | tr -s ' ' | grep -oE "refPriceUpdatedNs = [0-9-]+" | head -1 | awk '{print $3}'; }

adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
adm setAmmRefPrice "(\"$MKT\", $(e8 3.00) : nat)" >/dev/null   # P0, clears any pending
adm setTestMinSources '(opt (99 : nat))' >/dev/null            # primary floor unreachable → fallback path

echo "── §1 old XRC minute is refused even when just received ──"
adm setTestXrcRate "(\"ICP\", opt ($(e8 3.02) : nat), opt (400 : nat))" >/dev/null   # +0.7%, minute 400s old
R=$(adm fetchAndSetRefPrice "(\"$MKT\")")
P=$(refpx)
if [ "$P" = "$(e8 3.00)" ]; then ok "stale-minute anchor rejected (mark still 3.00)"; else nok "old anchor applied" "px=$P r=$(echo "$R" | head -c 150)"; fi
adm setTestXrcRate "(\"ICP\", opt ($(e8 3.02) : nat), opt (0 : nat))" >/dev/null     # same rate, current minute
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null
P=$(refpx)
if [ "$P" = "$(e8 3.02)" ]; then ok "current-minute anchor applies (mark → 3.02)"; else nok "fresh anchor refused" "px=$P"; fi

echo "── §2 the fallback mark carries the anchor's age ──"
adm setTestXrcRate "(\"ICP\", opt ($(e8 3.04) : nat), opt (60 : nat))" >/dev/null    # +0.7% again, minute 60s old
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null
P=$(refpx); NS=$(refns); NOW=$(date +%s)
if [ "$P" = "$(e8 3.04)" ]; then ok "60s-old anchor still admissible (inside the 180s window)"; else nok "anchor refused" "px=$P"; fi
AGE=$(( NOW - NS / 1000000000 ))
if [ "$AGE" -ge 50 ] && [ "$AGE" -le 90 ]; then
  ok "mark stamped with the anchor's age (refPriceUpdatedNs ≈ ${AGE}s old, not now)"
else nok "mark re-stamped as instantaneous" "age=${AGE}s (want ≈60)"; fi

echo "── §3 livelock: same-direction replacement keeps the aging clock ──"
adm setAmmRefPrice "(\"$MKT\", $(e8 3.00) : nat)" >/dev/null                          # reset P0, clear pending
adm setTestPendingJump "(\"ICP\", opt ($(e8 3.30) : nat), opt (35 : nat))" >/dev/null # +10% candidate, aged 35s
adm setTestXrcRate "(\"ICP\", opt ($(e8 3.33) : nat), opt (0 : nat))" >/dev/null      # >50bps from candidate, same direction
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null    # replacement — pre-fix this RESET the clock
R=$(adm fetchAndSetRefPrice "(\"$MKT\")")          # 3.33 vs candidate 3.33 confirms IF the clock survived
P=$(refpx)
if [ "$P" = "$(e8 3.33)" ]; then ok "sustained move confirms (clock survived the replacement)"; else nok "livelock: move never confirms (the finding)" "px=$P r=$(echo "$R" | head -c 150)"; fi

adm setAmmRefPrice "(\"$MKT\", $(e8 3.00) : nat)" >/dev/null
adm setTestPendingJump "(\"ICP\", opt ($(e8 3.30) : nat), opt (35 : nat))" >/dev/null # aged UP-candidate
adm setTestXrcRate "(\"ICP\", opt ($(e8 2.70) : nat), opt (0 : nat))" >/dev/null      # DOWN vs P0 — direction flip
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null    # replacement resets the clock (flip)
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null    # too soon — must NOT confirm
P=$(refpx)
if [ "$P" = "$(e8 3.00)" ]; then ok "direction flip resets the clock (down-move still unconfirmed)"; else nok "flip confirmed instantly" "px=$P"; fi

adm setTestPendingJump '("ICP", null, null)' >/dev/null 2>&1
adm setTestXrcRate '("ICP", null, null)' >/dev/null 2>&1
adm setTestMinSources '(null)' >/dev/null 2>&1

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_oracle_time_bases ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_oracle_time_bases ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
