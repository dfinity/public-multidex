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
#   §2 the fallback writer cannot REWIND the mark's clock (#55 "fallback clock
#      rewinds"): an admissible anchor whose pricing minute predates the
#      standing mark is refused, mark and clock untouched; once the mark is
#      older than the anchor it applies and carries the anchor's age (W3-07)
#   §3 livelock: a same-direction >50bps replacement keeps the aging clock,
#      so the follow-up confirms; a direction FLIP resets it, so it does not
#   §4 the oracle epoch is checked in the CALLEE (#55 "epoch guard on one
#      caller"): a bump landing while a fetch's fan-out is open leaves
#      lastAggregates untouched and the callee abandons it at finalization —
#      the window is STAGED (devStallSource #hold leaves the admin fetch's
#      fan-out OPEN to the 8 s deadline sweep; the brake pins the tick),
#      never raced against the feed
#   §5 H-23 (F27): the mark's RELEASE REFERENCE is the fetch's DISPATCH clock
#      — captured before the fan-out's first await, so it precedes the apply
#      and never exceeds the arrival stamp; the writers (aggregate and XRC
#      fallback alike) stamp it with the mark, and getReleaseInfo exposes it
#
# Needs #dev. Uses ICP-ICPUSD; restores min-sources and clears test anchors.

set -u
# The checked-in Candid contract for every backend call (--candid; the belt
# tests/_lib.sh gives its call() — this suite is standalone, so it names the
# file itself; task 1788512331).
MDX_CANDID="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/candid/backend.did"
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
MKT="ICP-ICPUSD"

refpx() { adm getAmmPool "(\"$MKT\")" | tr -d '_\n' | tr -s ' ' | grep -oE "refPrice = [0-9]+" | head -1 | awk '{print $3}'; }
refns() { adm getAmmPool "(\"$MKT\")" | tr -d '_\n' | tr -s ' ' | grep -oE "refPriceUpdatedNs = [0-9-]+" | head -1 | awk '{print $3}'; }
lastagg() { adm getLastAggregate '("ICP")' --query | tr -d '_\n' | tr -s ' ' | grep -oE "timestamp = [0-9]+" | head -1 | awk '{print $3}'; }
# Backdate the standing mark's clock by N seconds (the mark itself is kept).
backdate_mark() { adm setTestRefPriceUpdatedNs "(\"$MKT\", $(( ($(date +%s) - $1) * 1000000000 )) : int)" >/dev/null; }
# P0: stamp the mark at 3.00 (clears any pending jump) and pin its clock 5s
# into the past. The fallback writer refuses an anchor whose pricing SECOND is
# at or before the mark (§2), and a test-injected age-0 anchor's clock is
# floor(now) — a setAmmRefPrice stamp landing in the SAME second would read
# as a rewind and refuse a legitimately fresh anchor. Backdating pins the
# ordering instead of hoping two calls straddle a second boundary.
p0() { adm setAmmRefPrice "(\"$MKT\", $(e8 3.00) : nat)" >/dev/null; backdate_mark 5; }

# EXIT HYGIENE (task 1788541235): the 99-source floor, the test anchor and a
# pend are venue-global pins that outlive this suite — a failure path used
# to leave every later fetch on the venue rejected below the floor (marks
# frozen). This suite is standalone (no _lib.sh), so a plain EXIT trap is
# the right tool here; the success path's restores at the end stay.
trap 'adm setTestPendingJump "(\"ICP\", null, null)" >/dev/null 2>&1; adm setTestXrcRate "(\"ICP\", null, null)" >/dev/null 2>&1; adm setTestMinSources "(null)" >/dev/null 2>&1' EXIT
adm createAmmPool "(\"$MKT\")" >/dev/null 2>&1
p0
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

echo "── §2 the fallback writer cannot rewind the mark's clock (#55) ──"
# The mark stands at 3.02 with the clock of §1's current-minute anchor. A
# 60s-old anchor is inside the 180s admissibility window but its pricing
# minute PREDATES the standing mark. Pre-fix this section EXECUTED the rewind
# and asserted it: the anchor applied and moved the mark's clock back ~60s,
# after which a straggling primary sampled in between passes the W3-06 guard
# — the overwrite that guard refuses, reached through the other writer.
NS0=$(refns)
adm setTestXrcRate "(\"ICP\", opt ($(e8 3.04) : nat), opt (60 : nat))" >/dev/null    # +0.7% again, minute 60s old
R=$(adm fetchAndSetRefPrice "(\"$MKT\")")
P=$(refpx); NS=$(refns)
if [ "$P" = "$(e8 3.02)" ] && [ "$NS" = "$NS0" ]; then
  ok "older-minute anchor refused: mark 3.02 and its clock untouched"
else nok "the fallback rewound the mark (the finding)" "px=$P ns0=$NS0 ns=$NS"; fi
if echo "$R" | grep -q "at or before the current mark"; then ok "the refusal names the rewind"; else nok "unexpected result" "$(echo "$R" | head -c 150)"; fi
# Same anchor against an OLDER mark: once the standing clock predates the
# anchor's minute the anchor is admissible again — and the mark it writes
# carries the ANCHOR's age, not `now` (W3-07, kept).
backdate_mark 120
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null
P=$(refpx); NS=$(refns); NOW=$(date +%s)
if [ "$P" = "$(e8 3.04)" ]; then ok "60s-old anchor applies once it postdates the mark (inside the 180s window)"; else nok "anchor refused against an older mark" "px=$P"; fi
AGE=$(( NOW - NS / 1000000000 ))
if [ "$AGE" -ge 50 ] && [ "$AGE" -le 90 ]; then
  ok "mark stamped with the anchor's age (refPriceUpdatedNs ≈ ${AGE}s old, not now)"
else nok "mark re-stamped as instantaneous" "age=${AGE}s (want ≈60)"; fi

echo "── §3 livelock: same-direction replacement keeps the aging clock ──"
p0                                                                                    # reset P0, clear pending
adm setTestPendingJump "(\"ICP\", opt ($(e8 3.30) : nat), opt (35 : nat))" >/dev/null # +10% candidate, aged 35s
adm setTestXrcRate "(\"ICP\", opt ($(e8 3.33) : nat), opt (0 : nat))" >/dev/null      # >50bps from candidate, same direction
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null    # replacement — pre-fix this RESET the clock
R=$(adm fetchAndSetRefPrice "(\"$MKT\")")          # 3.33 vs candidate 3.33 confirms IF the clock survived
P=$(refpx)
if [ "$P" = "$(e8 3.33)" ]; then ok "sustained move confirms (clock survived the replacement)"; else nok "livelock: move never confirms (the finding)" "px=$P r=$(echo "$R" | head -c 150)"; fi

p0
adm setTestPendingJump "(\"ICP\", opt ($(e8 3.30) : nat), opt (35 : nat))" >/dev/null # aged UP-candidate
adm setTestXrcRate "(\"ICP\", opt ($(e8 2.70) : nat), opt (0 : nat))" >/dev/null      # DOWN vs P0 — direction flip
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null    # replacement resets the clock (flip)
adm fetchAndSetRefPrice "(\"$MKT\")" >/dev/null    # too soon — must NOT confirm
P=$(refpx)
if [ "$P" = "$(e8 3.00)" ]; then ok "direction flip resets the clock (down-move still unconfirmed)"; else nok "flip confirmed instantly" "px=$P"; fi

echo "── §4 the oracle epoch is checked in the callee: a bump mid-fetch writes nothing (#55) ──"
# W4-13 put the epoch compare in tickPriceRefresh AFTER refreshMultiSourcePrice
# had already written lastAggregates/_lastOracleSrc, and the GEPTOR and admin
# callers had no compare at all — so a wipe landing mid-fetch still cached the
# pre-wipe observation as the new venue's first aggregate. W4-13 could not
# stage the race (a wipe is timing) and pinned the structure in hygiene; the
# #dev hook devBumpOracleEpoch stages the epoch half alone: fire the admin
# fetch, bump the epoch while its 8-way fan-out is open, then assert the
# callee abandoned the result unwritten.
# The WINDOW is staged, not hoped for (task 1788544376 — this section used to
# sleep 1s and lost the race three times over on a warm feed; task 1788748485
# — the first #hold parked one self-call's RETURN in a self-message loop,
# which starved the local replica for the whole hold and cost 16s a run):
# devStallSource #hold makes ONE source record nothing AND makes the admin
# fetch leave its fan-out OPEN to the heartbeat's deadline sweep (8s) instead
# of draining it — the admin call returns at ~1.5s with a "left OPEN" err,
# the fan-out stays open on a responsive replica, and the sweep's
# finalization is where the callee's epoch compare runs (the outcome shows on
# devGetFanout as `abandoned: oracle epoch moved`). The timers brake pins the
# tick (the sweep runs above the pause gate, so the fan-out still closes at
# 8s), which makes the first fan-out newer than the last one seen the admin
# fetch's OWN; the bump lands once devGetFanout shows it open — anywhere in
# an 8s window, so one attempt is enough. A venue whose devStallSource lacks
# #hold (#play) cannot stage the window — it skips LOUDLY, never ✗ on timing.
adm setTestPendingJump '("ICP", null, null)' >/dev/null   # no anchor, no pend: a fetch that
adm setTestXrcRate '("ICP", null, null)' >/dev/null       # COMPLETES can only be refused (floor 99)
HOLD_SRC="kraken"
stall()       { adm devStallSource "(\"$HOLD_SRC\", variant { $1 })"; }
fanout_view() { adm devGetFanout '("ICP")' --query | tr -d '_\n' | tr -s ' '; }
fo_num()      { printf '%s' "$1" | grep -oE "$2 = [0-9]+" | head -1 | awk '{print $3}'; }
fo_open()     { printf '%s' "$1" | grep -oE "open = (true|false)" | head -1 | awk '{print $3}'; }
# The stall and the brake are venue-global: clear both at the section's end
# AND on any exit, so a red run cannot strand a held source or a braked tick
# for the suites that share this feed.
s4_teardown() { stall clear >/dev/null 2>&1; adm setTestTimersPaused '(false)' >/dev/null 2>&1; }
trap s4_teardown EXIT
HR=$(stall hold)
if [ "$(printf '%s' "$HR" | tr -d '[:space:]')" != "()" ]; then
  echo -e "  ⊘ skipped: §4 — devStallSource #hold is not on this venue ($(echo "$HR" | tr -d '\n' | head -c 90)); the epoch-bump window cannot be staged here"
else
  adm setTestTimersPaused '(true)' >/dev/null
  TMPD=$(mktemp -d); R=""; WIN=""
  T0=$(lastagg)
  ID0=$(fo_num "$(fanout_view)" id); ID0=${ID0:-0}
  S0=$(date +%s)
  adm fetchAndSetRefPrice "(\"$MKT\")" > "$TMPD/fetch" 2>&1 &
  FPID=$!
  # Wait for the fetch's own fan-out: newer than ID0 and open (left to the sweep).
  OPEN=0; FV=""; ID1=""
  while [ $(( $(date +%s) - S0 )) -lt 6 ]; do
    FV=$(fanout_view); ID1=$(fo_num "$FV" id)
    if [ "${ID1:-0}" -gt "$ID0" ] 2>/dev/null && [ "$(fo_open "$FV")" = "true" ]; then OPEN=1; break; fi
    kill -0 "$FPID" 2>/dev/null || break
    sleep 0.2
  done
  if [ "$OPEN" = 1 ]; then
    adm devBumpOracleEpoch '()' >/dev/null
    WIN="fan-out #$ID1 open with $(fo_num "$FV" arrived) arrived, bump at +$(( $(date +%s) - S0 ))s"
  fi
  # The admin call returns once its fleet has (~1.5s) — the hold is read at
  # its end, so the stall is cleared only AFTER it returned (earlier, the call
  # would drain the fan-out itself). Then the sweep's close: poll well past
  # PRICE_FANOUT_DEADLINE_NS (8s) + a beat.
  wait "$FPID"
  R=$(cat "$TMPD/fetch")
  stall clear >/dev/null
  if [ "$OPEN" = 1 ]; then ok "the admin fetch's fan-out was OPEN on a responsive replica ($WIN)"; else nok "the fetch's fan-out never showed open" "reply=$(echo "$R" | tr -d '\n' | head -c 120)"; fi
  if echo "$R" | grep -q 'left OPEN for the deadline sweep'; then ok "the admin call returned at once (+$(( $(date +%s) - S0 ))s) with the fan-out left to the sweep: $(echo "$R" | tr -d '\n' | head -c 90)"; else nok "the admin call did not report the held-open fan-out" "$(echo "$R" | tr -d '\n' | head -c 160)"; fi
  FV=$(fanout_view)
  while [ "$(fo_open "$FV")" = "true" ] && [ $(( $(date +%s) - S0 )) -lt 16 ]; do sleep 0.5; FV=$(fanout_view); done
  if [ "$(fo_open "$FV")" = "false" ] && echo "$FV" | grep -q 'reason = "deadline"' && echo "$FV" | grep -q 'abandoned: oracle epoch moved during the fetch'; then
    ok "the callee abandoned the fetch at the deadline sweep (+$(( $(date +%s) - S0 ))s; fan-out #$ID1 reason deadline, outcome 'abandoned: oracle epoch moved')"
  else
    nok "the epoch bump did not abandon the held fetch at the sweep" "window=${WIN:-never open} view=$(echo "$FV" | head -c 220)"
  fi
  T1=$(lastagg)
  if [ -n "$T0" ] && [ "$T1" = "$T0" ]; then ok "lastAggregates untouched (timestamp $T0 unchanged)"; else nok "the abandoned fetch still wrote lastAggregates" "before=$T0 after=$T1"; fi
  P=$(refpx)
  if [ "$P" = "$(e8 3.00)" ]; then ok "mark untouched (3.00)"; else nok "mark moved by an abandoned fetch" "px=$P"; fi
  rm -rf "$TMPD"
  s4_teardown
fi

echo "── §5 the release reference is the fetch's DISPATCH clock (H-23 / F27) ──"
# Through the fallback writer (floor still 99): a current-minute anchor applies.
# The reference must sit between the pre-call wall clock and the apply clock —
# dispatch ≤ applied — and getReleaseInfo.releaseRefNs must be the same value.
relref() { adm devGetReleaseRef "(\"$MKT\")" --query | tr -d '_\n' | tr -s ' ' | grep -oE "$1 = [0-9-]+" | head -1 | awk '{print $3}'; }
p0
D0=$(relref dispatchNs)
adm setTestXrcRate "(\"ICP\", opt ($(e8 3.02) : nat), opt (0 : nat))" >/dev/null
T0=$(( $(date +%s) * 1000000000 ))
R=$(adm fetchAndSetRefPrice "(\"$MKT\")")
D1=$(relref dispatchNs); A1=$(relref appliedNs); P=$(refpx)
if [ "$P" = "$(e8 3.02)" ]; then ok "anchor applied through the fallback writer (mark → 3.02)"; else nok "fallback did not apply" "px=$P r=$(echo "$R" | head -c 120)"; fi
if [ -n "$D1" ] && [ -n "$A1" ] && [ "$D1" -gt "${D0:-0}" ] 2>/dev/null; then ok "the writer stamped a new release reference (dispatch $D0 → $D1)"; else nok "no release reference recorded by the fetch (pre-H-23: devGetReleaseRef absent or unmoved)" "d0=$D0 d1=$D1 $(echo "$R" | head -c 80)"; fi
if [ -n "$D1" ] && [ "$D1" -ge $(( T0 - 2000000000 )) ] 2>/dev/null && [ "$D1" -le "${A1:-0}" ] 2>/dev/null; then ok "dispatch clock ≥ the pre-call wall clock and ≤ the apply clock (latency $(( (A1 - D1) / 1000000 ))ms)"; else nok "dispatch clock out of order" "t0=$T0 dispatch=$D1 applied=$A1"; fi
RR=$(adm getReleaseInfo "(\"$MKT\")" --query | tr -d '_\n' | tr -s ' ' | grep -oE "releaseRefNs = [0-9-]+" | head -1 | awk '{print $3}')
if [ -n "$RR" ] && [ "$RR" = "$D1" ]; then ok "getReleaseInfo.releaseRefNs is the dispatch clock ($RR)"; else nok "getReleaseInfo does not expose the reference" "releaseRefNs=$RR dispatch=$D1"; fi

adm setTestPendingJump '("ICP", null, null)' >/dev/null 2>&1
adm setTestXrcRate '("ICP", null, null)' >/dev/null 2>&1
adm setTestMinSources '(null)' >/dev/null 2>&1

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_oracle_time_bases ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_oracle_time_bases ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
