#!/bin/bash
# W3-08 — a trapping heartbeat subtask cannot take the beat down.
#
# Nine subtasks used to run INLINE in the heartbeat: one trap killed the
# whole beat message and every subtask after it, permanently. They now run
# as isolated self-sends (hbRun) behind a dispatch/completion breaker with
# geometric backoff (mirror of the liquidation breaker).
#
#   §1 baseline: beats advance; subtask completions accrue
#   §2 forced trap in the every-beat "drain" subtask: the BEAT keeps
#      advancing, other subtasks keep completing, the streak grows, and
#      the breaker backs the trapping task off (dispatches ≪ beats)
#   §3 clearing the trap: the subtask recovers and its streak resets
#   §4 #47.1 — the dead-man sweep outruns the timer brake: an armed
#      cancelAllAfter still fires while setTestTimersPaused(true) is set
#      (the dispatch sits ABOVE the pause gate), and the armed-status
#      surfaces (getMyCancelAllAfter / getAccessPolicy / whyAmIRefused)
#      cross-reference the brake as timersPaused
#
# Needs #dev (setTestHbTrap) and RUNNING timers.

set -u
export PATH="$HOME/.local/bin:$PATH"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }
adm() { icp canister call --identity anonymous backend "$@" 2>&1; }

hb() { adm getCanisterInfo '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "lastHeartbeatNs = [0-9-]+" | awk '{print $3}'; }
field() { # field <name> <subtask>  from getHbHealth
  adm getHbHealth '()' --query | tr -d '_\n' | tr -s ' ' | grep -oE "\"$2\"; record \{[^}]*" | grep -oE "$1 = [0-9]+" | awk '{print $3}';
}

adm setTestTimersPaused '(false)' >/dev/null 2>&1

echo "── §1 baseline: beats + completions ──"
H0=$(hb); sleep 3; H1=$(hb)
[ "${H1:-0}" != "${H0:-0}" ] && ok "heartbeat advancing" || nok "heartbeat stalled before the test" "h0=$H0 h1=$H1"
D0=$(field completions drain); sleep 2; D1=$(field completions drain)
[ "${D1:-0}" -gt "${D0:-0}" ] && ok "drain subtask completing (isolated dispatch works)" || nok "drain not completing" "d0=$D0 d1=$D1"

echo "── §2 a trapping subtask leaves the beat + siblings alive ──"
adm setTestHbTrap '(opt "drain")' >/dev/null
sleep 6
H2=$(hb); sleep 3; H3=$(hb)
[ "${H3:-0}" != "${H2:-0}" ] && ok "beat still advancing with 'drain' trapping every run" || nok "trap took the heartbeat down (the finding)" "h2=$H2 h3=$H3"
S=$(field streak drain)
[ "${S:-0}" -ge 1 ] && ok "breaker sees the failures (streak=$S)" || nok "streak not growing" "s=$S"
A0=$(field completions arrears); sleep 3; A1=$(field completions arrears)
[ "${A1:-0}" -gt "${A0:-0}" ] && ok "sibling subtask (arrears) still completing" || nok "sibling starved" "a0=$A0 a1=$A1"
DD0=$(field dispatches drain); sleep 8; DD1=$(field dispatches drain)
DELTA=$(( DD1 - DD0 ))
if [ "$DELTA" -lt 8 ]; then ok "backoff engaged: $DELTA dispatches in 8s (an unbroken every-beat task would make ~8)"; else nok "no backoff" "delta=$DELTA"; fi

echo "── §3 clearing the trap recovers the subtask ──"
adm setTestHbTrap '(null)' >/dev/null
sleep 12
S2=$(field streak drain); C0=$(field completions drain); sleep 3; C1=$(field completions drain)
[ "${S2:-9}" = "0" ] && ok "streak reset on recovery" || nok "streak stuck" "s=$S2"
[ "${C1:-0}" -gt "${C0:-0}" ] && ok "drain completing again" || nok "no recovery" "c0=$C0 c1=$C1"

echo "── §4 the dead-man sweep outruns the timer brake (#47.1) ──"
# Arm a minimum-window switch as a non-anonymous user, then set the brake.
# The armed-status surfaces must cross-reference the brake, and the switch
# must STILL fire while braked: the deadman dispatch deliberately sits ABOVE
# the heartbeat pause gate (trading is not brake-gated, so a dead bot's
# orders stay liftable while braked — the switch is what bounds that).
ali() { icp canister call --identity alice backend "$@" 2>&1; }
ARM=$(ali cancelAllAfter '(opt (5 : nat))')
if echo "$ARM" | grep -q "ok"; then ok "deadman armed (5s window)"; else nok "arm failed" "$ARM"; fi
adm setTestTimersPaused '(true)' >/dev/null
S1=$(ali getMyCancelAllAfter '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$S1" | grep -q "timersPaused = true"; then ok "getMyCancelAllAfter cross-references the brake"; else nok "getMyCancelAllAfter silent about the brake" "$S1"; fi
AP=$(ali getAccessPolicy '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$AP" | grep -q "myDeadmanArmed = true" && echo "$AP" | grep -q "timersPaused = true"; then
  ok "getAccessPolicy reports armed + brake"
else nok "getAccessPolicy missing armed/brake flags" "$AP"; fi
WR=$(ali whyAmIRefused '()' --query | tr -d '_\n' | tr -s ' ')
if echo "$WR" | grep -q "deadmanArmed = true" && echo "$WR" | grep -q "timersPaused = true"; then
  ok "whyAmIRefused reports armed + brake"
else nok "whyAmIRefused missing armed/brake flags" "$WR"; fi
sleep 9   # past the 5s window, with slack for the beat + isolated sweep
S2=$(ali getMyCancelAllAfter '()' --query | tr -d '\n' | tr -s ' ')
if echo "$S2" | grep -q "(null)"; then
  ok "switch FIRED while braked (entry swept by the heartbeat)"
else nok "switch did not fire under the brake (the #47.1 finding)" "$S2"; fi
adm setTestTimersPaused '(false)' >/dev/null

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_heartbeat_isolation ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_heartbeat_isolation ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
