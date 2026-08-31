#!/bin/bash
# W5-09 — the STANDALONE verifier (scripts/verify_ledger.mjs) is executed by
# a gate, not just cited by one. The docs hand this tool to users who do not
# want to trust the site; before this file, no gate in the repository ever
# ran it (the hygiene census iterates scripts/*.sh — *.mjs cannot match).
#
# Fixture: the reporter's offline hostile-host stub (#37.7, gist rvnt9999/
# a5cbbd48…, vendored under tests/fixtures/verify-ledger-stub/). It opens no
# socket, impersonates @icp-sdk/core, and slices canonical()/hashEvent() out
# of the REAL verifier at runtime by marker — the fixture cannot drift from
# what it measures, and it throws rather than measure its own copy.
#
# The four W2-02 verdicts pinned here:
#   no-cert                      exit 1  "host served NO certificate"
#   bad-cert                     exit 1  certificate does not commit / FAILED
#   good-cert + empty tape       exit 1  zero-progress rule ("nothing verifiable")
#   good-cert + 1-event skew     exit 0  the honest live-tape case KEEPS PASSING
# And the two W2-04 lies (both exited 0 pre-fix):
#   fabricated-gap               exit 1  a getLedgerGaps tuple at a segment
#                                        boundary no longer suppresses the
#                                        cross-archive link check — the claim
#                                        needs a chain-committed #gap event
#   truncated-list               exit 1  omitting early archives from
#                                        getArchives is refused (genesis pin:
#                                        coverage must reach the chain origin)
#
# Offline by construction — no venue, no replica, no posture requirement.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass=0; fail=0
ok()  { echo -e "${GREEN}✓${NC} $1"; pass=$((pass+1)); }
nok() { echo -e "${RED}✗${NC} $1 — $2"; fail=$((fail+1)); }

H=$(mktemp -d "${TMPDIR:-/tmp}/mdx_vlg.XXXXXX")
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/node_modules/@icp-sdk/core"
cp "$REPO/scripts/verify_ledger.mjs" "$H/verify_ledger.mjs"
F="$REPO/tests/fixtures/verify-ledger-stub"
cp "$F/stub-agent.js"     "$H/node_modules/@icp-sdk/core/agent.js"
cp "$F/stub-candid.js"    "$H/node_modules/@icp-sdk/core/candid.js"
cp "$F/stub-principal.js" "$H/node_modules/@icp-sdk/core/principal.js"
cp "$F/stub-package.json" "$H/node_modules/@icp-sdk/core/package.json"

# The copy in $H is what runs (so node resolves the stub SDK beside it); the
# stub slices canonical()/hashEvent() from MDX_REAL_VERIFIER — point it at
# the repo's file explicitly rather than trusting the stub's default hop.
# Scenario variables are UNSET between runs, never blanked: the stub treats a
# defined-but-empty MDX_STUB_WITHHOLD as "withhold everything".
runv() {  # runv <scenario> [extra env as k=v...]
  ( cd "$H" && env -u MDX_STUB_TAIL -u MDX_STUB_WITHHOLD \
      MDX_REAL_VERIFIER="$REPO/scripts/verify_ledger.mjs" \
      MDX_STUB_SCENARIO="$1" "${@:2}" \
      node verify_ledger.mjs --backend aaaaa-aa --host https://icp-api.io --full \
  ) >"$H/out.txt" 2>&1
  echo $?
}

RC=$(runv no-cert)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "host served NO certificate"; then
  ok "no-cert: exit 1, refuses to vouch without the subnet's signature"
else nok "no-cert verdict wrong" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

RC=$(runv bad-cert)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -qE "certificate does NOT commit|certificate check FAILED"; then
  ok "bad-cert: exit 1, forged certificate rejected"
else nok "bad-cert verdict wrong" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

RC=$(runv good-cert MDX_STUB_TAIL=1)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "nothing verifiable"; then
  ok "good-cert + all-[] tape: exit 1 (zero-progress rule — the #37.1 lie)"
else nok "empty-tape verdict wrong (pre-W2-02 this was exit 0)" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

RC=$(runv good-cert MDX_STUB_WITHHOLD=2)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "chain links verified" \
   && echo "$OUT" | grep -q "\[stub\] Certificate.create reached"; then
  ok "good-cert + honest 1-event skew: exit 0 (the legitimate live-tape case)"
else nok "honest-skew control broken (over-tightened verifier?)" "rc=$RC $(echo "$OUT" | tail -3 | head -2 | tr '\n' ' ')"; fi

# ── W2-04: the two structural lies. Certificates are GENUINE in both — the
# refusal must come from the trust-anchor logic, not a broken cert. ──
RC=$(runv fabricated-gap)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "unjustified discontinuity"; then
  ok "fabricated-gap: exit 1 — a self-reported tuple cannot suppress a link check"
else nok "fabricated gap tuple was honored (the R1 attack)" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

RC=$(runv truncated-list)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "early archives omitted"; then
  ok "truncated-list: exit 1 — genesis pinned, omitted archives refused"
else nok "truncated archive list verified clean (the sibling attack)" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_verify_ledger_gate ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_verify_ledger_gate ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
