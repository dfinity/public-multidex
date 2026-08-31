#!/bin/bash
# tests/test_deploy_hygiene.sh
#
# STATIC regression for the operator-machine defects in
# docs/issue-triage-2026-08.md §3 and §4.1. Every one of these was a real
# incident or a live vulnerability, and every one is invisible to the
# integration suite because it lives in the DEPLOY SCRIPTS, not the canister.
# So this test reads source, not state.
#
# NO REPLICA REQUIRED — it never calls a canister. That is deliberate: these
# are exactly the checks you want still working when the exchange is down.
#
# What it pins, and why each one is here:
#
#   1. awk PROGRAM-TEXT INJECTION (#10.1). deploy.sh built an awk program by
#      string interpolation, splicing in field 2 of a fixed-name file under
#      /tmp. awk has system(). Because /tmp is sticky (1777), a file planted
#      there by another local user cannot be removed or overwritten by our own
#      `rm -f` — so it is a PERSISTENT plant, not a race. Values belong in
#      `-v` bindings, where they are data and can never be parsed as code.
#
#   2. FIXED-NAME /tmp PATHS. Same root cause as (1): the plantable file. The
#      deploy scripts now use .run/ (repo-local, operator-owned, gitignored)
#      via scripts/lib/runfiles.sh.
#
#   3. BARE PATTERN KILLS (#10.2). A pattern cannot tell a local simulator
#      from one driving multidex.ai — the target used to live only in IC_ENV,
#      and environment assignments are not part of argv. This killed the LIVE
#      fleet on 2026-07-23, 2026-07-28 and 2026-08-01. Stops belong to the
#      PID-file architecture in scripts/lib/{targets,bots}.sh, which kills by
#      ancestry from a PID recorded at launch. Killing one's OWN children by
#      parent pid is fine — that is ancestry, not a pattern.
#
#   4. UNKNOWN DEPLOY TARGET (#10.5). deploy_to_engine.sh execs
#      `deploy.sh engine`, but deploy.sh's vocabulary was local|cloud|subnet,
#      so `engine` fell through to a plain passthrough that SKIPS
#      apply_anti_sybil_settings — the step that re-stamps production
#      frontend_origins, whose absence took multidex.ai sign-in down on
#      2026-07-11. An unrecognised target must now be a HARD ERROR.
#
#   5. lint-ratchet's DEAD TYPE-CHECK (§4.1). It ran moc without the project's
#      build flags, and detected failure with a pattern moc never emits, so it
#      matched nothing and reported success unconditionally.
#
#   6. UNPINNED FRONTEND BUILD (#10.4). The build that produces the assets
#      served from multidex.ai must install exactly what the lockfile pins.
#
#   7. BRIDGE POSTURE (§2.15). The Bridge had no posture concept at all, and
#      icp.yaml wires this same stub into BOTH production-facing targets.
#
# Uses _lib.sh's _ok/_fail counters but its own matchers and summary. NOT
# _lib.sh's assert_contains: that helper strips underscores from the haystack
# (a Candid number-formatting quirk) and treats the needle as a REGEX, so a
# source needle like IS_PRODUCTION or '*.mo' could never match correctly.

source "$(dirname "$0")/_lib.sh"

ROOT="$SCRIPT_DIR"
cd "$ROOT" || exit 1

echo "── test_deploy_hygiene ──"

# ── Literal source matchers ───────────────────────────────────────
# grep -cF >/dev/null, NOT grep -qF (W5-10 item 3): -q exits at the first
# match WITHOUT draining, the printf takes SIGPIPE, and the pipefail
# inherited from _lib.sh promotes 141 into the pipeline status — so a
# MATCHED needle lands in the failure branch. Latent while every haystack
# was ≤7KB (onset ≈48KB); W3-05's whole-main.mo haystack (≈488KB) made it
# fire deterministically. -c drains the stream fully and exits 0 iff the
# count is non-zero.
src_has() {   # src_has <name> <haystack> <literal needle>
  if printf '%s\n' "$2" | grep -cF -- "$3" >/dev/null; then _ok "$1"
  else _fail "$1 — expected to find: $3"; fi
}
src_lacks() { # src_lacks <name> <haystack> <literal needle>
  if printf '%s\n' "$2" | grep -cF -- "$3" >/dev/null; then
    _fail "$1 — found banned text: $3"
    printf '%s\n' "$2" | grep -nF -- "$3" | head -5 | sed 's/^/      /' >&2
  else _ok "$1"; fi
}

# Strip shell/YAML comments before scanning, so a line DOCUMENTING a banned
# pattern (several of them deliberately quote the old bug, and so does this
# file) is not itself a hit.
# Anchored to line-START (W5-10 item 4): the old `s/#.*//` cut at the first
# `#` BYTE, including one inside a double-quoted string — so a banned pattern
# written after a `#` inside a string was invisible to every ban scan. Now
# only full-line comments are stripped; trailing-comment text is scanned
# (reword a comment rather than weakening this).
uncommented() { sed 's/^[[:space:]]*#.*//' "$1"; }
# Same idea for Motoko, on stdin: the comment inside claim() that explains why
# ledgerOf is deliberately NOT called must not read as a call to it.
mo_code() { sed 's://.*::'; }

# Extract one Motoko function body by brace depth from its signature line.
# A sed line-range cannot do this: the closing brace of `claim` is at the same
# indent as several later declarations, so a range over-runs into the next
# function and the assertions silently test the wrong code.
mo_func() {   # mo_func <file> <signature substring>
  # `seen` is load-bearing: a Motoko signature may wrap before its opening
  # brace (a multi-line return type is the usual reason), and without it the
  # depth test fires on the signature line itself and extraction stops after
  # ONE line. That fails loudly for src_has but passes VACUOUSLY for src_lacks,
  # which is the dangerous direction — so don't start counting down until an
  # opening brace has actually been seen.
  #
  # Braces are counted on a CODE-ONLY image of each line (W5-10 item 7): the
  # old count included braces inside comments and string literals, so a
  # phantom `}` in a doc comment ended the window early and every src_lacks
  # below it passed vacuously — the reporter truncated the heartbeat window
  # from 64 lines to 43 with one comment and all six liquidation-breaker
  # assertions stayed green. The scanner tracks Motoko line comments (//),
  # NESTED block comments (/* */), and string/char literals with escapes;
  # the signature match also reads the code image, so a comment QUOTING a
  # signature cannot start the window. Output lines stay the originals.
  awk -v sig="$2" '
    function codeimg(line,   i, n, ch, nx, out) {
      out = ""; i = 1; n = length(line)
      while (i <= n) {
        ch = substr(line, i, 1); nx = substr(line, i, 2)
        if (bc > 0) {
          if (nx == "/*") { bc++; i += 2; continue }
          if (nx == "*/") { bc--; i += 2; continue }
          i++; continue
        }
        if (instr) {
          if (ch == "\\") { i += 2; continue }
          if (ch == "\"") { instr = 0 }
          i++; continue
        }
        if (inchr) {
          if (ch == "\\") { i += 2; continue }
          if (ch == "\x27") { inchr = 0 }
          i++; continue
        }
        if (nx == "//") { break }
        if (nx == "/*") { bc = 1; i += 2; continue }
        if (ch == "\"") { instr = 1; i++; continue }
        if (ch == "\x27") { inchr = 1; i++; continue }
        out = out ch
        i++
      }
      # Motoko text/char literals do not span lines; comments via bc do.
      instr = 0; inchr = 0
      return out
    }
    {
      code = codeimg($0)
      if (!on && index(code, sig)) { on = 1 }
      if (on) {
        print
        o = gsub(/\{/, "&", code)
        c = gsub(/\}/, "&", code)
        depth += o - c
        if (o > 0) { seen = 1 }
        if (seen && depth <= 0) exit
      }
    }
  ' "$1"
}

# The scripts that run on a deploy path. Explicit rather than globbed: a new
# script must be added here CONSCIOUSLY, which is the point of a ratchet.
DEPLOY_SCRIPTS="
scripts/deploy.sh
scripts/deploy_to_local.sh
scripts/deploy_to_engine.sh
scripts/deploy_to_subnet.sh
scripts/cold_start.sh
scripts/play_start.sh
scripts/seed.sh
scripts/inject_history.sh
"

# ── 1. No awk program-text interpolation anywhere in scripts/ ─────
# A double-quoted awk program is one a shell variable can be spliced into; a
# single-quoted program with -v bindings cannot be. This bans the SHAPE, not
# just today's instances.
AWK_HITS=""
for f in scripts/*.sh scripts/lib/*.sh; do
  [ -f "$f" ] || continue
  h=$(uncommented "$f" | grep -nE 'awk +"' || true)
  [ -n "$h" ] && AWK_HITS="$AWK_HITS $f:$h"
done
assert_eq "no awk program-text interpolation in scripts/" "" "$(printf '%s' "$AWK_HITS" | tr -d '[:space:]')"

# The site that was exploitable. Assert the FIX is present, not merely that
# the old shape is gone.
SEED_PX=$(sed -n '/^seed_px()/,/^}/p' scripts/deploy.sh)
src_has   "seed_px binds the price with -v (data, not program text)" "$SEED_PX" 'awk -v p='
src_has   "seed_px validates the price against a decimal pattern"    "$SEED_PX" '^[0-9]+(\.[0-9]+)?$'
src_lacks "seed_px has no interpolated awk program"                  "$SEED_PX" 'awk "'

# ── 2. No fixed-name /tmp paths in the deploy scripts ─────────────
TMP_HITS=""
for f in $DEPLOY_SCRIPTS scripts/simulate_trading.sh; do
  [ -f "$f" ] || continue
  h=$(uncommented "$f" | grep -n '/tmp/' || true)
  [ -n "$h" ] && TMP_HITS="$TMP_HITS $f:$h"
done
assert_eq "no fixed /tmp paths in the deploy scripts" "" "$(printf '%s' "$TMP_HITS" | tr -d '[:space:]')"
src_has "runfiles.sh defines the shared price-snapshot path" \
  "$(cat scripts/lib/runfiles.sh)" "MDX_ORACLE_PRICES"

# The writer and every reader must agree on ONE path. If they drift, the
# readers silently fall back to stale hardcoded prices and walk a freshly
# seeded AMM off its real price — a failure play_start.sh already documents.
for f in scripts/inject_history.sh scripts/deploy.sh scripts/play_start.sh \
         scripts/seed.sh scripts/simulate_trading.sh; do
  src_has "$(basename "$f") reads/writes the shared snapshot path" "$(cat "$f")" "MDX_ORACLE_PRICES"
done

# ── 3. No pattern-selection kills anywhere: pkill -f OR pgrep -f ──
# SCOPE EXTENSION 1: tests/*.sh joined $DEPLOY_SCRIPTS as a GLOB. Nine test
# files carried their own `pkill -9 -f simulate_trading.sh` — the exact class
# recorded above as killing the live fleet three times — precisely because
# this scan read only the explicit deploy list, so the ban never reached one
# directory over. Tests are where stop-the-sim lines keep being (re)written,
# so a NEW test must be covered without anyone remembering a list.
# SCOPE EXTENSION 2 (W1-01, the FIFTH instance): all of scripts/,
# scripts/lib/ and ops/ are scanned too, and `pgrep -f` is banned alongside
# `pkill -f`. stop_local_bots.sh was not a pkill: it SELECTED pids with
# `pgrep -f` on a script-name regex held in a VARIABLE, then killed them in
# a loop — same kill, different spelling, and no same-line script-name test
# can see through a variable, so the MECHANISM is banned, not a list of
# names. When 16137cf pointed every target at trading_simulation.sh, that
# script's "local-only" pattern came to select the LIVE subnet fleet while
# its last line still printed "live subnet fleet untouched".
# The flag class MUST include digits: the tests' variant was `pkill -9 -f`,
# and `[A-Za-z]` alone let the signal flag slip straight past the scan — the
# glob extension without this was verified to still miss all nine files.
# Two REPORTING shapes are exempt, as exact spellings ([-]f keeps the
# exemption from matching this file's own scan lines), each scoped to the
# ONE file that owns it (W1-06 moved the pocket-ic enumeration into
# targets.sh's mdx_stray_masters): the master enumerator
# `pgrep -f "pocket-ic --ttl"` (selects the local replica binary, never a
# script; detection only) and bots.sh's stray reporter
# `pgrep -f "MDX_TARGET=` (prints pids, kills nothing). The same spelling
# anywhere ELSE is a new instance of the banned class. Any other spelling
# must fail here and either move to the PID-file architecture or be
# exempted CONSCIOUSLY, in this file, with a reason.
PATKILL_HITS=""
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh $(find ops -type f 2>/dev/null); do
  [ -f "$f" ] || continue
  case "$f" in
    scripts/lib/targets.sh) ALLOW='pgrep [-]f "pocket-ic --ttl' ;;
    scripts/lib/bots.sh)    ALLOW='pgrep [-]f "MDX_TARGET=' ;;
    *)                      ALLOW='W1MDX-NEVER-MATCHES' ;;
  esac
  h=$(uncommented "$f" | grep -nE 'p(kill|grep) +(-[A-Za-z0-9]+ +)*-f' \
                       | grep -vE "$ALLOW" || true)
  [ -n "$h" ] && PATKILL_HITS="$PATKILL_HITS $f:$h"
done
assert_eq "no pattern-matched process kill/selection via -f in scripts/, ops/ or tests/" "" "$(printf '%s' "$PATKILL_HITS" | tr -d '[:space:]')"

# And the instance that motivated extension 2 stays retired: the file must
# not come back under its old name with its old "local only" header claim.
if [ -e scripts/stop_local_bots.sh ]; then
  _fail "scripts/stop_local_bots.sh is back — stops go through stop_bots_<target>.sh (PID-file ancestry)"
else
  _ok "stop_local_bots.sh (the pattern-matching stopper) stays retired"
fi

# ── 3b. The reaper trio resolves its owner from the CLI record ────
# (W1-06.) The "legitimate master" used to be whoever listens on TCP 8000 —
# true only for the canonical checkout. Under the worktree-parallel
# workflow (random gateway port) cold_start killed the worktree's OWN
# healthy master, and deploy.sh's inline copy had NO cwd filter at all, so
# any other project's replica — a normal machine state — tripped its
# zombie nag on every local deploy. All three now delegate to
# mdx_stray_masters / mdx_local_gateway (lib/targets.sh), which resolve
# the owner via `icp network status` — the same ICP_HOME + cwd scope that
# `icp network stop` acts on, so the judgment and the stop cannot diverge.
TGT_CODE=$(uncommented scripts/lib/targets.sh)
src_has "targets.sh resolves the gateway from the CLI record" "$TGT_CODE" "icp network status"
src_has "targets.sh defines the stray-master detector"        "$TGT_CODE" "mdx_stray_masters()"
for f in scripts/cold_start.sh scripts/play_start.sh scripts/deploy.sh; do
  CODE=$(uncommented "$f")
  src_lacks "$(basename "$f") no longer hardwires the :8000 owner"  "$CODE" "lsof -nP -tiTCP:8000"
  src_has   "$(basename "$f") detects strays via mdx_stray_masters" "$CODE" "mdx_stray_masters"
done

# cold_start.sh is the script that had not been migrated (play_start.sh had).
COLD=$(cat scripts/cold_start.sh)
src_has "cold_start stops bots via the PID-file wrapper"  "$COLD" "stop_bots_local.sh"
src_has "cold_start starts bots via the PID-file wrapper" "$COLD" "start_bots_local.sh"
src_has "cold_start fails fast on an unhandled error"     "$COLD" "set -euo pipefail"

# ── 4. deploy.sh rejects an unknown target, non-zero ──────────────
UNKNOWN_OUT=$(DEPLOY_TARGET="definitely-not-a-target" bash scripts/deploy.sh 2>&1)
UNKNOWN_RC=$?
assert_eq "unknown target exits non-zero" "1" "$UNKNOWN_RC"
src_has "unknown target names the mistake"          "$UNKNOWN_OUT" "Unknown deploy target"
src_has "unknown target lists the real vocabulary"  "$UNKNOWN_OUT" "local | engine | subnet"
# The failure mode being pinned: it must NOT have quietly become a passthrough.
src_lacks "unknown target did not fall through to a passthrough" "$UNKNOWN_OUT" "Plain passthrough"

# `engine` — the exact spelling deploy_to_engine.sh passes — must be a
# recognised keyword, not an unrecognised word that lands in the passthrough.
DEPLOY_SRC=$(cat scripts/deploy.sh)
src_has "deploy.sh accepts the engine keyword"    "$DEPLOY_SRC" "local|cloud|engine|subnet)"
src_has "deploy.sh canonicalises the target"      "$DEPLOY_SRC" "canonical_target()"
src_has "cloud survives as an alias for engine"   "$DEPLOY_SRC" "engine|cloud)"
src_has "deploy.sh routes engine to the remote flow" "$DEPLOY_SRC" '[ "$TARGET" = "engine" ]'
# Vocabulary agreement with the single source of truth for what a target IS.
src_has "targets.sh vocabulary is local|engine|subnet" \
  "$(cat scripts/lib/targets.sh)" "local|engine|subnet)"
src_has "deploy_to_engine.sh passes the canonical name" \
  "$(cat scripts/deploy_to_engine.sh)" '"engine"'

# ── 5. lint-ratchet's type-check gates on exit codes ──────────────
# Scan CODE only: this script's own header, and lint-ratchet's, both quote the
# broken detector on purpose.
LR_CODE=$(uncommented scripts/lint-ratchet.sh)
LR_ALL=$(cat scripts/lint-ratchet.sh)
src_lacks "lint-ratchet no longer detects errors by text pattern" "$LR_CODE" "grep -qE ': error'"
src_has   "lint-ratchet type-checks with the real build flags"    "$LR_CODE" "--default-persistent-actors"
src_has   "lint-ratchet passes --implicit-package=core"           "$LR_CODE" "--implicit-package=core"
src_has   "lint-ratchet gates the backend check on moc's exit code" "$LR_CODE" 'TYPE_RC'
src_has   "lint-ratchet gates the test check on moc's exit code"  "$LR_CODE" 'if ! T_OUT='
src_has   "lint-ratchet type-checks tests/*.mo as well"           "$LR_CODE" "find tests -name"
src_has   "lint-ratchet records why the gate was dead"            "$LR_ALL"  "unconditionally"

# Behavioural proof that a moc error IS detectable this way — and that the old
# text detector would have missed it. Runs moc directly with the gate's flags
# so it stays fast and does not depend on the rest of the ratchet being green.
# Skip cleanly when the toolchain isn't usable — `mops toolchain bin moc` can
# print a path that doesn't execute, so probe the binary rather than trusting
# the string (lint-ratchet skips on the same principle).
MOC_BIN=$(mops toolchain bin moc 2>/dev/null || true)
MOC_SRCS=$(mops sources 2>/dev/null || true)
if [ -n "$MOC_BIN" ] && [ -n "$MOC_SRCS" ] && "$MOC_BIN" --version >/dev/null 2>&1; then
  PROBE_DIR=$(mktemp -d)
  printf 'let x : Nat = "not a Nat";\n' > "$PROBE_DIR/probe.mo"
  PROBE_OUT=$("$MOC_BIN" $MOC_SRCS --default-persistent-actors --implicit-package=core \
              --check "$PROBE_DIR/probe.mo" 2>&1)
  PROBE_RC=$?
  rm -rf "$PROBE_DIR"
  assert_eq "moc --check exits non-zero on a type error" "1" "$PROBE_RC"
  # The premise of the whole finding: moc says "type error", so a detector
  # looking for a bare ": error" matches neither this nor its own noise.
  src_has "moc reports it as a 'type error'" "$PROBE_OUT" "type error"
  if printf '%s\n' "$PROBE_OUT" | grep -qE ': error'; then
    _fail "the old ': error' detector WOULD have matched — the finding's premise is broken"
  else
    _ok "the old ': error' detector matches nothing (why the gate could not fail)"
  fi
else
  echo "  (moc unavailable — skipped the behavioural type-check proof)"
fi

# ── 6. icp.yaml enforces the committed lockfile ───────────────────
YAML_CODE=$(uncommented icp.yaml)
src_has   "icp.yaml builds the frontend from the lockfile" "$YAML_CODE" "npm ci"
src_lacks "icp.yaml does not resolve deps at build time"   "$YAML_CODE" "npm install"

# ── 6b. DEPLOY_MODE resolution: comment-aware, ambiguity-refusing ─
# (W1-02.) Four deploy-path gates re-read the posture literal by text, in
# three different spellings, and none stripped comments: a commented decoy
# above the real declaration defeated all four at once — worst case,
# deploy_to_subnet.sh ships a #dev build with the faucet open. The
# targets.sh spelling also had no head -1, so TWO matches made a two-line
# string that equals neither "dev" nor "play": ambiguity read as SAFETY.
# All four now delegate to ONE reader, mdx_posture_of (lib/targets.sh),
# which strips // comments and refuses any count but exactly 1. Probes
# drive the helper through FIXTURE files only — the real main.mo is shared
# working tree and is not touched.
MPO() { bash -c '. scripts/lib/targets.sh && mdx_posture_of "$1"' _ "$1" 2>/dev/null; }

TARGETS_CODE=$(uncommented scripts/lib/targets.sh)
src_has "targets.sh defines the one posture reader"       "$TARGETS_CODE" "mdx_posture_of()"
src_has "targets.sh deploy gate reads through the helper" "$TARGETS_CODE" 'MDX_POSTURE=$(mdx_posture_of'
for f in scripts/deploy.sh scripts/cold_start.sh scripts/play_start.sh; do
  CODE=$(uncommented "$f")
  src_has   "$(basename "$f") sources lib/targets.sh"          "$CODE" "lib/targets.sh"
  src_has   "$(basename "$f") resolves posture via the helper" "$CODE" "mdx_posture_of"
  src_lacks "$(basename "$f") has no hand-rolled -oE posture grep" "$CODE" "grep -oE 'DEPLOY_MODE"
  src_lacks "$(basename "$f") has no hand-rolled -q posture grep"  "$CODE" "grep -q 'DEPLOY_MODE"
done

# Behavioral: the helper itself, against fixtures.
POSTURE_DIR=$(mktemp -d)
printf 'actor {\n  transient let DEPLOY_MODE : DeployMode = #play;\n}\n' > "$POSTURE_DIR/clean.mo"
assert_eq "helper resolves a clean single declaration" "play" "$(MPO "$POSTURE_DIR/clean.mo")"
# THE attack: commented #play decoy above a real #dev. The old gates read
# the decoy (or a two-line string); the helper must resolve the REAL
# posture, so the remote-target gates refuse the #dev build loudly.
printf '  // transient let DEPLOY_MODE : DeployMode = #play;\n  transient let DEPLOY_MODE : DeployMode = #dev;\n' > "$POSTURE_DIR/decoy.mo"
assert_eq "a commented decoy is ignored; the real posture wins" "dev" "$(MPO "$POSTURE_DIR/decoy.mo")"
# Trailing-comment decoy — full-line-only stripping would miss this one.
printf 'let x = 1; // transient let DEPLOY_MODE : DeployMode = #play;\n  transient let DEPLOY_MODE : DeployMode = #dev;\n' > "$POSTURE_DIR/trail.mo"
assert_eq "a trailing-comment decoy is ignored too" "dev" "$(MPO "$POSTURE_DIR/trail.mo")"
# Two REAL declarations: refuse with the count — never take the first.
printf '  transient let DEPLOY_MODE : DeployMode = #play;\n  transient let DEPLOY_MODE : DeployMode = #dev;\n' > "$POSTURE_DIR/two.mo"
if MPO "$POSTURE_DIR/two.mo" >/dev/null; then _fail "two declarations must refuse (rc)"; else _ok "two real declarations refuse (non-zero)"; fi
assert_eq "two real declarations yield NO posture" "" "$(MPO "$POSTURE_DIR/two.mo")"
TWO_ERR=$(bash -c '. scripts/lib/targets.sh && mdx_posture_of "$1"' _ "$POSTURE_DIR/two.mo" 2>&1 >/dev/null || true)
src_has "the refusal names the count" "$TWO_ERR" "found 2"
# Zero declarations (file moved / shape drifted): refuse, don't guess.
printf 'actor {}\n' > "$POSTURE_DIR/none.mo"
if MPO "$POSTURE_DIR/none.mo" >/dev/null; then _fail "zero declarations must refuse (rc)"; else _ok "zero declarations refuse (non-zero)"; fi
rm -rf "$POSTURE_DIR"
# And the real tree resolves to exactly one legitimate posture word.
REAL_POSTURE=$(MPO src/backend/main.mo)
case "$REAL_POSTURE" in
  dev|play|production) _ok "src/backend/main.mo resolves unambiguously (#$REAL_POSTURE)" ;;
  *) _fail "src/backend/main.mo did not resolve cleanly (got '$REAL_POSTURE')" ;;
esac

# ── 6c. The load-shed EXIT SET stays exempt (W1-05) ───────────────
# inspect used to be caller-only: at any floor ≥ 1 every rank-0 registered
# user was refused on ALL updates pre-consensus — including the exit
# methods, none of which is reachable by query — so the congestion that
# raised the floor converted into forced liquidations. The exemption is a
# msg-variant switch inside inspect; these pins keep it from being
# "simplified" away. (The full 222-method enumeration is pinned by the
# COMPILER: a new public method is an M0127 at inspect until its tag is
# added, which forces the exit-or-sheddable classification.)
INSPECT_FN=$(mo_func src/backend/main.mo "system func inspect(")
[ -n "$INSPECT_FN" ] || _fail "could not extract inspect() — the extractor needs updating"
src_has "inspect carries the EXIT SET rationale" "$INSPECT_FN" "THE EXIT SET"
for m in cancelMyOrder cancelAllMyOrders closePosition withdrawMarginPool unstakeInsurance withdrawLp withdraw cancelPoolOrder; do
  src_has "exit set exempts $m" "$INSPECT_FN" "#$m _"
done
src_has "non-exit updates still shed by rank" "$INSPECT_FN" 'levelRank(levelOfKey(key)) >= _shedFloor'

# ── 6d. Auto-fuel guards (W3-02 / W3-03) ──────────────────────────
# Structural properties no live query can cheaply observe: the ambiguous
# interlock must gate BOTH the manual stage-2 entry and the heartbeat
# trigger; the daily budget and the burn-sample clamp must sit on the paths
# that spend/extrapolate. Behaviour is covered by test_autofuel_guards.sh.
STAGE2_FN=$(mo_func src/backend/main.mo "func fuelStage2(")
[ -n "$STAGE2_FN" ] || _fail "could not extract fuelStage2()"
src_has "stage-2 refuses while a transfer is ambiguous" "$STAGE2_FN" "_fuelAmbiguous != null"
src_has "stage-2 classifies the catch (clean vs ambiguous)" "$STAGE2_FN" "Error.isCleanReject"
src_has "stage-2 engages the ledger dedup window" "$STAGE2_FN" "created_at_time = ?"
TICK_FUEL_FN=$(mo_func src/backend/main.mo "func tickAutoFuel(")
[ -n "$TICK_FUEL_FN" ] || _fail "could not extract tickAutoFuel()"
src_has "the trigger stands down while ambiguous" "$TICK_FUEL_FN" "_fuelAmbiguous != null"
src_has "the trigger enforces the daily ICP budget" "$TICK_FUEL_FN" "AUTO_FUEL_ICP_DAILY_MAX"
src_has "the budget trip is logged, not silent" "$TICK_FUEL_FN" "daily ICP budget tripped"
BURN_FN=$(mo_func src/backend/main.mo "func closeBurnWindow(")
[ -n "$BURN_FN" ] || _fail "could not extract closeBurnWindow()"
src_has "burn extrapolation is clamped before the EMA" "$BURN_FN" "clampBurnSample"

# ── 6e. Oracle quote bases (W3-05) ────────────────────────────────
# The mark is USD-denominated: sources carry quote tags, aggregation is
# per-quote (divergence = the depeg signal), and the XRC anchor sits on the
# mark's side. Combine logic is unit-pinned (PriceFeedQuotes.test.mo);
# these pin the wiring.
MAIN_CODE_ORACLE=$(mo_code < src/backend/main.mo)
src_has "sources are quote-tagged (USD side present)"  "$MAIN_CODE_ORACLE" "quote            = #usd;"
src_has "sources are quote-tagged (USDT side present)" "$MAIN_CODE_ORACLE" "quote            = #usdt;"
src_has "refresh aggregates per quote group"           "$MAIN_CODE_ORACLE" "PriceFeed.aggregateByQuote"
src_has "a divergence is logged, not averaged away"    "$MAIN_CODE_ORACLE" "possible USDT depeg"
src_has "the XRC anchor is USD-quoted (fiat leg)"      "$MAIN_CODE_ORACLE" 'quote_asset = { symbol = "USD"; class_ = #FiatCurrency }'
src_lacks "no USDT-quoted anchor request remains"      "$MAIN_CODE_ORACLE" 'quote_asset = { symbol = "USDT"'

# ── 6f. Heartbeat subtask isolation (W3-08) ───────────────────────
# Nine subtasks ran INLINE in the beat — one trap killed maintenance
# permanently, and no breaker can attach to an inline task (its accounting
# rolls back with the beat). All nine now dispatch through hbRun behind the
# hbReady breaker; recomputeShedFloor stays inline BY CHOICE (audited
# trap-free; the floor must move in the observing beat).
HB_FN2=$(mo_func src/backend/main.mo "system func heartbeat(")
[ -n "$HB_FN2" ] || _fail "could not extract heartbeat()"
for t in reap drain tier heat leader arrears ttlsweep candles deadman; do
  src_has "heartbeat isolates '$t' via hbRun" "$HB_FN2" "hbRun(\"$t\""
done
src_has "the drain ordering decision is written down" "$HB_FN2" "ORDERING DECISION"
src_has "recomputeShedFloor stays inline by choice"   "$HB_FN2" "INLINE BY CHOICE"
src_has "the breaker judges dispatch vs completion" "$(mo_code < src/backend/main.mo | grep -A20 'func hbReady')" "disp > done"

# ── 6g. The deploy path reads the Bridge's posture too (W3-09) ────
# §7 below asserts the one-directional rule in the SUITE; these pin it on
# the DEPLOY PATH, where it was absent — a #production DEX with a #play
# Bridge would have shipped unremarked.
src_has "targets.sh gate reads the Bridge literal"  "$(uncommented scripts/lib/targets.sh)" 'mdx_posture_of "$MDX_ROOT/src/bridge/main.mo"'
src_has "deploy.sh gate reads the Bridge literal"   "$(uncommented scripts/deploy.sh)" "mdx_posture_of src/bridge/main.mo"
src_has "deploy.sh names the unbacked-credit risk"  "$(cat scripts/deploy.sh)" "unbacked-credit"

# Behavioural: fixture pair — production DEX + play bridge must refuse.
W309_DIR=$(mktemp -d)
printf '  transient let DEPLOY_MODE : DeployMode = #production;\n' > "$W309_DIR/dex.mo"
printf '  transient let DEPLOY_MODE : DeployMode = #play;\n' > "$W309_DIR/bridge.mo"
W309_OUT=$(bash -c '. scripts/lib/targets.sh
  MDX_POSTURE=$(mdx_posture_of "$1" || true)
  if [ "$MDX_POSTURE" = "production" ]; then
    BP=$(mdx_posture_of "$2" || true)
    [ "$BP" != "production" ] && { echo REFUSED; exit 1; }
  fi
  echo PASSED' _ "$W309_DIR/dex.mo" "$W309_DIR/bridge.mo" 2>&1)
rm -rf "$W309_DIR"
if printf '%s' "$W309_OUT" | grep -cF "REFUSED" >/dev/null; then
  _ok "production DEX beside a play Bridge is refused (fixture)"
else
  _fail "the production/play pair was not refused — got: $W309_OUT"
fi

# ── 6h. The arb's clip never exceeds the DEX's per-call cap (W4-08) ─
# Two constants in two canisters with no shared source: the arb sized legs
# to $10.25k while extMarketSwap refused >$5k — so the FLATTEN (the arb's
# only exit) was the refused step and inventory stuck until the mark
# happened to decline. Pin arb ≤ DEX so they cannot silently diverge again.
ARB_CAP=$(mo_code < src/arb/main.mo | grep -oE 'TRADE_CAP_USD : Nat = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
DEX_CAP=$(mo_code < src/backend/main.mo | grep -oE 'ARB_MAX_SWAP_USD    : Nat = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
if [ -n "$ARB_CAP" ] && [ -n "$DEX_CAP" ] && [ "$ARB_CAP" -le "$DEX_CAP" ]; then
  _ok "arb TRADE_CAP_USD ($ARB_CAP) ≤ DEX ARB_MAX_SWAP_USD ($DEX_CAP)"
else
  _fail "arb clip exceeds (or cannot be compared to) the DEX per-call cap — arb=$ARB_CAP dex=$DEX_CAP"
fi
# W4-17 item 5: the hourly budget must dwarf the per-call cap, or it doubles
# as a kill switch on the price-pinning mechanism (measured: ~65s to dark).
HOUR_CAP=$(mo_code < src/backend/main.mo | grep -oE 'ARB_HOURLY_CAP_USD  : Nat = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
if [ -n "$HOUR_CAP" ] && [ -n "$DEX_CAP" ] && [ "$HOUR_CAP" -ge $((DEX_CAP * 10)) ]; then
  _ok "hourly budget ≥ 10× the per-call cap ($HOUR_CAP ≥ 10 × $DEX_CAP)"
else
  _fail "hourly/per-call cap ratio too tight — hourly=$HOUR_CAP percall=$DEX_CAP"
fi
src_has "the hourly trip is logged (edge-triggered)" "$(mo_code < src/backend/main.mo)" "Hourly external-market budget tripped"
src_has "exports are exempt from the hourly budget"  "$(mo_code < src/backend/main.mo)" "side == #importBase and _arbHourUsd"
src_has "the arb unwinds a refused hedge"            "$(mo_code < src/arb/main.mo)" "unwinding the import"
src_has "extMarketSwap carries a price bound"        "$(mo_code < src/backend/main.mo)" "maxMarkE8 : ?Nat"

# ── 6h′. Arb order TTL strictly under the tick (W4-25) ─────────────
# Resting spot orders hold no reservation, so at TTL 8s > tick 5s the
# flatten exported the very base backing a still-live hedge — the
# unfilled-hedge overlap was the NORMAL case (and a late fill hit an
# unfunded maker, W4-24's cancel path). The remnant must be dead before
# the next flatten reads availBase.
ARB_TTL=$(mo_code < src/arb/main.mo | grep -oE 'ORDER_TTL_SEC : Nat = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
ARB_TICK_NS=$(mo_code < src/arb/main.mo | grep -oE 'TICK_NS       : Int = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
if [ -n "$ARB_TTL" ] && [ -n "$ARB_TICK_NS" ] && [ $((ARB_TTL * 1000000000)) -lt "$ARB_TICK_NS" ]; then
  _ok "arb ORDER_TTL_SEC (${ARB_TTL}s) < tick ($((ARB_TICK_NS / 1000000000))s) — no self-export overlap"
else
  _fail "arb ORDER_TTL_SEC must be strictly under the tick — ttl=${ARB_TTL}s tick_ns=$ARB_TICK_NS"
fi
# W4-25: the rolling window + zero-fill refund are what keep a spoof burst
# from darking the import leg for the rest of the hour.
src_has "the import budget is a rolling ring (W4-25)"  "$(mo_code < src/backend/main.mo)" "_arbMinuteBuckets"
src_has "a zero-fill round-trip refunds the budget"    "$(mo_code < src/backend/main.mo)" "Unwind refund"
src_has "the arb re-reads takeable depth post-import"  "$(mo_code < src/arb/main.mo)" "takeable depth vanished after the import"
src_has "spoofed markets back off the rich side"       "$(mo_code < src/arb/main.mo)" "rich backoff"


# ── 6i. Netted-pair dust guard (W4-03) ────────────────────────────
# cash floors to 0 when the netted base is worth <1 ICPUSD unit; below the
# guard, writeOffLoan(0) is rejected+ignored while the buyer's base debt is
# forgiven anyway — an unrecorded mutation. Driving a sub-unit pair through
# a live liquidation is not something an integration test can stage
# deterministically; pin the guard structurally, mirroring the q guard.
NETTED_FN=$(mo_func src/backend/lib/Liquidator.mo "func settleNettedPair(")
[ -n "$NETTED_FN" ] || _fail "could not extract settleNettedPair()"
src_has "settleNettedPair guards q == 0"    "$NETTED_FN" "if (q == 0) { return zero }"
src_has "settleNettedPair guards cash == 0" "$NETTED_FN" "if (cash == 0) { return zero }"

# ── 6j. Spawn lifecycle + oracle epoch (W4-13/16) ─────────────────
# Timing-dependent behaviours (a wipe racing a parked refresh; an upgrade
# landing inside a spawn's install await) cannot be staged deterministically
# from a test — pin the structures.
MAIN_MO_CODE=$(mo_code < src/backend/main.mo)
src_has "spawns are two-step and recorded (spawnArchive)" "$MAIN_MO_CODE" "func spawnArchive"
src_has "the pending spawn survives (stable var)"          "$MAIN_MO_CODE" "var _pendingSpawn"
src_has "a reconciler cleans lost spawns"                  "$MAIN_MO_CODE" "func reconcilePendingSpawn"
src_has "the heartbeat dispatches the reconciler"          "$MAIN_MO_CODE" "reconcilePendingSpawn()"
if [ "$(printf '%s\n' "$MAIN_MO_CODE" | grep -cF "Archive.Archive(Principal.fromActor(Uplands))")" = "0" ]; then
  _ok "no one-shot actor-class spawn remains (all three sites use spawnArchive)"
else
  _fail "a one-shot Archive.Archive(...) spawn remains — its principal is unrecorded across the await"
fi
src_has "the wipe bumps the oracle epoch"        "$MAIN_MO_CODE" "_oracleEpoch += 1"
src_has "a parked refresh abandons on epoch move" "$MAIN_MO_CODE" "_oracleEpoch != oracleEpoch"
W413_CLEARS=$(printf '%s\n' "$MAIN_MO_CODE" | grep -cF "_priceRefreshInFlight := false")
if [ "$W413_CLEARS" = "1" ]; then
  _ok "_priceRefreshInFlight has exactly one writer clearing it (its own finally)"
else
  _fail "_priceRefreshInFlight cleared at $W413_CLEARS sites — it has one owner (W4-13)"
fi

# ── 6k. frontend_origins read-back gate (W6-09) ───────────────────
# apply_anti_sybil_settings warns-and-continues when its settings update
# fails, so both remote tails must read the deployed value BACK and die on
# drift — on the live venue a mismatch is sign-in down (2026-07-11), not a
# warn. The gate script's parse/compare logic is driven offline via
# --from-file; the source of truth is II_PINNED_ORIGINS in main.js.
DEPLOY_SH_CODE="$(uncommented scripts/deploy.sh)"
CO_CALLS=$(printf '%s\n' "$DEPLOY_SH_CODE" | grep -cF "check_origins.sh" || true)
if [ "${CO_CALLS:-0}" -ge 2 ]; then _ok "both remote tails run the check_origins read-back ($CO_CALLS call sites)"
else _fail "check_origins.sh wired at ${CO_CALLS:-0} site(s) in deploy.sh — the subnet AND engine tails must both read the value back (W6-09)"; fi
CO_DIES=$(printf '%s\n' "$DEPLOY_SH_CODE" | grep -cF 'die "deployed frontend_origins' || true)
if [ "${CO_DIES:-0}" -ge 2 ]; then _ok "a read-back mismatch DIES the deploy at both sites (not a warn)"
else _fail "read-back mismatch dies at ${CO_DIES:-0} site(s) — a warn here is the exact hole W6-09 closes"; fi
[ -f scripts/check_origins.sh ] || _fail "scripts/check_origins.sh missing (gate cannot vouch for a file it cannot read)"
CO_SH="$(uncommented scripts/check_origins.sh)"
src_has "the gate READS the value back (settings show)"     "$CO_SH" "settings show backend"
src_has "subnet truth is II_PINNED_ORIGINS from main.js"    "$CO_SH" "II_PINNED_ORIGINS = "
src_has "the read-back call carries --identity (no default)" "$CO_SH" '--identity "$IDENTITY"'
src_has "a parse miss fails closed, never passes"           "$CO_SH" "no frontend_origins in settings output"
# Offline fixtures through the REAL script: the parser must round-trip the
# REAL main.js pin list, and dropping the canonical origin must go red.
PIN_CSV="$(sed -n '/II_PINNED_ORIGINS = \[/,/\];/p' src/frontend/src/main.js | grep -o '"https://[^"]*"' | tr -d '"' | paste -sd, -)"
PIN_N=$(printf '%s' "$PIN_CSV" | tr ',' '\n' | grep -c . || true)
if [ "${PIN_N:-0}" -ge 3 ]; then _ok "main.js II_PINNED_ORIGINS parses to $PIN_N origins"
else _fail "II_PINNED_ORIGINS parse found ${PIN_N:-0} origins — the gate's source of truth is unreadable"; fi
CO_TMP="$(mktemp -d "${TMPDIR:-/tmp}/co_gate.XXXXXX")"
printf '  frontend_origins: %s\n  trusted_attribute_signers: x\n' "$PIN_CSV" > "$CO_TMP/match.txt"
if bash scripts/check_origins.sh --from-file "$CO_TMP/match.txt" >/dev/null 2>&1; then _ok "read-back gate passes on a matching live value"
else _fail "read-back gate rejects a live value equal to II_PINNED_ORIGINS"; fi
printf '  frontend_origins: %s\n' "$(printf '%s' "$PIN_CSV" | tr ',' '\n' | grep -v 'icp\.net' | paste -sd, -)" > "$CO_TMP/miss.txt"
if bash scripts/check_origins.sh --from-file "$CO_TMP/miss.txt" >/dev/null 2>&1; then _fail "read-back gate PASSED with the canonical .icp.net origin missing"
else _ok "a missing canonical origin goes red"; fi
printf 'Environment variables: (none)\n' > "$CO_TMP/none.txt"
if bash scripts/check_origins.sh --from-file "$CO_TMP/none.txt" >/dev/null 2>&1; then _fail "read-back gate PASSED with no frontend_origins present at all"
else _ok "an absent env var fails closed"; fi
rm -rf "$CO_TMP"

# ── 6l. Username draws stay principal-free + widened (W6-11) ──────
# A principal-derived name component would let anyone rebuild the whole
# name↔principal mapping offline from the public tape — the exact attack the
# draws-based design closes. And the space must stay ≥ the widened 6.24M
# (collisions are display-only, but 279-profile birthday odds were absurd).
UNAME_FN=$(mo_func src/backend/lib/Profiles.mo "func usernameFromDraws(")
[ -n "$UNAME_FN" ] || _fail "could not extract usernameFromDraws()"
src_has  "name space widened to 6.24M (d3 % 9_990)" "$UNAME_FN" "(d3 % 9_990) + 10"
src_lacks "no principal-derived name component"      "$(printf '%s\n' "$UNAME_FN" | mo_code)" "Principal"

# ── 6m. Candid #err is not shell success (W5-22) ──────────────────
# `icp canister call` exits 0 when the method RETURNS — #err included — so a
# gate testing the exit status prints ok for a refused call (fundArbitrageur
# refuses on #production; the deploy then said "arb funded" and enabled it).
# The variant is what gets tested, through one shared predicate.
DEPLOY_SH_W522="$(uncommented scripts/deploy.sh)"
src_has "the variant predicate exists (mdx_call_ok)"      "$DEPLOY_SH_W522" "mdx_call_ok() {"
src_has "fundArbitrageur gates on the VARIANT"            "$DEPLOY_SH_W522" 'if mdx_call_ok "$fund_out"; then'
src_has "seedInsuranceFund gates on the VARIANT"          "$DEPLOY_SH_W522" 'if mdx_call_ok "$seed_ins_out"; then'
if printf '%s\n' "$DEPLOY_SH_W522" | grep -E 'if icp canister call backend (fundArbitrageur|seedInsuranceFund)' | grep -cq .; then
  _fail "an exit-status-tested fund/seed call came back (W5-22 regression)"
else _ok "no exit-status-tested fund/seed calls remain"; fi
# Drive the REAL predicate offline: #ok passes, #err must not.
W522_TMP="$(mktemp -d "${TMPDIR:-/tmp}/w522.XXXXXX")"
cat > "$W522_TMP/probe.sh" <<'W522EOF'
mdx_call_ok() { printf '%s' "$1" | grep -qE 'variant[[:space:]]*\{[[:space:]]*ok'; }
SRC="$1"
eval "$(sed -n '/^mdx_call_ok() {/,/^}/p' "$SRC")"   # use the REAL definition
mdx_call_ok "(variant { ok = 5 : nat })" || exit 1
mdx_call_ok "( variant { ok })" || exit 2
mdx_call_ok "(variant { err = \"fundArbitrageur is not available on #production\" })" && exit 3
mdx_call_ok "Error: call failed" && exit 4
exit 0
W522EOF
if bash "$W522_TMP/probe.sh" scripts/deploy.sh; then _ok "mdx_call_ok: #ok passes, #err and CLI errors refuse (real definition driven)"
else _fail "mdx_call_ok verdict wrong (exit $?)"; fi
rm -rf "$W522_TMP"

# ── 6n. Silent paths log: archive fuel + authority setters (#47.3/#47.4) ──
# fundArchive's #err is DISCARDED by both automatic callers (including the
# blind-fund path for sealed/blackholed segments), so the ring log is the
# only place a failed archive top-up surfaces — the catch must warn, like
# its BRIDGE FUEL / ARB FUEL siblings. And every authority rewire lands in
# the log the way setArbitrageur's always has; a "simplification" that
# drops one of these logs reopens the silent path. Task 1787182530.
# #47.4 second half (operator-ratified 2026-08-20, task 1787199871): each of
# the six setters ALSO emits a #config event onto the durable hash-chained
# tape (emitConfig — setter = the method name, value = the ring log's
# rendered value text), beside — never replacing — its ring-log line.
FUND_ARCH_FN=$(mo_func src/backend/main.mo "func fundArchive(")
[ -n "$FUND_ARCH_FN" ] || _fail "could not extract fundArchive()"
src_has "fundArchive warns on deposit failure" "$FUND_ARCH_FN" 'logEvent("warn", "system", "ARCHIVE FUEL: deposit_cycles failed for "'
SET_ARB_FN=$(mo_func src/backend/main.mo "func setArbitrageur(")
[ -n "$SET_ARB_FN" ] || _fail "could not extract setArbitrageur()"
src_has "setArbitrageur logs the rewire (the exemplar)" "$SET_ARB_FN" 'logEvent("info", "system", "Arbitrage canister wired: "'
src_has "setArbitrageur emits #config on the tape" "$SET_ARB_FN" 'emitConfig(msg.caller, "setArbitrageur"'
SET_BRIDGE_FN=$(mo_func src/backend/main.mo "func setBridge(")
[ -n "$SET_BRIDGE_FN" ] || _fail "could not extract setBridge()"
src_has "setBridge logs the rewire" "$SET_BRIDGE_FN" 'logEvent("info", "system", "Bridge canister wired: "'
src_has "setBridge emits #config on the tape" "$SET_BRIDGE_FN" 'emitConfig(msg.caller, "setBridge"'
SET_BH_FN=$(mo_func src/backend/main.mo "func setBlackholeAtSeal(")
[ -n "$SET_BH_FN" ] || _fail "could not extract setBlackholeAtSeal()"
src_has "setBlackholeAtSeal logs the flip" "$SET_BH_FN" 'logEvent("info", "system", "Blackhole-at-seal "'
src_has "setBlackholeAtSeal emits #config on the tape" "$SET_BH_FN" 'emitConfig(msg.caller, "setBlackholeAtSeal", v)'
SET_FR_FN=$(mo_func src/backend/main.mo "func setFuelRoute(")
[ -n "$SET_FR_FN" ] || _fail "could not extract setFuelRoute()"
# The rendered ring line is unchanged ("Fuel route wired: ledger …, cmc …");
# the value text is now built once (`v`) so ring log and tape cannot drift.
src_has "setFuelRoute renders the route value once" "$SET_FR_FN" 'let v = "ledger "'
src_has "setFuelRoute logs the rewire" "$SET_FR_FN" 'logEvent("info", "system", "Fuel route wired: " # v'
src_has "setFuelRoute emits #config on the tape" "$SET_FR_FN" 'emitConfig(msg.caller, "setFuelRoute", v)'
SET_AF_FN=$(mo_func src/backend/main.mo "func setAutoFuel(")
[ -n "$SET_AF_FN" ] || _fail "could not extract setAutoFuel()"
src_has "setAutoFuel logs the flip" "$SET_AF_FN" 'logEvent("info", "system", "Auto-fuel "'
src_has "setAutoFuel emits #config on the tape" "$SET_AF_FN" 'emitConfig(msg.caller, "setAutoFuel", v)'
SET_XRC_FN=$(mo_func src/backend/main.mo "func setXrcCanister(")
[ -n "$SET_XRC_FN" ] || _fail "could not extract setXrcCanister()"
src_has "setXrcCanister logs the rewire" "$SET_XRC_FN" '"XRC canister wired: "'
src_has "setXrcCanister logs the unwire too" "$SET_XRC_FN" '"XRC canister unwired"'
src_has "setXrcCanister emits #config on the tape" "$SET_XRC_FN" 'emitConfig(msg.caller, "setXrcCanister", v)'

# ── 6o. The ship ack cursor refuses divergent acks (#43, 1787182536) ──
# tickShipEvents once clamped only the DROP when an archive acked past what it
# was sent, then advanced shippedSeq unconditionally — silently absorbing the
# divergence: the cursor ran permanently ahead of the queue (undrainable — every
# later sane ack read as stale) and resetSeason's Nat subtraction would trap.
# Unreachable today (performWorldWipe nulls archive0 in both reachable arms and
# both callers refuse on #production), but the impossible-state trip must stay:
# refuse the ack, bump the tripwire, record the range, fail toward the L1 roll.
TICK_SHIP_FN=$(mo_func src/backend/main.mo "func tickShipEvents(")
[ -n "$TICK_SHIP_FN" ] || _fail "could not extract tickShipEvents()"
src_has   "divergence trip tests the full queue span"      "$TICK_SHIP_FN" 'if (nextExpected > shippedSeq + m)'
src_has   "divergent ack bumps the tripwire counter"       "$TICK_SHIP_FN" '_ackDivergences += 1'
src_has   "divergent ack counts toward the L1 roll"        "$TICK_SHIP_FN" 'divergent ack REFUSED'
src_lacks "the old silent clamp-and-advance is gone"       "$TICK_SHIP_FN" 'if (drop > m) { drop := m }'
RESET_SEASON_FN=$(mo_func src/backend/main.mo "func resetSeason(")
[ -n "$RESET_SEASON_FN" ] || _fail "could not extract resetSeason()"
src_has   "resetSeason guards the cursor subtraction"      "$RESET_SEASON_FN" 'if (shippedSeq > nextEventSeq)'

# ── 7. The Bridge has a posture, and it agrees with the DEX ───────
BRIDGE_SRC=$(cat src/bridge/main.mo)
src_has "bridge declares a DeployMode type"  "$BRIDGE_SRC" "public type DeployMode"
src_has "bridge derives a production flag"   "$BRIDGE_SRC" "IS_PRODUCTION"
src_has "bridge exposes its posture"         "$BRIDGE_SRC" "public query func getDeployMode()"
# `transient` is load-bearing: a plain `let` in a persistent actor is
# implicitly STABLE, so an edited literal would be overwritten by the stored
# value on upgrade and the flip would never land.
src_has "bridge posture is transient (re-read on install AND upgrade)" \
  "$BRIDGE_SRC" "transient let DEPLOY_MODE"

# Both read through the comment-aware helper pinned in §6b — the raw grep
# here had the same decoy blindness as the four deploy gates.
BRIDGE_MODE=$(MPO src/bridge/main.mo)
DEX_MODE=$(MPO src/backend/main.mo)
assert_eq "bridge default posture is play" "play" "$BRIDGE_MODE"

# NOT a strict equality check against the DEX. A working-tree flip of the DEX
# to #dev is normal and expected — the dev fixtures and seed.sh need it, and
# deploy.sh's own posture gate exempts the local target for exactly that
# reason. Asserting equality here would fail on every ordinary local test
# session, and a test that cries wolf gets ignored.
#
# The invariant that actually matters is one-directional: the Bridge must
# never be MORE PERMISSIVE than the DEX it credits. Concretely — if the DEX is
# value-bearing, a Bridge that still answers its unbacked-credit hooks is the
# §2.15 hole wide open, and nothing in the deploy path would catch it: the
# scripts read the DEX's literal (mdx_assert_posture_for_target, posture_of)
# and never look at the Bridge's.
if [ "$DEX_MODE" = "production" ] && [ "$BRIDGE_MODE" != "production" ]; then
  _fail "DEX is #production but the Bridge is #$BRIDGE_MODE — the stub's unbacked-credit hooks would be live against a value-bearing DEX"
else
  _ok "bridge is not more permissive than the DEX (DEX #$DEX_MODE / bridge #$BRIDGE_MODE)"
fi

# The asset allowlist must be a GATE, not just a declaration: both write paths
# key permanent maps on the caller's Text, and there is no length check.
src_has "bridge has an asset membership test" "$BRIDGE_SRC" "func isSupportedAsset"

CLAIM_FN=$(mo_func src/bridge/main.mo "func claim(asset : Text)")
[ -n "$CLAIM_FN" ] || _fail "could not extract claim() — the extractor needs updating"
src_has "claim validates the asset" "$CLAIM_FN" "isSupportedAsset"
# THE ORDER IS THE BUG. ledgerOf is get-or-CREATE, and returning #err from an
# update method is a normal return rather than a trap — so a Map.add above the
# rejection COMMITS a permanent row for every rejected call.
src_lacks "claim never calls the get-or-create ledgerOf" \
  "$(printf '%s\n' "$CLAIM_FN" | mo_code)" "ledgerOf("
src_has   "claim reads the ledger without creating it"   "$CLAIM_FN" "Map.get(ledgers"

# The dev hooks must refuse on the UNCAPPED posture. #play deliberately KEEPS
# them: devSimulateDeposit is the live on-ramp there, and the DEX's
# playDepositCap — the thing that bounds it — is active on every play-family
# posture (#dev mirrors #play; only #production has no play cap).
SIM_FN=$(mo_func src/bridge/main.mo "func devSimulateDeposit(")
CONF_FN=$(mo_func src/bridge/main.mo "func devConfirmDeposits(")
[ -n "$SIM_FN" ]  || _fail "could not extract devSimulateDeposit()"
[ -n "$CONF_FN" ] || _fail "could not extract devConfirmDeposits()"
src_has "devSimulateDeposit validates the asset first" "$SIM_FN"  "isSupportedAsset"
src_has "devSimulateDeposit refuses on production"     "$SIM_FN"  "requireNotProduction"
src_has "devConfirmDeposits refuses on production"     "$CONF_FN" "IS_PRODUCTION"
src_has "devConfirmDeposits traps (it has no Result channel)" "$CONF_FN" "Runtime.trap"
# Both must remain usable on #play — the committed posture and the live venue.
src_lacks "devSimulateDeposit is not gated to dev only" "$SIM_FN"  "IS_DEV"
src_lacks "devConfirmDeposits is not gated to dev only" "$CONF_FN" "IS_DEV"

# The liquidation sweep's retry pacing (Menese #12.1). This is a STRUCTURAL
# property no live query can observe: you would have to wedge the batch on a
# real replica to see the difference, and by then it is burning cycles. The
# hazard is specific — _lastLiqNs is stamped only on COMPLETION (correct: it is
# the health signal), so gating the heartbeat's dispatch on it means a trapping
# batch freezes the stamp, leaves the predicate permanently true, and re-fires
# every beat instead of every 30s. Cadence must come from the dispatch stamp,
# which advances whether or not the pass survives.
HB_FN=$(mo_func src/backend/main.mo "system func heartbeat(")
[ -n "$HB_FN" ] || _fail "could not extract heartbeat()"
src_lacks "heartbeat does not pace liquidations off the completion stamp" "$HB_FN" "now - _lastLiqNs"
src_has   "heartbeat paces liquidations off the dispatch stamp"           "$HB_FN" "armLiquidationDispatch"
ARM_FN=$(mo_func src/backend/main.mo "func armLiquidationDispatch(")
[ -n "$ARM_FN" ] || _fail "could not extract armLiquidationDispatch()"
src_has "dispatch arming advances the dispatch stamp"        "$ARM_FN" "_lastLiqDispatchNs := now"
src_has "an incomplete previous pass increments the streak"  "$ARM_FN" "_liqFailStreak += 1"
# #52.4: the streak is judged on the LIVE in-flight flag, never on the
# difference of the monotone dispatch/completion totals — one historical trap
# skews that difference forever, pre-arming the streak so a fresh trap
# escalates one pass early, and pinning `pending` above 0 on a healed venue.
src_has   "the streak is judged against the live in-flight flag" "$ARM_FN" "if (_liqInFlight)"
src_lacks "the streak is never judged against the counter difference" "$ARM_FN" "_liqDispatches > _liqCompletions"
src_has   "dispatch arming raises the in-flight flag" "$ARM_FN" "_liqInFlight := true"
# Only a completed pass may clear the streak — clearing it on dispatch would
# make the backoff unreachable and restore the unthrottled retry. The
# completion body lives in completeLiquidationPass (shared with the
# devDriveLiqCycle fixture); tickLiquidations must still route through it.
TICK_FN=$(mo_func src/backend/main.mo "func tickLiquidations(")
[ -n "$TICK_FN" ] || _fail "could not extract tickLiquidations()"
src_has "tickLiquidations routes through the shared completion body" "$TICK_FN" "completeLiquidationPass()"
COMPLETE_FN=$(mo_func src/backend/main.mo "func completeLiquidationPass(")
[ -n "$COMPLETE_FN" ] || _fail "could not extract completeLiquidationPass()"
src_has "a completed pass clears the failure streak" "$COMPLETE_FN" "_liqFailStreak := 0"
# ...and the flag clears ONLY here — on the completion stamp, never on a
# timer or an admin reset, which would mask a stuck engine (#52.4 qualifier).
src_has "a completed pass lowers the in-flight flag" "$COMPLETE_FN" "_liqInFlight := false"
N_INFLIGHT_CLEARS=$(grep -c "_liqInFlight := false" src/backend/main.mo || true)
if [ "$N_INFLIGHT_CLEARS" -eq 1 ]; then _ok "the in-flight flag clears only at the completion stamp"
else _fail "_liqInFlight cleared in $N_INFLIGHT_CLEARS places — only completeLiquidationPass may lower it (a time-based or admin clear masks a stuck engine)"; fi

# The market-maker freshness shield (OhShii #6.4, hardened per #51.2). Stamps
# are written at PLACEMENT, so every path that un-stages an intent before it
# lands must clear them, or staging-then-cancelling buys a free renewable
# shield. The first regression came from a hardcoded list: the clear was added
# to cancelOwnSpotOrder alone while the endpoint users actually call kept its
# own copy — and the list-based gate that replaced it could not see a FIFTH
# path being added. So the rule is STRUCTURAL now: discover every function
# whose body calls removeDeferredExec (the un-stage primitive — any new cancel
# or kill path must call it or it leaks the staged entry) and require
# clearMmShield to co-occur. releaseDeferred is the one function where
# co-occurrence is too weak — it hosts the LANDING fall-through (which keeps
# its shield: the stamp IS the repricing intent that just landed) next to the
# kill early-returns (which must clear it) — so it gets a per-return rule
# below instead.
MM_KILL_FNS=$(mo_code < src/backend/main.mo | awk '
  /^  [^ ]/ && /func [A-Za-z_][A-Za-z0-9_]* *\(/ { decl = $0 }
  /removeDeferredExec\(/ && !/func removeDeferredExec\(/ {
    if (decl != "") print decl
  }
' | sed -E 's/.*func +([A-Za-z_][A-Za-z0-9_]*) *\(.*/\1/' | sort -u)
# The discovery itself must observe something, or a rename of the primitive
# would green every assertion below vacuously.
src_has "un-stage call sites discovered (removeDeferredExec still the primitive)" "$MM_KILL_FNS" "releaseDeferred"
for name in $MM_KILL_FNS; do
  [ "$name" = "releaseDeferred" ] && continue   # per-return rule below
  BODY=$(mo_func src/backend/main.mo "func ${name}(")
  [ -n "$BODY" ] || _fail "could not extract ${name}()"
  src_has "${name} un-stages ⇒ it clears the MM freshness shield" "$BODY" "clearMmShield"
done
# releaseDeferred, per RETURN SITE: every early return is a KILL exit (the
# landing path falls through to the end of the body — it has no return
# statement), and a killed intent never reached the book, so each one must
# clear the shield in its exit block. A future fifth kill-return added
# without the clear fails here.
REL_FN=$(mo_func src/backend/main.mo "func releaseDeferred(")
[ -n "$REL_FN" ] || _fail "could not extract releaseDeferred()"
REL_RETURNS=$(printf '%s\n' "$REL_FN" | mo_code | grep -cE '(^|[^A-Za-z_])return($|[^A-Za-z0-9_])' || true)
if [ "${REL_RETURNS:-0}" -ge 1 ]; then _ok "releaseDeferred kill exits observed ($REL_RETURNS early returns)"
else _fail "releaseDeferred has no early returns — the kill exits moved; re-derive this rule"; fi
BAD_KILL_RETURNS=$(printf '%s\n' "$REL_FN" | mo_code | awk '
  { hist[NR % 5] = $0 }
  /(^|[^A-Za-z_])return($|[^A-Za-z0-9_])/ {
    ok = 0
    for (i = 0; i < 5; i++) if (hist[i] ~ /clearMmShield\(/) ok = 1
    if (!ok) print NR ": " $0
  }
')
if [ -z "$BAD_KILL_RETURNS" ]; then _ok "every kill-return in releaseDeferred clears the MM freshness shield"
else
  _fail "kill-return(s) in releaseDeferred without clearMmShield in the exit block — a killed intent must not go on shielding"
  printf '%s\n' "$BAD_KILL_RETURNS" | head -5 | sed 's/^/      /' >&2
fi
# The deletes must live ONLY in the helper — an inlined copy is a path that can
# drift out of agreement again.
STAMP_DELETES=$(grep -c "Map.delete(mmQuoteStamp" src/backend/main.mo || true)
if [ "$STAMP_DELETES" -eq 1 ]; then _ok "mmQuoteStamp is cleared through one shared helper"
else _fail "mmQuoteStamp cleared in $STAMP_DELETES places — inline the calls through clearMmShield"; fi

# The stale-mark liquidation guard (#6.2). tryLiquidate's F1 guard is the ONLY
# defence on the post-fill path (adjustAffectedUsers calls straight through and
# IGNORES the outcome, so the distinct #err is unobservable from any endpoint —
# which is why this is a source pin, not a behavioral probe). The guard is only
# a guard while it runs BEFORE the first state mutation: accrueAll writes loan
# state, and everything after it acts on the possibly-stale valuation.
TL_FN=$(mo_func src/backend/main.mo "func tryLiquidate(")
[ -n "$TL_FN" ] || _fail "could not extract tryLiquidate()"
src_has "tryLiquidate refuses a stale mark with the distinct deferral error" \
  "$TL_FN" 'return #err("stale mark — liquidation deferred")'
TL_GUARD_LN=$(printf '%s\n' "$TL_FN" | mo_code | grep -nF "userMarksFreshAt(user, now)" | head -1 | cut -d: -f1)
TL_MUT_LN=$(printf '%s\n' "$TL_FN" | mo_code | grep -nE "accrueAll|cancelAllUserOrders|Liquidator\.tryLiquidate" | head -1 | cut -d: -f1)
if [ -n "${TL_GUARD_LN:-}" ] && [ -n "${TL_MUT_LN:-}" ] && [ "$TL_GUARD_LN" -lt "$TL_MUT_LN" ]; then
  _ok "tryLiquidate's stale-mark guard precedes its first state mutation (line $TL_GUARD_LN < $TL_MUT_LN)"
else
  _fail "tryLiquidate's stale-mark guard does not precede the first state mutation (guard=${TL_GUARD_LN:-missing}, first mutation=${TL_MUT_LN:-missing}) — a stale mark must be refused before anything is written"
fi

# ── §7b W5-12: no implicitly-stable scalar tuning constants ─────────────
# Under `persistent actor` a plain `let` is implicitly STABLE: an upgrade
# that edits the literal is silently overwritten by the old stored value,
# and the retune never lands (found live on EPISODE_CAP and
# MARGIN_CASH_SETTLE_USD — the 1.60 audit note claiming uniform `transient`
# was wrong). State containers SHOULD be plain (they are the data); scalar
# UPPER_SNAKE literals must be `transient`.
# STABLE-FOSSIL lines are exempt: EOP refuses to DROP a stable field without
# a migration, so a superseded constant stays declared (unread, marked) until
# the next migration sweep. The marker is the conscious act.
N_STABLE_CONST=$(grep -E '^  let [A-Z][A-Z0-9_]* : (Nat|Int|Float|Bool|Text) = ' src/backend/main.mo | grep -cv 'STABLE-FOSSIL' || true)
if [ "${N_STABLE_CONST:-0}" -eq 0 ]; then _ok "no implicitly-stable scalar constant in main.mo"
else
  _fail "$N_STABLE_CONST scalar constant(s) in main.mo are implicitly stable — mark them 'transient let' or the next retune upgrade silently keeps the old value"
  grep -nE '^  let [A-Z][A-Z0-9_]* : (Nat|Int|Float|Bool|Text) = ' src/backend/main.mo | head -5 | sed 's/^/      /' >&2
fi
# subPendingQty is subReserved's twin: non-negativity is an INVARIANT there,
# so it must fail closed + log, never SafeMath-clamp (#28.4).
SPQ_FN=$(mo_func src/backend/main.mo "func subPendingQty(")
[ -n "$SPQ_FN" ] || _fail "could not extract subPendingQty()"
src_lacks "subPendingQty does not clamp the invariant away" "$(printf '%s\n' "$SPQ_FN" | mo_code)" "subOrZero"
src_has   "subPendingQty logs the desync fail-closed"       "$SPQ_FN" "pending-qty desync"

# ── §7c W5-20: the deploy path regenerates candid before every build ────
# A deploy from a tree whose .did is stale used to ship the stale interface
# as PUBLIC candid:service metadata (live repro during W1-03: silently
# dropped fields, raw hash variants). deploy.sh must run gen-did.sh before
# the posture gate — for every target, not one branch of the case.
DEPLOY_UNC=$(uncommented scripts/deploy.sh)
src_has "deploy.sh regenerates candid before building (gen-did.sh)" "$DEPLOY_UNC" "bash scripts/gen-did.sh"
src_has "deploy.sh refuses on a gen-did failure (no stale interface ships)" "$DEPLOY_UNC" "refusing to deploy a stale candid"
# The step must sit BEFORE the per-target case dispatch, so no target skips it.
GENDID_LN=$(grep -n "bash scripts/gen-did.sh" scripts/deploy.sh | head -1 | cut -d: -f1)
CASE_LN=$(grep -n 'case "$TARGET" in' scripts/deploy.sh | head -1 | cut -d: -f1)
if [ -n "$GENDID_LN" ] && [ -n "$CASE_LN" ] && [ "$GENDID_LN" -lt "$CASE_LN" ]; then
  _ok "gen-did step precedes the target dispatch (every target inherits it)"
else
  _fail "gen-did step at line ${GENDID_LN:-none} does not precede the target case at ${CASE_LN:-none} — a target branch could ship without it"
fi

# ── §7d W6-02: checklist-asserted literals exist in the code they gate ──
# The production gate (pre-mainnet-checklist.md) and the kill matrix
# (deployment-modes.md) assert exact refusal strings. One drifted for months
# (`"dev-only override"` vs the code's `"dev-only hook"`) — the runbook
# verified a literal no .mo file emits. Every `#err("…")` the documents
# assert must exist verbatim in src/**/*.mo, and the four trap literals the
# reconciliation standardised are pinned by name.
DOC_LITS=$(grep -ohE '#err\("[^"]+"' docs/pre-mainnet-checklist.md docs/deployment-modes.md | sed 's/#err("//; s/"$//' | sort -u)
if [ -z "$DOC_LITS" ]; then _fail "no #err literals found in the gate documents — the extraction is broken, not the docs clean"; fi
while IFS= read -r lit; do
  [ -z "$lit" ] && continue
  if grep -rqF "$lit" src/backend src/bridge --include='*.mo'; then
    _ok "gate literal exists in code: ${lit:0:60}"
  else
    _fail "gate document asserts a literal NO .mo file emits: \"$lit\" — reconcile the doc or the code (W6-02)"
  fi
done <<< "$DOC_LITS"
for lit in "addTestTokens is a dev-only faucet" "setTestBalance is not available on #production" "getTestBalance is not available on #production" "resetExchange is not available on #production"; do
  if grep -rqF "$lit" src/backend --include='*.mo'; then _ok "loud-refusal literal present: $lit"
  else _fail "loud-refusal literal missing from code: $lit (checklist asserts it)"; fi
done

# ── §7e 1786991553: mops.toml comment blocks survive the mops CLI ───────
# `mops generate candid <name>` (mops 2.19.2) rewrites mops.toml WHOLESALE —
# comments stripped — whenever it must ADD a missing `candid =` key
# (observed 2026-08-17: the rewrite deleted the --max-stable-pages incident
# rationale; nothing warned). Two pins close it from both ends: the
# load-bearing rationale comment must exist, and EVERY [canisters.*] block
# must carry an explicit `candid =` key — with the key present the generate
# is a verified byte-identical no-op, so the rewrite path never triggers.
if grep -q "8 GiB clears the full 10M-event rotation" mops.toml; then
  _ok "mops.toml carries the max-stable-pages incident rationale (strip-canary)"
else
  _fail "mops.toml lost its --max-stable-pages rationale comment — a mops CLI rewrite stripped it (task 1786991553); restore from git and add the missing candid= key that triggered it"
fi
MOPS_BLOCKS=$(grep -c '^\[canisters\.' mops.toml)
MOPS_CANDIDS=$(grep -c '^candid = ' mops.toml)
if [ "${MOPS_BLOCKS:-0}" -ge 1 ] && [ "$MOPS_BLOCKS" = "$MOPS_CANDIDS" ]; then
  _ok "every [canisters.*] block carries candid= ($MOPS_BLOCKS/$MOPS_BLOCKS) — the rewrite path stays dormant"
else
  _fail "a [canisters.*] block lacks a candid= key (blocks=$MOPS_BLOCKS candid=$MOPS_CANDIDS) — the next 'mops generate candid' for it will rewrite mops.toml and strip every comment (task 1786991553)"
fi

# ── §7f #45: no unbraced expansion abuts a multibyte glyph in tests ──────
# macOS /bin/bash 3.2 under a UTF-8 locale classifies the bytes of ≈ and →
# as variable-name characters, so an unbraced expansion written directly
# against such a glyph parses the glyph INTO the name, and `set -u` aborts
# the suite mid-run — several of these sat on value-conservation SUCCESS
# paths, so a healthy venue produced a red that read as a generic failure.
# Brace the expansion (the ${VAR}→ form) or put a space before the glyph.
# run_all.sh also pins LC_ALL=C on each child (the belt), but direct
# `bash tests/foo.sh` runs have no runner — the brace is the real fix.
MB_HITS=$(perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]/; close ARGV if eof' tests/*.sh 2>/dev/null || true)
if [ -z "$MB_HITS" ]; then
  _ok "no unbraced expansion abuts a multibyte glyph in tests/*.sh (#45)"
else
  _fail "unbraced expansion abutting a multibyte glyph — macOS bash 3.2 + UTF-8 locale swallows the glyph into the variable name and set -u aborts the suite (#45); brace it (the \${VAR}→ form): $MB_HITS"
fi
if grep -qF 'LC_ALL=C bash "$t"' tests/run_all.sh; then
  _ok "run_all.sh pins LC_ALL=C on its suite invocations (#45)"
else
  _fail "run_all.sh no longer pins LC_ALL=C on its bash \"\$t\" invocation — suite results become ambient-locale-dependent (#45)"
fi

# ── §7g #21 fifth latent (2026-08-10): no duplicate OQL entity names ────
# Registry.build (src/backend/oql/Registry.mo) inserts decls with Map.add,
# which silently OVERWRITES on a duplicate key: two entities declared with
# the same name collapse to whichever comes LAST — .auth(...) policy
# included, so a later .public_() decl would silently replace an
# owner-scoped one. The check must NOT live in build() as a trap (build runs
# in the transient initializer, i.e. DURING upgrade — a trapping check makes
# the release carrying the duplicate unshippable), so it lives here at test
# time instead: per registry array in main.mo, every entity name must be
# unique. tests/OqlRegistry.test.mo pins the underlying last-wins/no-trap
# behaviour; see src/backend/oql/README.md's latent-defect watch.
oql_registry_names() {  # oql_registry_names <anchor literal> — prints one entity name per line
  awk -v anchor="$1" '
    index($0, anchor) { f = 1 }
    f { print }
    f && /^[[:space:]]*\]\)?;[[:space:]]*$/ { exit }
  ' src/backend/main.mo | mo_code | tr '\n' ' ' \
  | grep -oE '(Entity\.(manual|new|newScoped)<[^>]*>|\.toEntity)[[:space:]]*\([[:space:]]*"[^"]+"' \
  | sed 's/.*"\([^"]*\)"$/\1/'
}
for REG_ANCHOR in "transient let archiveRegistry = OQL.Registry.build([" \
                  "transient let oqlEntities : [OQL.Entity.Decl] = ["; do
  REG_LABEL=$(printf '%s' "$REG_ANCHOR" | awk '{print $3}')
  NAMES=$(oql_registry_names "$REG_ANCHOR")
  N_NAMES=$(printf '%s\n' "$NAMES" | grep -c . || true)
  # Vacuity guard: every decl the block builds must have yielded a name — a
  # constructor this extractor does not recognise must fail loudly, not pass.
  N_BUILDS=$(awk -v anchor="$REG_ANCHOR" '
    index($0, anchor) { f = 1 }
    f { print }
    f && /^[[:space:]]*\]\)?;[[:space:]]*$/ { exit }
  ' src/backend/main.mo | mo_code | grep -cE '\.build\(\)' || true)
  if [ "${N_NAMES:-0}" -eq 0 ] || [ "$N_NAMES" -ne "${N_BUILDS:-0}" ]; then
    _fail "$REG_LABEL: entity-name extraction saw $N_NAMES name(s) for $N_BUILDS .build() decl(s) — extractor out of step with the decl style, fix §7g before trusting it"
  else
    DUPES=$(printf '%s\n' "$NAMES" | sort | uniq -d)
    if [ -z "$DUPES" ]; then
      _ok "$REG_LABEL: $N_NAMES entity names, no duplicates (Registry.build silently last-wins on collision)"
    else
      _fail "$REG_LABEL declares DUPLICATE entity name(s): $(printf '%s' "$DUPES" | tr '\n' ' ')— Registry.build keeps only the LAST decl, .auth policy included (#21 fifth latent; do NOT fix with a trap in build — see src/backend/oql/README.md)"
    fi
  fi
done

# ── §7h 1787224373: oqlEvKind + its kind domain cover every UserEventKind ─
# oqlEvKind (the History OQL surface's kind flattener) has NO catch-all BY
# DESIGN — a new tape kind must be flattened deliberately — but Motoko treats
# a non-exhaustive switch as a WARNING, i.e. a runtime trap, not a compile
# error. #gap (W2-04) sat missing from both the switch and the .domain("kind")
# list for months: unreachable only because #gap rows carry the canister's own
# principal, which no caller's archiveExecute materialization queries. This
# pins both halves against the NEXT constructor: (1) every UserEventKind
# constructor in lib/Types.mo appears as a case in oqlEvKind; (2) the string
# literals the switch returns and the .domain("kind", ...) #text list are the
# SAME SET (no hardcoded name mapping — #deposit's deposit/withdrawal split
# rides through automatically). The sibling flatteners (oqlEvToken et al.)
# carry `case _` catch-alls and need no pin.
UEK_CONS=$(awk '
  index($0, "public type UserEventKind = {") { f = 1 }
  f { print }
  f && /^[[:space:]]*\};[[:space:]]*$/ { exit }
' src/backend/lib/Types.mo | mo_code | grep -oE '#[A-Za-z_]+[[:space:]]*:' | sed 's/[ :]//g; s/^#//' | sort -u)
N_CONS=$(printf '%s\n' "$UEK_CONS" | grep -c . || true)
EVKIND_FN=$(mo_func src/backend/main.mo "func oqlEvKind(")
[ -n "$EVKIND_FN" ] || _fail "§7h: could not extract oqlEvKind() from main.mo"
if [ "${N_CONS:-0}" -lt 14 ]; then
  _fail "§7h: UserEventKind extraction saw only ${N_CONS:-0} constructor(s) — extractor out of step with lib/Types.mo's decl style, fix §7h before trusting it"
else
  EVKIND_CASES=$(printf '%s\n' "$EVKIND_FN" | mo_code | grep -oE 'case[[:space:]]*\(#[A-Za-z_]+' | sed 's/.*#//' | sort -u)
  MISSING_CASES=$(comm -23 <(printf '%s\n' "$UEK_CONS") <(printf '%s\n' "$EVKIND_CASES"))
  if [ -z "$MISSING_CASES" ]; then
    _ok "§7h: oqlEvKind enumerates all $N_CONS UserEventKind constructors (no catch-all, so an omission is a runtime trap)"
  else
    _fail "§7h: oqlEvKind is missing case(s) for UserEventKind constructor(s): $(printf '%s' "$MISSING_CASES" | tr '\n' ' ')— a row of that kind TRAPS the History OQL surface; add case (#<kind> _) { \"<kind>\" } and the matching #text(...) domain entry (see #config/#gap for the idiom)"
  fi
  EVKIND_STRS=$(printf '%s\n' "$EVKIND_FN" | mo_code | grep -oE '"[A-Za-z_]+"' | tr -d '"' | sort -u)
  KIND_DOMAIN_LINE=$(mo_code < src/backend/main.mo | grep -F '.domain("kind",')
  N_DOMAIN_LINES=$(printf '%s\n' "$KIND_DOMAIN_LINE" | grep -c . || true)
  if [ "${N_DOMAIN_LINES:-0}" -ne 1 ]; then
    _fail "§7h: expected exactly one .domain(\"kind\", ...) decl in main.mo, saw ${N_DOMAIN_LINES:-0} — extractor out of step, fix §7h before trusting it"
  else
    KIND_DOMAIN=$(printf '%s\n' "$KIND_DOMAIN_LINE" | grep -oE '#text\("[A-Za-z_]+"\)' | sed 's/#text("//; s/")//' | sort -u)
    DOMAIN_DIFF=$(comm -3 <(printf '%s\n' "$EVKIND_STRS") <(printf '%s\n' "$KIND_DOMAIN"))
    if [ -z "$DOMAIN_DIFF" ]; then
      _ok "§7h: .domain(\"kind\", ...) matches oqlEvKind's returned strings exactly ($(printf '%s\n' "$KIND_DOMAIN" | grep -c .) values)"
    else
      _fail "§7h: oqlEvKind's returned strings and the .domain(\"kind\", ...) list DIVERGE on: $(printf '%s' "$DOMAIN_DIFF" | tr -s '\n\t' '  ')— the explorer's kind filter dropdown and the actual rows disagree; keep the two sets identical"
    fi
  fi
fi

# ── §8 the no-await property on user value paths (OhShii #41.3, W5-05) ──
# docs/security-review.md:143 closes the IC reentrancy/double-spend class in
# six words: "no `await` in any user value path" — every debit/credit commits
# as ONE message, so there is no interleaving point to race. The property
# holds BY CONSTRUCTION, which is exactly why nothing would notice it
# breaking: a runtime test cannot tell "the race is impossible" from "the
# race did not happen this run". This gate is the tripwire. If it just went
# red: you added an await (or await*) to a settlement path — read
# docs/security-review.md:143 and mixins/UserAccount.mo's custody comment,
# and have the saga conversation BEFORE weakening this, not after.
for VF in src/backend/lib/BorrowEngine.mo src/backend/lib/Liquidator.mo \
          src/backend/lib/Accounts.mo src/backend/mixins/UserAccount.mo; do
  if [ ! -f "$VF" ]; then _fail "value-path file missing: $VF (gate cannot vouch for a file it cannot read)"; continue; fi
  AW=$(mo_code < "$VF" | grep -cE '\bawait\b' || true)
  if [ "${AW:-0}" -eq 0 ]; then _ok "no await in $(basename "$VF") (single-message value path)"
  else _fail "$VF has $AW await(s) outside comments — this removes the property that closes the reentrancy/double-spend class (docs/security-review.md:143); custody needs a saga, not a bare await"; fi
done

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_deploy_hygiene\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_deploy_hygiene ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
