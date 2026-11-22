#!/bin/bash
# Trading-profit leaderboard (profit vs HODL).
#   profit = net equity − value_now(net deposited basket)
# Three traders, one price move, every property pinned:
#   • lb_win  buys 2000 ICP @ $3 from lb_lose, then ICP +20% → profit ≈ +$1,194
#     (2000 × $0.60 gain − $6 taker fee)
#   • lb_lose sold before the rise → profit ≈ −$1,203 (missed gain + maker fee)
#   • lb_hold never trades → profit EXACTLY $0 through the price move
#     (equity and HODL baseline move together — the board measures trading,
#     not market beta)
#   • setTestBalance deltas are recorded as external flows (capital = seeded $10k)
#   • a withdrawal moves equity AND baseline → profit unchanged (score can't be
#     gamed by shuffling capital)
#   • the AMM seeder's LP position is HODL-neutral too (vault untouched → ≈ 0)
# Timers paused; the snapshot is forced via adminRecomputeLeaderboard.
# ⚠️ Calls resetExchange — at entry AND at exit. The fixture seeds the vault
# under lb_seed (a throwaway identity mdx_identity_new DELETES when the run
# ends), so leaving the venue as-is strands an LP supply no successor can ever
# sum: _lib.sh's I1 (Σ LP over alice..eve == vaultLPSupply) read "got 0.0"
# against 6e12 in every following suite that does not wipe first, and the SOL
# pool the seeded venue carried is gone (test_liq_direction redded on both in
# run_all order, task 1788523488). The fixture-hygiene rule in _lib.sh
# (assert_invariants I1): a test that funds the vault under ad-hoc identities
# resetExchanges at exit. Registered through on_exit so a mid-suite exit
# still cleans up; timers resume in the same hook.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"; set +o pipefail   # shared helpers (mdx_identity_new / principal_of — throwaway identities that LEAVE the store); this suite keeps its own ok/nok frame and pipeline semantics
export PATH="$HOME/.local/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

e8() { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mdx_identity_new lb_seed; SEED=$(principal_of lb_seed); mdx_identity_new lb_win; WIN=$(principal_of lb_win); mdx_identity_new lb_hold; HOLD=$(principal_of lb_hold); mdx_identity_new lb_lose; LOSE=$(principal_of lb_lose)
adm() { icp canister call --candid "$MDX_CANDID" --identity anonymous backend "$@" 2>&1; }
# Exit hygiene (header): the lb_seed-held vault does not outlive the run.
on_exit "adm resetExchange '()' >/dev/null 2>&1 || true; adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true"
# my-row helper: caller's own leaderboard entry, underscores stripped.
myrow() { icp canister call --candid "$MDX_CANDID" --identity "$1" backend getLeaderboard '()' --query 2>&1 | tr -d '_\n' | tr -s ' ' | grep -oE "my = opt record \{[^}]*\}"; }
field() { echo "$1" | grep -oE "$2 = [-+0-9]+" | grep -oE "[-+0-9]+$"; }

# Deterministic run needs the trading bot DEAD (paused timers stop the
# heartbeat, but the sim is an external process placing real orders and
# moving the ref price mid-fixture). cold_start relaunches it later.
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
adm createAmmPool '("ICP-ICPUSD")' >/dev/null 2>&1
adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 3) : nat)" >/dev/null

# Zero every token for the test identities first — resetExchange keeps user
# balances, so a rerun would otherwise inherit its own prior fills. (Each
# zeroing SET records a flow too, so baselines stay exact.)
clean() { for t in BTC ETH SOL ICP ICPUSD; do adm setTestBalance "(principal \"$1\", \"$t\", 0 : nat)" >/dev/null; done; }
clean "$SEED"; clean "$WIN"; clean "$HOLD"; clean "$LOSE"

# The board ranks NAMED traders — an account with no profile is the venue's own
# machinery (only controller seeding can register one without a browser), so it
# is excluded. These fixtures are funded by exactly that admin path, so they
# must identify themselves or they will not appear. Same step simulate_trading.sh
# takes for its bots.
for id in lb_seed lb_win lb_hold lb_lose; do
  icp canister call --candid "$MDX_CANDID" --identity "$id" backend getMyProfile "()" >/dev/null 2>&1 || true
done

# Fund everyone via setTestBalance — each SET's delta must land in the
# external-flow ledger (the HODL baseline).
adm setTestBalance "(principal \"$SEED\", \"ICP\",    $(e8 10000) : nat)" >/dev/null
adm setTestBalance "(principal \"$SEED\", \"ICPUSD\", $(e8 30000) : nat)" >/dev/null
adm setTestBalance "(principal \"$WIN\",  \"ICPUSD\", $(e8 10000) : nat)" >/dev/null
adm setTestBalance "(principal \"$HOLD\", \"ICPUSD\", $(e8 10000) : nat)" >/dev/null
adm setTestBalance "(principal \"$LOSE\", \"ICP\",    $(e8 2000)  : nat)" >/dev/null
mdx_lp_deposit lb_seed "ICP-ICPUSD" "$(e8 10000)" "$(e8 30000)" >/dev/null 2>&1
adm enableAmm '("ICP-ICPUSD", true)' >/dev/null
fresh() { adm setAmmRefPrice "(\"ICP-ICPUSD\", $(e8 $1) : nat)" >/dev/null; adm requoteAmm '("ICP-ICPUSD")' >/dev/null; }
fresh 3

echo "── 1. The trade: lose sells 2000 ICP @ \$3.00, win buys them ──"
icp canister call --candid "$MDX_CANDID" --identity lb_lose backend placeLimitOrder "(\"ICP-ICPUSD\", variant { sell }, $(e8 3) : nat, $(e8 2000) : nat)" >/dev/null 2>&1
fresh 3   # lose's ask releases and rests (inside the AMM spread)
icp canister call --candid "$MDX_CANDID" --identity lb_win backend placeLimitOrder "(\"ICP-ICPUSD\", variant { buy }, $(e8 3) : nat, $(e8 2000) : nat)" >/dev/null 2>&1
fresh 3   # win's buy releases and crosses it
WIN_ICP=$(adm getTestBalance "(principal \"$WIN\", \"ICP\")" | tr -d '_' | grep -oE "[0-9]+" | head -1)
if [ "${WIN_ICP:-0}" = "$(e8 2000)" ]; then ok "trade settled: win holds 2000 ICP"; else nok "trade did not settle" "winICP=$WIN_ICP"; fi

echo ""
echo "── 2. ICP rises 20% (\$3.00 → \$3.60); snapshot the board ──"
fresh 3.6
adm adminRecomputeLeaderboard "()" >/dev/null

W=$(myrow lb_win); H=$(myrow lb_hold); L=$(myrow lb_lose); S=$(myrow lb_seed)
WP=$(field "$W" profitUsd); HP=$(field "$H" profitUsd); LP=$(field "$L" profitUsd); SP=$(field "$S" profitUsd)
WR=$(field "$W" rank); LR=$(field "$L" rank)
HC=$(field "$H" capitalUsd)
echo "   win: profit=$WP rank=$WR   hold: profit=$HP capital=$HC   lose: profit=$LP rank=$LR   seeder: profit=$SP"

# win: +$1,200 gain − $6 taker fee = +$1,194 (±$2 for rounding dust)
if awk -v p="${WP:-0}" 'BEGIN{ exit (p > 119200000000 && p < 119600000000 ? 0 : 1) }'; then
  ok "winner's profit ≈ +\$1,194 (gain − taker fee)"
else nok "winner profit off" "profitUsd=$WP (expected ≈119_400_000_000)"; fi

# hold: EXACTLY zero — the HODL-neutrality invariant.
if [ "${HP:-x}" = "0" ]; then
  ok "holder's profit is EXACTLY \$0 through the price move"
else nok "holder should score 0" "profitUsd=$HP"; fi

# hold's capital = the seeded $10k (setTestBalance delta was recorded).
if [ "${HC:-x}" = "1000000000000" ]; then
  ok "setTestBalance delta recorded as capital (\$10,000)"
else nok "capital wrong" "capitalUsd=$HC"; fi

# lose: −$1,200 missed gain − $3 maker fee ≈ −$1,203
if awk -v p="${LP:-0}" 'BEGIN{ exit (p < -120000000000 && p > -120600000000 ? 0 : 1) }'; then
  ok "seller's profit ≈ −\$1,203 (sold before the rise)"
else nok "seller profit off" "profitUsd=$LP (expected ≈ −120_300_000_000)"; fi

# seeder: LP position is HODL-neutral on marks, but the vault now earns HALF
# of every trading fee (drain fix 4), so the seeder drifts slightly POSITIVE
# with test volume — never negative.
if awk -v p="${SP:-0}" 'BEGIN{ exit (p >= 0 && p < 2500000000 ? 0 : 1) }'; then
  ok "AMM seeder ≈ flat-to-slightly-up (LP fee share) — profitUsd=$SP"
else nok "seeder should be ~flat (0 ≤ p < \$25 fee share)" "profitUsd=$SP"; fi

# Ranking: win is #1; lose is last of the ranked set.
TOT=$(icp canister call --candid "$MDX_CANDID" --identity anonymous backend getLeaderboard '()' --query | tr -d '_' | grep -oE "totalRanked = [0-9]+" | grep -oE "[0-9]+")
if [ "${WR:-0}" = "1" ]; then ok "winner ranked #1"; else nok "winner not #1" "rank=$WR"; fi
if [ "${LR:-0}" = "${TOT:-x}" ]; then ok "seller ranked last (#$LR of $TOT)"; else nok "seller not last" "rank=$LR of $TOT"; fi

echo ""
echo "── 3. Withdrawal neutrality: hold withdraws \$2,000 → profit still \$0 ──"
icp canister call --candid "$MDX_CANDID" --identity lb_hold backend withdraw '("ICPUSD", 200_000_000_000 : nat, "ext-dest")' >/dev/null 2>&1
adm adminRecomputeLeaderboard "()" >/dev/null
H2=$(myrow lb_hold)
HP2=$(field "$H2" profitUsd); HC2=$(field "$H2" capitalUsd)
echo "   hold after withdrawal: profit=$HP2 capital=$HC2"
if [ "${HP2:-x}" = "0" ]; then
  ok "withdrawal moved equity AND baseline — profit unchanged (\$0)"
else nok "withdrawal skewed the score" "profitUsd=$HP2"; fi
if [ "${HC2:-x}" = "800000000000" ]; then
  ok "capital now \$8,000 (net of the withdrawal)"
else nok "capital after withdrawal wrong" "capitalUsd=$HC2"; fi

echo ""
echo "── 4. OQL projection: the public \`leaderboard\` entity serves its Usd columns in HUMAN units ──"
# Task 1793551691: Agent Chat's only read tool is OQL, and a live model handed
# the e8 integers rendered a $10,000 account as $10,000,000 (÷100 instead of
# ÷10^8) even with the prompt's UNITS rule naming these columns. The entity now
# projects profitUsd / capitalUsd / equityUsd as human-unit floats (e8 ÷ 10^8,
# the account snapshot's convention) while getLeaderboard (candid, §1-3 above)
# keeps the exact e8 integers; returnBps stays an integer (basis points). The
# pin: hold's OQL row equals its candid row ÷ 10^8, cell by cell.
HN=$(echo "$H2" | grep -oE 'username = "[^"]*"' | sed -E 's/username = "([^"]*)"/\1/')
HE2=$(field "$H2" equityUsd)
OQLQ=$(scratch_new lb_oql_query.txt) || exit 1
printf '("{\\"start\\":\\"leaderboard\\",\\"limit\\":50}")' > "$OQLQ"
LBO=$(icp canister call --candid "$MDX_CANDID" --args-file "$OQLQ" backend execute --query --identity anonymous 2>&1 | tr -d '_\n' | tr -s ' ')
# One row per line (the executor prints each row as `vec { record {...}; ... }`),
# then hold's row by its username — the only identity the public entity carries.
LBROW=$(echo "$LBO" | sed 's/vec { record/\
vec { record/g' | grep -F "\"text\" = \"$HN\"" | head -1)
# A cell prints `value = variant { <tag> = <v> : <type> }; name = "<col>"`; the
# tag is quoted when it is a candid keyword ("nat", "int", "text") and bare
# otherwise (float).
oqlkind() { echo "$1" | grep -oE "value = variant \{ \"?[a-z]+\"? = [^;]*; name = \"$2\"" | head -1 | grep -oE 'variant \{ "?[a-z]+' | grep -oE '[a-z]+$'; }
oqlnum()  { echo "$1" | grep -oE "value = variant \{ \"?[a-z]+\"? = [-+0-9.eE]+ : [a-z0-9]+ \}; name = \"$2\"" | head -1 | grep -oE '= [-+0-9.eE]+ :' | grep -oE '[-+0-9.eE]+'; }
same() { awk -v o="$1" -v c="$2" 'BEGIN{ d = o - c / 100000000; if (d < 0) d = -d; exit (d < 0.000001 ? 0 : 1) }'; }
if [ -n "$LBROW" ]; then ok "hold's row is on the OQL leaderboard entity (username $HN)"; else nok "hold's row missing from the OQL entity" "rows=$(echo "$LBO" | grep -o 'name = "rank"' | wc -l | tr -d ' ')"; fi
OC=$(oqlnum "$LBROW" capitalUsd); OP=$(oqlnum "$LBROW" profitUsd); OE=$(oqlnum "$LBROW" equityUsd); OR=$(oqlnum "$LBROW" returnBps)
echo "   OQL row: capitalUsd=$OC profitUsd=$OP equityUsd=$OE returnBps=$OR   (candid: $HC2 / $HP2 / $HE2 e8)"
if [ "$(oqlkind "$LBROW" capitalUsd)" = "float" ] && [ "$(oqlkind "$LBROW" profitUsd)" = "float" ] && [ "$(oqlkind "$LBROW" equityUsd)" = "float" ]; then
  ok "profitUsd / capitalUsd / equityUsd arrive as FLOAT cells (schema typeName Float — the model sees the unit)"
else nok "Usd columns are not float cells" "kinds: $(oqlkind "$LBROW" capitalUsd) / $(oqlkind "$LBROW" profitUsd) / $(oqlkind "$LBROW" equityUsd)"; fi
if [ -n "${OC:-}" ] && same "$OC" "${HC2:-0}" && same "$OC" "800000000000"; then ok "OQL capitalUsd = \$8,000 — the candid row's 800000000000 e8 ÷ 10^8"; else nok "OQL capitalUsd off" "oql=$OC candid=$HC2 (expected 8000)"; fi
if [ -n "${OP:-}" ] && same "$OP" "${HP2:-1}"; then ok "OQL profitUsd = \$0 — the candid row ÷ 10^8"; else nok "OQL profitUsd off" "oql=$OP candid=$HP2"; fi
if [ -n "${OE:-}" ] && same "$OE" "${HE2:-1}"; then ok "OQL equityUsd = the candid row ÷ 10^8 (\$$OE)"; else nok "OQL equityUsd off" "oql=$OE candid=$HE2"; fi
if [ "$(oqlkind "$LBROW" returnBps)" = "int" ] && [ "${OR:-x}" = "0" ]; then ok "returnBps stays an INTEGER cell (basis points — never scaled)"; else nok "returnBps cell wrong" "kind=$(oqlkind "$LBROW" returnBps) value=$OR"; fi

adm setTestTimersPaused '(false)' >/dev/null 2>&1 || true
echo ""
echo "═══════════════════════════════════════════════════════"
echo "RESULT: passed=$pass failed=$fail"
exit $fail
