#!/bin/bash
# 1788471187 — the oracle mark BASIS and the last USD/USDT depeg signal are
# on the status surface, not only in the warn log.
#
# Task 1788465030 (issue #55 "oracle split") made PriceFeed.aggregateByQuote
# return `mark : MarkBasis` (#pooled | #usdGroup) beside diverged / depegBps /
# usdCount / usdtCount, and refreshMultiSourcePrice worded its `warn` oracle
# event by that basis — the ONLY place the split was visible. An operator
# reading the Status page could not tell a USDT-depeg divergence (pooled mark,
# USDT-dominated) from a healthy feed without tailing the event log. Now the
# callee keeps the last QuoteAggregate signal per asset in a transient map
# and getPriceFeedStats() carries it as `quoteSignals : [(Text, QuoteSignal)]`
# plus `depegAlarmBps` (the threshold `diverged` was judged at).
#
# No injection path exists for a depeg (the sources are real outcalls), so
# this suite drives ONE real refresh through the admin fetch and asserts the
# healthy-feed shape:
#   §1  the additive fields are present on getPriceFeedStats (depegAlarmBps
#       is the 100bps alarm; quoteSignals decodes as a vec)
#   §2  after a refresh the asset carries a signal: diverged == false,
#       mark == #pooled, and the two group counts sum to the aggregate's
#       surviving source count (every reading is in exactly one quote group)
#   §3  the signal is keyed by asset, not by market (BTC after BTC's fetch)
#
# Reads only queries + the admin fetch (a controller method that is live on
# every posture) — no #dev hooks, so it runs on a #play venue too. The fetch
# result itself (#ok / pended / rejected) is NOT asserted: the signal is
# written by the callee BEFORE the accept gate runs, whatever the gate then
# decides about the mark. Offline venue (every source failing) still yields
# a signal — with both counts 0, no cross-check — and the assertions hold.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
# icp pretty-prints nested records across lines; flatten before matching.
flat() { tr -d '_\n' | tr -s ' '; }
stats() { adm getPriceFeedStats '()' --query | flat; }
# signal_of ICP "<flat stats>" → the `record { ... }` paired with that asset
# inside `quoteSignals = vec { record { "ICP"; record { ... } }; ... }`. The
# inner record nests one brace group (`mark = variant { pooled }`), so the
# match admits one level of braces — a plain `[^}]*` stops at the variant.
signal_of() {
  printf '%s' "$2" | grep -oE "record \{ \"$1\"; record \{ ([^{}]|\{[^{}]*\})*\}" | head -1
}
srccount() { adm getLastAggregate "(\"$1\")" --query | flat | grep -oE "sourceCount = [0-9]+" | head -1 | awk '{print $3}'; }

echo "── §1 the additive fields are on the status record ──"
S0=$(stats)
if echo "$S0" | grep -qE "depegAlarmBps = 100 : nat"; then ok "depegAlarmBps = 100 (the USDT depeg alarm threshold)"
else nok "depegAlarmBps missing or not the 100bps alarm" "$(echo "$S0" | head -c 200)"; fi
if echo "$S0" | grep -qE "quoteSignals = vec \{"; then ok "quoteSignals is a vec on getPriceFeedStats"
else nok "quoteSignals missing from getPriceFeedStats" "$(echo "$S0" | head -c 200)"; fi

echo "── §2 one real refresh populates the asset's signal ──"
# Drive the callee through the admin fetch (real outcalls; a few seconds).
# The apply verdict is reported, not asserted — see the header.
R=$(adm fetchAndSetRefPrice '("ICP-ICPUSD")' | flat)
if mdx_ok "$R"; then echo "  (fetch applied: $(echo "$R" | head -c 80))"
else echo "  (fetch did not apply — fine, the signal is written before the gate: $(echo "$R" | head -c 100))"; fi
S1=$(stats)
SIG=$(signal_of ICP "$S1")
if [ -n "$SIG" ]; then ok "ICP carries a quote signal after the refresh"
else nok "no ICP entry in quoteSignals after a refresh" "$(echo "$S1" | grep -oE "quoteSignals = vec \{.{0,160}")"; fi
if echo "$SIG" | grep -qE "diverged = false"; then ok "diverged == false on a healthy feed"
else nok "expected diverged = false" "$SIG"; fi
if echo "$SIG" | grep -qE "mark = variant \{ pooled \}"; then ok "mark == #pooled (the pooled trim priced the mark)"
else nok "expected mark = variant { pooled }" "$SIG"; fi
USD=$(echo "$SIG" | grep -oE "usdCount = [0-9]+" | awk '{print $3}')
USDT=$(echo "$SIG" | grep -oE "usdtCount = [0-9]+" | awk '{print $3}')
DEPEG=$(echo "$SIG" | grep -oE "depegBps = [0-9]+" | awk '{print $3}')
SRC=$(srccount ICP)
echo "  observed: USD ${USD:-?} / USDT ${USDT:-?} sources, depeg ${DEPEG:-?}bps, aggregate sourceCount ${SRC:-?}"
if [ -n "${USD:-}" ] && [ -n "${USDT:-}" ] && [ -n "${SRC:-}" ] && [ $((USD + USDT)) -eq "$SRC" ]; then
  ok "usdCount + usdtCount == the aggregate's sourceCount (every reading sits in one quote group)"
else nok "group counts do not partition the aggregate" "usd=${USD:-?} usdt=${USDT:-?} sourceCount=${SRC:-?}"; fi
if [ -n "${DEPEG:-}" ] && [ "$DEPEG" -le 100 ]; then ok "depegBps (${DEPEG}) is within the alarm on a healthy feed"
else nok "depegBps should be ≤ the 100bps alarm when not diverged" "depeg=${DEPEG:-?}"; fi

echo "── §3 the signal is keyed by asset ──"
adm fetchAndSetRefPrice '("BTC-ICPUSD")' >/dev/null 2>&1 || true
S2=$(stats)
if [ -n "$(signal_of BTC "$S2")" ]; then ok "BTC carries its own signal after BTC's fetch"
else nok "no BTC entry after a BTC fetch" "$(echo "$S2" | grep -oE "quoteSignals = vec \{.{0,160}")"; fi
if [ -n "$(signal_of ICP "$S2")" ]; then ok "ICP's signal survives BTC's fetch (per-asset map, not last-write)"
else nok "ICP's signal vanished after BTC's fetch" "$(echo "$S2" | grep -oE "quoteSignals = vec \{.{0,160}")"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_oracle_quote_signal ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_oracle_quote_signal ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
