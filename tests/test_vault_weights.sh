#!/bin/bash
# Weighted AMM vault — FEES-ONLY deposit incentive + concentration caps.
#
# The vault targets an equal-weight basket (BTC/ETH/SOL/ICP = 12.5% each,
# ICPUSD = 50%), hardcoded. LP deposits are FEES-ONLY: an over-weight leg pays
# a fee (mints < its value), an at-/under-weight leg mints at FAIR value (1.0 —
# never a bonus, which would be extractable). A deposit that would over-
# concentrate an asset past its cap (2× target for volatile assets) is rejected.
# The first deposit into an empty vault must clear the $1000 floor.
#
# Verified: dust genesis deposit rejected; equal target weights;
# under-weight earns NO bonus (mult == 1.0) while over-weight is fee'd;
# over-concentrating deposit rejected; a balancing deposit is accepted fair.

set -u
export PATH="$HOME/.local/bin:$PATH"
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_ok — the only sanctioned #ok oracle); this suite keeps its own ok/nok frame and pipeline semantics

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

# Integer-money: methods take/return Nat BASE UNITS (10^8). Weights and
# deposit multipliers come back as 0..1 fractions at 10^8 (e.g. 12.5% =
# 12_500_000), so from_e8 restores the human 0.125 scale the asserts use.
e8()      { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
from_e8() { awk -v x="$1" 'BEGIN{ printf "%.8f", x/100000000 }'; }

ID=vaultw
mdx_identity_new $ID
P=$(icp identity principal --identity $ID 2>/dev/null | tail -1)   # NOT a controller
A=$(icp identity principal --identity alice 2>/dev/null | tail -1) # alice = controller
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
usr() { icp canister call --candid "$MDX_CANDID" --identity $ID backend "$@" 2>&1; }
asA() { icp canister call --candid "$MDX_CANDID" --identity alice backend "$@" 2>&1; }
# named base-unit field for a token's record in getVaultWeights (underscores
# stripped BEFORE extraction — Candid prints 12_500_000).
wfield() { adm getVaultWeights "()" | tr -d '_' | tr '}' '\n' | grep -A4 "token = \"$2\"" | grep -oE "$1 = [0-9]+" | grep -oE "[0-9]+" | head -1; }
# multiplier / target / current weight for a token, in HUMAN scale (0..1)
mult() { local n; n=$(wfield depositMultiplier "$1"); [ -z "$n" ] && n=0; from_e8 "$n"; }
tgtw() { local n; n=$(wfield targetWeight "$1"); [ -z "$n" ] && n=0; from_e8 "$n"; }
curw() { local n; n=$(wfield currentWeight "$1"); [ -z "$n" ] && n=0; from_e8 "$n"; }
lpnum(){ tr -d '_' | grep -oE "ok = [0-9]+" | grep -oE "[0-9]+" | head -1; }

adm setTestTimersPaused '(true)' >/dev/null 2>&1 || true
adm resetExchange "()" >/dev/null 2>&1 || true
for m in BTC ETH SOL ICP; do adm createAmmPool "(\"$m-ICPUSD\")" >/dev/null 2>&1; done
adm setAmmRefPrice "(\"BTC-ICPUSD\", $(e8 50000.0) : nat)" >/dev/null
adm setAmmRefPrice "(\"ETH-ICPUSD\", $(e8 2000.0) : nat)"  >/dev/null
adm setAmmRefPrice "(\"SOL-ICPUSD\", $(e8 80.0) : nat)"    >/dev/null
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3.0) : nat)"     >/dev/null
# ENABLE the four pools (fixture trap, task 1788500129). §6 leaves the vault
# HOLDING BTC, and tickPriceRefresh (src/backend/main.mo) refreshes ENABLED
# pools only: a disabled pool's mark freezes at the stamp above, and 60s
# later vaultPricesStale refuses EVERY LP mint on the venue ("LP deposit
# paused: BTC refPrice is stale") until something resets or restamps —
# reproduced 2026-09-04 on a #dev seat venue: this suite green in 11s, every
# depositLp on the venue refused from +60s. Timers are paused for the run,
# so the fixed marks above hold while the sections execute; once the suite
# unpauses at exit the feed takes the enabled pools over: measured on the
# same venue, the mint gate reads stale from +60s until the feed's next tick
# (60s per-pool cadence by code — a 45s stale gate on a 30s beat quantises
# to two beats; task 1788503312), then pends behind the circuit breaker (the fixed marks sit
# far from live), and the honest gates were back by ~+120s — bounded and
# self-healing, unlike the frozen mark.
for m in BTC ETH SOL ICP; do adm enableAmm "(\"$m-ICPUSD\", true)" >/dev/null; done
for who in "$P" "$A"; do for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$who\", \"$t\", 0 : nat)" >/dev/null; done; done
adm setTestBalance "(principal \"$P\", \"BTC\",    $(e8 10.0) : nat)"     >/dev/null
adm setTestBalance "(principal \"$P\", \"ICPUSD\", $(e8 500000.0) : nat)" >/dev/null
adm setTestBalance "(principal \"$A\", \"ICPUSD\", $(e8 500000.0) : nat)" >/dev/null

echo "── 1. First deposit into an EMPTY vault must clear the minimum ──"
# (staged door since apiVersion 6.0.0: mdx_lp_deposit stages, re-stamps and
# settles; a settlement refusal comes back as the #cancelled text, rc 1)
R=$(mdx_lp_deposit $ID "BTC-ICPUSD" 0 "$(e8 100.0)")   # $100 < $1000 floor
if echo "$R" | grep -qiE "at least"; then ok "dust genesis deposit rejected at settlement (< \$1000 floor)"; else nok "should reject dust genesis" "$R"; fi
if R=$(mdx_lp_deposit $ID "BTC-ICPUSD" 0 "$(e8 100000.0)"); then ok "first deposit ≥ floor accepted (\$100k cash, minted $R)"; else nok "genesis" "$R"; fi   # anyone may be first if ≥ floor

echo ""
echo "── 2. Target weights are equal-weight (12.5% assets, 50% cash) ──"
if awk -v b="$(tgtw BTC)" -v q="$(tgtw ICPUSD)" 'BEGIN{exit (b>0.124 && b<0.126 && q>0.499 && q<0.501 ? 0 : 1)}'; then
  ok "targets: BTC=$(tgtw BTC) ICPUSD=$(tgtw ICPUSD) (12.5% / 50%)"; else nok "target weights wrong" "BTC=$(tgtw BTC) ICPUSD=$(tgtw ICPUSD)"; fi

echo ""
echo "── 3. FEES-ONLY: over-weight is fee'd, under-weight is FAIR (no bonus) ──"
# Vault is 100% cash → ICPUSD over-weight, BTC under-weight.
MQ=$(mult ICPUSD); MB=$(mult BTC)
echo "   deposit multipliers — ICPUSD(over)=$MQ  BTC(under)=$MB"
if awk -v q="$MQ" 'BEGIN{exit (q < 0.9999 ? 0 : 1)}'; then ok "over-weight ICPUSD pays a FEE (mult < 1.0): $MQ"; else nok "over-weight not fee'd" "$MQ"; fi
if awk -v b="$MB" 'BEGIN{exit (b > 0.9999 && b < 1.0001 ? 0 : 1)}'; then ok "under-weight BTC mints FAIR (mult == 1.0, NO bonus): $MB"; else nok "under-weight should be 1.0 not a bonus" "$MB"; fi

echo ""
echo "── 4. Over-weight deposit actually pays the fee (mints < value) ──"
# vaultw (non-controller, vault non-empty now) deposits cash → over-weight → fee.
MINT=$(mdx_lp_deposit $ID "BTC-ICPUSD" 0 "$(e8 50000.0)")
MINT_H=$(from_e8 "${MINT:-0}")
echo "   \$50k cash deposit minted: $MINT_H LP"
if awk -v m="$MINT_H" 'BEGIN{exit (m > 40000 && m < 49999 ? 0 : 1)}'; then ok "over-weight cash deposit fee'd (~45k for \$50k)"; else nok "fee not applied" "minted=$MINT_H"; fi

echo ""
echo "── 5. A deposit that would over-CONCENTRATE an asset is rejected ──"
# Vault ~150k, all cash. A $100k BTC deposit → BTC would be 40% > 25% cap.
R=$(mdx_lp_deposit $ID "BTC-ICPUSD" "$(e8 2.0)" 0)
if echo "$R" | grep -qiE "concentration cap"; then ok "over-concentrating BTC deposit rejected at settlement (would be 40% > 25% cap)"; else nok "should reject over-concentration" "$R"; fi

echo ""
echo "── 6. A balancing (under-cap) deposit is accepted at fair value ──"
WB_BEFORE=$(curw BTC)
if R=$(mdx_lp_deposit $ID "BTC-ICPUSD" "$(e8 0.5)" 0); then DEP6=ok; else DEP6=err; fi   # $25k BTC → ~14% < 25% cap
WB_AFTER=$(curw BTC)
echo "   BTC weight: ${WB_BEFORE:-0} → ${WB_AFTER:-0}  (deposit: $DEP6)"
if [ "$DEP6" = "ok" ] && awk -v a="${WB_AFTER:-0}" -v b="${WB_BEFORE:-0}" 'BEGIN{exit (a > b ? 0 : 1)}'; then
  ok "balancing BTC deposit accepted; BTC weight rose toward target"; else nok "balancing deposit should be accepted + converge" "$R wb=${WB_BEFORE}→$WB_AFTER"; fi
# (${var}→ braces: macOS bash 3.2 under a UTF-8 locale swallows the multibyte
# glyph into the variable name and `set -u` kills the script.)

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
