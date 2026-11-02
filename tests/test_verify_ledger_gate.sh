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
#   good-cert + 1-event skew     exit 3  INCONCLUSIVE (H-18 / F10, below) —
#                                        the walk was never anchored to a
#                                        certified head; the passing control
#                                        is now the stub's catch-up mode
# And the #51 follow-up (1788465046) replayed certificate — the stub's
# lookup_path always answered the CORRECT head, so the verifier's
# `eq(res.value, head)` conjunct at both certificate sites was only ever
# exercised where it was true (delete it: every scenario above stays green,
# and the verifier accepts any parseable certificate, one replayed from
# another canister included — the hostile-gateway case the check exists for):
#   wrong-head --full            exit 1  "does NOT commit to this segment's
#                                        head" — the per-segment site
#                                        (validateArchiveCert) fires first
#   wrong-head --last 3          exit 1  "IC certificate does NOT commit to
#                                        this head" — a single-archive tape,
#                                        so the window visits no sealed
#                                        segment and only the active-head
#                                        site after the walk can fire
# And the two W2-04 lies (both exited 0 pre-fix):
#   fabricated-gap               exit 1  a getLedgerGaps tuple at a segment
#                                        boundary no longer suppresses the
#                                        cross-archive link check — the claim
#                                        needs a chain-committed #gap event
#   truncated-list               exit 1  omitting early archives from
#                                        getArchives is refused (genesis pin:
#                                        coverage must reach the chain origin)
# And the #55.1 lie (exited 0 pre-fix — the genesis pin took the origin from
# the host under audit):
#   consistent-liar              exit 1  sealed archive omitted AND the active
#                                        head claims chainStartSeq = its own
#                                        firstSeq, the shape every honest
#                                        second segment reports; the origin
#                                        now defaults to 0 (never a value the
#                                        host chose), --expect-start overrides
# Plus the flag hygiene #55.1 named: a bare or non-numeric --expect-start /
# --max-tail-skew exits 2 loudly instead of parsing to NaN and silently
# disabling the bound it names.
# And the #55.4 honest tape (exited 1 pre-fix — a jump was matched only
# against a SINGLE chain declaration):
#   double-shed                  exit 0  two back-to-back sheds under a blocked
#                                        spawn: ONE list jump [2..4), TWO
#                                        contiguous #gap events [2..3),[3..4)
#   holed-shed                   exit 1  declarations [2..3),[4..5) under a
#                                        jump [2..5): a hole never merges
#   over-shed                    exit 1  declarations [2..3),[3..5) under a
#                                        jump [2..4): the merged run must
#                                        equal the jump exactly
# And the 1788469743 honest tapes (a later shed drops the earlier sheds' own
# #gap events off the queue front; the backend now declares the COALESCED
# outage on every shed, and a surviving earlier half must not confuse the match):
#   dropped-first-gap            exit 0  jump [2..5); chain declares [3..4) and
#                                        the coalesced [2..5) — matched directly
#   overlap-first-gap            exit 0  jump [2..5); chain declares [2..3) and
#                                        the coalesced [2..5) — an overlap is
#                                        never merged, the exact match still hits
# And the #55.6 WINDOW-mode lies (`--last N`; the gate ran --full only before):
#   window-liar --last 3         exit 0 AND 2 links — the head's uncertified
#                                        chainStartSeq (= headSeq) no longer
#                                        clamps the window start; pre-fix the
#                                        run walked ONE event: "✓ 0 chain
#                                        links verified", exit 0
#   window-clip-liar --last 3    exit 1  the same claim moved into the
#                                        routing list (firstSeq = headSeq):
#                                        the clip is a coverage jump [0..2)
#                                        nothing bridges or declares
#   consistent-liar --last 3     exit 1  the full-walk liar meets the same
#                                        rule in window mode
#   double-shed --last 10        exit 0  an honest clip at a re-anchor: the
#                                        jump [2..4) is declared on the chain
#   genesis-only --last 3        exit 0  one event, zero links, legitimately
# And 1788472713 — the window is a CLIPPED FULL WALK: `--last N` routes the
# request newest-backwards across the routing list, VISITS every archive
# holding tape inside the window (hash carried across each boundary, every
# visited sealed head compared and certificate-checked), justifies the jumps
# INSIDE the window exactly as list jumps, and skips only the tape below the
# window. Pre-fix the window clipped at the active archive's firstSeq and
# printed "not visited; run --full" — right after a rotation `--last 500`
# verified a handful of links.
#   double-shed --last 10        exit 0  3 links (the sealed segment's 1 + the
#                                        active's 2), "archive 1/2" walked,
#                                        "(sealed) [certified]", the inner
#                                        jump [2..4) justified by the merged
#                                        #gap run (pre-fix: 2 links, clipped)
#   two-archives --last 10       exit 0  2 links, 2/2 archives, 1 sealed
#                                        certificate validated separately
#   two-archives --last 2        exit 0  the sealed segment walked from INSIDE
#                                        it (self-seeded from its seq 0)
#   two-archives --last 1        exit 0  the window's edge: bridged by the
#                                        unvisited predecessor's last event,
#                                        named as not visited
#   fabricated-gap --last 10     exit 1  the tuple at a contiguous boundary
#                                        INSIDE the window is refused exactly
#                                        as --full refuses it (empty [2..2))
#                                        — the sealed segment was visited
# And the #55 (1788468754) CLOSED-season walk (`--season N`; before it the
# verifier only ever consulted getArchives, which the season boundary detaches
# the closed chain from — the prize-audit record was verifiable in principle,
# not in practice):
#   sealed-season --season 1     exit 0  routes by getSeasonArchives(1): the
#                                        sealed segment + the tip, the empty
#                                        pre-spawned successor skipped, the
#                                        NEW season's getLedgerGaps tuple
#                                        ignored (2 links across the boundary),
#                                        walked head == SeasonRecord.chainHead
#   season-head-liar             exit 1  record chainHead the walk never reaches
#   season-extent-liar           exit 1  record finalEventSeq ≠ tape end + 1
#   season-truncated             exit 1  season table omits the sealed segment
#                                        — the origin pin holds for seasons
#   sealed-season --season 2     exit 1  no SeasonRecord for that season
#   sealed-season --season 1 --last 3  exit 2  a sealed season walks in full
#   season-wiped --season 1      exit 1  (1788477403) the record is intact but
#                                        getSeasonArchives(1) is EMPTY — the
#                                        shape a #dev/#play resetExchange
#                                        leaves; refused as "names 3 archive(s)
#                                        but none is routed any more ...
#                                        resetExchange", never as "no segment
#                                        holds any event"
# And 1788474114 (the boundary preserves the closed season's gap tuples and
# shed re-baselines — getSeasonGaps(N) / getSeasonShedBaselines(N) — and the
# season walk consults THOSE where the live walk consults the live pair):
#   season-shed --season 1 --fold  exit 0  the preserved tuple [2..3) is the
#                                        re-anchor claim, proven by the tip's
#                                        #gap[2..3); the fold RESETS at the
#                                        preserved baseline [4..5) → ICP 0.01
#                                        (7.51 pre-fix), "healed by 1
#                                        re-baseline(s)", no "not preserved"
#   season-fabricated-gap --season 1  exit 1  a preserved tuple at a continuous
#                                        boundary is refused like fabricated-gap
#                                        (a preserved claim is still a claim)
#
# And H-18 (F10 + F21, task 1788467615). F10: the tail-skew concession let a
# walk that stopped SHORT of the certified head exit 0 with "chain links
# verified" and "IC certificate VALID" — the certificate was genuine, but it
# covered a head the walk never reached, so nothing certified covered the
# walk. Now a truncated tail is ANCHORED or the run is INCONCLUSIVE (exit 3,
# a distinct code): the verifier re-fetches getCertifiedHead (bounded by
# --anchor-retries) and either the tape catches up to a fresh head (recomputed
# head == that head, that certificate validated) or a fresh head lands INSIDE
# the readable window (recomputed hash AT that seq == it). Both --full and
# --last. F21: a served routing list with a non-final open row (lastSeq null)
# or ranges not strictly ascending is refused before the walk, in both
# mirrors; the CLI concession is limited to the LAST entry.
#   good-cert WITHHOLD=2         exit 3  the honest-skew shape with no
#                                        catch-up: INCONCLUSIVE, no
#                                        "chain links verified", no VALID
#                                        (pre-fix: exit 0 — the F10 lie)
#   good-cert WITHHOLD=2 CATCHUP exit 0  the tape catches up on the re-fetch:
#                                        2 links, "caught up", VALID
#   good-cert WITHHOLD=2 FRESH_HEAD=1
#                                exit 0  a fresh certified head at seq 1,
#                                        inside the readable window: anchored
#                                        at the recomputed hash AT seq 1
#   the same three under --last 3        exit 3 / 0 / 0
#   fabricated-prefix            exit 3  fake [0..1] under a genuine
#                                        certificate for the withheld real
#                                        head: never VALID (pre-fix: exit 0)
#   fabricated-prefix FRESH_HEAD=1
#                                exit 1  the fresh head IS the real seq 1 —
#                                        the fake recomputed hash ≠ it
#   unsealed-predecessor         exit 1  two open rows + a gap tuple: the
#                                        list is malformed (pre-fix: exit 0)
#   overlapping-list             exit 1  ranges not strictly ascending
#   good-cert MDX_STUB_TAIL=1    exit 1  still the zero-progress rule — a
#                                        host serving nothing is a FAILURE,
#                                        not an inconclusive
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
EXTRA_ARGS=""   # extra verifier CLI args for one run: EXTRA_ARGS="--x y" runv …
runv() {  # runv <scenario> [extra env as k=v...]
  # shellcheck disable=SC2086  # EXTRA_ARGS is deliberately word-split
  ( cd "$H" && env -u MDX_STUB_TAIL -u MDX_STUB_WITHHOLD \
      MDX_REAL_VERIFIER="$REPO/scripts/verify_ledger.mjs" \
      MDX_STUB_SCENARIO="$1" "${@:2}" \
      node verify_ledger.mjs --backend aaaaa-aa --host https://icp-api.io --full $EXTRA_ARGS \
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

# ── 1788465046: the REPLAYED certificate. Certificate.create returns
# normally (parseable, "valid") but lookup_path answers ANOTHER canister's
# head — the sealed segment's. bad-cert throws before lookup_path is reached
# and every other scenario answers the correct head, so the `eq(res.value,
# head)` conjunct never decided a verdict before this. The two assertions
# pin the two sites SEPARATELY by refusal text: in --full the per-segment
# validateArchiveCert fires first ("segment's head"); in --last on this
# single-archive tape no sealed segment is visited, so only the active-head
# check after the walk can fire ("IC certificate does NOT commit to this
# head"). Drop the conjunct at one site and exactly that site's assertion
# goes red. ──
RC=$(runv wrong-head)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "does NOT commit to this segment's head" \
   && echo "$OUT" | grep -q "\[stub\] Certificate.create reached"; then
  ok "wrong-head --full: exit 1 — a parseable certificate committing to another canister's head is refused at the per-segment site"
else nok "replayed certificate accepted at validateArchiveCert (eq conjunct dead)" "rc=$RC $(echo "$OUT" | grep -E '✗|VALID|commit' | tail -1)"; fi

RC=$(EXTRA_ARGS="--last 3" runv wrong-head)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "IC certificate does NOT commit to this head" \
   && ! echo "$OUT" | grep -q "segment's head" \
   && echo "$OUT" | grep -q "\[stub\] Certificate.create reached"; then
  ok "wrong-head --last 3: exit 1 — the same replay is refused at the active-head site (the only certificate check a single-archive window runs)"
else nok "replayed certificate accepted at the active-head check (eq conjunct dead)" "rc=$RC $(echo "$OUT" | grep -E '✗|VALID|commit' | tail -1)"; fi

# --anchor-retries 1: one re-fetch is all these offline shapes need (the
# catch-up flips on the SECOND getCertifiedHead call); the default 5 would
# only add sleeps. A pre-fix verifier ignores the flag (unknown flags are
# inert), so the RED runs below are the same invocations.
RC=$(EXTRA_ARGS="--anchor-retries 1" runv good-cert MDX_STUB_TAIL=1)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "nothing verifiable"; then
  ok "good-cert + all-[] tape: exit 1 (zero-progress rule — the #37.1 lie; a FAILURE, not inconclusive)"
else nok "empty-tape verdict wrong (pre-W2-02 this was exit 0)" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# ── H-18 (F10): the honest-skew shape is no longer a pass by itself. One
# event withheld under a genuine certificate for the head beyond it: the walk
# checked 1 link and NOTHING certified covers it. Pre-fix: exit 0, "✓ 1 chain
# links verified", "IC certificate VALID". ──
RC=$(EXTRA_ARGS="--anchor-retries 1" runv good-cert MDX_STUB_WITHHOLD=2)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "3" ] && echo "$OUT" | grep -q "INCONCLUSIVE" \
   && ! echo "$OUT" | grep -q "chain links verified" && ! echo "$OUT" | grep -q "VALID"; then
  ok "good-cert + 1-event skew, no catch-up: exit 3 INCONCLUSIVE — no 'chain links verified', no VALID (the F10 lie)"
else nok "an unanchored walk was vouched for (F10)" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|INCONCLUSIVE' | tail -2 | tr '\n' ' ')"; fi

# The passing control, re-based on the stub's catch-up mode: the withheld
# event becomes readable once the verifier re-fetches the head; the walk then
# REACHES the certified head and is compared against it.
RC=$(EXTRA_ARGS="--anchor-retries 1" runv good-cert MDX_STUB_WITHHOLD=2 MDX_STUB_CATCHUP=1)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 2 chain links verified" \
   && echo "$OUT" | grep -q "caught up" && echo "$OUT" | grep -q "IC certificate VALID" \
   && echo "$OUT" | grep -q "\[stub\] Certificate.create reached"; then
  ok "good-cert + 1-event skew that CATCHES UP on the re-fetch: exit 0, 2 links, anchored at the certified head (the legitimate live-tape case)"
else nok "honest catch-up control broken (over-tightened verifier?)" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|caught|INCONCLUSIVE' | tail -3 | tr '\n' ' ')"; fi

# The other honest anchor: the re-fetch lands on the replica that SERVES the
# tape, which certifies its own (lower) head at seq 1 — inside the readable
# window. The recomputed hash AT seq 1 is compared and THAT certificate is
# validated; the walk is anchored without ever reaching seq 2.
RC=$(EXTRA_ARGS="--anchor-retries 1" runv good-cert MDX_STUB_WITHHOLD=2 MDX_STUB_FRESH_HEAD=1)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 1 chain links verified" \
   && echo "$OUT" | grep -q "anchored at a fresh certified head: seq 1" && echo "$OUT" | grep -q "IC certificate VALID"; then
  ok "good-cert + 1-event skew + fresh head at seq 1: exit 0 — anchored at the recomputed hash AT seq 1, that certificate validated"
else nok "fresh-head-inside-window anchor broken" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|anchored|INCONCLUSIVE' | tail -3 | tr '\n' ' ')"; fi

# The same three shapes under --last (the window path has its own copy of
# the concession).
RC=$(EXTRA_ARGS="--last 3 --anchor-retries 1" runv good-cert MDX_STUB_WITHHOLD=2)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "3" ] && echo "$OUT" | grep -q "INCONCLUSIVE" \
   && ! echo "$OUT" | grep -q "chain links verified" && ! echo "$OUT" | grep -q "VALID"; then
  ok "--last 3 + 1-event skew, no catch-up: exit 3 INCONCLUSIVE (window path)"
else nok "an unanchored WINDOW walk was vouched for (F10, --last)" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|INCONCLUSIVE' | tail -2 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--last 3 --anchor-retries 1" runv good-cert MDX_STUB_WITHHOLD=2 MDX_STUB_CATCHUP=1)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 2 chain links verified" && echo "$OUT" | grep -q "caught up"; then
  ok "--last 3 + skew that catches up: exit 0, 2 links (window path anchored)"
else nok "window catch-up control broken" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|caught|INCONCLUSIVE' | tail -3 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--last 3 --anchor-retries 1" runv good-cert MDX_STUB_WITHHOLD=2 MDX_STUB_FRESH_HEAD=1)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 1 chain links verified" && echo "$OUT" | grep -q "anchored at a fresh certified head: seq 1"; then
  ok "--last 3 + fresh head at seq 1: exit 0, anchored inside the window (window path)"
else nok "window fresh-head anchor broken" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|anchored|INCONCLUSIVE' | tail -3 | tr '\n' ' ')"; fi

# ── H-18 (F10): the attack the concession admitted. A self-consistent FAKE
# prefix [0..1] served under a GENUINE certificate for the real (withheld)
# head at seq 2. Pre-fix: 1 link walked, skew 1, "✓ 1 chain links verified",
# "✓ IC certificate VALID", exit 0 — the certificate vouched for a head the
# walk never touched. ──
RC=$(EXTRA_ARGS="--anchor-retries 1" runv fabricated-prefix)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "3" ] && echo "$OUT" | grep -q "INCONCLUSIVE" && ! echo "$OUT" | grep -q "VALID" \
   && ! echo "$OUT" | grep -q "chain links verified"; then
  ok "fabricated-prefix: exit 3 — a fake prefix under a genuine certificate for a withheld head is never VALID"
else nok "fabricated prefix vouched for under a genuine certificate (the F10 attack)" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|INCONCLUSIVE' | tail -2 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--anchor-retries 1" runv fabricated-prefix MDX_STUB_FRESH_HEAD=1)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "recomputed hash at seq 1 ≠"; then
  ok "fabricated-prefix + fresh head at seq 1: exit 1 — the real certified hash at seq 1 ≠ the fake tape's recomputed hash"
else nok "fake prefix matched a real fresh head" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|anchored' | tail -2 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--last 3 --anchor-retries 1" runv fabricated-prefix)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "3" ] && echo "$OUT" | grep -q "INCONCLUSIVE" && ! echo "$OUT" | grep -q "VALID"; then
  ok "fabricated-prefix --last 3: exit 3 — the window path refuses to vouch too"
else nok "fabricated prefix vouched for in window mode" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?|INCONCLUSIVE' | tail -2 | tr '\n' ' ')"; fi

# ── H-18 (F21): the malformed routing lists. getArchives appends exactly one
# open row (the active archive) after the sealed ones, so a non-final row
# with lastSeq null is a shape the backend cannot emit. Pre-fix the CLI
# walked the first open row to the head, took the tail concession on it (it
# keyed on lastSeq null, not on being last), then nulled the seed at the
# second open row with NO justification pushed (guarded on the predecessor's
# lastSeq): exit 0, the active segment linked to nothing. ──
RC=$(EXTRA_ARGS="--anchor-retries 1" runv unsealed-predecessor)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "routing list malformed" && ! echo "$OUT" | grep -q "chain links verified"; then
  ok "unsealed-predecessor: exit 1 — a non-final open row is refused before the walk"
else nok "unsealed non-final row honored (the F21 attack)" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?' | tail -2 | tr '\n' ' ')"; fi

RC=$(runv overlapping-list)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "routing list malformed"; then
  ok "overlapping-list: exit 1 — ranges not strictly ascending are refused as malformed"
else nok "overlapping ranges not refused as malformed" "rc=$RC $(echo "$OUT" | grep -E '✓|✗|\?' | tail -2 | tr '\n' ' ')"; fi

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

# ── #55.1: the consistent liar. Same omission as truncated-list, but the
# active head now claims chainStartSeq = its own firstSeq (2) — exactly the
# per-canister anchor a REAL second segment holds, so the host is consistent
# with itself. Pre-fix the genesis pin defaulted its origin to that claim and
# `firstSeq > origin` was false by construction: exit 0, "0 chain links
# verified". The certificate is genuine; the refusal must come from an origin
# the host did not get to choose. ──
RC=$(runv consistent-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "early archives omitted"; then
  ok "consistent-liar: exit 1 — the origin defaults to 0, not to the host's chainStartSeq"
else nok "consistent liar verified clean (origin taken from the party under audit)" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# The override is still the override: an operator vouching out-of-band for a
# later origin (a dev venue whose tape predates the chain code) gets the walk
# they asked for — and this proves the accept path is alive, not that the
# default merely throws on everything.
RC=$(EXTRA_ARGS="--expect-start 2" runv consistent-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "chain links verified"; then
  ok "consistent-liar + --expect-start 2: exit 0 — the explicit out-of-band anchor overrides"
else nok "--expect-start override dead" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# ── #55.1 flag hygiene: a numeric flag is absent or a well-formed integer.
# Pre-fix a bare --max-tail-skew parsed to NaN, `skew > NaN` was false, and
# the #37.1 bound was silently OFF; a bare --expect-start was silently
# ignored. Both now exit 2 with the flag named, before any query. ──
RC=$(EXTRA_ARGS="--max-tail-skew" runv good-cert MDX_STUB_WITHHOLD=2)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "2" ] && echo "$OUT" | grep -q -- "--max-tail-skew needs a non-negative integer"; then
  ok "bare --max-tail-skew: exit 2, refused loudly (was NaN = bound disabled)"
else nok "bare --max-tail-skew not refused" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

RC=$(EXTRA_ARGS="--expect-start abc" runv consistent-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "2" ] && echo "$OUT" | grep -q -- "--expect-start needs a non-negative integer"; then
  ok "non-numeric --expect-start: exit 2, refused loudly (was NaN = pin disabled)"
else nok "non-numeric --expect-start not refused" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# ── #55.4: back-to-back sheds. The honest shape: a shed drops [2..3) while
# the successor spawn is blocked, the queue refills, a second shed drops
# [3..4), the fresh archive anchors at 4. The archive between them acked
# nothing → ABANDONED, no sealed entry — so getArchives carries ONE jump
# [2..4) while the chain carries TWO declarations. Certificates genuine,
# tape honest; pre-fix: exit 1 "unjustified discontinuity". ──
RC=$(runv double-shed)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "chain links verified across 1 gap" \
   && echo "$OUT" | grep -q "justified by 2 contiguous chain-declared #gap events"; then
  ok "double-shed: exit 0 — one list jump justified by two CONTIGUOUS chain declarations"
else nok "honest back-to-back shed tape refused (the #55.4 false positive)" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# Merging is for exactly-contiguous runs only: a hole between the
# declarations, or a run that overshoots the jump, is still refused — a
# superset or a hole would re-admit the fabricated-tuple attack above.
RC=$(runv holed-shed)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "unjustified discontinuity"; then
  ok "holed-shed: exit 1 — declarations with a hole between them never merge"
else nok "holed declarations were merged across the hole" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

RC=$(runv over-shed)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "unjustified discontinuity"; then
  ok "over-shed: exit 1 — a merged run that is a SUPERSET of the jump is refused"
else nok "superset run accepted as justification" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# ── 1788469743: the coalesced declaration. A third shed under the same
# blocked spawn drops the FRONT of the queue past the earlier #gap events,
# so the backend declares the whole coalesced outage on every shed; the
# newest surviving declaration then always spans from the last acked seq.
# Both shapes an upgrade can leave on one chain — a surviving later half
# [3..4) or a surviving first half [2..3) beside the coalesced [2..5) — must
# verify: the exact match finds [2..5) itself, and the contiguous-only merge
# never fuses an overlap into a superset (over-shed above stays refused). ──
RC=$(runv dropped-first-gap)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "chain links verified across 1 gap" \
   && ! echo "$OUT" | grep -q "justified by .* contiguous"; then
  ok "dropped-first-gap: exit 0 — the coalesced [2..5) declaration justifies the jump directly beside a surviving [3..4)"
else nok "coalesced declaration beside a dropped-first-gap survivor refused" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

RC=$(runv overlap-first-gap)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "chain links verified across 1 gap" \
   && ! echo "$OUT" | grep -q "justified by .* contiguous"; then
  ok "overlap-first-gap: exit 0 — [2..3) beside the coalesced [2..5) is an overlap, never merged, and the exact match still hits"
else nok "coalesced declaration beside a surviving first half refused" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# ── #55.6: WINDOW mode. Pre-fix `--last N` took its start bound from the
# head's uncertified chainStartSeq claim: a head saying chainStartSeq = headSeq
# made from = headSeq, ONE event walked, links = 0, hash trivially equal to the
# certified head, exit 0 "✓ 0 chain links verified" — the #37.1 shape with no
# tail concession involved. The clamp is now the archive's SERVE bound
# (getArchives firstSeq — uncertified too, but it bounds what the actor can
# physically return, not what the host wants verified), the window's seed
# comes from the tape (seq from-1 on the active archive or the listed
# predecessor), a clip the tape does not bridge must be a chain-declared #gap
# run, and zero links at a start other than the chain origin is refused. ──
RC=$(EXTRA_ARGS="--last 3" runv window-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 2 chain links verified"; then
  ok "window-liar --last 3: exit 0 with 2 links — the head's chainStartSeq claim never clamps the window"
else nok "window clamped to the host's chainStartSeq claim (the #55.6 zero-progress lie)" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

RC=$(EXTRA_ARGS="--last 3" runv window-clip-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "early tape omitted"; then
  ok "window-clip-liar --last 3: exit 1 — a serve-bound clip nothing bridges or declares is refused"
else nok "routing-list clip accepted in window mode" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

RC=$(EXTRA_ARGS="--last 3" runv consistent-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "early tape omitted"; then
  ok "consistent-liar --last 3: exit 1 — the full-walk liar meets the same rule in window mode"
else nok "consistent liar verified clean in window mode" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

# The honest clip: a window reaching below a shed re-anchor. The jump [2..4)
# is declared on the chain by the two contiguous #gap events the walk visits.
# 1788472713: the window spans the re-anchor, so the sealed segment [0..1]
# is VISITED — its 1 link walked, its head compared and certificate-checked —
# and the jump [2..4) is an INNER jump justified by the merged #gap run.
# Pre-fix: "window clipped at seq 4", 2 links, the sealed segment never read.
RC=$(EXTRA_ARGS="--last 10" runv double-shed)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 3 chain links verified across 1 gap" \
   && echo "$OUT" | grep -q "archive 1/2 " && echo "$OUT" | grep -q "archive 2/2 " \
   && echo "$OUT" | grep -q "(sealed) \[certified\]" \
   && echo "$OUT" | grep -q "justified by 2 contiguous chain-declared #gap events" \
   && echo "$OUT" | grep -q "\[2\.\.4) inside the window is a chain-declared shed" \
   && echo "$OUT" | grep -q "window spans 2/2 archive" \
   && ! echo "$OUT" | grep -q "not visited"; then
  ok "double-shed --last 10: exit 0 — the sealed segment is VISITED (2/2 archives, [certified]), 3 links, the inner jump [2..4) justified by the chain's own #gap run"
else nok "window did not route across the sealed segment (1788472713)" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗|clipped|archive|spans|visited' | tail -4 | tr '\n' ' ')"; fi

# The honest rolled tape with no shed at all: the window carries the hash
# across the boundary (the cross-archive link is one of the 2), certifies
# the sealed head, and the certificate block counts it separately.
RC=$(EXTRA_ARGS="--last 10" runv two-archives)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 2 chain links verified; 1 segment certificate(s) subnet-validated" \
   && echo "$OUT" | grep -q "archive 1/2 " && echo "$OUT" | grep -q "(sealed) \[certified\]" \
   && echo "$OUT" | grep -q "window spans 2/2 archive" \
   && echo "$OUT" | grep -q "(+ 1 sealed segment(s) validated separately)" \
   && ! echo "$OUT" | grep -q "not visited"; then
  ok "two-archives --last 10: exit 0 — 2 links across the boundary, the sealed head certificate-validated separately, nothing left unvisited"
else nok "honest two-archive window broken (1788472713)" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗|archive|spans|visited|VALID' | tail -4 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--last 2" runv two-archives)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 2 chain links verified" \
   && echo "$OUT" | grep -q "archive 1/2 " && echo "$OUT" | grep -q "(sealed) \[certified\]"; then
  ok "two-archives --last 2: exit 0 — the sealed segment is walked from INSIDE it (self-seeded from seq 0), 2 links"
else nok "window starting inside a sealed segment broken (1788472713)" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗|archive' | tail -3 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--last 1" runv two-archives)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 1 chain links verified" \
   && ! echo "$OUT" | grep -q "archive 1/2 " \
   && echo "$OUT" | grep -q "1 older sealed archive(s) hold tape below seq 2" \
   && echo "$OUT" | grep -q "1 sealed segment(s) below seq 2 not visited"; then
  ok "two-archives --last 1: exit 0 — the window's edge is bridged by the unvisited predecessor's last event (1 link) and the sealed archive is named as not visited"
else nok "window-edge bridge broken (1788472713)" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗|archive|visited' | tail -3 | tr '\n' ' ')"; fi

# The W2-04 lie inside a window: the sealed segment is visited, the boundary
# is inside the window, and the tuple's re-anchor claim at a CONTIGUOUS
# boundary is the empty range [2..2) no honest chain declares — refused
# exactly as --full refuses it, not verified past by the window.
RC=$(EXTRA_ARGS="--last 10" runv fabricated-gap)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "unjustified discontinuity" && echo "$OUT" | grep -q "\[2\.\.2)" \
   && echo "$OUT" | grep -q "archive 1/2 "; then
  ok "fabricated-gap --last 10: exit 1 — the tuple at a boundary inside the window is refused as in --full (the sealed segment was visited)"
else nok "fabricated tuple honored inside a window (1788472713)" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗|archive' | tail -3 | tr '\n' ' ')"; fi

# An honest one-event tape has zero links legitimately: the rule keys on the
# walk starting at the chain origin, never on anything the host claimed.
RC=$(EXTRA_ARGS="--last 3" runv genesis-only)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 0 chain links verified"; then
  ok "genesis-only --last 3: exit 0 — one event, zero links, the honest short chain keeps passing"
else nok "honest genesis-only tape refused (over-tightened zero-progress rule)" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

# ── #55 (1788468754): a CLOSED season. getArchives lists none of its
# segments (the boundary detaches them); `--season 1` routes by
# getSeasonArchives(1) — sealed [0..1], the tip [2..], and the successor
# pre-spawned before the boundary (no events, skipped by its empty head) —
# pins the origin at 0, ignores the NEW season's getLedgerGaps tuple, carries
# the link across the sealed boundary, and must ALSO meet the SeasonRecord:
# walked head == chainHead, last seq == finalEventSeq - 1. ──
RC=$(EXTRA_ARGS="--season 1" runv sealed-season)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 2 chain links verified" \
   && echo "$OUT" | grep -q "season 1 anchored" && echo "$OUT" | grep -q "never held an event" \
   && ! echo "$OUT" | grep -q "recorded ledger gaps"; then
  ok "sealed-season --season 1: exit 0 — 2 links by the season table, successor skipped, record anchor met, new-season tuple ignored"
else nok "closed-season walk broken" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗|season' | tail -3 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--season 1" runv season-head-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "SeasonRecord's chainHead"; then
  ok "season-head-liar --season 1: exit 1 — a record chainHead the walk never reaches is refused"
else nok "season record head not enforced" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

RC=$(EXTRA_ARGS="--season 1" runv season-extent-liar)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "finalEventSeq is 4"; then
  ok "season-extent-liar --season 1: exit 1 — finalEventSeq ≠ tape end + 1 is refused"
else nok "season record extent not enforced" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

RC=$(EXTRA_ARGS="--season 1" runv season-truncated)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "early archives omitted"; then
  ok "season-truncated --season 1: exit 1 — the origin pin refuses a season table missing its sealed segment"
else nok "truncated season table verified clean" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

RC=$(EXTRA_ARGS="--season 2" runv sealed-season)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "no SeasonRecord for season 2"; then
  ok "sealed-season --season 2: exit 1 — an unrecorded season has nothing to anchor to"
else nok "unknown season not refused" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# 1788477403: a wiped season — the record intact, the season table empty (what
# resetExchange leaves behind). The verdict must say the tape was DELETED and
# name resetExchange; the pre-fix "no segment holds any event" described a
# table whose rows are merely headless, and misled on the seat-3 venue.
RC=$(EXTRA_ARGS="--season 1" runv season-wiped)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "season 1: the SeasonRecord names 3 archive(s) but none is routed any more" \
   && echo "$OUT" | grep -q "resetExchange" && ! echo "$OUT" | grep -q "no segment holds any event"; then
  ok "season-wiped --season 1: exit 1 — an empty season table under a committed record is 'archives deleted (resetExchange)', not 'no segment holds any event'"
else nok "wiped season misreported" "rc=$RC $(echo "$OUT" | grep -E 'season|✗' | tail -2 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--season 1 --last 3" runv sealed-season)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "2" ] && echo "$OUT" | grep -q -- "drop --last"; then
  ok "--season with --last: exit 2 — a sealed season is walked in full"
else nok "--season --last not refused" "rc=$RC $(echo "$OUT" | tail -2 | head -1)"; fi

# ── 1788474114: a CLOSED season that SHED. The boundary preserved its gap
# tuple [2..3) and shed baseline [4..5) (getSeasonGaps / getSeasonShedBaselines);
# the live pair still answers the NEW season's [0..2). `--season 1 --fold`
# must read the preserved pair: the re-anchor at the tip (firstSeq 3) is the
# preserved tuple's claim, proven by the chain's own #gap[2..3) at seq 3, and
# the fold RESETS at seq 4 — the folded ICP total is the re-attested 0.01,
# not 7.51 (sealed 5 + 2.5 + the re-attestation). Pre-fix neither was read
# in season mode: 7.51 and "shed re-baselines are not preserved". ──
RC=$(EXTRA_ARGS="--season 1 --fold" runv season-shed)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "0" ] && echo "$OUT" | grep -q "✓ 2 chain links verified across 1 gap" \
   && echo "$OUT" | grep -q "season 1 anchored" \
   && echo "$OUT" | grep -q "preserved at the season boundary" \
   && echo "$OUT" | grep -q "seq \[4..5)  (1 re-attestation rows — fold resets here)" \
   && echo "$OUT" | grep -qE "^  ICP +0\.01$" \
   && echo "$OUT" | grep -q "healed by" && echo "$OUT" | grep -q "1 re-baseline(s)" \
   && ! echo "$OUT" | grep -q "not preserved" && ! echo "$OUT" | grep -q "no shed re-baselines were preserved"; then
  ok "season-shed --season 1 --fold: exit 0 — the preserved tuple's re-anchor proven by the chain's #gap, the fold reset at the preserved baseline (ICP 0.01, not 7.51), healed-by reported, no 'not preserved' warning"
else nok "closed-season shed not honored from the preserved record" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗|ICP|re-baseline|preserved|season' | tail -6 | tr '\n' ' ')"; fi

RC=$(EXTRA_ARGS="--season 1" runv season-fabricated-gap)
OUT=$(cat "$H/out.txt")
if [ "$RC" = "1" ] && echo "$OUT" | grep -q "unjustified discontinuity" && echo "$OUT" | grep -q "\[2..2)"; then
  ok "season-fabricated-gap --season 1: exit 1 — a PRESERVED tuple at a continuous boundary is still only a claim (empty [2..2) has no #gap event)"
else nok "a preserved season tuple suppressed the sealed-boundary link check" "rc=$RC $(echo "$OUT" | grep -E 'chain links|✗' | tail -1)"; fi

echo ""
if [ $fail -eq 0 ]; then
  echo -e "${GREEN}PASS: test_verify_ledger_gate ($pass assertions)${NC}"; exit 0
else
  echo -e "${RED}FAIL: test_verify_ledger_gate ($fail of $((pass+fail)) failed)${NC}"; exit 1
fi
