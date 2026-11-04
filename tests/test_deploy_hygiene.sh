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
# Measured on this bash 3.2 (task 1788740563): a bare printf writer fails
# 0/40 at 48 KB, 36/40 at 64 KB (the pipe buffer), 40/40 at 96 KB; a sed
# writer (uncommented/mo_code) already from 58 KB (29/30); -c >/dev/null 0/N at
# every size. Three suites had been silently SKIPPED by the TRAP_HITS scan.
# A bash FUNCTION as the writing element fails at ~4 KB - never wrap one.
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
# grep_scan <var> <haystack> <ERE> — the matching lines (`grep -nE --`; the
# same printf writer and -n drain as src_has) land in <var> BY NAME (printf
# -v): the helper runs in THIS shell, never inside a $(...), so its _fail
# reaches _TEST_ERRORS and the PASS/FAIL total — a _fail fired inside
# VAR=$(helper) bumps a subshell's copy and the total stays PASS (measured,
# task 1793496258). rc 0/1 is returned as grep's; a REGEX ERROR (rc >= 2) is
# a _fail naming the needle AND the same words in <var>, so the site's own
# emptiness gate reds beside it — never a silent "no match": §3d's needle
# was malformed for two months behind `… || true` (task 1793491373), and
# every `VAR=$(… | grep -nE '…' || true)` scan in this file read rc 2 the
# same way. The ONE scan idiom here; a new ban scan goes through it.
grep_scan() {
  local _gs_rc=0 _gs_out
  _gs_out=$(printf '%s\n' "$2" | grep -nE -- "$3") || _gs_rc=$?
  if [ "$_gs_rc" -ge 2 ]; then
    _gs_out="grep regex error (rc=$_gs_rc) in a hygiene needle: $3"
    _fail "$_gs_out"
  fi
  printf -v "$1" '%s' "$_gs_out"
  return "$_gs_rc"
}
# grep_count <var> <haystack> <ERE> — the match COUNT (`grep -cE --`, the same
# printf writer and full drain) lands in <var> BY NAME, in THIS shell, exactly
# as grep_scan does. rc 0/1 is grep's (1 = a count of 0). A REGEX ERROR
# (rc >= 2) prints NOTHING on this BSD grep, so `N=$(… | grep -cE '…' || true)`
# came back EMPTY — and every ban gated `[ "${N:-0}" -eq 0 ]` passed vacuously
# (the three await bans; measured, task 1793499609). Here it is a _fail naming
# the needle AND -1 in <var>: a value no `-eq 0` / `= "1"` / `-eq 1` / `-ge N`
# gate accepts, so the site's own line reds beside it (it reads "-1 await(s)"
# — odd, and red). The ONE count idiom here; a new count goes through it.
grep_count() {
  local _gc_rc=0 _gc_out
  _gc_out=$(printf '%s\n' "$2" | grep -cE -- "$3") || _gc_rc=$?
  if [ "$_gc_rc" -ge 2 ]; then
    _fail "grep regex error (rc=$_gc_rc) in a hygiene needle: $3"
    _gc_out=-1
  fi
  printf -v "$1" '%s' "$_gc_out"
  return "$_gc_rc"
}
# grep_filter [-F] [-k] <var> <needle> — the refinement stage of a two-stage
# scan: reads <var> (a grep_scan result), keeps the lines NOT matching <needle>
# (`grep -vE --`; -F: a fixed string, no regex to break; -k: KEEP the matching
# lines instead — the positive middle stage of §6af) and writes the survivors
# back BY NAME, in THIS shell. Same physics as grep_scan. A REGEX ERROR
# (rc >= 2) is a _fail naming the needle AND those words left in <var>, so the
# site's emptiness gate reds beside it: in `… | grep -nE '…' | grep -vE '…'
# || true` a broken needle in EITHER stage left the variable empty and the ban
# passed (measured, task 1793499609). Every refinement stage goes through it.
grep_filter() {
  local _gf_v=v _gf_m=E _gf_rc=0 _gf_out
  while :; do
    case "${1-}" in
      -F) _gf_m=F; shift ;;
      -k) _gf_v=;  shift ;;
      *)  break ;;
    esac
  done
  _gf_out=$(printf '%s\n' "${!1-}" | grep "-$_gf_v$_gf_m" -- "$2") || _gf_rc=$?
  if [ "$_gf_rc" -ge 2 ]; then
    _gf_out="grep regex error (rc=$_gf_rc) in a hygiene needle: $2"
    _fail "$_gf_out"
  fi
  printf -v "$1" '%s' "$_gf_out"
  return "$_gf_rc"
}
# grep_has <haystack> <ERE> — the BOOLEAN stage: `… | grep -cE '…' >/dev/null`
# read by an `if` or an `||` list (the same printf writer and -c drain as
# src_has; never -q). Returns 0 iff the count is non-zero, 1 iff it is zero.
# A REGEX ERROR (rc >= 2) took exactly the branch rc 1 does — "not found" —
# so a `|| continue` file gate skipped EVERY suite and a ban on a FILE printed
# its ✓ (measured, task 1793502683). Here it is a _fail naming the needle AND
# a return of 0, the branch each site reads as RED: a skip gate stops
# skipping (the file is scanned, the total already red) and a ban fires its
# own _fail. Runs in THIS shell, never inside a $(...), so the _fail counts.
# A site that needs the other direction gets a flag here, not a second
# helper. The ONE boolean idiom here; a new `if grep …` / `|| continue` gate
# goes through it.
grep_has() {
  local _gh_rc=0
  printf '%s\n' "$1" | grep -cE -- "$2" >/dev/null || _gh_rc=$?
  if [ "$_gh_rc" -ge 2 ]; then
    _fail "grep regex error (rc=$_gh_rc) in a hygiene needle: $2"
    return 0
  fi
  return "$_gh_rc"
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
# One step further, for COMMAND ban scans (task 1788495525): drop the CONTENTS
# of shell string literals, keeping the quotes, so a message that TELLS the
# operator which command to run (`skip_section "... icp build bridge ..."`)
# does not read as a suite RUNNING it. On stdin, code-shaped output:
#   - "..." contents go, including \" and \` escapes and any $VAR / ${...}
#     expansion inside; a $(...) or `...` INSIDE the quotes is kept verbatim
#     because bash really runs it there (a hidden command must still trip).
#     The $(...) copy is QUOTE-AWARE (task 1793512052): a nested "..." / '...'
#     inside the substitution is tracked (\ escapes the next byte), a $( inside
#     a nested "..." recurses, and only an UNQUOTED ( / ) moves the paren
#     depth. Before: every ( / ) byte counted — a `(` inside a quoted needle
#     (`"$(mo_func f "func x(" | mo_code)"`, this file's commonest shape) ran
#     the copy to the line end, swallowed the literal's closing quote and read
#     every line below INVERTED (code stripped, string contents kept) until an
#     odd-quote line happened to resync — 20 such stretches in this file, up to
#     47 lines each; a `)` inside a quoted needle (`sed 's/ || true)/)/'`)
#     ended the copy early and hid the rest of the substitution (1793505604's
#     early-cut case — the §6ao PIPE_NEG scan was invisible to the §6af
#     census). A $(...) that spans lines CARRIES (task 1793513986): every
#     level still open at the line end keeps its nested-quote state and paren
#     depth, the next line resumes the copy before it scans any code, and the
#     continuation lines are copied verbatim up to the ) that closes the
#     outermost level — before, the copy stopped at the line end and the
#     continuation lines read as the enclosing literal's CONTENT (the `bash
#     scripts/deploy.sh subnet` on the second line of a two-line capture was
#     invisible to every command scan; a nested "..." left open at the line
#     end even re-opened the literal on the closing line and inverted the two
#     lines after it). A file that ends inside an open $( is as unreliable as
#     one ending inside an open "...": the helper appends a second sentinel
#     line, CODE_ONLY_UNTERMINATED_SUBST, beside the literal one below.
#   - '...' contents go (a `'` inside "..." is content, a `"` inside '...' is
#     content). Single-quote state resets at every line end, so a trailing
#     comment's apostrophe (`... # don't`) strips the rest of ITS line only
#     and can never invert the scan for the rest of the file.
#   - Double-quote state CARRIES across lines (a literal spanning lines is
#     content on every line it covers; the code after its closing quote is
#     scanned). If a file ends inside an open "...", the view is unreliable
#     and the helper appends the sentinel line CODE_ONLY_UNTERMINATED_DQ —
#     a scan asserts its absence rather than trusting an inverted view.
#   - Unquoted text is kept as-is (a backslash escapes the next byte).
# Heredoc bodies are not recognised; they read as code (over-scan, never
# under-scan). Not a shell parser — a conservative literal stripper, so use
# it only on the haystack of a COMMAND scan: a scan that needs a string's
# text (the loose-"ok" needle scan) must read the plain uncommented source.
# The awk text below spells the apostrophe "\047" because it sits inside a
# single-quoted bash literal — and the backtick "\140" because this file reads
# ITSELF through this function (the §6af census): the awk program is a
# multi-line literal whose continuation lines read as code (single-quote state
# is line-local, above), so a literal backtick inside an awk string read as an
# unterminated command substitution, swallowed the string's closing quote and
# inverted this file's own view for the 93 lines below it (measured 2026-11-01,
# task 1793512052). Keep both escapes.
code_only() {
  awk '
  # copy_subst: copies one $(...) command substitution met inside a "..."
  # literal, from the $ at index i through its matching ), into out — verbatim,
  # because bash really runs it there. Quote-aware (task 1793512052): a nested
  # double- or single-quoted string inside the substitution (a grep needle, a
  # mo_func signature) is tracked, a backslash escapes the next byte, only an
  # UNQUOTED ( / ) moves the depth, and a $( inside a nested double-quoted
  # string recurses (lvl + 1). Returns the index just past the closing ), or an
  # index past n when the line ends first — then the level CARRIES (task
  # 1793513986): its nested-quote state and depth are saved in SQ[lvl] / SD[lvl],
  # nxt records the deepest level left open, and the per-line block re-enters
  # the copy on the next line (resume: level 1 first, each level descending into
  # the next while lvl < sub_open, the deepest clearing the flag) before it
  # scans any code. Before, the copy stopped at the line end and the enclosing
  # literal stayed open over the continuation lines.
  function copy_subst(i, lvl,   d, q, depth) {
    q = 0; depth = 0
    if (resume) {
      q = SQ[lvl]; depth = SD[lvl]
      if (lvl < sub_open) i = copy_subst(i, lvl + 1); else resume = 0
      if (i > n) { SQ[lvl] = q; SD[lvl] = depth; if (lvl > nxt) nxt = lvl; return i }
    }
    while (i <= n) {
      d = substr($0, i, 1)
      if (q == 0) {
        if (d == "\\") { out = out substr($0, i, 2); i += 2; continue }
        if (d == "\"") q = 1; else if (d == "\047") q = 2
        else if (d == "(") depth++
        else if (d == ")") { depth--; if (depth == 0) { out = out d; return i + 1 } }
        out = out d; i++; continue
      }
      if (q == 1) {
        if (d == "\\") { out = out substr($0, i, 2); i += 2; continue }
        if (d == "$" && substr($0, i + 1, 1) == "(") { i = copy_subst(i, lvl + 1); continue }
        if (d == "\"") q = 0
        out = out d; i++; continue
      }
      if (d == "\047") q = 0
      out = out d; i++
    }
    SQ[lvl] = q; SD[lvl] = depth; if (lvl > nxt) nxt = lvl
    return i
  }
  BEGIN { st = 0; sub_open = 0 }           # st: 0 code, 1 inside double quotes, 2 inside single quotes; sub_open: substitution levels carried from the previous line
  { n = length($0); i = 1; out = ""; if (st == 2) st = 0; nxt = 0
    if (sub_open > 0) { resume = 1; i = copy_subst(1, 1) }
    while (i <= n) {
      c = substr($0, i, 1)
      if (st == 0) {
        if (c == "\\") { out = out c substr($0, i + 1, 1); i += 2; continue }
        if (c == "\"") st = 1; else if (c == "\047") st = 2
        out = out c; i++; continue
      }
      if (st == 2) { if (c == "\047") { st = 0; out = out c }; i++; continue }
      if (c == "\\") { i += 2; continue }
      if (c == "\"") { st = 0; out = out c; i++; continue }
      if (c == "$" && substr($0, i + 1, 1) == "(") { i = copy_subst(i, 1); continue }
      if (c == "\140") { out = out c; i++
        while (i <= n) { d = substr($0, i, 1); out = out d; i++; if (d == "\140") break }
        continue
      }
      i++
    }
    sub_open = nxt
    print out
  }
  END { if (st == 1) print "CODE_ONLY_UNTERMINATED_DQ"; if (sub_open > 0) print "CODE_ONLY_UNTERMINATED_SUBST" }'
}
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
  #
  # Parens are tracked too (1788480909): a record type inside the PARAMETER
  # LIST (`items : [{ ... }],` in placeLimitOrdersBulk) opens and closes a
  # brace before the body's own `{`, so the old count saw depth return to 0
  # with `seen` set and ended the window on the signature — §8b then passed
  # that entry on nine lines of signature and zero lines of body. The window
  # cannot open (`seen`) or close while the signature's parens are still
  # unbalanced; §8b's closing-line check below is the tripwire for the next
  # shape of the same truncation.
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
        pd += gsub(/\(/, "&", code) - gsub(/\)/, "&", code)
        if (o > 0 && pd <= 0) { seen = 1 }
        if (seen && depth <= 0 && pd <= 0) exit
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
  grep_scan h "$(uncommented "$f")" 'awk +"'
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

# SCOPE EXTENSION 2 (H-04, F24): the census covers tests/ too. Six suites wrote
# fixed names under /tmp (/tmp/oqlguard.did, /tmp/aiguard_*.did, /tmp/hopiso.did,
# /tmp/uplands-conc-N.log, /tmp/w42_*.out, the seed log) and read four of them
# straight back as --args-file signed by a controller identity — so a planted
# symlink at the old name received the suite's write (verified live: the plant
# target held the 33 KB args body) and a planted file would have been the
# controller-signed argument. The glob covers tests/_lib.sh and tests/_scratch.sh.
# EXEMPT: lines that call mktemp (O_EXCL fresh names — a plant cannot land on
# one; run_all.sh's per-suite log and position_accounting's anchor), and this
# file itself, which names the pattern in order to grep for it and builds its
# own fixture dirs with mktemp -d "${TMPDIR:-/tmp}/…".
TEST_TMP_HITS=""
for f in tests/*.sh; do
  [ -f "$f" ] || continue
  [ "$f" = tests/test_deploy_hygiene.sh ] && continue
  h=$(uncommented "$f" | grep -n '/tmp/' | grep -v 'mktemp' || true)
  [ -n "$h" ] && TEST_TMP_HITS="$TEST_TMP_HITS $f:$h"
done
assert_eq "no fixed /tmp paths in the test suites (H-04)" "" "$(printf '%s' "$TEST_TMP_HITS" | tr -d '[:space:]')"

# ── 2b. H-04: the suites' scratch discipline lives in ONE place ────
# tests/_scratch.sh: one private per-run directory under $MDX_RUN_DIR (repo-
# local .run/ — operator-owned, not world-writable), created by mktemp -d,
# removed on EXIT; scratch_new asserts a name ABSENT before anyone writes it.
# Every _lib suite inherits it — and ONLY through _lib.sh. A suite that sources
# _lib.sh and then sources _scratch.sh directly runs it twice: a second mktemp -d,
# a reset cleanup list, a re-armed trap — so only the second directory is ever
# removed and the first is orphaned under .run/ on every run (task 1788497403).
SCR=$(cat tests/_scratch.sh)
src_has "_scratch.sh sources runfiles.sh (scratch lives under .run/, never /tmp)" "$SCR" 'scripts/lib/runfiles.sh'
src_has "_scratch.sh creates the per-run dir with mktemp -d under MDX_RUN_DIR"     "$SCR" 'mktemp -d "$MDX_RUN_DIR/'
src_has "_scratch.sh removes the per-run dir on EXIT"                              "$SCR" "on_exit 'rm -rf \"\$TEST_SCRATCH\"'"
src_has "_scratch.sh owns the one EXIT trap (suites register through on_exit)"     "$SCR" 'trap _mdx_run_exit EXIT'
src_has "scratch_new asserts the name is absent before anyone writes it"           "$SCR" '[ -e "$f" ] || [ -L "$f" ]'
src_has "seed_logged writes the seed log under noclobber after its rm"             "$SCR" 'set -o noclobber; bash "$MDX_ROOT/scripts/seed.sh"'
src_has "_lib.sh sources _scratch.sh (every _lib suite inherits it)" "$(cat tests/_lib.sh)" 'source "$SCRIPT_DIR/tests/_scratch.sh"'
for f in tests/test_ai_prompt_guard.sh tests/test_oql_guard.sh tests/test_archive_hop_isolation.sh \
         tests/test_concurrency.sh tests/test_w4_batch2.sh; do
  src_has "$(basename "$f") takes its scratch paths from scratch_new" "$(cat "$f")" '$(scratch_new '
done
for f in tests/test_archive_hop_isolation.sh tests/test_w4_batch2.sh; do
  src_has "$(basename "$f") inherits _scratch.sh through _lib.sh (no longer standalone)" "$(cat "$f")" 'source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"'
done
# The double-source shape, repo-wide: no suite that sources _lib.sh may also
# source _scratch.sh directly (task 1788497403). _lib.sh is the ONE legitimate
# sourcer; this file is skipped because it names the pattern in order to pin it.
# grep -c, not -q (W5-10 item 3): -q can SIGPIPE the sed under pipefail and a
# non-zero status here would silently SKIP the suite instead of scanning it.
DOUBLE_HITS=""
for f in tests/*.sh; do
  [ "$f" = tests/_lib.sh ] && continue
  [ "$f" = tests/_scratch.sh ] && continue
  [ "$f" = tests/test_deploy_hygiene.sh ] && continue
  grep_has "$(uncommented "$f")" '(source|\.) .*_lib\.sh' || continue
  grep_scan h "$(uncommented "$f")" '(source|\.) .*_scratch\.sh'
  [ -n "$h" ] && DOUBLE_HITS="$DOUBLE_HITS $f:$h"
done
assert_eq "no suite sources _scratch.sh directly on top of _lib.sh (the double-source shape orphans a scratch dir per run)" "" "$(printf '%s' "$DOUBLE_HITS" | tr -d '[:space:]')"
for f in tests/_lib.sh tests/test_swap.sh; do
  src_has "$(basename "$f") runs seed.sh through seed_logged" "$(cat "$f")" 'seed_logged '
done
# A suite that sources _lib.sh or _scratch.sh and then installs its own
# `trap … EXIT` REPLACES the scratch cleanup (bash keeps one EXIT trap per
# shell) and leaks its directory into .run/ — such suites register cleanups
# through on_exit. Standalone suites that source neither have no scratch dir
# and keep their own traps.
TRAP_HITS=""
for f in tests/*.sh; do
  [ "$f" = tests/_scratch.sh ] && continue
  [ "$f" = tests/test_deploy_hygiene.sh ] && continue
  grep_has "$(uncommented "$f")" 'source .*(_lib|_scratch)\.sh' || continue
  grep_scan h "$(uncommented "$f")" 'trap .*EXIT'
  [ -n "$h" ] && TRAP_HITS="$TRAP_HITS $f:$h"
done
assert_eq "no _lib/_scratch suite overrides _scratch.sh's EXIT trap (on_exit instead)" "" "$(printf '%s' "$TRAP_HITS" | tr -d '[:space:]')"
src_has "test_position_accounting registers its keeper cleanup through on_exit" "$(cat tests/test_position_accounting.sh)" "on_exit 'kill \$REFPRICE_KEEPER"
# The orphans the trap model cannot prevent (task 1788742727): a suite killed
# by SIGKILL (harness timeout, the 30-min reaper, a wedged icp call the
# operator kills, a reboot) never runs EXIT, so its per-run directory stays
# under .run/ for good — four sat on one seat on 2026-09-07. run_all.sh sweeps
# the ones older than six hours before its test loop: DIRECTORIES only, by the
# six-char mktemp suffix (the STABLE .run/test-seed.log can never match), one
# loud line per removal. src_has is the grep -c >/dev/null drain (header): the
# haystack is the whole uncommented runner, never `| grep -q` it.
RA_UNC=$(uncommented tests/run_all.sh)
src_has "run_all.sh takes MDX_RUN_DIR from runfiles.sh (the one definition of .run/)" "$RA_UNC" 'source "$SCRIPT_DIR/../scripts/lib/runfiles.sh"'
src_has "run_all.sh sweeps stale per-run scratch DIRECTORIES only, by the six-char mktemp suffix, older than six hours" "$RA_UNC" "find \"\$MDX_RUN_DIR\" -mindepth 1 -maxdepth 1 -type d -name 'test-*.??????' -mmin +360"
src_has "run_all.sh's stale-scratch sweep is never silent (one loud line per removal, with the age)" "$RA_UNC" 'removed stale scratch dir ${_stale} (${_age} old) — a suite exited without its EXIT trap'

# The writer and every reader must agree on ONE path. If they drift, the
# readers silently fall back to stale hardcoded prices and walk a freshly
# seeded AMM off its real price — a failure play_start.sh already documents.
for f in scripts/inject_history.sh scripts/deploy.sh scripts/play_start.sh \
         scripts/seed.sh scripts/simulate_trading.sh; do
  src_has "$(basename "$f") reads/writes the shared snapshot path" "$(cat "$f")" "MDX_ORACLE_PRICES"
done
# Standalone `seed.sh full --history-days 0` (the suites' reseed path) has no
# snapshot file, and used to stamp the four AMM marks at hardcoded fallbacks
# (BTC 75000 ...) while the venue's live feed sat at ~81k: the first post-seed
# tick pended every leg and vaultPricesStale refused EVERY LP mint for
# ~65-95s (task 3088500128, measured 2026-09-04). seed_full now snapshots the
# live aggregate and prefers it over the fallback. Pin the shape, comment-
# stripped: the read exists, it sits BEFORE seed_full's resetExchange (which
# clears lastAggregates — a read after it always sees null), and the marks
# are re-stamped AFTER the timers resume (the 60s LP-deposit staleness grace
# must outlast the ~45-50s wait for the first post-unpause tick).
SEED_UNC=$(uncommented scripts/seed.sh)
src_has "seed.sh reads the live aggregate for the AMM marks (getLastAggregate)" "$SEED_UNC" 'call getLastAggregate'
src_has "seed_full prefers the live aggregate over the hardcoded fallback"        "$SEED_UNC" 'live-aggregate('
SEED_FULL_LN=$(printf '%s\n' "$SEED_UNC" | grep -n '^seed_full()' | head -1 | cut -d: -f1)
SEED_LIVE_LN=$(printf '%s\n' "$SEED_UNC" | awk -v s="${SEED_FULL_LN:-0}" 'NR > s && /live_aggregate_mark "\$a"/ { print NR; exit }')
SEED_RESET_LN=$(printf '%s\n' "$SEED_UNC" | awk -v s="${SEED_FULL_LN:-0}" 'NR > s && /^[[:space:]]*reset_exchange[[:space:]]*$/ { print NR; exit }')
SEED_UNPAUSE_LN=$(printf '%s\n' "$SEED_UNC" | awk -v s="${SEED_FULL_LN:-0}" 'NR > s && /setTestTimersPaused "\(false\)"/ { print NR; exit }')
SEED_RESTAMP_LN=$(printf '%s\n' "$SEED_UNC" | awk -v s="${SEED_UNPAUSE_LN:-0}" 'NR > s && /must_ok "setAmmRefPrice / { print NR; exit }')
if [ -n "$SEED_FULL_LN" ] && [ -n "$SEED_LIVE_LN" ] && [ -n "$SEED_RESET_LN" ] && [ "$SEED_LIVE_LN" -lt "$SEED_RESET_LN" ]; then
  _ok "seed_full snapshots the live marks BEFORE resetExchange clears them"
else
  _fail "seed_full's live-mark snapshot at line ${SEED_LIVE_LN:-none} does not precede its resetExchange at ${SEED_RESET_LN:-none} — the read would always see null"
fi
if [ -n "$SEED_UNPAUSE_LN" ] && [ -n "$SEED_RESTAMP_LN" ]; then
  _ok "seed_full re-stamps the marks AFTER the timers resume (staleness grace outlasts the first tick)"
else
  _fail "seed_full has no setAmmRefPrice after its setTestTimersPaused(false) at line ${SEED_UNPAUSE_LN:-none} — the first pool's mark goes stale before the first post-unpause tick"
fi

# cold_start.sh used to follow seed.sh with a flat `sleep 90` ("staleness
# guard + one refresh cycle") — a double wait once seed_full's own bounded
# first-tick wait landed (task 3088502787). The health phase is now condition-
# driven: it polls getPriceFeedStats.successCount (zeroed by resetExchange /
# the play reinstall, untouched by the seed's setAmmRefPrice stamps, bumped
# only by an APPLIED tick) and ends at ≥ 1, so it costs ~0s after seed_full's
# wait and IS the wait on the play path. Pin the shape, comment-stripped: no
# fixed 90s sleep, the successCount poll present, and cold_start does NOT
# disable seed.sh's wait (MDX_SEED_FEED_WAIT_SEC=0 would re-open the
# ~65-95s LP-mint refusal window a standalone seed had).
COLD_UNC=$(uncommented scripts/cold_start.sh)
src_lacks "cold_start's oracle-health phase has no fixed 90s sleep"          "$COLD_UNC" 'sleep 90'
src_has   "cold_start's oracle-health phase polls successCount"              "$COLD_UNC" '/successCount/'
src_has   "cold_start's oracle-health phase breaks on the first applied tick" "$COLD_UNC" 'if [ "${SUCCESS:-0}" -ge 1 ] 2>/dev/null; then break; fi'
src_lacks "cold_start does not disable seed.sh's first-tick wait"            "$COLD_UNC" 'MDX_SEED_FEED_WAIT_SEC=0'

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
    # replica-doctor.sh is the READ-ONLY memory doctor behind factory.sh's
    # claim-boundary recycle gate (ported 2026-09-01 from open-saas
    # 2594cf507): the same main-enumerator spelling as targets.sh, selects
    # the local replica binary (never a script), measures footprint, kills
    # NOTHING - there is no kill path anywhere in the file.
    scripts/replica-doctor.sh) ALLOW='pgrep [-]f "pocket-ic --ttl' ;;
    # factory.sh's spawn_live_pids selects claude session processes by
    # --name (the "[-]-name <session>" argv pattern held in $pat) to verify
    # a spawned successor came up — detection only, prints pids, kills
    # NOTHING (any kill in factory.sh goes by captured PID). Law 10 bans
    # pattern KILLS, not read-only lookups. Scoped to this one spelling.
    # The 2026-10-31 engine re-sync from open-saas adds three read-only
    # ENUMERATORS beside it: replica-recycle's two (the local replica binary
    # and its launcher, both then lsof-ATTRIBUTED to the caller's own
    # worktree before any kill - and every kill goes by that captured pid,
    # rr_kill_tree) and name_pids' `pgrep -a -f "$pat"` (session processes
    # by --name, detection only: the duplicate-session gate, fleet-doctor's
    # husk rows). Law 10 bans pattern KILLS; none of these kills.
    scripts/factory.sh)     ALLOW='pgrep [-]f "\$pat"|pgrep -a [-]f "\$pat"|pgrep [-]f '"'"'pocket-ic --ttl'"'"'|pgrep [-]f '"'"'icp-cli-network-launcher'"'"'' ;;
    *)                      ALLOW='W1MDX-NEVER-MATCHES' ;;
  esac
  grep_scan h "$(uncommented "$f")" 'p(kill|grep) +(-[A-Za-z0-9]+ +)*-f'
  grep_filter h "$ALLOW"
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

# ── 3c. play_start honours --no-simulate: the fleet START sits under a knob (task 1788479256) ──
# play_start.sh step 7 used to stop AND start the local fleet unconditionally,
# and cold_start's --no-simulate governed only its own §4 launcher — so no
# factory seat (where --no-simulate is non-negotiable) could run the canonical
# #play bring-up at all. Now cold_start forwards an EXPLICIT --no-simulate to
# play_start as MDX_NO_SIMULATE=1, and play_start's start_bots_local.sh call
# sits inside that knob's else-branch while the stop stays unconditional
# BEFORE it (a stale recorded fleet trading under the reinstall is the thing
# the step exists to prevent). Pinned structurally on the uncommented source:
# the play_start step-7 block is the text between its two `hdr` lines, and
# the order stop < if-knob < start < fi is asserted by line number so a
# start hoisted out of the branch (or above the stop) reds here.
PS7=$(uncommented scripts/play_start.sh | awk '/^hdr "Trading bots"/{f=1} /^hdr "Frontend"/{f=0} f')
PS7_STOP_LN=$(printf '%s\n' "$PS7" | grep -n 'bash scripts/stop_bots_local.sh'  | head -1 | cut -d: -f1)
PS7_KNOB_LN=$(printf '%s\n' "$PS7" | grep -n '^if \[ "${MDX_NO_SIMULATE:-0}" = "1" \]' | head -1 | cut -d: -f1)
# Line-START anchored: the skip branch's warn text NAMES the start command
# ("start it by hand with: bash scripts/start_bots_local.sh"), which is
# advice, not a call — only a line that BEGINS with the command is a call.
PS7_START_LN=$(printf '%s\n' "$PS7" | grep -nE '^[[:space:]]*bash scripts/start_bots_local.sh' | head -1 | cut -d: -f1)
PS7_FI_LN=$(printf '%s\n' "$PS7" | grep -n '^fi$' | head -1 | cut -d: -f1)
if [ -n "$PS7_STOP_LN" ] && [ -n "$PS7_KNOB_LN" ] && [ -n "$PS7_START_LN" ] && [ -n "$PS7_FI_LN" ] \
   && [ "$PS7_STOP_LN" -lt "$PS7_KNOB_LN" ] && [ "$PS7_KNOB_LN" -lt "$PS7_START_LN" ] && [ "$PS7_START_LN" -lt "$PS7_FI_LN" ]; then
  _ok "play_start step 7: stop (${PS7_STOP_LN}) < MDX_NO_SIMULATE knob (${PS7_KNOB_LN}) < start (${PS7_START_LN}) < fi (${PS7_FI_LN})"
else
  _fail "play_start step 7 is not stop-then-knob-guarded-start: stop=${PS7_STOP_LN:-none} knob=${PS7_KNOB_LN:-none} start=${PS7_START_LN:-none} fi=${PS7_FI_LN:-none}"
fi
# Only ONE start call in the block — a second, unguarded one would defeat the knob.
assert_eq "play_start step 7 has exactly one start_bots_local.sh call" "1" \
  "$(printf '%s\n' "$PS7" | grep -cE '^[[:space:]]*bash scripts/start_bots_local.sh')"
# The knob's skip branch tells the operator how to start the fleet by hand.
src_has "play_start's skip branch names the manual start" "$PS7" "fleet NOT started (MDX_NO_SIMULATE=1)"
# cold_start forwards the knob in play mode, BEFORE it calls play_start.sh,
# and only for an EXPLICIT --no-simulate (the play default is also "no" and
# must keep launching the fleet).
COLD_UNC=$(uncommented scripts/cold_start.sh)
src_has "cold_start's --no-simulate records that it was explicit" "$COLD_UNC" '--no-simulate)    SIMULATE="no";  NO_SIMULATE_EXPLICIT=true;'
src_has "cold_start exports the knob for play_start"              "$COLD_UNC" 'export MDX_NO_SIMULATE=1'
COLD_KNOB_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'export MDX_NO_SIMULATE=1' | head -1 | cut -d: -f1)
COLD_PLAY_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'bash "$SCRIPT_DIR/play_start.sh"' | head -1 | cut -d: -f1)
if [ -n "$COLD_KNOB_LN" ] && [ -n "$COLD_PLAY_LN" ] && [ "$COLD_KNOB_LN" -lt "$COLD_PLAY_LN" ]; then
  _ok "cold_start exports MDX_NO_SIMULATE (line $COLD_KNOB_LN) before calling play_start.sh ($COLD_PLAY_LN)"
else
  _fail "cold_start's MDX_NO_SIMULATE export (${COLD_KNOB_LN:-none}) does not precede its play_start.sh call (${COLD_PLAY_LN:-none})"
fi
src_has "cold_start's help documents that --no-simulate reaches play mode" \
  "$(sed -n '1,80p' scripts/cold_start.sh)" "forwarded to it as MDX_NO_SIMULATE=1"

# ── 3d. play_start asserts every AMM admin reply + the post-seed vault (task 1788502351) ──
# play_start.sh step 5 used to run its seven AMM lifecycle calls as
# `adm … > /dev/null || true` — reply AND exit status discarded — and gate
# the whole block on `[ "$SEEDED" -gt 0 ]`, so a refused createAmmPool /
# setAmmConfig / enableAmm (a `variant { err }` is exit 0 from icp; a
# controller trap is a swallowed non-zero) printed "markets live", and three
# of four refused vault deposits came up as a one-pool venue reporting
# success. Now every one of those calls goes through must_ok / must_unit
# (seed.sh's reply oracles, task 1788501249), the seedAmmPool reply is
# asserted by SHAPE, the final gate is MDX_PLAY_MIN_SEEDED (default: all
# markets), the post-seed vault is asserted (assert_vault_seeded), and the
# die path resumes the timers. Pinned on the uncommented step-5 block (the
# text between its `hdr` and the insurance fund's).
PS5=$(uncommented scripts/play_start.sh | awk '/^hdr "AMM vault \+ maker ladder"/{f=1} /^hdr "Insurance fund"/{f=0} f')
[ -n "$PS5" ] || _fail "play_start step-5 block not found between its hdr lines — the §3d pins below are inert"
for m in createAmmPool setAmmConfig setAmmSkewConfig enableAmm; do
  # whitespace-tolerant: the labels are column-aligned in the script
  if printf '%s\n' "$PS5" | grep -qE "^[[:space:]]*must_ok \"$m \\\$market\"[[:space:]]+$m "; then
    _ok "play_start step 5 gates $m through must_ok"
  else
    _fail "play_start step 5 gates $m through must_ok — expected a line: must_ok \"$m \$market\" $m …"
  fi
done
src_has "play_start step 5 pauses the timers through must_unit"    "$PS5" 'must_unit "setTestTimersPaused(true)" setTestTimersPaused "(true)"'
src_has "play_start step 5 resumes the timers through must_unit"   "$PS5" 'must_unit "setTestTimersPaused(false)" setTestTimersPaused "(false)"'
src_has "play_start step 5 sets auto-inventory through must_unit"  "$PS5" 'must_unit "setAmmAutoInventory(true)"  setAmmAutoInventory "(true)"'
grep_scan PS5_SWALLOWED "$PS5" 'adm (createAmmPool|setAmmConfig|setAmmSkewConfig|enableAmm|setAmmAutoInventory|setTestTimersPaused) '
assert_eq "play_start step 5 has no swallowed AMM lifecycle call left (adm … || true)" "" "$PS5_SWALLOWED"
# seedAmmPool: asserted by reply shape, not a substring grep of the raw output.
src_has   "play_start's seedAmmPool reply is asserted by shape (mdx_reply_ok)" "$PS5" '! mdx_reply_ok "$seed_out"'
src_lacks "play_start's seedAmmPool gate no longer greps the raw output for err" "$PS5" 'grep -q "err"'
# The honest final gate + the post-seed vault assertion, in that order.
src_has "play_start's final gate is the MDX_PLAY_MIN_SEEDED knob (default all markets)" "$PS5" 'MIN_SEEDED="${MDX_PLAY_MIN_SEEDED:-$NMARKETS}"'
src_has "play_start dies below the knob"          "$PS5" '[ "$SEEDED" -ge "$MIN_SEEDED" ]'
src_has "play_start asserts the post-seed vault" "$PS5" 'assert_vault_seeded $SEEDED_TOKS'
src_lacks "play_start's old any-market gate is gone" "$PS5" '[ "$SEEDED" -gt 0 ]'
PS5_GATE_LN=$(printf '%s\n' "$PS5" | grep -n '\[ "$SEEDED" -ge "$MIN_SEEDED" \]' | head -1 | cut -d: -f1)
PS5_VAULT_LN=$(printf '%s\n' "$PS5" | grep -n 'assert_vault_seeded \$SEEDED_TOKS' | head -1 | cut -d: -f1)
PS5_LIVE_LN=$(printf '%s\n' "$PS5" | grep -n 'markets live' | head -1 | cut -d: -f1)
if [ -n "$PS5_GATE_LN" ] && [ -n "$PS5_VAULT_LN" ] && [ -n "$PS5_LIVE_LN" ] \
   && [ "$PS5_GATE_LN" -lt "$PS5_VAULT_LN" ] && [ "$PS5_VAULT_LN" -lt "$PS5_LIVE_LN" ]; then
  _ok "play_start step 5: shortfall gate ($PS5_GATE_LN) < vault assertion ($PS5_VAULT_LN) < 'markets live' ($PS5_LIVE_LN)"
else
  _fail "play_start step 5's 'markets live' line is not behind both gates: gate=${PS5_GATE_LN:-none} vault=${PS5_VAULT_LN:-none} live=${PS5_LIVE_LN:-none}"
fi
# The die path resumes the timers (a failed bring-up must not strand a paused venue).
PS_SF=$(sed -n '/^seed_fail() {/,/^}/p' scripts/play_start.sh)
src_has "play_start's seed_fail resumes the timers"                  "$PS_SF" 'setTestTimersPaused "(false)"'
src_has "play_start's seed_fail exits through die (non-zero)"        "$PS_SF" 'die "play bring-up ABORTED'
src_has "play_start's must_ok fails through seed_fail"   "$(sed -n '/^must_ok() {/,/^}/p'   scripts/play_start.sh)" 'seed_fail "$label refused'
src_has "play_start's must_unit fails through seed_fail" "$(sed -n '/^must_unit() {/,/^}/p' scripts/play_start.sh)" 'seed_fail "$label failed'
# The oracles carry the identity pin (mdex-process-safety §5) like seed.sh's.
src_has "play_start's call() refuses an identity-less call" "$(sed -n '/^call() {/,/^}/p' scripts/play_start.sh)" 'call() without --identity'
# Insurance fund: the (N : nat) shape (lib/reply.sh's mdx_reply_nat), not a substring `nat`.
PS_UNC=$(uncommented scripts/play_start.sh)
src_lacks "play_start's insurance gate no longer greps for a bare nat substring" "$PS_UNC" 'grep -q "nat"'
src_has   "play_start's insurance gate is the (N : nat) shape"                    "$PS_UNC" 'if mdx_reply_nat "$ins_out"; then'
src_has   "play_start's header documents MDX_PLAY_MIN_SEEDED" "$(sed -n '1,60p' scripts/play_start.sh)" 'MDX_PLAY_MIN_SEEDED'

# ── 3d′. ONE copy of the reply oracles: scripts/lib/reply.sh (task 1788503030) ──
# seed.sh (seed_ok), play_start.sh (reply_ok) and deploy.sh (mdx_call_ok /
# mdx_call_nat) each carried their own copy of the same predicates; a regex
# fixed in one place stayed broken in the other two. Now the PURE predicates
# — mdx_reply_ok / mdx_reply_unit / mdx_reply_nat / mdx_one_line /
# mdx_vault_nat / mdx_reply_nat_value — live once in scripts/lib/reply.sh,
# each of the three scripts sources it, and none defines a private copy (no
# old-name definition, no `grep … 'variant` needle, no `(N : nat)` regex of
# its own — gate OR extractor: the lib's mdx_reply_nat_value is the one
# bare-nat extractor and mdx_reply_nat its non-emptiness, task 1793496257).
# The behaviour unit for the lib is §6af (it slices the lib, not a script).
LIB_REPLY_UNC=$(uncommented scripts/lib/reply.sh)
for fn in mdx_reply_ok mdx_reply_unit mdx_reply_nat mdx_one_line mdx_vault_nat mdx_reply_nat_value; do
  grep_count n "$LIB_REPLY_UNC" "^$fn\(\) \{"
  if [ "$n" = "1" ]; then _ok "§3d: scripts/lib/reply.sh defines $fn exactly once (column 0)"
  else _fail "§3d: scripts/lib/reply.sh defines $fn $n times (expected exactly one column-0 definition — §6af slices it by name)"; fi
done
src_has "§3d: the lib's ok predicate accepts the named AND hash-spelled ok, nothing else" "$LIB_REPLY_UNC" "grep -cE 'variant \\{ (ok|24_860)( \\}| =)'"
src_has "§3d: the lib's nat extractor holds the bare (N : nat) shape (LAST match, underscores stripped)" "$LIB_REPLY_UNC" "grep -oE '\\([[:space:]]*[0-9][0-9_]*[[:space:]]*:[[:space:]]*nat[[:space:]]*\\)' | tail -1 | grep -oE '[0-9][0-9_]*' | tr -d '_'"
src_has "§3d: the lib's nat extractor ends in || true — exit 0 on a miss, the extractor status contract (task 1793502104; §6af drives it)" "$LIB_REPLY_UNC" "grep -oE '[0-9][0-9_]*' | tr -d '_' || true"
src_has "§3d: the lib's vault extractor ends in || true — exit 0 on an absent field, the same contract (task 1793502104)"              "$LIB_REPLY_UNC" "sed 's/.* = //' | tr -d '_' || true"
src_has "§3d: the lib's nat predicate is the extractor's non-emptiness (one regex: gate and value cannot drift)" "$LIB_REPLY_UNC" '[ -n "$(mdx_reply_nat_value "$1")" ]'
src_has "§3d: seed.sh sources scripts/lib/reply.sh"       "$(uncommented scripts/seed.sh)"       '. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/reply.sh"'
src_has "§3d: play_start.sh sources scripts/lib/reply.sh" "$PS_UNC"                              '. "$(cd "$(dirname "$0")" && pwd)/lib/reply.sh"'
src_has "§3d: deploy.sh sources scripts/lib/reply.sh"     "$(uncommented scripts/deploy.sh)"     '. "$(cd "$(dirname "$0")" && pwd)/lib/reply.sh"'
# Task 1788508007 brought tests/_lib.sh under the same roof: it sources the
# lib (SCRIPT_DIR there is the repo root, so the path is unambiguous) and its
# mdx_ok ROUTES to mdx_reply_ok instead of carrying a twin needle — §7i pins
# the routing and the absence of a private needle. scripts/simulate_trading.sh
# is deliberately OUTSIDE this scope: live fleets run it un-sourced, so its
# is_ok is a self-contained copy pinned literally in §7i and driven in §6af.
src_has "§3d: tests/_lib.sh sources scripts/lib/reply.sh (mdx_ok routes to the lib)" "$(uncommented tests/_lib.sh)" 'source "$SCRIPT_DIR/scripts/lib/reply.sh"'
for f in scripts/seed.sh scripts/play_start.sh scripts/deploy.sh; do
  code=$(uncommented "$f")
  grep_scan PRIV "$code" '^(seed_ok|seed_unit|reply_ok|reply_unit|reply_nat|one_line|vault_nat|mdx_call_ok|mdx_call_nat|mdx_reply_ok|mdx_reply_unit|mdx_reply_nat|mdx_one_line|mdx_vault_nat)\(\)'
  if [ -z "$PRIV" ]; then _ok "§3d: $f defines no private reply oracle (the lib is the only copy)"
  else _fail "§3d: $f carries a private reply-oracle definition again — use the lib's: $(printf '%s' "$PRIV" | tr '\n' ' ' | head -c 200)"; fi
  # The hand-rolled reply shapes the lib replaced: a grep whose pattern
  # literal opens with `variant` (the ok/err oracle), with
  # `\([[:space:]]*[0-9]` (the (N : nat) oracle, paren-anchored) or with
  # `[0-9][0-9_]*[[:space:]]*:` (the same oracle's "N : nat" TAIL spelling:
  # deploy.sh's old insurance read opened with `[0-9]` and sat under this
  # scan uncaught until task 1793498812 added the branch), under any flag
  # spelling (-qE, -cE, -E, -q -E, -F, -oE, none). An -o EXTRACTOR copy
  # counts too: the lib's mdx_reply_nat_value is the one bare-nat extractor
  # (task 1793496257 — until then seed.sh's bulk_fund pulled the N out of
  # its lib-gated reply with a private -o copy of the regex). A bare digit
  # run (`"[0-9][0-9_]*"`, deploy.sh's old arb read) is too generic to ban
  # as a regex: that routing is pinned LITERALLY after this loop instead.
  # Single-quoted ERE ('\'' is a literal quote): the double-quoted original
  # (04d8e40) turned `\\\(` into `\\(` — a literal backslash plus an UNCLOSED
  # group — so grep answered rc 2 ("parentheses not balanced") into `|| true`
  # on every run from 2026-09-04 until task 1793491373, and the assertion
  # could never fail. Hence grep_scan's rc split: 1 is "no match" (_ok),
  # 2+ is a broken needle and fails LOUDLY (mdex-process-safety §3).
  grep_scan NEEDLE "$code" 'grep( -[a-zA-Z]+)* +'\''(variant|\\\(\[\[:space:]]\*\[0-9]|\[0-9]\[0-9_]\*\[\[:space:]]\*:)'
  if [ -z "$NEEDLE" ]; then _ok "§3d: $f carries no private variant / (N : nat) regex (gate or extractor)"
  else _fail "§3d: $f greps a reply shape by hand instead of through lib/reply.sh: $(printf '%s' "$NEEDLE" | tr '\n' ' ' | head -c 200)"; fi
  grep_count USES "$code" '\bmdx_reply_(ok|unit|nat)\b'
  if [ "${USES:-0}" -ge 1 ]; then _ok "§3d: $f gates through the lib's predicates ($USES sites)"
  else _fail "§3d: $f never calls mdx_reply_ok / mdx_reply_unit / mdx_reply_nat — the gates moved off the lib"; fi
done
# The two deploy.sh bare-nat routings, pinned LITERALLY (task 1793498812):
# the insurance pool read (1793496257) and the arb working-capital read,
# whose old `grep -oE "[0-9][0-9_]*" | head -1` the needle above cannot see
# (double-quoted, too generic to ban) and which was shape-blind — a
# hash-spelled variant's `5_048_165` read as a funded arb and the fund was
# skipped behind "already funded". §6ao (7b) drives the arb block with
# exactly that reply; this pin is the static half. The capture is BARE —
# no `|| true` at the site — by the lib's EXTRACTOR STATUS CONTRACT (task
# 1793502104, decision A): mdx_reply_nat_value's pipeline ends in a grep
# that misses on every non-nat reply, so until then the function answered
# empty WITH STATUS 1 under pipefail, and deploy.sh's `set -euo pipefail` —
# enforced on the assignment at TOP level even though not inside the
# function (§6ap) — ended the script silently (§6ao's bad / miss / hashed
# moods all exited 1) at exactly the reply the -z arm exists to survive;
# 1793498812 landed the site with `|| true` inside the substitution. Now
# the extractor itself ends in `|| true` (pinned above, DRIVEN in §6af), the
# site reads like seed.sh's and play_start.sh's bare captures, and §6ao's
# moods drive this very block through the real lib. seed.sh and
# play_start.sh run without -e.
DEPLOY_UNC_3D=$(uncommented scripts/deploy.sh)
src_has "§3d: deploy.sh's arb working-capital read is the lib's extractor over the captured reply, BARE — the extractor's own || true is the status (tasks 1793498812, 1793502104)" "$DEPLOY_UNC_3D" 'arb_bal="$(mdx_reply_nat_value "$arb_out")"'
src_has "§3d: deploy.sh's insurance pool read is the lib's extractor over the captured reply (task 1793496257)"     "$DEPLOY_UNC_3D" 'seed_ins_pool="$(mdx_reply_nat_value "$seed_ins_out" | awk '\''{printf "%.0f", $1/1e8}'\'')"'
# (b) play_start's remaining swallowed money / wiring lines (task 1788503030):
# setTestBalance answers `()`, so the three funding lines (ladder makers'
# ICPUSD, their per-market base leg, the LP's base leg) are must_unit — a
# trap or a CLI failure is a die carrying the reply, not a warn (or nothing)
# that a refused seedAmmPool re-reports one screen later. setFuelRoute and
# setXrcCanister are wiring, not money: captured, judged by shape, and a
# warn that NAMES the reply.
src_has "play_start funds the ladder makers' ICPUSD through must_unit"   "$PS_UNC" 'must_unit "fund $t ICPUSD" setTestBalance "(principal \"$tp\", \"ICPUSD\", $(e8 40000.0))" --identity anonymous'
src_has "play_start funds the ladder makers' base leg through must_unit" "$PS_UNC" 'must_unit "fund $t $base_tok" setTestBalance "(principal \"$tp\", \"$base_tok\", $(e8 $mm_base))" --identity anonymous'
src_has "play_start funds the LP's base leg through must_unit"           "$PS_UNC" 'must_unit "fund LP $base_tok leg" setTestBalance "(principal \"$LP_PRINCIPAL\", \"$base_tok\", $(e8 $base_fund))" --identity anonymous'
src_has "play_start funds the LP's quote leg through must_unit"          "$PS_UNC" 'must_unit "fund LP ICPUSD quote leg" setTestBalance "(principal \"$LP_PRINCIPAL\", \"ICPUSD\",'
grep_scan PS_SWALLOWED "$PS_UNC" 'adm (setTestBalance|setFuelRoute|setXrcCanister) .*> */dev/null'
assert_eq "play_start has no swallowed setTestBalance / setFuelRoute / setXrcCanister line left (adm … > /dev/null)" "" "$PS_SWALLOWED"
src_has "play_start judges setFuelRoute's reply by shape"      "$PS_UNC" 'if [ "$fr_rc" -eq 0 ] && mdx_reply_unit "$fr_out"; then'
src_has "play_start's setFuelRoute warn names the reply"       "$PS_UNC" 'warn "setFuelRoute did not answer () (rc=$fr_rc) — auto-fuel Stage 2 may be unwired: $(mdx_one_line "$fr_out")"'
src_has "play_start judges setXrcCanister's reply by shape"    "$PS_UNC" 'if [ "$xrc_rc" -eq 0 ] && mdx_reply_unit "$xrc_out"; then'
src_has "play_start's setXrcCanister warn names the reply"     "$PS_UNC" 'warn "setXrcCanister (null) did not answer () (rc=$xrc_rc) — a dev XRC wiring may survive: $(mdx_one_line "$xrc_out")"'

# ── 3e. The keychain helper: no password on argv, no `unsigned:` grant, controller keys opt-in (H-01 · F15 + F17) ──
# scripts/fix_icp_keychain_prompts.sh used to spawn one `security
# set-generic-password-partition-list … -k "$PASS"` per icp identity — 200+
# children with the login password in each argv (readable via ps /
# KERN_PROCARGS2 by any same-user process) — and granted the `unsigned:`
# partition (any binary, no code-signature check) on EVERY icp-cli item,
# the funded controller/wallet identity included. Now: ONE `security -i`
# process fed over stdin (the password is a token on a pipe, never an argv
# element), the partition is the resolved icp executable's Team ID
# (`teamid:<ID>`, read from codesign at runtime; an unsigned or ad-hoc
# executable is REFUSED, never widened), the identities are an explicit
# allow-list (default: the launchd fleet's `<target>bot_N` family) with
# SN_IDENTITY / CE_IDENTITY / WALLET excluded unless --include-controller,
# and the consequence is printed before any mutation (--yes / --dry-run).
# Behaviour is exercised by tests/test_keychain_helper.sh against PATH shims
# (never a real keychain); this section pins the SOURCE shape.
KCH=$(uncommented scripts/fix_icp_keychain_prompts.sh)
src_lacks "keychain helper never passes the password on argv (-k \"\$PASS\")"      "$KCH" '-k "$PASS"'
src_lacks "keychain helper never grants the unsigned: partition"                    "$KCH" 'unsigned:'
src_has   "keychain helper drives ONE security -i process over stdin"               "$KCH" 'security -i'
src_has   "keychain helper composes the partition from the executable's Team ID"    "$KCH" 'teamid:'
src_has   "keychain helper's identities are an explicit allow-list (--identity)"     "$KCH" '--identity)'
src_has   "keychain helper excludes the controller keys unless --include-controller" "$KCH" '--include-controller)'
src_has   "keychain helper has a --dry-run that prints the security lines"           "$KCH" '--dry-run)'
src_has   "keychain helper redacts the password in every printed line"              "$KCH" '<redacted>'
src_has   "keychain helper asks for confirmation unless --yes"                      "$KCH" '--yes)'
src_has   "keychain helper fails fast on an unhandled error"                        "$KCH" 'set -euo pipefail'
src_has   "keychain helper resolves paths through SCRIPT_DIR"                       "$KCH" 'SCRIPT_DIR='
# 1788552433: the three captures on the executable-resolve path are gated BY
# NAME. Under `set -euo pipefail` a failing `$(resolve_path …)` — a shebang
# interpreter that does not exist, so realpath exits 1 — or a failing
# `$(head -n 1 …)` ended the helper with only the tool's own stderr line: no
# die, no variable, no line named (the 1788480302 class (b): a bare capture,
# where `$(…)` propagates the single command's status and -e stops the script
# before any of its own dies can speak). The perl fallback answers '' with
# exit 0 for the same missing path, so each gate tests the VALUE too. Pinned
# literally, then a bare-capture scan over the resolve path with a negative
# control (the gates stripped must expose exactly the three sites), then the
# REAL helper is driven with a stub `icp` whose shebang names a missing
# interpreter — --dry-run, and the abort lands before `icp identity list`,
# so no real icp and no `security` is ever reached — and must die by name;
# the same run against the helper with its gates stripped is the negative
# control: exit non-zero with nothing named (the bug the probe pins).
src_has "keychain helper: the ICP_REAL capture is gated on status AND value, dying by name"   "$KCH" 'ICP_REAL=$(resolve_path "$ICP_CMD") && [ -n "$ICP_REAL" ] || die'
src_has "keychain helper: ...naming the variable"                                            "$KCH" "ICP_REAL=''"
src_has "keychain helper: the SHEBANG capture is gated, dying by name"                       "$KCH" 'SHEBANG=$(head -n 1 "$ICP_REAL") || die'
src_has "keychain helper: ...naming the variable"                                            "$KCH" "SHEBANG=''"
src_has "keychain helper: the EXEC_PATH capture is gated on status AND value, dying by name" "$KCH" 'EXEC_PATH=$(resolve_path "$INTERP") && [ -n "$EXEC_PATH" ] || die'
src_has "keychain helper: ...naming the variable"                                            "$KCH" "EXEC_PATH=''"
kch_bare() { grep -nE '=\$\((resolve_path|head) ' | grep -vE '\|\| *die ' || true; }
KCH_BARE="$(printf '%s\n' "$KCH" | kch_bare)"
if [ -z "$KCH_BARE" ]; then _ok "keychain helper: no bare \$(resolve_path …) / \$(head …) capture remains on the resolve path"
else _fail "keychain helper: bare capture(s) on the resolve path (gate with || die naming the variable — task 1788552433): $(printf '%s' "$KCH_BARE" | tr '\n' ' ' | head -c 300)"; fi
kch_strip() { sed -E 's/( && \[ -n "\$[A-Z_]+" \])? \|\| die "[^"]*"$//'; }
KCH_NEG="$(printf '%s\n' "$KCH" | kch_strip | kch_bare | grep -c '' || true)"
if [ "${KCH_NEG:-0}" -eq 3 ]; then _ok "keychain helper negative control: with the gates stripped the scan exposes exactly the 3 resolve-path captures"
else _fail "keychain helper negative control: the scan saw ${KCH_NEG:-0} bare capture(s) with the gates stripped (expected 3) — it cannot see the shape it bans"; fi
KCH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/kch3e.XXXXXX")"
mkdir -p "$KCH_TMP/bin"
printf '#!%s/nowhere/node\nconsole.log(1)\n' "$KCH_TMP" > "$KCH_TMP/bin/icp"; chmod 755 "$KCH_TMP/bin/icp"
kch_strip < scripts/fix_icp_keychain_prompts.sh > "$KCH_TMP/stripped.sh"
KCH_OUT="$(PATH="$KCH_TMP/bin:$PATH" bash scripts/fix_icp_keychain_prompts.sh --dry-run 2>&1)"; KCH_RC=$?
if [ "$KCH_RC" -ne 0 ] && printf '%s\n' "$KCH_OUT" | grep -qF "missing interpreter? realpath/perl failed or answered nothing) — EXEC_PATH=''" && ! printf '%s\n' "$KCH_OUT" | grep -qF 'security lines'; then
  _ok "keychain helper driven with a stub icp whose shebang names a missing interpreter: dies BY NAME (EXEC_PATH='', exit $KCH_RC) before the consequence print"
else _fail "keychain helper under a missing-interpreter stub: exit $KCH_RC — $(printf '%s' "$KCH_OUT" | tr '\n' ' ' | head -c 300)"; fi
KCH_OUT="$(PATH="$KCH_TMP/bin:$PATH" bash "$KCH_TMP/stripped.sh" --dry-run 2>&1)"; KCH_RC=$?
if [ "$KCH_RC" -ne 0 ] && ! printf '%s\n' "$KCH_OUT" | grep -q "EXEC_PATH=''" && ! printf '%s\n' "$KCH_OUT" | grep -q '✗'; then
  _ok "keychain helper negative control: with the gates stripped the same stub aborts with NOTHING named (exit $KCH_RC, only realpath's own line) — the probe sees the bug"
else _fail "keychain helper negative control (gates stripped) did not abort silently: exit $KCH_RC — $(printf '%s' "$KCH_OUT" | tr '\n' ' ' | head -c 300)"; fi
rm -rf "$KCH_TMP"

# ── 3f. The skill sync never replaces or prunes a directory it did not install (H-03 · F7, task 1788467591) ──
# .claude/sync-ic-skills.sh runs at EVERY session start on every seat and used
# to move aside and replace ANY existing .claude/skills/<name> the remote index
# named, recording it as managed — so a later index that dropped the name
# pruned it. The two git-tracked guardrail skills (mdex-process-safety,
# mdex-software-factory — .gitignore's explicit exceptions) were replaceable
# and deletable by whoever answers for skills.internetcomputer.org, the
# authority the script's own header says the mirror never has. Now the
# manifest (.ic-managed.json) is the ONLY authority over replace/prune: a
# git-tracked name is refused outright (install AND prune, even when a
# poisoned manifest lists it); an existing directory the manifest does not
# list is refused; a refusal never records; fetches are scheme-pinned
# (https, or file:// for offline fixtures) and a redirect off $BASE discards
# the download. The behaviour is DRIVEN here against a throwaway tree under
# the suite scratch — its own nested git repo with the two repo-owned skills
# committed — via SYNC_BASE=file:///… fixture indexes; the real
# .claude/skills is never touched and no network is reached.
SYNC_SRC=$(uncommented .claude/sync-ic-skills.sh)
src_has "sync: SYNC_BASE overrides the origin (offline fixtures)"                 "$SYNC_SRC" 'SYNC_BASE:-https://skills.internetcomputer.org/.well-known/skills'
src_has "sync: fetches are pinned to the origin scheme, redirects included"        "$SYNC_SRC" '--proto "=$PROTO" --proto-redir "=$PROTO"'
src_has "sync: a redirect that leaves \$BASE discards the download"               "$SYNC_SRC" '"$BASE"/*) return 0 ;;'
src_has "sync: the index and every file go through the pinned fetch"              "$SYNC_SRC" 'fetch "$BASE/$name/$f" "$STAGING/$f"'
src_lacks "sync: no bare curl -L outside the pinned helper"                        "$(printf '%s\n' "$SYNC_SRC" | grep -v 'curl -fsSL --max-time 20 --proto')" 'curl -fsSL'
src_has "sync: git-tracked names are refused via ls-files --error-unmatch"        "$SYNC_SRC" 'git ls-files --error-unmatch -- "$DEST/$1"'
src_has "sync: an existing dir the manifest does not list is refused"             "$SYNC_SRC" '[ -e "$DEST/$name" ] && ! is_managed "$name"'
src_has "sync: the prune loop refuses git-tracked names"                          "$SYNC_SRC" 'refused to prune'
src_lacks "sync: no pattern kills"                                                 "$SYNC_SRC" 'pkill'
SYNC_T=$(scratch_new sync-tree) && SYNC_FX=$(scratch_new sync-fx) && SYNC_W=$(scratch_new sync-work) || exit 1
mkdir -p "$SYNC_T/.claude/skills" "$SYNC_FX" "$SYNC_W"
cp .claude/sync-ic-skills.sh "$SYNC_T/.claude/"
sed -n '/^\.claude\/skills\/\*/,/^!\.claude\/skills\/mdex-software-factory\/$/p' .gitignore > "$SYNC_T/.gitignore"
cp -R .claude/skills/mdex-process-safety .claude/skills/mdex-software-factory "$SYNC_T/.claude/skills/"
sync_git() { git -C "$SYNC_T" -c core.hooksPath="$SYNC_T/.nohooks" -c user.name=hygiene -c user.email=hygiene@localhost -c commit.gpgsign=false "$@"; }
sync_git init -q && sync_git add .gitignore .claude/skills/mdex-process-safety .claude/skills/mdex-software-factory && sync_git commit -q -m fixture
if sync_git ls-files --error-unmatch .claude/skills/mdex-process-safety >/dev/null 2>&1; then _ok "§3f fixture: the scratch repo tracks mdex-process-safety (as the real one does)"
else _fail "§3f fixture: could not build the tracked-skill scratch repo — the block below cannot judge the git-tracked guard"; fi
# sync_idx <fxdir> <name|hash|file,file>...  — a fixture index in the upstream shape
sync_idx() {
  local d="$1" js='{"skills":[]}' spec n rest h files; shift; mkdir -p "$d"
  for spec in "$@"; do
    n="${spec%%|*}"; rest="${spec#*|}"; h="${rest%%|*}"; files="${rest#*|}"
    js="$(jq -c --arg n "$n" --arg h "$h" --arg f "$files" '.skills += [{name:$n, hash:$h, files:($f|split(","))}]' <<<"$js")"
  done; printf '%s\n' "$js" > "$d/index.json"
}
sync_run() {   # sync_run <fx-subdir|url>: the script under test, in the scratch tree, against a fixture
  local base="$1"; case "$base" in *://*) ;; *) base="file://$SYNC_FX/$base" ;; esac
  (cd "$SYNC_T" && SYNC_BASE="$base" bash .claude/sync-ic-skills.sh >"$SYNC_W/out" 2>"$SYNC_W/err"); echo "exit=$?" >>"$SYNC_W/err"
}
SYNC_SK="$SYNC_T/.claude/skills"; SYNC_MF="$SYNC_SK/.ic-managed.json"
mkdir -p "$SYNC_SK/local-notes" "$SYNC_SK/alpha"
printf 'my private notes\n' > "$SYNC_SK/local-notes/SKILL.md"; printf 'alpha v1\n' > "$SYNC_SK/alpha/SKILL.md"
cp -R "$SYNC_SK/mdex-process-safety" "$SYNC_W/mps.before"; cp -R "$SYNC_SK/mdex-software-factory" "$SYNC_W/msf.before"
# (A) the brief's Verify: an index naming the tracked skill; the managed alpha unchanged at its hash.
sync_idx "$SYNC_FX/A" "mdex-process-safety|sha256:evil|SKILL.md" "alpha|sha256:alpha1|SKILL.md"
mkdir -p "$SYNC_FX/A/mdex-process-safety" "$SYNC_FX/A/alpha"
printf 'PWNED\n' > "$SYNC_FX/A/mdex-process-safety/SKILL.md"; printf 'alpha v1\n' > "$SYNC_FX/A/alpha/SKILL.md"
jq -n '{"alpha":"sha256:alpha1"}' > "$SYNC_MF"; cp "$SYNC_MF" "$SYNC_W/manifest.before"
sync_run A
if diff -r "$SYNC_W/mps.before" "$SYNC_SK/mdex-process-safety" >/dev/null 2>&1; then _ok "§3f(A): the tracked mdex-process-safety dir is byte-identical after a run whose index names it"
else _fail "§3f(A): mdex-process-safety was REPLACED by the index (now: $(head -c 40 "$SYNC_SK/mdex-process-safety/SKILL.md" 2>/dev/null | tr '\n' ' '))"; fi
if cmp -s "$SYNC_W/manifest.before" "$SYNC_MF"; then _ok "§3f(A): the manifest is byte-identical (a refused name is never recorded)"
else _fail "§3f(A): the manifest changed: $(jq -cS . "$SYNC_MF" 2>/dev/null)"; fi
if grep -q "refused to install 'mdex-process-safety'" "$SYNC_W/err"; then _ok "§3f(A): the refusal is warned on stderr"
else _fail "§3f(A): no refusal warning (stderr: $(tr '\n' '|' < "$SYNC_W/err"))"; fi
if jq -e '.hookSpecificOutput.reloadSkills == false and (.systemMessage|test("1 refused"))' "$SYNC_W/out" >/dev/null 2>&1; then _ok "§3f(A): the refusal surfaces as a systemMessage, without a skills reload"
else _fail "§3f(A): hook output: $(tr -d '\n' < "$SYNC_W/out")"; fi
if [ -z "$(ls -d "$SYNC_SK"/.staging-* "$SYNC_SK"/.old-* 2>/dev/null)" ] && grep -q 'exit=0' "$SYNC_W/err"; then _ok "§3f(A): no staging/backup residue, exit 0"
else _fail "§3f(A): residue left or nonzero exit"; fi
# (B) adjacent cases: an untracked dir the manifest does not list (refused); a POISONED manifest
#     naming a tracked skill that the index drops (prune refused); the positive path — a managed
#     skill updated at a new hash and a new skill installed with a subdir file.
sync_idx "$SYNC_FX/B" "local-notes|sha256:evil2|SKILL.md" "beta|sha256:beta1|SKILL.md,scripts/run.sh" "alpha|sha256:alpha2|SKILL.md"
mkdir -p "$SYNC_FX/B/local-notes" "$SYNC_FX/B/beta/scripts" "$SYNC_FX/B/alpha"
printf 'PWNED\n' > "$SYNC_FX/B/local-notes/SKILL.md"; printf 'beta skill\n' > "$SYNC_FX/B/beta/SKILL.md"
printf 'echo run\n' > "$SYNC_FX/B/beta/scripts/run.sh"; printf 'alpha v2\n' > "$SYNC_FX/B/alpha/SKILL.md"
jq -n '{"alpha":"sha256:alpha1","mdex-software-factory":"sha256:poison"}' > "$SYNC_MF"
sync_run B
if [ "$(cat "$SYNC_SK/local-notes/SKILL.md" 2>/dev/null)" = "my private notes" ]; then _ok "§3f(B): an untracked dir the manifest does not list is left untouched"
else _fail "§3f(B): local-notes (untracked, unmanaged) was replaced"; fi
if diff -r "$SYNC_W/msf.before" "$SYNC_SK/mdex-software-factory" >/dev/null 2>&1; then _ok "§3f(B): a tracked skill survives a poisoned manifest + an index that drops it (prune refused)"
else _fail "§3f(B): mdex-software-factory was pruned or replaced on a poisoned manifest"; fi
if [ "$(cat "$SYNC_SK/alpha/SKILL.md" 2>/dev/null)" = "alpha v2" ]; then _ok "§3f(B): a managed skill at a new hash is updated"
else _fail "§3f(B): alpha was not updated (the guard must not block what the manifest lists)"; fi
if [ "$(cat "$SYNC_SK/beta/SKILL.md" 2>/dev/null)" = "beta skill" ] && [ "$(cat "$SYNC_SK/beta/scripts/run.sh" 2>/dev/null)" = "echo run" ]; then _ok "§3f(B): a new skill installs, subdir file included"
else _fail "§3f(B): beta was not installed"; fi
if [ "$(jq -cS . "$SYNC_MF" 2>/dev/null)" = '{"alpha":"sha256:alpha2","beta":"sha256:beta1"}' ]; then _ok "§3f(B): the manifest lists exactly what the script installed"
else _fail "§3f(B): manifest: $(jq -cS . "$SYNC_MF" 2>/dev/null)"; fi
if grep -q "refused to install 'local-notes'" "$SYNC_W/err" && grep -q "refused to prune 'mdex-software-factory'" "$SYNC_W/err"; then _ok "§3f(B): both refusals are warned"
else _fail "§3f(B): refusal warnings missing (stderr: $(tr '\n' '|' < "$SYNC_W/err"))"; fi
if jq -e '.hookSpecificOutput.reloadSkills == true and (.systemMessage|test("1 added, 1 updated, 0 removed, 2 refused"))' "$SYNC_W/out" >/dev/null 2>&1; then _ok "§3f(B): the summary counts installs, updates and refusals; a real change reloads skills"
else _fail "§3f(B): hook output: $(tr -d '\n' < "$SYNC_W/out")"; fi
# (C) the prune of a MANAGED name still works, and a no-op run stays silent.
sync_idx "$SYNC_FX/C" "beta|sha256:beta1|SKILL.md,scripts/run.sh"
mkdir -p "$SYNC_FX/C/beta/scripts"; cp "$SYNC_FX/B/beta/SKILL.md" "$SYNC_FX/C/beta/"; cp "$SYNC_FX/B/beta/scripts/run.sh" "$SYNC_FX/C/beta/scripts/"
sync_run C
if [ ! -e "$SYNC_SK/alpha" ] && jq -e '.systemMessage|test("0 added, 0 updated, 1 removed, 0 refused")' "$SYNC_W/out" >/dev/null 2>&1; then _ok "§3f(C): a managed skill the index drops is still pruned"
else _fail "§3f(C): alpha not pruned or not reported ($(tr -d '\n' < "$SYNC_W/out"))"; fi
sync_run C
if [ ! -s "$SYNC_W/out" ]; then _ok "§3f(C): a no-op run prints nothing"
else _fail "§3f(C): a no-op run printed: $(tr -d '\n' < "$SYNC_W/out")"; fi
# (D) the scheme pin: a base that is neither https:// nor file:/// is refused before any fetch
#     (exit 0, nothing touched — a hook must never fail the session); an unreachable base keeps the cache.
cp "$SYNC_MF" "$SYNC_W/manifest.C"
sync_run "http://127.0.0.1:9/skills"
if grep -q 'SYNC_BASE must be https' "$SYNC_W/err" && grep -q 'exit=0' "$SYNC_W/err" && cmp -s "$SYNC_W/manifest.C" "$SYNC_MF"; then _ok "§3f(D): an http:// base is refused before any fetch, exit 0, nothing touched"
else _fail "§3f(D): http base: $(tr '\n' '|' < "$SYNC_W/err")"; fi
sync_run "file://$SYNC_W/does-not-exist"
if grep -q 'could not reach' "$SYNC_W/err" && grep -q 'exit=0' "$SYNC_W/err" && [ -e "$SYNC_SK/beta" ] && cmp -s "$SYNC_W/manifest.C" "$SYNC_MF"; then _ok "§3f(D): an unreachable base keeps the cached skills and the manifest, exit 0"
else _fail "§3f(D): unreachable base: $(tr '\n' '|' < "$SYNC_W/err")"; fi
rm -rf "$SYNC_T" "$SYNC_FX" "$SYNC_W"

# ── 3g. The smoke harness names no venue port and never acts as an identity (task 1793500998) ──
# scripts/smoke-harness.mjs serves the built bundle at a unique *.localhost
# host for undisturbed browser smokes and proxies /api/* to the gateway port
# it is GIVEN (--gateway: the seat's OS-assigned one). Two literals it must
# never grow, scanned over the WHOLE file, comments included (a reader copies
# what a comment shows): the primary's machine-global venue port (the
# operator's live venue - bring-up step 2 - which a tool run from a seat must
# never guess at), and an `icp ` invocation (it must never act as an identity
# - law 10; the bundle's ids reach it through the venue's own ic_env cookie,
# copied at start). The positive pins beside the bans keep the block from
# passing on an emptied or moved file. Behaviour: tests/smoke_harness.test.mjs.
SMOKE_SRC=$(cat scripts/smoke-harness.mjs 2>/dev/null)
if [ -n "$SMOKE_SRC" ]; then _ok "§3g: scripts/smoke-harness.mjs is present and non-empty"
else _fail "§3g: scripts/smoke-harness.mjs is missing or empty — the pins below are inert"; fi
src_lacks "§3g: the smoke harness carries no 8000 literal (the operator's machine-global venue, :8000 included)" "$SMOKE_SRC" '8000'
src_lacks "§3g: the smoke harness never spells an icp invocation (it must never act as an identity — law 10)"  "$SMOKE_SRC" 'icp '
src_has   "§3g: the smoke harness takes the gateway port as an argument, never a default"                        "$SMOKE_SRC" '--gateway <port> is required'
src_has   "§3g: the smoke harness binds and proxies on loopback only"                                            "$SMOKE_SRC" 'const LOOPBACK = "127.0.0.1"'
src_has   "§3g: the smoke harness refuses to start without the venue's ic_env cookie"                            "$SMOKE_SRC" 'frontend not deployed on ${gateway}'

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
  if grep_has "$PROBE_OUT" ': error'; then
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

# ── 6bg. The frontend recipe: static-site (certified-assets), configured by
# _headers / _redirects (task 1793503326, 2026-11-01) ───────────────────
# The legacy @dfinity/asset-canister read public/.ic-assets.json5; the
# certified-assets canister never does (a dotfile is not even uploaded), so a
# config left there is silent. Pinned: the recipe line, the two files that
# configure it (their CONTENT is tests/frontend_security.test.mjs §E's), the
# legacy file's absence, and the one-time migration gate — a venue still on
# the legacy wasm cannot be UPGRADED (unrelated Candid interfaces: icp refuses
# the deploy as BREAKING before installing anything; --yes would push it onto
# stable memory the new wasm cannot read), so cold_start.sh and `deploy.sh
# local frontend` reinstall the stateless frontend themselves when the
# legacy-only `api_version` query answers, and deploy.sh NAMES the explicit
# `--mode reinstall` for a remote venue instead of running it (law 8). The
# detector is driven against a stub icp both ways.
src_has   "§6bg: icp.yaml hosts the frontend on the static-site (certified-assets) recipe" "$YAML_CODE" 'type: "@dfinity/static-site@v'
src_lacks "§6bg: icp.yaml no longer names the legacy asset-canister recipe"                "$YAML_CODE" 'asset-canister'
if [ -f src/frontend/public/_headers ];   then _ok "§6bg: public/_headers ships (the CSP, the security headers, caching)"; else _fail "§6bg: src/frontend/public/_headers missing — the certified-assets canister adds NO default headers"; fi
if [ -f src/frontend/public/_redirects ]; then _ok "§6bg: public/_redirects ships (the SPA fallback)";                   else _fail "§6bg: src/frontend/public/_redirects missing — deep links would 404"; fi
if [ -e src/frontend/public/.ic-assets.json5 ]; then _fail "§6bg: public/.ic-assets.json5 is back — the static-site canister never reads it (rules there silently do nothing)"; else _ok "§6bg: no public/.ic-assets.json5 (the legacy config left with the legacy recipe)"; fi
TGT_FR="$(uncommented scripts/lib/targets.sh)"
src_has "§6bg: targets.sh defines the legacy-wasm detector"                     "$TGT_FR" 'mdx_frontend_is_legacy_asset_canister() {'
src_has "§6bg: ...which probes the legacy-only api_version query on the env"     "$TGT_FR" "echo y | icp canister call frontend api_version '()' --query -e \"\$1\" --identity \"\$2\" >/dev/null 2>&1"
COLD_FR="$(uncommented scripts/cold_start.sh)"
src_has "§6bg: cold_start reinstalls a legacy frontend BEFORE the plain deploy"  "$COLD_FR" 'if mdx_frontend_is_legacy_asset_canister local anonymous; then'
src_has "§6bg: ...with --mode reinstall, never --yes"                            "$COLD_FR" 'icp deploy frontend --mode reinstall --identity anonymous'
if printf '%s\n' "$COLD_FR" | grep -n 'mdx_frontend_is_legacy_asset_canister local anonymous\|^  log "icp deploy"$' | head -2 | sed -n '1p' | grep -q 'mdx_frontend_is_legacy_asset_canister'; then _ok "§6bg: the reinstall gate sits above the plain \`icp deploy\` (the whole deploy would otherwise be refused)"; else _fail "§6bg: the reinstall gate must precede cold_start's \`log \"icp deploy\"\`"; fi
DEPLOY_FR="$(uncommented scripts/deploy.sh)"
src_has "§6bg: deploy.sh frontend-only probes the legacy wasm on the target env" "$DEPLOY_FR" 'if mdx_frontend_is_legacy_asset_canister "$FO_ENV" "$FO_ID"; then'
src_has "§6bg: ...reinstalls it on a LOCAL venue"                                 "$DEPLOY_FR" 'FO_MODE=(--mode reinstall)'
src_has "§6bg: ...forwards the mode to icp deploy"                                "$DEPLOY_FR" '${FO_MODE[@]+"${FO_MODE[@]}"}'
src_has "§6bg: ...and NAMES the explicit --mode reinstall for a remote venue"     "$DEPLOY_FR" 'bash scripts/deploy.sh $TARGET frontend --mode reinstall'
FR_TMP=$(mktemp -d); mkdir -p "$FR_TMP/bin"
cat > "$FR_TMP/bin/icp" <<'FREOF'
#!/usr/bin/env bash
# stub icp: `canister call frontend api_version` answers like the legacy asset
# canister when FR_MODE=legacy, like certified-assets (IC0536) otherwise.
case "$*" in
  *"canister call frontend api_version"*)
    if [ "${FR_MODE:-}" = legacy ]; then echo "(1 : nat16)"; exit 0; fi
    echo "Error: IC0536: Canister has no query method 'api_version'" >&2; exit 1 ;;
  *) echo "stub icp: unexpected: $*" >&2; exit 2 ;;
esac
FREOF
chmod +x "$FR_TMP/bin/icp"
if FR_MODE=legacy PATH="$FR_TMP/bin:$PATH" bash -c '. scripts/lib/targets.sh && mdx_frontend_is_legacy_asset_canister local anonymous' 2>/dev/null; then _ok "§6bg: the detector answers 0 when api_version answers (the legacy wasm)"; else _fail "§6bg: the detector said 'not legacy' though api_version answered"; fi
if FR_MODE=modern PATH="$FR_TMP/bin:$PATH" bash -c '. scripts/lib/targets.sh && mdx_frontend_is_legacy_asset_canister local anonymous' 2>/dev/null; then _fail "§6bg: the detector said 'legacy' on an IC0536 refusal (certified-assets)"; else _ok "§6bg: the detector answers non-zero when api_version is refused (certified-assets, or no canister)"; fi
rm -rf "$FR_TMP"

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
# H-02 (F20): the reader used to strip `//` only and match ONE spacing-exact
# regex, so a real declaration in any OTHER spelling was invisible to it and
# a canonical decoy inside a block comment or a Text literal was the only
# thing it saw: a re-spaced real `#dev` beside `/* … #play; */` read as
# "play" (docs/hardening-plan-2026-09.md §H-02, confirmed on a scratch
# fixture) — and every remote gate shares this reader. It now works on a
# CODE IMAGE (// and nested /* */ comments and "…"/'…' literals stripped),
# counts `let DEPLOY_MODE` in ANY spelling, and refuses unless that count
# AND the canonical-match count are both exactly 1 — a spelling it cannot
# read is refused, never guessed. Every fixture below is a payload the old
# reader answered "play" to; each must now yield NO posture and non-zero.
F20_DECOY='/* transient let DEPLOY_MODE : DeployMode = #play; */'
printf '  transient let DEPLOY_MODE  : DeployMode = #dev; %s\n' "$F20_DECOY" > "$POSTURE_DIR/f20-twospace.mo"
printf '  transient let DEPLOY_MODE\t: DeployMode = #dev; %s\n' "$F20_DECOY" > "$POSTURE_DIR/f20-tab.mo"
printf '  transient let DEPLOY_MODE: DeployMode = #dev;\n  %s\n' "$F20_DECOY" > "$POSTURE_DIR/f20-nospace.mo"
printf '  let s = "see // the docs"; transient let DEPLOY_MODE  : DeployMode = #dev;\n  %s\n' "$F20_DECOY" > "$POSTURE_DIR/f20-strslash.mo"
printf '  let doc = "transient let DEPLOY_MODE : DeployMode = #play;";\n  transient let DEPLOY_MODE  : DeployMode = #dev;\n' > "$POSTURE_DIR/f20-textdecoy.mo"
printf '  /*\n   * transient let DEPLOY_MODE : DeployMode = #play;\n   */\n  transient let DEPLOY_MODE  : DeployMode = #dev;\n' > "$POSTURE_DIR/f20-multiline.mo"
for fx in f20-twospace f20-tab f20-nospace f20-strslash f20-textdecoy f20-multiline; do
  out="$(MPO "$POSTURE_DIR/$fx.mo")"; rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then _ok "F20 payload $fx: no posture, non-zero (fails closed)"
  else _fail "F20 payload $fx: rc=$rc output='$out' — a non-canonical real #dev beside a decoy must refuse, never read as '${out:-play}'"; fi
done
F20_ERR=$(bash -c '. scripts/lib/targets.sh && mdx_posture_of "$1"' _ "$POSTURE_DIR/f20-twospace.mo" 2>&1 >/dev/null || true)
src_has "the F20 refusal names both counts (canonical vs any spelling)" "$F20_ERR" "in any spelling"
# A lone non-canonical spelling with NO decoy is refused too: the wasm is
# built from it and the gate cannot read it, so it must not pass as safe.
printf '  transient let DEPLOY_MODE  : DeployMode = #play;\n' > "$POSTURE_DIR/f20-lonely.mo"
if MPO "$POSTURE_DIR/f20-lonely.mo" >/dev/null; then _fail "a lone non-canonical spelling must refuse (unreadable is not safe)"; else _ok "a lone non-canonical spelling refuses"; fi
# Adjacent: decoys that are now STRIPPED no longer hide a canonical
# declaration — the reader resolves it instead of refusing on a phantom count.
printf '  let s = "see // the docs"; transient let DEPLOY_MODE : DeployMode = #dev;\n' > "$POSTURE_DIR/ok-strslash.mo"
assert_eq "a // inside a preceding string literal does not hide the declaration" "dev" "$(MPO "$POSTURE_DIR/ok-strslash.mo")"
printf '  let doc = "transient let DEPLOY_MODE : DeployMode = #play;";\n  transient let DEPLOY_MODE : DeployMode = #dev;\n' > "$POSTURE_DIR/ok-textdecoy.mo"
assert_eq "a Text-literal decoy is stripped; the real declaration wins" "dev" "$(MPO "$POSTURE_DIR/ok-textdecoy.mo")"
printf '  /* transient let DEPLOY_MODE : DeployMode = #play; */\n  transient let DEPLOY_MODE : DeployMode = #dev;\n' > "$POSTURE_DIR/ok-block.mo"
assert_eq "a block-comment decoy is stripped; the real declaration wins" "dev" "$(MPO "$POSTURE_DIR/ok-block.mo")"
printf '  /* outer /* nested */ transient let DEPLOY_MODE : DeployMode = #play; */\n  transient let DEPLOY_MODE : DeployMode = #dev;\n' > "$POSTURE_DIR/ok-nested.mo"
assert_eq "a NESTED block-comment decoy is stripped too" "dev" "$(MPO "$POSTURE_DIR/ok-nested.mo")"
printf '  let c = %s; transient let DEPLOY_MODE : DeployMode = #dev; // "\n' "'\"'" > "$POSTURE_DIR/ok-charquote.mo"
assert_eq "a char literal holding a quote does not open a string" "dev" "$(MPO "$POSTURE_DIR/ok-charquote.mo")"
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
for m in cancelMyOrder cancelAllMyOrders closePosition withdrawMarginPool unstakeInsurance withdrawLp withdraw cancelPoolOrder repayPoolDebt cancelStagedLpRequest; do
  src_has "exit set exempts $m" "$INSPECT_FN" "#$m _"
done
src_has "non-exit updates still shed by rank" "$INSPECT_FN" 'levelRank(levelOfKey(key)) >= _shedFloor'
# #55 ("exits still say refused"): the exit set is ONE list, EXIT_METHOD_SET,
# read by both inspect (via isExitMethod) and whyAmIRefused (exitMethods +
# exitsAdmitted). The compiler forces literal tags in inspect's switch, so
# the switch can only ROUTE candidate tags to names — this pin is what makes
# the routing arms and the list one set: derive both structurally and
# require set equality in both directions, so neither can grow alone.
# (#51.2-class: discovered, not hand-listed — a hand copy of the eight here
# would be the very second list the fix removes.)
# The list is TRANSIENT by name (task 1788523828): its predecessor EXIT_METHODS
# was a plain `let` — implicitly stable — so the literal an upgrade shipped
# never replaced the first-installed eight on a live venue; the fossil stays
# (no stable drops) and must stay UNREAD.
EXIT_LIST_DECL=$(mo_code < src/backend/main.mo | sed -n '/transient let EXIT_METHOD_SET : \[Text\] = \[/,/\];/p')
grep_count EXIT_FOSSIL_READS "$(mo_code < src/backend/main.mo)" '\bEXIT_METHODS\b'
if [ "${EXIT_FOSSIL_READS:-0}" -eq 1 ]; then _ok "§6c/1788523828: the stable fossil EXIT_METHODS is declared once and read nowhere (the live list is transient EXIT_METHOD_SET)"
else _fail "§6c/1788523828: EXIT_METHODS occurs $EXIT_FOSSIL_READS times outside comments — the stable fossil must be declared exactly once and never read (a read sees the FIRST-installed list on every upgraded venue, the W5-12 shape); read EXIT_METHOD_SET"; fi
EXIT_LIST=$(printf '%s\n' "$EXIT_LIST_DECL" | grep -oE '"[A-Za-z0-9_]+"' | tr -d '"' | sort -u)
# (H-30 put a SECOND routing switch in inspect — the pre-registration set —
# so each extraction anchors on its own `let <x>Candidate : ?Text = switch (msg)`
# line; a bare `switch (msg)` range would union the two sets.)
EXIT_ARMS=$(printf '%s\n' "$INSPECT_FN" | mo_code | sed -n '/let exitCandidate : ?Text = switch (msg)/,/case _/p' | grep -oE '#[A-Za-z0-9_]+' | tr -d '#' | sort -u)
EXIT_ROUTED=$(printf '%s\n' "$INSPECT_FN" | mo_code | sed -n '/let exitCandidate : ?Text = switch (msg)/,/case _/p' | grep -oE '\?"[A-Za-z0-9_]+"' | tr -d '?"' | sort -u)
if [ -z "$EXIT_LIST" ]; then _fail "§6c/#55: could not read EXIT_METHOD_SET out of main.mo — the parser needs updating, the tie is inert"
elif [ "$(printf '%s\n' $EXIT_LIST | grep -c .)" -lt 9 ]; then _fail "§6c/#55: EXIT_METHOD_SET names fewer than the nine exits (W1-05 seven + cancelPoolOrder + repayPoolDebt)"
else _ok "§6c/#55: EXIT_METHOD_SET read ($(printf '%s\n' $EXIT_LIST | grep -c .) methods)"; fi
if [ -z "$EXIT_ARMS" ]; then _fail "§6c/#55: could not read the routing arms out of inspect's switch (msg)"
elif [ "$EXIT_ARMS" = "$EXIT_LIST" ]; then _ok "§6c/#55: inspect's routing arms and EXIT_METHOD_SET enumerate the same set"
else _fail "§6c/#55: inspect's arms {$(echo $EXIT_ARMS)} != EXIT_METHOD_SET {$(echo $EXIT_LIST)} — the gate and the diagnostic would disagree (the #55 finding); change both together"; fi
if [ "$EXIT_ROUTED" = "$EXIT_ARMS" ]; then _ok "§6c/#55: every routing arm names its own tag (tag→name spelling matches)"
else _fail "§6c/#55: routing arms route to {$(echo $EXIT_ROUTED)} but match tags {$(echo $EXIT_ARMS)} — a misspelt name silently drops that exit from the exemption"; fi
src_has "inspect defers the exit verdict to isExitMethod" "$INSPECT_FN" "isExitMethod(name)"
src_has "inspect reads the shared caller policy" "$INSPECT_FN" "callerAdmitted(caller, registered)"
WHY_FN=$(mo_func src/backend/main.mo "func whyAmIRefused(")
[ -n "$WHY_FN" ] || _fail "could not extract whyAmIRefused() — the extractor needs updating"
src_has "whyAmIRefused reports the exit set from EXIT_METHOD_SET" "$WHY_FN" "exitMethods    = EXIT_METHOD_SET"
src_has "whyAmIRefused derives exitsAdmitted from the shared caller policy" "$WHY_FN" "callerAdmitted(msg.caller, registered)"

# ── 6d. H-30: unknown principals reach THE PRE-REGISTRATION SET only ────
# inspect used to admit any unregistered keypair to every update outside
# production (64 permanent pool records per keypair, an armable dead-man
# switch per throwaway — F37/F43). The admitted surface is now ONE list,
# PRE_REGISTRATION_METHOD_SET (+ DEV_PRE_REGISTRATION_METHOD_SET on #dev: the
# faucet is the dev registration path), routed by a second msg switch in
# inspect and reported by whyAmIRefused — the same tie as §6c, both
# directions, so neither the arms nor the list can grow alone. The set is
# the frontend's pre-deposit surface (main.js: getMyProfile / regenerateUsername
# / get+setUserPreferences / the two II legs) — a method added here must be
# something a signed-in, never-deposited user legitimately calls.
# Both lists are TRANSIENT by name (task 1788533845): their predecessors
# PRE_REGISTRATION_METHODS / DEV_PRE_REGISTRATION_METHODS were plain `let`s —
# implicitly stable — so on every venue that took H-30 as an upgrade the gate
# kept H-30's FIRST-installed list whatever a later build shipped (rehearsed
# live: an upgrade adding a name left whyAmIRefused on the old seven). The
# fossils stay declared (no stable drops, no class flips — IC0503) and must
# stay UNREAD: declared once, read nowhere, exactly §6c's pin on EXIT_METHODS.
src_has "inspect carries the PRE-REGISTRATION SET rationale" "$INSPECT_FN" "THE PRE-REGISTRATION SET"
src_has "inspect refuses unknown principals through the shared caller policy before routing" "$INSPECT_FN" "if (not callerAdmitted(caller, registered)) {"
src_has "inspect consults the shared pre-registration policy" "$INSPECT_FN" "preRegistrationAdmitted(caller, registered)"
src_has "inspect defers the pre-registration verdict to isPreRegistrationMethod" "$INSPECT_FN" "isPreRegistrationMethod(name)"
src_lacks "inspect no longer admits unknown principals wholesale" "$(printf '%s\n' "$INSPECT_FN" | mo_code)" "not IS_PRODUCTION"
for fossil in PRE_REGISTRATION_METHODS DEV_PRE_REGISTRATION_METHODS; do
  grep_count PRE_FOSSIL_READS "$(mo_code < src/backend/main.mo)" "\\b$fossil\\b"
  if [ "${PRE_FOSSIL_READS:-0}" -eq 1 ]; then _ok "§6d/1788533845: the stable fossil $fossil is declared once and read nowhere (the live list is transient ${fossil%S}_SET)"
  else _fail "§6d/1788533845: $fossil occurs $PRE_FOSSIL_READS times outside comments — the stable fossil must be declared exactly once and never read (a read sees H-30's FIRST-installed list on every upgraded venue, the W5-12 shape); read ${fossil%S}_SET"; fi
  src_has "§6d/1788533845: the stable fossil $fossil is parked empty and marked" "$(grep -E "^  let $fossil : \[Text\] = " src/backend/main.mo)" "let $fossil : [Text] = []; // STABLE-FOSSIL"
done
# (awk, not a sed range: a one-line `let X : [Text] = ["…"];` starts AND ends
# on the same line, and a sed range only tests the end pattern from the NEXT
# line on — it would run to some unrelated `];` and pull in foreign names.
# Anchored on `transient let` so a stable fossil can never satisfy the read.)
mo_list_decl() { mo_code < src/backend/main.mo | awk -v n="transient let $1 : [Text] = [" 'index($0, n) { f = 1 } f { print } f && /\];/ { exit }'; }
PRE_LIST_DECL=$(mo_list_decl PRE_REGISTRATION_METHOD_SET)
DEV_PRE_LIST_DECL=$(mo_list_decl DEV_PRE_REGISTRATION_METHOD_SET)
[ -n "$PRE_LIST_DECL" ] && _ok "§6d/1788533845: PRE_REGISTRATION_METHOD_SET is a transient let (the literal is what every upgrade installs)" || _fail "§6d/1788533845: could not read 'transient let PRE_REGISTRATION_METHOD_SET : [Text] = [' out of main.mo — a plain let would be stable and the upgrade would keep the first-installed list"
[ -n "$DEV_PRE_LIST_DECL" ] && _ok "§6d/1788533845: DEV_PRE_REGISTRATION_METHOD_SET is a transient let" || _fail "§6d/1788533845: could not read 'transient let DEV_PRE_REGISTRATION_METHOD_SET : [Text] = [' out of main.mo"
PRE_LIST=$(printf '%s\n' "$PRE_LIST_DECL" "$DEV_PRE_LIST_DECL" | grep -oE '"[A-Za-z0-9_]+"' | tr -d '"' | sort -u)
PRE_ARMS=$(printf '%s\n' "$INSPECT_FN" | mo_code | sed -n '/let preRegCandidate : ?Text = switch (msg)/,/case _/p' | grep -oE '#[A-Za-z0-9_]+' | tr -d '#' | sort -u)
PRE_ROUTED=$(printf '%s\n' "$INSPECT_FN" | mo_code | sed -n '/let preRegCandidate : ?Text = switch (msg)/,/case _/p' | grep -oE '\?"[A-Za-z0-9_]+"' | tr -d '?"' | sort -u)
for m in getMyProfile setUserPreferences getUserPreferences regenerateUsername _internet_identity_sign_in_start _internet_identity_sign_in_finish; do
  case " $(echo $PRE_LIST) " in *" $m "*) _ok "§6d/H-30: pre-registration set names $m" ;; *) _fail "§6d/H-30: PRE_REGISTRATION_METHOD_SET lost $m — the frontend calls it before the first deposit (main.js)" ;; esac
done
case " $(echo $PRE_LIST) " in *" addTestTokens "*) _ok "§6d/H-30: the #dev faucet is in the dev pre-registration list (it is the dev registration path)" ;; *) _fail "§6d/H-30: DEV_PRE_REGISTRATION_METHOD_SET lost addTestTokens — no identity could register on #dev" ;; esac
if [ -z "$PRE_ARMS" ]; then _fail "§6d/H-30: could not read the pre-registration routing arms out of inspect (let preRegCandidate … switch (msg))"
elif [ "$PRE_ARMS" = "$PRE_LIST" ]; then _ok "§6d/H-30: inspect's pre-registration arms and the two lists enumerate the same set ($(printf '%s\n' $PRE_LIST | grep -c .) methods)"
else _fail "§6d/H-30: inspect's pre-registration arms {$(echo $PRE_ARMS)} != PRE_REGISTRATION_METHOD_SET ∪ DEV {$(echo $PRE_LIST)} — the gate and the diagnostic would disagree; change both together"; fi
if [ "$PRE_ROUTED" = "$PRE_ARMS" ]; then _ok "§6d/H-30: every pre-registration arm names its own tag"
else _fail "§6d/H-30: pre-registration arms route to {$(echo $PRE_ROUTED)} but match tags {$(echo $PRE_ARMS)} — a misspelt name silently drops that method from the set"; fi
# The two routing switches must not share members: an exit is never a
# pre-registration method (an unregistered principal has nothing to exit).
PRE_EXIT_OVERLAP=$(comm -12 <(printf '%s\n' $PRE_ARMS) <(printf '%s\n' $EXIT_ARMS) | tr '\n' ' ')
[ -z "$(echo $PRE_EXIT_OVERLAP)" ] && _ok "§6d/H-30: the pre-registration set and the exit set are disjoint" || _fail "§6d/H-30: {$PRE_EXIT_OVERLAP} sit in BOTH the exit set and the pre-registration set"
src_has "whyAmIRefused reports the pre-registration set from the shared lists" "$WHY_FN" "preRegistrationMethods  = effectivePreRegistrationMethods()"
src_has "whyAmIRefused derives preRegistrationAdmitted from the shared policy" "$WHY_FN" "preRegistrationAdmitted(msg.caller, registered)"
# The posture half (operator decision 2026-09-05, task 1788499950): the
# pre-registration set is admitted to unknown principals on EVERY posture —
# onboarding between II sign-in and the first deposit is a production
# requirement, and H-36's bounded store is what makes that safe. The verdict
# lives in lib/PreReg.admitted, posture-parameterised so PreReg.test.mo pins
# all three postures and a fourth cannot compile undecided; main.mo's
# preRegistrationAdmitted only feeds it the live DEPLOY_MODE. Neither the
# gate nor the diagnostic reads IS_PRODUCTION any more — the production
# interlocks that REMAIN are body-level (custody: fundArbitrageur,
# extMarketSwap, seedInsurance, resetExchange, the withdraw interlock) and
# the registration guard (requireRegistered, posture-independent, above).
PRA_FN=$(mo_func src/backend/main.mo "func preRegistrationAdmitted(")
[ -n "$PRA_FN" ] || _fail "§6d/1788499950: could not extract preRegistrationAdmitted()"
src_lacks "§6d/1788499950: preRegistrationAdmitted carries no posture arm (production admits the pre-registration set)" "$(printf '%s\n' "$PRA_FN" | mo_code)" "IS_PRODUCTION"
src_has   "§6d/1788499950: preRegistrationAdmitted is the lib verdict under the live posture" "$(printf '%s\n' "$PRA_FN" | mo_code)" "PreReg.admitted(DEPLOY_MODE, Principal.isAnonymous(caller), registered)"
src_lacks "§6d/1788499950: inspect reads no posture" "$(printf '%s\n' "$INSPECT_FN" | mo_code)" "IS_PRODUCTION"
src_lacks "§6d/1788499950: whyAmIRefused reads no posture" "$(printf '%s\n' "$WHY_FN" | mo_code)" "IS_PRODUCTION"
PREREG_ADMIT_FN=$(mo_func src/backend/lib/PreReg.mo "public func admitted(")
[ -n "$PREREG_ADMIT_FN" ] || _fail "§6d/1788499950: could not extract PreReg.admitted()"
src_has "§6d/1788499950: PreReg.admitted admits an unknown principal on every posture (exhaustive switch — a new posture must decide)" "$(printf '%s\n' "$PREREG_ADMIT_FN" | mo_code)" "case (#dev or #play or #production) { true }"
src_has "§6d/1788499950: PreReg.admitted refuses anonymous first" "$(printf '%s\n' "$PREREG_ADMIT_FN" | mo_code)" "if (anonymous) { return false };"
for needle in 'fundArbitrageur is disabled on #production' 'extMarketSwap is disabled on #production' 'seedInsurance is not available on #production' 'resetExchange is not available on #production'; do
  src_has "§6d/1788499950: the body-level production interlock survives — $needle" "$(mo_code < src/backend/main.mo)" "$needle"
done
# The genesis-window half (operator decision 2026-09-06, task 1788529484 —
# F29-backend, the second half of H-17): setTestBalance and fundArbitrageur
# are RATIFIED live-on-#play bootstrap tools (an absolute SET, controller-
# only, extNetFlow-recorded; the fleet refill and play_start's per-market
# base legs need them after the first enableAmm), and bulkSetTestBalances —
# which no #play path calls (scripts/seed.sh is the #dev seeder) — is BOUND
# to the _ammEverEnabled window like injectHistoricalTrades and the repeat
# seedInsuranceFund. The verdict lives in lib/Genesis.bulkSeedWindowClosed,
# posture-parameterised so tests/Genesis.test.mo pins all three postures and
# a fourth cannot compile undecided; the mixin reads the latch through a
# READER (a Bool argument would freeze the include-time value). Pinned here:
# the predicate's arms, the mixin's call + refusal shape (mirroring
# seedInsuranceFund's: names the window, names the sanctioned path, "only a
# reinstall re-arms"), that the two ratified tools carry NO latch, the
# include wiring, the decision text in getApiDoc + deployment-modes, and —
# the reason (c) is safe — that scripts/seed.sh is the ONLY script calling
# bulkSetTestBalances.
GEN_FN=$(mo_func src/backend/lib/Genesis.mo "public func bulkSeedWindowClosed(")
[ -n "$GEN_FN" ] || _fail "§6d/1788529484: could not extract Genesis.bulkSeedWindowClosed()"
GEN_CODE="$(printf '%s\n' "$GEN_FN" | mo_code)"
src_has "§6d/1788529484: Genesis.bulkSeedWindowClosed — #dev never closes (seed.sh re-funds after enableAmm)" "$GEN_CODE" 'case (#dev) { false };'
src_has "§6d/1788529484: Genesis.bulkSeedWindowClosed — #play closes on the latch"                          "$GEN_CODE" 'case (#play) { ammEverEnabled };'
src_has "§6d/1788529484: Genesis.bulkSeedWindowClosed — #production always closed (exhaustive switch)"      "$GEN_CODE" 'case (#production) { true };'
BULK_FN=$(mo_func src/backend/mixins/AdminOps.mo "func bulkSetTestBalances(")
[ -n "$BULK_FN" ] || _fail "§6d/1788529484: could not extract bulkSetTestBalances()"
BULK_CODE="$(printf '%s\n' "$BULK_FN" | mo_code)"
src_has "§6d/1788529484: bulkSetTestBalances asks the lib verdict under the live posture and the latch READER" "$BULK_CODE" 'if (Genesis.bulkSeedWindowClosed(posture, genesisLatched())) {'
src_has "§6d/1788529484: bulkSetTestBalances' refusal names the genesis window (seedInsuranceFund's shape)"   "$BULK_CODE" 'bulkSetTestBalances: genesis window closed'
src_has "§6d/1788529484: bulkSetTestBalances' refusal names the sanctioned live path (setTestBalance)"       "$BULK_CODE" 'Fund accounts one at a time via setTestBalance'
src_has "§6d/1788529484: bulkSetTestBalances' refusal says only a reinstall re-arms (seedInsuranceFund's shape)" "$BULK_CODE" 'Only a reinstall (a new venue) re-arms the window.'
src_has "§6d/1788529484: bulkSetTestBalances keeps its #production trap first"                               "$BULK_CODE" 'bulkSetTestBalances is not available on #production'
BULK_PROD_LN=$(printf '%s\n' "$BULK_CODE" | grep -n 'bulkSetTestBalances is not available on #production' | head -1 | cut -d: -f1)
BULK_CTRL_LN=$(printf '%s\n' "$BULK_CODE" | grep -n 'requireMinter(msg.caller, "bulkSetTestBalances");' | head -1 | cut -d: -f1)   # the caller gate: controller OR the funding authority since 1789609263 (§6be)
BULK_GEN_LN=$(printf '%s\n' "$BULK_CODE" | grep -n 'Genesis.bulkSeedWindowClosed(' | head -1 | cut -d: -f1)
if [ -n "${BULK_PROD_LN:-}" ] && [ -n "${BULK_CTRL_LN:-}" ] && [ -n "${BULK_GEN_LN:-}" ] && [ "$BULK_PROD_LN" -lt "$BULK_CTRL_LN" ] && [ "$BULK_CTRL_LN" -lt "$BULK_GEN_LN" ]; then _ok "§6d/1788529484: bulkSetTestBalances gates posture → controller → genesis window, in that order (prod=$BULK_PROD_LN ctrl=$BULK_CTRL_LN genesis=$BULK_GEN_LN)"
else _fail "§6d/1788529484: bulkSetTestBalances must gate posture, then controller, then the genesis window — a non-controller must get the controller refusal, never a latch oracle (prod=${BULK_PROD_LN:-none} ctrl=${BULK_CTRL_LN:-none} genesis=${BULK_GEN_LN:-none})"; fi
# The refusal text mirrors seedInsuranceFund's SHAPE: both name the window and
# the reinstall re-arm; the two sanctioned-path sentences differ on purpose.
SEED_INS_CODE_6D="$(mo_func src/backend/main.mo "func seedInsuranceFund(" | mo_code)"
[ -n "$SEED_INS_CODE_6D" ] || _fail "§6d/1788529484: could not extract seedInsuranceFund()"
src_has "§6d/1788529484: seedInsuranceFund's refusal carries the same re-arm sentence (the shape bulkSetTestBalances mirrors)" "$SEED_INS_CODE_6D" 'Only a reinstall (a new venue) re-arms the window.'
# The two RATIFIED tools carry no latch — the decision's (a) half.
SET_FN=$(mo_func src/backend/mixins/AdminOps.mo "func setTestBalance(")
[ -n "$SET_FN" ] || _fail "§6d/1788529484: could not extract setTestBalance()"
src_lacks "§6d/1788529484: setTestBalance is ratified live on #play — reads no genesis latch"        "$(printf '%s\n' "$SET_FN" | mo_code)" 'genesisLatched'
src_lacks "§6d/1788529484: setTestBalance is ratified live on #play — asks no Genesis verdict"     "$(printf '%s\n' "$SET_FN" | mo_code)" 'Genesis.'
src_has   "§6d/1788529484: setTestBalance keeps its #production trap"                              "$(printf '%s\n' "$SET_FN" | mo_code)" 'setTestBalance is not available on #production'
FUND_ARB_FN=$(mo_func src/backend/main.mo "func fundArbitrageur(")
[ -n "$FUND_ARB_FN" ] || _fail "§6d/1788529484: could not extract fundArbitrageur()"
src_lacks "§6d/1788529484: fundArbitrageur is ratified live on #play — reads no genesis latch"      "$(printf '%s\n' "$FUND_ARB_FN" | mo_code)" '_ammEverEnabled'
src_lacks "§6d/1788529484: fundArbitrageur is ratified live on #play — asks no Genesis verdict"    "$(printf '%s\n' "$FUND_ARB_FN" | mo_code)" 'Genesis.'
# The wiring: the actor hands the mixin its live posture and a latch reader.
src_has "§6d/1788529484: the AdminOps include passes DEPLOY_MODE and the latch reader" "$(mo_code < src/backend/main.mo)" 'include AdminOps(accounts, registeredUsers, isFundingAuthority, IS_PRODUCTION, recordExternalFlow, preRegPromote, DEPLOY_MODE, genesisLatched);'
src_has "§6d/1788529484: genesisLatched reads the live _ammEverEnabled latch"           "$(mo_code < src/backend/main.mo)" 'func genesisLatched() : Bool { _ammEverEnabled };'
# The decision is recorded where bot authors and operators read.
src_has "§6d/1788529484: getApiDoc records the F29-backend DECISION"                    "$(mo_code < src/backend/main.mo)" 'DECISION (F29-backend, 1788529484, 2026-09-06): the controller BOOTSTRAP mints on #play.'
src_has "§6d/1788529484: getApiDoc names bulkSetTestBalances as genesis-bound"           "$(mo_code < src/backend/main.mo)" 'bulkSetTestBalances is instead BOUND to the genesis window'
src_has "§6d/1788529484: deployment-modes records the DECISION under \"The genesis window\"" "$(cat docs/deployment-modes.md)" 'DECISION (F29-backend, `1788529484`, 2026-09-06)'
src_has "§6d/1788529484: deployment-modes kill-matrix row marks bulkSetTestBalances genesis-only on play" "$(cat docs/deployment-modes.md)" '| `bulkSetTestBalances` (AdminOps, controller-only, batched seed mint) | ✅ | ⏳ genesis only | ❌ |'
# Why (c) is safe: scripts/seed.sh (the #dev seeder, cold_start non-play
# modes only) is the ONLY script that calls bulkSetTestBalances — the #play
# bring-up (play_start.sh), deploy.sh's seed/bots, the fleets and the history
# injector all fund per account through setTestBalance. Computed over every
# script, comments stripped, so a NEW #play caller trips this pin.
# (grep WITHOUT -q: under pipefail an early-exiting grep SIGPIPEs sed and the
# match reads as a failure — the set came back empty on 2026-09-06.)
BULK_CALLERS=$(for f in scripts/*.sh scripts/lib/*.sh; do if sed 's/[[:space:]]#.*$//; /^[[:space:]]*#/d' "$f" | grep 'bulkSetTestBalances' >/dev/null; then printf '%s\n' "$f"; fi; done | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$BULK_CALLERS" = "scripts/seed.sh" ]; then _ok "§6d/1788529484: scripts/seed.sh is the only script calling bulkSetTestBalances (no #play path — the latch breaks no bring-up)"
else _fail "§6d/1788529484: bulkSetTestBalances is called from {$BULK_CALLERS} — expected exactly scripts/seed.sh; a #play-path caller would trip the genesis latch after the first enableAmm (fund per account via setTestBalance instead)"; fi
for f in scripts/play_start.sh scripts/deploy.sh scripts/sim_trading.sh scripts/trading_simulation.sh scripts/inject_history.sh; do
  src_lacks "§6d/1788529484: $f (a #play path) never calls bulkSetTestBalances" "$(sed 's/[[:space:]]#.*$//; /^[[:space:]]*#/d' "$f")" 'bulkSetTestBalances'
done
src_has "§6d/1788529484: cold_start routes play mode to play_start.sh, not seed.sh" "$(sed '/^[[:space:]]*#/d' scripts/cold_start.sh)" 'if [ "$MODE" = "play" ]; then'
# The body-level half: the shared registration guard sits in the three
# methods the finding named (inter-canister callers bypass inspect).
for fn in createMarginPool cancelAllAfter aiComplete; do
  FN_BODY=$(mo_func src/backend/main.mo "func $fn(")
  [ -n "$FN_BODY" ] || { _fail "§6d/H-30: could not extract $fn()"; continue; }
  src_has "§6d/H-30: $fn requires registration in its body (requireRegistered)" "$(printf '%s\n' "$FN_BODY" | mo_code)" "requireRegistered(msg.caller)"
done
RR_FN=$(mo_func src/backend/main.mo "func requireRegistered(")
[ -n "$RR_FN" ] || _fail "§6d/H-30: could not extract requireRegistered()"
src_has "§6d/H-30: requireRegistered reads registeredUsers" "$RR_FN" "Map.get(registeredUsers, Text.compare, Principal.toText(caller)) == null"
# F43's other half: the dead-man sweep is capped per pass, mirroring the
# expiry finaliser, and fires without a version bump for a principal that
# held nothing.
DM_FN=$(mo_func src/backend/main.mo "func tickDeadman(")
[ -n "$DM_FN" ] || _fail "§6d/H-30: could not extract tickDeadman()"
src_has "§6d/H-30: tickDeadman caps fires per pass" "$(printf '%s\n' "$DM_FN" | mo_code)" "if (List.size(due) >= cap) { break collect };"
src_has "§6d/H-30: tickDeadman skips the version bump when nothing was cancelled" "$(printf '%s\n' "$DM_FN" | mo_code)" "if (n > 0) { bumpUserVersion(p) };"
src_has "§6d/H-30: DEADMAN_MAX_FIRES_PER_PASS exists beside its expiry sibling" "$(mo_code < src/backend/main.mo)" "transient let DEADMAN_MAX_FIRES_PER_PASS : Nat = "
# F37's other half: the five per-user pool reads resolve through the owner
# index, and the heat/risk scans skip registry-only pools before counting.
for fn in myMarginPoolsOf myPositionFillsOf myPoolLiquidationsOf; do
  FN_BODY=$(mo_func src/backend/main.mo "func $fn(")
  [ -n "$FN_BODY" ] || { _fail "§6d/H-30: could not extract $fn()"; continue; }
  src_has  "§6d/H-30: $fn reads the owner index" "$(printf '%s\n' "$FN_BODY" | mo_code)" "ownedPoolIds(caller)"
  src_lacks "§6d/H-30: $fn does not walk marginPools" "$(printf '%s\n' "$FN_BODY" | mo_code)" "Map.entries(marginPools)"
done
AP_FN=$(mo_func src/backend/main.mo "func archiveReadPrincipals(")
[ -n "$AP_FN" ] || _fail "§6d/H-30: could not extract archiveReadPrincipals() (H-29's per-segment principal set)"
src_has "§6d/H-30: archiveReadPrincipals (getMyArchivedEvents + archiveExecute, current chain) is the owner-index read" "$(printf '%s\n' "$AP_FN" | mo_code)" "case null { selfAndOwnedPools(caller) };"
src_lacks "§6d/H-30: archiveReadPrincipals does not walk marginPools" "$(printf '%s\n' "$AP_FN" | mo_code)" "marginPools"
# Security-review L3's third scan (task 1788513124) indexed getMyPendingMatches'
# read. apiVersion 6.0.0 (task 1788731608) REMOVED that query with the rest of
# the PendingMatch surface, and the owner-index fixture went with its last
# reader — pmIdsByUser, recordPendingMatchIndex, myPendingMatchesOf,
# devSweepCostProbe's seven pending fields, tests/test_pending_owner_index.sh.
# The fossil map keeps no index because nothing reads it. Pins: the fixture is
# GONE, the probe carries no pending measurement, the retired suite is not in
# the tree (§6az holds the fossil declarations and the Candid side).
MAIN_L3=$(mo_code < src/backend/main.mo)
for FN in myPendingMatchesOf getMyPendingMatches recordPendingMatchIndex; do
  src_lacks "§6d/L3 (6.0.0): main.mo no longer defines $FN" "$MAIN_L3" "func $FN("
done
src_lacks "§6d/L3 (6.0.0): the pending owner index pmIdsByUser is gone" "$MAIN_L3" "pmIdsByUser"
src_lacks "§6d/L3 (6.0.0): ...and PENDING_PROBE_SYNTH with it" "$MAIN_L3" "PENDING_PROBE_SYNTH"
PROBE_FN=$(mo_func src/backend/main.mo "func devSweepCostProbe(")
[ -n "$PROBE_FN" ] || _fail "§6d/L3: could not extract devSweepCostProbe()"
src_lacks "§6d/L3 (6.0.0): devSweepCostProbe carries no pending measurement" "$(printf '%s\n' "$PROBE_FN" | mo_code)" "pendingMyRead"
if [ -f tests/test_pending_owner_index.sh ]; then _fail "§6d/L3 (6.0.0): tests/test_pending_owner_index.sh must stay retired with the query it pinned"
else _ok "§6d/L3 (6.0.0): test_pending_owner_index.sh is retired"; fi
for fn in computeMarketHeatmap computeRiskSummary tickMarketSideAgg refreshVaultImpairment; do
  FN_BODY=$(mo_func src/backend/main.mo "func $fn(")
  [ -n "$FN_BODY" ] || { _fail "§6d/H-30: could not extract $fn()"; continue; }
  src_has "§6d/H-30: $fn skips empty pools before the HEAT_MAX_POOLS count" "$(printf '%s\n' "$FN_BODY" | mo_code)" "continue scan"
  src_has "§6d/H-30: $fn uses poolIsEmpty" "$(printf '%s\n' "$FN_BODY" | mo_code)" "poolIsEmpty("
done

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
for t in reap drain tier heat leader arrears ttlsweep candles deadman ammsnap; do
  src_has "heartbeat isolates '$t' via hbRun" "$HB_FN2" "hbRun(\"$t\""
done
# H-09 (D7, extension of W3-08): the two bare self-sends that stayed outside
# the breaker — the finaliser (dispatched via the async variant, it must
# send) and the AMM tick (dispatched PER MARKET as "amm:<marketId>") — and
# no bare `ignore tickAmm()` / `ignore finaliseExpiredPending()` remains.
src_has "heartbeat isolates the finaliser via hbRunAsync" "$HB_FN2" 'hbRunAsync("finalise"'
src_has "heartbeat dispatches the AMM tick per market"    "$HB_FN2" '"amm:" # id'
src_lacks "no bare finaliser self-send remains"           "$HB_FN2" "ignore finaliseExpiredPending()"
src_lacks "no bare AMM-tick self-send remains"            "$HB_FN2" "ignore tickAmm()"
src_has "hbRunAsync awaits an async* computation inline (one message)" "$(mo_code < src/backend/main.mo | grep -A4 'func hbRunAsync')" "await* task()"
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
# happened to decline. Pin arb < DEX so they cannot silently diverge again —
# STRICT (#55): the arb floors capBase at the mark it read, the DEX re-prices
# the leg at ITS current mark with a ceiling, so an EQUAL cap loses a tick to
# "Exceeds per-call cap" on every uptick between the two reads.
ARB_CAP=$(mo_code < src/arb/main.mo | grep -oE 'TRADE_CAP_USD : Nat = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
DEX_CAP=$(mo_code < src/backend/main.mo | grep -oE 'ARB_MAX_SWAP_USD    : Nat = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
if [ -n "$ARB_CAP" ] && [ -n "$DEX_CAP" ] && [ "$ARB_CAP" -lt "$DEX_CAP" ]; then
  _ok "arb TRADE_CAP_USD ($ARB_CAP) < DEX ARB_MAX_SWAP_USD ($DEX_CAP)"
else
  _fail "arb clip must sit strictly under the DEX per-call cap — arb=$ARB_CAP dex=$DEX_CAP"
fi
# #55: and the headroom must cover the largest oracle step the DEX applies
# WITHOUT its jump gate (PRICE_JUMP_BPS; bigger moves pend, and extMarketSwap
# refuses while one pends). Exports carry only a floor bound, so a whole
# applied step reaches the cap check: arb·(1 + jump) must still clear the DEX
# cap or a cap-sized flatten refuses on every such tick.
JUMP_BPS=$(mo_code < src/backend/main.mo | grep -oE 'PRICE_JUMP_BPS : Float = [0-9]+' | grep -oE '[0-9]+$')
if [ -n "$JUMP_BPS" ] && [ -n "$ARB_CAP" ] && [ -n "$DEX_CAP" ] \
   && [ $((ARB_CAP * (10000 + JUMP_BPS))) -lt $((DEX_CAP * 10000)) ]; then
  _ok "arb clip headroom clears one applied oracle step (${JUMP_BPS} bps): $ARB_CAP × (1 + ${JUMP_BPS}/10000) < $DEX_CAP"
else
  _fail "arb clip headroom under the DEX cap must exceed PRICE_JUMP_BPS — arb=$ARB_CAP dex=$DEX_CAP jump=${JUMP_BPS:-?}bps"
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
# Timing-dependent behaviours (a wipe racing a parked refresh; an install that
# throws or traps mid-spawn — #55 (d): an upgrade cannot land inside the
# install await, so that is not one of them) cannot be staged
# deterministically from a test — pin the structures.
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
# H-37 (F34): the refresh-in-flight flag W4-13 gave one owner no longer
# exists — `refreshInFlight` is DERIVED from the open fan-outs, so there is
# no writer to latch (a trap between set and clear used to disable the
# periodic refresh until the next upgrade). Pin: no writer, one reader.
W413_FLAG=$(printf '%s\n' "$MAIN_MO_CODE" | grep -cF "_priceRefreshInFlight" || true)
if [ "${W413_FLAG:-0}" = "0" ]; then
  _ok "no refresh-in-flight flag remains (nothing to latch — W4-13's one-owner rule, made structural by H-37)"
else
  _fail "_priceRefreshInFlight is back ($W413_FLAG sites) — refreshInFlight derives from the fan-out map (H-37); a bare flag re-opens the W4-13 latch"
fi
src_has "refreshInFlight derives from the open fan-outs" "$MAIN_MO_CODE" "func priceRefreshInFlight() : Bool {"

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
# The RETURN SHAPE is what gets tested, through one shared predicate per
# shape: mdx_reply_ok for `async Result` methods (fundArbitrageur), and
# mdx_reply_nat for `async Nat` ones (seedInsuranceFund answers a bare
# `(N : nat)` — #55, round 18: W5-22 gated it on the variant it never
# returns, so every SUCCESSFUL engine seed printed "Insurance fund seed
# failed", and this section REQUIRED that wrong gate). The ok-form is now
# banned for that call; the nat-form is required. Both predicates are the
# shared copy in scripts/lib/reply.sh (task 1788503030; deploy.sh's own
# mdx_call_ok / mdx_call_nat were the third private copy).
DEPLOY_SH_W522="$(uncommented scripts/deploy.sh)"
LIB_REPLY_W522="$(uncommented scripts/lib/reply.sh)"
src_has "the variant predicate exists (mdx_reply_ok, lib/reply.sh)"   "$LIB_REPLY_W522" "mdx_reply_ok() {"
src_has "the bare-nat predicate exists (mdx_reply_nat, lib/reply.sh)" "$LIB_REPLY_W522" "mdx_reply_nat() {"
src_has "deploy.sh sources the lib the predicates live in"            "$DEPLOY_SH_W522" '/lib/reply.sh"'
src_has "fundArbitrageur gates on the VARIANT"            "$DEPLOY_SH_W522" 'if mdx_reply_ok "$fund_out"; then'
src_has "seedInsuranceFund gates on the returned NAT (#55)" "$DEPLOY_SH_W522" 'if mdx_reply_nat "$seed_ins_out"; then'
src_lacks "seedInsuranceFund no longer gates on a variant it never returns" "$DEPLOY_SH_W522" 'mdx_reply_ok "$seed_ins_out"'
if grep_has "$DEPLOY_SH_W522" 'if icp canister call backend (fundArbitrageur|seedInsuranceFund)'; then
  _fail "an exit-status-tested fund/seed call came back (W5-22 regression)"
else _ok "no exit-status-tested fund/seed calls remain"; fi
# Drive the REAL predicates offline: #ok passes and a bare nat passes — each
# through ITS OWN predicate; #err, a bare nat under the variant predicate,
# a variant under the nat predicate, traps, and CLI errors all refuse. The
# fallbacks below FAIL by construction, so a lib the probe could not source
# (moved, renamed) reads as a wrong verdict, never as a silent pass.
W522_TMP="$(mktemp -d "${TMPDIR:-/tmp}/w522.XXXXXX")"
cat > "$W522_TMP/probe.sh" <<'W522EOF'
mdx_reply_ok()  { return 1; }
mdx_reply_nat() { return 1; }
. "$1" 2>/dev/null || true    # the REAL definitions: scripts/lib/reply.sh
mdx_reply_ok "(variant { ok = 5 : nat })" || exit 1
mdx_reply_ok "( variant { ok })" || exit 2
mdx_reply_ok "(variant { err = \"fundArbitrageur is not available on #production\" })" && exit 3
mdx_reply_ok "Error: call failed" && exit 4
# The bare-nat shape, exactly as `icp canister call backend seedInsuranceFund`
# prints it ($144k pool in e8, underscore-grouped) — the fixture this section
# lacked while it required the wrong gate.
SEED_NAT="(14_400_000_000_000 : nat)"
mdx_reply_nat "$SEED_NAT" || exit 5
mdx_reply_nat "( 300_000_000_000 : nat )" || exit 6
mdx_reply_ok  "$SEED_NAT" && exit 7                    # the #55 bug: the ok-form refuses a successful seed
mdx_reply_nat "(variant { ok = 5 : nat })" && exit 8   # a nat INSIDE a variant is not the bare shape
mdx_reply_nat "Error: The replica returned a rejection error: reject message: seedInsurance is not available on #production" && exit 9
mdx_reply_nat "Error: call failed" && exit 10
mdx_reply_nat "" && exit 11
exit 0
W522EOF
if bash "$W522_TMP/probe.sh" scripts/lib/reply.sh; then _ok "mdx_reply_ok/mdx_reply_nat: #ok and bare nat pass their own gate; #err, cross-shape, traps and CLI errors refuse (real definitions driven)"
else _fail "mdx_reply_ok/mdx_reply_nat verdict wrong (exit $?)"; fi
rm -rf "$W522_TMP"
# And the canister side of #55: a re-run of the seed (the manual retry the
# false "failed" invited) must not mint a SECOND unbacked pool — a pool that
# already holds value is already seeded; the call logs and returns it.
# Live pin: tests/test_insurance_fund.sh (re-seed leaves the buffer at $3k).
SEED_INS_FN=$(mo_func src/backend/main.mo "func seedInsuranceFund(")
[ -n "$SEED_INS_FN" ] || _fail "could not extract seedInsuranceFund()"
src_has "seedInsuranceFund refuses to double-mint a seeded pool (#55)" "$(printf '%s\n' "$SEED_INS_FN" | mo_code)" 'INSURANCE SEED: skipped'
src_has "seedInsuranceFund's guard reads the LIVE pool value, not the share supply" "$(printf '%s\n' "$SEED_INS_FN" | mo_code)" 'let existing = insurancePoolValue();'
# H-17 (F29-backend): the #55 skip answered the EXISTING value as a bare nat,
# which is exactly the shape deploy.sh's gate reads as "seeded" — so a
# repeated genesis seed on a live venue still looked like a success. On
# #play the repeat is bound to the injectHistoricalTrades genesis window
# (_ammEverEnabled): a seed into a pool that already holds value REFUSES
# loudly (a trap — the signature has no Result channel), naming the window
# and the BACKED top-up path. The refusal must precede the #55 skip, or the
# skip answers first and the trap is dead code. Live pin:
# tests/test_audit_2026_08_fixes.sh (posture branch).
SEED_INS_CODE="$(printf '%s\n' "$SEED_INS_FN" | mo_code)"
src_has "seedInsuranceFund binds the repeat seed to the genesis latch (H-17)" "$SEED_INS_CODE" '_ammEverEnabled'
src_has "seedInsuranceFund's post-genesis refusal names the genesis window (H-17)" "$SEED_INS_CODE" 'seedInsuranceFund: genesis window closed'
src_has "seedInsuranceFund's post-genesis refusal is scoped to #play (H-17)" "$SEED_INS_CODE" 'DEPLOY_MODE == #play'
H17_TRAP_LN=$(printf '%s\n' "$SEED_INS_CODE" | grep -n 'seedInsuranceFund: genesis window closed' | head -1 | cut -d: -f1)
H17_SKIP_LN=$(printf '%s\n' "$SEED_INS_CODE" | grep -n 'INSURANCE SEED: skipped' | head -1 | cut -d: -f1)
if [ -n "${H17_TRAP_LN:-}" ] && [ -n "${H17_SKIP_LN:-}" ] && [ "$H17_TRAP_LN" -lt "$H17_SKIP_LN" ]; then _ok "seedInsuranceFund's genesis refusal precedes the #55 skip (trap=$H17_TRAP_LN skip=$H17_SKIP_LN)"
else _fail "seedInsuranceFund's genesis refusal must PRECEDE the #55 skip, or the skip answers first and the refusal is dead code (trap=${H17_TRAP_LN:-none} skip=${H17_SKIP_LN:-none})"; fi

# ── H-35 (F42, D3 (a)): the insurance UNSTAKE COOLDOWN ──────────────────
# A stake entered one message before a predictable solvent liquidation (the
# 30 s HB_LIQ_NS sweep) and exited one message after it skimmed A/(V+A) of
# the penalty from the long-term stakers. D3 chose a cooldown over an exit
# fee (breaks the redeem(mint(A)) == A and quote == payout pins) and over an
# accrual index (largest change). The pins below are the shape the live
# suite (tests/test_insurance_staking.sh §5) cannot see: that the constant is
# TRANSIENT (W5-12), that the stamp map is STABLE (a transient map would
# forget every lock across an upgrade — an upgrade would be the skim's exit
# window), that the cooldown exceeds the sweep cadence, that the stamp dies
# with the holding and with the world wipe, and that the hook is dev-gated.
H35_MAIN="$(mo_code < src/backend/main.mo)"
src_has "H-35: INSURANCE_UNSTAKE_COOLDOWN_NS is a transient let (the literal is what every upgrade installs)" "$H35_MAIN" 'transient let INSURANCE_UNSTAKE_COOLDOWN_NS : Int = '
src_has "H-35: insuranceStakedAt is a STABLE map (plain let — locks survive an upgrade)" "$(grep -E '^  let insuranceStakedAt +=' src/backend/main.mo)" 'let insuranceStakedAt'
grep_scan H35_STAKED_DECL "$(cat src/backend/main.mo)" 'insuranceStakedAt += Map.empty'
src_lacks "H-35: insuranceStakedAt is not transient (an upgrade must not unlock every stake)" "$H35_STAKED_DECL" 'transient'
H35_COOL=$(printf '%s\n' "$H35_MAIN" | grep -oE 'transient let INSURANCE_UNSTAKE_COOLDOWN_NS : Int = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
H35_HBLIQ=$(printf '%s\n' "$H35_MAIN" | grep -oE 'transient let HB_LIQ_NS +: Int = [0-9_]+' | grep -oE '[0-9_]+$' | tr -d '_')
if [ -n "${H35_COOL:-}" ] && [ -n "${H35_HBLIQ:-}" ] && [ "$H35_COOL" -gt "$H35_HBLIQ" ]; then _ok "H-35: the cooldown ($((H35_COOL / 1000000000)) s) exceeds one liquidation cycle (HB_LIQ_NS = $((H35_HBLIQ / 1000000000)) s)"
else _fail "H-35: INSURANCE_UNSTAKE_COOLDOWN_NS (${H35_COOL:-unreadable}) must exceed HB_LIQ_NS (${H35_HBLIQ:-unreadable}) — a cooldown shorter than the sweep cadence does not close the skim"; fi
H35_STAKE_FN="$(mo_func src/backend/main.mo "func stakeInsurance(" | mo_code)"
H35_UNSTAKE_FN="$(mo_func src/backend/main.mo "func unstakeInsurance(" | mo_code)"
H35_QUERY_FN="$(mo_func src/backend/main.mo "func getMyInsuranceStake(" | mo_code)"
H35_SUB_FN="$(mo_func src/backend/main.mo "func subInsuranceShares(" | mo_code)"
H35_HOOK_FN="$(mo_func src/backend/main.mo "func setTestInsuranceStakedAt(" | mo_code)"
[ -n "$H35_STAKE_FN" ] && [ -n "$H35_UNSTAKE_FN" ] && [ -n "$H35_QUERY_FN" ] && [ -n "$H35_SUB_FN" ] && [ -n "$H35_HOOK_FN" ] || _fail "H-35: could not extract one of stakeInsurance / unstakeInsurance / getMyInsuranceStake / subInsuranceShares / setTestInsuranceStakedAt"
src_has "H-35: stakeInsurance stamps the caller's latest-stake time (a top-up restarts the clock)" "$H35_STAKE_FN" 'Map.add(insuranceStakedAt, Text.compare, Principal.toText(msg.caller), Time.now());'
src_has "H-35: unstakeInsurance gates on the shared unlock instant" "$H35_UNSTAKE_FN" 'let unlockAt = insuranceUnlockAtNs(msg.caller);'
src_has "H-35: unstakeInsurance's refusal names the unlock instant" "$H35_UNSTAKE_FN" 'Insurance stake is locked until'
H35_LOCK_LN=$(printf '%s\n' "$H35_UNSTAKE_FN" | grep -n 'Insurance stake is locked until' | head -1 | cut -d: -f1)
H35_PAY_LN=$(printf '%s\n' "$H35_UNSTAKE_FN" | grep -n 'let payout = insuranceRedeemValue(shares);' | head -1 | cut -d: -f1)
if [ -n "${H35_LOCK_LN:-}" ] && [ -n "${H35_PAY_LN:-}" ] && [ "$H35_LOCK_LN" -lt "$H35_PAY_LN" ]; then _ok "H-35: the cooldown refusal precedes the payout (lock=$H35_LOCK_LN payout=$H35_PAY_LN)"
else _fail "H-35: the cooldown refusal must PRECEDE the payout in unstakeInsurance (lock=${H35_LOCK_LN:-none} payout=${H35_PAY_LN:-none})"; fi
src_has "H-35: getMyInsuranceStake quotes the same unlock instant the refusal names" "$H35_QUERY_FN" 'unlockAtNs = insuranceUnlockAtNs(msg.caller)'
src_has "H-35: a holding that falls to zero deletes its stamp (the stamp map stays a subset of the share map)" "$H35_SUB_FN" 'ignore Map.delete(insuranceStakedAt, Text.compare, Principal.toText(user));'
src_has "H-35: the world wipe clears the stamps with the holdings" "$H35_MAIN" 'Map.clear(insuranceStakedAt);'
src_has "H-35: the re-stamp hook is dev-gated" "$H35_HOOK_FN" 'requireDevHook("setTestInsuranceStakedAt")'
src_has "H-35: the re-stamp hook is controller-only" "$H35_HOOK_FN" 'requireController(msg.caller);'
src_has "H-35: the re-stamp hook never stamps a non-holder" "$H35_HOOK_FN" 'if (getInsuranceShares(user) > 0) {'
# (H-35's additive field bumped the minor within major 5; the major later
# moved to 6 for the sealed LP doors + the PendingMatch removal — task
# 1788731608, §6ba — never for this field. The pin now holds the current
# major so it cannot regress through a stray downgrade.)
src_has "H-35: the additive query field never took a major of its own (the current major is 6.0.0's, task 1788731608)" "$H35_MAIN" 'transient let MM_API_VERSION : Text = "6.'

# ── H-36 (F33, D4 (a′)): the HARD-CAPPED, self-expiring pre-registration store ──
# getMyProfile / setUserPreferences write permanent records before the first
# deposit by design (the frontend's sign-in path), so free keypairs bought
# stable-heap growth at ingress rate. D4's answer: bounded BY CONSTRUCTION
# (write-time cap, LRU-evict unregistered), autonomous expiry on the heartbeat
# (MULTI/DEX is NNS-run — no property may depend on an operator tool), promotion
# on registration. The live suite (tests/test_h36_prereg_bound.sh) measures the
# bound; these pins are the shape it cannot see: the constants are TRANSIENT
# (W5-12), the store is STABLE (a transient index would forget every slot on
# upgrade and orphan the records it bounds), every drop re-checks registration
# (a registered user is never deleted), every registration site promotes, every
# pre-registration WRITE touches, the heartbeat step sits BEHIND the pause gate
# and inside the breaker, the hooks are dev-gated, and the II sign-in handshake
# state is bounded by the pinned mo:identity-attributes version itself.
H36_MAIN="$(mo_code < src/backend/main.mo)"
H36_UA="$(mo_code < src/backend/mixins/UserAccount.mo)"
H36_AO="$(mo_code < src/backend/mixins/AdminOps.mo)"
src_has "H-36: PREREG_CAP is a transient let (the literal is what every upgrade installs)" "$H36_MAIN" 'transient let PREREG_CAP : Nat = '
src_has "H-36: PREREG_GRACE_NS is a transient let" "$H36_MAIN" 'transient let PREREG_GRACE_NS : Int = '
src_has "H-36: PREREG_STEP_BUDGET is a transient let (the per-tick pop budget)" "$H36_MAIN" 'transient let PREREG_STEP_BUDGET : Nat = '
src_has "H-36: preRegStore is a STABLE record (plain let — slots survive an upgrade with the records they bound)" "$(grep -E '^  let preRegStore = PreReg.empty\(\);' src/backend/main.mo)" 'let preRegStore = PreReg.empty();'
grep_scan H36_STORE_DECL "$(cat src/backend/main.mo)" 'preRegStore = PreReg.empty'
src_lacks "H-36: preRegStore is not transient" "$H36_STORE_DECL" 'transient'
H36_CAP=$(printf '%s\n' "$H36_MAIN" | grep -oE 'transient let PREREG_CAP : Nat = [0-9_]+' | tr -d '_' | grep -oE '[0-9]+$')
if [ -n "${H36_CAP:-}" ] && [ "$H36_CAP" -ge 1000 ] && [ "$H36_CAP" -le 100000 ]; then _ok "H-36: PREREG_CAP = $H36_CAP sits in the sane band [1,000, 100,000] (≈0.5 KB/entry → ≤ 50 MB peak)"
else _fail "H-36: PREREG_CAP (${H36_CAP:-unreadable}) outside [1,000, 100,000] — too small evicts real pre-deposit users under normal load, too large is not a bound"; fi
H36_DROP_FN=$(mo_func src/backend/main.mo "func preRegDrop(")
H36_TOUCH_FN=$(mo_func src/backend/main.mo "func preRegTouch(")
H36_TICK_FN=$(mo_func src/backend/main.mo "func tickPreReg(")
H36_HB_FN=$(mo_func src/backend/main.mo "system func heartbeat()")
H36_BOUNDS_FN=$(mo_func src/backend/main.mo "func setTestPreRegBounds(")
H36_FLOOD_FN=$(mo_func src/backend/main.mo "func devSeedPreRegFlood(")
[ -n "$H36_DROP_FN" ] && [ -n "$H36_TOUCH_FN" ] && [ -n "$H36_TICK_FN" ] && [ -n "$H36_HB_FN" ] && [ -n "$H36_BOUNDS_FN" ] && [ -n "$H36_FLOOD_FN" ] || _fail "H-36: could not extract one of preRegDrop / preRegTouch / tickPreReg / heartbeat / setTestPreRegBounds / devSeedPreRegFlood"
src_has "H-36: a drop re-checks registration first — a registered principal is a promotion, never a deletion" "$H36_DROP_FN" 'if (isRegisteredKey(key)) { preRegStore.promoted += 1; return };'
src_has "H-36: a drop removes the profile with the slot" "$H36_DROP_FN" 'ignore Map.delete(userProfiles, Text.compare, key);'
src_has "H-36: a drop removes the preferences with the slot" "$H36_DROP_FN" 'ignore Map.delete(userPreferences, Text.compare, key);'
src_has "H-36: a registered caller's touch lifts it out instead of stamping it" "$H36_TOUCH_FN" 'if (isRegisteredKey(key)) { ignore PreReg.forget(preRegStore, key); return };'
src_has "H-36: touch evicts through the cap in force" "$H36_TOUCH_FN" 'PreReg.touch(preRegStore, key, Time.now(), preRegCap())'
src_has "H-36: the tick expires at the per-tick budget (bounded pops, no scan)" "$H36_TICK_FN" 'PreReg.expire(preRegStore, now, preRegGraceNs(), PREREG_STEP_BUDGET)'
src_has "H-36: the tick re-converges on a lowered cap" "$H36_TICK_FN" 'PreReg.trim(preRegStore, preRegCap(), PREREG_STEP_BUDGET)'
src_has "H-36: residue adoption is sharded (Shard.step over userProfiles)" "$H36_TICK_FN" 'Shard.step<Types.UserProfile>(userProfiles, _preRegAdoptCursor, PREREG_ADOPT_SHARD, adopt)'
src_has "H-36: residue adoption covers userPreferences too" "$H36_TICK_FN" 'Shard.step<Types.UserPreferences>(userPreferences, _preRegAdoptCursor, PREREG_ADOPT_SHARD, adopt)'
src_has "H-36: the expiry step is a breaker-isolated heartbeat subtask ('prereg')" "$H36_HB_FN" 'ignore hbRun("prereg", func() { tickPreReg(now) })'
H36_GATE_LN=$(printf '%s\n' "$H36_HB_FN" | mo_code | grep -n 'if (timersHeld()) { return };' | head -1 | cut -d: -f1)
H36_PREREG_LN=$(printf '%s\n' "$H36_HB_FN" | mo_code | grep -n 'hbRun("prereg"' | head -1 | cut -d: -f1)
if [ -n "${H36_GATE_LN:-}" ] && [ -n "${H36_PREREG_LN:-}" ] && [ "$H36_GATE_LN" -lt "$H36_PREREG_LN" ]; then _ok "H-36: the 'prereg' dispatch sits BELOW the pause gate (gate=$H36_GATE_LN prereg=$H36_PREREG_LN) — maintenance, not a safety contract"
else _fail "H-36: the 'prereg' dispatch must follow the pause gate in heartbeat (gate=${H36_GATE_LN:-none} prereg=${H36_PREREG_LN:-none})"; fi
H36_TICK_CALLERS=$(printf '%s\n' "$H36_MAIN" | grep -n 'tickPreReg(')
grep_filter H36_TICK_CALLERS 'func tickPreReg\(|hbRun\("prereg"'
src_lacks "H-36: no operator entry point runs the purge — the only callers of tickPreReg are the heartbeat and the #dev bounds hook (NNS-run doctrine)" "$H36_TICK_CALLERS" 'tickPreReg('
# Every pre-registration WRITE touches BEFORE it writes; every registration
# site promotes right after it registers.
for fn in getMyProfile regenerateUsername setUserPreferences; do
  FN=$(mo_func src/backend/mixins/UserAccount.mo "func $fn(")
  [ -n "$FN" ] || { _fail "H-36: could not extract $fn() from UserAccount.mo"; continue; }
  src_has "H-36: $fn touches the pre-registration store" "$FN" 'preRegTouch(msg.caller);'
done
H36_UA_SET=$(mo_func src/backend/mixins/UserAccount.mo "func setUserPreferences(")
H36_T_LN=$(printf '%s\n' "$H36_UA_SET" | mo_code | grep -n 'preRegTouch(msg.caller);' | head -1 | cut -d: -f1)
H36_W_LN=$(printf '%s\n' "$H36_UA_SET" | mo_code | grep -n 'Map.add(userPreferences, Text.compare, key, prefs);' | head -1 | cut -d: -f1)
if [ -n "${H36_T_LN:-}" ] && [ -n "${H36_W_LN:-}" ] && [ "$H36_T_LN" -lt "$H36_W_LN" ]; then _ok "H-36: setUserPreferences touches BEFORE it writes (touch=$H36_T_LN write=$H36_W_LN) — the caller takes the newest slot, never its own eviction"
else _fail "H-36: setUserPreferences must touch before Map.add (touch=${H36_T_LN:-none} write=${H36_W_LN:-none})"; fi
H36_REG_MISSING=""
for f in src/backend/main.mo src/backend/mixins/UserAccount.mo src/backend/mixins/AdminOps.mo; do
  # each `Map.add(registeredUsers, …)` must be followed within 2 code lines by a promotion
  MISS=$(mo_code < "$f" | awk -v f="$f" '/Map\.add\(registeredUsers, Text\.compare/ { pend = NR; next } pend && NR <= pend + 2 && /preRegPromote\(|onRegistered\(/ { pend = 0 } pend && NR > pend + 2 { print f ":" pend; pend = 0 } END { if (pend) print f ":" pend }')
  [ -n "$MISS" ] && H36_REG_MISSING="$H36_REG_MISSING $MISS"
done
H36_REG_SITES=$(cat src/backend/main.mo src/backend/mixins/UserAccount.mo src/backend/mixins/AdminOps.mo | mo_code | grep -c 'Map.add(registeredUsers, Text.compare' || true)
if [ "${H36_REG_SITES:-0}" -ge 4 ] && [ -z "$H36_REG_MISSING" ]; then _ok "H-36: every registration site ($H36_REG_SITES) promotes within two lines of the registeredUsers write"
else _fail "H-36: registration site(s) without a promotion:${H36_REG_MISSING:- (found only ${H36_REG_SITES:-0} sites)} — a registered user left in the bounded store can be evicted"; fi
src_has "H-36: AdminOps receives the promotion hook" "$H36_AO" 'onRegistered      : Principal -> (),'
src_has "H-36: the bounds hook is dev-gated" "$H36_BOUNDS_FN" 'requireDevHook("setTestPreRegBounds")'
src_has "H-36: the bounds hook is controller-only" "$H36_BOUNDS_FN" 'requireController(msg.caller);'
src_has "H-36: the flood seeder is dev-gated" "$H36_FLOOD_FN" 'requireDevHook("devSeedPreRegFlood")'
src_has "H-36: the flood seeder is controller-only" "$H36_FLOOD_FN" 'requireController(msg.caller);'
src_has "H-36: the flood seeder inserts through the LIVE primitive (preRegTouch), not a shortcut" "$H36_FLOOD_FN" 'preRegTouch(p);'
src_has "H-36: getPreRegStoreStats is an open query (the bound is a public measurement)" "$H36_MAIN" 'public query func getPreRegStoreStats() : async {'
src_has "H-36: getApiDoc tells bot authors the pre-registration state is bounded" "$H36_MAIN" 'PRE-REGISTRATION STATE IS BOUNDED'
# The II sign-in HANDSHAKE (nonce) state: bounded inside the pinned package —
# maxTotal + expiry pruning + transient. Pin the version; verify the constants
# when the package source is installed (a stripped checkout has no .mops).
src_has "H-36: mo:identity-attributes is pinned to the version whose nonce store is capped" "$(grep -E '^identity-attributes = ' mops.toml)" 'identity-attributes = "0.4.1"'
H36_CH=".mops/identity-attributes@0.4.1/src/Internal/Challenges.mo"
if [ -f "$H36_CH" ]; then
  src_has "H-36: the II nonce store has a hard cap (Challenges.maxTotal = 4096)" "$(cat "$H36_CH")" 'public let maxTotal : Nat = 4096;'
  src_has "H-36: the II nonce store prunes expired entries on every issue/consume" "$(cat "$H36_CH")" 'pruneExpired(store, nowNs);'
  src_has "H-36: the II nonce store evicts at the cap" "$(cat "$H36_CH")" 'if (Map.size(store) >= maxTotal) {'
else
  echo "  · H-36: $H36_CH not installed (mops install) — the nonce-store constants are not re-verified in this run"
fi

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
# H-32 factored the send-and-ack slice of the tick into shipBatchTo (so the
# backlog-scaled burst can send several per tick); the trip lives there now
# and every batch — ordinary or burst — passes through it.
SHIP_BATCH_FN=$(mo_func src/backend/main.mo "func shipBatchTo(")
[ -n "$SHIP_BATCH_FN" ] || _fail "could not extract shipBatchTo()"
src_has   "divergence trip tests the full queue span"      "$SHIP_BATCH_FN" 'if (nextExpected > shippedSeq + m)'
src_has   "divergent ack bumps the tripwire counter"       "$SHIP_BATCH_FN" '_ackDivergences += 1'
src_has   "divergent ack counts toward the L1 roll"        "$SHIP_BATCH_FN" 'divergent ack REFUSED'
src_lacks "the old silent clamp-and-advance is gone"       "$SHIP_BATCH_FN$TICK_SHIP_FN" 'if (drop > m) { drop := m }'
RESET_SEASON_FN=$(mo_func src/backend/main.mo "func resetSeason(")
[ -n "$RESET_SEASON_FN" ] || _fail "could not extract resetSeason()"
src_has   "resetSeason guards the cursor subtraction"      "$RESET_SEASON_FN" 'if (shippedSeq > nextEventSeq)'

# ── 6o'. The SeasonRecord snapshots THIS season's chain, in ORDER (#54.4,
# 3088465055) ── `archives = allArchivePrincipals()` spanned the season
# REGISTRY (season N's record listed seasons 1..N). currentArchivePrincipals
# reads the current chain (sealed + tip, never the successor) and is correct
# ONLY because the record is built BEFORE performWorldWipe(true) detaches
# that chain into the registry — the order is the invariant, so pin the line
# numbers, not just the call. And the detach must not register the
# pre-spawned successor (#55 "empty successor": a 0-growing row refilled
# forever) — tickShipEvents adopts it as the next epoch's archive instead.
src_has   "resetSeason snapshots currentArchivePrincipals (this season only)" "$RESET_SEASON_FN" 'archives      = currentArchivePrincipals();'
src_lacks "resetSeason no longer snapshots allArchivePrincipals (the registry)" "$RESET_SEASON_FN" 'archives      = allArchivePrincipals()'
RS_SNAP_LN=$(printf '%s\n' "$RESET_SEASON_FN" | grep -n 'archives      = currentArchivePrincipals();' | head -1 | cut -d: -f1)
RS_WIPE_LN=$(printf '%s\n' "$RESET_SEASON_FN" | grep -n 'await\* performWorldWipe(true);' | head -1 | cut -d: -f1)
if [ -n "$RS_SNAP_LN" ] && [ -n "$RS_WIPE_LN" ] && [ "$RS_SNAP_LN" -lt "$RS_WIPE_LN" ]; then _ok "resetSeason builds the record (line $RS_SNAP_LN) BEFORE the season detach (line $RS_WIPE_LN)"
else _fail "resetSeason's archive snapshot (${RS_SNAP_LN:-none}) does not precede performWorldWipe(true) (${RS_WIPE_LN:-none}) — the record would read the registry-emptied chain"; fi
CUR_ARCH_FN=$(mo_func src/backend/main.mo "func currentArchivePrincipals(")
[ -n "$CUR_ARCH_FN" ] || _fail "could not extract currentArchivePrincipals()"
src_lacks "currentArchivePrincipals excludes the pre-spawned successor" "$CUR_ARCH_FN" '_archiveNext'
src_lacks "currentArchivePrincipals excludes the season registry"      "$CUR_ARCH_FN" '_seasonArchives'
WORLD_WIPE_FN=$(mo_func src/backend/main.mo "func performWorldWipe(")
[ -n "$WORLD_WIPE_FN" ] || _fail "could not extract performWorldWipe()"
src_lacks "the season detach does not register the empty successor" "$WORLD_WIPE_FN" 'firstSeq = 0; lastSeq = null; season = seasonNo'
src_has   "tickShipEvents adopts the carried successor as the new epoch's archive" "$TICK_SHIP_FN" 'case (null, ?next) {'

# ── 6o''. The EMPTY tip is the successor's twin (1788511319) ── the seal+swap
# installs the pre-spawned successor as archive0 anchored at shippedSeq, and
# until the next batch ships it has chained nothing. A tip sealed on the LAST
# drain before resetSeason therefore meets the boundary EMPTY — and both the
# record (currentArchivePrincipals) and the detach (performWorldWipe) treated
# it as a season segment: 3 canisters "sealed at event seq 305", the third
# registered { firstSeq 305; lastSeq null } with a null certified head — the
# #55 "0 – growing" row under another name, reproduced deterministically on
# a seat venue 2026-09-04 (test_season_record_archives.sh §6 is the twin).
# The rule is one predicate — shippedSeq <= _activeFirstSeq — applied by BOTH
# readers: the record omits the tip, the detach carries it as _archiveNext
# (never registers it), and tickShipEvents' (null, ?next) arm adopts it at
# the new epoch's seq 0 exactly like a pre-spawned successor. NOT the
# reconstructed in-window shape: the heartbeat returns under timersHeld()
# (the sealing latch), so nothing ships inside the Bridge await; the badge
# burst is ring-log only, post-wipe. The two suites that park the active
# count in the spawn window pin the cap far above it between grow() and
# resetSeason so the closing drain cannot seal (§6 owns that case).
src_has   "§6o'': the empty-tip predicate exists (shippedSeq <= _activeFirstSeq)" "$(uncommented src/backend/main.mo)" 'func activeTipEmpty() : Bool { shippedSeq <= _activeFirstSeq };'
src_has   "§6o'': currentArchivePrincipals omits an EMPTY tip"                     "$CUR_ARCH_FN" 'if (not activeTipEmpty()) { List.add(out, p) }'
src_has   "§6o'': the season detach carries an EMPTY tip as the successor"          "$WORLD_WIPE_FN" 'if (tipEmptyAtBoundary and _archiveNext == null) {'
# The predicate is read BEFORE the wipe's cursor reset: performWorldWipe sets
# shippedSeq := 0 well before the season detach, so evaluating it AT the
# detach reads 0 <= anchor — every tip "empty", every tip carried, no season
# ever registers its tip (test_season_seal §3 went red on exactly that build:
# the record named the tip, getSeasonArchives routed nothing). No await sits
# between the read and the detach (the season arm awaits nothing).
src_has   "§6o'': the detach reads the predicate into a local"                      "$WORLD_WIPE_FN" 'let tipEmptyAtBoundary = activeTipEmpty();'
src_lacks "§6o'': the detach never evaluates the predicate live (post-reset)"       "$WORLD_WIPE_FN" 'if (activeTipEmpty()'
WW_READ_LN=$(printf '%s\n' "$WORLD_WIPE_FN" | grep -n 'let tipEmptyAtBoundary = activeTipEmpty();' | head -1 | cut -d: -f1)
WW_ZERO_LN=$(printf '%s\n' "$WORLD_WIPE_FN" | grep -n '^    shippedSeq := 0;' | head -1 | cut -d: -f1)
WW_AWAIT_LN=$(printf '%s\n' "$WORLD_WIPE_FN" | mo_code | grep -n 'await ' | head -1 | cut -d: -f1)
WW_DETACH_LN=$(printf '%s\n' "$WORLD_WIPE_FN" | grep -n 'if (tipEmptyAtBoundary and _archiveNext == null) {' | head -1 | cut -d: -f1)
if [ -n "$WW_READ_LN" ] && [ -n "$WW_ZERO_LN" ] && [ "$WW_READ_LN" -lt "$WW_ZERO_LN" ]; then _ok "§6o'': the predicate is read (line $WW_READ_LN) BEFORE shippedSeq := 0 (line $WW_ZERO_LN)"
else _fail "§6o'': the empty-tip read (${WW_READ_LN:-none}) does not precede the cursor reset (${WW_ZERO_LN:-none}) — every tip would read empty"; fi
if [ -n "$WW_DETACH_LN" ] && { [ -z "$WW_AWAIT_LN" ] || [ "$WW_DETACH_LN" -lt "$WW_AWAIT_LN" ]; }; then _ok "§6o'': no await separates the read from the season detach (detach line $WW_DETACH_LN, first await ${WW_AWAIT_LN:-none})"
else _fail "§6o'': an await (line ${WW_AWAIT_LN:-?}) precedes the season detach (line ${WW_DETACH_LN:-?}) — a ship could move the cursor between the read and its use"; fi
src_has   "§6o'': ...by installing it as _archiveNext"                              "$WORLD_WIPE_FN" '_archiveNext := ?p;   // carried: the new epoch'"'"'s first archive'
src_lacks "§6o'': the season detach no longer registers the tip unconditionally"    "$WORLD_WIPE_FN" 'case (?p) { List.add(_seasonArchives, { canisterId = p; firstSeq = _activeFirstSeq; lastSeq = null; season = seasonNo }) };'
src_has   "§6o'': the non-empty tip is still registered as the season's open row"   "$WORLD_WIPE_FN" 'List.add(_seasonArchives, { canisterId = p; firstSeq = _activeFirstSeq; lastSeq = null; season = seasonNo });'
if [ "$(uncommented tests/test_season_record_archives.sh | grep -c "setTestArchiveCap '(opt (100_000 : nat))'")" -ge 2 ]; then _ok "§6o'': test_season_record_archives pins the cap above the count before its §2 and §4 closes"
else _fail "§6o'': test_season_record_archives.sh must pin setTestArchiveCap '(opt (100_000 : nat))' between grow() and resetSeason in §1 AND §4 — the closing drain can seal the tip on a venue with enough users"; fi
src_has   "§6o'': test_season_record_archives exercises the empty-tip boundary (§6)" "$(cat tests/test_season_record_archives.sh)" 'the empty tip is NOT a season $SC row'
src_has   "§6o'': test_retire_empty_season_segment pins the cap before its close"    "$(uncommented tests/test_retire_empty_season_segment.sh)" "setTestArchiveCap '(opt (100_000 : nat))'"

# ── 6o'''. The join-badge backfill is QUIET (3088514069) ── performWorldWipe
# clears `badges` but never `registeredUsers`, so the first tier tick after a
# season reset re-grants the join badge to every registered principal at once
# (the whole set fits one TIER_BADGE_SHARD_SIZE slice). One per-user ring-log
# line each — 167 consecutive lines observed live on a 167-user seat venue
# 2026-09-04 — buried the `Season N closed` line and resetSeason's honest-seal
# error line, and past EVENT_LOG_CAP users the burst would EVICT them within a
# minute of the close. The backfill lambda now grants through the silent
# idempotent primitive (grantBadge) and emits ONE summary line per tick in the
# same access/badge category; the per-user line stays on the inline
# first-deposit path (creditAndRegister -> awardBadge). The `badges` map ends
# identical either way.
# LIFETIME join badge (1788515790, operator decision (a)): the wipe KEEPS the
# join badge — it rides with `registeredUsers`, which neither wipe arm clears —
# so it never disappears / re-appears across a season and the backfill finds
# nothing to do after a reset. performWorldWipe harvests every user's join
# stamp BEFORE `Map.clear(badges)` and re-grants it AFTER with the ORIGINAL
# awardedNs (grantBadge's `now` argument is the stamp), so no badge is awarded
# twice; the other badges restart with the scorecards.
TICK_TIER_FN=$(mo_func src/backend/main.mo "func tickTier(")
AWARD_BADGE_FN=$(mo_func src/backend/main.mo "func awardBadge(")
GRANT_BADGE_FN=$(mo_func src/backend/main.mo "func grantBadge(")
if [ -n "$TICK_TIER_FN" ] && [ -n "$AWARD_BADGE_FN" ] && [ -n "$GRANT_BADGE_FN" ]; then _ok "§6o''': tickTier / awardBadge / grantBadge bodies extracted"
else _fail "§6o''': could not extract tickTier, awardBadge or grantBadge from main.mo"; fi
src_has   "§6o''': the silent grant primitive reports newness"                          "$GRANT_BADGE_FN" 'if (Map.get(m, Nat.compare, id) != null) { return false };'
src_lacks "§6o''': the silent grant primitive never logs"                               "$GRANT_BADGE_FN" 'logEventF('
src_has   "§6o''': awardBadge logs the per-user line only on a NEW grant"               "$AWARD_BADGE_FN" 'if (grantBadge(k, id, now)) {'
src_has   "§6o''': ...with the per-user text intact"                                    "$AWARD_BADGE_FN" '"badge awarded: " # badgeName(id)'
src_lacks "§6o''': the backfill lambda no longer calls the per-user logger directly"    "$TICK_TIER_FN" 'awardBadge(k, BADGE_JOIN, now)'
src_has   "§6o''': the backfill lambda grants silently and counts"                      "$TICK_TIER_FN" 'if (grantBadge(k, BADGE_JOIN, now)) { joinBackfilled += 1 };'
src_has   "§6o''': ...and emits ONE summary line per tick, in the access/badge category" "$TICK_TIER_FN" 'logEventF("info", "access", ?"badge", null, "join-badge backfill: " # Nat.toText(joinBackfilled) # " awarded", null);'
src_has   "§6o''': the inline first-deposit path keeps the per-user line"               "$(mo_code < src/backend/main.mo)" 'awardBadge(Principal.toText(user), BADGE_JOIN, Time.now());'
JOIN_WIPE_FN=$(mo_func src/backend/main.mo "func performWorldWipe(" | mo_code)
[ -n "$JOIN_WIPE_FN" ] || _fail "§6o''': could not extract performWorldWipe()"
src_has   "§6o''': the wipe harvests every join stamp before clearing badges"           "$JOIN_WIPE_FN" 'case (?ts) { List.add(joinStamps, (k, ts)) };'
src_has   "§6o''': ...still clears the badge map (the other badges restart)"            "$JOIN_WIPE_FN" 'Map.clear(badges);'
src_has   "§6o''': ...and re-grants the join badge with its ORIGINAL awardedNs"         "$JOIN_WIPE_FN" 'for ((k, ts) in List.values(joinStamps)) { ignore grantBadge(k, BADGE_JOIN, ts) };'
src_lacks "§6o''': the wipe never clears registeredUsers (the fact the join badge mirrors)" "$JOIN_WIPE_FN" 'Map.clear(registeredUsers)'
JOIN_HARVEST_LN=$(printf '%s\n' "$JOIN_WIPE_FN" | grep -nF 'List.add(joinStamps, (k, ts))' | head -1 | cut -d: -f1)
JOIN_CLEAR_LN=$(printf '%s\n' "$JOIN_WIPE_FN" | grep -nF 'Map.clear(badges);' | head -1 | cut -d: -f1)
JOIN_REGRANT_LN=$(printf '%s\n' "$JOIN_WIPE_FN" | grep -nF 'ignore grantBadge(k, BADGE_JOIN, ts)' | head -1 | cut -d: -f1)
if [ -n "$JOIN_HARVEST_LN" ] && [ -n "$JOIN_CLEAR_LN" ] && [ -n "$JOIN_REGRANT_LN" ] && [ "$JOIN_HARVEST_LN" -lt "$JOIN_CLEAR_LN" ] && [ "$JOIN_CLEAR_LN" -lt "$JOIN_REGRANT_LN" ]; then _ok "§6o''': harvest (${JOIN_HARVEST_LN}) precedes the clear (${JOIN_CLEAR_LN}) precedes the re-grant (${JOIN_REGRANT_LN})"
else _fail "§6o''': join-stamp harvest / Map.clear(badges) / re-grant are not in that order (${JOIN_HARVEST_LN:-none} / ${JOIN_CLEAR_LN:-none} / ${JOIN_REGRANT_LN:-none})"; fi

# ── 6p. Capture sites cannot abort silently under set -e (#55) ─────
# deploy.sh runs `set -euo pipefail` (the ERR belt of §6ao only NAMES an
# abort, it does not prevent one), so a bare
# `x="$(icp … 2>&1)"` ends the script at a non-zero CLI exit (a transport or
# decode failure — reachable on every shipped posture) with the diagnostic
# CAPTURED BUT NEVER PRINTED; at the arb site that also skipped setEnabled,
# the AI-key injection and the frontend build. The fix is cold_start.sh's
# shape: `|| true` INSIDE the substitution, then gate on the OUTPUT (§6m's
# predicates). Pinned in source, then PROVED: the three real blocks are
# extracted verbatim and run under `set -euo pipefail` against a failing
# `icp` stub on PATH — the stub's diagnostic must be printed, the warn arm
# taken, and the line after the block reached. A negative control strips
# the `|| true` and must abort with the sentinel unreached, so the probe
# demonstrably sees the bug it pins; a succeeding stub proves the ok arm.
DEPLOY_SH_55="$(uncommented scripts/deploy.sh)"
for m in seedAmmPool seedInsuranceFund fundArbitrageur; do
  if printf '%s\n' "$DEPLOY_SH_55" | grep -E "^ *[a-z_]+=\"?\\\$\\(icp canister call backend $m " | grep -cE '2>&1 \|\| true\)"?$' >/dev/null; then
    _ok "$m capture keeps || true INSIDE the substitution"
  else _fail "$m capture is a bare \$(icp … 2>&1) again — under set -e a CLI failure aborts deploy.sh with the diagnostic unprinted (#55)"; fi
done
grep_scan BARE_CAPTURES "$DEPLOY_SH_55" '=\"?\$\(icp .*2>&1\)\"?$'
grep_filter BARE_CAPTURES '\|\| true\)"?$'
if [ -z "$BARE_CAPTURES" ]; then _ok "no bare \$(icp … 2>&1) capture remains in deploy.sh"
else _fail "bare icp captures in deploy.sh (add || true inside the substitution, gate on the output): $(printf '%s' "$BARE_CAPTURES" | tr '\n' ' ' | head -c 300)"; fi
src_has "seedAmmPool gates on the returned VARIANT, not a case-sensitive grep for err" "$DEPLOY_SH_55" 'if ! mdx_reply_ok "$seed_out"; then'
W55_TMP="$(mktemp -d "${TMPDIR:-/tmp}/w55.XXXXXX")"
mkdir -p "$W55_TMP/bad" "$W55_TMP/good"
cat > "$W55_TMP/bad/icp" <<'W55EOF'
#!/bin/bash
# a CLI that FAILS: the diagnostic the real CLI prints on a transport failure
echo "Error: transport failure: connection reset by peer (W55 STUB DIAGNOSTIC)" >&2
exit 7
W55EOF
cat > "$W55_TMP/good/icp" <<'W55EOF'
#!/bin/bash
# a CLI that SUCCEEDS: the exact shapes the three methods answer with
case "$*" in
  *seedInsuranceFund*) echo "(14_400_000_000_000 : nat)" ;;
  *)                   echo "(variant { ok = 5 : nat })" ;;
esac
W55EOF
chmod +x "$W55_TMP/bad/icp" "$W55_TMP/good/icp"
sed -n '/^ *seed_out=\$(icp canister call backend seedAmmPool/,/^ *fi$/p'          scripts/deploy.sh > "$W55_TMP/blk_seedAmmPool.sh"
sed -n '/^ *seed_ins_out="\$(icp canister call backend seedInsuranceFund/,/^ *fi$/p' scripts/deploy.sh > "$W55_TMP/blk_seedInsuranceFund.sh"
sed -n '/^ *fund_out="\$(icp canister call backend fundArbitrageur/,/^ *fi$/p'       scripts/deploy.sh > "$W55_TMP/blk_fundArbitrageur.sh"
cat > "$W55_TMP/probe.sh" <<'W55EOF'
#!/bin/bash
# $1 = deploy.sh  $2 = extracted block  $3 = keep|strip (strip = the #55 bug)
set -euo pipefail
ok()   { printf 'ok %s\n' "$1"; }
warn() { printf 'warn %s\n' "$1"; }
e8()   { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
mdx_reply_ok()  { return 1; }
mdx_reply_nat() { return 1; }
. "$(dirname "$1")/lib/reply.sh" 2>/dev/null || true    # the REAL predicates (scripts/lib/reply.sh, as deploy.sh sources them)
CE_ENV=engine; CE_IDENTITY=stub; market=BTC-ICPUSD; base=1; quote=1; px=1
SEED_MINT_FAILED=0; seed_record() { :; }   # H-02: the blocks count failures + record mints
if [ "$3" = strip ]; then BODY="$(sed 's/ || true)/)/' "$2")"; else BODY="$(cat "$2")"; fi
eval "$BODY"
echo "W55-REACHED-AFTER-BLOCK"
W55EOF
for m in seedAmmPool seedInsuranceFund fundArbitrageur; do
  blk="$W55_TMP/blk_$m.sh"
  if ! grep -q '^ *if ' "$blk" || ! grep -q '^ *fi$' "$blk" || ! grep -q '|| true)' "$blk"; then
    _fail "could not extract the $m block from deploy.sh (probe would test nothing)"; continue
  fi
  out="$(PATH="$W55_TMP/bad:$PATH" bash "$W55_TMP/probe.sh" scripts/deploy.sh "$blk" keep 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'W55 STUB DIAGNOSTIC' \
     && printf '%s\n' "$out" | grep -q '^warn ' && printf '%s\n' "$out" | grep -q 'W55-REACHED-AFTER-BLOCK'; then
    _ok "$m: failing icp → diagnostic PRINTED in the warn, script continues (exit 0)"
  else _fail "$m under a failing icp: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi
  out="$(PATH="$W55_TMP/bad:$PATH" bash "$W55_TMP/probe.sh" scripts/deploy.sh "$blk" strip 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'W55-REACHED-AFTER-BLOCK' && ! printf '%s\n' "$out" | grep -q '^warn '; then
    _ok "$m negative control: without || true the block aborts silently (exit $rc, no warn) — the probe sees the #55 bug"
  else _fail "$m negative control did not abort silently (exit $rc) — the probe cannot see the #55 bug"; fi
  out="$(PATH="$W55_TMP/good:$PATH" bash "$W55_TMP/probe.sh" scripts/deploy.sh "$blk" keep 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q '^ok ' && ! printf '%s\n' "$out" | grep -q '^warn '; then
    _ok "$m: succeeding icp → the ok arm (the gate still passes real successes)"
  else _fail "$m under a succeeding icp: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi
done
rm -rf "$W55_TMP"

# ── 6q. The header gate checks EVERY https origin (#55) ────────────
# Both W4-20 loops `break`-ed after the first CSV token, so a non-https
# FIRST origin ran no header check at all, and a second public origin was
# never verified. One shared function now walks the whole list, skips
# non-https tokens BY NAME, and dies once naming every failing origin. The
# real function is driven offline against a recording check_headers.sh stub.
DEPLOY_SH_HDR="$(uncommented scripts/deploy.sh)"
HDR_FN="$(sed -n '/^check_frontend_headers() {/,/^}/p' scripts/deploy.sh)"
[ -n "$HDR_FN" ] || _fail "could not extract check_frontend_headers() from deploy.sh"
src_lacks "the header gate no longer breaks after the first token"     "$HDR_FN" "break"
src_has   "the subnet tail checks every SN_FRONTEND_ORIGINS token"     "$DEPLOY_SH_HDR" 'check_frontend_headers "${SN_FRONTEND_ORIGINS:-}"'
src_has   "the engine tail checks every CE_FRONTEND_ORIGINS token"     "$DEPLOY_SH_HDR" 'check_frontend_headers "${CE_FRONTEND_ORIGINS:-}"'
src_lacks "no inline first-token-only header loop remains"            "$DEPLOY_SH_HDR" 'https://*) bash'
HDR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hdrgate.XXXXXX")"
cat > "$HDR_TMP/check_headers.sh" <<'HDREOF'
#!/bin/bash
# recording stub: every origin it is asked about lands in seen.log; *bad* fails
echo "$1" >> "$(dirname "$0")/seen.log"
case "$1" in *bad*) echo "check_headers: FAIL ($1)" >&2; exit 1 ;; *) echo "check_headers: PASS ($1)" ;; esac
HDREOF
cat > "$HDR_TMP/probe.sh" <<'HDREOF'
#!/bin/bash
set -euo pipefail
ok()   { printf 'ok %s\n' "$1"; }
warn() { printf 'warn %s\n' "$1"; }
die()  { printf 'die %s\n' "$1" >&2; exit 1; }
check_frontend_headers() { echo "FALLBACK-NOT-THE-REAL-FUNCTION"; exit 99; }
eval "$(sed -n '/^check_frontend_headers() {/,/^}/p' "$1")"   # the REAL gate; $0's dir holds the stub
check_frontend_headers "$2"
HDREOF
: > "$HDR_TMP/seen.log"
out="$(bash "$HDR_TMP/probe.sh" scripts/deploy.sh "http://plain.local,https://a.good,https://b.bad,https://c.good" 2>&1)"; rc=$?
seen="$(tr '\n' ' ' < "$HDR_TMP/seen.log")"
if [ "$seen" = "https://a.good https://b.bad https://c.good " ]; then _ok "header gate: every https token is checked, a non-https first token does not stop it (saw: $seen)"
else _fail "header gate checked '$seen' — expected all three https origins, in order"; fi
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'die security headers missing on: https://b.bad —'; then _ok "header gate dies naming the failing origin"
else _fail "header gate with a failing origin: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"; fi
src_has "header gate names the non-https token it skipped" "$out" 'warn header check skipped for http://plain.local'
: > "$HDR_TMP/seen.log"
out="$(bash "$HDR_TMP/probe.sh" scripts/deploy.sh "https://a.good,https://c.good" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'ok security headers verified on 2 origin(s)' && [ "$(grep -c . "$HDR_TMP/seen.log")" -eq 2 ]; then _ok "header gate passes an all-green CSV, reporting the count"
else _fail "header gate on an all-green CSV: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"; fi
: > "$HDR_TMP/seen.log"
out="$(bash "$HDR_TMP/probe.sh" scripts/deploy.sh "" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$HDR_TMP/seen.log" ]; then _ok "header gate: an empty CSV checks nothing and passes (no origin recorded = nothing to verify)"
else _fail "header gate on an empty CSV: exit $rc, seen='$(cat "$HDR_TMP/seen.log")'"; fi
rm -rf "$HDR_TMP"

# ── 6r. check_headers.sh follows redirects, judges the final hop (#55) ──
# A public origin that 301/302s to its canonical host carried none of the
# headers on the redirect response, so the gate went red on a healthy site.
# curl now follows (-L), and only the LAST header block is judged — headers
# on an intermediate hop vouch for nothing. Driven offline through a curl
# stub that prints the hop alone unless -L is passed.
CH_SH="$(uncommented scripts/check_headers.sh)"
src_has "check_headers follows redirects (curl -L)"     "$CH_SH" 'curl -s -L --max-redirs'
src_has "check_headers keeps only the final header block" "$CH_SH" "awk 'BEGIN{RS=\"\"} {blk=\$0} END{printf \"%s\", blk}'"
src_has "check_headers asserts the served Permissions-Policy keeps clipboard-write=(self) (1793507771)" "$CH_SH" 'clipboard-write=\(self\)'
CH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/chdr.XXXXXX")"
mkdir -p "$CH_TMP/bin"
cat > "$CH_TMP/bin/curl" <<'CHEOF'
#!/bin/bash
# curl stub: a 302 hop, then (only under -L) the final 200. Default: the hop
# is bare and the final carries every header. CH_MODE=leaky inverts that —
# the HOP carries the headers and the final response has none. CH_MODE=legacy
# keeps the hop bare and serves LEGACY as the final response (1793509070).
# FULL is every header the gate needs, Permissions-Policy included (1793507771).
# LEGACY is FULL with the pre-1793506794 Permissions-Policy preset — the empty
# clipboard-write=() allowlist that denied the page its own Copy buttons; a
# sibling string (same \r\n line ends), never a sed over FULL.
follow=false; for a in "$@"; do [ "$a" = "-L" ] && follow=true; done
FULL=$'content-security-policy: default-src \'self\'; script-src \'self\'; object-src \'none\'; frame-ancestors \'none\'\r\nstrict-transport-security: max-age=31536000\r\nx-content-type-options: nosniff\r\nx-frame-options: DENY\r\nreferrer-policy: same-origin\r\npermissions-policy: clipboard-read=(), clipboard-write=(self)\r\n'
LEGACY=$'content-security-policy: default-src \'self\'; script-src \'self\'; object-src \'none\'; frame-ancestors \'none\'\r\nstrict-transport-security: max-age=31536000\r\nx-content-type-options: nosniff\r\nx-frame-options: DENY\r\nreferrer-policy: same-origin\r\npermissions-policy: clipboard-read=(), clipboard-write=()\r\n'
hop=""; fin="$FULL"
[ "${CH_MODE:-}" = leaky ] && { hop="$FULL"; fin=""; }
[ "${CH_MODE:-}" = legacy ] && { hop=""; fin="$LEGACY"; }
printf 'HTTP/1.1 302 Found\r\nlocation: https://final.example/\r\ncontent-length: 0\r\n%s\r\n' "$hop"
$follow && printf 'HTTP/1.1 200 OK\r\ncontent-type: text/html\r\n%s\r\n' "$fin"
exit 0
CHEOF
chmod +x "$CH_TMP/bin/curl"
out="$(PATH="$CH_TMP/bin:$PATH" bash scripts/check_headers.sh https://redirecting.example/ 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'followed 1 redirect' && printf '%s\n' "$out" | grep -q 'check_headers: PASS'; then _ok "check_headers passes a redirecting origin whose FINAL response carries the headers"
else _fail "check_headers on a redirecting origin: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi
out="$(CH_MODE=leaky PATH="$CH_TMP/bin:$PATH" bash scripts/check_headers.sh https://redirecting.example/ 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'check_headers: FAIL'; then _ok "check_headers fails when only the redirect HOP carries the headers (the final response is what is judged)"
else _fail "check_headers PASSED on headers that live only on the redirect hop: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi
# The clipboard token's NEGATIVE control (1793509070): the legacy preset
# `clipboard-read=(), clipboard-write=()` must be REJECTED, and the verdict must
# name clipboard-write=(self) ALONE — clipboard-read=() is still served, so the
# gate may not flag it. The textual pin above only proves the ERE's spelling; a
# later loosening (`clipboard-write=\(` or `clipboard-write=` alone) that lets
# `()` through again reds HERE. Until this line the control lived in a seat's
# shell history (1793507771).
out="$(CH_MODE=legacy PATH="$CH_TMP/bin:$PATH" bash scripts/check_headers.sh https://redirecting.example/ 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qF '✗ MISSING: Permissions-Policy: clipboard-write=(self)' && printf '%s\n' "$out" | grep -qF 'check_headers: FAIL' && ! printf '%s\n' "$out" | grep -qF '✗ MISSING: Permissions-Policy: clipboard-read=()'; then _ok "check_headers REJECTS the legacy clipboard-write=() preset and names only that token (1793509070)"
else _fail "check_headers on the legacy clipboard-write=() preset: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi
rm -rf "$CH_TMP"

# ── 6s. play_start.sh's header describes the wiring it does (#55) ──
# The header claimed the script "re-wires setBridge/setDex"; the body (and
# the ok line it prints) says Bridge ↔ DEX auto-wire from the canister env
# vars and setBridge/setDex stay break-glass. Headers are what operators
# read first; keep this one honest.
PS_HDR="$(sed -n '1,60p' scripts/play_start.sh)"
src_lacks "play_start.sh header no longer claims a setBridge/setDex re-wire" "$PS_HDR" "re-wires setBridge/setDex"
src_has   "play_start.sh header names the env-var auto-wire"               "$PS_HDR" "auto-wire from the PUBLIC_CANISTER_ID:* env vars"
src_has   "play_start.sh body still reports the auto-wire"                  "$(cat scripts/play_start.sh)" 'ok "Bridge ↔ DEX auto-wired via canister env vars"'

# ── 6t. adminUpgradeArchives reports the real failure cause (#54.7) ──
# The per-hop catch used to drop Error.message(e), and the reply labelled
# EVERY failed hop "skipped (blackholed)" although _blackholeAtSeal defaults
# OFF — so on dev/play every non-zero skip was a misreport, and the subnet
# runbook (docs/deploy-to-subnet.md §3) read that string and proceeded. The
# gate was `archive0 == null`, refusing a chain of N upgradeable sealed
# segments right after a season reset. Pins: the gate is the CHAIN; a failed
# hop is logged with principal + IC cause; a blackholed hop is classified
# from the seal-time record (written where the controller drop succeeds);
# the one-cause label and the error-dropping catch are gone. Live twin:
# tests/test_archive_chain.sh §5-§7. Task 1788465023.
UPG_ARCH_FN=$(mo_func src/backend/main.mo "func adminUpgradeArchives(")
[ -n "$UPG_ARCH_FN" ] || _fail "could not extract adminUpgradeArchives()"
UPG_ARCH_CODE=$(printf '%s\n' "$UPG_ARCH_FN" | mo_code)
src_has   "adminUpgradeArchives gates on the whole chain, not the active tip" "$UPG_ARCH_CODE" 'if (chain.size() == 0)'
src_lacks "adminUpgradeArchives no longer refuses on a null archive0"         "$UPG_ARCH_CODE" 'archive0 == null'
src_has   "a failed hop logs the principal and the IC cause"                  "$UPG_ARCH_CODE" 'logEvent("warn", "system", "ARCHIVE UPGRADE: " # Principal.toText(cid) # " failed: " # Error.message(e)'
src_has   "a blackholed hop is classified from the seal-time record"          "$UPG_ARCH_CODE" 'if (isBlackholedArchive(cid))'
src_lacks "the catch no longer discards the error"                             "$UPG_ARCH_CODE" 'catch (_)'
src_has   "the reply counts failures beside design skips"                      "$UPG_ARCH_CODE" '" failed"'
src_has   "a pass with failures logs at warn"                                  "$UPG_ARCH_CODE" 'if (failed > 0) "warn" else "info"'
TICK_SHIP_BH=$(mo_func src/backend/main.mo "func tickShipEvents(")
[ -n "$TICK_SHIP_BH" ] || _fail "could not extract tickShipEvents()"
src_has   "the seal-time record is written only after the controller drop succeeds" "$(printf '%s\n' "$TICK_SHIP_BH" | mo_code)" 'List.add(_archivesBlackholed, sealedCid);'
WIPE_FN=$(mo_func src/backend/main.mo "func performWorldWipe(")
[ -n "$WIPE_FN" ] || _fail "could not extract performWorldWipe()"
src_has   "the full wipe clears the seal-time record with the routing lists" "$(printf '%s\n' "$WIPE_FN" | mo_code)" 'List.clear(_archivesBlackholed);'
CTRL_HOOK_FN=$(mo_func src/backend/main.mo "func setTestArchiveControllers(")
[ -n "$CTRL_HOOK_FN" ] || _fail "could not extract setTestArchiveControllers()"
src_has   "the forced-failure hook is dev-gated"                     "$CTRL_HOOK_FN" 'requireDevHook("setTestArchiveControllers")'
src_has   "the forced-failure hook is scoped to our own segments"    "$CTRL_HOOK_FN" 'not an archive segment of this exchange'

# ── 6u. H-02 (F8): the remote pre-flight pins ids + the controller set ──
# deploy.sh used to install onto whatever .icp/data/mappings/<env>.ids.json
# named: no expected id lived anywhere in the tree, nothing read the
# target's controllers before inject_ai_keys / apply_anti_sybil_settings,
# and no gate read ids.json at all — so a poisoned mapping (one id swapped
# for an attacker's canister) would ship the AI keys and the production
# origins to it, and factory_guard.sh (seat-keyed) never sees an OPERATOR
# rollout. targets.sh now pins the PUBLIC ids per environment;
# mdx_assert_deploy_target diffs the mapping against the table BEFORE any
# icp call, then resolves every canister via icp-cli and reads each
# controller set, refusing unless it equals the deployer's principal set
# (+ the table's pinned extras). Driven END TO END: the real deploy.sh runs
# `subnet` inside a throwaway copy of the tree (fixture main.mo at #play, a
# stub gen-did.sh, a fake scripts/.subnet.conf that exists ONLY in the copy
# — never the primary's) against an `icp` stub that records every
# invocation and FAILS LOUDLY on any deploy / canister call: no remote is
# ever touched (law 8), and a run that reaches the deploy is itself proof
# the pre-flight is what stopped the others.
TG_H02="$(uncommented scripts/lib/targets.sh)"
src_has "targets.sh defines the pre-flight"                       "$TG_H02" "mdx_assert_deploy_target()"
src_has "targets.sh pins the expected ids per environment"         "$TG_H02" "mdx_expected_id()"
src_has "the pre-flight diffs the mapping file against the table" "$TG_H02" 'ids.json'
src_has "the pre-flight reads the controller set"                  "$TG_H02" 'Controllers:'
for envn in subnet engine; do
  for c in backend bridge arb frontend; do
    want="$(bash -c '. scripts/lib/targets.sh && mdx_expected_id "$1" "$2"' _ "$envn" "$c" 2>/dev/null)"
    have="$(sed -n "s/.*\"$c\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" ".icp/data/mappings/$envn.ids.json")"
    if [ -n "$want" ] && [ "$want" = "$have" ]; then _ok "pinned $envn:$c id agrees with the tracked mapping ($want)"
    else _fail "pinned $envn:$c id '$want' vs tracked mapping '$have' — the table and the mapping must agree or every $envn deploy is refused"; fi
  done
done
for f in scripts/deploy_to_subnet.sh scripts/deploy_to_engine.sh; do
  src_has "$(basename "$f") runs the pre-flight before exec-ing deploy.sh" "$(uncommented "$f")" "mdx_assert_deploy_target"
done
DEPLOY_H02="$(uncommented scripts/deploy.sh)"
PF_SUBNET_LN="$(printf '%s\n' "$DEPLOY_H02" | grep -n 'mdx_assert_deploy_target "$CE_ENV" "$SN_IDENTITY"' | head -1 | cut -d: -f1)"
PF_ENGINE_LN="$(printf '%s\n' "$DEPLOY_H02" | grep -n 'mdx_assert_deploy_target "$CE_ENV" "$CE_IDENTITY"' | head -1 | cut -d: -f1)"
RD_CALLS="$(printf '%s\n' "$DEPLOY_H02" | grep -nE '^[[:space:]]*remote_deploy[[:space:]]*$' | cut -d: -f1)"
RD_SUBNET_LN="$(printf '%s\n' "$RD_CALLS" | sed -n '1p')"; RD_ENGINE_LN="$(printf '%s\n' "$RD_CALLS" | sed -n '2p')"
if [ -n "$PF_SUBNET_LN" ] && [ -n "$RD_SUBNET_LN" ] && [ "$PF_SUBNET_LN" -lt "$RD_SUBNET_LN" ]; then _ok "deploy.sh subnet: pre-flight (line $PF_SUBNET_LN) precedes remote_deploy (line $RD_SUBNET_LN)"
else _fail "deploy.sh subnet: pre-flight must run before remote_deploy (pre-flight line '${PF_SUBNET_LN:-none}', remote_deploy line '${RD_SUBNET_LN:-none}')"; fi
if [ -n "$PF_ENGINE_LN" ] && [ -n "$RD_ENGINE_LN" ] && [ "$PF_ENGINE_LN" -lt "$RD_ENGINE_LN" ] && [ "$PF_ENGINE_LN" -gt "$RD_SUBNET_LN" ]; then _ok "deploy.sh engine: pre-flight (line $PF_ENGINE_LN) precedes remote_deploy (line $RD_ENGINE_LN)"
else _fail "deploy.sh engine: pre-flight must run before remote_deploy (pre-flight line '${PF_ENGINE_LN:-none}', remote_deploy line '${RD_ENGINE_LN:-none}')"; fi
RD_FN="$(sed -n '/^remote_deploy() {/,/^}/p' scripts/deploy.sh)"
src_has "remote_deploy refuses to run without a verified target" "$RD_FN" 'MDX_TARGET_VERIFIED'
PF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
PF_REPO="$PF_TMP/repo"; PF_LOG="$PF_TMP/calls.log"
mkdir -p "$PF_REPO/scripts/lib" "$PF_REPO/src/backend" "$PF_REPO/src/bridge" "$PF_REPO/.icp/data/mappings" "$PF_TMP/bin"
cp scripts/deploy.sh scripts/factory_guard.sh "$PF_REPO/scripts/"
cp scripts/lib/*.sh "$PF_REPO/scripts/lib/"
cp .icp/data/mappings/subnet.ids.json .icp/data/mappings/engine.ids.json "$PF_REPO/.icp/data/mappings/"
printf '#!/bin/bash\nexit 0\n' > "$PF_REPO/scripts/gen-did.sh"
for f in src/backend/main.mo src/bridge/main.mo; do
  printf 'actor {\n  public type DeployMode = { #dev; #play; #production };\n  transient let DEPLOY_MODE : DeployMode = #play;\n  transient let IS_PRODUCTION : Bool = DEPLOY_MODE == #production;\n  transient let IS_DEV : Bool = DEPLOY_MODE == #dev;\n}\n' > "$PF_REPO/$f"
done
printf "SN_IDENTITY=pf-stub-wallet\nSN_SUBNET=pf-stub-subnet\nSN_FRONTEND_ORIGINS=''\n" > "$PF_REPO/scripts/.subnet.conf"
cat > "$PF_TMP/bin/icp" <<'PFEOF'
#!/bin/bash
# Recording icp stub. Answers identity/status READS from the copy's own
# mapping; any deploy or canister call is a FORBIDDEN remote act: logged,
# loud, exit 9. PF_CONTROLLERS / PF_BRIDGE_ID bend the status answers.
printf '%s\n' "$*" >> "$PF_LOG"
name=""; for a in "$@"; do case "$a" in backend|bridge|arb|frontend) name="$a" ;; esac; done
case "$1 $2" in
  "identity principal") echo "pf-stub-principal-aaaaa-aa" ;;
  "canister status")
    id="$(sed -n "s/.*\"$name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$PF_MAPPING")"
    [ "$name" = bridge ] && [ -n "${PF_BRIDGE_ID:-}" ] && id="$PF_BRIDGE_ID"
    # With no injected set the stub answers the LIVE shape: the deployer plus
    # the extras pinned for ($env, $name) in the copied targets.sh (2026-10-31:
    # the subnet's wallet/backend + recovery principals, per canister) - so
    # the control case passes only when the table and the pre-flight agree.
    extras=""; [ -n "${PF_CONTROLLERS:-}" ] || extras="$( . "$PF_REPO/scripts/lib/targets.sh" >/dev/null 2>&1; mdx_expected_extra_controllers subnet "$name" )"
    printf 'Canister Id: %s\nCanister Name: %s\nCanister Status Report:\n  Status: Running\n  Controllers: %s\n  Memory Size: 1\n' "$id" "$name" "${PF_CONTROLLERS:-pf-stub-principal-aaaaa-aa${extras:+ $extras}}" ;;
  "deploy "*|"canister call"|"canister settings"|"canister install"|"canister create")
    echo "icp stub: FORBIDDEN remote act attempted: icp $*" >&2; printf 'FORBIDDEN %s\n' "$*" >> "$PF_LOG"; exit 9 ;;
  *) exit 0 ;;
esac
PFEOF
chmod +x "$PF_TMP/bin/icp"
pf_run() {  # runs the real deploy.sh `subnet` inside the copy → $out, $rc, $PF_LOG
  : > "$PF_LOG"
  out="$(cd "$PF_REPO" && env -u FACTORY_WORKER -u FACTORY_FORCE PATH="$PF_TMP/bin:$PATH" PF_LOG="$PF_LOG" \
        PF_REPO="$PF_REPO" PF_MAPPING="$PF_REPO/.icp/data/mappings/subnet.ids.json" PF_CONTROLLERS="${PF_CONTROLLERS:-}" PF_BRIDGE_ID="${PF_BRIDGE_ID:-}" \
        DEPLOY_TARGET=subnet SEED=false bash scripts/deploy.sh subnet </dev/null 2>&1)"; rc=$?
}
# A negated ban: with -q a regex error (rc 2) was `! 2` = TRUE and every chain
# below reached its _ok; grep_has fails the chain instead (task 1793505604).
pf_no_remote_act() { ! grep_has "$(cat "$PF_LOG")" '^(FORBIDDEN|deploy |canister call)'; }
# (a) one mapping id changed → abort BEFORE any icp call beyond the identity read
cp .icp/data/mappings/subnet.ids.json "$PF_REPO/.icp/data/mappings/subnet.ids.json"
sed 's/"backend": *"[^"]*"/"backend": "aaaaa-aa"/' .icp/data/mappings/subnet.ids.json > "$PF_REPO/.icp/data/mappings/subnet.ids.json"
PF_CONTROLLERS="" PF_BRIDGE_ID="" pf_run
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'subnet.ids.json' && printf '%s\n' "$out" | grep -q 'hmxr2-pqaaa-aaabq-qaaaa-cai' \
   && pf_no_remote_act && ! grep -q '^canister ' "$PF_LOG"; then
  _ok "deploy.sh subnet with a poisoned mapping aborts before ANY canister/deploy call, naming the file and the pinned id (icp saw: $(tr '\n' ';' < "$PF_LOG"))"
else _fail "deploy.sh subnet with a poisoned mapping: exit $rc, icp saw '$(tr '\n' ';' < "$PF_LOG")' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# (b) control: a clean mapping + matching controllers passes the pre-flight and
#     REACHES the (stubbed, refused) `icp deploy backend` — so (a)'s abort was
#     the gate, not something earlier, and the pre-flight really resolves ids
cp .icp/data/mappings/subnet.ids.json "$PF_REPO/.icp/data/mappings/subnet.ids.json"
PF_CONTROLLERS="" PF_BRIDGE_ID="" pf_run
if [ "$rc" -ne 0 ] && grep -q '^FORBIDDEN deploy backend' "$PF_LOG" && grep -q '^canister status backend' "$PF_LOG" \
   && printf '%s\n' "$out" | grep -qi 'pre-flight'; then
  _ok "control: a clean mapping + matching controllers passes the pre-flight and reaches the (stubbed) backend deploy"
else _fail "control: clean mapping did not reach the deploy through the pre-flight: exit $rc, icp saw '$(tr '\n' ';' < "$PF_LOG")' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# (c) an extra controller on the target → abort before the deploy
PF_CONTROLLERS="pf-stub-principal-aaaaa-aa, evil-attacker-principal-aaaaa-aa" PF_BRIDGE_ID="" pf_run
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qi 'controller' && printf '%s\n' "$out" | grep -q 'evil-attacker-principal' && pf_no_remote_act; then
  _ok "a foreign controller on the target aborts the deploy before any remote act, naming it"
else _fail "foreign controller: exit $rc, icp saw '$(tr '\n' ';' < "$PF_LOG")' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# (d) the CLI resolves one name to a different id than the table (env drift) → abort
PF_CONTROLLERS="" PF_BRIDGE_ID="aaaaa-aa" pf_run
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'bridge' && printf '%s\n' "$out" | grep -q 'hlwxo-ciaaa-aaabq-qaaaq-cai' && pf_no_remote_act; then
  _ok "icp-cli resolving a name to an unpinned id aborts the deploy before any remote act"
else _fail "cli id drift: exit $rc, icp saw '$(tr '\n' ';' < "$PF_LOG")' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
rm -rf "$PF_TMP"

# ── 6v. H-02 (F20): the DEPLOYED posture is read back after the install ──
# Every remote gate reads the SOURCE literal; the only getDeployMode read on
# the remote path sat inside cloud_seed behind the pools guard, and the
# runtime reader was wired only to bot start. So a wasm whose posture the
# source gate misread (or a stale build) reached apply_anti_sybil_settings,
# inject_ai_keys and the frontend legs unchallenged. remote_deploy now reads
# getDeployMode right after `icp deploy backend` and dies unless it equals
# the source posture the gate accepted — and unconditionally on dev.
RD_FN="$(sed -n '/^remote_deploy() {/,/^}/p' scripts/deploy.sh)"
RB_LN="$(printf '%s\n' "$RD_FN" | grep -n '^ *assert_deployed_posture$' | head -1 | cut -d: -f1)"
DEP_LN="$(printf '%s\n' "$RD_FN" | grep -n 'icp deploy backend -e' | head -1 | cut -d: -f1)"
ASS_LN="$(printf '%s\n' "$RD_FN" | grep -n '^ *apply_anti_sybil_settings$' | head -1 | cut -d: -f1)"
if [ -n "$RB_LN" ] && [ -n "$DEP_LN" ] && [ -n "$ASS_LN" ] && [ "$DEP_LN" -lt "$RB_LN" ] && [ "$RB_LN" -lt "$ASS_LN" ]; then
  _ok "remote_deploy reads the posture back between the backend install and apply_anti_sybil_settings"
else _fail "remote_deploy: the read-back must sit after 'icp deploy backend' and before apply_anti_sybil_settings (deploy '${DEP_LN:-none}', read-back '${RB_LN:-none}', settings '${ASS_LN:-none}')"; fi
RB_FN="$(sed -n '/^assert_deployed_posture() {/,/^}/p' scripts/deploy.sh)"
[ -n "$RB_FN" ] || _fail "could not extract assert_deployed_posture() from deploy.sh"
src_has "the read-back is a --query on getDeployMode" "$RB_FN" 'getDeployMode "()" --query'
RB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/readback.XXXXXX")"
mkdir -p "$RB_TMP/bin"
cat > "$RB_TMP/bin/icp" <<'RBEOF'
#!/bin/bash
[ "${RB_FAIL:-}" = 1 ] && { echo "Error: gateway unreachable (RB STUB DIAGNOSTIC)" >&2; exit 7; }
printf '("%s")\n' "$RB_MODE"
RBEOF
chmod +x "$RB_TMP/bin/icp"
cat > "$RB_TMP/probe.sh" <<'RBEOF'
#!/bin/bash
# $1 = deploy.sh  $2 = source posture the gate accepted
set -euo pipefail
ok()   { printf 'ok %s\n' "$1"; }
warn() { printf 'warn %s\n' "$1"; }
die()  { printf 'die %s\n' "$1" >&2; exit 1; }
eval "$(sed -n '/^assert_deployed_posture() {/,/^}/p' "$1")"
CE_ENV=subnet; CE_IDENTITY=stub; POSTURE="$2"
assert_deployed_posture
echo "RB-REACHED-AFTER-READBACK"
RBEOF
rb_case() {  # rb_case <label> <source posture> <deployed mode> <fail:0|1> <expect: pass|die>
  local out rc
  out="$(RB_MODE="$3" RB_FAIL="$4" PATH="$RB_TMP/bin:$PATH" bash "$RB_TMP/probe.sh" scripts/deploy.sh "$2" 2>&1)"; rc=$?
  case "$5" in
    pass) if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'RB-REACHED-AFTER-READBACK'; then _ok "read-back $1: proceeds"
          else _fail "read-back $1: expected to proceed, exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi ;;
    die)  if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'RB-REACHED-AFTER-READBACK' && printf '%s\n' "$out" | grep -q '^die '; then _ok "read-back $1: dies before the settings/keys/frontend legs"
          else _fail "read-back $1: expected to die, exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi ;;
  esac
}
rb_case "play source, play deployed"             play       play       0 pass
rb_case "production source, production deployed" production production 0 pass
rb_case "play source, DEV deployed"              play       dev        0 die
rb_case "dev source, dev deployed (unconditional)" dev      dev        0 die
rb_case "play source, production deployed"       play       production 0 die
rb_case "production source, play deployed"       production play       0 die
rb_case "empty source posture"                   ""         play       0 die
rb_case "gateway failure"                        play       play       1 die
out="$(RB_MODE=play RB_FAIL=1 PATH="$RB_TMP/bin:$PATH" bash "$RB_TMP/probe.sh" scripts/deploy.sh play 2>&1 || true)"
src_has "a failed read-back surfaces the CLI diagnostic" "$out" "RB STUB DIAGNOSTIC"
rm -rf "$RB_TMP"

# ── 6w. H-02 (F29-scripts): the seed probe fails CLOSED ──────────────
# cloud_seed's first-deploy guard was an UPDATE call with stderr discarded
# and `grep -q record`: a gateway hiccup during a routine deploy was
# indistinguishable from "no pools", so the guard fell through and re-ran
# the whole genesis mint (setTestBalance, seedAmmPool, seedInsuranceFund —
# several $M of unbacked supply onto a live venue). The probe is now a
# --query whose exit status is checked, whose stderr is surfaced, and whose
# output is parsed POSITIVELY: `vec {}` means seed, a record means seeded,
# anything else dies. Mint steps report their failures instead of
# swallowing them, and the summary states what was minted.
CS_FN="$(sed -n '/^cloud_seed() {/,/^}/p' scripts/deploy.sh)"
[ -n "$CS_FN" ] || _fail "could not extract cloud_seed() from deploy.sh"
src_lacks "cloud_seed no longer greps a stderr-discarded update probe" "$CS_FN" '2>/dev/null | grep -q "record"'
if printf '%s\n' "$CS_FN" | grep -cE '^[[:space:]]*seed_probe_pools[[:space:]]*$' >/dev/null; then _ok "cloud_seed calls the probe BARE (dies in its own shell, never inside \$())"
else _fail "cloud_seed must call seed_probe_pools as a bare statement (a \$() subshell swallows its die — targets.sh NOTE ON SHAPE)"; fi
src_has   "cloud_seed acts on the probe verdict"                       "$CS_FN" '"$SEED_PROBE" = "seeded"'
src_has   "cloud_seed posture probe is a --query (1788549769)"        "$CS_FN" 'getDeployMode "()" --query'
src_lacks "no setTestBalance mint is swallowed in cloud_seed"          "$(printf '%s\n' "$CS_FN" | grep 'setTestBalance')" '>/dev/null 2>&1 || true'
src_has   "the seed summary states what was minted"                    "$CS_FN" 'Minted (genesis, unbacked)'
SP_FN="$(sed -n '/^seed_probe_pools() {/,/^}/p' scripts/deploy.sh)"
[ -n "$SP_FN" ] || _fail "could not extract seed_probe_pools() from deploy.sh"
src_has "the probe is a --query" "$SP_FN" 'getAmmPools "()" --query'
SP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/seedprobe.XXXXXX")"
mkdir -p "$SP_TMP/bin"
cat > "$SP_TMP/bin/icp" <<'SPEOF'
#!/bin/bash
case "${SP_MODE:-}" in
  fail)   echo "Error: gateway unreachable: connection refused (SP STUB DIAGNOSTIC)" >&2; exit 7 ;;
  empty)  echo "(vec {})" ;;
  seeded) echo "(vec { record { market = \"BTC-ICPUSD\"; refPrice = 1 : nat } })" ;;
  junk)   echo "Warning: something odd happened" ;;
esac
SPEOF
chmod +x "$SP_TMP/bin/icp"
cat > "$SP_TMP/probe.sh" <<'SPEOF'
#!/bin/bash
# $1 = deploy.sh  $2 = new|old  (old = the pre-H-02 probe shape, the negative control)
set -euo pipefail
info() { printf 'info %s\n' "$1"; }
ok()   { printf 'ok %s\n' "$1"; }
warn() { printf 'warn %s\n' "$1"; }
die()  { printf 'die %s\n' "$1" >&2; exit 1; }
CE_ENV=subnet; CE_IDENTITY=stub; SEED_PROBE=""
if [ "$2" = old ]; then
  seed_probe_pools() {
    if icp canister call backend getAmmPools "()" -e "$CE_ENV" --identity "$CE_IDENTITY" 2>/dev/null | grep -q "record"; then SEED_PROBE=seeded; else SEED_PROBE=empty; fi
  }
else
  eval "$(sed -n '/^seed_probe_pools() {/,/^}/p' "$1")"
fi
seed_probe_pools
if [ "$SEED_PROBE" = "seeded" ]; then echo "SP-SKIP-ALREADY-SEEDED"; exit 0; fi
echo "SP-REACHED-MINT"
SPEOF
sp_case() {  # sp_case <label> <mode> <new|old> <expect: mint|skip|die>
  local out rc
  out="$(SP_MODE="$2" PATH="$SP_TMP/bin:$PATH" bash "$SP_TMP/probe.sh" scripts/deploy.sh "$3" 2>&1)"; rc=$?
  case "$4" in
    mint) if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'SP-REACHED-MINT'; then _ok "seed probe $1: proceeds to mint"
          else _fail "seed probe $1: expected to mint, exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi ;;
    skip) if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'SP-SKIP-ALREADY-SEEDED'; then _ok "seed probe $1: skips (already seeded)"
          else _fail "seed probe $1: expected to skip, exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi ;;
    die)  if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'SP-REACHED-MINT' && printf '%s\n' "$out" | grep -q '^die '; then _ok "seed probe $1: dies — nothing minted"
          else _fail "seed probe $1: expected to die, exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 300)"; fi ;;
  esac
}
sp_case "empty venue (vec {})"      empty  new mint
sp_case "seeded venue (record)"     seeded new skip
sp_case "gateway failure"           fail   new die
sp_case "unparseable answer"        junk   new die
out="$(SP_MODE=fail PATH="$SP_TMP/bin:$PATH" bash "$SP_TMP/probe.sh" scripts/deploy.sh new 2>&1 || true)"
src_has "a failed probe surfaces the CLI diagnostic" "$out" "SP STUB DIAGNOSTIC"
# Negative control: the pre-H-02 probe shape under the same gateway failure
# proceeds to mint — the probe demonstrably sees the F29 fail-open.
out="$(SP_MODE=fail PATH="$SP_TMP/bin:$PATH" bash "$SP_TMP/probe.sh" scripts/deploy.sh old 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'SP-REACHED-MINT'; then _ok "negative control: the old probe under a gateway failure falls through to the mint (the probe sees the F29 bug)"
else _fail "negative control: the old probe shape did not fall through (exit $rc) — the probe cannot see the F29 bug"; fi
rm -rf "$SP_TMP"
# ── 6x. The archive spawn slot is a busy guard (#55, task 1788465033) ──
# W4-16's _pendingSpawn was a record only: set AFTER create_canister, checked
# by no spawn site (they gated on the transient cooldown alone), and cleared
# UNCONDITIONALLY by the reconciler. A wipe zeroing the cooldown mid-install
# let the first beat re-spawn and overwrite the record — a funded canister
# main controls, listed nowhere. Pins: a transient latch is raised BEFORE
# create_canister and released in finally; every spawn site asks the guard
# first and a refusal arms no cooldown; both clears compare-and-clear; an
# install failure logs the principal; the wipe leaves the record to the
# reconciler; the hooks are dev-gated and scoped; getCanisterInfo lists the
# slot. Live twin: tests/test_archive_failover.sh §S.
SPAWN_FN=$(mo_func src/backend/main.mo "func spawnArchive(")
[ -n "$SPAWN_FN" ] || _fail "could not extract spawnArchive()"
SPAWN_CODE=$(printf '%s\n' "$SPAWN_FN" | mo_code)
src_has "spawnArchive refuses while the slot is held (the belt)"        "$SPAWN_CODE" 'if (spawnSlotBusy("belt"))'
LATCH_LN=$(printf '%s\n' "$SPAWN_CODE" | grep -nF '_spawnInFlight := true' | head -1 | cut -d: -f1)
CREATE_LN=$(printf '%s\n' "$SPAWN_CODE" | grep -nF 'ic00.create_canister' | head -1 | cut -d: -f1)
if [ -n "$LATCH_LN" ] && [ -n "$CREATE_LN" ] && [ "$LATCH_LN" -lt "$CREATE_LN" ]; then _ok "the in-flight latch is raised BEFORE create_canister (the record cannot guard that await)"
else _fail "the in-flight latch must precede create_canister (latch line ${LATCH_LN:-none}, create line ${CREATE_LN:-none})"; fi
src_has "the latch is released in finally (a trapping callback still frees the slot)" "$SPAWN_CODE" '} finally {'
src_has "the latch release is the finally body"                          "$SPAWN_CODE" '_spawnInFlight := false;'
src_has "an install failure logs the orphan's principal"                 "$SPAWN_CODE" '"ARCHIVE SPAWN: install of " # Principal.toText(cid) # " failed ("'
src_has "spawnArchive clears only the record it wrote"                   "$SPAWN_CODE" 'if (Principal.equal(cur.cid, cid)) { _pendingSpawn := null }'
src_lacks "spawnArchive has no unconditional clear"                      "$SPAWN_CODE" '_pendingSpawn := null;'
REC_FN=$(mo_func src/backend/main.mo "func reconcilePendingSpawn(")
[ -n "$REC_FN" ] || _fail "could not extract reconcilePendingSpawn()"
REC_CODE=$(printf '%s\n' "$REC_FN" | mo_code)
src_has "the reconciler clears only the record it read"                  "$REC_CODE" 'if (Principal.equal(cur.cid, ps.cid)) { _pendingSpawn := null }'
src_lacks "the reconciler has no unconditional clear"                    "$REC_CODE" '_pendingSpawn := null;'
src_lacks "a failed cleanup keeps the record"                            "$(printf '%s\n' "$REC_CODE" | sed -n '/catch (e)/,$p')" '_pendingSpawn := null'
# (task 1788485539) the dev hold that makes the interleave testable sits
# BETWEEN the stop and delete awaits, is IS_DEV-gated in the reconciler
# itself, re-reads its knob every round (release ends it at once), and its
# hook is dev-gated. Live twin: test_archive_failover.sh §S (interleave).
REC_STOP_LN=$(printf '%s\n' "$REC_CODE" | grep -nF 'ic00.stop_canister' | head -1 | cut -d: -f1)
REC_HOLD_LN=$(printf '%s\n' "$REC_CODE" | grep -nF 'while (hold > 0 and _testSpawnReconcileHold > 0) { await async {}; hold -= 1 }' | head -1 | cut -d: -f1)
REC_DEL_LN=$(printf '%s\n' "$REC_CODE" | grep -nF 'ic00.delete_canister' | head -1 | cut -d: -f1)
if [ -n "$REC_STOP_LN" ] && [ -n "$REC_HOLD_LN" ] && [ -n "$REC_DEL_LN" ] && [ "$REC_STOP_LN" -lt "$REC_HOLD_LN" ] && [ "$REC_HOLD_LN" -lt "$REC_DEL_LN" ]; then _ok "the reconciler's test hold sits between its stop and delete awaits (stop $REC_STOP_LN < hold $REC_HOLD_LN < delete $REC_DEL_LN)"
else _fail "the reconciler's test hold must sit between stop and delete (stop ${REC_STOP_LN:-none}, hold ${REC_HOLD_LN:-none}, delete ${REC_DEL_LN:-none}) — the interleave test exercises exactly that window"; fi
src_has "the reconciler's hold is IS_DEV-gated in place (0 rounds on every other posture)" "$REC_CODE" 'var hold = if (IS_DEV) _testSpawnReconcileHold else 0;'
# (task 1788507866) the reconciler is SINGLE-FLIGHT: the heartbeat runs it
# once a minute regardless of setTestTimersPaused, so a second entry during
# the first's stop/delete awaits read the same orphan and double-deleted it —
# the second delete failed "not found" into a level-"error" recover-by-hand
# line for a canister that no longer existed. Pins mirror the spawnArchive
# latch above: a transient latch raised BEFORE ic00.stop_canister (before the
# first await), the second entry returns at it, it is released in finally,
# and that finally is its only clearing writer (the W4-13 one-owner shape).
# Live twin: test_archive_failover.sh §S (single-flight).
REC_LATCH_LN=$(printf '%s\n' "$REC_CODE" | grep -nF '_spawnReconcileInFlight := true' | head -1 | cut -d: -f1)
if [ -n "$REC_LATCH_LN" ] && [ -n "$REC_STOP_LN" ] && [ "$REC_LATCH_LN" -lt "$REC_STOP_LN" ]; then _ok "the reconciler's in-flight latch is raised BEFORE stop_canister (latch $REC_LATCH_LN < stop $REC_STOP_LN)"
else _fail "the reconciler's in-flight latch must precede stop_canister (latch line ${REC_LATCH_LN:-none}, stop line ${REC_STOP_LN:-none}) — a sibling entering during the awaits double-deletes"; fi
src_has "a second reconciler entry returns at the latch"                  "$REC_CODE" 'if (_spawnReconcileInFlight) { return }'
src_has "the reconciler's latch is released in finally"                   "$REC_CODE" '} finally {'
src_has "the reconciler's latch release is the finally body"              "$REC_CODE" '_spawnReconcileInFlight := false;'
REC_LATCH_CLEARS=$(printf '%s\n' "$MAIN_MO_CODE" | grep -cF "_spawnReconcileInFlight := false")
if [ "$REC_LATCH_CLEARS" = "1" ]; then _ok "_spawnReconcileInFlight has exactly one writer clearing it (its own finally)"
else _fail "_spawnReconcileInFlight cleared at $REC_LATCH_CLEARS sites — it has one owner (a second clear frees the slot under a live reconciler)"; fi
HOLD_HOOK_FN=$(mo_func src/backend/main.mo "func setTestSpawnReconcileHold(")
[ -n "$HOLD_HOOK_FN" ] || _fail "could not extract setTestSpawnReconcileHold()"
src_has "the reconcile-hold hook is dev-gated"                            "$HOLD_HOOK_FN" 'requireDevHook("setTestSpawnReconcileHold")'
src_has "the reconcile-hold hook is capped (no unbounded parked reconciler)" "$HOLD_HOOK_FN" 'Nat.min(rounds, 30_000)'
SLOT_FN=$(mo_func src/backend/main.mo "func spawnSlotBusy(")
[ -n "$SLOT_FN" ] || _fail "could not extract spawnSlotBusy()"
src_lacks "a refusal arms no failure cooldown (the slot clears itself)"   "$(printf '%s\n' "$SLOT_FN" | mo_code)" '_spawnRetryAfterNs'
src_has  "a refusal is logged with the occupant"                          "$(printf '%s\n' "$SLOT_FN" | mo_code)" '"ARCHIVE SPAWN (" # site # "): refused — slot occupied by " # h'
TICK_SHIP_SLOT=$(mo_func src/backend/main.mo "func tickShipEvents(")
[ -n "$TICK_SHIP_SLOT" ] || _fail "could not extract tickShipEvents()"
TICK_SHIP_SLOT_CODE=$(printf '%s\n' "$TICK_SHIP_SLOT" | mo_code)
src_has "the initial spawn asks the busy guard first"                    "$TICK_SHIP_SLOT_CODE" 'if (spawnSlotBusy("initial")) { return }'
src_has "the successor pre-spawn asks the busy guard"                    "$TICK_SHIP_SLOT_CODE" 'and not spawnSlotBusy("successor")'
ROLL_FN=$(mo_func src/backend/main.mo "func emergencyRollArchive(")
[ -n "$ROLL_FN" ] || _fail "could not extract emergencyRollArchive()"
src_has "the failover spawn asks the busy guard"                         "$(printf '%s\n' "$ROLL_FN" | mo_code)" 'if (spawnSlotBusy("failover")) { return false }'
WIPE_SLOT_FN=$(mo_func src/backend/main.mo "func performWorldWipe(")
[ -n "$WIPE_SLOT_FN" ] || _fail "could not extract performWorldWipe()"
src_lacks "the wipe leaves the spawn record to the reconciler"            "$(printf '%s\n' "$WIPE_SLOT_FN" | mo_code)" '_pendingSpawn'
ORPHAN_HOOK_FN=$(mo_func src/backend/main.mo "func setTestSpawnOrphan(")
[ -n "$ORPHAN_HOOK_FN" ] || _fail "could not extract setTestSpawnOrphan()"
src_has "the orphan hook is dev-gated"                                   "$ORPHAN_HOOK_FN" 'requireDevHook("setTestSpawnOrphan")'
src_has "the orphan hook obeys the busy guard"                           "$ORPHAN_HOOK_FN" 'return #err("spawn slot occupied")'
PLANT_HOOK_FN=$(mo_func src/backend/main.mo "func setTestPendingSpawn(")
[ -n "$PLANT_HOOK_FN" ] || _fail "could not extract setTestPendingSpawn()"
src_has "the plant hook is dev-gated"                                    "$PLANT_HOOK_FN" 'requireDevHook("setTestPendingSpawn")'
src_has "the plant hook refuses a routed segment"                        "$PLANT_HOOK_FN" 'is a routed archive segment of this exchange'
src_has "the plant hook refuses this canister"                           "$PLANT_HOOK_FN" 'refusing to plant this canister as its own orphan'
src_has "getCanisterInfo lists the spawn slot"                           "$(cat src/backend/main.mo)" 'pendingSpawn         = switch (_pendingSpawn)'

# ── 6y. Oracle writer discipline (#55 "fallback clock rewinds" + "epoch guard on one caller", task 1788465036) ──
# W3-06's monotonic-in-sample-time guard protected the AGGREGATE apply only:
# the XRC fallback writer re-stamped the mark with the anchor's pricing minute
# without comparing it to the standing mark, so a below-floor fan-out a second
# after an eight-source apply moved the mark to an OLDER single-source value
# and its clock back ~90s — after which a straggling primary sampled between
# the two passed the guard, the overwrite W3-06 refuses. And W4-13's oracle
# epoch compare sat in ONE caller (tickPriceRefresh) AFTER
# refreshMultiSourcePrice had already written lastAggregates/_lastOracleSrc;
# the GEPTOR and admin callers had none. Pins: the fallback arm refuses an
# anchor whose effective clock is at or before the mark, BEFORE the breaker
# sees it; the callee captures the epoch before its first await and compares
# before its first side-map write; that capture is the only one (no caller
# re-derives it); the bump hook is dev-gated. Live twin:
# tests/test_oracle_time_bases.sh §2 (the rewind refused) + §4 (the bump
# staged inside a live fan-out leaves lastAggregates untouched).
APPLY_FN=$(mo_func src/backend/main.mo "func applyFreshAggregate(")
[ -n "$APPLY_FN" ] || _fail "could not extract applyFreshAggregate()"
APPLY_CODE=$(printf '%s\n' "$APPLY_FN" | mo_code)
src_has "the fallback writer refuses an anchor at or before the mark"   "$APPLY_CODE" 'if (xrcAnchorEffectiveNs(a) <= p.refPriceUpdatedNs) {'
REWIND_LN=$(printf '%s\n' "$APPLY_CODE" | grep -nF 'if (xrcAnchorEffectiveNs(a) <= p.refPriceUpdatedNs) {' | head -1 | cut -d: -f1)
FB_BRK_LN=$(printf '%s\n' "$APPLY_CODE" | grep -nF 'acceptOrPendPrice(baseToken, p.refPrice, a.rateE8, xrcAnchorEffectiveNs(a))' | head -1 | cut -d: -f1)
if [ -n "$REWIND_LN" ] && [ -n "$FB_BRK_LN" ] && [ "$REWIND_LN" -lt "$FB_BRK_LN" ]; then _ok "the rewind guard precedes the breaker (a rewinding anchor pends nothing)"
else _fail "the rewind guard must precede acceptOrPendPrice in the fallback arm (guard ${REWIND_LN:-none}, breaker ${FB_BRK_LN:-none})"; fi
# H-37 (F34): the fetch is a FAN-OUT — openPriceFanout captures the epoch
# (before the fleet's first send), the per-source self-calls record into it,
# and finalizePriceFanout (whichever message reaches quorum, completion or
# the deadline) compares the epoch BEFORE its side-map writes; the late-
# attach path compares it too. The same property, on the new structure:
# capture once at dispatch, compare before every write, abandon unwritten.
OPEN_FN=$(mo_func src/backend/main.mo "func openPriceFanout(")
[ -n "$OPEN_FN" ] || _fail "could not extract openPriceFanout()"
OPEN_CODE=$(printf '%s\n' "$OPEN_FN" | mo_code)
src_has "the dispatcher captures the oracle epoch"                       "$OPEN_CODE" 'let oracleEpoch = _oracleEpoch;'
src_has "the captured epoch rides the fan-out"                            "$OPEN_CODE" 'id = _fanoutSeq; asset; dispatchNs; oracleEpoch;'
src_lacks "the dispatcher sends nothing itself (state only — arm/stamp and dispatch commit together)" "$OPEN_CODE" 'fetchAndRecord('
FIN_FN=$(mo_func src/backend/main.mo "func finalizePriceFanout(")
[ -n "$FIN_FN" ] || _fail "could not extract finalizePriceFanout()"
FIN_CODE=$(printf '%s\n' "$FIN_FN" | mo_code)
src_has "the finalizer compares the epoch"                                "$FIN_CODE" 'if (_oracleEpoch != oracleEpoch) {'
FIN_CMP_LN=$(printf '%s\n' "$FIN_CODE" | grep -nF 'if (_oracleEpoch != oracleEpoch) {' | head -1 | cut -d: -f1)
FIN_WRITE_LN=$(printf '%s\n' "$FIN_CODE" | grep -nF 'Map.add(lastAggregates' | head -1 | cut -d: -f1)
FIN_SRC_LN=$(printf '%s\n' "$FIN_CODE" | grep -nF 'Map.add(_lastOracleSrc' | head -1 | cut -d: -f1)
FIN_APPLY_LN=$(printf '%s\n' "$FIN_CODE" | grep -nF 'applyFreshAggregate(mkt, asset, agg, now, f.dispatchNs)' | head -1 | cut -d: -f1)
if [ -n "$FIN_CMP_LN" ] && [ -n "$FIN_WRITE_LN" ] && [ -n "$FIN_SRC_LN" ] && [ -n "$FIN_APPLY_LN" ] && [ "$FIN_CMP_LN" -lt "$FIN_WRITE_LN" ] && [ "$FIN_CMP_LN" -lt "$FIN_SRC_LN" ] && [ "$FIN_CMP_LN" -lt "$FIN_APPLY_LN" ]; then _ok "the side-map writes (lastAggregates, _lastOracleSrc) and the apply come AFTER the compare"
else _fail "every side-map write and the apply must follow the epoch compare (compare ${FIN_CMP_LN:-none}, lastAggregates ${FIN_WRITE_LN:-none}, _lastOracleSrc ${FIN_SRC_LN:-none}, apply ${FIN_APPLY_LN:-none})"; fi
src_has "an abandoned fan-out reports the abandonment per market"        "$FIN_CODE" '#abandoned("oracle epoch moved during the fetch — result abandoned")'
src_has "an abandoned fan-out still releases its guards"                  "$FIN_CODE" 'releaseFanoutGuards(f);'
src_has "the fan-out's dispatch clock is the release reference (H-23)"   "$FIN_CODE" 'applyFreshAggregate(mkt, asset, agg, now, f.dispatchNs)'
LATE_FN=$(mo_func src/backend/main.mo "func attachLateReading(")
[ -n "$LATE_FN" ] || _fail "could not extract attachLateReading()"
src_has "the late-attach path compares the epoch before its write"       "$(printf '%s\n' "$LATE_FN" | mo_code)" 'if (_oracleEpoch != f.oracleEpoch) { return };'
src_lacks "a late reading never re-applies the mark"                      "$(printf '%s\n' "$LATE_FN" | mo_code)" 'applyFreshAggregate('
EPOCH_CAPS=$(printf '%s\n' "$MAIN_MO_CODE" | grep -cF 'let oracleEpoch = _oracleEpoch')
if [ "$EPOCH_CAPS" = "1" ]; then _ok "the dispatcher's capture is the only epoch capture (no caller re-derives its own)"
else _fail "expected exactly one 'let oracleEpoch = _oracleEpoch' (the dispatcher), found $EPOCH_CAPS"; fi
TICK_ORC_FN=$(mo_func src/backend/main.mo "func tickPriceRefresh(")
[ -n "$TICK_ORC_FN" ] || _fail "could not extract tickPriceRefresh()"
src_has "the tick joins the asset's open fan-out (one fleet per asset)"  "$(printf '%s\n' "$TICK_ORC_FN" | mo_code)" 'openPriceFanout(p.baseToken, id, #tick, now, true)'
src_lacks "the tick awaits no fetch (every pool's fleet is in flight at once)" "$(printf '%s\n' "$TICK_ORC_FN" | mo_code)" 'await fetch'
# The shared in-flight stamp (tasks 3088525590 + 1788535668, folded into the
# fan-out by H-37): the admin fetch stamps _fetchInFlight beside the tick, and
# every release goes through the guarded delete keyed by the stamp the fan-out
# dispatched with (clearFetchInFlight) — never a whole-map clear, which let the
# commit lock go for a concurrent fetch's remainder. The tick no longer awaits
# (no finally, no live-stamp tracking to pin); the fan-out's guard release is
# the one site, for the tick's and the admin's stamps alike.
src_lacks "no whole-map clear of the in-flight stamps anywhere in main.mo" "$MAIN_MO_CODE" 'Map.clear(_fetchInFlight)'
REL_FN=$(mo_func src/backend/main.mo "func releaseFanoutGuards(")
[ -n "$REL_FN" ] || _fail "could not extract releaseFanoutGuards()"
src_has "the fan-out releases the tick's stamp through the guarded delete"    "$(printf '%s\n' "$REL_FN" | mo_code)" 'case (#tick)  { clearFetchInFlight(m, f.dispatchNs) };'
src_has "the fan-out releases the admin fetch's stamp through the guarded delete" "$(printf '%s\n' "$REL_FN" | mo_code)" 'case (#admin) { clearFetchInFlight(m, f.dispatchNs) };'
GEP_ORC_FN=$(mo_func src/backend/main.mo "func geptorFetchAndSweep(")
[ -n "$GEP_ORC_FN" ] || _fail "could not extract geptorFetchAndSweep()"
src_has "the GEPTOR's fan-out is its own, keyed to its arm (dispatch clock = armedAt)" "$(printf '%s\n' "$GEP_ORC_FN" | mo_code)" 'openPriceFanout(baseToken, marketId, #geptor(armedAt), armedAt, false)'
ADM_ORC_FN=$(mo_func src/backend/main.mo "func fetchAndSetRefPrice(")
[ -n "$ADM_ORC_FN" ] || _fail "could not extract fetchAndSetRefPrice()"
src_has "the admin fetch reports the abandonment"                        "$(printf '%s\n' "$ADM_ORC_FN" | mo_code)" 'case (?#abandoned(why)) { #err(why) };'
src_has "the admin fetch drains its own fleet (never joins)"             "$(printf '%s\n' "$ADM_ORC_FN" | mo_code)" 'openPriceFanout(baseToken, marketId, #admin, dispatchNs, false)'
src_has "the admin fetch stamps the shared in-flight map before its first send (3088525590)" "$(printf '%s\n' "$ADM_ORC_FN" | mo_code)" 'Map.add(_fetchInFlight, Text.compare, marketId, dispatchNs);'
src_has "the admin fetch closes a fan-out its whole fleet left open"     "$(printf '%s\n' "$ADM_ORC_FN" | mo_code)" 'if (PriceFeed.fanoutClose(f.st, #drained)) { finalizePriceFanout(f, #drained, Time.now()) };'
# task 1788748485: the ONE exception to the drain is the #dev `devStallSource
# #hold` — the fan-out (and the in-flight stamp) is left to the deadline
# sweep so a test can stage into an 8s window on a responsive replica. The
# gate is posture-gated (false on #play/#production: the drain is byte-
# identical there), the call says so instead of reading a missing outcome,
# and the retired self-message hold loop (it starved pocket-ic's request
# serving for the whole hold) must not come back.
src_has "the drain is skipped only under the #dev hold (the fan-out is the sweep's)" "$(printf '%s\n' "$ADM_ORC_FN" | mo_code)" 'if (not devHoldsFanoutOpen()) {'
src_has "an admin fetch whose fan-out was left open says so (no outcome to read)" "$(printf '%s\n' "$ADM_ORC_FN" | mo_code)" 'if (fanoutIsOpen(f)) {'
HOLD_FN=$(mo_func src/backend/main.mo "func devHoldsFanoutOpen(")
[ -n "$HOLD_FN" ] || _fail "could not extract devHoldsFanoutOpen()"
src_has "the hold gate is posture-gated (false off #dev)"                "$(printf '%s\n' "$HOLD_FN" | mo_code)" 'if (not IS_DEV) { return false };'
src_lacks "no self-message hold loop parks a fan-out self-call (the replica-starving shape)" "$MAIN_MO_CODE" 'DEV_HOLD_MAX_NS'
# The deadline sweep sits ABOVE the heartbeat's pause gate: it completes
# fetches already dispatched (exactly what the awaits it replaced did under
# a pause), so a braked venue still lands its in-flight marks and releases
# its guards — and never past PRICE_FANOUT_DEADLINE_NS + a beat.
HB_FN=$(mo_func src/backend/main.mo "system func heartbeat()")
[ -n "$HB_FN" ] || _fail "could not extract heartbeat()"
HB_CODE=$(printf '%s\n' "$HB_FN" | mo_code)
HB_SWEEP_LN=$(printf '%s\n' "$HB_CODE" | grep -nF 'sweepPriceFanouts(now)' | head -1 | cut -d: -f1)
HB_GATE_LN=$(printf '%s\n' "$HB_CODE" | grep -nF 'if (timersHeld()) { return };' | head -1 | cut -d: -f1)
if [ -n "$HB_SWEEP_LN" ] && [ -n "$HB_GATE_LN" ] && [ "$HB_SWEEP_LN" -lt "$HB_GATE_LN" ]; then _ok "the fan-out deadline sweep sits above the heartbeat's pause gate"
else _fail "sweepPriceFanouts must precede the pause gate in heartbeat (sweep ${HB_SWEEP_LN:-none}, gate ${HB_GATE_LN:-none}) — a braked venue would otherwise hold its guards to the GEPTOR TTL"; fi
src_has "the deadline is well under the staging window"                  "$MAIN_MO_CODE" 'transient let PRICE_FANOUT_DEADLINE_NS : Int = 8_000_000_000;'
BUMP_FN=$(mo_func src/backend/main.mo "func devBumpOracleEpoch(")
[ -n "$BUMP_FN" ] || _fail "could not extract devBumpOracleEpoch()"
src_has "the epoch bump hook is dev-gated"                              "$BUMP_FN" 'requireDevHook("devBumpOracleEpoch")'
src_has "the epoch bump hook is controller-only"                        "$BUMP_FN" 'requireController(msg.caller);'

# ── 6z. lint-ratchet keeps a toolchain-version miss apart from a broken tree (#51 follow-up item 4, task 1788465048) ──
# A mops-CLI / ic-wasm pin miss used to set the same `fail=1` a type error
# sets, and the Candid step gates on `fail` — so on any machine with either
# version off, the additive-only subtype check W5-07/08 hardened never ran
# ("skipping candid gate — fix the failures above first"), and the exit on
# offer was --no-verify. Now two classes, two variables: section 0 sets ONLY
# `toolfail`, the tree checks set ONLY `fail`, the Candid gate still keys on
# `fail` alone (its inputs are the pinned moc from mops.toml plus the tree —
# the CLI/ic-wasm pins govern neither), each miss prints its `install:` line,
# and the exit carries both bits (1 tree, 2 toolchain, 3 both). Structural
# pins on the slice + gate + exit, a README cross-check that the install
# lines name the SAME versions the script pins, and a BEHAVIOURAL run of the
# real section-0 code under a spoofed `ic-wasm --version` — the output shape
# the remedy depends on.
LR_CODE=$(uncommented scripts/lint-ratchet.sh)
LR_TOOL=$(sed -n '/^# ── 0\. TOOLCHAIN INTEGRITY/,/^# The project.s REAL build flags/p' scripts/lint-ratchet.sh)
[ -n "$LR_TOOL" ] || _fail "§6z: could not slice lint-ratchet's section 0 (the '0. TOOLCHAIN INTEGRITY' / 'REAL build flags' markers moved?)"
LR_TOOL_CODE=$(printf '%s\n' "$LR_TOOL" | sed 's/^[[:space:]]*#.*//')
src_has "§6z: section 0 records a toolchain miss in its own variable" "$LR_TOOL_CODE" 'toolfail=1'
grep_count TREE_SETS "$LR_TOOL_CODE" '(^|[^[:alnum:]_])fail=1'
if [ "${TREE_SETS:-0}" -eq 0 ]; then _ok "§6z: section 0 never sets the tree class (no bare fail=1)"
else _fail "§6z: lint-ratchet's toolchain section sets fail=1 $TREE_SETS time(s) — a pin miss would again skip the candid gate"; fi
TOOL_SETS=$(printf '%s\n' "$LR_CODE" | grep -c 'toolfail=1' || true)
if [ "${TOOL_SETS:-0}" -eq 3 ]; then _ok "§6z: exactly three toolchain sites set toolfail=1 (lock re-hash, mops CLI, ic-wasm)"
else _fail "§6z: expected 3 'toolfail=1' sites in lint-ratchet (lock, mops CLI, ic-wasm), found ${TOOL_SETS:-0} — a tree check leaked into the toolchain class, or a pin lost its miss branch"; fi
src_has "§6z: the candid gate keys on the tree class alone"           "$LR_CODE" 'if [ "$fail" -eq 0 ]; then'
src_lacks "§6z: no gate keys on the toolchain class"                  "$LR_CODE" 'if [ "$toolfail" -eq 0 ]'
src_has "§6z: the tree-skip message is still the TREE skip"           "$LR_CODE" 'skipping candid gate — fix the failures above first'
src_has "§6z: the mops CLI miss names its install line"               "$LR_CODE" 'MOPS_CLI_INSTALL="npm install -g ic-mops@$MOPS_CLI_PIN"'
src_has "§6z: the ic-wasm miss names its install line"                "$LR_CODE" 'IC_WASM_INSTALL="cargo install ic-wasm --version $IC_WASM_PIN"'
src_has "§6z: the ic-wasm miss prints it"                             "$LR_TOOL_CODE" 'install: $IC_WASM_INSTALL'
src_has "§6z: the mops CLI miss prints it"                            "$LR_TOOL_CODE" 'install: $MOPS_CLI_INSTALL'
src_has "§6z: the subtype step says so when it ran through an unpinned mops CLI" "$LR_CODE" 'note: that subtype check ran through mops CLI'
src_has "§6z: the toolchain verdict is its own line"                  "$LR_CODE" 'lint-ratchet: TOOLCHAIN MISMATCH — install the pinned versions named above'
src_has "§6z: the tree verdict keeps its own line"                    "$LR_CODE" 'lint-ratchet: FAIL — the tree has failures above'
src_lacks "§6z: the toolchain verdict does not invite --no-verify"    "$(printf '%s\n' "$LR_CODE" | grep -F 'TOOLCHAIN MISMATCH')" 'no-verify'
src_has "§6z: the exit code carries both classes as separate bits"    "$LR_CODE" 'exit $(( fail + 2 * toolfail ))'
# README cross-check: the prerequisites name the same versions in the same
# install lines the script prints. Values come FROM the script, so a pin bump
# that forgets the README fails here rather than drifting.
LR_MOPS_PIN=$(printf '%s\n' "$LR_CODE" | grep -oE '^MOPS_CLI_PIN="[0-9.]+"' | grep -oE '[0-9.]+')
LR_ICW_PIN=$(printf '%s\n' "$LR_CODE" | grep -oE '^IC_WASM_PIN="[0-9.]+"' | grep -oE '[0-9.]+')
README_SRC=$(cat README.md)
[ -n "$LR_MOPS_PIN" ] && [ -n "$LR_ICW_PIN" ] || _fail "§6z: could not read MOPS_CLI_PIN / IC_WASM_PIN out of lint-ratchet (mops='${LR_MOPS_PIN:-}' ic-wasm='${LR_ICW_PIN:-}')"
src_has "§6z: README names the mops CLI pin ($LR_MOPS_PIN) in its install line" "$README_SRC" "npm install -g ic-mops@$LR_MOPS_PIN"
src_has "§6z: README names the ic-wasm pin ($LR_ICW_PIN) in its install line"   "$README_SRC" "cargo install ic-wasm --version $LR_ICW_PIN"
src_has "§6z: README describes the toolchain exit as distinct"                  "$README_SRC" "a *toolchain* verdict, distinct from a broken tree's exit 1"
# Behavioural: the REAL section-0 code, run in isolation (fail/toolfail
# seeded, the slice appended, both echoed after) under a PATH whose ic-wasm
# answers `--version` with a wrong number. The remedy-bearing lines must
# appear and the TREE class must stay untouched. `mops install --lock check`
# runs for real (seconds) — skip only when mops itself is absent.
if command -v mops >/dev/null 2>&1 && [ -n "$LR_TOOL" ]; then
  SPOOF_DIR=$(mktemp -d)
  printf '#!/usr/bin/env bash\necho "ic-wasm 9.9.9"\n' > "$SPOOF_DIR/ic-wasm"
  chmod +x "$SPOOF_DIR/ic-wasm"
  { printf 'set -u\nfail=0\ntoolfail=0\n'; printf '%s\n' "$LR_TOOL"; printf 'echo "classes: fail=$fail toolfail=$toolfail"\n'; } > "$SPOOF_DIR/sec0.sh"
  SPOOF_OUT=$(cd "$ROOT" && PATH="$SPOOF_DIR:$PATH" bash "$SPOOF_DIR/sec0.sh" 2>&1)
  rm -rf "$SPOOF_DIR"
  src_has "§6z: spoofed ic-wasm — the version line fails on its own, naming both versions" "$SPOOF_OUT" "✗ toolchain: ic-wasm is '9.9.9', pinned $LR_ICW_PIN"
  src_has "§6z: spoofed ic-wasm — the remedy is an install line"                          "$SPOOF_OUT" "install: cargo install ic-wasm --version $LR_ICW_PIN"
  src_has "§6z: spoofed ic-wasm — the output says the tree checks still run"              "$SPOOF_OUT" "toolchain mismatch is its own failure class"
  src_has "§6z: spoofed ic-wasm — the toolchain class is set"                             "$SPOOF_OUT" "toolfail=1"
  src_has "§6z: spoofed ic-wasm — the tree class stays clean (the candid gate would run)"  "$SPOOF_OUT" "classes: fail=0 toolfail=1"
else
  echo "  (mops unavailable — skipped the spoofed-ic-wasm behavioural proof)"
fi

# ── 6aa. In-suite Bridge rebuilds are posture-aware, and typed results are judged by their tag (task 1788474497) ──
# `icp deploy bridge` BUILDS from the tree. On a factory seat the tree sits at
# #play between deploys while the venue runs #dev, so ONE bare deploy inside
# a suite (test_deposit_ledger_guard §5) flipped the venue's Bridge to #play
# and every later Bridge-hook suite went red for a reason that was not code;
# `icp canister install --mode upgrade` does not rebuild and so inherits
# whatever posture the last build had. And `grep -q "ok"` matched the word
# "hook" inside a dev-hook REFUSAL, turning a refused hold into a green line.
# Both now live in ONE place each (tests/_lib.sh): the posture-equality guard
# every in-suite Bridge upgrade goes through, and the variant-tag matcher
# every #ok judgement uses. Structural pins on the helpers, a ban scan across
# the Bridge/deposit/season family, and a BEHAVIOURAL run of each: the
# matcher against the exact refusal shape, and the guard under a stubbed
# `icp` whose getDeployMode answer is chosen to match or mismatch the tree —
# it must build-then-install in one case and touch nothing in the other.
LIB_CODE=$(uncommented tests/_lib.sh)
src_has "§6aa: _lib.sh defines the one Bridge-upgrade guard"                   "$LIB_CODE" 'bridge_upgrade_if_posture_matches() {'
src_has "§6aa: the guard reads the VENUE Bridge's posture"                     "$LIB_CODE" "icp canister call bridge getDeployMode '()' --query --identity anonymous"
src_has "§6aa: the guard reads the TREE through the comment-aware reader"      "$LIB_CODE" 'mdx_posture_of "$1/src/bridge/main.mo"'
src_has "§6aa: the guard BUILDS before it installs (install never rebuilds)"    "$LIB_CODE" 'icp build bridge >/dev/null 2>&1'
src_has "§6aa: the guard installs --mode upgrade as the local controller"      "$LIB_CODE" 'icp canister install bridge --mode upgrade -y --identity anonymous'
src_has "§6aa: the guard's skip is the loud ⊘ marker naming both postures"     "$LIB_CODE" 'skip_section "$label (tree is #${tree:-?}, venue Bridge is #${venue:-?}'
src_has "§6aa: _lib.sh defines the variant-tag matcher"                        "$LIB_CODE" 'mdx_ok() {'
src_has "§6aa: the matcher keys on the tag, not the substring (via the lib's mdx_reply_ok — task 1788508007)" "$LIB_CODE" 'mdx_reply_ok "$reply"'
src_has "§6aa: assert_ok wraps it for the assert-style suites"                 "$LIB_CODE" 'assert_ok() {'
BRIDGE_FAMILY="tests/test_bridge_deposit_claim.sh tests/test_bridge_write_ahead.sh tests/test_deposit_ledger_guard.sh tests/test_season_seal.sh tests/test_season_wipe_fence.sh"
FAMILY_CODE=$(for f in $BRIDGE_FAMILY; do uncommented "$f"; done)
# The COMMAND scans read the code-only view (string-literal contents dropped —
# code_only, top of file): a skip_section message that names the command an
# operator must run by hand is guidance, not a suite running it (task
# 1788495525; a guidance string kept main 2-red here). The loose-"ok" scan
# below stays on $FAMILY_CODE — its needle IS a string's text.
FAMILY_CMDS=$(printf '%s\n' "$FAMILY_CODE" | code_only)
src_lacks "§6aa: the family's code-only view closes every literal (the command scan is trustworthy)" "$FAMILY_CMDS" "CODE_ONLY_UNTERMINATED_DQ"
src_lacks "§6aa: the family's code-only view closes every \$(...) (no multi-line capture runs to the file end)" "$FAMILY_CMDS" "CODE_ONLY_UNTERMINATED_SUBST"
src_lacks "§6aa: no suite deploys the Bridge from the tree directly"           "$FAMILY_CMDS" "icp deploy bridge"
src_lacks "§6aa: no suite builds the Bridge outside the guard"                 "$FAMILY_CMDS" "icp build bridge"
src_lacks "§6aa: no suite installs the Bridge outside the guard"               "$FAMILY_CMDS" "icp canister install bridge"
# code_only itself, behaviourally, through the exact scan path (uncommented |
# code_only) on a family-shaped fixture: the NEGATIVE control is a bare
# build line that must survive the strip and trip the ban; the positive case
# is the :298-shaped guidance string, which must not.
CO_DIR=$(mktemp -d)
cat > "$CO_DIR/family.sh" <<'CO_FIXTURE'
# don't read this: icp build bridge in a full-line comment (uncommented strips it)
skip_section "needs the Bridge at #dev (venue is #${BMODE:-?}) — \`icp build bridge\` + \`icp canister install bridge --mode upgrade\`, then rerun"
icp build bridge >/dev/null 2>&1
CO_FIXTURE
CO_VIEW=$(uncommented "$CO_DIR/family.sh" | code_only)
src_has   "§6aa: code_only NEGATIVE control — a bare build line still trips the ban"    "$CO_VIEW" "icp build bridge >/dev/null 2>&1"
src_lacks "§6aa: code_only — the guidance string's install command is not a hit"        "$CO_VIEW" "icp canister install bridge"
assert_eq "§6aa: code_only — the guidance string is scanned as an empty literal" 'skip_section ""' "$(printf '%s\n' "$CO_VIEW" | sed -n 2p)"
assert_eq "§6aa: code_only — the bare build line is untouched"                    'icp build bridge >/dev/null 2>&1' "$(printf '%s\n' "$CO_VIEW" | sed -n 3p)"
rm -rf "$CO_DIR"
# ...and the stripper's edge cases, one line each: an escaped quote inside a
# literal, two literals on one line, a literal spanning a $VAR expansion, a
# single-quoted literal, an apostrophe in a TRAILING comment (line-local: it
# strips the rest of its own line, nothing more), a $(...) inside "..." (bash
# runs it — kept), an UNESCAPED backtick inside "..." (also runs — kept), an
# unquoted escaped quote (code, kept), a literal spanning two lines (the code
# after its closing quote is scanned), and the unterminated-literal sentinel.
assert_eq "§6aa: code_only strips a literal with an escaped quote inside"  'echo ""'            "$(printf '%s\n' 'echo "say \"icp build bridge\" here"' | code_only)"
assert_eq "§6aa: code_only strips two literals on one line"                'echo "" ""'         "$(printf '%s\n' 'echo "icp build bridge" "icp canister install bridge"' | code_only)"
assert_eq "§6aa: code_only strips a literal spanning a \$VAR expansion"    'echo ""'            "$(printf '%s\n' 'echo "venue #${BMODE:-x} — icp build bridge"' | code_only)"
assert_eq "§6aa: code_only strips a single-quoted literal"                 "echo ''"            "$(printf '%s\n' "echo 'icp build bridge'" | code_only)"
assert_eq "§6aa: code_only — a trailing-comment apostrophe is line-local"  "icp build bridge # don'|next icp build bridge" "$(printf '%s\n' "icp build bridge # don't" 'next icp build bridge' | code_only | paste -sd'|' -)"
assert_eq "§6aa: code_only keeps a \$(...) inside a literal (bash runs it)" 'OUT="$(icp build bridge 2>&1)"' "$(printf '%s\n' 'OUT="$(icp build bridge 2>&1)"' | code_only)"
assert_eq "§6aa: code_only keeps an unescaped backtick inside a literal (bash runs it)" 'echo "`icp build bridge`"' "$(printf '%s\n' 'echo "`icp build bridge`"' | code_only)"
assert_eq "§6aa: code_only keeps an unquoted escaped quote as code"        'echo \"icp build bridge\"' "$(printf '%s\n' 'echo \"icp build bridge\"' | code_only)"
assert_eq "§6aa: code_only carries a literal across lines, then scans the code after it" 'msg="|"; icp build bridge' "$(printf '%s\n' 'msg="icp build bridge' 'still text"; icp build bridge' | code_only | paste -sd'|' -)"
assert_eq "§6aa: code_only flags a file that ends inside an open literal"  'x="|CODE_ONLY_UNTERMINATED_DQ' "$(printf '%s\n' 'x="never closed' | code_only | paste -sd'|' -)"
# ...and the $(...) copy's quote-awareness (task 1793512052), the pre-fix view
# being each case's negative control: an unbalanced `(` inside a nested quote
# inside "$(...)" ran the copy to the line end, swallowed the literal's closing
# quote and read the NEXT line inverted (its command vanished, the view gained
# the sentinel); a `)` inside a nested quote ended the copy early and hid the
# rest of the substitution (1793505604's early-cut case). The fixtures sit in
# top-level single quotes and the views in plain assignments, so the needles
# they carry are string content to the §6af census, never hits of their own.
CO_PAREN=$(printf '%s\n' 'L="$(grep -oE "(" f)"' 'icp build bridge' | code_only | paste -sd'|' -)
assert_eq "§6aa: code_only — an unbalanced ( inside a nested quote inside \$(...) never swallows the literal's closing quote (the next line's command survives)" 'L="$(grep -oE "(" f)"|icp build bridge' "$CO_PAREN"
CO_MOFN=$(printf '%s\n' 'FN="$(mo_func src/backend/main.mo "func seedInsuranceFund(" | mo_code)"' 'icp build bridge' | code_only | paste -sd'|' -)
assert_eq "§6aa: code_only — the mo_func signature shape (\"func x(\" inside \$(...)) keeps the next line's command" 'FN="$(mo_func src/backend/main.mo "func seedInsuranceFund(" | mo_code)"|icp build bridge' "$CO_MOFN"
CO_EARLY=$(printf 'OUT="$(sed \047s/ || true)/)/\047 f | icp build bridge)"\n' | code_only)
assert_eq "§6aa: code_only — a ) inside a nested quote inside \$(...) never ends the copy early (the substitution's trailing command stays in view)" 'OUT="$(sed '"'"'s/ || true)/)/'"'"' f | icp build bridge)"' "$CO_EARLY"
CO_NESTED=$(printf '%s\n' 'X="$(echo "$(cmd "a)b")" tail)"; echo "icp build bridge"' | code_only)
assert_eq "§6aa: code_only — a \$(...) nested inside a quoted argument of a \$(...) is copied whole" 'X="$(echo "$(cmd "a)b")" tail)"; echo ""' "$CO_NESTED"
# the four-line probe of 1793512052 (a multi-line literal whose second line
# carries the `(` needle): line 3 keeps its command, the view ends sane
CO_PROBE=$(printf '%s\n' 'L="x' '$(printf '"'"'%s\n'"'"' "$U" | grep -oE "(" | sed -E "s/a/b/")"' "echo \"code after\" | grep -nE 'hit'" 'X=$(grep -nE "later" f)' | code_only)
assert_eq "§6aa: code_only — the 1793512052 probe: the line after the ( needle keeps its command" "echo \"\" | grep -nE ''" "$(printf '%s\n' "$CO_PROBE" | sed -n 3p)"
src_lacks "§6aa: code_only — the 1793512052 probe's view ends without the sentinel" "$CO_PROBE" "CODE_ONLY_UNTERMINATED_DQ"
# ...and the carry across lines (task 1793513986): a "$(...)" whose closing )
# sits on a LATER line used to stop copying at the line end — the enclosing
# literal stayed open and the continuation lines read as its CONTENT, so a
# command on the second line of a two-line capture vanished from every command
# scan (the pre-fix view of the two-line fixture is X="$(cmd arg1 \|"; echo ""
# — the needle gone; the negative control is the pre-fix function driven from a
# scratch harness, an eval of its sed-sliced body). Now every level left open
# at the line end carries its nested-quote state and depth: the continuation
# lines are copied verbatim, the code after the closing quote is scanned as
# before, a nested "..." left open at the line end (the §6af
# extractor_status_probe shape, whose closing line used to RE-OPEN the literal
# and invert the two lines after it) and a nested $(...) left open (two levels)
# carry too, and a file that ends inside an open $( prints BOTH sentinels.
CO_TWO=$(printf '%s\n' 'X="$(cmd arg1 \' '  icp build bridge)"; echo "after"' | code_only | paste -sd'|' -)
src_has   "§6aa: code_only — a \$(...) spanning two lines keeps the second line's command in view (the family ban can see it)" "$CO_TWO" "icp build bridge"
assert_eq "§6aa: code_only — the two-line capture is copied verbatim and the code after its closing quote is still scanned" 'X="$(cmd arg1 \|  icp build bridge)"; echo ""' "$CO_TWO"
CO_CARRYQ=$(printf '%s\n' 'rc="$(bash -c "set -o pipefail' '$body' '$call >/dev/null; echo \$?" 2>/dev/null)"; echo "after"' | code_only | paste -sd'|' -)
assert_eq "§6aa: code_only — a nested \"...\" left open at the line end inside a \$(...) carries with it (the §6af probe shape; its third line closes both)" 'rc="$(bash -c "set -o pipefail|$body|$call >/dev/null; echo \$?" 2>/dev/null)"; echo ""' "$CO_CARRYQ"
CO_DEEP=$(printf '%s\n' 'X="$(echo "$(cmd a \' '  b)" tail)"; echo "after"' | code_only | paste -sd'|' -)
assert_eq "§6aa: code_only — a \$(...) nested inside a quoted argument and left open at the line end carries too (both levels resume)" 'X="$(echo "$(cmd a \|  b)" tail)"; echo ""' "$CO_DEEP"
assert_eq "§6aa: code_only flags a file that ends inside an open \$(...) with both sentinels" 'x="$(never closed|CODE_ONLY_UNTERMINATED_DQ|CODE_ONLY_UNTERMINATED_SUBST' "$(printf '%s\n' 'x="$(never closed' | code_only | paste -sd'|' -)"
for f in tests/test_deposit_ledger_guard.sh tests/test_bridge_write_ahead.sh tests/test_season_wipe_fence.sh; do
  src_has "§6aa: $(basename "$f") upgrades through the guard" "$(uncommented "$f")" 'bridge_upgrade_if_posture_matches "'
done
grep_count LOOSE_OK "$FAMILY_CODE" 'grep -q "[o]k"|grep -q [o]k( |$)|"[o]k"[[:space:]]*$'   # [o]k: the §7i ban reads this line too
if [ "${LOOSE_OK:-0}" -eq 0 ]; then _ok "§6aa: no loose \"ok\" substring judgement remains in the Bridge/deposit/season family"
else _fail "§6aa: $LOOSE_OK loose \"ok\" judgement(s) in the Bridge/deposit/season family — use mdx_ok / assert_ok (the substring matches \"hook\" in a dev-hook refusal)"; fi
# Behavioural, the matcher: the exact refusal shape must NOT read as #ok —
# and must still contain the substring, or this pin has gone vacuous.
REFUSAL='(variant { err = "devTestHoldAdmission is a dev-only hook (posture: play/production)" })'
if mdx_ok "$REFUSAL"; then _fail "§6aa: mdx_ok accepted a dev-hook refusal (the 'hook' false positive is back)"
else _ok "§6aa: mdx_ok rejects a dev-hook refusal"; fi
if printf '%s\n' "$REFUSAL" | grep -cF "ok" >/dev/null; then _ok "§6aa: ...which the old substring judgement would have accepted (the pin is live)"
else _fail "§6aa: the refusal fixture no longer contains the substring — this pin is vacuous, re-derive it"; fi
if mdx_ok '(variant { ok })'; then _ok "§6aa: mdx_ok accepts a unit #ok"; else _fail "§6aa: mdx_ok rejected '(variant { ok })'"; fi
if mdx_ok '(variant { ok = 150_000_000 : nat })'; then _ok "§6aa: mdx_ok accepts a valued #ok"; else _fail "§6aa: mdx_ok rejected a valued #ok"; fi
if mdx_ok "$(printf '(\n  variant {\n    ok = record {\n      admittedUnits = 0 : nat;\n    }\n  },\n)')"; then _ok "§6aa: mdx_ok accepts a pretty-printed record #ok"
else _fail "§6aa: mdx_ok rejected a pretty-printed record #ok (the flatten step regressed)"; fi
if mdx_ok '(variant { err = "ok" })'; then _fail "§6aa: mdx_ok accepted an #err whose text is \"ok\""; else _ok "§6aa: mdx_ok rejects an #err carrying the text \"ok\""; fi
# Behavioural, the guard: a stub `icp` answers getDeployMode with a chosen
# posture and RECORDS every other invocation. Matching the tree → build then
# install, in that order; mismatching → rc 1, the ⊘ naming both, and no
# build/install call at all. The tree's side is read the way the guard reads
# it, so this holds on a #play tree and on a seat's #dev flip alike. The stub
# dir is re-prepended AFTER sourcing _lib.sh, which itself prepends
# ~/.local/bin (where the real icp lives) — without that the probe would
# quietly run against the real venue and pass or fail for the wrong reason.
STUB_DIR=$(mktemp -d)
cat > "$STUB_DIR/icp" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *getDeployMode*) printf '("%s")\n' "$STUB_BRIDGE_POSTURE" ;;
  *) printf '%s\n' "$*" >> "$STUB_LOG" ;;
esac
EOF
chmod +x "$STUB_DIR/icp"
G_TREE=$(MPO src/bridge/main.mo)
G_OTHER=$([ "$G_TREE" = "dev" ] && echo play || echo dev)
G_LOG="$STUB_DIR/match.log"; : > "$G_LOG"
G_MATCH=$(cd "$ROOT" && PATH="$STUB_DIR:$PATH" STUB_BRIDGE_POSTURE="$G_TREE" STUB_LOG="$G_LOG" \
  STUB_DIR="$STUB_DIR" bash -c 'source tests/_lib.sh; PATH="$STUB_DIR:$PATH"; bridge_upgrade_if_posture_matches "§6aa probe"; echo "rc=$? note=$BRIDGE_UPGRADE_NOTE"' 2>&1)
src_has "§6aa: guard under a MATCHING venue posture (#$G_TREE) returns 0"       "$G_MATCH" "rc=0"
src_has "§6aa: ...and reports the rebuild"                                      "$G_MATCH" "note=bridge rebuilt + upgraded in place (tree #$G_TREE == venue #$G_TREE)"
G_BUILD=$(grep -nF 'build bridge' "$G_LOG" | head -1 | cut -d: -f1)
G_INST=$(grep -nF 'canister install bridge --mode upgrade -y --identity anonymous' "$G_LOG" | head -1 | cut -d: -f1)
[ -n "$G_BUILD" ] && _ok "§6aa: ...it built the Bridge" || _fail "§6aa: matching guard never built the Bridge: $(tr '\n' '|' < "$G_LOG")"
[ -n "$G_INST" ]  && _ok "§6aa: ...and installed it as an upgrade, as the local controller" || _fail "§6aa: matching guard never installed: $(tr '\n' '|' < "$G_LOG")"
if [ -n "$G_BUILD" ] && [ -n "$G_INST" ] && [ "$G_BUILD" -lt "$G_INST" ]; then _ok "§6aa: ...build precedes install (the wasm that lands is the tree's)"
else _fail "§6aa: build did not precede install (build line ${G_BUILD:-none}, install line ${G_INST:-none})"; fi
G_LOG="$STUB_DIR/mismatch.log"; : > "$G_LOG"
G_MIS=$(cd "$ROOT" && PATH="$STUB_DIR:$PATH" STUB_BRIDGE_POSTURE="$G_OTHER" STUB_LOG="$G_LOG" \
  STUB_DIR="$STUB_DIR" bash -c 'source tests/_lib.sh; PATH="$STUB_DIR:$PATH"; bridge_upgrade_if_posture_matches "§6aa probe"; echo "rc=$? note=$BRIDGE_UPGRADE_NOTE"' 2>&1)
src_has "§6aa: guard under a MISMATCHED venue posture (#$G_OTHER) returns 1"    "$G_MIS" "rc=1"
src_has "§6aa: ...with the loud ⊘ naming both postures"                         "$G_MIS" "⊘ skipped: §6aa probe (tree is #$G_TREE, venue Bridge is #$G_OTHER"
if grep_has "$(cat "$G_LOG")" 'build bridge|canister install bridge'; then _fail "§6aa: mismatched guard still built/installed: $(tr '\n' '|' < "$G_LOG")"
else _ok "§6aa: ...and neither built nor installed anything"; fi
rm -rf "$STUB_DIR"

# ── 6ab. A created pool that HOLDS a priced leg must be ENABLED (task 1788500129) ──
# tickPriceRefresh (src/backend/main.mo) refreshes ENABLED pools only, so a
# pool a fixture creates (createAmmPool + setAmmRefPrice) and never enables
# keeps its stamped mark forever. Once the vault holds that pool's base leg
# (seedAmmPool / depositLp with a non-zero base amount), vaultPricesStale
# refuses EVERY LP mint on the venue from 60s after the stamp ("LP deposit
# paused: <asset> refPrice is stale") — for the suite's later sections and
# for every suite that follows without a reset. Reproduced 2026-09-04 on a
# #dev seat venue: test_vault_weights green in 11s, every depositLp on the
# venue refused from +60s. Rule (tests/_lib.sh, Fixtures): enable the pool
# in the fixture, or deposit quote-only when the base leg is not needed.
# The scan is FILE-level: a suite that creates a pool AND mints with a
# non-zero (or variable) base leg must carry an enableAmm somewhere. A file
# whose base-leg "mint" is a refusal probe that never mints is exempted BY
# NAME with its reason, and the reason is re-checked, so the list cannot
# outlive it. Backend pins first: the property the rule rests on.
TPR_FN=$(mo_func src/backend/main.mo "func tickPriceRefresh()")
src_has "§6ab: tickPriceRefresh refreshes ENABLED pools only (the rule's cause)"   "$(printf '%s\n' "$TPR_FN" | mo_code)" 'if (p.enabled) {'
# Task 1788513125 factored the per-leg check out of vaultPricesStale into
# vaultHeldLegMarkIssue (shared by BOTH LP sides) and the refusal texts into
# vaultMarkIssueText; vaultPricesStale is now the deposit-side wrapper and
# vaultWithdrawPaused the redeem-side one (gated on NAV != holdings).
VHL_FN=$(mo_func src/backend/main.mo "func vaultHeldLegMarkIssue(")
VMT_FN=$(mo_func src/backend/main.mo "func vaultMarkIssueText(")
VPS_FN=$(mo_func src/backend/main.mo "func vaultPricesStale(")
VWP_FN=$(mo_func src/backend/main.mo "func vaultWithdrawPaused(")
WLP_FN=$(mo_func src/backend/main.mo "func performLpWithdraw(")   # task 1788503312: withdrawLp is a wrapper; the body is performLpWithdraw
src_has "§6ab: vaultHeldLegMarkIssue gates on the HELD balance, not the value"     "$(printf '%s\n' "$VHL_FN" | mo_code)" 'let held = vaultAssetBalance(vv, asset) > 0;'
src_has "§6ab: ...and a stale held leg pauses by name"                             "$(printf '%s\n' "$VMT_FN" | mo_code)" 'refPrice is stale'
src_has "§6ab: vaultPricesStale (deposit side) routes through the shared check"    "$(printf '%s\n' "$VPS_FN" | mo_code)" 'vaultHeldLegMarkIssue(now, vv)'
src_has "§6ab: vaultWithdrawPaused runs the same check only while NAV != holdings" "$(printf '%s\n' "$VWP_FN" | mo_code)" 'if (vv.totalQuoteValue == holdingsUsd) { return null };'
src_has "§6ab: withdrawLp refuses through vaultWithdrawPaused (task 1788513125)"   "$(printf '%s\n' "$WLP_FN" | mo_code)" 'vaultWithdrawPaused(Time.now(), vv, holdingsUsd)'
src_has "§6ab: the mint bar is the 60s LP_DEPOSIT_MAX_REF_AGE_NS"                   "$(cat src/backend/main.mo)" 'transient let LP_DEPOSIT_MAX_REF_AGE_NS : Int = 60_000_000_000;'
src_has "§6ab: _lib.sh carries the fixture rule"                                    "$(cat tests/_lib.sh)" 'a created pool that HOLDS a priced leg must be ENABLED'
src_has "§6ab: test_vault_weights enables the four pools it creates"                "$(uncommented tests/test_vault_weights.sh)" 'for m in BTC ETH SOL ICP; do adm enableAmm "(\"$m-ICPUSD\", true)" >/dev/null; done'
LP_HOLD_EXEMPT="test_authorization.sh"   # its anonymous seedAmmPool is an auth-REJECTION probe: nothing mints
src_has "§6ab: the exemption's reason still holds (test_authorization's seed is a rejection probe)" "$(uncommented tests/test_authorization.sh)" 'anonymous seedAmmPool rejected'
# lp_legs <uncommented suite text> → the BASE legs it mints, one per line: the
# argument after the market string through the raw doors (seedAmmPool /
# depositLp), or the third word after _lib.sh's mdx_lp_deposit (6.0.0:
# `mdx_lp_deposit <identity> <market> <base_e8> <quote_e8>`), with the
# literal-0 legs dropped. ONE copy, shared by the scan below and its negative
# control (task 1793507323), so the control drives the needles the scan runs.
lp_legs() {
  { printf '%s\n' "$1" | grep -E "(seedAmmPool|depositLp) +[\"']\(" | sed -E "s/.*(seedAmmPool|depositLp) +[\"']\([^,]*, *//" ;
    printf '%s\n' "$1" | grep -E 'mdx_lp_deposit +[^ ]+ +[^ ]+ +[^ ]' | sed -E 's/.*mdx_lp_deposit +[^ ]+ +[^ ]+ +//' ; } | grep -vE '^"?0"?( |:|$)' || true
}
LP_HOLD_BAD=""; LP_HOLD_N=0
for f in tests/test_*.sh; do
  [ "$f" = tests/test_deploy_hygiene.sh ] && continue   # carries the lp_legs control fixture, not a venue
  b=$(basename "$f")
  case " $LP_HOLD_EXEMPT " in *" $b "*) continue ;; esac
  code=$(uncommented "$f")
  printf '%s\n' "$code" | grep -cE 'createAmmPool' >/dev/null || continue
  # mint calls whose BASE argument is not a literal 0 (lp_legs, above)
  legs=$(lp_legs "$code")
  [ -n "$legs" ] || continue
  LP_HOLD_N=$((LP_HOLD_N + 1))
  printf '%s\n' "$code" | grep -cE 'enableAmm' >/dev/null || LP_HOLD_BAD="$LP_HOLD_BAD $b"
done
if [ -z "$LP_HOLD_BAD" ]; then _ok "§6ab: every suite that creates a pool and mints a base leg also enables it ($LP_HOLD_N suites scanned)"
else _fail "§6ab: created pool + base-leg mint with no enableAmm in:$LP_HOLD_BAD — the pool's mark freezes and 60s later every LP mint on the venue pauses; enable it in the fixture or deposit quote-only (tests/_lib.sh, Fixtures)"; fi
if [ "$LP_HOLD_N" -ge 25 ]; then _ok "§6ab: the scan still sees the base-leg fixtures ($LP_HOLD_N, floor 25)"
else _fail "§6ab: the scan matched only $LP_HOLD_N base-leg fixtures (floor 25) — the call shape moved and the rule went vacuous; re-derive the matcher"; fi
# negative control for the legs pipeline itself (task 1793507323): the SAME
# lp_legs over a fixture minting once through each door — a raw-door
# seedAmmPool, a raw-door depositLp, the lib's mdx_lp_deposit with a base leg,
# and a zero-base mdx_lp_deposit the zero filter must drop — yields exactly 3
# legs. A regex error (rc 2, read by a raw grep as "no match") in the raw-door
# needle yields 1, in the lib needle 2, in the zero filter 0: each reds here,
# where the floor 25 could not see it — 28 of the 31 suites arrive through the
# lib leg alone (this file's own needle text counted as a 32nd until the scan
# skipped it by name), so a dead raw-door needle left the scan green with the
# raw-door suites unscanned.
LP_LEGS_FX=$(scratch_new lp_legs_fixture.sh) || exit 1
cat > "$LP_LEGS_FX" <<'EOF'
adm seedAmmPool "(\"X/Y\", 5, 0)"
adm depositLp '("X/Y", 7, 0)'
mdx_lp_deposit alice X/Y 9 0
mdx_lp_deposit bob X/Y 0 5
EOF
grep_count LP_LEGS_N "$(lp_legs "$(uncommented "$LP_LEGS_FX")")" '.'
if [ "${LP_LEGS_N:-0}" -eq 3 ]; then _ok "§6ab negative control: lp_legs yields exactly 3 base legs on the four-mint fixture (seedAmmPool, depositLp, mdx_lp_deposit; the zero-base lib mint dropped)"
else _fail "§6ab negative control: lp_legs yielded ${LP_LEGS_N:-0} base legs on the four-mint fixture, expected 3 — a door's needle or the zero filter is broken (raw door → 1, lib → 2, zero filter → 0); the floor 25 cannot see a single lost door"; fi

# ── 6ac. H-29 (F45): pool ids never recycle; season federation reads the frozen owner map (task 1788467626) ──
# MarginPools.poolPrincipal is a pure function of the pool id and every
# archive segment indexes ledger rows by that principal forever, so a
# performWorldWipe that restarted nextPoolId at 1 made the next epoch's pool
# #k wear the prior season's pool #k principal — and the season federation
# (getMyArchivedEvents / archiveExecute), which built the caller's principal
# set from the CURRENT registry, handed the new owner the old owner's
# #delta/#debtDelta rows. Pin: (a) the wipe no longer resets the counter;
# (b) it freezes the season's owner map BEFORE clearing the registry (the
# order is the invariant — line numbers, not just the call); (c) both
# federation sites resolve principals per segment via archiveReadPrincipals,
# never by scanning marginPools; (d) the full wipe drops the map with the
# registry it keys.
H29_WIPE_FN=$(mo_func src/backend/main.mo "func performWorldWipe(")
[ -n "$H29_WIPE_FN" ] || _fail "could not extract performWorldWipe()"
H29_WIPE_CODE=$(printf '%s\n' "$H29_WIPE_FN" | mo_code)
src_lacks "§6ac: performWorldWipe no longer restarts nextPoolId"                     "$H29_WIPE_CODE" 'nextPoolId := 1'
src_has   "§6ac: performWorldWipe freezes the season's pool owner map"               "$H29_WIPE_CODE" 'Map.add(_seasonPoolOwners, Nat.compare, seasonNo, owners);'
src_has   "§6ac: the full wipe drops the owner map with the registry"                "$H29_WIPE_CODE" 'Map.clear(_seasonPoolOwners);'
H29_SNAP_LN=$(printf '%s\n' "$H29_WIPE_CODE" | grep -n 'Map.add(_seasonPoolOwners, Nat.compare, seasonNo, owners);' | head -1 | cut -d: -f1)
H29_CLR_LN=$(printf '%s\n' "$H29_WIPE_CODE" | grep -n 'Map.clear(marginPools);' | head -1 | cut -d: -f1)
if [ -n "$H29_SNAP_LN" ] && [ -n "$H29_CLR_LN" ] && [ "$H29_SNAP_LN" -lt "$H29_CLR_LN" ]; then _ok "§6ac: the owner map is frozen (line $H29_SNAP_LN) BEFORE the pool registry is cleared (line $H29_CLR_LN)"
else _fail "§6ac: the owner snapshot (${H29_SNAP_LN:-none}) does not precede Map.clear(marginPools) (${H29_CLR_LN:-none}) — it would freeze an empty map"; fi
H29_MINE_FN=$(mo_func src/backend/main.mo "func getMyArchivedEvents(")
[ -n "$H29_MINE_FN" ] || _fail "could not extract getMyArchivedEvents()"
H29_MINE_CODE=$(printf '%s\n' "$H29_MINE_FN" | mo_code)
src_has   "§6ac: getMyArchivedEvents resolves principals per segment (archiveReadPrincipals)" "$H29_MINE_CODE" 'archiveReadPrincipals(caller, season)'
src_lacks "§6ac: getMyArchivedEvents no longer scans the live registry"            "$H29_MINE_CODE" 'marginPools.entries()'
H29_EXEC_FN=$(mo_func src/backend/main.mo "func archiveExecute(")
[ -n "$H29_EXEC_FN" ] || _fail "could not extract archiveExecute()"
H29_EXEC_CODE=$(printf '%s\n' "$H29_EXEC_FN" | mo_code)
src_has   "§6ac: archiveExecute gives each season segment its own principal set"    "$H29_EXEC_CODE" 'archiveReadPrincipals(caller, ?sa.season)'
src_has   "§6ac: archiveExecute reads each hop with that hop's set"                 "$H29_EXEC_CODE" 'getEventsForPrincipals(hopPrincipals, off, 200)'
src_lacks "§6ac: archiveExecute no longer scans the live registry"                  "$H29_EXEC_CODE" 'marginPools.entries()'
H29_READ_FN=$(mo_func src/backend/main.mo "func archiveReadPrincipals(")
[ -n "$H29_READ_FN" ] || _fail "could not extract archiveReadPrincipals()"
src_has   "§6ac: a closed season resolves through the frozen owner map"             "$(printf '%s\n' "$H29_READ_FN" | mo_code)" 'Map.get(_seasonPoolOwners, Nat.compare, s)'
src_lacks "§6ac: a closed season never consults the live registry"                  "$(printf '%s\n' "$H29_READ_FN" | mo_code)" 'marginPools'
# ── 6ad. Suite identities LEAVE the store: one delete helper, the spelling that deletes (task 1788502454) ──
# `icp identity delete` takes NO --yes flag: that spelling fails on argument
# parsing (rc 2) and the trailing `|| true` swallowed it, so eight suites'
# "cleanup" never deleted anything — every store grew by one identity per
# suite name forever (the global store sits near the ~300-identity CMC
# mint-cap abort at network start) and a persisted identity carried the
# previous run's activity into the next run's "virgin" assertions. The CLI
# confirms on stdin (`echo y |`). tests/_lib.sh owns that spelling in
# mdx_identity_rm; mdx_identity_new mints a virgin identity, registers the
# delete through on_exit (a mid-suite `exit` still cleans up) and refuses a
# $(...) caller, where the registration would die with the subshell. The
# needles are spelled -[-]yes and mdx_identity_ne[w] so this file's own lines
# are exempt by construction; comment lines are stripped by uncommented.
LIB_ID=$(cat tests/_lib.sh)
src_has "§6ad: _lib.sh defines mdx_identity_rm on the confirm-by-pipe spelling"         "$LIB_ID" 'mdx_identity_rm() { echo y | icp identity delete "$1" >/dev/null 2>&1 || true; }'
src_has "§6ad: mdx_identity_new deletes any leftover before minting (a virgin principal)" "$LIB_ID" '  mdx_identity_rm "$1"'
src_has "§6ad: mdx_identity_new registers the delete through on_exit"                   "$LIB_ID" 'on_exit "mdx_identity_rm $(printf '"'"'%q'"'"' "$1")"'
src_has "§6ad: mdx_identity_new refuses a subshell caller (the on_exit would be lost)"   "$LIB_ID" 'if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then'
YES_HITS=""; SUB_HITS=""
for f in tests/*.sh; do
  grep_scan h "$(uncommented "$f")" 'identity delete .*-[-]yes'
  [ -n "$h" ] && YES_HITS="$YES_HITS $f:$(printf '%s\n' "$h" | head -1 | cut -d: -f1)"
  grep_scan h "$(uncommented "$f")" '\$\(mdx_identity_ne[w]'
  [ -n "$h" ] && SUB_HITS="$SUB_HITS $f:$(printf '%s\n' "$h" | head -1 | cut -d: -f1)"
done
if [ -z "$YES_HITS" ]; then _ok "§6ad: no suite spells the delete with the --yes flag (the silent no-op form) — deletes go through mdx_identity_rm"
else _fail "§6ad: the --yes flag on the delete is a silent no-op (rc 2, swallowed): identities accumulate in every store; use mdx_identity_rm / mdx_identity_new from tests/_lib.sh:$YES_HITS"; fi
if [ -z "$SUB_HITS" ]; then _ok "§6ad: no suite calls mdx_identity_new inside \$(...) (the on_exit cleanup would die with the subshell)"
else _fail "§6ad: mdx_identity_new inside \$(...) registers its on_exit in a subshell that discards it — call it as a statement, then principal_of:$SUB_HITS"; fi
ID_USERS=$(grep -lE '^[^#]*mdx_identity_new ' tests/test_*.sh | grep -v test_deploy_hygiene.sh | grep -c . || true)
if [ "${ID_USERS:-0}" -ge 11 ]; then _ok "§6ad: the helper is in use across the suites ($ID_USERS files, floor 11)"
else _fail "§6ad: only $ID_USERS suites call mdx_identity_new (floor 11: the eight census suites + price_collar, position_accounting, self_trade_prevention) — a suite went back to inline minting, or the call shape moved"; fi

# ── 6ae. Identity minting is HELPER-ONLY: no raw `icp identity new|delete` outside _lib.sh (task 1788503489) ──
# §6ad fixed the eight suites whose delete was a silent no-op; the LARGER
# population was never in that census: 41 suites carried a local `mkid()`
# (mint + principal, never delete) and ~30 more minted inline with
# `icp identity new X … || true`, so every store grew by one identity per
# suite name forever (the exec-a seat store held 125; the global store sits
# near the ~300-identity CMC mint-cap abort at network start), and a persisted
# principal carried one run's activity into the next run's "virgin"
# assertions. Every suite now goes through tests/_lib.sh: mdx_identity_new
# (virgin, deleted on EXIT) for its own actors, mdx_identity_ensure ONLY for
# the standing alice/bob/charlie/dave/eve (scripts/seed.sh's ensure_identity
# fixtures; run_tests.sh and deploy.sh mint the first three, 20+ suites sign
# with them — deleting them would break every later suite), and
# principal_of for the principal. The needles are spelled `identity ne[w]` /
# `identity delet[e]` / `mki[d]()` so this section's own scan lines are exempt
# by construction; comment lines are stripped by uncommented. This file is
# skipped as a whole nonetheless: §6ad and the src_has below must quote the
# helpers' LITERAL spelling to pin _lib.sh, and the failure messages name the
# banned shapes verbatim.
RAW_HITS=""; MKID_HITS=""; ENSURE_HITS=""
for f in tests/*.sh; do
  [ "$f" = tests/_lib.sh ] && continue
  [ "$f" = tests/test_deploy_hygiene.sh ] && continue
  grep_scan h "$(uncommented "$f")" 'icp identity (ne[w]|delet[e])'
  [ -n "$h" ] && RAW_HITS="$RAW_HITS $f:$(printf '%s\n' "$h" | head -1 | cut -d: -f1)"
  grep_scan h "$(uncommented "$f")" 'mki[d]\(\)'
  [ -n "$h" ] && MKID_HITS="$MKID_HITS $f:$(printf '%s\n' "$h" | head -1 | cut -d: -f1)"
  grep_scan h "$(uncommented "$f")" 'mdx_identity_ensur[e] '
  grep_filter h 'mdx_identity_ensur[e] (alice|bob|charlie)$|alice\|bob\|charlie\|dave\|eve\) mdx_identity_ensur[e] '
  [ -n "$h" ] && ENSURE_HITS="$ENSURE_HITS $f:$(printf '%s\n' "$h" | head -1 | cut -d: -f1)"
done
if [ -z "$RAW_HITS" ]; then _ok "§6ae: no suite mints or deletes an identity inline — every icp identity new/delete outside tests/_lib.sh is gone"
else _fail "§6ae: inline icp identity new/delete in a suite: the identity never leaves the store (or the delete is the silent no-op) — use mdx_identity_new NAME; X=\$(principal_of NAME) (mdx_identity_ensure only for alice/bob/charlie):$RAW_HITS"; fi
if [ -z "$MKID_HITS" ]; then _ok "§6ae: no suite carries a local mkid() (the mint-and-never-delete shape)"
else _fail "§6ae: a local mkid() is back — drop it, mint through mdx_identity_new:$MKID_HITS"; fi
if [ -z "$ENSURE_HITS" ]; then _ok "§6ae: mdx_identity_ensure names only the standing alice/bob/charlie (+ dave/eve in the five-trader seed set)"
else _fail "§6ae: mdx_identity_ensure on a non-standing name (not alice/bob/charlie, nor the five-trader seed set) persists a throwaway identity across runs — use mdx_identity_new:$ENSURE_HITS"; fi
src_has "§6ae: _lib.sh defines mdx_identity_ensure (create-if-absent, never delete) for the standing names" "$LIB_ID" 'mdx_identity_ensure() { icp identity new "$1" --storage plaintext >/dev/null 2>&1 || true; }'
ID_USERS2=$(grep -lE '^[^#]*mdx_identity_new ' tests/test_*.sh | grep -v test_deploy_hygiene.sh | grep -c . || true)
if [ "${ID_USERS2:-0}" -ge 75 ]; then _ok "§6ae: the helper carries the whole census ($ID_USERS2 suites, floor 75)"
else _fail "§6ae: only $ID_USERS2 suites call mdx_identity_new (floor 75: the §6ad eleven + the 41 mkid suites + the inline-mint suites) — a suite went back to inline minting, or the call shape moved"; fi
# ── §6af 1788507289: the seed/play reply oracles read icp's HASH-spelled #ok ─
# icp 1.2.0 fetches the canister's candid:service metadata per call; when the
# fetch misses transiently it prints "WARN could not fetch candid type,
# serializing arguments with inferred types." and spells a unit variant by its
# Candid field hash — idl_hash(name) = fold h*223+c: `ok` = 24_860, `err` =
# 5_048_165 (Rust-cased `Err` would be 3_456_837; this backend never emits
# it). On 2026-09-04 seed.sh read `(variant { 24_860 })` — a SUCCESSFUL
# createAmmPool — as a refusal and aborted a half-seeded venue. Two belts:
# every call passes the checked-in contract (`--candid candid/backend.did`),
# so the spelling never depends on the fetch; and the matchers accept the
# hashed ok. The matcher pin is a bash-level UNIT: the function body is
# sliced out of the live source and evaluated in a subshell, so it tests the
# code that runs, not a copy. Since task 1788503030 that source is the ONE
# shared copy, scripts/lib/reply.sh's mdx_reply_ok (seed.sh's seed_ok and
# play_start.sh's reply_ok were folded into it; §3d pins that the scripts
# source the lib and carry no private copy). A genuine #err — named or
# hashed — must still refuse: the abort is the point, the spelling is the bug.
# Task 1788508007 added the two remaining oracles: tests/_lib.sh's mdx_ok
# (every suite's #ok verdict — it ROUTES to the lib's mdx_reply_ok, which the
# sourced _lib.sh above puts in this shell, so the sliced body runs against
# the real predicate) and scripts/simulate_trading.sh's is_ok (the deliberate
# un-sourced copy live fleets run; §7i pins its needle literally). Each SPEC
# is `<file>:<fn>` and the function must be a column-0 multi-line definition
# (`^fn() {` … `^}`) or the slice is empty and the unit reports itself inert.
for SPEC in "scripts/lib/reply.sh:mdx_reply_ok" "tests/_lib.sh:mdx_ok" "scripts/simulate_trading.sh:is_ok"; do
  F=${SPEC%%:*}; FN=${SPEC#*:}
  BODY=$(sed -n "/^$FN() {/,/^}/p" "$F")
  if [ -z "$BODY" ]; then _fail "§6af: could not slice $FN() out of $F — the oracle moved or was renamed; the unit below is inert"; continue; fi
  for CASE in \
    "ok|(variant { ok })" \
    "ok|(variant { 24_860 })" \
    "ok|WARN could not fetch candid type, serializing arguments with inferred types. (variant { 24_860 })" \
    "ok|( variant { ok = 123_456 }, )" \
    "ok|( variant { 24_860 = 123_456 }, )" \
    "refuse|( variant { err = \"An AMM pool already exists for BTC-ICPUSD\" }, )" \
    "refuse|( variant { 5_048_165 = \"An AMM pool already exists for BTC-ICPUSD\" }, )" \
    "refuse|WARN could not fetch candid type, serializing arguments with inferred types. ( variant { 5_048_165 = \"refused\" }, )" \
    "refuse|( variant { 3_456_837 = \"Err-cased hash\" }, )" \
    "refuse|Error: The replica returned a rejection error: Caller is not a canister controller" \
    "refuse|()" ; do
    WANT=${CASE%%|*}; REPLY=${CASE#*|}
    if (eval "$BODY"; "$FN" "$REPLY") >/dev/null 2>&1; then GOT=ok; else GOT=refuse; fi
    if [ "$GOT" = "$WANT" ]; then _ok "§6af: $F $FN → $WANT on $(printf '%s' "$REPLY" | cut -c1-60)"
    else _fail "§6af: $F $FN answered $GOT, expected $WANT, on: $REPLY — icp spells a unit variant by hash (ok = 24_860) when its candid fetch misses; the oracle must accept ok/24_860 and refuse everything else"; fi
  done
done
# The bare-nat EXTRACTOR (task 1793496257): mdx_reply_nat_value answers on
# stdout — the digits of the LAST `(N : nat)`, underscores stripped, empty on
# any other shape — and mdx_reply_nat is defined as its non-emptiness, so
# this drives the ONE regex both the gate and the value rest on. Sliced the
# same way (column-0 multi-line); compared on stdout, not exit status.
NATV_BODY=$(sed -n '/^mdx_reply_nat_value() {/,/^}/p' scripts/lib/reply.sh)
if [ -z "$NATV_BODY" ]; then _fail "§6af: could not slice mdx_reply_nat_value() out of scripts/lib/reply.sh — the extractor moved or was renamed; the unit below is inert"
else
  for CASE in \
    "1234|(1_234 : nat)" \
    "|Error: The replica returned a rejection error: Caller is not a canister controller" ; do
    WANT=${CASE%%|*}; REPLY=${CASE#*|}
    GOT=$( (eval "$NATV_BODY"; mdx_reply_nat_value "$REPLY") 2>/dev/null )
    if [ "$GOT" = "$WANT" ]; then _ok "§6af: scripts/lib/reply.sh mdx_reply_nat_value → '${WANT:-<empty>}' on $(printf '%s' "$REPLY" | cut -c1-60)"
    else _fail "§6af: scripts/lib/reply.sh mdx_reply_nat_value answered '$GOT', expected '${WANT:-<empty>}', on: $REPLY — the extractor must yield the underscore-stripped N of the bare (N : nat) and NOTHING on any other shape (the gate mdx_reply_nat is its non-emptiness)"; fi
  done
fi
# The vault extractor (mdx_vault_nat) on stdout, the same way: the FIRST
# `<field> = N` of a record reply, underscores stripped, empty on an absent
# field (task 1793502104 — §6af drove only mdx_reply_nat_value's value
# until then).
VAULT_BODY=$(sed -n '/^mdx_vault_nat() {/,/^}/p' scripts/lib/reply.sh)
if [ -z "$VAULT_BODY" ]; then _fail "§6af: could not slice mdx_vault_nat() out of scripts/lib/reply.sh — the extractor moved or was renamed; the units below are inert"
else
  for CASE in \
    "1000|lpSupply|( record { lpSupply = 1_000 : nat; basket = record { btc = 2_500 : nat } }, )" \
    "2500|btc|( record { lpSupply = 1_000 : nat; basket = record { btc = 2_500 : nat } }, )" \
    "|lpSupply|( record { basket = record { btc = 2_500 : nat } }, )" \
    "|lpSupply|Error: The replica returned a rejection error: Caller is not a canister controller" ; do
    WANT=${CASE%%|*}; REST=${CASE#*|}; FIELD=${REST%%|*}; REPLY=${REST#*|}
    GOT=$( (eval "$VAULT_BODY"; mdx_vault_nat "$REPLY" "$FIELD") 2>/dev/null )
    if [ "$GOT" = "$WANT" ]; then _ok "§6af: scripts/lib/reply.sh mdx_vault_nat $FIELD → '${WANT:-<empty>}' on $(printf '%s' "$REPLY" | cut -c1-60)"
    else _fail "§6af: scripts/lib/reply.sh mdx_vault_nat $FIELD answered '$GOT', expected '${WANT:-<empty>}', on: $REPLY — the extractor must yield the underscore-stripped N of the FIRST '<field> = N' and NOTHING when the field is absent"; fi
  done
fi
# THE EXTRACTOR STATUS CONTRACT (task 1793502104, decision A): both extractors
# answer by stdout ONLY — exit 0 on every input — so a bare `v="$(fn …)"` is
# safe under `set -euo pipefail` and the caller's test on v IS the status.
# Why it is a contract and not a tidy-up: each ends in a grep that MISSES on
# a reply without the shape, a function's status is its last pipeline's, and
# while bash 3.2 does not enforce `set -e` INSIDE a function called in a
# $(…) (§6ap's premise), it DOES enforce it on the assignment at TOP level —
# so under deploy.sh's `set -euo pipefail` the bare arb capture ended the
# script, silently, at exactly the reply its -z arm exists to survive (task
# 1793498812 measured it live; §6ao's bad / miss / hashed moods). The
# trailing `|| true` INSIDE each extractor removes the trap for every
# present and future caller instead of documenting it at each site (the B
# alternative: teaching §6ap that a capture of a pipeline-ended function
# needs `|| true` on the line). Three probes per extractor, each DRIVING the
# sliced body in a CHILD bash so the options are exactly the ones named:
# (1) the status on an empty answer is 0 under `set -o pipefail`; (2) the
# task's shape — `bash -c 'set -euo pipefail; X="$(fn "")"; echo REACHED'`
# — REACHES, exit 0; (3) the negative control strips the `|| true` and the
# same shape must NOT reach, so the probe demonstrably sees the bug it pins.
extractor_status_probe() {  # extractor_status_probe <fn> <sliced body> <call…>
  local fn="$1" body="$2"; shift 2
  local call="$*" rc out neg_body neg_rc neg_out
  if [ -z "$body" ]; then _fail "§6af: the sliced $fn body is empty — its status probes are inert"; return 0; fi
  rc="$(bash -c "set -o pipefail
$body
$call >/dev/null; echo \$?" 2>/dev/null)"
  if [ "$rc" = "0" ]; then _ok "§6af: $fn exits 0 on an empty answer under set -o pipefail (the extractor status contract, task 1793502104)"
  else _fail "§6af: $fn exited '${rc:-?}' on an empty answer under set -o pipefail — an extractor answers by stdout ONLY: end its pipeline in || true, or every set -e caller's bare capture dies at the miss"; fi
  out="$(bash -c "set -euo pipefail
$body
X=\"\$($call)\"; echo REACHED" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "REACHED" ]; then _ok "§6af PROBE: bash -c 'set -euo pipefail; X=\"\$($call)\"; echo REACHED' REACHES with the sliced $fn (exit 0)"
  else _fail "§6af PROBE: the bare capture X=\"\$($call)\" under set -euo pipefail did not reach the next line (exit $rc, out='$(printf '%s' "$out" | tr '\n' ' ' | head -c 120)') — $fn's status aborts its set -e callers"; fi
  neg_body="$(printf '%s\n' "$body" | sed 's/ || true$//')"
  if [ "$neg_body" = "$body" ]; then _fail "§6af negative control: the sliced $fn carries no trailing '|| true' to strip — the control cannot see the bug"; return 0; fi
  neg_out="$(bash -c "set -euo pipefail
$neg_body
X=\"\$($call)\"; echo REACHED" 2>&1)" && neg_rc=0 || neg_rc=$?
  if [ "$neg_rc" -ne 0 ] && [ "$neg_out" != "REACHED" ]; then _ok "§6af negative control: with $fn's || true stripped the same shape aborts before REACHED (exit $neg_rc) — the probe sees the bug it pins"
  else _fail "§6af negative control: with $fn's || true stripped the shape still reached (exit $neg_rc, out='$neg_out') — the probe cannot see the bug"; fi
}
extractor_status_probe mdx_reply_nat_value "$NATV_BODY"  'mdx_reply_nat_value ""'
extractor_status_probe mdx_vault_nat       "$VAULT_BODY" 'mdx_vault_nat "" lpSupply'
SEED_UNC_6AE=$(uncommented scripts/seed.sh); PLAY_UNC_6AE=$(uncommented scripts/play_start.sh)
src_has "§6af: seed.sh resolves the checked-in contract for its calls"        "$SEED_UNC_6AE" 'SEED_CANDID="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../candid/backend.did"'
src_has "§6af: seed.sh's call() hands icp the contract (--candid) when present" "$SEED_UNC_6AE" 'icp canister call backend "$@" --candid "$SEED_CANDID" 2>&1'
src_has "§6af: play_start.sh resolves the checked-in contract for its calls"  "$PLAY_UNC_6AE" 'PLAY_CANDID="$(cd "$(dirname "$0")" && pwd)/../candid/backend.did"'
src_has "§6af: play_start.sh's call() hands icp the contract (--candid)"      "$PLAY_UNC_6AE" 'icp canister call backend "$@" --candid "$PLAY_CANDID" 2>&1'
src_has "§6af: play_start.sh's adm() hands icp the contract (--candid)"       "$PLAY_UNC_6AE" 'icp canister call backend "$@" --candid "$PLAY_CANDID" --identity anonymous 2>&1'
# The same belt on the two remaining callers (task 1788508007). tests/_lib.sh's
# call() — every suite's backend call — resolves the contract from the repo
# root (its SCRIPT_DIR) and passes it when present. deploy.sh — the #play
# seed + insurance gates on EVERY target, engine/subnet included, where a
# metadata miss is likelier than locally — resolves DEPLOY_CANDID once,
# empties it when the file is absent, and every `icp canister call backend`
# site carries `${DEPLOY_CANDID:+--candid "$DEPLOY_CANDID"}` (the :+ form is
# exempt from set -u, so the W55/seed-probe stubs above run the sliced blocks
# with the flag simply absent). The target table is untouched: the scan is
# "no backend call site without the flag", not a line-by-line pin.
LIB_UNC_6AF=$(uncommented tests/_lib.sh); DEPLOY_UNC_6AF=$(uncommented scripts/deploy.sh)
src_has "§6af: tests/_lib.sh resolves the checked-in contract from the repo root"   "$LIB_UNC_6AF" 'MDX_CANDID="$SCRIPT_DIR/candid/backend.did"'
src_has "§6af: tests/_lib.sh's call() hands icp the contract (--candid) when present" "$LIB_UNC_6AF" 'icp canister call backend "$@" --candid "$MDX_CANDID" 2>&1'
src_has "§6af: deploy.sh resolves the checked-in contract for its calls"            "$DEPLOY_UNC_6AF" 'DEPLOY_CANDID="$(cd "$(dirname "$0")" && pwd)/../candid/backend.did"'
src_has "§6af: deploy.sh empties DEPLOY_CANDID when the file is absent (the flag vanishes, the call still runs)" "$DEPLOY_UNC_6AF" '[ -f "$DEPLOY_CANDID" ] || DEPLOY_CANDID=""'
DEPLOY_NOCANDID=$(printf '%s\n' "$DEPLOY_UNC_6AF" | grep -n 'icp canister call backend' | grep -v 'DEPLOY_CANDID:+--candid "$DEPLOY_CANDID"' || true)
DEPLOY_CANDID_SITES=$(printf '%s\n' "$DEPLOY_UNC_6AF" | grep -c 'icp canister call backend.*DEPLOY_CANDID:+--candid "$DEPLOY_CANDID"' || true)
if [ -z "$DEPLOY_NOCANDID" ] && [ "${DEPLOY_CANDID_SITES:-0}" -ge 20 ]; then _ok "§6af: every backend call site in deploy.sh ($DEPLOY_CANDID_SITES) hands icp the contract via \${DEPLOY_CANDID:+--candid …}"
else _fail "§6af: deploy.sh backend call site(s) without the --candid belt (a metadata miss on engine/subnet would hash-spell the reply): $(printf '%s' "$DEPLOY_NOCANDID" | tr '\n' ' ' | head -c 300) [flagged sites: ${DEPLOY_CANDID_SITES:-0}]"; fi
[ -f candid/backend.did ] && _ok "§6af: candid/backend.did is checked in (the file both scripts pass as --candid)" || _fail "§6af: candid/backend.did is missing — both seeding scripts fall back to the per-call metadata fetch (run scripts/gen-did.sh)"
# The flag itself: an icp upgrade that drops --candid would make every
# seeding call refuse at the CLI. No canister is called — `--help` is offline.
if command -v icp >/dev/null 2>&1; then
  if icp canister call --help 2>/dev/null | grep -cF -- '--candid <PATH>' >/dev/null; then _ok "§6af: this icp ($(icp --version 2>/dev/null | tr -d '\n')) accepts --candid <PATH> on canister call"
  else _fail "§6af: this icp ($(icp --version 2>/dev/null | tr -d '\n')) does not list --candid <PATH> on canister call — seed.sh/play_start.sh pass it on every backend call"; fi
else _ok "§6af: icp not on PATH here — the --candid flag check is skipped (static run)"; fi

# Every SUITE too (task 1788512331). tests/test_*.sh carried ~260 backend call
# sites of their own — private adm()/u()-style helpers of the
# `icp canister call --identity X backend "$@"` shape (the word order dodged a
# `call backend` grep) plus inline sites — none of which passed through
# _lib.sh's call(), so none handed icp the contract. A suite that reads a
# reply by field NAME (extract_nat "field", `grep -oE 'usedUsd = …'`) rather
# than through mdx_ok reads an EMPTY value on a metadata miss and reds like a
# code regression. The scan, on the code-only view (comments and string
# literals dropped — a needle is not a call): no line of any suite may run
# `icp canister call … backend …` without `--candid`; a suite that carries the
# belt must be able to resolve MDX_CANDID (it sources _lib.sh, or names the
# file itself — the standalone suites); and no private `call() {` copy may
# shadow _lib.sh's without the belt. Sites that pass the canister as an
# argument (bridge_write_ahead's u) belt the backend branch only —
# candid/backend.did is the backend's contract, not the Bridge's. The one
# exemption is THIS file: its H-02 negative-control stub (a heredoc, which
# code_only cannot strip) runs the pre-H-02 probe shape against a stubbed icp
# by design — pinned below to exactly one such line, so a real bypass here
# cannot hide behind it.
SUITE_NOCANDID=""; SUITE_CANDID_SITES=0; SUITE_CANDID_FILES=0; SUITE_NORESOLVE=""; SUITE_PRIVCALL=""
for f in tests/test_*.sh; do
  [ "$f" = tests/test_deploy_hygiene.sh ] && continue
  UNC=$(uncommented "$f"); CO=$(printf '%s\n' "$UNC" | code_only)
  grep_scan hits "$CO" 'icp canister call'
  grep_filter -k hits '(^|[^A-Za-z_./-])backend([^A-Za-z_./-]|$)'
  grep_filter -F hits '--candid'
  [ -n "$hits" ] && SUITE_NOCANDID="$SUITE_NOCANDID $(basename "$f"):$(printf '%s\n' "$hits" | cut -d: -f1 | paste -sd, -)"
  n=$(printf '%s\n' "$UNC" | grep -c -- '--candid "$MDX_CANDID"' || true)
  if [ "${n:-0}" -gt 0 ]; then
    SUITE_CANDID_SITES=$(( SUITE_CANDID_SITES + n )); SUITE_CANDID_FILES=$(( SUITE_CANDID_FILES + 1 ))
    # grep -c, not -q (W5-10 item 3): the suite view is a whole file on a
    # pipe; -q matches on line ~20 without draining, the printf takes SIGPIPE
    # past the pipe buffer, and the `||` reads a resolving suite as NORESOLVE
    # (task 1788731609: test_vault_lp.sh crossed ~90 KB and did exactly that).
    printf '%s\n' "$UNC" | grep -cE '_lib\.sh"|^MDX_CANDID=' >/dev/null || SUITE_NORESOLVE="$SUITE_NORESOLVE $(basename "$f")"
  fi
  if printf '%s\n' "$UNC" | grep -c '^call() {' >/dev/null; then
    printf '%s\n' "$UNC" | sed -n '/^call() {/,/^}/p' | grep -c -- '--candid' >/dev/null || SUITE_PRIVCALL="$SUITE_PRIVCALL $(basename "$f")"
  fi
done
if [ -z "$SUITE_NOCANDID" ]; then _ok "§6af: no suite runs a backend call without the --candid belt (code-only view of every tests/test_*.sh)"
else _fail "§6af: backend call site(s) without --candid in tests/test_*.sh (a metadata miss hash-spells the reply and a by-name read comes back empty) —$SUITE_NOCANDID: give the line --candid \"\$MDX_CANDID\" or route it through _lib.sh's call()"; fi
if [ "$SUITE_CANDID_SITES" -ge 200 ] && [ "$SUITE_CANDID_FILES" -ge 60 ]; then _ok "§6af: the suites' own belt is in place ($SUITE_CANDID_SITES sites across $SUITE_CANDID_FILES suites)"
else _fail "§6af: the suites' --candid belt shrank to $SUITE_CANDID_SITES sites / $SUITE_CANDID_FILES suites (floor 200 / 60) — sites were removed, not routed through call(); re-derive from the sweep in task 1788512331"; fi
if [ -z "$SUITE_NORESOLVE" ]; then _ok "§6af: every belted suite resolves MDX_CANDID (sources _lib.sh or names candid/backend.did itself)"
else _fail "§6af: suite(s) pass --candid \"\$MDX_CANDID\" without sourcing _lib.sh or defining MDX_CANDID —$SUITE_NORESOLVE (set -u aborts the first call)"; fi
if [ -z "$SUITE_PRIVCALL" ]; then _ok "§6af: no private call() copy shadows _lib.sh's without the belt"
else _fail "§6af: private call() copy without --candid in$SUITE_PRIVCALL — delete it (the suite sources _lib.sh) or add the belt"; fi
HYG_SELF=$(uncommented tests/test_deploy_hygiene.sh | code_only | grep 'icp canister call' | grep -E '(^|[^A-Za-z_./-])backend([^A-Za-z_./-]|$)' | grep -v -- '--candid' || true)
HYG_SELF_N=$(printf '%s\n' "$HYG_SELF" | grep -c . || true)
if [ "${HYG_SELF_N:-0}" -eq 1 ] && printf '%s\n' "$HYG_SELF" | grep -qF 'getAmmPools "" -e ""'; then _ok "§6af: this file's only un-belted backend call is the H-02 negative-control stub (the pre-H-02 probe shape, by design)"
else _fail "§6af: test_deploy_hygiene.sh carries $HYG_SELF_N un-belted backend call line(s) where exactly one (the H-02 old-shape stub) is expected: $(printf '%s' "$HYG_SELF" | tr '\n' ' ' | head -c 300)"; fi
# ── §6af self-census (task 1793505604): every ERE grep in THIS file is belted ──
# Four tasks fixed one defect class — a grep REGEX ERROR (rc 2) that a raw grep
# reads as "no match" — with grep_scan / grep_count / grep_filter / grep_has,
# each header ending "the ONE … idiom here". Nothing enforced that: the next raw
# `X=$(… | grep -nE … || true)` scan or `… | grep -cE … >/dev/null || continue`
# gate lands green and stays inert until someone measures again. So this file
# reads its OWN code the way HYG_SELF above does: every line carrying an ERE grep
# outside the six helper bodies (blanked by their `name() {` … `}` anchors, never
# by line number; string literals stripped by code_only, so a needle QUOTING a
# grep is not a hit; a heredoc body still reads as code — over-scan, never
# under-scan) must contain exactly ONE entry of GSELF_ALLOW — a fixed string of
# the site, matched against the SOURCE line so the needle stays visible — and
# every entry names the site's BELT: how a regex error there still reds the run
# (a -n/-z gate on the extracted value, assert_eq against the empty count, a
# fail-closed || tail, a floor the emptied scan falls under, a negative control
# rerunning the same needle, or the FOUND branch being the _ok). A hit with no
# entry reds (route it through a helper, or allowlist it WITH its belt); an entry
# matching no line reds too, so an entry cannot outlive its site; a line matching
# two entries reds (tighten them). An entry whose belt has slack is marked WEAK
# and cites the follow-up that tightens it (the six of 1793505604 were tightened
# by 1793507323 — fixture-driven negative controls; none remain). To add a
# legitimately raw site: add the
# comment, then the entry (a substring unique to that line; single quotes, with
# '"'"' for an embedded quote); a raw grep -q ban can never be allowlisted —
# it has no belt (`! 2` is TRUE): route it.
GSELF_ALLOW=(
  # step 7: rc 2 → an empty line number → the [ -n ] chain → _fail
  'PS7_START_LN=$(printf '"'"'%s\n'"'"' "$PS7" | grep -nE'
  # step 7: assert_eq "1" against the EMPTY count a regex error prints → _fail
  '| grep -cE '"'"'^[[:space:]]*bash scripts/start_bots_local.sh'"'"')"'
  # PS5 must_ok: the FOUND branch is the _ok; rc 2 lands in the else _fail
  'grep -qE "^[[:space:]]*must_ok \"$m \\\$market\"'
  # keychain scan: KCH_NEG reruns the same two needles with the gates stripped under -eq 3 → _fail
  'kch_bare() { grep -nE'
  # §6c: [ -z "$EXIT_LIST" ] → _fail
  'EXIT_LIST=$(printf '"'"'%s\n'"'"' "$EXIT_LIST_DECL" | grep -oE'
  # §6c: [ -z "$EXIT_ARMS" ] → _fail
  'EXIT_ARMS=$(printf '"'"'%s\n'"'"' "$INSPECT_FN" | mo_code | sed -n '"'"'/let exitCandidate'
  # §6c: equality with EXIT_ARMS (itself -z gated) → _fail
  'EXIT_ROUTED=$(printf '"'"'%s\n'"'"' "$INSPECT_FN"'
  # §6d: src_has over the BUILT haystack — empty → _fail
  '"$(grep -E "^  let $fossil : \[Text\] = " src/backend/main.mo)"'
  # §6d: the per-method case → _fail for every name, and equality with PRE_ARMS
  'PRE_LIST=$(printf '"'"'%s\n'"'"' "$PRE_LIST_DECL" "$DEV_PRE_LIST_DECL" | grep -oE'
  # §6d: [ -z "$PRE_ARMS" ] → _fail
  'PRE_ARMS=$(printf '"'"'%s\n'"'"' "$INSPECT_FN"'
  # §6d: equality with PRE_ARMS (itself -z gated) → _fail
  'PRE_ROUTED=$(printf '"'"'%s\n'"'"' "$INSPECT_FN"'
  # §6h: [ -n "$ARB_CAP" ] in the cap comparison → _fail
  'ARB_CAP=$(mo_code < src/arb/main.mo | grep -oE'
  # §6h: [ -n "$DEX_CAP" ] → _fail
  'DEX_CAP=$(mo_code < src/backend/main.mo | grep -oE'
  # §6h: [ -n "$JUMP_BPS" ] → _fail
  'JUMP_BPS=$(mo_code < src/backend/main.mo | grep -oE'
  # §6h: [ -n "$HOUR_CAP" ] → _fail
  'HOUR_CAP=$(mo_code < src/backend/main.mo | grep -oE'
  # §6h′: [ -n "$ARB_TTL" ] → _fail
  'ARB_TTL=$(mo_code < src/arb/main.mo | grep -oE'
  # §6h′: [ -n "$ARB_TICK_NS" ] → _fail
  'ARB_TICK_NS=$(mo_code < src/arb/main.mo | grep -oE'
  # H-35: src_has over the BUILT haystack — empty → _fail
  '"$(grep -E '"'"'^  let insuranceStakedAt +='"'"' src/backend/main.mo)"'
  # H-35: [ -n "${H35_COOL:-}" ] → _fail
  'H35_COOL=$(printf '"'"'%s\n'"'"' "$H35_MAIN" | grep -oE'
  # H-35: [ -n "${H35_HBLIQ:-}" ] → _fail
  'H35_HBLIQ=$(printf '"'"'%s\n'"'"' "$H35_MAIN" | grep -oE'
  # H-36: src_has over the BUILT haystack — empty → _fail
  '"$(grep -E '"'"'^  let preRegStore = PreReg.empty\(\);'"'"' src/backend/main.mo)"'
  # H-36: [ -n "${H36_CAP:-}" ] → _fail
  'H36_CAP=$(printf '"'"'%s\n'"'"' "$H36_MAIN" | grep -oE'
  # H-36: src_has over the BUILT haystack — empty → _fail
  '"$(grep -E '"'"'^identity-attributes = '"'"' mops.toml)"'
  # #55 capture pin: the FOUND branch is the _ok; rc 2 in either stage lands in the else _fail
  '| grep -cE '"'"'2>&1 \|\| true\)"?$'"'"' >/dev/null; then'
  # H-02: [ -n "$RD_SUBNET_LN" ] / [ -n "$RD_ENGINE_LN" ] → _fail
  'RD_CALLS="$(printf '"'"'%s\n'"'"' "$DEPLOY_H02" | grep -nE'
  # cloud_seed probe: the FOUND branch is the _ok; rc 2 lands in the else _fail
  'grep -cE '"'"'^[[:space:]]*seed_probe_pools[[:space:]]*$'"'"' >/dev/null; then _ok'
  # §6z: [ -n "$LR_MOPS_PIN" ] || _fail
  'LR_MOPS_PIN=$(printf '"'"'%s\n'"'"' "$LR_CODE" | grep -oE'
  # §6z: [ -n "$LR_ICW_PIN" ] || _fail
  'LR_ICW_PIN=$(printf '"'"'%s\n'"'"' "$LR_CODE" | grep -oE'
  # §6ab skip gate: rc 2 skips EVERY file → LP_HOLD_N 0 under the floor 25 → _fail
  "grep -cE 'createAmmPool' >/dev/null || continue"
  # §6ab raw-door leg (lp_legs): the §6ab negative control — the same lp_legs over the four-mint fixture must yield exactly 3 legs; rc 2 here → 1 → _fail (the floor 25 alone could not see it: 28 of the 31 suites arrive through the lib leg; task 1793507323)
  '{ printf '"'"'%s\n'"'"' "$1" | grep -E "(seedAmmPool|depositLp)'
  # §6ab lib leg + the zero filter (lp_legs): rc 2 empties the legs → LP_HOLD_N under the floor 25 → _fail; the negative control reds too (2 / 0 legs)
  "grep -E 'mdx_lp_deposit +[^ ]+ +[^ ]+ +[^ ]'"
  # §6ab: fail-closed || tail — rc 2 adds the file → _fail
  "grep -cE 'enableAmm' >/dev/null || LP_HOLD_BAD="
  # §6ad: the -ge 11 floor — rc 2 lists no file → 0 → _fail
  'ID_USERS=$(grep -lE'
  # §6ae: the -ge 75 floor — rc 2 → 0 → _fail
  'ID_USERS2=$(grep -lE'
  # §6af: fail-closed || tail — rc 2 adds the suite → _fail
  'grep -cE '"'"'_lib\.sh"|^MDX_CANDID='"'"' >/dev/null || SUITE_NORESOLVE='
  # §6af: HYG_SELF_N -eq 1 — rc 2 → 0 → _fail
  'HYG_SELF=$(uncommented tests/test_deploy_hygiene.sh | code_only | grep '"'"'icp canister call'"'"' | grep -E'
  # §6ah: src_has KEEP=(…) on the line — empty → _fail
  'KEEP_LINE=$(printf '"'"'%s\n'"'"' "$CLEAN_UNC" | grep -E'
  # §6ah: the -ne 3 definition count → _fail
  'KEEP_DEFS=$(printf '"'"'%s\n'"'"' "$CLEAN_UNC" | grep -E'
  # §6ah: [ -n "$LADDER_6AH" ] || _fail
  'LADDER_6AH=$(printf '"'"'%s\n'"'"' "$(uncommented scripts/play_start.sh)" | grep -E'
  # §6ah LITS (mint_names): MINT_N floor 100 — rc 2 drops the ~170 direct literals → _fail; the §6ah negative control reds too ({alice} alone)
  'LITS=$(printf '"'"'%s\n'"'"' "$UNC" | grep -oE'
  # §6ah VARS (mint_names): the §6ah negative control — mint_names over the X=alice / bob fixture must yield {alice, bob}; rc 2 here → {bob} → _fail (the floor 100 alone could not see it: 170 of the 211 names are direct literals; task 1793507323)
  'VARS=$(printf '"'"'%s\n'"'"' "$UNC" | grep -oE'
  # §6ah per-var lookup (mint_names): the same negative control — rc 2 → {bob} → _fail (task 1793507323)
  '$(printf '"'"'%s\n'"'"' "$UNC" | grep -oE "(^|[[:space:];])$v='
  # §6ai: assert_eq "1" against the EMPTY count → _fail
  '"$(printf '"'"'%s\n'"'"' "$COLD_UNC" | grep -cE '"'"'^FLEET_STARTED=false$'"'"')"'
  # §6ai: [ -n "$COLD_FS0_LN" ] → _fail
  'COLD_FS0_LN=$(printf '"'"'%s\n'"'"' "$COLD_UNC" | grep -nE'
  # §6aj has_flat gate: the fixture control — the fixture defines flat() and compares NF, a count over its "| flat" capture, hollow; rc 2 → has_flat=0 → the no-flat branch never saturates NF → SATC_GOT loses "25: NF = 2" → _fail (raw by necessity: it runs inside $(satc_scan), where a helper's _fail is lost; task 1793507323)
  'grep -cE "^flat\(\)[[:space:]]*\{[[:space:]]*$SATC_STRIP" >/dev/null && has_flat=1'
  # §6aj: the fixture control — SATC_GOT must equal the eight expected verdicts → _fail
  'sat=$(printf '"'"'%s\n'"'"' "$code" | grep -E'
  # §6aj: the fixture control (the re-split exclusion) → _fail
  '| grep -vE "$SATC_STRIP.*$SATC_RESPLIT.*grep -c" \'
  # §6aj flat branch: the fixture control — the branch the fixture takes (it defines flat()); rc 2 empties stripped → the NT / HS / ROWSTAIL / NF verdicts vanish → _fail (task 1793507323)
  'stripped=$(printf '"'"'%s\n'"'"' "$code" | grep -E "^[[:space:]]*(local |export )?$SATC_NAME=\\\$\(.*($SATC_STRIP|\| *flat\))"'
  # §6aj re-split exclusion, BOTH branches (one entry, two identical lines): the flat one under the fixture control, the no-flat one under the derived no-flat fixture (flat() deleted) — rc 2 empties stripped either way → _fail (task 1793507323)
  '| grep -v '"'"'grep -c'"'"' | grep -vE "$SATC_RESPLIT" \'
  # §6aj no-flat branch: the derived no-flat fixture control (flat() deleted; NT / HS / ROWSTAIL verdicts) → _fail
  'stripped=$(printf '"'"'%s\n'"'"' "$code" | grep -E "^[[:space:]]*(local |export )?$SATC_NAME=\\\$\(.*$SATC_STRIP" \'
  # §6aj per-var saturated lookup: the fixture control → _fail
  '$(printf '"'"'%s\n'"'"' "$code" | grep -E "^[[:space:]]*(local |export )?$SATC_NAME=\\\$\(((echo|printf)'
  # §6aj LEFT comparisons: the fixture control → _fail
  'printf '"'"'%s\n'"'"' "$code" | grep -nE "\\\$(\{$v(:-[^}]*)?\}|$v)\"?[[:space:]]*$SATC_OPS'
  # §6aj LEFT fragments: the fixture control → _fail
  'printf '"'"'%s\n'"'"' "$line" | grep -oE "\\\$(\{$v(:-[^}]*)?\}|$v)\"?[[:space:]]*$SATC_OPS'
  # §6aj RIGHT comparisons: the fixture control → _fail
  'printf '"'"'%s\n'"'"' "$code" | grep -nE "(\"[^\"]*\"|[^][:space:]]+)[[:space:]]+$SATC_OPS'
  # §6aj RIGHT fragments: the fixture control → _fail
  'printf '"'"'%s\n'"'"' "$line" | grep -oE "(\"[^\"]*\"|[^][:space:]]+)[[:space:]]+$SATC_OPS'
  # §6aj FIXTURE TEXT inside the heredoc — data this suite writes, never a grep it runs
  'OLD41=$(echo "$MYW" | sed '"'"'s/record {/\nrecord {/g'"'"' | grep -cE "price = 41")'
  # stale-mark guard: [ -n "${TL_MUT_LN:-}" ] → _fail
  'TL_MUT_LN=$(printf '"'"'%s\n'"'"' "$TL_FN" | mo_code | grep -nE'
  # §6ao: PIPE_NEG reruns the same two needles under a -ge 8 floor → _fail
  'PIPE_BARE="$(printf '"'"'%s\n'"'"' "$DEPLOY_SH_CAP" | grep -nE'
  # §6ao PIPE_NEG itself: [ "${PIPE_NEG:-0}" -ge 8 ] on the emptied count → _fail. Visible to the census
  # since 1793512052: the `)` inside sed's 's/ || true)/)/' ended the old $(...) copy early and hid both greps (1793505604's early-cut case)
  'PIPE_NEG="$(printf '"'"'%s\n'"'"' "$DEPLOY_SH_CAP" | sed'
  # §6ao: src_has on the trap line — empty → _fail
  'CAP_TRAP="$(printf '"'"'%s\n'"'"' "$DEPLOY_SH_CAP" | grep -E'
  # §6ao: the -eq 2 line count → else _fail
  'CAP_BELT="$(grep -E '"'"'^set -E$|^trap .* ERR$'"'"' scripts/deploy.sh)"'
  # §6ao belt matrix: [ "" -eq 9 ] on the EMPTY count fails the && chain → _fail
  'grep -cE '"'"'^(A-else|B-else|C-else|D-else|G-or|I-while|J-neg|L-subshell|N-else)'"'"')" -eq 9 ]'
  # §6ao negative control: rc 2 → an empty script → rc 0 → [ "$rc" -ne 0 ] → _fail
  'bash <(grep -vE '"'"'^set -E$|^trap .* ERR$'"'"' "$CAP_TMP/belt.sh") bare'
  # §6ap: [ -n "$CAPF_FNS" ] → _fail
  'capf_fns()  { grep -hoE'
  # §6ap: the five '# pure:' roster checks → _fail per name
  'capf_pure() { grep -hE'
  # §6ap: the same capre runs through grep_count (CAPF_SITES) and the NEG_X / gate / pure negative controls → _fail
  'grep -nE -- "$capre" "$view" | cut -d: -f1 | while read -r i; do'
  # §6ap exemption test inside capf_scan: rc 2 → NOT exempt → the line is flagged → _fail (fail-closed)
  'grep -qE -- '"'"'\|\| true\)'"'"'; then :'
  # §6ap exemption test: rc 2 → flagged → _fail (fail-closed)
  'grep -qE -- '"'"'\|\| *(die|mdx_die|err|seed_fail|return|exit|\{)'"'"'; then :'
  # §6ap exemption test: rc 2 → flagged → _fail (fail-closed; the # safe: negative control reds too)
  "grep -qE -- '# safe:'; then :"
  # §6ap exemption test: rc 2 → flagged → _fail (fail-closed)
  'grep -qxE -- "$pure"; then :'
  # §6ap exemption test: rc 2 → flagged → _fail (fail-closed)
  'grep -qE -- "$gate"; then :'
  # §6au: -ge 5 on the count ("" errors the test) → _fail
  'H34_CTX_N=$(printf '"'"'%s\n'"'"' "$H06_MAIN" | grep -cE'
  # §6au: equality with H34_CTX_N → _fail
  'H34_HOOK_N=$(printf '"'"'%s\n'"'"' "$H06_MAIN" | grep -cE'
  # §6av: -ge 5 on the count → _fail
  'H41_CTX_N=$(printf '"'"'%s\n'"'"' "$H06_MAIN" | grep -cE'
  # §6av: equality with H41_CTX_N → _fail
  'H41_FUNDABLE_N=$(printf '"'"'%s\n'"'"' "$H06_MAIN" | grep -cE'
  # §7b: STABLE_FOSSILS reruns the same regex under [ -n ] → _fail
  'N_STABLE_CONST=$(grep -E "$STABLE_CONST_RE" src/backend/main.mo | grep -cv'
  # §7b: a diagnostic print inside the _fail branch — never a verdict
  'grep -nE "$STABLE_CONST_RE" src/backend/main.mo | grep -v '"'"'STABLE-FOSSIL'"'"' | head -5'
  # §7b: [ -n "$STABLE_FOSSILS" ] || _fail
  'STABLE_FOSSILS=$(grep -E "$STABLE_CONST_RE" src/backend/main.mo | grep '"'"'STABLE-FOSSIL'"'"''
  # W6-02: [ -z "$DOC_LITS" ] && _fail
  'DOC_LITS=$(grep -ohE'
  # §7g vacuity guard: N_NAMES 0 or ≠ N_BUILDS → _fail
  '| grep -oE '"'"'(Entity\.(manual|new|newScoped)<[^>]*>|\.toEntity)'
  # §7h: comm against UEK_CONS — every constructor missing → _fail
  'EVKIND_CASES=$(printf '"'"'%s\n'"'"' "$EVKIND_FN" | mo_code | grep -oE'
  # §7h: comm -3 against KIND_DOMAIN → _fail (unless both extractors break together)
  'EVKIND_STRS=$(printf '"'"'%s\n'"'"' "$EVKIND_FN" | mo_code | grep -oE'
  # §7h: comm -3 against EVKIND_STRS → _fail (same caveat)
  'KIND_DOMAIN=$(printf '"'"'%s\n'"'"' "$KIND_DOMAIN_LINE" | grep -oE'
  # §7i: the FOUND branch is the _ok; rc 2 lands in the else _fail
  'if grep -qE '"'"'^mdx_ok\(\) \{'"'"' tests/_lib.sh'
  # §7i: the FOUND branch is the _ok; rc 2 fails the chain → _fail (the line's negated clause is routed through grep_has)
  'if grep -qE '"'"'^is_ok\(\) \{$'"'"' scripts/simulate_trading.sh'
  # #51.5: the FOUND branch is the _ok; rc 2 lands in the else _fail
  'if grep -qE '"'"'^i1_tol_e8=[0-9]+$'"'"' tests/_lib.sh'
  # §8b: [ -z "$EXIT_SET" ] → _fail
  'EXIT_SET=$(printf '"'"'%s\n'"'"' "$INSPECT_FN" | mo_code | sed -n '"'"'/let exitCandidate'
  # §6bd: the -z branch's src_has on DR_LIVE → _fail whenever a replica is owned (indistinguishable from none owned otherwise)
  'DR_TOTAL="$(printf '"'"'%s\n'"'"' "$DR_LIVE" | grep -E'
  # §6bd: the FOUND branch is the _ok; rc 2 lands in the else _fail
  'elif printf '"'"'%s'"'"' "$DR_TOTAL" | grep -qE'
  # §6be: assert_eq against the two setters → _fail
  'FA_ARM_TAGS=$(printf '"'"'%s\n'"'"' "$INSPECT_FN" | mo_code | sed -n '"'"'/if (isFundingAuthority(caller)) {/'
)
GSELF_VIEW=$(uncommented tests/test_deploy_hygiene.sh \
  | sed -e '/^src_has() {/,/^}/s/.*//' -e '/^src_lacks() {/,/^}/s/.*//' \
        -e '/^grep_scan() {/,/^}/s/.*//' -e '/^grep_count() {/,/^}/s/.*//' \
        -e '/^grep_filter() {/,/^}/s/.*//' -e '/^grep_has() {/,/^}/s/.*//' \
  | code_only)
# The view must close every literal (task 1793512052). code_only appends the
# sentinel line CODE_ONLY_UNTERMINATED_DQ when the file ends inside an open
# "...", and the name otherwise lives in this file only inside string literals
# and comments — so a sane view never shows it, and a view that does is
# INVERTED somewhere (code stripped, string contents kept): every ERE grep in
# the inverted stretch is invisible to the census while it still prints its ✓
# (under-scan, the one direction the census must never take). Measured
# 2026-11-01: a bare `(` inside a quoted needle inside "$(...)" ran the old
# copy to the line end and swallowed the literal's closing quote — 20 inverted
# stretches in this file (the `"$(mo_func f "func x(" | mo_code)"` shape, up to
# 47 lines each) plus 93 lines under the literal backtick in code_only's own
# awk body, which exposed the very source line that prints the sentinel. A
# PARTIAL belt: a later odd-quote line can resync the state before EOF without
# an inverted line naming the sentinel, so the quote-aware copy is the fix and
# this is the tripwire for the next shape (a lone backtick, a new copy bug).
if grep_has "$GSELF_VIEW" 'CODE_ONLY_UNTERMINATED_DQ'; then
  _fail "§6af: the self-census view carries the unterminated-literal sentinel — the file ends inside an open double-quoted literal (code_only's \$(…) copy overran on an unbalanced ( inside a quoted substitution, or a lone backtick inside a literal swallowed its closing quote) or an inverted stretch exposed a line naming it; every ERE grep inside the inversion is invisible to the census"
else _ok "§6af: the self-census view closes every literal (no inverted stretch hides an ERE grep from the census)"; fi
# ...and no capture runs to the file end either (task 1793513986): the $(...)
# copy CARRIES across lines now, so a file ending inside an open $( is as
# unreliable as one ending inside an open literal — the second sentinel.
src_lacks "§6af: the self-census view closes every \$(...) (no multi-line capture runs to the file end)" "$GSELF_VIEW" "CODE_ONLY_UNTERMINATED_SUBST"
grep_scan GSELF_HITS "$GSELF_VIEW" 'grep -[a-zA-Z]*E'
# the hits' SOURCE lines (needles intact), keyed by the line numbers grep_scan prefixed
GSELF_HIT_SRC=$(awk -F: 'NR == FNR { if ($1 ~ /^[0-9]+$/) want[$1] = 1; next } (FNR in want) { print FNR ": " $0 }' \
  <(printf '%s\n' "$GSELF_HITS") tests/test_deploy_hygiene.sh)
GSELF_N=0; GSELF_BAD=""
while IFS= read -r l; do
  [ -n "$l" ] || continue
  GSELF_N=$((GSELF_N + 1)); m=0
  for e in "${GSELF_ALLOW[@]}"; do case "$l" in *"$e"*) m=$((m + 1)) ;; esac; done
  [ "$m" -eq 1 ] || GSELF_BAD="$GSELF_BAD
$m|$l"
done <<< "$GSELF_HIT_SRC"
if [ -z "$GSELF_BAD" ] && [ "$GSELF_N" -ge 1 ]; then _ok "§6af: every ERE grep in this file outside the six helpers is allowlisted with its belt ($GSELF_N lines, ${#GSELF_ALLOW[@]} entries)"
else
  [ "$GSELF_N" -ge 1 ] || _fail "§6af: the self-census saw NO ERE grep in this file — the view (uncommented | code_only) is broken, not the file clean"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "${l%%|*}" = 0 ]; then _fail "§6af: un-belted ERE grep outside the four helpers — route it through grep_scan/grep_count/grep_filter/grep_has, or allowlist it WITH its belt: $(printf '%s' "${l#*|}" | head -c 220)"
    else _fail "§6af: an ERE grep line matches ${l%%|*} allowlist entries where exactly one is expected — tighten them: $(printf '%s' "${l#*|}" | head -c 220)"; fi
  done <<< "$GSELF_BAD"
fi
GSELF_STALE=0
for e in "${GSELF_ALLOW[@]}"; do
  case "$GSELF_HIT_SRC" in *"$e"*) ;; *) GSELF_STALE=$((GSELF_STALE + 1)); _fail "§6af: stale allowlist entry: $e" ;; esac
done
[ "$GSELF_STALE" -eq 0 ] && _ok "§6af: every self-census allowlist entry still names a live ERE grep line"

# ── 6ag. adminRetireEmptySeasonSegment retires ONLY a provably empty pre-#54.4 successor row (task 1788499923) ──
# Seasons closed before 1788465055 registered the pre-spawned successor as a
# season row — { firstSeq 0; lastSeq null } for a canister that never held an
# event: "0 – growing" in both tables, refilled by the fuel loop forever, one
# archiveExecute hop per deep read. The registry is stable state and a
# migration cannot do the per-row await, so the repair is a controller-only
# admin op on EVERY posture. Pins: the gate order (registry row → lastSeq
# null → not routed by the current chain → the canister's OWN certified head
# is empty), the stop+delete pair resetExchange's wipe uses, the ring-log
# line + #config on the tape (the §6n shape), both new methods in inspect's
# enumeration, the seeding hook dev-gated and scoped to our own canisters,
# and the verifiers' "never held an event — not walked" tolerance kept
# (venues nobody sweeps still carry such rows). Live twin:
# tests/test_retire_empty_season_segment.sh.
RET_FN=$(mo_func src/backend/main.mo "func adminRetireEmptySeasonSegment(")
[ -n "$RET_FN" ] || _fail "§6ag: could not extract adminRetireEmptySeasonSegment()"
RET_CODE=$(printf '%s\n' "$RET_FN" | mo_code)
src_has   "§6ag: the op is controller-gated"                                    "$RET_CODE" 'requireController(msg.caller);'
src_lacks "§6ag: the op is NOT dev-gated (an ops repair on every posture)"      "$RET_CODE" 'requireDevHook('
src_has   "§6ag: a non-row principal is refused"                                "$RET_CODE" '#err("not a season registry row: "'
src_has   "§6ag: a row with lastSeq set is refused as a sealed segment"         "$RET_CODE" 'is a sealed segment (season'
src_has   "§6ag: the current chain's tip is refused"                            "$RET_CODE" 'is the active archive of the current chain'
src_has   "§6ag: the current chain's successor is refused"                      "$RET_CODE" 'is the pre-spawned successor of the current chain'
src_has   "§6ag: the canister's own certified head decides"                     "$RET_CODE" 'await a.getCertifiedHead();'
src_has   "§6ag: a head that covers an event is refused (a season tip)"         "$RET_CODE" 'holds events (certified headSeq'
src_has   "§6ag: an unreadable head is refused, never treated as empty"         "$RET_CODE" 'an unreadable segment is not provably empty'
src_has   "§6ag: the row is re-resolved after the await"                        "$RET_CODE" 'left the registry while its head was being read'
src_has   "§6ag: the retirement logs on the ring"                               "$RET_CODE" 'logEvent("info", "system", "SEASON REGISTRY: retired empty successor row " # v'
src_has   "§6ag: the retirement emits #config on the tape"                      "$RET_CODE" 'emitConfig(msg.caller, "adminRetireEmptySeasonSegment", v)'
src_has   "§6ag: the canister is stopped with the wipe's ic00 call"             "$RET_CODE" 'await ic00.stop_canister({ canister_id = cid });'
src_has   "§6ag: the canister is deleted with the wipe's ic00 call"             "$RET_CODE" 'await ic00.delete_canister({ canister_id = cid });'
src_has   "§6ag: a failed delete is reported with the by-hand recovery"         "$RET_CODE" 'delete it by hand'
SEED_ROW_FN=$(mo_func src/backend/main.mo "func setTestSeasonRow(")
[ -n "$SEED_ROW_FN" ] || _fail "§6ag: could not extract setTestSeasonRow()"
SEED_ROW_CODE=$(printf '%s\n' "$SEED_ROW_FN" | mo_code)
src_has   "§6ag: the seeding hook is dev-gated"                                 "$SEED_ROW_CODE" 'requireDevHook("setTestSeasonRow")'
src_has   "§6ag: the seeding hook is scoped to canisters this exchange spawned" "$SEED_ROW_CODE" 'not an archive segment of this exchange'
src_has   "§6ag: the seeding hook refuses a duplicate row"                      "$SEED_ROW_CODE" 'already a season registry row'
src_has   "§6ag: seeding the carried successor clears the next pointer"         "$SEED_ROW_CODE" '_archiveNext := null'
src_has   "§6ag: inspect enumerates adminRetireEmptySeasonSegment"              "$INSPECT_FN" '#adminRetireEmptySeasonSegment : Any'
src_has   "§6ag: inspect enumerates setTestSeasonRow"                           "$INSPECT_FN" '#setTestSeasonRow : Any'
src_has   "§6ag: verify_ledger.mjs keeps the never-held-an-event tolerance"     "$(cat scripts/verify_ledger.mjs)" 'never held an event (successor pre-spawned before the boundary) — not walked'
src_has   "§6ag: ledger.js keeps the never-held-an-event tolerance"             "$(cat src/frontend/src/ledger.js)" 'if (!h.headHash.length) continue;'
src_has   "§6ag: the live twin drives the op"                                   "$(cat tests/test_retire_empty_season_segment.sh)" 'adminRetireEmptySeasonSegment'
# ── §6ah 1788508000: cleanup_identities.sh sweeps ONE store and keeps the venue-lifetime names ─
# The sweeper's KEEP set decides which identities survive a store sweep. It
# must hold the standing five + anonymous (every suite signs with alice/bob/
# charlie; seed.sh's seed_full funds all five and places the resting book as
# them) and the VENUE-LIFETIME names the bring-up scripts and fleet engines
# mint and keep signing with (play_start's ladder makers own the resting
# ladder, deploy.sh's seed traders, the bots' funded balances) — deleting one
# orphans its on-venue positions and the next bring-up mints a stranger under
# the same name. It must NOT hold the retired throwaways swapper/buyer/taker/
# battery: the suites that used them mint per run via mdx_identity_new (§6ae)
# now, and a name in KEEP is a name that never leaves. The arrays and
# keep_name() are sliced out of the live script and evaluated in a subshell,
# so the unit tests the code that runs, not a copy. Store awareness: the
# script prints the store it acts on, refuses the GLOBAL store from inside a
# worktree unless --global (a seat that forgot `export ICP_HOME` must not
# wipe the machine-shared store), and offers --dry-run.
CLEAN_SH=scripts/cleanup_identities.sh
CLEAN_UNC=$(uncommented "$CLEAN_SH")
KEEP_LINE=$(printf '%s\n' "$CLEAN_UNC" | grep -E '^KEEP=\(' | head -1)
src_has "§6ah: KEEP is exactly the standing five + anonymous" "$KEEP_LINE" 'KEEP=(anonymous alice bob charlie dave eve)'
for w in swapper buyer taker battery; do
  src_lacks "§6ah: retired throwaway '$w' is out of KEEP (minted per run now)" "$KEEP_LINE" " $w"
done
KEEP_DEFS=$(printf '%s\n' "$CLEAN_UNC" | grep -E '^KEEP(_GLOB|_GLOBAL)?=\(')
KEEP_FN=$(sed -n '/^keep_name() {/,/^}/p' "$CLEAN_SH")
# Task 1789609264: on --global the sweep is POSITIVE - DOOM_GLOBAL (anchored
# EREs) + doom_name() decide what may go, everything else is protected.
DOOM_DEFS=$(sed -n '/^DOOM_GLOBAL=(/,/^)/p' "$CLEAN_SH")
DOOM_FN=$(sed -n '/^doom_name() {/,/^}/p' "$CLEAN_SH")
if [ -z "$KEEP_FN" ] || [ -z "$DOOM_FN" ] || [ -z "$DOOM_DEFS" ] || [ "$(printf '%s\n' "$KEEP_DEFS" | grep -c .)" -ne 3 ]; then
  _fail "§6ah: could not slice KEEP/KEEP_GLOB/KEEP_GLOBAL/DOOM_GLOBAL + keep_name()/doom_name() out of $CLEAN_SH — the sweeper's shape moved; the unit below is inert"
else
  keeps() {  # keeps <store-kind> <name> -> 0 iff the live sweeper would keep it
    (STORE_KIND="$1"; KEEP_EXTRA=""; eval "$KEEP_DEFS"; eval "$KEEP_FN"; keep_name "$2") >/dev/null 2>&1
  }
  sweeps() { # sweeps <store-kind> <name> -> 0 iff the live sweeper would DELETE it (not kept, and doomed)
    (STORE_KIND="$1"; KEEP_EXTRA=""; DELETE_EXTRA=""; eval "$KEEP_DEFS"; eval "$DOOM_DEFS"; eval "$KEEP_FN"; eval "$DOOM_FN"; ! keep_name "$2" && doom_name "$2") >/dev/null 2>&1
  }
  # The names the live bring-up scripts mint, read from the scripts themselves
  # so a renamed ladder maker / seed trader / bot prefix trips this, not a sweep.
  LADDER_6AH=$(printf '%s\n' "$(uncommented scripts/play_start.sh)" | grep -E '^LADDER_MAKERS=' | head -1 | sed 's/^LADDER_MAKERS=//; s/"//g')
  [ -n "$LADDER_6AH" ] && _ok "§6ah: play_start.sh names its ladder makers ($LADDER_6AH)" || _fail "§6ah: could not read LADDER_MAKERS out of play_start.sh"
  src_has "§6ah: deploy.sh's seed traders are mdex-seed-N"        "$(uncommented scripts/deploy.sh)"             'traders+=("mdex-seed-$k")'
  src_has "§6ah: deploy.sh's cloud bots are simbot_N"             "$(uncommented scripts/deploy.sh)"             'id="simbot_$i"'
  src_has "§6ah: sim_trading.sh defaults BOT_PREFIX to simbot"    "$(uncommented scripts/sim_trading.sh)"        'BOT_PREFIX="${BOT_PREFIX:-simbot}"'
  src_has "§6ah: trading_simulation.sh defaults BOT_PREFIX to mdxbot" "$(uncommented scripts/trading_simulation.sh)" 'BOT_PREFIX="${BOT_PREFIX:-mdxbot}"'
  src_has "§6ah: lib/bots.sh names a fleet <target>bot_N"          "$(uncommented scripts/lib/bots.sh)"           'BOT_PREFIX="${target}bot"'
  src_has "§6ah: seed_margin_book.sh prefixes its positions mb_"   "$(uncommented scripts/seed_margin_book.sh)"   'ID="${ID_PFX:-mb}_${PFX}'
  for NAME in $LADDER_6AH anonymous alice bob charlie dave eve mdex-seed-7 simbot_3 localbot_12 enginebot_2 subnetbot_1 mdxbot_1 trader_04 mb_L20_1; do
    if keeps ICP_HOME "$NAME"; then _ok "§6ah: a seat sweep keeps $NAME"
    else _fail "§6ah: a seat sweep would DELETE $NAME — a standing fixture or a venue-lifetime name the bring-up scripts sign with; its on-venue positions would be orphaned"; fi
  done
  for NAME in swapper buyer taker battery rp_whale sdb_maker4 loadtrader_0001 mdex-play-mm alice2 postest-a multidex mdex-engine; do
    if keeps ICP_HOME "$NAME"; then _fail "§6ah: a seat sweep keeps $NAME — a leaked suite name (or a global-only wallet) must go from a seat store, or the store regrows to the CMC mint-cap abort"
    else _ok "§6ah: a seat sweep deletes $NAME"; fi
  done
  for NAME in multidex mdex-engine mdex-bots; do
    if keeps GLOBAL "$NAME"; then _ok "§6ah: a --global sweep keeps the operator's $NAME wallet"
    else _fail "§6ah: a --global sweep would DELETE $NAME — the operator's remote-deploy / fleet wallet"; fi
  done
  # The GLOBAL store (task 1789609264): the 2026-09-17 dry run listed the cold
  # recovery key and another project's deploy identities among 244 deletions.
  # The belt: those names are in KEEP_GLOBAL (exact or glob) unconditionally.
  for NAME in multidex-recovery opensaas opensaas-engine opensaas-engine-key opensaas-minter ost-connector-e2e ost-deploy other-connector-key; do
    if keeps GLOBAL "$NAME"; then _ok "§6ah: a --global sweep KEEPS $NAME (recovery key / another project's identity - the belt)"
    else _fail "§6ah: a --global sweep would DELETE $NAME — the cold recovery key or another project's deploy identity, no backups"; fi
  done
  # The braces: a name with NO multidex fixture shape is PROTECTED by default
  # on the global store - not kept, not doomed - whatever project it belongs to.
  for NAME in some-other-wallet my-deploy-key wallet2 kx30 hmtrader agentprobe seat1-denial-probe; do
    if keeps GLOBAL "$NAME"; then _fail "§6ah: $NAME is in KEEP — it should be merely PROTECTED (unshaped), so the seat-store half of the test below stays honest"
    elif sweeps GLOBAL "$NAME"; then _fail "§6ah: a --global sweep would DELETE $NAME — it matches no multidex fixture shape and must be protected by default"
    else _ok "§6ah: a --global sweep protects the unshaped $NAME"; fi
  done
  # ...while every fixture shape the suites mint still goes from the global
  # store: <pfx>_<role>, hmtraderN, the bare \$ID words, seed.sh's phantoms.
  for NAME in amm_seed escape_mallory ins_liq1 slip_whale attr_maker probe_u h30_virgin_12345 loadtrader_0001 amm_uA hmtrader3 swapper buyer taker battery img imgg insf2 mpool2 bunwindmm liqp brdgrogue; do
    if sweeps GLOBAL "$NAME"; then _ok "§6ah: a --global sweep deletes the fixture $NAME"
    else _fail "§6ah: a --global sweep would PROTECT $NAME — a suite fixture shape; the global store regrows to the CMC mint-cap abort"; fi
  done
  # The seat store keeps its NEGATIVE default: everything outside KEEP goes,
  # shaped or not (only this repo writes there).
  for NAME in some-other-wallet kx30 rp_whale; do
    if sweeps ICP_HOME "$NAME"; then _ok "§6ah: a seat sweep still deletes $NAME (no positive list on a seat store)"
    else _fail "§6ah: a seat sweep would keep $NAME — the positive list must apply to the GLOBAL store only"; fi
  done
  # The positive list is pinned against the SUITES: every literal a test
  # mints through mdx_identity_new (bare, quoted, or a VAR=literal assigned
  # on the same line / a plain VAR=literal line for a VAR the file mints)
  # must be either kept or swept on --global. A new bare name that matches
  # no shape would otherwise survive every global sweep - rename it to the
  # <pfx>_<role> convention or add it to DOOM_GLOBAL's alternation.
  # mint_names <uncommented suite text> → every literal name it mints through
  # mdx_identity_new, one per line: bare or quoted, or a $VAR whose literal is
  # assigned in the file. ONE copy, shared by the scan below and its negative
  # control (task 1793507323), so the control drives the needles the scan runs.
  mint_names() {
    local UNC=$1 LITS VARS v
    LITS=$(printf '%s\n' "$UNC" | grep -oE 'mdx_identity_new +"?[A-Za-z0-9_-]+"?([[:space:]]|;|$)' | sed -E 's/mdx_identity_new +"?([A-Za-z0-9_-]+)"?.*/\1/')
    VARS=$(printf '%s\n' "$UNC" | grep -oE 'mdx_identity_new +"?\$[A-Z][A-Z0-9_]*"?' | sed -E 's/.*\$([A-Z][A-Z0-9_]*).*/\1/' | sort -u)
    for v in $VARS; do
      LITS="$LITS
$(printf '%s\n' "$UNC" | grep -oE "(^|[[:space:];])$v=\"?[A-Za-z0-9_-]+\"?([[:space:]]|;|$)" | sed -E "s/.*$v=\"?([A-Za-z0-9_-]+)\"?.*/\1/")"
    done
    printf '%s\n' "$LITS"
  }
  SUITE_MINTS=""
  for f in tests/test_*.sh; do
    [ "$f" = "tests/test_deploy_hygiene.sh" ] && continue
    for lit in $(mint_names "$(uncommented "$f")"); do SUITE_MINTS="$SUITE_MINTS $f:$lit"; done
  done
  MINT_N=0; MINT_BAD=""
  for pair in $SUITE_MINTS; do
    lit=${pair#*:}; MINT_N=$((MINT_N + 1))
    keeps GLOBAL "$lit" || sweeps GLOBAL "$lit" || MINT_BAD="$MINT_BAD $pair"
  done
  if [ "$MINT_N" -lt 100 ]; then _fail "§6ah: the suite-mint scan found only $MINT_N literal names (expected 100+) — the extraction is inert, the positive list is unpinned"
  elif [ -z "$MINT_BAD" ]; then _ok "§6ah: all $MINT_N literal names the suites mint are kept or swept by --global (the positive list covers the suites)"
  else _fail "§6ah: suite fixtures a --global sweep would PROTECT (rename to <pfx>_<role> or extend DOOM_GLOBAL):$MINT_BAD"; fi
  # negative control for the extraction itself (task 1793507323): the SAME
  # mint_names over a two-line fixture minting one name through a $VAR and one
  # bare must yield both. A regex error (rc 2, read by a raw grep as "no
  # match") in the VARS needle or the per-var lookup yields {bob} alone — red
  # here, where the floor (MINT_N ≥ 100; 170 of the 211 names are direct
  # literals) could not see the ~41 var-minted names go unchecked.
  MINT_FX=$(scratch_new mint_names_fixture.sh) || exit 1
  printf '%s\n' 'X=alice; mdx_identity_new "$X"' 'mdx_identity_new bob' > "$MINT_FX"
  MINT_CTL=$(mint_names "$(uncommented "$MINT_FX")" | sort | tr '\n' ' ')
  if [ "$MINT_CTL" = "alice bob " ]; then _ok "§6ah negative control: mint_names yields {alice, bob} from a \$VAR-minted and a bare mdx_identity_new"
  else _fail "§6ah negative control: mint_names yielded {${MINT_CTL% }} from 'X=alice; mdx_identity_new \"\$X\"' + 'mdx_identity_new bob', expected {alice bob} — the VARS needle or the per-var lookup is broken; the floor (MINT_N ≥ 100) cannot see the var-minted names go unchecked"; fi
fi
src_has "§6ah: the sweeper prints the protected set on the global store"      "$CLEAN_UNC" 'echo "protected ${#PROTECTED[@]} (GLOBAL store: no multidex fixture shape - left alone; DELETE_EXTRA='
src_has "§6ah: the protected line is printed whenever the store is GLOBAL"     "$CLEAN_UNC" 'if [ "$STORE_KIND" = "GLOBAL" ]; then'
src_has "§6ah: a seat store dooms everything outside KEEP"                     "$DOOM_FN"   '[ "$STORE_KIND" = "GLOBAL" ] || return 0'
src_has "§6ah: DELETE_EXTRA is honoured by doom_name only"                     "$DOOM_FN"   'for k in ${DELETE_EXTRA:-}; do case "$name" in $k) return 0 ;; esac; done'
src_lacks "§6ah: keep_name never reads DELETE_EXTRA (KEEP wins)"               "$KEEP_FN"   'DELETE_EXTRA'
src_has "§6ah: the classification asks keep_name before doom_name"             "$CLEAN_UNC" 'if keep_name "$name"; then KEPT+=("$name")'
src_has "§6ah: ...and files the rest as PROTECTED"                             "$CLEAN_UNC" 'else PROTECTED+=("$name"); fi'
src_has "§6ah: the sweeper prints the store it acts on"                   "$CLEAN_UNC" 'echo "identity store: $STORE_PATH ($STORE_KIND)"'
src_has "§6ah: the sweeper resolves ICP_HOME as the store"                "$CLEAN_UNC" 'STORE_KIND="ICP_HOME"; STORE_PATH="$ICP_HOME"'
src_has "§6ah: the sweeper refuses the GLOBAL store from inside a worktree" "$CLEAN_UNC" 'refusing to sweep the GLOBAL store from inside a worktree'
src_has "§6ah: the refusal is gated on --global"                          "$CLEAN_UNC" '[ "$TOPLEVEL" != "$PRIMARY" ] && ! $GLOBAL; then'
src_has "§6ah: the sweeper offers --dry-run"                              "$CLEAN_UNC" '--dry-run) DRY_RUN=true ;;'
src_has "§6ah: --dry-run deletes nothing"                                 "$CLEAN_UNC" 'DRY RUN - would delete ${#DOOMED[@]} of $total identities'
src_has "§6ah: run_tests.sh's teardown still sweeps (--yes)"              "$(uncommented tests/run_tests.sh)" 'scripts/cleanup_identities.sh" --yes'
# The refusal, LIVE: from a non-primary worktree with ICP_HOME unset the
# script must exit 2 before its first icp call (no store is read). From the
# primary checkout the same run would read the global store, so it is only
# exercised on a worktree.
TOP_6AH=$(git rev-parse --show-toplevel 2>/dev/null || true)
PRI_6AH=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
if [ -n "$TOP_6AH" ] && [ -n "$PRI_6AH" ] && [ "$TOP_6AH" != "$PRI_6AH" ]; then
  REF_OUT=$(env -u ICP_HOME bash "$CLEAN_SH" --dry-run 2>&1); REF_RC=$?
  if [ "$REF_RC" -eq 2 ] && printf '%s' "$REF_OUT" | grep -cF 'refusing to sweep the GLOBAL store' >/dev/null; then _ok "§6ah: with ICP_HOME unset on a worktree the sweeper refuses (rc 2) before reading any store"
  else _fail "§6ah: with ICP_HOME unset on a worktree the sweeper answered rc $REF_RC — expected a refusal (rc 2) naming the global store: $(printf '%s' "$REF_OUT" | head -2 | tr '\n' ' ')"; fi
else _ok "§6ah: primary checkout — the live worktree-refusal run is skipped (it would read the global store)"; fi
# The positive sweep, LIVE, against a FAKE global store (task 1789609264):
# icp-cli resolves its global store under $HOME, so a scratch HOME with
# ICP_HOME unset IS a global store to the script (STORE_KIND=GLOBAL, the
# refusal passed with --global) and to icp itself - the machine's real
# store is never opened. The fake store gets the recovery key, another
# project's identities, an unshaped stranger, the wallets, standing and
# venue-lifetime names, and suite fixtures; a --global --yes must delete
# ONLY the fixtures. Belt: the scratch store must start with anonymous
# alone, or the whole live block is skipped as a HOME override that failed.
FAKE_HOME=$(mktemp -d "${TEST_SCRATCH:-${TMPDIR:-/tmp}}/fakeglobal.XXXXXX")
fake_icp() { env -u ICP_HOME HOME="$FAKE_HOME" PATH="$HOME/.local/bin:$PATH" "$@"; }
fake_names() { fake_icp icp identity list 2>/dev/null | sed 's/^\*//' | awk '{print $1}' | sort | tr '\n' ' '; }
FAKE_STORE="$FAKE_HOME/Library/Application Support/org.dfinity.icp-cli"
if [ -z "$FAKE_HOME" ] || [ "$(fake_names)" != "anonymous " ]; then
  _fail "§6ah: the fake global store under HOME=$FAKE_HOME did not start as [anonymous] (got: $(fake_names)) — the HOME override is not isolating icp's store; the live --global run is SKIPPED rather than risk the real one"
else
  FAKE_SURVIVE="multidex-recovery opensaas-engine ost-connector-e2e some-other-wallet multidex mdex-bots alice mdex-play-mm-1 localbot_1"
  FAKE_DOOMED="amm_seed escape_mallory ins_liq1 hmtrader3 swapper img h30_virgin_123 loadtrader_0001"
  FAKE_MINT_FAIL=""
  for n in $FAKE_SURVIVE $FAKE_DOOMED; do fake_icp icp identity new "$n" --storage plaintext >/dev/null 2>&1 || FAKE_MINT_FAIL="$FAKE_MINT_FAIL $n"; done
  if [ -n "$FAKE_MINT_FAIL" ]; then
    _fail "§6ah: could not mint into the fake global store:$FAKE_MINT_FAIL — the live --global run is inert"
  else
    FAKE_BEFORE=$(fake_names)
    DRY_OUT=$(fake_icp bash "$CLEAN_SH" --global --dry-run 2>&1); DRY_RC=$?
    if [ "$DRY_RC" -eq 0 ] && [ "$(fake_names)" = "$FAKE_BEFORE" ]; then _ok "§6ah: --global --dry-run on the fake store deletes nothing (rc 0)"
    else _fail "§6ah: --global --dry-run on the fake store rc $DRY_RC / changed the store: before [$FAKE_BEFORE] after [$(fake_names)]"; fi
    src_has "§6ah: the dry run names the fake store as GLOBAL"                  "$DRY_OUT" "identity store: $FAKE_STORE (GLOBAL)"
    src_has "§6ah: the dry run prints the protected stranger"                   "$DRY_OUT" 'protected 1 (GLOBAL store: no multidex fixture shape - left alone; DELETE_EXTRA="name glob*" sweeps one deliberately): some-other-wallet'
    src_has "§6ah: the dry run would delete exactly the fixtures"               "$DRY_OUT" "DRY RUN - would delete $(echo $FAKE_DOOMED | wc -w | tr -d ' ') of $(echo $FAKE_SURVIVE $FAKE_DOOMED anonymous | wc -w | tr -d ' ') identities"
    LIVE_OUT=$(fake_icp bash "$CLEAN_SH" --global --yes 2>&1); LIVE_RC=$?
    FAKE_AFTER=$(fake_names)
    [ "$LIVE_RC" -eq 0 ] && _ok "§6ah: --global --yes on the fake store exits 0" || _fail "§6ah: --global --yes on the fake store exited $LIVE_RC: $(printf '%s' "$LIVE_OUT" | tail -3 | tr '\n' '|')"
    src_has "§6ah: the live run reports the fixture count deleted" "$LIVE_OUT" "deleted $(echo $FAKE_DOOMED | wc -w | tr -d ' ');"
    for n in anonymous $FAKE_SURVIVE; do
      if printf '%s\n' $FAKE_AFTER | grep -cx -- "$n" >/dev/null; then _ok "§6ah: fake global store: $n SURVIVES a --global --yes"
      else _fail "§6ah: fake global store: $n was DELETED by --global --yes (store after: $FAKE_AFTER)"; fi
    done
    for n in $FAKE_DOOMED; do
      if printf '%s\n' $FAKE_AFTER | grep -cx -- "$n" >/dev/null; then _fail "§6ah: fake global store: the fixture $n survived a --global --yes (store after: $FAKE_AFTER)"
      else _ok "§6ah: fake global store: the fixture $n is swept"; fi
    done
    # DELETE_EXTRA sweeps a protected name deliberately; KEEP still wins.
    EXTRA_OUT=$(DELETE_EXTRA="some-other-* multidex-recovery" fake_icp bash "$CLEAN_SH" --global --yes 2>&1)
    FAKE_AFTER2=$(fake_names)
    if printf '%s\n' $FAKE_AFTER2 | grep -cx -- some-other-wallet >/dev/null; then _fail "§6ah: DELETE_EXTRA=some-other-* left some-other-wallet in the fake store: $EXTRA_OUT"
    else _ok "§6ah: DELETE_EXTRA sweeps the named stranger from the fake store"; fi
    if printf '%s\n' $FAKE_AFTER2 | grep -cx -- multidex-recovery >/dev/null; then _ok "§6ah: DELETE_EXTRA naming multidex-recovery cannot take it (KEEP wins)"
    else _fail "§6ah: DELETE_EXTRA=multidex-recovery DELETED the recovery key — KEEP must win over DELETE_EXTRA"; fi
    src_has "§6ah: after the sweep the global store reports protected 0" "$EXTRA_OUT" 'protected 0 (GLOBAL store:'
  fi
fi
rm -rf "$FAKE_HOME"

# ── §6ai 3088509465: cold_start's banner reports the posture DEPLOYED, and names a bot log only for a fleet THIS run launched ─
# `deploy.sh local` on a seeded venue is `exec cold_start.sh --no-seed`, and
# the completion banner ended with `Mode    : play` + `Bot log : tail -f …`
# while the tree and the canister were both on #dev and no fleet had started
# (the log was a stale one from an earlier bring-up): MODE is the SEED-mode
# default, the posture guard that reads the tree is skipped on the no-seed
# path, and the bot-log line keyed on MODE=play. Now the Mode line derives
# from the LIVE getDeployMode with the comment-aware mdx_posture_of read —
# taken BEFORE the deploy — as its fallback, the no-seed update path is
# labelled distinctly, and the Bot log line is gated on a flag that only the
# two launch sites (play_start.sh's fleet, the --simulate launcher) set.
COLD_UNC=$(uncommented scripts/cold_start.sh)
src_lacks "§6ai: the banner no longer prints the seed-mode default as Mode" "$COLD_UNC" 'echo "  Mode    : $MODE"'
src_has "§6ai: the banner reads the live posture (getDeployMode, --identity pinned)" "$COLD_UNC" \
  "LIVE_POSTURE=\$(echo y | icp canister call backend getDeployMode '()' --query --identity anonymous"
src_has "§6ai: the pre-build fallback goes through mdx_posture_of (comment-aware)" "$COLD_UNC" \
  'BUILD_POSTURE="${SRC_POSTURE:-$(mdx_posture_of src/backend/main.mo'
src_has "§6ai: the Mode line prefers live over the pre-build read, never MODE" "$COLD_UNC" \
  'POSTURE_SHOWN="${LIVE_POSTURE:-${BUILD_POSTURE:-unresolved}}"'
src_has "§6ai: the Mode line prints the resolved posture"       "$COLD_UNC" 'echo "  Mode    : $POSTURE_SHOWN (seed: $MODE; $POSTURE_SRC)"'
src_has "§6ai: the no-seed update path is labelled distinctly"  "$COLD_UNC" 'echo "  Mode    : $POSTURE_SHOWN (update, no seed; $POSTURE_SRC)"'
assert_eq "§6ai: exactly two Mode lines (seed / no-seed), both from POSTURE_SHOWN" "2" \
  "$(printf '%s\n' "$COLD_UNC" | grep -cF 'echo "  Mode    : $POSTURE_SHOWN')"
assert_eq "§6ai: no other Mode line survives" "2" \
  "$(printf '%s\n' "$COLD_UNC" | grep -cF 'echo "  Mode    : ')"
# The fallback is read BEFORE the deploy: a tree edit mid-run cannot recolour
# the banner, and the no-seed path (which skips the posture guard) has a
# value at all. `uncommented` keeps line numbers, so the order is the source's.
COLD_BP_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'BUILD_POSTURE="${SRC_POSTURE:-$(mdx_posture_of' | head -1 | cut -d: -f1)
COLD_DEP_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'icp deploy --identity' | head -1 | cut -d: -f1)
if [ -n "$COLD_BP_LN" ] && [ -n "$COLD_DEP_LN" ] && [ "$COLD_BP_LN" -lt "$COLD_DEP_LN" ]; then
  _ok "§6ai: the pre-build posture read (line $COLD_BP_LN) precedes the icp deploy ($COLD_DEP_LN)"
else
  _fail "§6ai: the pre-build posture read (${COLD_BP_LN:-none}) does not precede the icp deploy (${COLD_DEP_LN:-none}) — the banner would report a post-deploy tree state"
fi
# Bot log: gated on the launch flag, never on the seed mode.
src_lacks "§6ai: the Bot log line no longer keys on MODE=play" "$COLD_UNC" '[ "$MODE" = "play" ] && ! $NO_SIMULATE_EXPLICIT'
src_has "§6ai: the Bot log line sits under the launch flag"     "$COLD_UNC" 'if $FLEET_STARTED; then'
assert_eq "§6ai: exactly one Bot log line" "1" "$(printf '%s\n' "$COLD_UNC" | grep -cF 'echo "  Bot log : tail -f $MDX_RUN_DIR/bots-local.log"')"
src_has "§6ai: the skip branch says fleet NOT started (play_start's spelling)" "$COLD_UNC" 'echo "  Bots    : fleet NOT started ($FLEET_WHY) — bash scripts/start_bots_local.sh"'
src_has "§6ai: a fleet an EARLIER run recorded is named, not hidden"          "$COLD_UNC" 'fleet NOT started by this run ($FLEET_WHY) — a fleet recorded by an earlier run is still trading'
# The flag is initialised false once and set true at exactly the two launch
# sites — one after play_start.sh returns (a live PID file after its
# unconditional stop-then-start is this run's fleet, and only when the
# --no-simulate knob did not hold it back), one after start_bots_local.sh
# succeeds in the --simulate launcher — and both precede the banner gate.
assert_eq "§6ai: FLEET_STARTED is initialised false once" "1" "$(printf '%s\n' "$COLD_UNC" | grep -cE '^FLEET_STARTED=false$')"
assert_eq "§6ai: FLEET_STARTED is set true at exactly two launch sites" "2" "$(printf '%s\n' "$COLD_UNC" | grep -cF 'FLEET_STARTED=true')"
src_has "§6ai: the play launch site checks the knob AND a live recorded PID" "$COLD_UNC" 'if ! $NO_SIMULATE_EXPLICIT && fleet_alive; then FLEET_STARTED=true; fi'
src_has "§6ai: fleet_alive reads the recorded PID file, kill -0 on that one PID" "$COLD_UNC" '[ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null'
COLD_FS0_LN=$(printf '%s\n' "$COLD_UNC" | grep -nE '^FLEET_STARTED=false$' | head -1 | cut -d: -f1)
COLD_PS_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'bash "$SCRIPT_DIR/play_start.sh"' | head -1 | cut -d: -f1)
COLD_FS1_LN=$(printf '%s\n' "$COLD_UNC" | grep -nF 'FLEET_STARTED=true' | sed -n 1p | cut -d: -f1)
COLD_SB_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'bash "$SCRIPT_DIR/start_bots_local.sh"' | head -1 | cut -d: -f1)
COLD_FS2_LN=$(printf '%s\n' "$COLD_UNC" | grep -nF 'FLEET_STARTED=true' | sed -n 2p | cut -d: -f1)
COLD_GATE_LN=$(printf '%s\n' "$COLD_UNC" | grep -nF 'if $FLEET_STARTED; then' | head -1 | cut -d: -f1)
if [ -n "$COLD_FS0_LN" ] && [ -n "$COLD_PS_LN" ] && [ -n "$COLD_FS1_LN" ] && [ -n "$COLD_SB_LN" ] && [ -n "$COLD_FS2_LN" ] && [ -n "$COLD_GATE_LN" ] \
   && [ "$COLD_FS0_LN" -lt "$COLD_PS_LN" ] && [ "$COLD_PS_LN" -lt "$COLD_FS1_LN" ] && [ "$COLD_FS1_LN" -lt "$COLD_SB_LN" ] \
   && [ "$COLD_SB_LN" -lt "$COLD_FS2_LN" ] && [ "$COLD_FS2_LN" -lt "$COLD_GATE_LN" ]; then
  _ok "§6ai: init ($COLD_FS0_LN) < play_start ($COLD_PS_LN) < flag ($COLD_FS1_LN) < start_bots ($COLD_SB_LN) < flag ($COLD_FS2_LN) < banner gate ($COLD_GATE_LN)"
else
  _fail "§6ai: launch-flag order broken: init=${COLD_FS0_LN:-none} play_start=${COLD_PS_LN:-none} flag1=${COLD_FS1_LN:-none} start_bots=${COLD_SB_LN:-none} flag2=${COLD_FS2_LN:-none} gate=${COLD_GATE_LN:-none}"
fi

# ── §6aj 1788520600: no exact/delta assertion rides a `grep -c` over newline-stripped CLI output ─
# `icp canister call … --query | tr -d '\n' | grep -c PATTERN` counts matching
# LINES, and after the strip the whole reply is ONE line — the count is 0 or 1
# whatever the number of records. Presence (-ge 1 / -gt 0) and absence (= 0)
# checks are sound on it; an "exactly one" (= 1), a delta (= $((BEFORE + 1)),
# -gt "$BEFORE") or any count above 1 is hollow — it passed H-10's first green
# run with the wrong count (bd40337), and it turned test_unfunded_maker_notice
# §4 falsely RED on a rerun (before=1 after=1, task 1788493033). The sound
# shape is an OCCURRENCE count over a field that appears exactly once per
# record: `grep -o 'PATTERN' | wc -l | tr -d ' '` (that suite's occ()).
# The scan, on the comment-stripped source of every tests/*.sh but this file:
#   saturated: NAME=$( … tr -d '<set holding \n>' … | grep -c …)      (one step)
#              NAME=$( echo|printf … "$STRIPPED" | grep -c …)  and
#              NAME=$( grep -c … <<< "$STRIPPED")                    (two steps)
#              where STRIPPED=$( … tr -d '<set holding \n>' …) or (… | flat)
#              under a tr -d flat(); a sed/tr that RE-INSERTS \n (one record
#              per line) exempts the line, as does any stage between the echo
#              and the grep — those are per-record counts, not line counts.
#   hollow:    a comparison with a saturated NAME on either side whose operator
#              is = == != -eq -ne with an other operand that is not 0, or is
#              -gt -ge -lt -le with an other operand that is not the literal
#              0 or 1 (a literal above 1 is unreachable; a variable or an
#              arithmetic expression is a delta on a saturated count).
# Non-vacuity: the scanner is driven against a scratch fixture carrying every
# banned and every tolerated shape and must report exactly the banned ones
# before its silence on the suites is believed.
SATC_STRIP="tr -d ['\"][^'\"]*[\\\\]n"
SATC_RESPLIT="(sed [^|]*[\\\\]n|tr [^|]*'[\\\\]n'|tr [^|]*\"[\\\\]n\")"
SATC_OPS="(=|==|!=|-eq|-ne|-gt|-ge|-lt|-le)"
SATC_NAME="[A-Za-z_][A-Za-z0-9_]*"
satc_verdict() {  # satc_verdict <file> <line> <var> <op> <other operand> → one hit line when the comparison is hollow
  case "$4" in
    =|==|!=|-eq|-ne) [ "$5" = "0" ] && return 0 ;;
    -gt|-ge|-lt|-le) case "$5" in 0|1) return 0 ;; esac ;;
  esac
  echo "$1:$2: $3 $4 $5"
}
satc_scan() {  # satc_scan <file> → hit lines (file:line: VAR op OTHER), nothing when clean
  local f=$1 code sat="" stripped="" has_flat=0 v
  code=$(uncommented "$f")
  printf '%s\n' "$code" | grep -cE "^flat\(\)[[:space:]]*\{[[:space:]]*$SATC_STRIP" >/dev/null && has_flat=1
  sat=$(printf '%s\n' "$code" | grep -E "^[[:space:]]*(local |export )?$SATC_NAME=\\\$\(.*$SATC_STRIP.*\|[[:space:]]*grep -c" \
        | grep -vE "$SATC_STRIP.*$SATC_RESPLIT.*grep -c" \
        | sed -E "s/^[[:space:]]*(local |export )?($SATC_NAME)=.*/\2/" | sort -u)
  if [ "$has_flat" = 1 ]; then
    stripped=$(printf '%s\n' "$code" | grep -E "^[[:space:]]*(local |export )?$SATC_NAME=\\\$\(.*($SATC_STRIP|\| *flat\))" \
        | grep -v 'grep -c' | grep -vE "$SATC_RESPLIT" \
        | sed -E "s/^[[:space:]]*(local |export )?($SATC_NAME)=.*/\2/" | sort -u)
  else
    stripped=$(printf '%s\n' "$code" | grep -E "^[[:space:]]*(local |export )?$SATC_NAME=\\\$\(.*$SATC_STRIP" \
        | grep -v 'grep -c' | grep -vE "$SATC_RESPLIT" \
        | sed -E "s/^[[:space:]]*(local |export )?($SATC_NAME)=.*/\2/" | sort -u)
  fi
  for v in $stripped; do
    sat="$sat
$(printf '%s\n' "$code" | grep -E "^[[:space:]]*(local |export )?$SATC_NAME=\\\$\(((echo|printf)[^|]*\\\$(\{$v[:}]|$v[^A-Za-z0-9_])[^|]*\|[[:space:]]*grep -c|grep -c[^<]*<<<[[:space:]]*\"?\\\$(\{$v[:}]|$v[^A-Za-z0-9_]))" \
        | sed -E "s/^[[:space:]]*(local |export )?($SATC_NAME)=.*/\2/")"
  done
  sat=$(printf '%s\n' "$sat" | grep . | sort -u)
  [ -z "$sat" ] && return 0
  for v in $sat; do
    # the saturated count on the LEFT of the operator …
    printf '%s\n' "$code" | grep -nE "\\\$(\{$v(:-[^}]*)?\}|$v)\"?[[:space:]]*$SATC_OPS[[:space:]]+(\"[^\"]*\"|[^][:space:]]+)" | while IFS= read -r line; do
      printf '%s\n' "$line" | grep -oE "\\\$(\{$v(:-[^}]*)?\}|$v)\"?[[:space:]]*$SATC_OPS[[:space:]]+(\"[^\"]*\"|[^][:space:]]+)" | while IFS= read -r frag; do
        satc_verdict "$f" "${line%%:*}" "$v" \
          "$(printf '%s' "$frag" | sed -E "s/^.*\"?[[:space:]]*$SATC_OPS[[:space:]]+.*$/\1/")" \
          "$(printf '%s' "$frag" | sed -E "s/^.*[[:space:]]$SATC_OPS[[:space:]]+//; s/^\"//; s/\"$//")"
      done
    done
    # … and on the RIGHT
    printf '%s\n' "$code" | grep -nE "(\"[^\"]*\"|[^][:space:]]+)[[:space:]]+$SATC_OPS[[:space:]]+\"?\\\$(\{$v(:-[^}]*)?\}|$v)\"?" | while IFS= read -r line; do
      printf '%s\n' "$line" | grep -oE "(\"[^\"]*\"|[^][:space:]]+)[[:space:]]+$SATC_OPS[[:space:]]+\"?\\\$(\{$v(:-[^}]*)?\}|$v)\"?" | while IFS= read -r frag; do
        satc_verdict "$f" "${line%%:*}" "$v" \
          "$(printf '%s' "$frag" | sed -E "s/^.*[[:space:]]$SATC_OPS[[:space:]]+.*$/\1/")" \
          "$(printf '%s' "$frag" | sed -E "s/[[:space:]]+$SATC_OPS[[:space:]]+.*$//; s/^\"//; s/\"$//")"
      done
    done
  done
}
# (a) the scanner sees what it claims to: every banned shape, none of the tolerated ones
SATC_FX=$(scratch_new satc_fixture.sh) || exit 1
cat > "$SATC_FX" <<'EOF'
A=$(adm getX '()' --query | tr -d '\n' | grep -c 'mid-match' || true)
B=$(adm getX '()' --query | tr -d '_\n' | grep -c 'id = ')
[ "${A:-0}" = "1" ] && ok "exactly one (hollow)"
[ "$B" -gt "${A:-0}" ] && ok "delta (hollow)"
[ "${B:-0}" -ge 1 ] && ok "presence (fine)"
[ "${B:-9}" = "0" ] && ok "absence (fine)"
[ "$A" -eq 0 ] && ok "absence -eq (fine)"
[ "$((A + 1))" = "$B" ] && ok "arithmetic on the right (hollow)"
ROWS=$(adm getT '()' --query | tr -d '_\n' | tr -s ' ')
NT=$(echo "$ROWS" | grep -c 'trade = record' || true)
[ "${NT:-0}" = "$((BEFORE + 1))" ] && ok "two-step delta (hollow)"
[ "${NT:-0}" -ge 1 ] && ok "two-step presence (fine)"
HS=$(grep -c 'x' <<< "$ROWS")
[ "$HS" -ge 2 ] && ok "here-string above 1 (hollow)"
ROWSTAIL=$(printf '%s\n' "$ROWS" | grep -c 'y')
[ "$ROWSTAIL" = "4" ] && ok "prefix-named sibling (hollow, name boundary)"
MYW=$(usr getMyOrders '()' --query | tr -d '_\n' | tr -s ' ')
OLD41=$(echo "$MYW" | sed 's/record {/\nrecord {/g' | grep -cE "price = 41")
[ "${OLD41:-0}" = "2" ] && ok "re-split per record (fine)"
N=$(echo "$MYW" | grep -o 'id = ' | wc -l | tr -d ' ')
[ "$N" = "3" ] && ok "occurrence count (fine)"
flat() { tr -d '_\n'; }
FL=$(adm getX '()' --query | flat)
NF=$(echo "$FL" | grep -c 'x')
[ "$NF" = "2" ] && ok "flat() helper (hollow)"
# Z=$(adm getX '()' | tr -d '\n' | grep -c y); [ "$Z" = "5" ]   comment line: exempt
EOF
SATC_WANT="11: NT = \$((BEFORE + 1))
14: HS -ge 2
16: ROWSTAIL = 4
25: NF = 2
3: A = 1
4: A -gt \$B
4: B -gt \${A:-0}
8: B = \$((A + 1))"
SATC_GOT=$(satc_scan "$SATC_FX" | sed "s#^$SATC_FX:##" | sort)
if [ "$SATC_GOT" = "$SATC_WANT" ]; then _ok "§6aj: the saturated-count scanner reports exactly the eight banned fixture shapes (the flat() helper's NF among them) and none of the six tolerated ones"
else _fail "§6aj: the scanner's fixture verdicts drifted — its silence on the suites cannot be trusted; got: $(printf '%s' "$SATC_GOT" | tr '\n' ';') want: $(printf '%s' "$SATC_WANT" | tr '\n' ';')"; fi
# (a′) the no-flat branch (task 1793507323): the fixture defines flat(), so (a)
# takes satc_scan's flat branch; the same fixture with that definition deleted
# takes the other one — FL's `| flat` capture is no longer a stripped one, so
# NF's comparison is not a verdict and the seven others still are. Both
# stripped= branches and both re-split exclusions are under the fixture control.
SATC_FX_NOFLAT=$(scratch_new satc_fixture_noflat.sh) || exit 1
sed '/^flat() {/d' "$SATC_FX" > "$SATC_FX_NOFLAT"
SATC_WANT_NOFLAT=$SATC_WANT; grep_filter -F SATC_WANT_NOFLAT '25: NF = 2'
SATC_GOT_NOFLAT=$(satc_scan "$SATC_FX_NOFLAT" | sed "s#^$SATC_FX_NOFLAT:##" | sort)
if [ "$SATC_GOT_NOFLAT" = "$SATC_WANT_NOFLAT" ]; then _ok "§6aj: without flat() the scanner takes its no-flat branch and reports the seven shapes that remain (NF's | flat capture is no longer a stripped one)"
else _fail "§6aj: the no-flat branch's fixture verdicts drifted — got: $(printf '%s' "$SATC_GOT_NOFLAT" | tr '\n' ';') want: $(printf '%s' "$SATC_WANT_NOFLAT" | tr '\n' ';')"; fi
# (b) the suites
SATC_HITS=""
for f in tests/*.sh; do
  [ "$f" = tests/test_deploy_hygiene.sh ] && continue
  h=$(satc_scan "$f")
  [ -n "$h" ] && SATC_HITS="$SATC_HITS $(printf '%s' "$h" | tr '\n' ' ')"
done
if [ -z "$SATC_HITS" ]; then _ok "§6aj: no suite asserts an exact or delta count on a grep -c over newline-stripped CLI output (0 or 1 by construction)"
else _fail "§6aj: an exact/delta assertion rides a grep -c over a newline-stripped (tr -d) reply — the count saturates at 1, so 'exactly one' passes on any positive count and a before/after delta reads before=1 after=1; count occurrences instead (grep -o 'FIELD' | wc -l | tr -d ' ' over a field that appears once per record, test_unfunded_maker_notice's occ()):$SATC_HITS"; fi
# (c) the suite the rule came from keeps its occurrence-count helper and routes §4's before/after pair through it
UFM_UNC=$(uncommented tests/test_unfunded_maker_notice.sh)
src_has  "§6aj: test_unfunded_maker_notice defines occ() as grep -o | wc -l"            "$UFM_UNC" "occ() { grep -o \"\$1\" | wc -l | tr -d ' '; }"
src_has  "§6aj: notice_count is an occurrence count over the stripped reply"            "$UFM_UNC" "backend getMyReleaseRejections '()' --query | tr -d '\\n' | occ 'mid-match'; }"
src_has  "§6aj: §4's before-count routes through notice_count"                          "$UFM_UNC" 'R0=$(notice_count ufm_m)'
src_has  "§6aj: §4's after-count routes through notice_count"                           "$UFM_UNC" 'R1=$(notice_count ufm_m)'
src_lacks "§6aj: no grep -c 'mid-match' survives in test_unfunded_maker_notice"          "$UFM_UNC" "grep -c 'mid-match'"

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

# H-27 (F5-Bridge): the AMOUNT CEILING. `amount` is an unbounded Nat; a
# ~100 KB one relayed into the DEX made its refusal's Nat.toText (Θ(bits²))
# burn the whole 40 B instruction budget. The ceiling is a fixed constant
# (2^128, the value H-15's brief names for the DEX side, so both halves
# agree), and ORDER IS THE PROPERTY: the check must precede the in-flight
# guard, the write-ahead and the DEX send — line numbers inside the
# extracted function body, not mere presence. The strand hook writes the
# same rows, so it wears the same gate. And no refusal may format the amount
# (that formatting is the cost the gate exists to avoid).
src_has "bridge declares the amount ceiling as 2^128" "$BRIDGE_SRC" "AMOUNT_CEILING : Nat = 2 ** 128"
src_has "bridge's ceiling refusal text is a constant"  "$BRIDGE_SRC" "AMOUNT_CEILING_MSG : Text"
src_lacks "no Bridge refusal formats the caller's amount" "$(printf '%s\n' "$BRIDGE_SRC" | mo_code)" "Nat.toText(amount"
SIM_CODE=$(printf '%s\n' "$SIM_FN" | mo_code)
SIM_CEIL_LN=$(printf '%s\n' "$SIM_CODE" | grep -n "amount > AMOUNT_CEILING" | head -1 | cut -d: -f1)
SIM_LOCK_LN=$(printf '%s\n' "$SIM_CODE" | grep -n "Map.add(admitting" | head -1 | cut -d: -f1)
SIM_WRITE_LN=$(printf '%s\n' "$SIM_CODE" | grep -n "Map.add(admittedUnits" | head -1 | cut -d: -f1)
SIM_SEND_LN=$(printf '%s\n' "$SIM_CODE" | grep -n "dexAdmitCalls += 1" | head -1 | cut -d: -f1)
SIM_AWAIT_LN=$(printf '%s\n' "$SIM_CODE" | grep -n "await dex.playDepositReserve" | head -1 | cut -d: -f1)
if [ -n "$SIM_CEIL_LN" ] && [ -n "$SIM_LOCK_LN" ] && [ -n "$SIM_WRITE_LN" ] && [ -n "$SIM_AWAIT_LN" ] \
   && [ "$SIM_CEIL_LN" -lt "$SIM_LOCK_LN" ] && [ "$SIM_LOCK_LN" -lt "$SIM_WRITE_LN" ] && [ "$SIM_WRITE_LN" -lt "$SIM_AWAIT_LN" ]; then
  _ok "devSimulateDeposit: ceiling ($SIM_CEIL_LN) < in-flight guard ($SIM_LOCK_LN) < write-ahead ($SIM_WRITE_LN) < DEX send ($SIM_AWAIT_LN)"
else
  _fail "devSimulateDeposit: ceiling check must precede the guard, the write-ahead and the DEX send: ceiling=${SIM_CEIL_LN:-none} guard=${SIM_LOCK_LN:-none} write=${SIM_WRITE_LN:-none} send=${SIM_AWAIT_LN:-none}"
fi
# The send counter is the live "no DEX call" observable (getBridgeStats
# .dexAdmitCalls): it must count at the send itself — the line before the
# await, never after it (a trapped continuation would then miss it; #55 (d):
# an upgrade cannot land inside the await, so a trap is the only such shape).
if [ -n "$SIM_SEND_LN" ] && [ -n "$SIM_AWAIT_LN" ] && [ "$SIM_SEND_LN" -lt "$SIM_AWAIT_LN" ] && [ $((SIM_AWAIT_LN - SIM_SEND_LN)) -le 2 ]; then
  _ok "devSimulateDeposit: the DEX send counter increments at the send ($SIM_SEND_LN → await $SIM_AWAIT_LN)"
else
  _fail "devSimulateDeposit: dexAdmitCalls must increment immediately before the playDepositReserve await: counter=${SIM_SEND_LN:-none} await=${SIM_AWAIT_LN:-none}"
fi
src_has "getBridgeStats exposes the DEX send counter" "$(mo_func src/bridge/main.mo "func getBridgeStats()")" "dexAdmitCalls"
STRAND_FN=$(mo_func src/bridge/main.mo "func devTestStrandAdmission(")
[ -n "$STRAND_FN" ] || _fail "could not extract devTestStrandAdmission()"
STRAND_CODE=$(printf '%s\n' "$STRAND_FN" | mo_code)
STRAND_CEIL_LN=$(printf '%s\n' "$STRAND_CODE" | grep -n "amount > AMOUNT_CEILING" | head -1 | cut -d: -f1)
STRAND_WRITE_LN=$(printf '%s\n' "$STRAND_CODE" | grep -n "Map.add(admittedUnits" | head -1 | cut -d: -f1)
if [ -n "$STRAND_CEIL_LN" ] && [ -n "$STRAND_WRITE_LN" ] && [ "$STRAND_CEIL_LN" -lt "$STRAND_WRITE_LN" ]; then
  _ok "devTestStrandAdmission: ceiling ($STRAND_CEIL_LN) precedes its write ($STRAND_WRITE_LN)"
else
  _fail "devTestStrandAdmission: ceiling check must precede the write: ceiling=${STRAND_CEIL_LN:-none} write=${STRAND_WRITE_LN:-none}"
fi

# H-15 (F5-DEX): the DEX half of the same ceiling. The three Bridge-facing
# updates (creditAndRegister, playDepositReserve, the legacy playDepositAdmit)
# take unbounded Nats from the relay; each must refuse above the SAME 2^128
# (SafeMath.RELAY_CEILING — one constant, so the halves cannot drift) BEFORE
# the replay-seq compare, the valuation and any write — line order inside the
# extracted bodies, as for the Bridge. And their refusal texts may format a
# caller-derived value ONLY through SafeMath.natDisplay (digits at or below
# the ceiling, a clamp text above): no Nat.toText of amount/seq/creditAmt/
# prevSeq/the valuation anywhere in those bodies.
src_has "SafeMath declares the relay ceiling as 2^128 (literal)" "$(cat src/backend/lib/SafeMath.mo)" "RELAY_CEILING : Nat = 340_282_366_920_938_463_463_374_607_431_768_211_456"
src_has "SafeMath's natDisplay clamps above the ceiling"      "$(mo_func src/backend/lib/SafeMath.mo "func natDisplay(")" "RELAY_CEILING_TEXT"
H15_BACKEND_SRC=$(cat src/backend/main.mo)
src_has "backend's ceiling is SafeMath's (transient alias)"   "$H15_BACKEND_SRC" "transient let RELAY_CEILING : Nat = SafeMath.RELAY_CEILING"
src_has "backend's ceiling refusal text is a constant"        "$H15_BACKEND_SRC" "transient let RELAY_CEILING_MSG : Text"
for spec in \
  "creditAndRegister|Map.get(creditedSeq|amount > RELAY_CEILING or seq > RELAY_CEILING" \
  "playDepositReserve|Map.get(playAdmitSeq|amount > RELAY_CEILING or seq > RELAY_CEILING" \
  "playDepositAdmit|markValueUsdFresh(token, amount|amount > RELAY_CEILING" ; do
  FN_NAME=${spec%%|*}; REST=${spec#*|}; FIRST_USE=${REST%%|*}; GATE=${REST#*|}
  FN_BODY=$(mo_func src/backend/main.mo "func $FN_NAME(")
  [ -n "$FN_BODY" ] || { _fail "could not extract $FN_NAME()"; continue; }
  FN_CODE=$(printf '%s\n' "$FN_BODY" | mo_code)
  GATE_LN=$(printf '%s\n' "$FN_CODE" | grep -n -F "$GATE" | head -1 | cut -d: -f1)
  USE_LN=$(printf '%s\n' "$FN_CODE" | grep -n -F "$FIRST_USE" | head -1 | cut -d: -f1)
  if [ -n "$GATE_LN" ] && [ -n "$USE_LN" ] && [ "$GATE_LN" -lt "$USE_LN" ]; then
    _ok "$FN_NAME: relay ceiling ($GATE_LN) precedes its first use of the value ($USE_LN)"
  else
    _fail "$FN_NAME: the relay-ceiling check must precede the seq compare/valuation: ceiling=${GATE_LN:-none} use=${USE_LN:-none}"
  fi
  for needle in "Nat.toText(amount" "Nat.toText(seq" "Nat.toText(creditAmt" "Nat.toText(prevSeq" "Nat.toText(v /" "Nat.toText(v)"; do
    src_lacks "$FN_NAME never Nat.toText's a caller-derived value ($needle)" "$FN_CODE" "$needle"
  done
done
src_has "creditAndRegister's pendingUnits hint wears the ceiling" "$(mo_func src/backend/main.mo "func creditAndRegister(" | mo_code)" "Option.get(pendingUnits, 0) > RELAY_CEILING"
src_has "playDepositAdmit's outstanding hints wear the ceiling"   "$(mo_func src/backend/main.mo "func playDepositAdmit(" | mo_code)" "a > RELAY_CEILING"

# H-14 (F26): the uptime sampler credits only the depth the owner's AVAILABLE
# balance could honour at sample time. Resting orders reserve nothing, so a
# sampler that read (quantity − filled) × price off the order record let a
# player rest $500/side, move the backing away, and keep L4's behavioural
# half on quotes that could never fill. Each market's bids draw on the
# owner's available QUOTE and its asks on the owner's available BASE (both
# through getAvailable — balance minus the staged soft-lock, the same number
# the engine funds a fill from), each order crediting Nat.min(its value, the
# budget left). The fixture (tests/test_uptime_funding.sh) lands samples on
# demand through devTickTier, which must stay dev-gated and controller-only.
H14_SAMPLE_FN=$(mo_func src/backend/main.mo "func sampleUptime(")
[ -n "$H14_SAMPLE_FN" ] || _fail "could not extract sampleUptime()"
H14_SAMPLE_CODE=$(printf '%s\n' "$H14_SAMPLE_FN" | mo_code)
src_has "sampleUptime budgets bids from the owner's available QUOTE"     "$H14_SAMPLE_CODE" "getAvailable(p, Types.QUOTE_TOKEN)"
src_has "sampleUptime budgets asks from the owner's available BASE"      "$H14_SAMPLE_CODE" "getAvailable(p, pool.baseToken)"
src_has "a bid credits Nat.min(value, quote budget)"                     "$H14_SAMPLE_CODE" "Nat.min(Fixed.mul(rem, o.price, false), budget)"
src_has "an ask credits Nat.min(remaining, base budget) at its price"    "$H14_SAMPLE_CODE" "Nat.min(rem, budget)"
src_lacks "no side is credited straight off the order record any more"  "$H14_SAMPLE_CODE" "let v = Fixed.mul(rem, o.price, false);"
H14_TICK_FN=$(mo_func src/backend/main.mo "func devTickTier(")
[ -n "$H14_TICK_FN" ] || _fail "could not extract devTickTier()"
src_has "the tier tick hook is dev-gated"                               "$H14_TICK_FN" 'requireDevHook("devTickTier")'
src_has "the tier tick hook is controller-only"                         "$H14_TICK_FN" 'requireController(msg.caller);'

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
grep_count REL_RETURNS "$(printf '%s\n' "$REL_FN" | mo_code)" '(^|[^A-Za-z_])return($|[^A-Za-z0-9_])'
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

# ── §6ak H-19 (F44): both CSV builders neutralise leading formula characters ─
# The pool name is the one player-authored free-text field on the OQL surface,
# and a controller's CSV export of `pool`/`position` rows lands in a spreadsheet
# that evaluates a cell starting `=`, `+`, `-` or `@` as a FORMULA. Both CSV
# builders (explorer.js dxToCsv via dxCsvCell; main.js archExport via
# archCsvCell) prefix such a cell with `'` and quote it — the guard regex is the
# brief's literal `/^[=+\-@\t\r]/`, pinned here in both files; the behavioural
# battery (fixed → literal text, unfixed stub → caught) is
# tests/frontend_security.test.mjs §K. Backend: createMarginPool refuses the
# same leading characters + control chars via MarginPools.nameRefusal
# (tests/MarginPools.test.mo pins the shapes; test_audit_2026_08_fixes.sh
# drives the live endpoint).
EXPL_JS=$(mo_code < src/frontend/src/explorer.js)
MAIN_JS=$(mo_code < src/frontend/src/main.js)
src_has "§6ak: explorer.js carries the formula-lead guard regex"          "$EXPL_JS" 'CSV_FORMULA_LEAD = /^[=+\-@\t\r]/'
src_has "§6ak: explorer.js's dxCsvCell prefixes a matching cell with a quote" "$EXPL_JS" 'if (CSV_FORMULA_LEAD.test(s)) return `"'"'"'${s.replace(/"/g, '"'"'""'"'"')}"`;'
src_has "§6ak: dxToCsv builds every cell through dxCsvCell"               "$EXPL_JS" 'cols.map((c) => dxCsvCell(r[c]))'
src_has "§6ak: main.js carries the formula-lead guard regex"              "$MAIN_JS" 'ARCH_CSV_FORMULA_LEAD = /^[=+\-@\t\r]/'
src_has "§6ak: archExport builds every cell through archCsvCell"          "$MAIN_JS" '.map(archCsvCell).join(",")'
src_lacks "§6ak: archExport's old quote-only esc is gone"                 "$MAIN_JS" 'const esc = (s) => `"${String(s).replace(/"/g'
src_has "§6ak: createMarginPool applies MarginPools.nameRefusal"          "$(mo_code < src/backend/main.mo)" 'switch (MarginPools.nameRefusal(name)) { case (?e) { return #err(e) }; case null {} };'

# ── §6al H-33 (F47): play-deposit admission is valued only at a fresh, un-pended mark ─
# markValueUsd reads `p.refPrice` with no age bound and no circuit-breaker
# check, so a deposit made while an asset's mark sat frozen below market was
# charged allowance at the stale value. The two admission callers
# (playDepositReserve; creditAndRegister's excess path) now value through
# markValueUsdFresh, whose verdict is AMM.markStaleReason (pure; boundary in
# tests/AMM.test.mo) at the 5-min MARGIN wall — not the 60 s LP/swap bar,
# which would refuse honest deposits between a quiet market's refreshes.
# Live: test_play_deposit_cap.sh §12.
H33_MAIN=$(mo_code < src/backend/main.mo)
src_has   "§6al: the admission bar IS the 5-min margin wall"                       "$H33_MAIN" 'transient let PLAY_DEPOSIT_MAX_MARK_AGE_NS : Int = MARGIN_MAX_REFPRICE_AGE_NS;'
src_has   "§6al: markValueUsdFresh routes its verdict through AMM.markStaleReason" "$H33_MAIN" 'AMM.markStaleReason(p, pended, now, PLAY_DEPOSIT_MAX_MARK_AGE_NS)'
src_has   "§6al: ...reading the breaker's pend for the base token"                 "$H33_MAIN" 'let pended = Map.get(pendingPriceJumps, Text.compare, token) != null;'
H33_PDR=$(mo_func src/backend/main.mo "func playDepositReserve(" | mo_code)
[ -n "$H33_PDR" ] || _fail "§6al: could not extract playDepositReserve()"
src_has   "§6al: playDepositReserve values the admission at the fresh mark"        "$H33_PDR" 'markValueUsdFresh(token, amount, Time.now())'
src_lacks "§6al: ...and no longer through the ungated markValueUsd"                "$H33_PDR" 'markValueUsd(token, amount)'
H33_CAR=$(mo_func src/backend/main.mo "func creditAndRegister(" | mo_code)
[ -n "$H33_CAR" ] || _fail "§6al: could not extract creditAndRegister()"
src_has   "§6al: creditAndRegister's excess path values at the fresh mark"         "$H33_CAR" 'markValueUsdFresh(token, excess, Time.now())'
src_lacks "§6al: ...and no longer through the ungated markValueUsd"                "$H33_CAR" 'markValueUsd(token, excess)'

# ── §6am 1788536324: seed.sh's trader padding QUOTES the `principal` label and COUNTS the bulk reply ─
# `principal` is a Candid textual-syntax keyword. As a record LABEL it must
# be quoted (`"principal" = principal "…"` — candid/backend.did spells it
# that way too); the bare form makes icp refuse the whole batch ("Candid
# parser error: Unrecognized token `Equals` … Expected one of \"text\""), and
# with the reply sent to /dev/null seed.sh printed "✓ balances seeded" over
# it — so for the script's whole life every `seed.sh full` (hence every
# `cold_start --mode full`) left the 100 padded traders holding NOTHING:
# the venue's live ledger was ~25 (principal, token) rows instead of ~425
# (the epoch-genesis journal after resetExchange read 75 on this seat, 475
# after the fix). Two pins: the label is quoted (and the bare spelling is
# gone from the code), and the reply is READ — bulk_fund() asserts the
# `(N : nat)` shape through the shared mdx_reply_nat AND the count (entries ×
# 4 rows), aborting through seed_fail on anything else; no `> /dev/null`
# bulk call remains. The helper is sliced out of the live script and driven
# in a subshell with a stubbed call(), §6af-style, so the unit tests the code
# that runs: 200 rows for 50 accounts passes, a short count / a parser
# error / a trap / a unit reply each abort. A deliberate label typo makes the
# real seed die on the ✗ line (rehearsed 2026-09-04: "record field principal
# not found", exit 1, no ✓ line).
SEED_UNC_6AM=$(uncommented scripts/seed.sh)
src_has   "§6am: seed.sh's bulk batch spells the label QUOTED (\"principal\" = principal …)" "$SEED_UNC_6AM" 'batch+="record { \"principal\" = principal \"$p\"; balances = vec {"'
src_lacks "§6am: the bare keyword label is gone from seed.sh's code"                       "$SEED_UNC_6AM" '{ principal = principal'
src_lacks "§6am: no bulkSetTestBalances call discards its reply"                           "$SEED_UNC_6AM" 'bulkSetTestBalances "(vec { $batch })" --identity alice > /dev/null'
src_has   "§6am: both batch flushes route through bulk_fund"                               "$SEED_UNC_6AM" 'bulk_fund "$batch" "$n"'
src_has   "§6am: seed_load asserts the padded total (count × 4 rows)"                      "$SEED_UNC_6AM" '[ "$rows" -eq $(( count * 4 )) ] || seed_fail "padding wrote $rows balance rows for $count principals'
BULK_FN=$(sed -n '/^bulk_fund() {/,/^}/p' scripts/seed.sh)
if [ -z "$BULK_FN" ]; then _fail "§6am: could not slice bulk_fund() out of scripts/seed.sh — the helper moved or was renamed; the unit below is inert"
else
  src_has "§6am: bulk_fund gates on the shared nat oracle"                "$BULK_FN" '! mdx_reply_nat "$out"'
  src_has "§6am: bulk_fund aborts through seed_fail on a non-nat reply"   "$BULK_FN" 'seed_fail "bulkSetTestBalances ($entries accounts) did not answer (N : nat) (rc=$rc)" "$out"'
  src_has "§6am: bulk_fund aborts through seed_fail on a short count"     "$BULK_FN" 'seed_fail "bulkSetTestBalances wrote $got balance rows for $entries accounts (expected $want)" "$out"'
  bulk_verdict() {  # bulk_verdict <entries> <stub rc> <stub reply> -> ok|abort, from the LIVE helper
    ( . scripts/lib/reply.sh; eval "$BULK_FN"
      STUB_RC="$2"; STUB_REPLY="$3"
      call() { printf '%s\n' "$STUB_REPLY"; return "$STUB_RC"; }
      ok() { :; }; err() { :; }
      seed_fail() { exit 7; }
      bulk_fund "vec-entries" "$1" ) >/dev/null 2>&1
    case $? in 0) echo ok ;; 7) echo abort ;; *) echo "rc=$?" ;; esac
  }
  for CASE in \
    "ok|50|0|(200 : nat)" \
    "ok|50|0|Sending the following argument: (vec { record { \"principal\" = principal \"aaaaa-aa\" } }) (200 : nat)" \
    "ok|2500|0|(10_000 : nat)" \
    "abort|50|0|(199 : nat)" \
    "abort|50|0|(201 : nat)" \
    "abort|50|1|Candid parser error: Unrecognized token \`Equals\` found at 26:27 Expected one of \"text\"" \
    "abort|50|1|Error: failed to serialize candid arguments with specific types Caused by: record field principal not found" \
    "abort|50|1|Error: The replica returned a rejection error: Caller is not a canister controller" \
    "abort|50|0|()" \
    "abort|50|0|(variant { ok })" ; do
    WANT=${CASE%%|*}; REST=${CASE#*|}; ENTRIES=${REST%%|*}; REST=${REST#*|}; RC=${REST%%|*}; REPLY=${REST#*|}
    GOT=$(bulk_verdict "$ENTRIES" "$RC" "$REPLY")
    if [ "$GOT" = "$WANT" ]; then _ok "§6am: bulk_fund($ENTRIES) → $WANT on $(printf '%s' "$REPLY" | cut -c1-60)"
    else _fail "§6am: bulk_fund($ENTRIES) answered $GOT, expected $WANT, on: $REPLY — the padding's ✓ line must rest on a counted (N : nat) reply of entries × 4, never on a discarded one"; fi
  done
fi
# ── §6an 1788541235: the requote commits its fresh ladder BEFORE its release pass ─
# ammRequote diffs the ladder (ammApplyQuotes: kept levels keep their ids,
# changed levels are cancelled + re-placed under new ids — the quote-liveness
# jitter re-posts ~2 levels per side per requote) and then runs the resting
# sweep and the deferred RELEASE against "the same fresh quotes". But the
# release reads the pool back out of `pools` by market id — releaseDeferred's
# #3a spot-market cap takes ammQuoteSpan(AMM.getPool(pools, ..)) as the
# ladder EDGE a taker may fill to this cycle — and every caller put the pool
# only AFTER ammRequote returned. So the release saw the PREVIOUS requote's
# ids, each just-re-placed level read as closed, the edge sat at the highest
# KEPT old level, and a market order was capped there: 199 / 299 of a 300
# buy against a 5 × 100 ladder (test_walk_scan_budget §4), 5.99 of 10 ETH
# (test_market_walks_locked) — green or red on the jitter's clock, misread
# for a day as an oracle-freshness strand. Pin: the put precedes both passes
# inside ammRequote, and the #3a cap still reads the map (the reason the
# order matters). Live: the two suites above, in run_all order.
AR_FN=$(mo_func src/backend/main.mo "func ammRequote(" | mo_code)
[ -n "$AR_FN" ] || _fail "§6an: could not extract ammRequote()"
AR_UPD_LN=$(printf '%s\n' "$AR_FN" | grep -nF 'let updated = AMM.withActiveOrders(working, bidRes.ids, askRes.ids, now);' | head -1 | cut -d: -f1)
AR_PUT_LN=$(printf '%s\n' "$AR_FN" | grep -nF 'AMM.putPool(pools, updated);' | head -1 | cut -d: -f1)
AR_SWP_LN=$(printf '%s\n' "$AR_FN" | grep -nF 'ammSweepResting(updated, now);' | head -1 | cut -d: -f1)
AR_REL_LN=$(printf '%s\n' "$AR_FN" | grep -nF 'processDeferred(updated, now);' | head -1 | cut -d: -f1)
if [ -n "$AR_UPD_LN" ] && [ -n "$AR_PUT_LN" ] && [ "$AR_UPD_LN" -lt "$AR_PUT_LN" ]; then _ok "§6an: ammRequote puts the UPDATED pool (line $AR_PUT_LN of the slice) after building it ($AR_UPD_LN)"
else _fail "§6an: ammRequote no longer commits \`updated\` to the pool map (updated=${AR_UPD_LN:-?} put=${AR_PUT_LN:-?}) — the release pass reads the previous requote's ids and caps market fills at the highest kept old level"; fi
if [ -n "$AR_PUT_LN" ] && [ -n "$AR_SWP_LN" ] && [ -n "$AR_REL_LN" ] && [ "$AR_PUT_LN" -lt "$AR_SWP_LN" ] && [ "$AR_SWP_LN" -lt "$AR_REL_LN" ]; then _ok "§6an: ...and the put precedes the sweep ($AR_SWP_LN) and the release pass ($AR_REL_LN)"
else _fail "§6an: the pool put (line ${AR_PUT_LN:-?}) must precede ammSweepResting (${AR_SWP_LN:-?}) and processDeferred (${AR_REL_LN:-?}) inside ammRequote"; fi
RD_FN=$(mo_func src/backend/main.mo "func releaseDeferred(" | mo_code)
[ -n "$RD_FN" ] || _fail "§6an: could not extract releaseDeferred()"
src_has "§6an: the #3a spot-market cap still reads the ladder edge from the pool MAP (why the put must come first)" "$RD_FN" 'let span = ammQuoteSpan(p, d.side);'
src_has "§6an: _lib.sh carries the live-mark pin (mdx_pin_mark: aggregate → primed → pool → fallback)" "$(uncommented tests/_lib.sh)" 'mdx_pin_mark() {'
src_has "§6an: test_market_walks_locked pins its ETH mark through it"                              "$(uncommented tests/test_market_walks_locked.sh)" '$(mdx_pin_mark ETH ETH-ICPUSD "$(e8 2000)")'
src_has "§6an: test_play_deposit_cap §8 pins its BTC mark through it on #dev"                      "$(uncommented tests/test_play_deposit_cap.sh)" '$(mdx_pin_mark BTC BTC-ICPUSD "$(e8 75000)")'

# ── §6ao 1788480302: pipeline captures cannot abort silently either; the ERR belt names what does ──
# §6p fixed the three `x="$(icp … 2>&1)"` sites. The SAME class remained in
# every PIPELINE capture: under `set -euo pipefail` a CLI failure — or a grep
# miss, which is the ordinary path for a pool that prints no refPrice line —
# anywhere in `x=$(icp … 2>/dev/null | grep … | awk …)` makes the assignment
# non-zero and `set -e` ends deploy.sh mid-flight, and because stderr went to
# /dev/null there was NO diagnostic, not even a captured one. The vault
# loop's "no live price; SKIPPING its vault" branch sat on the line after
# such a capture, unreachable by the path it was written for. Two belts:
#   (a) every pipeline capture carries `|| true` INSIDE the substitution and
#       is followed by an output gate that NAMES the variable — skip branches
#       (px_e8, tp, bp) continue; the id/principal/posture/balance gates warn
#       or die out loud; an unreadable arb balance is NOT read as zero
#       (fundArbitrageur is an unbacked mint with no re-fund guard);
#   (b) `set -E` + an ERR trap beside `set -euo pipefail` that names the
#       line and command of any abort that still slips through, guarded on
#       BASH_SUBSHELL so a failure INSIDE a `$(…)` whose parent context
#       absorbs it (an `if` test, an `||` list) prints nothing spurious.
# Pinned in source, then PROVED on this machine's bash (3.2): the real
# blocks are extracted verbatim and driven under `set -euo pipefail` by a
# recording `icp` stub in four moods (fail / grep-miss / hash-spelled / succeed); a
# negative control strips the `|| true` and must abort silently, so the
# probe demonstrably sees the bug it pins; and the belt's own shape matrix
# runs with the trap lines read from deploy.sh.
# 1788549770 (the follow-up): a warn-and-continue on an empty id read was
# still a DEGRADE — ai-connect.html left on its cookie resolver, ic-app.json
# missing rows, the arb unwired — while H-02 had already PINNED every public
# id per environment (scripts/lib/targets.sh mdx_expected_id) and verified
# the mapping AND icp-cli's resolution against that table before the run's
# first icp call. So every remote id read now goes through ONE helper,
# remote_canister_id: the by-hand status read (still `|| true` inside the
# substitution), and on an empty answer the pinned id — ANNOUNCED on stderr,
# never silent; empty only when both are empty (an env the table does not
# know), where the caller's gate names its variable exactly as before. The
# probes below drive the REAL helper (extracted verbatim, with the REAL
# mdx_expected_id from targets.sh): a bad/miss read lands on the pinned id
# and the value is asserted; a good read wins over the pin; an unpinned env
# still warns/dies by name; and two negative controls — the helper WITHOUT
# its fallback degrades as before; the helper without its `|| true`, called
# BARE, aborts silently — prove the probe sees both the fallback and the
# original bug. (Why bare: see the bash-3.2 finding at probe (6b).)
DEPLOY_SH_CAP="$(uncommented scripts/deploy.sh)"
PIPE_BARE="$(printf '%s\n' "$DEPLOY_SH_CAP" | grep -nE '=\"?\$\(icp .* \| ' | grep -vE '\|\| true\)"?$' || true)"
if [ -z "$PIPE_BARE" ]; then _ok "§6ao: no bare pipeline capture \$(icp … | …) remains in deploy.sh"
else _fail "§6ao: bare pipeline captures in deploy.sh (add || true inside the substitution, gate on the output): $(printf '%s' "$PIPE_BARE" | tr '\n' ' ' | head -c 300)"; fi
grep_count PIPE_KEPT "$DEPLOY_SH_CAP" '=\"?\$\(icp .* \| .*\|\| true\)"?$'
# floor 9 since 1788549770: the six id sites fold into remote_canister_id's one capture;
# 8 since 1793498812: the arb balance read is a PLAIN capture (arb_out, || true inside)
# plus the lib's mdx_reply_nat_value — no pipeline left on that site to count
if [ "${PIPE_KEPT:-0}" -ge 8 ]; then _ok "§6ao: $PIPE_KEPT pipeline captures carry || true inside the substitution (expected ≥ 8)"
else _fail "§6ao: only ${PIPE_KEPT:-0} pipeline captures carry || true — the sweep lost sites (expected ≥ 8)"; fi
# negative control for the scan itself: strip every `|| true)` and the ban must fire on every site
PIPE_NEG="$(printf '%s\n' "$DEPLOY_SH_CAP" | sed 's/ || true)/)/' | grep -nE '=\"?\$\(icp .* \| ' | grep -vcE '\|\| true\)"?$' || true)"
if [ "${PIPE_NEG:-0}" -ge 8 ]; then _ok "§6ao negative control: with the || true stripped the ban sees $PIPE_NEG sites"
else _fail "§6ao negative control: the ban saw only ${PIPE_NEG:-0} sites with || true stripped — the scan cannot see the shape it bans"; fi
# read_id is remote_canister_id's capture — the ONE place the id status read lives (1788549770);
# arb_out is the arb balance's RAW capture (task 1793498812) — arb_bal is the lib's
# mdx_reply_nat_value over it, no icp call of its own (that routing is pinned in §3d)
for v in mode PRINCIPAL px_e8 tp bp read_id arb_out; do
  grep_count n "$DEPLOY_SH_CAP" "^ *(\[ -n \"\\\$\{PRINCIPAL:-\}\" \] \|\| )?$v=\"?\\\$\(icp .*\|\| true\)\"?$"
  if [ "${n:-0}" -ge 1 ]; then _ok "§6ao: the $v capture carries || true ($n site(s))"
  else _fail "§6ao: the $v capture is a bare pipeline again (task 1788480302)"; fi
done
src_has "§6ao: the posture probe fails CLOSED on an empty answer, naming mode"           "$DEPLOY_SH_CAP" "printed nothing — mode=''): refusing to seed blind"
src_has "§6ao: the engine PRINCIPAL gate names the variable"                             "$DEPLOY_SH_CAP" "PRINCIPAL=''): the engine identity cannot be funded"
src_has "§6ao: the subnet PRINCIPAL gate names the variable"                             "$DEPLOY_SH_CAP" "(PRINCIPAL='') — refusing to deploy as an unknown principal"
src_has "§6ao: an unreadable arb balance is NOT funded"                                  "$DEPLOY_SH_CAP" "arb_bal=''): NOT funding"
src_has "§6ao: the arb fund gate distinguishes zero from unreadable"                     "$DEPLOY_SH_CAP" 'elif [ "$arb_bal" = "0" ]; then'
src_has "§6ao: the BRIDGE_ID gate warns by name"                                         "$DEPLOY_SH_CAP" "BRIDGE_ID='')"
src_has "§6ao: the FRONTEND_ID gate warns by name"                                       "$DEPLOY_SH_CAP" "FRONTEND_ID='')"
src_has "§6ao: the ARB_ID gate warns by name"                                            "$DEPLOY_SH_CAP" "ARB_ID='\${ARB_ID:-}'"
# 1788549770: every remote id read goes through remote_canister_id — the
# status read with || true inside, the pinned fallback announced on stderr —
# and the by-hand `awk '/^Canister Id/'` capture survives ONLY inside it.
src_has "§6ao/1788549770: remote_canister_id reads the status with || true inside the substitution" "$DEPLOY_SH_CAP" 'read_id="$(icp canister status "$c" -e "$env" --identity "$ident" 2>/dev/null | awk'
src_has "§6ao/1788549770: ...and falls back to the H-02 pinned id (mdx_expected_id)"   "$DEPLOY_SH_CAP" 'pinned="$(mdx_expected_id "$env" "$c")"'
src_has "§6ao/1788549770: ...announcing the fallback on stderr (stdout is the value)"  "$DEPLOY_SH_CAP" 'using the id pinned for $env:$c in scripts/lib/targets.sh ($pinned)" >&2'
for site in 'BACKEND_ID="$(remote_canister_id backend)"' 'BRIDGE_ID="$(remote_canister_id bridge)"' 'ARB_ID="$(remote_canister_id arb)"' \
            'FRONTEND_ID="$(remote_canister_id frontend)"' 'FRONTEND_ID="$(remote_canister_id frontend "$CE_ENV" "$SN_IDENTITY")"' 'id="$(remote_canister_id "$c" "$FO_ENV" "$FO_ID")"'; do
  src_has "§6ao/1788549770: the site reads through the helper: $site" "$DEPLOY_SH_CAP" "$site"
done
RCI_BYHAND="$(printf '%s\n' "$DEPLOY_SH_CAP" | grep -cF "awk -F': ' '/^Canister Id/" || true)"
if [ "${RCI_BYHAND:-0}" -eq 1 ]; then _ok "§6ao/1788549770: exactly one by-hand 'Canister Id' capture remains in deploy.sh (inside remote_canister_id)"
else _fail "§6ao/1788549770: ${RCI_BYHAND:-0} by-hand 'Canister Id' captures in deploy.sh — a site bypasses remote_canister_id and its pinned fallback (expected exactly 1, the helper's)"; fi
for g in "pins no id for \$CE_ENV:backend — BACKEND_ID=''" "pins no id for \$CE_ENV:bridge — BRIDGE_ID=''" "pins no id for \$CE_ENV:frontend — FRONTEND_ID=''" "pins no id for \$FO_ENV:\$c — id=''"; do
  src_has "§6ao/1788549770: the empty gate says the table has no entry: $g" "$DEPLOY_SH_CAP" "$g"
done
cap_pin() { bash -c '. scripts/lib/targets.sh && mdx_expected_id "$1" "$2"' _ "$1" "$2" 2>/dev/null; }
CAP_PIN_EB="$(cap_pin engine backend)"
[ -n "$CAP_PIN_EB" ] && _ok "§6ao/1788549770: targets.sh pins engine:backend ($CAP_PIN_EB) — the fallback probes have a value to assert" \
  || _fail "§6ao/1788549770: targets.sh pins no engine:backend id — the pinned-fallback probes below would test nothing"
src_has "§6ao: the belt — set -E beside set -euo pipefail"                               "$DEPLOY_SH_CAP" 'set -E'
CAP_TRAP="$(printf '%s\n' "$DEPLOY_SH_CAP" | grep -E "^trap .* ERR$" || true)"
src_has "§6ao: the belt — an ERR trap that names the line and command"                   "$CAP_TRAP" 'deploy.sh aborted at line %s: %s'
src_has "§6ao: ...guarded on BASH_SUBSHELL (no spurious print from inside a \$(…))"     "$CAP_TRAP" '[ "${BASH_SUBSHELL:-0}" -eq 0 ] &&'
CAP_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cap6an.XXXXXX")"
mkdir -p "$CAP_TMP/bin"
cat > "$CAP_TMP/bin/icp" <<'CAPEOF'
#!/bin/bash
# recording stub in four moods. bad: the CLI fails; miss: the CLI succeeds
# but prints an answer the grep/awk cannot use; hashed: the CLI succeeds but
# spells variants by Candid field hash (icp 1.2 when its candid fetch misses
# and --candid is absent: digits on stdout that are NOT a value — task
# 1793498812); good: the shapes the real CLI prints. Every invocation lands
# in $CAP_LOG.
echo "$*" >> "$CAP_LOG"
case "${CAP_MODE:-}" in
  bad)  echo "Error: transport failure: connection reset by peer (CAP STUB DIAGNOSTIC)" >&2; exit 7 ;;
  miss) case "$*" in
          *getAmmPool*)        echo '(opt record { market = "BTC-ICPUSD"; enabled = false })' ;;
          *getDeployMode*)     echo '(record {})' ;;
          *"canister status"*) echo "Canister Name: backend" ;;
          *getTestBalance*)    echo '(variant { err = "no such account" })' ;;
          *)                   echo "" ;;
        esac ;;
  hashed) case "$*" in
          *getTestBalance*)    echo '(variant { 5_048_165 = "code 404" })' ;;
          *)                   echo "(variant { 24_860 })" ;;
        esac ;;
  good) case "$*" in
          *getAmmPool*)        echo '(opt record { market = "BTC-ICPUSD"; refPrice = 7_971_522_000_000 : nat; enabled = true })' ;;
          *getDeployMode*)     echo "(\"${CAP_POSTURE:-play}\")" ;;
          *"canister status"*) echo "Canister Id: aaaaa-aa"; echo "Canister Name: x" ;;
          *getTestBalance*)    echo "(${CAP_ARB_BAL:-0} : nat)" ;;
          *fundArbitrageur*)   echo "(variant { ok })" ;;
          *"identity principal"*) echo "7mmfs-xttzr-3xqf3-2agye-app5u-zsh4a-dcdbk-siv72-a22ye-h2xy6-xqe" ;;
          *)                   echo "(variant { ok })" ;;
        esac ;;
esac
CAPEOF
chmod +x "$CAP_TMP/bin/icp"
# block splitter: every range <start>..<end> (regexes on whole lines) lands in
# its own numbered file, so a variable captured twice (px_e8, PRINCIPAL,
# FRONTEND_ID) yields one block per site instead of a concatenation.
cap_split() {  # cap_split <start-regex> <end-regex> <out-prefix> [<file>=scripts/deploy.sh]
  awk -v s="$1" -v e="$2" -v p="$3" '
    $0 ~ s && !f { n++; f=1; out=p "_" n ".sh"; printf "" > out }
    f { print >> out; if ($0 ~ e) { f=0; close(out) } }' "${4:-scripts/deploy.sh}"
}
cap_split '^ *px_e8=\\$\\(icp canister call backend getAmmPool'                 '^ *fi$'      "$CAP_TMP/px"
cap_split '^ *mode=\\$\\(icp canister call backend getDeployMode'               '^ *fi$'      "$CAP_TMP/mode"
cap_split '^ *\\[ -n "\\$\\{PRINCIPAL:-\\}" \\] \\|\\| PRINCIPAL="\\$\\(icp identity principal' '^ *\\[ -n "\\$\\{PRINCIPAL:-\\}" \\] \\|\\| die' "$CAP_TMP/eprin"
cap_split '^ *PRINCIPAL="\\$\\(icp identity principal --identity "\\$SN_IDENTITY"' '^ *ok "Deploying as' "$CAP_TMP/sprin"
cap_split '^ *tp=\\$\\(icp identity principal'                                  '^ *\\[ -n "\\$tp" \\]' "$CAP_TMP/tp"
cap_split '^ *bp=\\$\\(icp identity principal'                                  '^ *\\[ -n "\\$bp" \\]' "$CAP_TMP/bp"
cap_split '^ *id="\\$\\(remote_canister_id "\\$c"'                              '^ *\\[ -n "\\$id" \\]' "$CAP_TMP/fid"
cap_split '^ *BACKEND_ID="\\$\\(remote_canister_id backend'                     '^ *fi$'      "$CAP_TMP/bid"
cap_split '^ *BRIDGE_ID="\\$\\(remote_canister_id bridge'                       '^ *fi$'      "$CAP_TMP/brid"
cap_split '^ *ARB_ID="\\$\\(remote_canister_id arb'                             '^    fi$'    "$CAP_TMP/arbid"
# arb_out since 1793498812 (the raw capture; arb_bal is the lib's extractor over it) — either
# spelling, so a regrown by-hand arb_bal="$(icp …" read is DRIVEN and (7b) reds on it
cap_split '^ *arb_(out|bal)="\\$\\(icp canister call backend getTestBalance'    '^      fi$'  "$CAP_TMP/arbbal"
cap_split '^ *FRONTEND_ID="\\$\\(remote_canister_id frontend'                   '^ *fi$'      "$CAP_TMP/frid"
# the REAL helper and the REAL pinned table, verbatim, for the probe to eval (1788549770)
cap_split '^remote_canister_id\\(\\) \\{'                                         '^\\}'        "$CAP_TMP/rci"
cap_split '^mdx_expected_id\\(\\) \\{'                                            '^\\}'        "$CAP_TMP/mei" scripts/lib/targets.sh
cat > "$CAP_TMP/probe.sh" <<'CAPEOF'
#!/bin/bash
# $1 = deploy.sh  $2 = extracted block  $3 = plain|loop|fn  $4 = keep|strip (strip = the pre-fix bug)
set -euo pipefail
info() { printf 'info %s\n' "$1"; }
ok()   { printf 'ok %s\n' "$1"; }
warn() { printf 'warn %s\n' "$1"; }
die()  { printf 'die %s\n' "$1" >&2; exit 1; }
e8()   { awk -v x="$1" 'BEGIN{ printf "%.0f", x*100000000 }'; }
. "$(dirname "$1")/lib/reply.sh" 2>/dev/null || true    # the REAL predicates, as deploy.sh sources them
# the REAL mdx_expected_id (targets.sh) and remote_canister_id (deploy.sh), extracted
# verbatim (1788549770). CAP_RCI=strip deletes the helper's pinned fallback (the
# negative control: it must degrade/die by name as before); CAP_RCI=bare strips its
# `|| true` (the 1788480302 bug: a silent abort). CAP_ENV=nowhere is an env the table
# does not know.
eval "$(cat "$(dirname "$2")/mei_1.sh")"
RCI="$(cat "$(dirname "$2")/rci_1.sh")"
case "${CAP_RCI:-keep}" in
  strip) RCI="$(printf '%s\n' "$RCI" | sed '/mdx_expected_id/d')" ;;
  bare)  RCI="$(printf '%s\n' "$RCI" | sed 's/ || true)/)/')" ;;
esac
eval "$RCI"
CE_ENV="${CAP_ENV:-engine}"; CE_IDENTITY=stub; SN_IDENTITY=stub; FO_ENV="${CAP_ENV:-engine}"; FO_ID=stub; TARGET=engine; DEPLOY_CANDID=""
c=backend; t=mdex-seed-1; id=simbot_1; market=BTC-ICPUSD; tvl=1000
MDX_ORACLE_PRICES="$(dirname "$2")/prices"; ARB_ID="${ARB_ID:-aaaaa-aa}"; BACKEND_ID="${BACKEND_ID:-bbbbb-bb}"
seed_mint() { printf 'seed_mint %s\n' "$*"; }
if [ "$4" = strip ]; then BODY="$(sed 's/ || true)/)/' "$2")"; else BODY="$(cat "$2")"; fi
case "$3" in
  loop) eval "for _i in 1; do
$BODY
echo CAP-LOOP-BODY-REACHED; done" ;;
  fn)   eval "probe_fn() {
$BODY
echo CAP-FN-TAIL-REACHED; }; probe_fn" ;;
  *)    eval "$BODY" ;;
esac
echo "CAP-VARS BACKEND_ID='${BACKEND_ID:-}' BRIDGE_ID='${BRIDGE_ID:-}' FRONTEND_ID='${FRONTEND_ID:-}' ARB_ID='${ARB_ID:-}' id='${id:-}'"
echo "CAP-REACHED-AFTER-BLOCK"
CAPEOF
cap_run() {  # cap_run <mode> <block> <wrap> <keep|strip> → CAP_OUT, CAP_RC, CAP_LOG (the stub's argv log)
  : > "$CAP_TMP/calls.log"
  CAP_OUT="$(CAP_MODE="$1" CAP_LOG="$CAP_TMP/calls.log" PATH="$CAP_TMP/bin:$PATH" bash "$CAP_TMP/probe.sh" scripts/deploy.sh "$2" "$3" "$4" 2>&1)" && CAP_RC=0 || CAP_RC=$?
}
cap_has() { printf '%s\n' "$CAP_OUT" | grep -qF -- "$1"; }
cap_block_ok() {  # cap_block_ok <file> <must-contain> [<shape>='|| true)']: extraction sanity, so the probe never tests nothing
  if [ -s "$1" ] && grep -qF -- "$2" "$1" && grep -qF -- "${3:-|| true)}" "$1"; then return 0; fi
  _fail "§6ao: could not extract the block $(basename "$1") from deploy.sh (probe would test nothing)"; return 1
}
# (1) the vault loop: grep-miss and CLI failure both reach the SKIPPING warn and `continue`
if cap_block_ok "$CAP_TMP/px_2.sh" 'SKIPPING its vault'; then
  for mood in miss bad; do
    cap_run "$mood" "$CAP_TMP/px_2.sh" loop keep
    if [ "$CAP_RC" -eq 0 ] && cap_has 'warn BTC-ICPUSD — no live price; SKIPPING its vault' && ! cap_has 'CAP-LOOP-BODY-REACHED' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then
      _ok "§6ao px_e8 (vault) under a $mood icp: reaches 'no live price; SKIPPING its vault', continues the loop, exit 0"
    else _fail "§6ao px_e8 (vault) under a $mood icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  done
  cap_run miss "$CAP_TMP/px_2.sh" loop strip
  if [ "$CAP_RC" -ne 0 ] && ! cap_has 'SKIPPING' && ! cap_has 'CAP-REACHED-AFTER-BLOCK'; then
    _ok "§6ao px_e8 (vault) negative control: without || true a grep miss aborts SILENTLY before the SKIPPING test (exit $CAP_RC) — the probe sees the bug"
  else _fail "§6ao px_e8 (vault) negative control did not abort silently (exit $CAP_RC) — the probe cannot see the bug"; fi
  cap_run good "$CAP_TMP/px_2.sh" loop keep
  if [ "$CAP_RC" -eq 0 ] && ! cap_has 'SKIPPING' && cap_has 'CAP-LOOP-BODY-REACHED'; then _ok "§6ao px_e8 (vault) under a good icp: the live price is read and the vault body runs"
  else _fail "§6ao px_e8 (vault) under a good icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
fi
# (2) the step-2b live-price loop: the "no live price yet" else-arm, then the next market
if cap_block_ok "$CAP_TMP/px_1.sh" 'no live price yet'; then
  for mood in miss bad; do
    cap_run "$mood" "$CAP_TMP/px_1.sh" loop keep
    if [ "$CAP_RC" -eq 0 ] && cap_has 'warn BTC-ICPUSD — no live price yet' && cap_has 'CAP-LOOP-BODY-REACHED'; then
      _ok "§6ao px_e8 (step 2b) under a $mood icp: warns 'no live price yet' and continues"
    else _fail "§6ao px_e8 (step 2b) under a $mood icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  done
fi
# (3) the posture probe: fails CLOSED and LOUD, naming mode; the production arm still returns; play still seeds
if cap_block_ok "$CAP_TMP/mode_1.sh" 'refusing to seed blind'; then
  for mood in bad miss; do
    cap_run "$mood" "$CAP_TMP/mode_1.sh" fn keep
    if [ "$CAP_RC" -ne 0 ] && cap_has "die Could not read the canister posture" && cap_has "mode=''" && ! cap_has 'CAP-FN-TAIL-REACHED'; then
      _ok "§6ao mode under a $mood icp: dies LOUDLY naming mode='' — nothing seeded"
    else _fail "§6ao mode under a $mood icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  done
  cap_run bad "$CAP_TMP/mode_1.sh" fn strip
  if [ "$CAP_RC" -ne 0 ] && ! cap_has 'die ' && ! cap_has 'CAP-FN-TAIL-REACHED'; then
    _ok "§6ao mode negative control: without || true the CLI failure aborts SILENTLY (exit $CAP_RC, no die) — the probe sees the bug"
  else _fail "§6ao mode negative control did not abort silently (exit $CAP_RC)"; fi
  CAP_POSTURE=play cap_run good "$CAP_TMP/mode_1.sh" fn keep
  if [ "$CAP_RC" -eq 0 ] && ! cap_has 'die ' && ! cap_has 'warn ' && cap_has 'CAP-FN-TAIL-REACHED'; then _ok "§6ao mode under a good icp (play): no die, no warn, seeding proceeds"
  else _fail "§6ao mode under a good icp (play): exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  CAP_POSTURE=production cap_run good "$CAP_TMP/mode_1.sh" fn keep
  if [ "$CAP_RC" -eq 0 ] && cap_has 'warn Canister posture is PRODUCTION' && ! cap_has 'CAP-FN-TAIL-REACHED'; then _ok "§6ao mode under a good icp (production): warns and returns without seeding"
  else _fail "§6ao mode under a good icp (production): exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
fi
# (4) the two PRINCIPAL reads die by name; the trader/bot principals skip by name
for pr in eprin:PRINCIPAL sprin:PRINCIPAL; do
  f="$CAP_TMP/${pr%%:*}_1.sh"
  if cap_block_ok "$f" "${pr##*:}=''"; then
    cap_run bad "$f" plain keep
    if [ "$CAP_RC" -ne 0 ] && cap_has "PRINCIPAL=''" && cap_has 'die ' && ! cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao ${pr%%:*}: a failing icp dies LOUDLY naming PRINCIPAL=''"
    else _fail "§6ao ${pr%%:*} under a failing icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
    cap_run bad "$f" plain strip
    if [ "$CAP_RC" -ne 0 ] && ! cap_has 'die ' && ! cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao ${pr%%:*} negative control: without || true the abort is silent (exit $CAP_RC)"
    else _fail "§6ao ${pr%%:*} negative control did not abort silently (exit $CAP_RC)"; fi
    cap_run good "$f" plain keep
    if [ "$CAP_RC" -eq 0 ] && cap_has 'CAP-REACHED-AFTER-BLOCK' && ! cap_has 'die '; then _ok "§6ao ${pr%%:*}: a good icp resolves the principal and continues"
    else _fail "§6ao ${pr%%:*} under a good icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  fi
done
for pr in tp bp; do
  f="$CAP_TMP/${pr}_1.sh"
  if cap_block_ok "$f" "$pr=''"; then
    cap_run bad "$f" loop keep
    if [ "$CAP_RC" -eq 0 ] && cap_has "$pr=''" && cap_has 'warn no principal for' && ! cap_has 'CAP-LOOP-BODY-REACHED' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao $pr: a failing icp warns by name and skips the identity"
    else _fail "§6ao $pr under a failing icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  fi
done
# (5) the frontend-only id loop (1788549770): an empty read lands on the pinned
#     id — announced — and the loop continues; a good read wins over the pin; an
#     env the table does not know dies by name as before; the helper WITHOUT its
#     fallback dies by name (negative control)
if cap_block_ok "$CAP_TMP/fid_1.sh" "id=''" 'remote_canister_id'; then
  for mood in bad miss; do
    cap_run "$mood" "$CAP_TMP/fid_1.sh" loop keep
    if [ "$CAP_RC" -eq 0 ] && cap_has "info icp canister status backend -e engine printed no 'Canister Id' line — using the id pinned for engine:backend in scripts/lib/targets.sh ($CAP_PIN_EB)" && cap_has " id='$CAP_PIN_EB'" && cap_has 'CAP-LOOP-BODY-REACHED' && ! cap_has 'die '; then
      _ok "§6ao id (frontend-only) under a $mood icp: lands on the pinned engine:backend id ($CAP_PIN_EB), announced, the loop continues"
    else _fail "§6ao id (frontend-only) under a $mood icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  done
  cap_run good "$CAP_TMP/fid_1.sh" loop keep
  if [ "$CAP_RC" -eq 0 ] && cap_has " id='aaaaa-aa'" && ! cap_has 'using the id pinned' && cap_has 'CAP-LOOP-BODY-REACHED'; then _ok "§6ao id (frontend-only) under a good icp: the live read (aaaaa-aa) wins over the pin"
  else _fail "§6ao id (frontend-only) under a good icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  CAP_ENV=nowhere cap_run bad "$CAP_TMP/fid_1.sh" loop keep
  if [ "$CAP_RC" -ne 0 ] && cap_has "die Could not read the backend canister id on 'nowhere'" && cap_has "pins no id for nowhere:backend — id=''" && ! cap_has 'CAP-LOOP-BODY-REACHED'; then _ok "§6ao id (frontend-only) on an env the table does not know: dies LOUDLY naming id=''"
  else _fail "§6ao id (frontend-only) on an unpinned env: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  CAP_RCI=strip cap_run bad "$CAP_TMP/fid_1.sh" loop keep
  if [ "$CAP_RC" -ne 0 ] && cap_has "die Could not read the backend canister id" && cap_has "id=''" && ! cap_has 'using the id pinned'; then _ok "§6ao id negative control: the helper WITHOUT its pinned fallback dies by name as before — the probe sees the fallback"
  else _fail "§6ao id negative control (helper without fallback): exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
fi
# (6) the remote_deploy id reads (1788549770): an empty read lands on the pinned
#     id (announced, no warn, value asserted); a good read wins; an unpinned env
#     warns by name and continues, exactly as before; the helper WITHOUT its
#     fallback warns by name (negative control)
for pr in bid:BACKEND_ID:backend brid:BRIDGE_ID:bridge frid:FRONTEND_ID:frontend; do
  IFS=: read -r blk var can <<< "$pr"
  f="$CAP_TMP/${blk}_1.sh"; pin="$(cap_pin engine "$can")"
  if [ -n "$pin" ] && cap_block_ok "$f" "$var=''" 'remote_canister_id'; then
    for mood in bad miss; do
      cap_run "$mood" "$f" plain keep
      if [ "$CAP_RC" -eq 0 ] && cap_has "info icp canister status $can -e engine printed no 'Canister Id' line — using the id pinned for engine:$can in scripts/lib/targets.sh ($pin)" && cap_has " $var='$pin'" && ! cap_has 'warn ' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then
        _ok "§6ao $var under a $mood icp: lands on the pinned engine:$can id ($pin), announced, no warn, deploy continues"
      else _fail "§6ao $var under a $mood icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
    done
    cap_run good "$f" plain keep
    if [ "$CAP_RC" -eq 0 ] && cap_has " $var='aaaaa-aa'" && ! cap_has 'using the id pinned' && ! cap_has 'warn ' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao $var under a good icp: the live read (aaaaa-aa) wins over the pin, no warn"
    else _fail "§6ao $var under a good icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
    CAP_ENV=nowhere cap_run bad "$f" plain keep
    if [ "$CAP_RC" -eq 0 ] && cap_has "warn Could not read the" && cap_has "pins no id for nowhere:$can — $var=''" && cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao $var on an env the table does not know: warns by name ($var=''), deploy continues"
    else _fail "§6ao $var on an unpinned env: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
    CAP_RCI=strip cap_run bad "$f" plain keep
    if [ "$CAP_RC" -eq 0 ] && cap_has "warn Could not read the" && cap_has "$var=''" && ! cap_has 'using the id pinned' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao $var negative control: the helper WITHOUT its pinned fallback degrades by name as before — the probe sees the fallback"
    else _fail "§6ao $var negative control (helper without fallback): exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  else _fail "§6ao: could not extract the $var block from deploy.sh, or targets.sh pins no engine:$can id (probe would test nothing)"; fi
done
CAP_PIN_EF="$(cap_pin engine frontend)"
if [ -s "$CAP_TMP/frid_2.sh" ] && grep -qF 'remote_canister_id frontend "$CE_ENV" "$SN_IDENTITY"' "$CAP_TMP/frid_2.sh"; then
  cap_run bad "$CAP_TMP/frid_2.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && cap_has "using the id pinned for engine:frontend in scripts/lib/targets.sh ($CAP_PIN_EF)" && cap_has " FRONTEND_ID='$CAP_PIN_EF'" && ! cap_has 'warn ' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao FRONTEND_ID (subnet next-steps) under a failing icp: the next-steps URL gets the pinned id ($CAP_PIN_EF), no warn"
  else _fail "§6ao FRONTEND_ID (subnet next-steps) under a failing icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  CAP_ENV=nowhere cap_run bad "$CAP_TMP/frid_2.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && cap_has "FRONTEND_ID=''" && cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao FRONTEND_ID (subnet next-steps) on an env the table does not know: warns by name, the tail continues"
  else _fail "§6ao FRONTEND_ID (subnet next-steps) on an unpinned env: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
else _fail "§6ao: could not extract the subnet FRONTEND_ID block from deploy.sh (or it no longer reads through remote_canister_id)"; fi
# (6b) the helper's OWN || true, proven where -e applies. Finding on this bash
# (3.2.57, 2026-09-04): `set -e` is NOT enforced inside a function body invoked
# within a `$(…)` — `X="$(f)"` with a failing pipeline assignment inside f runs
# f to its end and yields exit 0 (whereas a bare pipeline assignment, a bare
# function call, and an explicit `set -e` inside the substitution all abort).
# So the six `VAR="$(remote_canister_id …)"` sites cannot abort THROUGH the
# helper on this bash even with its || true stripped — which is why the
# per-site negative control is not "helper without || true". The || true is
# load-bearing all the same: a BARE call (`remote_canister_id x`, no
# substitution) and any bash that propagates -e into substitutions abort
# silently without it. The control therefore drives the helper BARE: without
# || true a failing icp aborts silently BEFORE the fallback; with it the pinned
# id is printed, announced, and the call returns 0.
printf 'remote_canister_id backend\necho CAP-BARE-CALL-RETURNED\n' > "$CAP_TMP/rcibare.sh"
CAP_RCI=bare cap_run bad "$CAP_TMP/rcibare.sh" plain keep
if [ "$CAP_RC" -ne 0 ] && ! cap_has 'CAP-BARE-CALL-RETURNED' && ! cap_has 'using the id pinned' && ! cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao remote_canister_id negative control: called BARE without its || true, a failing icp aborts SILENTLY before the fallback (exit $CAP_RC) — the || true is load-bearing"
else _fail "§6ao remote_canister_id negative control (bare call, no || true) did not abort silently (exit $CAP_RC) — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
cap_run bad "$CAP_TMP/rcibare.sh" plain keep
if [ "$CAP_RC" -eq 0 ] && cap_has "$CAP_PIN_EB" && cap_has 'using the id pinned for engine:backend' && cap_has 'CAP-BARE-CALL-RETURNED'; then _ok "§6ao remote_canister_id called BARE under a failing icp: prints the pinned id ($CAP_PIN_EB), announces it, returns 0"
else _fail "§6ao remote_canister_id bare call under a failing icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
# (7) the arb: an UNREADABLE balance is never funded; zero is; a funded arb is left alone
if cap_block_ok "$CAP_TMP/arbbal_1.sh" 'NOT funding'; then
  for mood in bad miss; do
    cap_run "$mood" "$CAP_TMP/arbbal_1.sh" plain keep
    if [ "$CAP_RC" -eq 0 ] && cap_has "arb_bal=''" && cap_has 'NOT funding' && ! grep -q fundArbitrageur "$CAP_TMP/calls.log" && cap_has 'CAP-REACHED-AFTER-BLOCK'; then
      _ok "§6ao arb_bal under a $mood icp: warns by name, fundArbitrageur NOT called, deploy continues"
    else _fail "§6ao arb_bal under a $mood icp: exit $CAP_RC, calls=$(tr '\n' ';' < "$CAP_TMP/calls.log" | head -c 120) — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
    # task 1793502103: the warn QUOTES the reply it could not read (`It answered:
    # '$(mdx_one_line "$arb_out")'`) — stderr went to /dev/null, so the shape that
    # came back is the operator's only clue to the cure. Under `miss` the stub
    # answers `(variant { err = "no such account" })`: the NOT-funding line must
    # carry it (grep -cF >/dev/null, the W5-10 drain, as src_has).
    if [ "$mood" = miss ]; then
      if printf '%s\n' "$CAP_OUT" | grep -F 'NOT funding' | grep -cF -- 'no such account' >/dev/null; then
        _ok "§6ao arb_bal under a miss icp: the NOT-funding warn quotes the reply it could not read — 'no such account' reaches the operator (task 1793502103)"
      else _fail "§6ao arb_bal under a miss icp: the NOT-funding warn does not quote the reply — 'no such account' missing (task 1793502103) — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
    fi
  done
  # (7b) task 1793498812: a digit-bearing NON-nat reply is UNREADABLE, not a
  # balance. `(variant { 5_048_165 = "code 404" })` is the hash-spelled err
  # icp prints when its candid fetch misses and --candid is absent; the old
  # `grep -oE "[0-9][0-9_]*" | head -1` read its 5_048_165 as a funded arb
  # ("already funded (0 ICPUSD)", fund skipped); the lib's mdx_reply_nat_value
  # answers empty on every non-(N : nat) shape, so the -z arm warns by name.
  # (Its pipeline's grep also MISSES there — until task 1793502104 the
  # function answered status 1 under pipefail and the site carried its own
  # `|| true`; now the extractor ends in `|| true` — the lib's status
  # contract, driven in §6af — and the capture is BARE, so these three moods
  # also prove the contract on the real block: without it, hashed, bad and
  # miss all abort silently with exit 1.)
  cap_run hashed "$CAP_TMP/arbbal_1.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && cap_has "arb_bal=''" && cap_has 'NOT funding' && ! cap_has 'already funded' && ! grep -q fundArbitrageur "$CAP_TMP/calls.log" && cap_has 'CAP-REACHED-AFTER-BLOCK'; then
    _ok "§6ao arb_bal under a hash-spelled err reply ((variant { 5_048_165 = \"code 404\" }) — digits, not a nat): arb_bal='' → NOT funding, fundArbitrageur NOT called, deploy continues (task 1793498812)"
  else _fail "§6ao arb_bal under a hash-spelled err reply (digits, not a nat): exit $CAP_RC, calls=$(tr '\n' ';' < "$CAP_TMP/calls.log" | head -c 120) — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  # task 1793502103: ...and the hash-spelled reply itself reaches the operator —
  # the NOT-funding line carries its `5_048_165` (the one-line quote of $arb_out),
  # the shape that names its own cure (--candid / the backend's candid:service).
  if printf '%s\n' "$CAP_OUT" | grep -F 'NOT funding' | grep -cF -- '5_048_165' >/dev/null; then
    _ok "§6ao arb_bal under a hash-spelled err reply: the NOT-funding warn quotes the reply it could not read — '5_048_165' reaches the operator (task 1793502103)"
  else _fail "§6ao arb_bal under a hash-spelled err reply: the NOT-funding warn does not quote the reply — '5_048_165' missing (task 1793502103) — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  cap_run bad "$CAP_TMP/arbbal_1.sh" plain strip
  if [ "$CAP_RC" -ne 0 ] && ! cap_has 'warn ' && ! cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao arb_bal negative control: without || true the abort is silent (exit $CAP_RC)"
  else _fail "§6ao arb_bal negative control did not abort silently (exit $CAP_RC)"; fi
  CAP_ARB_BAL=0 cap_run good "$CAP_TMP/arbbal_1.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && grep -q fundArbitrageur "$CAP_TMP/calls.log" && cap_has 'ok arb funded'; then _ok "§6ao arb_bal = 0 under a good icp: fundArbitrageur called, ok arm"
  else _fail "§6ao arb_bal = 0 under a good icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  CAP_ARB_BAL=128_125_000_000_000 cap_run good "$CAP_TMP/arbbal_1.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && ! grep -q fundArbitrageur "$CAP_TMP/calls.log" && cap_has 'ok arb already funded'; then _ok "§6ao arb_bal > 0 under a good icp: already funded, no mint"
  else _fail "§6ao arb_bal > 0 under a good icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
fi
# the arb id (1788549770): both envs pin one, so a failed read lands on it and the
# wiring proceeds (its balance read fails too under `bad`, so NOT funded — the (7)
# guard above); an unpinned env, or the helper without its fallback, warns by name
CAP_PIN_EA="$(cap_pin engine arb)"
if [ -n "$CAP_PIN_EA" ] && cap_block_ok "$CAP_TMP/arbid_1.sh" "ARB_ID='" 'remote_canister_id'; then
  cap_run bad "$CAP_TMP/arbid_1.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && cap_has "using the id pinned for engine:arb in scripts/lib/targets.sh ($CAP_PIN_EA)" && cap_has "ok Arbitrageur wired (arb=$CAP_PIN_EA)" && cap_has 'NOT funding' && ! grep -q fundArbitrageur "$CAP_TMP/calls.log" && ! cap_has 'arbitrageur NOT funded or enabled' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then
    _ok "§6ao ARB_ID under a failing icp: lands on the pinned engine:arb id ($CAP_PIN_EA), the wiring proceeds (unreadable balance still NOT funded), deploy continues"
  else _fail "§6ao ARB_ID under a failing icp: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  CAP_ENV=nowhere cap_run bad "$CAP_TMP/arbid_1.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && cap_has "ARB_ID=''" && cap_has 'arbitrageur NOT funded or enabled' && cap_has 'CAP-REACHED-AFTER-BLOCK'; then _ok "§6ao ARB_ID on an env the table does not know: warns by name, deploy continues to the keys and frontend"
  else _fail "§6ao ARB_ID on an unpinned env: exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
  CAP_RCI=strip cap_run bad "$CAP_TMP/arbid_1.sh" plain keep
  if [ "$CAP_RC" -eq 0 ] && cap_has "ARB_ID=''" && cap_has 'arbitrageur NOT funded or enabled' && ! cap_has 'using the id pinned'; then _ok "§6ao ARB_ID negative control: the helper WITHOUT its pinned fallback warns by name as before"
  else _fail "§6ao ARB_ID negative control (helper without fallback): exit $CAP_RC — $(printf '%s' "$CAP_OUT" | tr '\n' ' ' | head -c 300)"; fi
else _fail "§6ao: could not extract the ARB_ID block from deploy.sh, or targets.sh pins no engine:arb id (probe would test nothing)"; fi
# (8) the belt's shape matrix on THIS bash: the trap lines are read from
# deploy.sh; twelve guarded shapes print nothing; a bare capture is named.
CAP_BELT="$(grep -E '^set -E$|^trap .* ERR$' scripts/deploy.sh)"
if [ "$(printf '%s\n' "$CAP_BELT" | grep -c '')" -eq 2 ]; then
  cat > "$CAP_TMP/belt.sh" <<CAPEOF
#!/bin/bash
set -euo pipefail
$CAP_BELT
fn_fail() { icp x 2>/dev/null; return 1; }
fn_grep() { local v; v="\$(icp x 2>/dev/null | grep -oE 'zzz' || true)"; [ -n "\$v" ]; }
fn_cap_norv() { local v; v="\$(icp x 2>/dev/null | tail -1)"; echo "M-tail v='\$v'"; }
fn_cap_rv()   { local v; v="\$(icp x 2>/dev/null | tail -1)" || return 1; echo "N-tail-unreached" >&2; }
if [ "\$(icp identity principal 2>/dev/null)" = x ]; then echo A-then; else echo A-else; fi
if out="\$(icp canister call foo 2>&1)"; then echo B-then; else echo "B-else: \$out"; fi
if fn_fail; then echo C-then; else echo C-else; fi
if fn_grep; then echo D-then; else echo D-else; fi
v="\$(icp x 2>/dev/null | tail -1 || true)"; echo "E v='\$v'"
[ -n "\${v:-}" ] || v="\$(icp x 2>/dev/null | tail -1 || true)"; echo "F v='\$v'"
icp x >/dev/null 2>&1 || echo G-or
w="\$(icp x 2>/dev/null | grep -oE 'zzz' | head -1 || true)"; echo "H w='\$w'"
while icp x 2>/dev/null; do :; done; echo I-while
! icp x 2>/dev/null; echo J-neg
x="\$(echo hi | grep -oE 'zzz' || true)"; echo "K x='\$x'"
( icp x 2>/dev/null ) || echo L-subshell
m="\$(fn_cap_norv)"; echo "M m='\$m'"
if n="\$(fn_cap_rv)"; then echo N-then; else echo N-else; fi
echo "BELT-GUARDED-DONE"
[ "\${1:-}" = fnbare ] && { o="\$(fn_cap_rv)"; echo "BELT-AFTER-FNBARE"; }
[ "\${1:-}" = bare ] || exit 0
bare="\$(icp x 2>/dev/null | tail -1)"
echo "BELT-AFTER-BARE"
CAPEOF
  out="$(CAP_MODE=bad CAP_LOG="$CAP_TMP/calls.log" PATH="$CAP_TMP/bin:$PATH" bash "$CAP_TMP/belt.sh" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q 'aborted at line' && printf '%s\n' "$out" | grep -q 'BELT-GUARDED-DONE' \
     && [ "$(printf '%s\n' "$out" | grep -cE '^(A-else|B-else|C-else|D-else|G-or|I-while|J-neg|L-subshell|N-else)')" -eq 9 ] \
     && printf '%s\n' "$out" | grep -qF "M m='M-tail v='''"; then
    _ok "§6ao belt: fourteen guarded shapes (if-tests, || lists, pipelines, negation, subshells, functions, X=\"\$(f)\" with an inner || return surfacing as an if-else) print NO spurious abort on bash $BASH_VERSION; and X=\"\$(f)\" WITHOUT it ran f to its end past the failing pipeline (exit 0, v='') — the 1788550974 finding, re-asserted"
  else _fail "§6ao belt: a guarded shape printed spuriously or misbehaved (exit $rc) — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
  out="$(CAP_MODE=bad CAP_LOG="$CAP_TMP/calls.log" PATH="$CAP_TMP/bin:$PATH" bash "$CAP_TMP/belt.sh" bare 2>&1)"; rc=$?
  if [ "$rc" -eq 7 ] && printf '%s\n' "$out" | grep -q 'deploy.sh aborted at line [0-9][0-9]*: bare=' && ! printf '%s\n' "$out" | grep -q 'BELT-AFTER-BARE'; then
    _ok "§6ao belt: a bare pipeline capture is named (line + command) and the CLI's exit status is preserved (exit 7)"
  else _fail "§6ao belt: the bare capture was not named or the exit status changed (exit $rc) — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
  out="$(CAP_MODE=bad CAP_LOG="$CAP_TMP/calls.log" PATH="$CAP_TMP/bin:$PATH" bash <(grep -vE '^set -E$|^trap .* ERR$' "$CAP_TMP/belt.sh") bare 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -q 'aborted at line'; then _ok "§6ao belt negative control: without the trap the same abort is SILENT (exit $rc)"
  else _fail "§6ao belt negative control: without the trap the abort was not silent (exit $rc)"; fi
  # 1788550974: X="$(f)" where f carries `|| return 1` on its failing step — the OUTER assignment fails, -e stops the
  # script, the ERR trap names the line and the assignment (o=), f's tail never ran; the exit status is f's return (1).
  out="$(CAP_MODE=bad CAP_LOG="$CAP_TMP/calls.log" PATH="$CAP_TMP/bin:$PATH" bash "$CAP_TMP/belt.sh" fnbare 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'deploy.sh aborted at line [0-9][0-9]*: o=' && ! printf '%s\n' "$out" | grep -q 'BELT-AFTER-FNBARE' && ! printf '%s\n' "$out" | grep -q 'N-tail-unreached'; then
    _ok "§6ao belt: X=\"\$(f)\" with an explicit || return 1 inside f aborts the script (exit 1), f's tail never runs, and the ERR trap names the line (o=…)"
  else _fail "§6ao belt: X=\"\$(f)\" with || return 1 inside did not abort by name (exit $rc) — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
  out="$(CAP_MODE=bad CAP_LOG="$CAP_TMP/calls.log" PATH="$CAP_TMP/bin:$PATH" bash <(sed 's/ || return 1; echo "N-tail-unreached" >&2/; echo "N-tail-unreached" >\&2/' "$CAP_TMP/belt.sh") fnbare 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'BELT-AFTER-FNBARE' && printf '%s\n' "$out" | grep -q 'N-tail-unreached' && ! printf '%s\n' "$out" | grep -q 'aborted at line'; then
    _ok "§6ao belt negative control: with f's || return 1 stripped the same X=\"\$(f)\" returns 0, f's tail runs, nothing is named — the explicit return is what makes the abort happen at all on bash $BASH_VERSION"
  else _fail "§6ao belt negative control (|| return 1 stripped): exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
else _fail "§6ao belt: expected exactly the set -E line and one ERR trap line at deploy.sh's top level"; fi
rm -rf "$CAP_TMP"

# ── §6ap 1788550974: a function captured in $(…) never "dies by set -e" — every such capture is gated ──
# Finding, verified on this machine's /bin/bash 3.2.57 (2026-09-04, and
# re-asserted every run by §6ao's belt matrix, shapes M/N): `set -e` is NOT
# enforced inside a function body invoked within a command substitution.
# `X="$(f)"` where f's body has a failing step — a pipeline assignment
# (`v="$(icp … | tr …)"`, icp exit 7) or a bare failing command — runs f TO
# ITS END and the outer assignment gets exit 0 with f's later stdout; the
# same pipeline as a bare top-level assignment aborts, f called BARE aborts,
# an explicit `set -e` inside the substitution aborts. So a helper written
# to "die by set -e" at a failing step continues past it and answers with a
# partial or wrong value, exit 0, and the caller's output gate (if any) is
# the only defence. The audit (task 1788550974) read every `$(fn …)` capture
# on the deploy path — deploy.sh, cold_start.sh, factory_guard.sh and the
# libs they source — and found one helper that relied on -e mid-way:
# mdx_stray_masters, whose `repo=$(pwd -P)` failing would have left repo=''
# so that any pid whose cwd lsof could not read (pcwd='') matched it and was
# reported as OUR zombie — kill -9ed by cold_start. It now returns
# explicitly. Every other captured helper was pure text (a case table, an
# awk, a prompt) or already explicit (`|| true` inside, explicit returns,
# the caller gating on the output by name — §6ao's shape).
# The ban, so the class cannot come back: in the deploy-path scope, every
# `VAR="$(fn …)"` capture of a function DEFINED in that scope must carry one
# of the admitted idioms — `|| true` inside the substitution; `|| die` /
# `|| mdx_die` / `|| err` / `|| return` / `|| exit` / `|| {` on the line;
# a test on VAR (`-n`/`-z`/`-f`… `"$VAR"`, `"$VAR" = …`, `case "$VAR"`,
# `${VAR:-…}`) within the next two lines; a `# pure:` marker on the
# function's DEFINITION line (text-only, never fails — the marker is the
# conscious claim); or a `# safe: <reason>` marker on the capture line.
# Four negative controls prove the scan sees a bare capture, sees a gate
# removed, sees the pure marker removed, and does NOT see a full-line COMMENT
# quoting the shape — the scan and the sites count read the line-preserving
# `uncommented` view (task 1793505680; 1793502104 was flagged live on two
# reply.sh header comments that quoted deploy.sh's arb capture as an
# example), so a comment that documents a capture is neither a site nor a
# gate; the mdx_stray_masters probe drives the REAL function with `pwd`
# shadowed to fail, fixed and stripped.
# The premise's edge (task 1793502104; 1793498812 hit it live): -e is not
# enforced INSIDE fn, but fn's RETURN STATUS is its last command's, and the
# assignment `X="$(fn)"` carries it to the TOP level, where -e IS enforced —
# so a function whose LAST command is a pipeline that can fail (the lib's
# two extractors ended in a grep that misses on a reply without the shape)
# killed a `set -e` caller through a capture this scan admits by the
# variable-test idiom (deploy.sh's arb read, the -z arm one line below it).
# Decision A: the lib's extractors answer by stdout ONLY — a trailing
# `|| true` makes their status 0 — pinned in §3d and DRIVEN in §6af (the
# status, the REACHED probe, a negative control), so the variable-test
# idiom stays sound for them. The scope's other pipeline-ended functions are
# predicates (mdx_reply_ok, valid_teamid — the status IS the answer, never
# captured) or cannot miss (mdx_one_line's tr | cut; usage's sed | sed).
CAPF_SCOPE="scripts/deploy.sh scripts/cold_start.sh scripts/factory_guard.sh scripts/lib/targets.sh scripts/lib/reply.sh scripts/lib/runfiles.sh scripts/fix_icp_keychain_prompts.sh"
capf_fns()  { grep -hoE '^[a-z_][a-z0-9_]*\(\) *\{' $CAPF_SCOPE | sed 's/().*//' | sort -u | paste -sd'|' -; }
capf_pure() { grep -hE '^[a-z_][a-z0-9_]*\(\) *\{.*# pure:' $CAPF_SCOPE | sed 's/().*//' | sort -u | paste -sd'|' -; }
capf_capre() { printf '(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*="?\\$\\((%s)( |\\))' "$1"; }
capf_scan() {  # capf_scan <label> <fns-alternation> <pure-alternation> <file> → violations "label:line: [var <- fn] text"
  # Reads the line-preserving UNCOMMENTED view of <file> (task 1793505680): a full-line comment that QUOTES the
  # shape is not a capture (reply.sh's header did, twice, and 1793502104 was flagged live on it), and a gating
  # idiom spelled in a comment inside the window is not a gate. `uncommented` BLANKS such lines, never deletes
  # them, so the line numbers reported, `sed -n "${i}p"` and the i..i+2 context window all stay the FILE's (a hit
  # line is never a full-line comment, so its text is the file's own). The view is written under CAPF_TMP, which
  # exists before the first call; <label> stays the caller's (the scope loop passes the file path).
  local name="$1" fns="$2" pure="${3:-__none__}" file="$4" view capre i l v f gate ctx
  [ -d "${CAPF_TMP:-}" ] || { echo "$name:0: [CAPF_TMP <- unset] capf_scan has no CAPF_TMP dir to write its uncommented view — the scan ran on nothing"; return 1; }
  view="$CAPF_TMP/view.$(printf '%s' "$name" | tr '/' '_')"
  uncommented "$file" > "$view"
  capre="$(capf_capre "$fns")"
  grep -nE -- "$capre" "$view" | cut -d: -f1 | while read -r i; do
    l="$(sed -n "${i}p" "$view")"
    v="$(printf '%s\n' "$l" | sed -E "s/.*(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=\"?\\\$\\((${fns})( |\\)).*/\2/")"
    f="$(printf '%s\n' "$l" | sed -E "s/.*(^|[^A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)=\"?\\\$\\((${fns})( |\\)).*/\3/")"
    gate="-[nzfdes] \"\\\$\\{?${v}[:}\"]|\"\\\$\\{?${v}\\}?\" *[!=]=|case \"\\\$\\{?${v}[}\"]|\\\$\\{${v}:-"
    ctx="$(sed -n "${i},$((i+2))p" "$view")"
    if printf '%s\n' "$l" | grep -qE -- '\|\| true\)'; then :
    elif printf '%s\n' "$l" | grep -qE -- '\|\| *(die|mdx_die|err|seed_fail|return|exit|\{)'; then :
    elif printf '%s\n' "$l" | grep -qE -- '# safe:'; then :
    elif printf '%s\n' "$f" | grep -qxE -- "$pure"; then :
    elif printf '%s\n' "$ctx" | grep -qE -- "$gate"; then :
    else echo "$name:$i: [$v <- $f] $l"; fi
  done
}
CAPF_FNS="$(capf_fns)"; CAPF_PURE="$(capf_pure)"
if [ -n "$CAPF_FNS" ]; then _ok "§6ap: the deploy-path scope defines $(printf '%s' "$CAPF_FNS" | tr '|' '\n' | grep -c .) functions the scan keys on"
else _fail "§6ap: could not derive the scope's function list — the scan would test nothing"; fi
for p in ask seed_px mdx_env_for mdx_expected_id mdx_principal_set; do
  if printf '%s\n' "$CAPF_PURE" | tr '|' '\n' | grep -qx "$p"; then _ok "§6ap: $p is marked '# pure:' on its definition line (text-only, never fails)"
  else _fail "§6ap: $p lost its '# pure:' definition marker — its bare captures are now unexplained"; fi
done
CAPF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cap6ap.XXXXXX")"   # before the first capf_scan: it writes its uncommented view here
CAPF_SITES=0; CAPF_BARE=""
for f in $CAPF_SCOPE; do
  grep_count n "$(uncommented "$f")" "$(capf_capre "$CAPF_FNS")"; CAPF_SITES=$((CAPF_SITES + ${n:-0}))   # the view capf_scan reads: a comment quoting the shape is not a site
  b="$(capf_scan "$f" "$CAPF_FNS" "${CAPF_PURE:-__none__}" "$f")"; [ -z "$b" ] || CAPF_BARE="$CAPF_BARE$b"$'\n'
done
if [ "$CAPF_SITES" -ge 30 ]; then _ok "§6ap: $CAPF_SITES \$(fn …) capture sites in the deploy-path scope (expected ≥ 30 — the scan sees the shape)"
else _fail "§6ap: only $CAPF_SITES \$(fn …) capture sites seen in the scope — the scan lost the shape (expected ≥ 30)"; fi
if [ -z "$CAPF_BARE" ]; then _ok "§6ap: every \$(fn …) capture in the deploy-path scope is gated (|| true inside, || die/return, a test on the variable, a # pure: definition, or a # safe: marker)"
else _fail "§6ap: bare \$(fn …) capture(s) — bash 3.2 does not enforce -e inside the function; gate the output or mark it: $(printf '%s' "$CAPF_BARE" | tr '\n' ' ' | head -c 400)"; fi
# negative control (1): a synthetic bare capture is flagged, and only it
{ cat scripts/deploy.sh; printf '%s\n' 'NEG_X="$(remote_canister_id backend)"' 'ok "unrelated"' 'ok "unrelated"'; } > "$CAPF_TMP/neg1.sh"
CAPF_N1="$(capf_scan neg1 "$CAPF_FNS" "$CAPF_PURE" "$CAPF_TMP/neg1.sh")"
if [ "$(printf '%s\n' "$CAPF_N1" | grep -c .)" -eq 1 ] && printf '%s\n' "$CAPF_N1" | grep -qF '[NEG_X <- remote_canister_id]'; then _ok "§6ap negative control: a synthetic bare capture NEG_X=\"\$(remote_canister_id …)\" is flagged, alone"
else _fail "§6ap negative control (synthetic bare capture): got '$(printf '%s' "$CAPF_N1" | tr '\n' ' ' | head -c 300)'"; fi
# negative control (1b), task 1793505680: a full-line COMMENT quoting the shape is NOT a hit, while the bare capture
# on the line after it still is — reported at the FILE's line number (the comment sits between the base and NEG_X,
# so a view that DELETED comment lines instead of blanking them would place NEG_X one line early). 1793502104 hit
# the raw read live: two reply.sh header comments quoting deploy.sh's arb capture as an example were flagged.
{ cat scripts/deploy.sh; printf '%s\n' '# NEG_C="$(remote_canister_id backend)"' 'NEG_X="$(remote_canister_id backend)"' 'ok "unrelated"' 'ok "unrelated"'; } > "$CAPF_TMP/negc.sh"
CAPF_NC="$(capf_scan negc "$CAPF_FNS" "$CAPF_PURE" "$CAPF_TMP/negc.sh")"
CAPF_NC_AT=$(( $(wc -l < scripts/deploy.sh) + 2 ))
if [ "$(printf '%s\n' "$CAPF_NC" | grep -c .)" -eq 1 ] && printf '%s\n' "$CAPF_NC" | grep -qF "negc:$CAPF_NC_AT: [NEG_X <- remote_canister_id]"; then _ok "§6ap negative control: a COMMENT quoting the shape (# NEG_C=\"\$(remote_canister_id …)\") is not a hit while the bare NEG_X capture on the next line is, at the file's own line number — the scan reads the line-preserving uncommented view"
else _fail "§6ap negative control (comment quoting the shape): expected exactly 'negc:$CAPF_NC_AT: [NEG_X <- remote_canister_id] …', got '$(printf '%s' "$CAPF_NC" | tr '\n' ' ' | head -c 300)'"; fi
# negative control (2): the frontend-only loop's gate line deleted → its id= capture is flagged (the gate is load-bearing)
grep -vF '[ -n "$id" ] || die "Could not read the $c canister id' scripts/deploy.sh > "$CAPF_TMP/neg2.sh"
CAPF_N2="$(capf_scan neg2 "$CAPF_FNS" "$CAPF_PURE" "$CAPF_TMP/neg2.sh")"
if [ "$(wc -l < "$CAPF_TMP/neg2.sh")" -lt "$(wc -l < scripts/deploy.sh)" ] && printf '%s\n' "$CAPF_N2" | grep -qF '[id <- remote_canister_id]'; then _ok "§6ap negative control: with the frontend-only loop's [ -n \"\$id\" ] gate deleted the id= capture is flagged — the gate is what admits it"
else _fail "§6ap negative control (gate deleted): got '$(printf '%s' "$CAPF_N2" | tr '\n' ' ' | head -c 300)'"; fi
# negative control (3): without the pure roster the seed_px captures are flagged (the # pure: marker is load-bearing)
CAPF_N3="$(capf_scan neg3 "$CAPF_FNS" "__none__" scripts/deploy.sh | grep -cF '<- seed_px]' || true)"
if [ "${CAPF_N3:-0}" -ge 3 ]; then _ok "§6ap negative control: with the # pure: roster emptied the $CAPF_N3 seed_px captures are flagged — the marker is what admits them"
else _fail "§6ap negative control (pure roster emptied): only ${CAPF_N3:-0} seed_px captures flagged (expected ≥ 3)"; fi
# a `# safe: <reason>` marker on the capture line admits it (the documented escape hatch)
{ cat scripts/deploy.sh; printf '%s\n' 'NEG_Y="$(remote_canister_id backend)"  # safe: probe — the value is only logged' 'ok "unrelated"' 'ok "unrelated"'; } > "$CAPF_TMP/neg4.sh"
CAPF_N4="$(capf_scan neg4 "$CAPF_FNS" "$CAPF_PURE" "$CAPF_TMP/neg4.sh")"
if [ -z "$CAPF_N4" ]; then _ok "§6ap: a capture carrying '# safe: <reason>' is admitted"
else _fail "§6ap: the '# safe:' marker did not admit the capture: '$(printf '%s' "$CAPF_N4" | tr '\n' ' ' | head -c 200)'"; fi
# source pins: the rule is written where the first such helper lives; the one at-risk helper returns explicitly
src_has "§6ap: deploy.sh states THE \$(fn) RULE beside remote_canister_id"       "$(cat scripts/deploy.sh)" 'THE $(fn) RULE'
src_has "§6ap: mdx_stray_masters returns explicitly when the repo path cannot be read (no repo, no strays)" "$(cat scripts/lib/targets.sh)" 'repo=$(pwd -P 2>/dev/null) || return 0'
src_has "§6ap: ...and on an empty repo path"                                       "$(cat scripts/lib/targets.sh)" '[ -n "$repo" ] || return 0'
# the mdx_stray_masters probe: the REAL function (with the REAL mdx_local_gateway), pgrep/lsof/icp stubbed, `pwd`
# shadowed by a failing shell function. fixed: no repo → nothing reported. stripped (the pre-fix body): the
# walk continues with repo='' and the unreadable-cwd pid is reported as a stray. healthy: the detector
# still detects (a pid rooted at this cwd is reported; one rooted elsewhere is not).
mkdir -p "$CAPF_TMP/bin"
printf '#!/bin/bash\necho 4242\n' > "$CAPF_TMP/bin/pgrep"
printf '#!/bin/bash\ncase "${CAPF_LSOF:-none}" in here) printf "p4242\\nn%%s\\n" "$(pwd -P)" ;; there) printf "p4242\\nn/nowhere/else\\n" ;; *) : ;; esac\n' > "$CAPF_TMP/bin/lsof"
printf '#!/bin/bash\nexit 0\n' > "$CAPF_TMP/bin/icp"
chmod +x "$CAPF_TMP/bin/pgrep" "$CAPF_TMP/bin/lsof" "$CAPF_TMP/bin/icp"
awk '/^mdx_local_gateway\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' scripts/lib/targets.sh > "$CAPF_TMP/gw.sh"
awk '/^mdx_stray_masters\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' scripts/lib/targets.sh > "$CAPF_TMP/sm.sh"
cat > "$CAPF_TMP/probe.sh" <<'CAPEOF'
#!/bin/bash
# $1 = keep|strip (strip = the pre-fix body)  $2 = pwd-ok|pwd-fails
set -euo pipefail
eval "$(cat "$CAPF_TMP/gw.sh")"
if [ "$1" = strip ]; then eval "$(sed -e '/^  \[ -n "\$repo" \] || return 0$/d' -e 's/ || return 0$//' "$CAPF_TMP/sm.sh")"; else eval "$(cat "$CAPF_TMP/sm.sh")"; fi
if [ "$2" = pwd-fails ]; then pwd() { return 1; }; fi
STRAYS=$(mdx_stray_masters || true)
echo "STRAYS='$(echo $STRAYS)'"
echo CAPF-REACHED
CAPEOF
capf_run() { CAPF_OUT="$(CAPF_TMP="$CAPF_TMP" CAPF_LSOF="$1" PATH="$CAPF_TMP/bin:$PATH" bash "$CAPF_TMP/probe.sh" "$2" "$3" 2>&1)" && CAPF_RC=0 || CAPF_RC=$?; }
if grep -qF 'repo=$(pwd -P 2>/dev/null) || return 0' "$CAPF_TMP/sm.sh" && grep -qF 'for pid in' "$CAPF_TMP/sm.sh" && grep -qF 'mdx_local_gateway() {' "$CAPF_TMP/gw.sh"; then
  capf_run none keep pwd-fails
  if [ "$CAPF_RC" -eq 0 ] && printf '%s\n' "$CAPF_OUT" | grep -qF "STRAYS=''" && printf '%s\n' "$CAPF_OUT" | grep -qF CAPF-REACHED; then _ok "§6ap mdx_stray_masters: with pwd failing the fixed function reports NO stray (the unreadable-cwd pid 4242 is not ours to kill)"
  else _fail "§6ap mdx_stray_masters (pwd failing, fixed): exit $CAPF_RC — $(printf '%s' "$CAPF_OUT" | tr '\n' ' ' | head -c 300)"; fi
  capf_run none strip pwd-fails
  if [ "$CAPF_RC" -eq 0 ] && printf '%s\n' "$CAPF_OUT" | grep -qF "STRAYS='4242'"; then _ok "§6ap mdx_stray_masters negative control: the pre-fix body continues past the failed pwd with repo='' and reports the unreadable-cwd pid 4242 as a stray — the probe sees the bug"
  else _fail "§6ap mdx_stray_masters negative control did not report 4242 (exit $CAPF_RC) — $(printf '%s' "$CAPF_OUT" | tr '\n' ' ' | head -c 300)"; fi
  capf_run here keep pwd-ok
  if [ "$CAPF_RC" -eq 0 ] && printf '%s\n' "$CAPF_OUT" | grep -qF "STRAYS='4242'"; then _ok "§6ap mdx_stray_masters: a pocket-ic rooted at THIS checkout is still detected (4242)"
  else _fail "§6ap mdx_stray_masters (healthy, rooted here): exit $CAPF_RC — $(printf '%s' "$CAPF_OUT" | tr '\n' ' ' | head -c 300)"; fi
  capf_run there keep pwd-ok
  if [ "$CAPF_RC" -eq 0 ] && printf '%s\n' "$CAPF_OUT" | grep -qF "STRAYS=''"; then _ok "§6ap mdx_stray_masters: a pocket-ic rooted elsewhere is not ours (nothing reported)"
  else _fail "§6ap mdx_stray_masters (healthy, rooted elsewhere): exit $CAPF_RC — $(printf '%s' "$CAPF_OUT" | tr '\n' ' ' | head -c 300)"; fi
  capf_run none keep pwd-ok
  if [ "$CAPF_RC" -eq 0 ] && printf '%s\n' "$CAPF_OUT" | grep -qF "STRAYS=''"; then _ok "§6ap mdx_stray_masters: an unreadable cwd (lsof prints nothing) never matches a real repo path"
  else _fail "§6ap mdx_stray_masters (healthy, unreadable cwd): exit $CAPF_RC — $(printf '%s' "$CAPF_OUT" | tr '\n' ' ' | head -c 300)"; fi
else _fail "§6ap: could not extract mdx_stray_masters / mdx_local_gateway from scripts/lib/targets.sh (probe would test nothing)"; fi
rm -rf "$CAPF_TMP"

# ── §6aq H-05 (F1): a pool's exposure-reducing fill is equity-bounded; pool market orders walk the ladder-edge cap ─
# closePosition staged a #market close at mark × (1 ± maxSlippage) (≤ 25 %)
# and releaseDeferred's #3a ladder-edge cap was scoped to spot wallets, so a
# pool's close executed at its raw cap against a colluding ask behind an
# emptied AMM side; clampToInitialMargin's de-lever escape was PRICE-BLIND
# (magnitude-qualified since #49.1) and released the whole flattening size
# at any worst-case price → base residue → #insolvent → absorbBadDebt. Four
# pins on the release path (every taker walks; the held quantity re-parks;
# a zero-quantity release never reaches the engine) and four on the clamp
# (the blind escape is gone; RAW equity at the worst-case price, fees at the
# L0 taker ceiling; the remainder is HELD, not dropped). Live:
# test_initial_margin.sh §F/§F2, test_insurance_fund.sh §H-05,
# test_borrow_unwind.sh §H1–H3 (walk-draining).
H05_REL=$(mo_func src/backend/main.mo "func releaseDeferred(" | mo_code)
[ -n "$H05_REL" ] || _fail "§6aq: could not extract releaseDeferred()"
src_has   "§6aq: the #3a cap applies to every non-FOK market release (pools included)" "$H05_REL" 'let walksLadder = (d.kind == #market) and (not fok);'
src_lacks "§6aq: ...the spot-only pool exclusion is gone"                               "$H05_REL" 'and (Map.get(poolByPrincipal, Text.compare, Principal.toText(d.owner)) == null);'
src_has   "§6aq: the equity-held quantity rides the #market remainder to the re-park"   "$H05_REL" 'let rem = SafeMath.subOrZero(relQty, order.filled) + heldQty;'
src_has   "§6aq: a zero-quantity release re-stages instead of reaching the engine"      "$H05_REL" 'holdWholeRelease(d, heldQty, reDeferCount, effLimit);'
H05_CLAMP=$(mo_func src/backend/main.mo "func clampToInitialMargin(" | mo_code)
[ -n "$H05_CLAMP" ] || _fail "§6aq: could not extract clampToInitialMargin()"
src_lacks "§6aq: the price-blind de-lever escape is gone"                               "$H05_CLAMP" 'if (deLeverQty >= quantity) { return #full };'
src_has   "§6aq: the de-lever portion is bounded by RAW equity"                         "$H05_CLAMP" 'let equity = rawEquityUsd(user);'
src_has   "§6aq: ...at the worst-case price with the fee at the L0 taker ceiling"       "$H05_CLAMP" 'let feeUp = Fixed.mulDiv(qp, TAKER_FEE_BPS, 10_000, true);'
src_has   "§6aq: ...and the unsafe remainder is HELD for the next requote, not dropped" "$H05_CLAMP" 'if (safe < deLeverQty) { held := deLeverQty - safe; deLeverQty := safe };'

# ── §6ar H-06 (F23): every debt-increasing pool action needs the WHOLE basket fresh; the release clamp fails closed ─
# openPosition gated marginPriceFresh(baseToken) only while the borrow gate
# valued the pool's whole collateral basket through the age-blind
# marginPriceLookup (a frozen ETH mark sized a BTC borrow); withdrawMarginPool
# and the liquidator already used the basket-wide userMarksFreshAt.
# clampToInitialMargin returned #full — no margin check at all — on a
# null/zero oracle and scored a present-but-stale mark as fresh. Pins: the
# token-naming basket predicate; the open's basket gate on the POOL
# principal; the clamp's two #full escapes gone, its mark-quality decision
# made once and applied to the re-levering excess only (the de-lever
# pass-through is H-05's and stays). Live: test_margin_staleness.sh §4/§5.
H06_MAIN=$(mo_code < src/backend/main.mo)   # MAIN_MO_IMG is bound later (§8b)
src_has   "§6ar: the basket predicate names the first stale token"                        "$H06_MAIN" 'func userStaleMarkAt(user : Principal, now : Int) : ?Types.TokenId {'
src_has   "§6ar: ...and userMarksFreshAt is its Bool face (one loop, two callers' shapes)"  "$H06_MAIN" 'func userMarksFreshAt(user : Principal, now : Int) : Bool { userStaleMarkAt(user, now) == null };'
H06_OPEN=$(mo_func src/backend/main.mo "func openPosition(" | mo_code)
[ -n "$H06_OPEN" ] || _fail "§6ar: could not extract openPosition()"
src_has   "§6ar: openPosition still gates the traded token's mark (F1)"                    "$H06_OPEN" 'if (not marginPriceFresh(baseToken)) { return #err("oracle price stale for " # baseToken # " — try again shortly") };'
src_has   "§6ar: ...and the pool's whole basket, on the POOL principal, before the borrow"  "$H06_OPEN" 'switch (userStaleMarkAt(poolP, Time.now())) {'
H06_OPEN_GATE_LN=$(printf '%s\n' "$H06_OPEN" | grep -nF 'switch (userStaleMarkAt(poolP, Time.now())) {' | head -1 | cut -d: -f1)
# H-34 (D5 (d)): openPosition no longer BORROWS — it CHECKS the shortfall (reserving nothing) and the fill borrows; the basket gate must still precede that check (§6au pins the fill-time gate).
H06_OPEN_BORROW_LN=$(printf '%s\n' "$H06_OPEN" | grep -nF 'BorrowEngine.borrowCheck(' | head -1 | cut -d: -f1)
if [ -n "$H06_OPEN_GATE_LN" ] && [ -n "$H06_OPEN_BORROW_LN" ] && [ "$H06_OPEN_GATE_LN" -lt "$H06_OPEN_BORROW_LN" ]; then _ok "§6ar: the basket gate (line $H06_OPEN_GATE_LN of the slice) precedes the first BorrowEngine.borrowCheck ($H06_OPEN_BORROW_LN)"
else _fail "§6ar: openPosition's basket gate (${H06_OPEN_GATE_LN:-?}) must precede its borrow check (${H06_OPEN_BORROW_LN:-?}) — the refusal must name the stale token, not the vault"; fi
H06_CLAMP=$(mo_func src/backend/main.mo "func clampToInitialMargin(" | mo_code)
[ -n "$H06_CLAMP" ] || _fail "§6ar: could not extract clampToInitialMargin()"
src_lacks "§6ar: the clamp's missing-oracle #full escape is gone"                          "$H06_CLAMP" 'case null { return #full } };'
src_lacks "§6ar: ...and the zero-oracle #full escape is gone"                              "$H06_CLAMP" 'if (oracle == 0) { return #full };'
src_has   "§6ar: the mark quality is decided once (missing / stale base / stale basket)"   "$H06_CLAMP" 'let markProblem : ?Text = if (oracle == 0) { ?("missing for " # baseToken) }'
src_has   "§6ar: ...over the whole basket"                                                 "$H06_CLAMP" 'else { switch (userStaleMarkAt(user, now)) { case (?t) { ?("stale for " # t # " (pool collateral/debt)") }; case null { null } } };'
src_has   "§6ar: ...and gates only the RE-LEVERING excess (the de-lever part still passes)" "$H06_CLAMP" 'if (deLeverQty + held < quantity) {'
src_has   "§6ar: ...as #partial when a de-lever part exists"                               "$H06_CLAMP" 'if (deLeverQty > 0 or held > 0) { return #partial({ qty = deLeverQty; held }) };'
src_has   "§6ar: ...and #none — killed with the reason — otherwise"                         "$H06_CLAMP" '"Order blocked at release: oracle price " # why #'
H06_GATE_LN=$(printf '%s\n' "$H06_CLAMP" | grep -nF 'switch (markProblem) {' | head -1 | cut -d: -f1)
H06_DELTA_LN=$(printf '%s\n' "$H06_CLAMP" | grep -nF 'if (deltaPerUnit >= 0) {' | head -1 | cut -d: -f1)
if [ -n "$H06_GATE_LN" ] && [ -n "$H06_DELTA_LN" ] && [ "$H06_GATE_LN" -lt "$H06_DELTA_LN" ]; then _ok "§6ar: the stale gate (line $H06_GATE_LN of the slice) precedes the deltaPerUnit shortcut ($H06_DELTA_LN) — a zero oracle cannot pass a #sell as collateral-improving"
else _fail "§6ar: the clamp's stale gate (${H06_GATE_LN:-?}) must precede the deltaPerUnit >= 0 early return (${H06_DELTA_LN:-?})"; fi
src_has   "§6ar: test_margin_staleness §4 drives the basket gate (stale ETH owed, BTC traded)" "$(uncommented tests/test_margin_staleness.sh)" 'if echo "$R" | grep -q "oracle price stale for ETH"; then ok "§4:'
src_has   "§6ar: test_margin_staleness §5 drives the clamp through the users-only expiry pass" "$(uncommented tests/test_margin_staleness.sh)" 'if echo "$RJ" | grep -q "oracle price stale for BTC"; then ok "§5:'

# ── §6as task 1788557389 (H-05's carry-over): a pool close reserves at the MARK, and a trimmed staging is never silent ─
# parkDeferred's under-funded #buy branch sized an owner's staging at the
# order's limitPrice — for closePosition's #market close that is the slippage
# CAP (mark × (1 + maxSlippage), up to 25 %), so a pool whose free quote was
# thin at the cap parked LESS than its short and the rest was never re-staged:
# the trader saw #ok and kept a residual position (a 2,100 ICP short staged
# ≈ 1,696 at a 25 % cap, test_initial_margin §F2). Shape 2 of the task: the
# reservation of a pool's exposure-REDUCING #market #buy is sized at the mark
# (poolDeleverMark), the release-time #3a price cap and H-05 equity bound
# protect the price, and the engine's available-balance clamp makes a short
# reservation harmless. Pins: the full-headroom path keeps the L0 ceiling
# (1788475362's flat-rate work stays), the under-funded branch sizes at
# sizePrice and trims at the EARNED rate, never parks more than asked, the
# old cap-price division is gone; the mark helper is pool-short-only and
# floored at the cap; every staging that parks short of its size records it
# (closePosition, the #3a re-park, the held re-park). Live: §F2.
H_PARK=$(mo_func src/backend/main.mo "func parkDeferred(" | mo_code)
[ -n "$H_PARK" ] || _fail "§6as: could not extract parkDeferred()"
src_has   "§6as: the full-headroom reservation still sizes at the cap price with the L0 fee ceiling" "$H_PARK" 'let feeUp = Fixed.mulDiv(base, ceilBps, 10_000, true);'
src_has   "§6as: ...and parks the full qty when the cap reservation fits"                          "$H_PARK" 'if (want <= avail) {'
src_has   "§6as: the under-funded branch sizes a pool's de-lever #market buy at the mark"           "$H_PARK" 'let sizePrice = if (kind == #market) { poolDeleverMark(owner, baseToken, marketId, limitPrice) } else { limitPrice };'
src_has   "§6as: ...parking the whole position when it fits at the mark"                            "$H_PARK" 'if (wantM <= avail) {'
src_has   "§6as: ...the trim still uses the owner's EARNED taker rate (1788475362)"                 "$H_PARK" 'let effBps = quoteFeeFor(owner, 10_000, #takerDebit);'
src_has   "§6as: ...divides by the sizing price and never parks more than asked"                    "$H_PARK" 'Nat.min(qty, Fixed.div(baseAfford, sizePrice, false))'
src_lacks "§6as: the cap-price trim (baseAfford / limitPrice) is gone"                              "$H_PARK" 'Fixed.div(baseAfford, limitPrice, false)'
H_MARK=$(mo_func src/backend/main.mo "func poolDeleverMark(" | mo_code)
[ -n "$H_MARK" ] || _fail "§6as: could not extract poolDeleverMark()"
src_has   "§6as: the mark helper keeps the cap for a pool with no short in the base (a #buy re-levers it)" "$H_MARK" 'if (poolNetSize(poolId, baseToken) >= 0) { return fallback };'
src_has   "§6as: ...and floors the mark at the order's cap"                                          "$H_MARK" 'Nat.min(p.refPrice, fallback)'
H_NOTE=$(mo_func src/backend/main.mo "func noteStagedShort(" | mo_code)
[ -n "$H_NOTE" ] || _fail "§6as: could not extract noteStagedShort()"
src_has   "§6as: the short-staging record is a no-op when the whole size staged"                    "$H_NOTE" 'if (staged >= asked) { return };'
src_has   "§6as: ...and names the un-staged remainder otherwise"                                    "$H_NOTE" '" is NOT staged. Close again'
H_CLOSE=$(mo_func src/backend/main.mo "func closePosition(" | mo_code)
[ -n "$H_CLOSE" ] || _fail "§6as: could not extract closePosition()"
src_has   "§6as: closePosition records a staging that parked less than the position"                "$H_CLOSE" 'case (?e) { noteStagedShort(poolP, marketId, baseToken, side, Int.abs(size), e.qty, execPrice) };'
src_lacks "§6as: ...the silent case (?_) is gone"                                                   "$H_CLOSE" 'case (?_) {};'
src_has   "§6as: the #3a re-park records a trimmed remainder (budgeted spot remainders exempt)"      "$(mo_func src/backend/main.mo "func releaseDeferred(" | mo_code)" 'if (remBudget == null) { noteStagedShort(d.owner, d.marketId, d.baseToken, d.side, rem, e2.qty, d.limitPrice) };'
src_has   "§6as: ...and so does the held re-park"                                                   "$(mo_func src/backend/main.mo "func holdWholeRelease(" | mo_code)" 'noteStagedShort(d.owner, d.marketId, d.baseToken, d.side, held, e2.qty, d.limitPrice);'
src_has   "§6as: getApiDoc's margin paragraph records the shape (reserve at the mark)"              "$(mo_code < src/backend/main.mo)" 'market close reserves its buy-back at the MARK, not at the slippage cap'
# 1788533844 (operator decision (i), 2026-09-06): runLiquidationBatch does NOT
# reconcile idle pool debt — the owner's repayPoolDebt is the whole answer, and
# getApiDoc tells bot authors so in one sentence (the frontend's Repay row is
# pinned by tests/frontend_display_integrity.test.mjs §N2).
src_has   "§6as/1788533844: getApiDoc records decision (i) — idle debt is the owner's via repayPoolDebt; the liquidation pass never repays" "$(mo_code < src/backend/main.mo)" 'idle debt is retired by the owner via repayPoolDebt; the liquidation pass never repays'
src_has   "§6as/1788533844: ...and that fundMarginPool is margin, not repayment"                    "$(mo_code < src/backend/main.mo)" 'fundMarginPool is margin, not repayment'
src_has   "§6as: test_initial_margin §F2 pins the whole position staging"                          "$(uncommented tests/test_initial_margin.sh)" 'then ok "F2: the WHOLE 2,100 ICP short staged'

# ── §6at H-32 (F12, D2): one principal's exit-set tape inflow is bounded without refusing an exit; the drain scales; the shear needs memory pressure ─
# The exit set is admitted at every floor (W1-05, §6c) and the four
# value-moving exits bounded only `amount == 0`, writing 2–11 permanent rows
# each: one registered principal issuing dust exits at ingress speed out-ran
# a healthy archive's fixed one-batch-per-tick drain and reached the
# SIZE-ONLY L3 shear in ~18 min — 175k events of everyone's history dropped
# with nothing wrong. D2 (task 1788467594) kept the doctrine (exits are
# never refused, at the gate or in the body) and bounded the TAPE instead:
# a per-principal window in which a DUST exit (under EXIT_DUST_USD — the
# order path's own entry floor — and not spend-all) executes in full but has
# its journal rows MOVED into the window and summed, flushed as ordinary
# rows at the window's end (never dropped); a backlog-scaled ship burst above
# the soft tier; and a shear gated on a memory-pressure signal. Pins: the
# decision helper, the fold (rows moved, not copied), the flush, every
# forced-flush point ahead of an absolute row, the wipe clearing, the four
# exits' dust predicates (spend-all exempt), the window map STABLE, the
# burst loop and its guards, the shear's AND. Live: test_exit_coalesce.sh
# (RED 14/28 on the pre-fix build → 29/29) and test_archive_failover.sh §F.
H32_MAIN=$(mo_code < src/backend/main.mo)
src_has   "§6at: the dust bar IS the order path's entry floor (W3-10), not a new number"        "$H32_MAIN" 'transient let EXIT_DUST_USD : Nat = Types.MIN_ORDER_ICPUSD;'
src_has   "§6at: the window map is a plain let — STABLE, so withheld rows survive an upgrade"      "$H32_MAIN" 'let _exitWindows = Map.empty<Text, ExitWindow>();'
src_lacks "§6at: ...never transient (a lost withheld row is a permanent fold mismatch)"          "$H32_MAIN" 'transient let _exitWindows'
H32_FOLDS=$(mo_func src/backend/main.mo "func exitFolds(" | mo_code)
[ -n "$H32_FOLDS" ] || _fail "§6at: could not extract exitFolds()"
src_has   "§6at: an elapsed window is flushed BEFORE the new one opens (the spaced exit is live)"  "$H32_FOLDS" 'if (now - w.openedNs >= exitCoalesceWindowNs()) {'
src_has   "§6at: ...flushExitWindow then a fresh window"                                          "$H32_FOLDS" 'flushExitWindow(key, w);'
src_has   "§6at: inside the window only DUST folds (a genuine exit writes live)"                  "$H32_FOLDS" '} else { dust };'
src_has   "§6at: the first exit opens the window and writes live"                                  "$H32_FOLDS" 'case null { Map.add(_exitWindows, Text.compare, key, freshExitWindow(now)); false };'
H32_FOLD=$(mo_func src/backend/main.mo "func foldDustExit(" | mo_code)
[ -n "$H32_FOLD" ] || _fail "§6at: could not extract foldDustExit()"
src_has   "§6at: the fold sums the exit's journal rows per (principal, token)"                     "$H32_FOLD" 'deltas := sumDeltaRow(deltas, p, tok, d)'
src_has   "§6at: ...and MOVES them off the journal (never copied — nothing folds twice)"           "$H32_FOLD" 'List.truncate(accounts.journal, j0);'
src_has   "§6at: ...counting the coalesced exit"                                                  "$H32_FOLD" '_exitCoalesced += 1;'
src_lacks "§6at: the fold never awaits (it runs inside the exit's own message)"                   "$H32_FOLD" 'await'
H32_FLUSH=$(mo_func src/backend/main.mo "func flushExitWindow(" | mo_code)
[ -n "$H32_FLUSH" ] || _fail "§6at: could not extract flushExitWindow()"
src_has   "§6at: the flush closes the window"                                                     "$H32_FLUSH" 'ignore Map.delete(_exitWindows, Text.compare, key);'
src_has   "§6at: ...writes nothing for a window that folded nothing"                              "$H32_FLUSH" 'if (w.folded == 0) { return };'
src_has   "§6at: ...and emits the withheld #delta rows RAW, like the drain"                        "$H32_FLUSH" 'emitEventRaw(p, null, #delta { token = tok; amount = d })'
src_has   "§6at: the heartbeat drain flushes elapsed windows"                                     "$(mo_func src/backend/main.mo "func drainLedgerJournal(" | mo_code)" 'flushExitWindows(false);'
H32_SHED=$(mo_func src/backend/main.mo "func shedOldestEvents(" | mo_code)
H32_SHED_FLUSH=$(printf '%s\n' "$H32_SHED" | grep -nF 'flushExitWindows(true);' | head -1 | cut -d: -f1)
H32_SHED_DRAIN=$(printf '%s\n' "$H32_SHED" | grep -nF 'drainLedgerJournal();' | head -1 | cut -d: -f1)
if [ -n "$H32_SHED_FLUSH" ] && [ -n "$H32_SHED_DRAIN" ] && [ "$H32_SHED_FLUSH" -lt "$H32_SHED_DRAIN" ]; then _ok "§6at: the shed forces every window out (line $H32_SHED_FLUSH of the slice) ahead of the drain ($H32_SHED_DRAIN) and so ahead of its re-baseline — no withheld row can land after an absolute row"
else _fail "§6at: shedOldestEvents must flushExitWindows(true) (${H32_SHED_FLUSH:-missing}) before drainLedgerJournal() (${H32_SHED_DRAIN:-missing})"; fi
H32_SEASON=$(mo_func src/backend/main.mo "func resetSeason(" | mo_code)
H32_SEASON_FLUSH=$(printf '%s\n' "$H32_SEASON" | grep -nF 'flushExitWindows(true);' | head -1 | cut -d: -f1)
H32_SEASON_GATE=$(printf '%s\n' "$H32_SEASON" | grep -nF 'if (nextEventSeq != shippedSeq) {' | head -1 | cut -d: -f1)
if [ -n "$H32_SEASON_FLUSH" ] && [ -n "$H32_SEASON_GATE" ] && [ "$H32_SEASON_FLUSH" -lt "$H32_SEASON_GATE" ]; then _ok "§6at: resetSeason forces the windows out ($H32_SEASON_FLUSH) before its unshipped-history gate ($H32_SEASON_GATE) — the closed season's tape carries every withheld row"
else _fail "§6at: resetSeason must flushExitWindows(true) (${H32_SEASON_FLUSH:-missing}) before the unshipped-history gate (${H32_SEASON_GATE:-missing})"; fi
src_has   "§6at: the world wipe clears the windows with the journal (genesis rows carry the balances)" "$(mo_func src/backend/main.mo "func performWorldWipe(" | mo_code)" 'Map.clear(_exitWindows);'
src_has   "§6at: adminReplayReset forces the windows out so the fold is comparable"                "$(mo_func src/backend/main.mo "func adminReplayReset(" | mo_code)" 'flushExitWindows(true);'
src_has   "§6at: adminReplayStep's done requires no withheld rows"                                 "$(mo_func src/backend/main.mo "func adminReplayStep(" | mo_code)" 'and exitRowsWithheld() == 0'
# The four exits: dust predicate (spend-all exempt), journal mark before the first move, fold-or-live.
H32_WMP=$(mo_func src/backend/main.mo "func withdrawMarginPool(" | mo_code)
src_has   "§6at: withdrawMarginPool reads its journal mark before the debit"                        "$H32_WMP" 'let j0 = List.size(accounts.journal);'
src_has   "§6at: ...and folds only dust that leaves free ICPUSD behind"                            "$H32_WMP" 'if (exitFolds(msg.caller, Time.now(), amount < EXIT_DUST_USD and amount < poolAvail)) {'
H32_UNS=$(mo_func src/backend/main.mo "func unstakeInsurance(" | mo_code)
src_has   "§6at: unstakeInsurance: dust = payout under the bar AND shares remain"                   "$H32_UNS" 'let dust = payout < EXIT_DUST_USD and shares < getInsuranceShares(msg.caller);'
src_has   "§6at: ...folds the #insuranceUnstake with its rows"                                     "$H32_UNS" 'foldDustExit(msg.caller, j0, #ins(shares, payout))'
src_has   "§6at: ...or writes it live"                                                             "$H32_UNS" 'else { emitEvent(msg.caller, null, #insuranceUnstake { shares; payoutUsd = payout }) };'
H32_WLP=$(mo_func src/backend/main.mo "func performLpWithdraw(" | mo_code)   # task 1788503312: the redemption body (withdrawLp wraps it)
src_has   "§6at: withdrawLp: dust = NAV under the bar AND shares remain"                            "$H32_WLP" 'let dust = lpAmount < have and VaultMath.navValue(lpAmount, vaultLPSupply, navUsd) < EXIT_DUST_USD;'
src_has   "§6at: ...folds the #lpWithdraw with its legs"                                           "$H32_WLP" 'if (folds) { foldDustExit(owner, j0, #lp(lpAmount, basketRows)) };'
H32_WLP_FOLD=$(printf '%s\n' "$H32_WLP" | grep -nF 'foldDustExit(owner, j0, #lp(' | head -1 | cut -d: -f1)
H32_WLP_SWEEP=$(printf '%s\n' "$H32_WLP" | grep -nF 'sweepZeroSupplyVaultToTreasury()' | head -1 | cut -d: -f1)
if [ -n "$H32_WLP_FOLD" ] && [ -n "$H32_WLP_SWEEP" ] && [ "$H32_WLP_FOLD" -lt "$H32_WLP_SWEEP" ]; then _ok "§6at: withdrawLp folds ($H32_WLP_FOLD) BEFORE the zero-supply sweep ($H32_WLP_SWEEP) — the treasury's rows are the sweep's, not the exit's"
else _fail "§6at: withdrawLp must fold (${H32_WLP_FOLD:-missing}) before sweepZeroSupplyVaultToTreasury (${H32_WLP_SWEEP:-missing})"; fi
H32_RW=$(mo_func src/backend/main.mo "func recordWithdrawal(" | mo_code)
[ -n "$H32_RW" ] || _fail "§6at: could not extract recordWithdrawal()"
src_has   "§6at: withdraw's tape half: dust = under the bar at the mark AND not spend-all"          "$H32_RW" 'let dust = record.amount < availBefore and (switch (markValueUsd(record.token, record.amount)) {'
src_has   "§6at: ...an unpriced token is never dust"                                               "$H32_RW" 'case null { false };'
src_has   "§6at: ...folds the #withdrawal or writes it live"                                       "$H32_RW" 'if (exitFolds(user, record.timestamp, dust)) { foldDustExit(user, j0, #withdrawal(record.token, record.amount)) }'
src_lacks "§6at: ...and never awaits"                                                             "$H32_RW" 'await'
H32_MIX=$(mo_func src/backend/mixins/UserAccount.mo "func withdraw(" | mo_code)
H32_MIX_J0=$(printf '%s\n' "$H32_MIX" | grep -nF 'let j0 = List.size(accounts.journal);' | head -1 | cut -d: -f1)
H32_MIX_SUB=$(printf '%s\n' "$H32_MIX" | grep -nF 'Accounts.subtractBalance(accounts, msg.caller, token, amount)' | head -1 | cut -d: -f1)
if [ -n "$H32_MIX_J0" ] && [ -n "$H32_MIX_SUB" ] && [ "$H32_MIX_J0" -lt "$H32_MIX_SUB" ]; then _ok "§6at: the mixin's withdraw reads its journal mark ($H32_MIX_J0) before the debit ($H32_MIX_SUB)"
else _fail "§6at: mixins/UserAccount.mo withdraw must read j0 (${H32_MIX_J0:-missing}) before subtractBalance (${H32_MIX_SUB:-missing})"; fi
src_has   "§6at: ...and hands the tape row to the actor's window with the pre-debit available balance" "$H32_MIX" 'recordWithdrawal(msg.caller, j0, { token; amount; timestamp = Time.now(); kind = #withdrawal }, avail);'
# The drain bursts above the soft tier; the shear needs memory pressure.
src_has   "§6at: the burst ceiling is a transient literal"                                        "$H32_MAIN" 'transient let SHIP_BURST_MAX : Nat = 8;'
src_has   "§6at: shipBatchTo sizes its batch from the (pinnable) batch max"                        "$(mo_func src/backend/main.mo "func shipBatchTo(" | mo_code)" 'let k = if (n > shipBatchMax()) { shipBatchMax() } else { n };'
H32_TICK=$(mo_func src/backend/main.mo "func tickShipEvents(" | mo_code)
[ -n "$H32_TICK" ] || _fail "§6at: could not extract tickShipEvents()"
src_has   "§6at: the ordinary batch goes through shipBatchTo"                                      "$H32_TICK" 'switch (await* shipBatchTo(a, epoch)) {'
src_has   "§6at: the burst loop runs only above the soft tier, on a healthy shipper, in-epoch"     "$H32_TICK" 'label drain while (burst < SHIP_BURST_MAX and not archiveFull and _shipFailStreak == 0'
src_has   "§6at: ...(the tier + epoch guards)"                                                     "$H32_TICK" 'and List.size(userEvents) > shipSoftTier() and _captureEpoch == epoch) {'
src_has   "§6at: ...re-reading archive0 each pass and stopping on #full / a non-ack"               "$H32_TICK" 'case (#acked(f)) { if (f.full) { break drain } };'
src_has   "§6at: the L3 shear needs size AND memory pressure"                                     "$H32_TICK" 'if (List.size(userEvents) >= shipShearCap() and shearMemoryPressure()) {'
src_lacks "§6at: the size-only shear is gone"                                                     "$H32_TICK" 'if (List.size(userEvents) >= shipShearCap()) {'
H32_MEM=$(mo_func src/backend/main.mo "func shearMemoryPressure(" | mo_code)
src_has   "§6at: the memory signal reads wasm memory against the canister's limit"                 "$H32_MEM" '(Prim.rts_memory_size() * 100 >= limit * SHEAR_MEM_PCT)'
src_has   "§6at: ...or a recent lowmemory() hook"                                                  "$H32_MEM" '_lowMemoryAtNs > 0 and Time.now() - _lowMemoryAtNs < SHEAR_LOWMEM_TTL_NS'
src_has   "§6at: ...with the platform default until canister_status has been read"                 "$H32_MEM" 'let limit = if (_wasmMemoryLimit > 0) { _wasmMemoryLimit } else { SHEAR_MEM_LIMIT_DEFAULT };'
src_has   "§6at: test_exit_coalesce §1 asserts the tape series the fix moves (rows per burst)"     "$(uncommented tests/test_exit_coalesce.sh)" 'then ok "tape-bound rows grew by $GROW1 for 12 exits'
src_has   "§6at: test_exit_coalesce §5 asserts one tick drains to the soft tier"                   "$(uncommented tests/test_exit_coalesce.sh)" 'then ok "ONE ship tick drained $Q0 → $Q1'
src_has   "§6at: test_archive_failover §F asserts no shed past the shear cap without memory pressure" "$(uncommented tests/test_archive_failover.sh)" 'ok "no shed past the shear cap WITHOUT memory pressure'

# ── §6au H-34 / D5 option (d): leverage is BORROWED AT THE FILL, never at placement ─
# The operator's 2026-09-05 ruling (tasks/archive/1788467597) superseded the
# H-34 brief's (a)/(b)/(c): a leveraged pool entry reserves NOTHING from the
# vault until it executes. openPosition only CHECKS the shortfall (sized at
# the ceiling, reserving nothing) and stages the whole size; the engine's
# ProtectionCtx.fundForFill hook (poolFundForFill) borrows exactly each
# slice's shortfall at the fill — synchronously, on fresh marks, through
# BorrowEngine.borrow — and a vault that cannot lend fails the slice CLOSED
# (maker: W4-24's notice + cancel; aggressor: H-10's remainder cancel + one
# notice naming the vault). Only exposure-INCREASING fills borrow; exits are
# funded by holdings as before, the resting-order earmark and the post-debit
# adjuster cover exits only, and the release clamp scores a pool's excess
# as borrowed at the fill. H-07's idle-repay arms stay, dead-safe. Live:
# test_initial_margin.sh §G1–G3 (RED 16 ✗ on main 8ae4549's build → GREEN).
H34_OPEN=$(mo_func src/backend/main.mo "func openPosition(" | mo_code)
[ -n "$H34_OPEN" ] || _fail "§6au: could not extract openPosition()"
src_lacks "§6au: openPosition takes NO placement-time borrow"                               "$H34_OPEN" 'BorrowEngine.borrow('
src_has   "§6au: ...it CHECKS the long's shortfall at the ceiling (reserving nothing)"      "$H34_OPEN" 'switch (BorrowEngine.borrowCheck(loans, marginAccounts, accounts, reservedBalance, ammPrincipal(), poolP, Types.QUOTE_TOKEN, quoteNeeded - have, now, marginPriceLookup)) {'
src_has   "§6au: ...and the short's"                                                        "$H34_OPEN" 'switch (BorrowEngine.borrowCheck(loans, marginAccounts, accounts, reservedBalance, ammPrincipal(), poolP, baseToken, sizeBase - have, now, marginPriceLookup)) {'
src_lacks "§6au: ...so there is no borrow to unwind on a staging failure"                   "$H34_OPEN" 'BorrowEngine.repay('
H34_ENGINE=$(mo_code < src/backend/lib/MatchingEngine.mo)
src_has   "§6au: the engine's ProtectionCtx carries the fundForFill hook (REQUIRED field)"  "$H34_ENGINE" 'fundForFill : (party : Principal, baseToken : Types.TokenId,'
src_has   "§6au: the limit variant funds the BUYER per slice before its gate"               "$H34_ENGINE" 'let buyerFunded  = ctx.fundForFill(buyer,  baseToken, Types.QUOTE_TOKEN, tradeCost + buyerFee, fillQty);'
src_has   "§6au: ...and the SELLER"                                                         "$H34_ENGINE" 'let sellerFunded = buyerFunded and ctx.fundForFill(seller, baseToken, baseToken, fillQty, fillQty);'
src_has   "§6au: the market variant funds the MAKER per slice (its taker is never a pool)"  "$H34_ENGINE" 'if (not ctx.fundForFill(best.owner, baseToken, makerTok, makerNeeds, fillQty)) {'
src_has   "§6au: an unfundable aggressor stops the walk, marked for the H-10 cancel"        "$H34_ENGINE" 'aggressorUnfunded := true;'
src_has   "§6au: ...the ONE notice fires for any unfunded aggressor (sweep or pool)"        "$H34_ENGINE" 'if (aggressorUnfunded) {'
src_has   "§6au: ...and its remainder is never rested (the cancel branch is sweep-agnostic)" "$H34_ENGINE" '} else if (aggressorUnfunded) {'
H34_FUND=$(mo_func src/backend/main.mo "func poolFundForFill(" | mo_code)
[ -n "$H34_FUND" ] || _fail "§6au: could not extract poolFundForFill()"
src_has   "§6au: the hook is a wallet no-op (the engine's balance gates decide)"            "$H34_FUND" 'case null { return true };'
src_has   "§6au: ...borrows only for an exposure-INCREASING fill (exits are never borrowed)" "$H34_FUND" 'if (not poolOrderAddsExposure(poolId, side, baseToken, fillQty)) { return true };'
src_has   "§6au: ...gates the traded token's mark (F1)"                                     "$H34_FUND" 'if (not marginPriceFreshAt(baseToken, now)) { return refuse("oracle price stale for " # baseToken) };'
src_has   "§6au: ...and the whole basket (H-06) before the borrow"                          "$H34_FUND" 'switch (userStaleMarkAt(party, now)) {'
src_has   "§6au: ...borrows exactly the slice's shortfall through BorrowEngine.borrow (borrowCheck inside)" "$H34_FUND" 'switch (BorrowEngine.borrow(loans, marginAccounts, accounts, reservedBalance, ammPrincipal(), party, token, short, now, marginPriceLookup)) {'
src_has   "§6au: ...re-provisions the pool after the loan mutation"                         "$H34_FUND" 'reprovisionPool(party);'
src_has   "§6au: ...and stashes the vault's reason for the notice"                          "$H34_FUND" 'Map.add(_borrowRefusal, Text.compare, Principal.toText(party), why);'
H34_GATE_LN=$(printf '%s\n' "$H34_FUND" | grep -nF 'switch (userStaleMarkAt(party, now)) {' | head -1 | cut -d: -f1)
H34_BORROW_LN=$(printf '%s\n' "$H34_FUND" | grep -nF 'BorrowEngine.borrow(' | head -1 | cut -d: -f1)
if [ -n "$H34_GATE_LN" ] && [ -n "$H34_BORROW_LN" ] && [ "$H34_GATE_LN" -lt "$H34_BORROW_LN" ]; then _ok "§6au: the basket gate (line $H34_GATE_LN of the slice) precedes the fill-time borrow ($H34_BORROW_LN)"
else _fail "§6au: poolFundForFill's basket gate (${H34_GATE_LN:-?}) must precede its borrow (${H34_BORROW_LN:-?})"; fi
src_lacks "§6au: the hook never awaits (it runs inside the matching pass)"                  "$H34_FUND" 'await'
H34_CTX_N=$(printf '%s\n' "$H06_MAIN" | grep -cE 'onTradeFees += recordTradeFees;')
H34_HOOK_N=$(printf '%s\n' "$H06_MAIN" | grep -cE 'fundForFill += poolFundForFill;')
if [ "${H34_CTX_N:-0}" -ge 5 ] && [ "$H34_CTX_N" = "$H34_HOOK_N" ]; then _ok "§6au: every ProtectionCtx literal in main.mo wires the hook ($H34_HOOK_N of $H34_CTX_N)"
else _fail "§6au: $H34_HOOK_N of $H34_CTX_N ProtectionCtx literals wire fundForFill = poolFundForFill — a ctx without it is a build error today, but keep the count honest"; fi
src_has   "§6au: the notice names the vault's reason for a pool"                            "$H06_MAIN" 'Pool order cancelled mid-match: the vault could not lend this pool'
H34_PARK=$(mo_func src/backend/main.mo "func parkDeferred(" | mo_code)
src_has   "§6au: parkDeferred names a pool's exposure-increasing entry"                     "$H34_PARK" 'case (?poolId) { poolOrderAddsExposure(poolId, side, baseToken, qty) };'
src_has   "§6au: ...parks a pool entry's WHOLE quantity against what it owns (never trimmed)" "$H34_PARK" '(Types.QUOTE_TOKEN, Nat.min(want, avail), qty, null)'
src_has   "§6au: ...a short entry too"                                                      "$H34_PARK" '(baseToken, amt, if (poolEntry) { qty } else { amt }, null)'
src_has   "§6au: ...and lets a pool entry reserve nothing"                                  "$H34_PARK" 'if (parkedQty == 0 or (reserve == 0 and not poolEntry)) { return null };'
H34_REL=$(mo_func src/backend/main.mo "func releaseDeferred(" | mo_code)
src_has   "§6au: releaseDeferred recognises a borrow-refused pool aggressor"                "$H34_REL" 'let borrowRefused = (stop == #unfunded) and Option.isSome(Map.get(poolByPrincipal, Text.compare, Principal.toText(d.owner)));'
src_has   "§6au: ...never re-parks its #market remainder (no second record either)"         "$H34_REL" 'else if (borrowRefused) {'
src_has   "§6au: ...and links no order for the id-0 #limit cancel"                          "$H34_REL" 'if (order.id != 0) { linkStagedRelease(d.id, order.id) };'
src_has   "§6au: H-07's tail stays as a dead-safe backstop"                                 "$H34_REL" 'if (relQty < d.qty or (unfilled > 0 and not remainderLives)) { repayIdlePoolBorrow(d.owner, d.marketId) };'
H34_NEEDS=$(mo_func src/backend/main.mo "func poolRestingOrderNeeds(" | mo_code)
src_has   "§6au: the resting-order earmark covers EXITS only"                               "$H34_NEEDS" 'if (rem > 0 and not isEntry) {'
H34_REVAL=$(mo_func src/backend/main.mo "func revalidateUserOrders(" | mo_code)
src_has   "§6au: a pool's post-debit adjuster leaves its borrow-at-fill entries alone"      "$H34_REVAL" 'LiquidityManager.adjustPoolOrders(orderStore, accounts, user, getAllMarketPairs(),'
H34_LM=$(mo_code < src/backend/lib/LiquidityManager.mo)
src_has   "§6au: ...via the exits-only pool adjuster (balance shrink, no wallet caps)"      "$H34_LM" 'public func adjustPoolOrders('
src_has   "§6au: ...whose shrink skips the named entries"                                   "$H34_LM" 'if (OrderBook.isOpen(o) and not skip(o)) {'
H34_CLAMP=$(mo_func src/backend/main.mo "func clampToInitialMargin(" | mo_code)
# Task 1793732895: the per-unit inequality moved out of the clamp into
# BorrowEngine.fillDeltaPerUnit (+ fillHeadroom / fillRoom), the ONE source
# previewOpenPosition shares with the release — the arm literals are pinned
# THERE, and both call sites are pinned here so the two can never drift again.
H34_FILL=$(mo_func src/backend/lib/BorrowEngine.mo "func fillDeltaPerUnit(" | mo_code)
[ -n "$H34_FILL" ] || _fail "§6au: could not extract BorrowEngine.fillDeltaPerUnit()"
src_has   "§6au: the release clamp scores a pool's re-levering excess as BORROWED at the fill (buy)"  "$H34_FILL" 'case (true, #buy)   { haircut - (Fixed.mul(qp, Types.INITIAL_HEALTH_RATIO, true) : Int) };'
src_has   "§6au: ...(sell: the base debt valued UP at the mark)"                            "$H34_FILL" 'case (true, #sell)  { (qp : Int) - (Fixed.mul(oracle, Types.INITIAL_HEALTH_RATIO, true) : Int) };'
src_has   "§6au: ...and the clamp takes its per-unit delta from that shared function"      "$H34_CLAMP" 'let deltaPerUnit : Int = BorrowEngine.fillDeltaPerUnit(Option.isSome(poolIdOf), side, oracle, baseLtv, qp);'
src_has   "§6au: ...its headroom too"                                                       "$H34_CLAMP" 'let headroom : Int = BorrowEngine.fillHeadroom(h.collateralUsd, h.debtUsd);'
src_has   "§6au: ...and its room"                                                           "$H34_CLAMP" 'let maxExcess = switch (BorrowEngine.fillRoom(headroom, deltaPerUnit)) { case (?q) { q }; case null { excessQty } };'
H34_PREVIEW=$(mo_func src/backend/main.mo "func previewOpenPosition(" | mo_code)
[ -n "$H34_PREVIEW" ] || _fail "§6au: could not extract previewOpenPosition()"
# Task 1793733917: the probe and the verdict run for `side` as given — the
# #buy-only gate of 1793732895 is gone (a 20 % BTC market short previewed
# canOpen = true at 2.75× while the release's post-sale rule, qp − 1.25·oracle,
# cut it to 2.2×); the clamp's #sell arm already carried the right delta, so
# maxSizeBase = min(borrow room, clamp room) now reads for either side and the
# refusal names the side.
src_has   "§6au: previewOpenPosition judges EITHER side by the release clamp itself (the capacity probe)"  "$H34_PREVIEW" 'let probed = clampToInitialMargin(poolP, baseToken, side, probe, execPrice);'
src_has   "§6au: ...and the requested size by the same clamp (the release's literal verdict)" "$H34_PREVIEW" 'let verdict = if (probe == sizeBase) { probed } else { clampToInitialMargin(poolP, baseToken, side, sizeBase, execPrice) };'
src_lacks "§6au: ...no #buy-gated clamp call survives in the preview (1793733917)"           "$H34_PREVIEW" 'clampToInitialMargin(poolP, baseToken, #buy,'
src_has   "§6au: ...and the refusal names the side"                                          "$H34_PREVIEW" 'case (#buy) { "a long" }; case (#sell) { "a short" }'
src_has   "§6au: ...reporting min(borrow room, clamp room) as the capacity"                 "$H34_PREVIEW" 'if (room < maxSizeBase) { maxSizeBase := room };'
src_has   "§6au: ...and a debt-free POOL no longer skips the gate (its first entry IS the borrow)" "$H34_CLAMP" 'if (h.debtUsd == 0 and Option.isNull(poolIdOf)) {'
src_has   "§6au: getApiDoc says leverage is borrowed at the fill"                           "$H06_MAIN" 'LEVERAGE IS BORROWED AT THE FILL, never at placement'
src_has   "§6au: test_initial_margin §G1 pins zero debt for a staged entry"                 "$(uncommented tests/test_initial_margin.sh)" 'ok "G1: STAGED entry → pool debt exactly 0 (no placement-time borrow)"'
src_has   "§6au: ...§G2 pins the fill's exact borrow"                                       "$(uncommented tests/test_initial_margin.sh)" 'the fill must borrow exactly its own shortfall'
src_has   "§6au: ...§G3 pins the dry-vault fail-closed with one notice"                     "$(uncommented tests/test_initial_margin.sh)" 'G3: exactly ONE notice, naming the vault'

# ── §6av 1788641149: the book-walking PROBES score a margin pool by its FUNDABLE balance ─
# H-34 made a pool borrow its slice AT THE FILL, so a leveraged resting entry
# with no cash behind it fills whenever the vault can lend — but the
# simulators (walkFillable → the FOK gate, the post-only probe, quoteSwap,
# getTakeableDepth, the cross-swap gate; the engine's FOK pre-check
# simulateAvailableFill) scored a maker by available balance alone and
# counted such an entry as ZERO depth: a FOK sell against it was killed
# "only 0 was takeable", previews under-reported by the pool's leveraged
# size. They now score a pool by its FUNDABLE balance = available + the
# vault's lendable room for an exposure-increasing slice, on the hook's own
# freshness gates — READ-ONLY: the engine's fundForFill stays the only
# borrower. Live: test_fok_market.sh §12 (RED 5 ✗ on main 1f3fe25's build →
# GREEN); the walk-budget pins (test_walk_scan_budget.sh §3) hold because a
# pool's room is snapshotted once per walk. Since 1788652744 the score is a
# per-walk SCORER (poolFundableScorer / MatchingEngine.FundableScorer, §6aw
# below) rather than one number per (owner, token); these pins follow it.
H41_FUNDABLE=$(mo_func src/backend/main.mo "func poolFundableScorer(" | mo_code)
[ -n "$H41_FUNDABLE" ] || _fail "§6av: could not extract poolFundableScorer()"
src_has   "§6av: a wallet scores its available balance (no pool ledger)"                    "$H41_FUNDABLE" 'let cash = getAvailable(party, token);'
src_has   "§6av: ...cash is all it can bring"                                               "$H41_FUNDABLE" 'case null { e.cash };'
src_has   "§6av: ...so does an exposure-REDUCING pool slice (exits are funded by holdings)" "$H41_FUNDABLE" 'if (not netAddsExposure(p.net, sideOf(token), fillQty)) { return e.cash };'
src_has   "§6av: ...stale marks lend nothing (F1)"                                          "$H41_FUNDABLE" 'if (not marginPriceFreshAt(baseToken, now)) { null }'
src_has   "§6av: ...nor a stale basket (H-06)"                                              "$H41_FUNDABLE" 'else if (Option.isSome(userStaleMarkAt(party, now))) { null }'
src_has   "§6av: ...else available + the vault's lendable room (initial-health room ∧ vault cap)" "$H41_FUNDABLE" 'e.cash + Nat.min(BorrowEngine.healthRoom(p.collUsd, p.debtUsd, p.ltv, p.price), p.vaultRoom)'
src_lacks "§6av: the probe never borrows"                                                   "$H41_FUNDABLE" 'BorrowEngine.borrow('
H41_WALK=$(mo_func src/backend/main.mo "func walkFillable(" | mo_code)
src_has   "§6av: walkFillable scores every maker through it (one scorer per walk)"          "$H41_WALK" 'let scorer = poolFundableScorer();'
src_lacks "§6av: ...and no longer by raw availability"                                      "$H41_WALK" 'getAvailable(owner, token)'
src_has   "§6av: the engine's ProtectionCtx carries the probe-side scorer factory (REQUIRED field)" "$H34_ENGINE" 'fundableScorer : () -> FundableScorer;'
src_has   "§6av: simulateAvailableFill scores a maker by it (one scorer per walk)"          "$H34_ENGINE" 'let scorer = ctx.fundableScorer();'
src_has   "§6av: ...asked before each slice"                                                "$H34_ENGINE" 'let makerBal = scorer.balance(o.owner, baseToken, makerTok, fillQty);'
H41_CTX_N=$(printf '%s\n' "$H06_MAIN" | grep -cE 'onTradeFees += recordTradeFees;')
H41_FUNDABLE_N=$(printf '%s\n' "$H06_MAIN" | grep -cE 'fundableScorer += poolFundableScorer;')
if [ "${H41_CTX_N:-0}" -ge 5 ] && [ "$H41_CTX_N" = "$H41_FUNDABLE_N" ]; then _ok "§6av: every ProtectionCtx literal in main.mo wires the probe ($H41_FUNDABLE_N of $H41_CTX_N)"
else _fail "§6av: $H41_FUNDABLE_N of $H41_CTX_N ProtectionCtx literals wire fundableScorer = poolFundableScorer"; fi
src_has   "§6av: test_fok_market §12 pins the leveraged pool bid as takeable depth"         "$(uncommented tests/test_fok_market.sh)" 'getTakeableDepth must count the leveraged pool bid by its FUNDABLE balance'
src_has   "§6av: ...the FOK fill against it alone"                                          "$(uncommented tests/test_fok_market.sh)" 'a FOK whose only in-cap depth is a leveraged pool bid must FILL'
src_has   "§6av: ...and the dry-vault control"                                              "$(uncommented tests/test_fok_market.sh)" 'a dry vault must kill the FOK (the probe must follow the vault)'

# ── §6aw 1788652744: the probe re-scores a pool's room per SLICE, as if settled ─
# 1788641149's room was maxBorrowable ONCE at current marks — the closed
# form a ≤ (C − R·D)/(R − ltv) valuing the borrowed quote at ITS LTV (1.0)
# — memoised at the pool's first slice and drawn down like cash. The live
# hook borrows per slice, and every settled slice turns quote into base
# worth ltv × mark (ICP 0.8), so the pool's health after slice 1 is worse
# than the closed form assumed and slice 2's borrowCheck refuses where the
# probe credited it: a FOK spanning two leveraged entries of ONE pool passed
# the gate, filled the first, had the second REFUSED (the vault notice) and
# ended PARTIALLY filled — the #48.4 shape. Now every walker carries one
# scorer with a per-pool (collateral, debt, vault room, net) ledger and
# COMMITS each credited slice: own cash out at `token`'s LTV, the received
# leg in at its own LTV (DOWN), the shortfall as debt (UP) and vault room
# used, the net base moved — then re-runs the closed form on that state
# (BorrowEngine.healthRoom, the piece maxBorrowable itself is built from).
# Still read-only; the engine's fundForFill is the only borrower. Live:
# test_fok_market.sh §13 (RED 6 ✗ on main 354cfea's build — ICP 1000→500,
# one vault notice, debt $2,482 — → GREEN); walk-budget pins within noise.
H42_COMMIT=$(printf '%s\n' "$H41_FUNDABLE" | sed -n '/commit = func(party, baseToken, token, spent, received) {/,$p')
[ -n "$H42_COMMIT" ] || _fail "§6aw: could not slice the scorer's commit"
src_has   "§6aw: the pool's own cash funds a slice first (the hook borrows only the shortfall)" "$H42_COMMIT" 'let fromCash = Nat.min(e.cash, spent);'
src_has   "§6aw: ...the received leg joins the collateral at ITS LTV, valued down"          "$H42_COMMIT" '+ Fixed.mul(Fixed.mul(received, p.otherPrice, false), p.otherLtv, false);'
src_has   "§6aw: ...the shortfall is new debt, valued up"                                   "$H42_COMMIT" 'p.debtUsd += Fixed.mul(short, p.price, true);'
src_has   "§6aw: ...and draws the vault's room"                                             "$H42_COMMIT" 'p.vaultRoom := SafeMath.subOrZero(p.vaultRoom, short);'
src_has   "§6aw: ...and moves the net base the entry/exit predicate reads"                  "$H42_COMMIT" 'p.net := switch (sideOf(token)) { case (#buy) { p.net + received }; case (#sell) { p.net - spent } };'
# 1788660963 retired the walker's #fundedPartial mode (quoteSwap and the
# cross-swap preview credited a maker a PART the engine's cancel never
# delivers): one all-or-nothing arm, one commit per taker side.
H42_WALK_COMMITS=$(printf '%s\n' "$H41_WALK" | grep -c 'scorer.commit(o.owner, baseToken, ')
if [ "${H42_WALK_COMMITS:-0}" -eq 2 ]; then _ok "§6aw: walkFillable commits every credited slice (one all-or-nothing arm × both taker sides: $H42_WALK_COMMITS)"
else _fail "§6aw: walkFillable commits $H42_WALK_COMMITS slices (need 2: the single all-or-nothing arm × taker buy/sell) — an uncommitted slice re-credits the pool's room to its next entry, a third arm is a retired mode creeping back"; fi
src_lacks "§6aw: ...the walker has ONE maker-crediting mode (1788660963: #fundedPartial retired — no engine path fills a part the maker cannot fund)" "$H41_WALK" 'fundedPartial'
src_lacks "§6aw: ...quoteSwap walks it too (no per-consumer mode switch)"                   "$H06_MAIN" 'perMaker'
src_has   "§6aw: simulateAvailableFill commits its credited slice too"                      "$H34_ENGINE" 'scorer.commit(o.owner, baseToken, makerTok, makerNeeds, makerGets);'
H42_BORROW=$(mo_code < src/backend/lib/BorrowEngine.mo)
src_has   "§6aw: maxBorrowable is composed of the same two halves the walker re-runs (one closed form)" "$H42_BORROW" 'case (?r) { Nat.min(healthRoom(r.collUsd, r.debtUsd, r.ltv, r.price), r.vaultRoom) };'
src_has   "§6aw: test_fok_market §13 pins all-or-nothing depth at the first bid alone"      "$(uncommented tests/test_fok_market.sh)" 'getTakeableDepth must re-score the pool'"'"'s room per slice: first bid only'
src_has   "§6aw: ...the spanning FOK kills"                                                 "$(uncommented tests/test_fok_market.sh)" 'a FOK spanning two entries the pool cannot fund in sequence must KILL, never partial-fill (#48.4)'
src_has   "§6aw: ...and one sized to the settled room fills (first-slice-only scoring would kill it)" "$(uncommented tests/test_fok_market.sh)" 'first-slice-only scoring would kill it'

# ── §6ax 1788661917: every maker-BUY gate rounds like the settlement debit ──
# A maker-buy slice settles at tradeCost = ⌊qty × price⌋ + fee(⌊…⌋), and the
# seller is credited on the SAME floored cost (conservation). The market
# variant's early makerNeeds pre-gate and the FOK pre-check
# (simulateAvailableFill) CEILED that cost — one quote unit above their own
# debit — so a bid funded to the unit was refused on the cross-swap legs
# while the release path (executeLimitOrderProtected) filled it whole. The
# TAKER's needs stay ceil: a spend cap the shrink provably keeps inside.
src_has   "§6ax: the market variant's maker-buy pre-gate FLOORS the cost (the settlement's tradeCost)" "$H34_ENGINE" 'case (#sell) { let b = Fixed.mul(fillQty, best.price, false); b + ctx.quoteFee(best.owner, b, #makerDebit) };'
src_lacks "§6ax: ...never ceils it (a maker funded to the unit was cancelled for a debit that left it at 0)" "$H34_ENGINE" 'case (#sell) { let b = Fixed.mul(fillQty, best.price, true); b + ctx.quoteFee(best.owner, b, #makerDebit) };'
src_has   "§6ax: the FOK pre-check floors the maker-buy's spend the same way"                   "$H34_ENGINE" 'case (#sell) { let b = Fixed.mul(fillQty, o.price, false); (b + ctx.quoteFee(o.owner, b, #makerDebit), fillQty) };'
src_lacks "§6ax: ...and no longer ceils it"                                                     "$H34_ENGINE" 'Fixed.mul(fillQty, o.price, true); (b + ctx.quoteFee(o.owner, b, #makerDebit), fillQty)'
src_has   "§6ax: the TAKER's budget probe stays ceil (a spend cap, not a settlement mirror)"     "$H34_ENGINE" 'case (#buy) { let b = Fixed.mul(fillQty, best.price, true); b + ctx.quoteFee(taker, b, #takerDebit) };'
src_has   "§6ax: ...as does the limit variant's"                                                "$H34_ENGINE" 'let needs = do { let c = Fixed.mul(fillQty, best.price, true); c + ctx.quoteFee(owner, c, feeRole) };'
src_has   "§6ax: the settlement debits the floored cost + fee"                                  "$H34_ENGINE" 'let buyerOk = Accounts.subtractBalance(accounts, buyer, Types.QUOTE_TOKEN, tradeCost + buyerFee);'
src_has   "§6ax: ...on a tradeCost that floors"                                                 "$H34_ENGINE" 'let tradeCost = Fixed.mul(fillQty, tradePrice, false);'
src_has   "§6ax: the walker's maker-buy gate floors too (one rounding, every gate)"             "$H41_WALK" 'let cost = Fixed.mul(take, o.price, false);'
src_has   "§6ax: test_cross_swap_atomic §4 pins the exact-funded bid taken whole by the sell leg" "$(uncommented tests/test_cross_swap_atomic.sh)" 'a bid funded to ⌊cost⌋ + fee must be TAKEN by the cross-swap'"'"'s sell leg'
src_has   "§6ax: ...with residue 0"                                                              "$(uncommented tests/test_cross_swap_atomic.sh)" 'the settlement must debit ⌊cost⌋ + fee exactly (residue 0)'
src_has   "§6ax: ...and one unit short a clean kill"                                            "$(uncommented tests/test_cross_swap_atomic.sh)" 'a bid one unit short of ⌊cost⌋ + fee is no depth — the FOK must kill'

# ── §6ay 1788665638: the LOCAL deploy path tops the sidecars up to a cycle floor BEFORE `icp deploy`; an IC0207 reject names the cure ──
# `icp deploy` on the local replica endows the arb and the Bridge once, at
# create time, and cold_start's phase-2.5 top-up feeds the backend alone —
# so every long-lived seat venue drifted into `Failed to install canister
# 'arb' … is out of cycles … IC0207` at the in-place update (seat-3,
# 2026-09-06, a 12-day replica; this seat several times the same week) while
# `canister status` still read hundreds of B, and nothing on the path said
# what to run. `deploy.sh local` is `exec cold_start.sh [--no-seed]` on both
# branches (§6av), so the ONE `icp deploy` the local path runs is
# cold_start's: mdx_local_cycle_floor (lib/targets.sh) runs right before it —
# reads each balance in MDX_LOCAL_CYCLE_FLOOR_CANISTERS (`arb bridge`), tops
# any below MDX_LOCAL_CYCLE_FLOOR (5t) up through scripts/top_up_cycles.sh,
# prints both lines (plus idle burn/day) as the deploy diagnostics, and never
# fails (an unreadable balance warns by NAME and continues). LOCAL ONLY by
# construction: no `-e` anywhere in the helpers, anonymous pays, deploy.sh
# never calls it (its remote branches keep scripts/topup.sh). And the deploy
# output now lands in MDX_COLD_DEPLOY_LOG so the failure arm can read an
# `out of cycles`/IC0207 reject back and name the frozen canister + the
# one-line cure. Pinned in source, then driven offline: the REAL helpers
# (targets.sh sourced from a scratch copy) under a recording `icp` stub and a
# recording top_up_cycles.sh stub — low balance → top-up called with the
# right canister/amount/identity; high → not called; status failure / no
# Cycles line → warn by name, no top-up; top-up failure → warn names the
# by-hand command, exit 0; the knobs honoured — plus the REAL cold_start
# deploy block under a stub whose `deploy` rejects IC0207. Two negative
# controls strip each fix (the below-floor branch; the reject detector) and
# must lose exactly the behaviour they pin.
TGT_CF_RAW="$(cat scripts/lib/targets.sh)"
TGT_CF="$(uncommented scripts/lib/targets.sh)"
src_has "§6ay: targets.sh defines the floor helper"                              "$TGT_CF" 'mdx_local_cycle_floor() {'
src_has "§6ay: ...the status reader"                                             "$TGT_CF" 'mdx_canister_cycles() {'
src_has "§6ay: ...the amount parser, marked pure on its definition line (§6ap)"  "$TGT_CF_RAW" 'mdx_cycles_to_int() {  # pure:'
src_has "§6ay: ...and the formatter, marked pure"                                "$TGT_CF_RAW" 'mdx_fmt_cycles() {  # pure:'
src_has "§6ay: the floor knob defaults to 5t"                                    "$TGT_CF" 'floor="${MDX_LOCAL_CYCLE_FLOOR:-5t}"'
src_has "§6ay: the canister list defaults to arb + bridge"                       "$TGT_CF" 'for c in ${MDX_LOCAL_CYCLE_FLOOR_CANISTERS:-arb bridge}; do'
src_has "§6ay: the status capture carries || true inside, --identity pinned"     "$TGT_CF" 'out="$(icp canister status "$1" --identity anonymous 2>/dev/null || true)"'
src_has "§6ay: the Cycles line is parsed with underscores stripped"              "$TGT_CF" "awk '/^ *Cycles:/ { gsub(/_/, \"\", \$2); print \$2; exit }'"
src_has "§6ay: the reading is captured with || true and gated by name"           "$TGT_CF" 'reading="$(mdx_canister_cycles "$c" || true)"'
src_has "§6ay: an unreadable balance warns by name and continues"                "$TGT_CF" "printed no Cycles line — \${c}_cycles='') — floor NOT applied to \$c"
src_has "§6ay: the top-up goes through the repo helper — canister, floor, anonymous" "$TGT_CF" 'bash "$scripts_dir/top_up_cycles.sh" --canister "$c" --amount "$floor" --identity anonymous'
src_has "§6ay: a failed top-up names the by-hand command"                        "$TGT_CF" 'by hand: bash scripts/top_up_cycles.sh --canister $c --amount $floor --identity anonymous'
CF_FN="$(printf '%s\n' "$TGT_CF" | sed -n '/^mdx_cycles_to_int() {/,/^}/p; /^mdx_canister_cycles() {/,/^}/p; /^mdx_local_cycle_floor() {/,/^}/p')"
if [ "$(printf '%s\n' "$CF_FN" | grep -c '^}')" -eq 3 ]; then _ok "§6ay: the three helper bodies extract (3 closing braces)"
else _fail "§6ay: could not extract the three helper bodies from targets.sh (got $(printf '%s\n' "$CF_FN" | grep -c '^}') closing braces) — the LOCAL-ONLY pins below would test nothing"; fi
src_lacks "§6ay: LOCAL ONLY — no environment flag anywhere in the floor helpers"  "$CF_FN" ' -e '
src_lacks "§6ay: ...nor --environment"                                           "$CF_FN" '--environment'
src_lacks "§6ay: the helpers never die (a floor, not a gate)"                    "$CF_FN" 'mdx_die'
grep_scan CF_EXITS "$CF_FN" '(^[[:space:]]*|[;{]|&&|\|\||then |else |do )exit( +[0-9"$]|$)'   # a shell exit STATEMENT; awk's `; exit }` and "(exit $rc)" in a message are not
if [ -z "$CF_EXITS" ]; then _ok "§6ay: the helpers never exit the caller (warn-and-continue only)"
else _fail "§6ay: a shell exit inside the floor helpers — a floor must never end the deploy: $(printf '%s' "$CF_EXITS" | tr '\n' ' ' | head -c 200)"; fi
src_has   "§6ay: the floor helper returns 0 unconditionally at its end"          "$CF_FN" '  return 0
}'
grep_scan CF_ICP_BARE "$CF_FN" '(^|[^a-z_])icp '
grep_filter -F CF_ICP_BARE '--identity anonymous'
if [ -z "$CF_ICP_BARE" ]; then _ok "§6ay: every icp call in the helpers carries --identity anonymous (process-safety §5)"
else _fail "§6ay: icp call without --identity anonymous in the floor helpers: $(printf '%s' "$CF_ICP_BARE" | tr '\n' ' ' | head -c 200)"; fi
COLD_CF="$(uncommented scripts/cold_start.sh)"
src_has "§6ay: cold_start applies the floor (bare call — it never fails, nothing to gate)" "$COLD_CF" '  mdx_local_cycle_floor'
CF_CALL_LN="$(printf '%s\n' "$COLD_CF" | grep -n '^  mdx_local_cycle_floor$' | head -1 | cut -d: -f1)"
CF_GENDID_LN="$(printf '%s\n' "$COLD_CF" | grep -n 'gen-did.sh' | head -1 | cut -d: -f1)"
CF_DEPLOY_LN="$(printf '%s\n' "$COLD_CF" | grep -n 'icp deploy --identity' | head -1 | cut -d: -f1)"
CF_DODEP_LN="$(printf '%s\n' "$COLD_CF" | grep -n '^if \$DO_DEPLOY; then$' | head -1 | cut -d: -f1)"
if [ -n "$CF_CALL_LN" ] && [ -n "$CF_GENDID_LN" ] && [ -n "$CF_DEPLOY_LN" ] && [ -n "$CF_DODEP_LN" ] && [ "$CF_DODEP_LN" -lt "$CF_GENDID_LN" ] && [ "$CF_GENDID_LN" -lt "$CF_CALL_LN" ] && [ "$CF_CALL_LN" -lt "$CF_DEPLOY_LN" ]; then
  _ok "§6ay: the floor runs inside the deploy phase, after gen-did and BEFORE icp deploy (lines $CF_DODEP_LN < $CF_GENDID_LN < $CF_CALL_LN < $CF_DEPLOY_LN)"
else _fail "§6ay: the floor call (${CF_CALL_LN:-none}) is not between gen-did (${CF_GENDID_LN:-none}) and icp deploy (${CF_DEPLOY_LN:-none}) inside the deploy phase (${CF_DODEP_LN:-none}) — it would top up after the install already failed"; fi
src_has "§6ay: the deploy output is written to the runfiles log (readable by the failure arm)" "$COLD_CF" 'if icp deploy --identity anonymous ${MDX_DEPLOY_BREAKING:+--yes} > "$MDX_COLD_DEPLOY_LOG" 2>&1; then'
# 1788731608: the one deploy that installs an apiVersion MAJOR bump is not a
# Candid subtype of the running canister, and icp refuses it without --yes;
# MDX_DEPLOY_BREAKING forwards that, by hand, for THAT deploy — loudly, and
# no script may set it (the declaration is the committed major, the ratchet's
# hatch; this is only its transport to icp).
src_has "§6ay/6.0.0: the breaking-deploy bypass warns by name" "$COLD_CF" 'warn "MDX_DEPLOY_BREAKING set: bypassing icp'"'"'s Candid compatibility check'
if grep -rn --include='*.sh' -E '(^|[^A-Za-z_])MDX_DEPLOY_BREAKING=' scripts/ tests/ | grep -v test_deploy_hygiene >/dev/null; then _fail "§6ay/6.0.0: a script SETS MDX_DEPLOY_BREAKING — the bypass is an operator's hand-set knob for one deploy, never automated"
else _ok "§6ay/6.0.0: no script sets MDX_DEPLOY_BREAKING (hand-set, one deploy)"; fi
src_has "§6ay: runfiles.sh defines that log under .run/"                         "$(uncommented scripts/lib/runfiles.sh)" 'MDX_COLD_DEPLOY_LOG="${MDX_COLD_DEPLOY_LOG:-$MDX_RUN_DIR/cold-start-deploy.log}"'
src_has "§6ay: the failure arm detects the cycles reject"                        "$COLD_CF" "if grep -qE 'out of cycles|IC0207' \"\$MDX_COLD_DEPLOY_LOG\"; then"
src_has "§6ay: ...reads the frozen canister's name with || true inside"          "$COLD_CF" "FROZEN=\"\$(grep -oE \"canister '[a-z0-9-]+'\" \"\$MDX_COLD_DEPLOY_LOG\" | head -1 | sed \"s/canister '//; s/'//\" || true)\""
src_has "§6ay: ...and names the cure by canister, floor and identity"            "$COLD_CF" 'Cure: bash scripts/top_up_cycles.sh --canister ${FROZEN:-<name>} --amount ${MDX_LOCAL_CYCLE_FLOOR:-5t} --identity anonymous'
src_has "§6ay: ...pointing at the knobs"                                         "$COLD_CF" 'raise it, or add the canister to MDX_LOCAL_CYCLE_FLOOR_CANISTERS'
src_lacks "§6ay: the pre-fix deploy pipeline (no readable output) is gone"       "$COLD_CF" 'icp deploy --identity anonymous 2>&1 | tail -20'
DEPLOY_CF="$(uncommented scripts/deploy.sh)"
src_lacks "§6ay: deploy.sh never calls the floor helper (so its remote branches cannot)"    "$DEPLOY_CF" 'mdx_local_cycle_floor'
src_lacks "§6ay: deploy.sh never calls top_up_cycles.sh either (the remote feeding stays scripts/topup.sh)" "$DEPLOY_CF" 'top_up_cycles.sh'
src_has   "§6ay: deploy.sh's local section documents where the floor lives"                "$(cat scripts/deploy.sh)" 'floor first (mdx_local_cycle_floor, lib/targets.sh — task 1788665638)'
src_has   "§6ay: deploy.sh local's seed branch is still the cold_start site (the floor rides it)"   "$DEPLOY_CF" 'exec bash scripts/cold_start.sh ${PASS[@]+"${PASS[@]}"}'
src_has   "§6ay: deploy.sh local's update branch is still the cold_start site"             "$DEPLOY_CF" 'exec bash scripts/cold_start.sh --no-seed ${PASS[@]+"${PASS[@]}"}'
# ── behavioural: the REAL helpers under recording stubs ──
CF_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cap6ay.XXXXXX")"
mkdir -p "$CF_TMP/bin" "$CF_TMP/scripts" "$CF_TMP/run"
cat > "$CF_TMP/bin/icp" <<'CFEOF'
#!/bin/bash
# recording stub. status moods (CF_STATUS): good (a real status report; the
# Cycles value is CF_ARB / CF_BRIDGE, and after a recorded top-up CF_AFTER),
# bad (the CLI fails), miss (a report with no Cycles line). deploy moods
# (CF_DEPLOY): ok, ic0207 (the seat-3 reject text), other.
echo "$*" >> "$CF_LOG"
case "$1 $2" in
  "canister status")
    c="$3"
    case "${CF_STATUS:-good}" in
      bad)  echo "Error: transport failure: connection reset by peer (CF STUB DIAGNOSTIC)" >&2; exit 7 ;;
      miss) printf 'Canister Id: aaaaa-aa\nCanister Name: %s\nCanister Status Report:\n  Status: Running\n' "$c" ;;
      *)
        case "$c" in arb) v="${CF_ARB:-1_399_205_717_302}" ;; bridge) v="${CF_BRIDGE:-1_497_749_748_420}" ;; *) v="7_000_000_000_000" ;; esac
        if grep -q "top_up_cycles.sh --canister $c " "$CF_LOG" 2>/dev/null; then v="${CF_AFTER:-6_399_205_717_302}"; fi
        printf 'Canister Id: aaaaa-aa\nCanister Name: %s\nCanister Status Report:\n  Status: Running\n  Controllers: 2vxsx-fae\n  Freezing threshold: 2_592_000\n  Reserved cycles limit: 5_000_000_000_000\n  Memory size: 11_734_018\n  Cycles: %s\n  Reserved cycles: 0\n  Idle cycles burned per day: 1_163_781_171\n' "$c" "$v" ;;
    esac ;;
  "deploy --identity")
    case "${CF_DEPLOY:-ok}" in
      ic0207) echo "Deploying backend..."; echo "Failed to install canister 'arb' (46el7-ql777-77775-aaada-cai): The replica returned a rejection error: reject code CanisterError, reject message Canister 46el7-ql777-77775-aaada-cai is out of cycles: please top up the canister with at least 138_775_852_648 additional cycles, error code IC0207"; exit 1 ;;
      other)  echo "Error: Candid compatibility check failed for canister backend (CF STUB)"; exit 1 ;;
      *)      echo "Deployed backend, bridge, arb, frontend (CF STUB)" ;;
    esac ;;
  *) echo "(variant { ok })" ;;
esac
CFEOF
cat > "$CF_TMP/scripts/top_up_cycles.sh" <<'CFEOF'
#!/bin/bash
echo "top_up_cycles.sh $*" >> "$CF_LOG"
if [ "${CF_TOPUP_RC:-0}" -ne 0 ]; then echo "  ✗ top-up failed (CF STUB)" >&2; exit "$CF_TOPUP_RC"; fi
echo "Top-up complete."
CFEOF
chmod +x "$CF_TMP/bin/icp" "$CF_TMP/scripts/top_up_cycles.sh"
cp scripts/lib/targets.sh "$CF_TMP/targets_keep.sh"
# negative control (1): the below-floor branch never fires (the comparison forced true) — the pre-fix world, where nothing topped the sidecars up
sed 's/\[ "\$cyc" -ge "\$floor_int" \]/true/' scripts/lib/targets.sh > "$CF_TMP/targets_strip.sh"
cat > "$CF_TMP/probe_floor.sh" <<'CFEOF'
#!/bin/bash
# $1 = keep|strip (the targets.sh copy to source)
set -euo pipefail
. "$CF_TMP/targets_$1.sh"
export MDX_SCRIPTS_DIR="$CF_TMP/scripts"
mdx_local_cycle_floor
echo "CF-RC=$?"
echo CF-REACHED
CFEOF
cf_run() {  # cf_run <keep|strip> → CF_OUT, CF_RC, CF_LOG (the stubs' argv log); moods via the CF_* env on the call
  : > "$CF_TMP/calls.log"
  CF_OUT="$(CF_TMP="$CF_TMP" CF_LOG="$CF_TMP/calls.log" PATH="$CF_TMP/bin:$PATH" bash "$CF_TMP/probe_floor.sh" "$1" 2>&1)" && CF_RC=0 || CF_RC=$?
}
cf_has()    { printf '%s\n' "$CF_OUT" | grep -qF -- "$1"; }
cf_called() { grep -qF -- "$1" "$CF_TMP/calls.log"; }
cf_show()   { printf 'exit %s; calls=%s; out=%s' "$CF_RC" "$(tr '\n' ';' < "$CF_TMP/calls.log" | head -c 200)" "$(printf '%s' "$CF_OUT" | tr '\n' ' ' | head -c 400)"; }
if grep -qF 'mdx_local_cycle_floor() {' "$CF_TMP/targets_keep.sh" && ! grep -qF '[ "$cyc" -ge "$floor_int" ]' "$CF_TMP/targets_strip.sh" && grep -qF '[ "$cyc" -ge "$floor_int" ]' "$CF_TMP/targets_keep.sh"; then
  # (1) both sidecars below the floor: two top-ups, right canister / amount / identity, both diagnostics lines, exit 0
  cf_run keep
  if [ "$CF_RC" -eq 0 ] && cf_called 'top_up_cycles.sh --canister arb --amount 5t --identity anonymous' && cf_called 'top_up_cycles.sh --canister bridge --amount 5t --identity anonymous' \
     && cf_has 'arb cycles: 1_399_205_717_302 (1.40T), idle burn/day 1_163_781_171 (0.00T) — BELOW the floor 5t (MDX_LOCAL_CYCLE_FLOOR); topping up 5t via scripts/top_up_cycles.sh' \
     && cf_has 'bridge cycles: 1_497_749_748_420 (1.50T), idle burn/day' && cf_has 'arb cycles: 6_399_205_717_302 (6.40T) after topping up 5t (was 1_399_205_717_302 (1.40T))' \
     && cf_has 'bridge cycles: 6_399_205_717_302 (6.40T) after topping up 5t' && cf_has 'CF-RC=0' && cf_has 'CF-REACHED'; then
    _ok "§6ay floor (both below 5t): top_up_cycles.sh called for arb AND bridge with --amount 5t --identity anonymous; before/after lines printed; exit 0"
  else _fail "§6ay floor (both below 5t): $(cf_show)"; fi
  cf_called 'canister status arb --identity anonymous' && cf_called 'canister status bridge --identity anonymous' \
    && _ok "§6ay floor: the balances are read with 'icp canister status <c> --identity anonymous' (no -e: the ambient local network)" \
    || _fail "§6ay floor: the status reads did not carry the expected argv — $(cf_show)"
  # (2) both at/above the floor: nothing topped up, both lines still printed (the diagnostics are unconditional)
  CF_ARB=9_000_000_000_000 CF_BRIDGE=5_000_000_000_000 cf_run keep
  if [ "$CF_RC" -eq 0 ] && ! cf_called 'top_up_cycles.sh' && cf_has 'arb cycles: 9_000_000_000_000 (9.00T), idle burn/day 1_163_781_171 (0.00T) — at or above the floor 5t (MDX_LOCAL_CYCLE_FLOOR)' \
     && cf_has 'bridge cycles: 5_000_000_000_000 (5.00T), idle burn/day 1_163_781_171 (0.00T) — at or above the floor 5t' && cf_has 'CF-REACHED'; then
    _ok "§6ay floor (9T / exactly 5T): no top-up; both diagnostics lines printed (5T counts as AT the floor); exit 0"
  else _fail "§6ay floor (at/above): $(cf_show)"; fi
  # (3) the CLI fails / (4) no Cycles line: warn by NAME, no top-up, continue, exit 0
  for mood in bad miss; do
    CF_STATUS=$mood cf_run keep
    if [ "$CF_RC" -eq 0 ] && ! cf_called 'top_up_cycles.sh' && cf_has "arb cycles: UNREADABLE (icp canister status arb printed no Cycles line — arb_cycles='') — floor NOT applied to arb; if the deploy fails IC0207: bash scripts/top_up_cycles.sh --canister arb --amount 5t --identity anonymous" \
       && cf_has "bridge_cycles=''" && cf_has 'CF-RC=0' && cf_has 'CF-REACHED'; then
      _ok "§6ay floor under a $mood status read: warns by name (arb_cycles='' / bridge_cycles='') with the by-hand cure, no top-up, exit 0"
    else _fail "§6ay floor under a $mood status read: $(cf_show)"; fi
  done
  # (5) the top-up itself fails: warn names the by-hand command; the deploy still proceeds (exit 0)
  CF_TOPUP_RC=3 cf_run keep
  if [ "$CF_RC" -eq 0 ] && cf_called 'top_up_cycles.sh --canister arb --amount 5t' && cf_has 'arb top-up FAILED (exit 3):' && cf_has 'top-up failed (CF STUB)' \
     && cf_has 'by hand: bash scripts/top_up_cycles.sh --canister arb --amount 5t --identity anonymous' && cf_has 'CF-REACHED'; then
    _ok "§6ay floor with a failing top_up_cycles.sh: warns with its exit code, its text and the by-hand command; continues; exit 0"
  else _fail "§6ay floor with a failing top-up: $(cf_show)"; fi
  # (6) the knobs: a 1t floor leaves 1.4T alone; the canister list narrows the reads; a garbage floor skips loudly
  MDX_LOCAL_CYCLE_FLOOR=1t cf_run keep
  if [ "$CF_RC" -eq 0 ] && ! cf_called 'top_up_cycles.sh' && cf_has 'at or above the floor 1t (MDX_LOCAL_CYCLE_FLOOR)'; then _ok "§6ay floor knob: MDX_LOCAL_CYCLE_FLOOR=1t is honoured (1.4T reads as at/above, no top-up)"
  else _fail "§6ay floor knob (1t): $(cf_show)"; fi
  MDX_LOCAL_CYCLE_FLOOR_CANISTERS=arb cf_run keep
  if [ "$CF_RC" -eq 0 ] && cf_called 'canister status arb' && ! cf_called 'canister status bridge' && ! cf_called '--canister bridge'; then _ok "§6ay canister-list knob: MDX_LOCAL_CYCLE_FLOOR_CANISTERS=arb reads and tops up only the arb"
  else _fail "§6ay canister-list knob: $(cf_show)"; fi
  MDX_LOCAL_CYCLE_FLOOR=five cf_run keep
  if [ "$CF_RC" -eq 0 ] && ! cf_called 'canister status' && cf_has "MDX_LOCAL_CYCLE_FLOOR='five' is not a cycles amount" && cf_has 'local cycle floor SKIPPED' && cf_has 'CF-REACHED'; then _ok "§6ay floor knob: a non-amount floor is named and the floor is skipped, exit 0 (never a silent abort)"
  else _fail "§6ay floor knob (garbage): $(cf_show)"; fi
  # negative control (1): with the below-floor branch stripped the low case records NO top-up — the probe sees the missing fix
  cf_run strip
  if [ "$CF_RC" -eq 0 ] && ! cf_called 'top_up_cycles.sh' && cf_has 'arb cycles: 1_399_205_717_302 (1.40T)'; then _ok "§6ay negative control: with the below-floor branch stripped, 1.4T is reported but NOTHING is topped up — the (1) assertion above sees the bug"
  else _fail "§6ay negative control (branch stripped) did not lose the top-up: $(cf_show)"; fi
else _fail "§6ay: could not stage the targets.sh copies for the floor probe (helper or comparison line missing) — the probe would test nothing"; fi
# ── the REAL cold_start deploy block: an IC0207 reject names the frozen canister and the cure ──
awk '/^  log "icp deploy"$/{f=1} f{print} f&&/^  ok "backend \+ frontend deployed"$/{f=0}' scripts/cold_start.sh > "$CF_TMP/deploy_block.sh"
# negative control (2): the reject detector never matches — the pre-fix "deploy failed" alone
sed "s/out of cycles|IC0207/CF-NEVER-MATCHES/" "$CF_TMP/deploy_block.sh" > "$CF_TMP/deploy_block_strip.sh"
cat > "$CF_TMP/probe_deploy.sh" <<'CFEOF'
#!/bin/bash
# $1 = the extracted block to run
set -euo pipefail
log()  { printf 'log %s\n' "$1"; }
ok()   { printf 'ok %s\n' "$1"; }
err()  { printf 'err %s\n' "$1" >&2; }
MDX_COLD_DEPLOY_LOG="$CF_TMP/run/deploy.log"
eval "$(cat "$1")"
echo CF-DEPLOY-REACHED
CFEOF
cfd_run() { : > "$CF_TMP/calls.log"; CF_OUT="$(CF_TMP="$CF_TMP" CF_LOG="$CF_TMP/calls.log" PATH="$CF_TMP/bin:$PATH" bash "$CF_TMP/probe_deploy.sh" "$1" 2>&1)" && CF_RC=0 || CF_RC=$?; }
if grep -qF 'if icp deploy --identity anonymous ${MDX_DEPLOY_BREAKING:+--yes} > "$MDX_COLD_DEPLOY_LOG" 2>&1; then' "$CF_TMP/deploy_block.sh" && grep -qF 'ok "backend + frontend deployed"' "$CF_TMP/deploy_block.sh" && grep -qF 'CF-NEVER-MATCHES' "$CF_TMP/deploy_block_strip.sh"; then
  CF_DEPLOY=ic0207 cfd_run "$CF_TMP/deploy_block.sh"
  if [ "$CF_RC" -eq 1 ] && cf_has "err deploy failed — arb is out of cycles (IC0207). Cure: bash scripts/top_up_cycles.sh --canister arb --amount 5t --identity anonymous  — then re-run." \
     && cf_has "The pre-deploy floor covers 'arb bridge' at 5t (MDX_LOCAL_CYCLE_FLOOR)" && cf_has 'error code IC0207' && ! cf_has 'CF-DEPLOY-REACHED'; then
    _ok "§6ay cold_start deploy block under an IC0207 reject: exit 1, the replica text is shown AND the arm names the frozen canister (arb) and the cure with canister/floor/identity"
  else _fail "§6ay cold_start deploy block (IC0207): $(cf_show)"; fi
  MDX_LOCAL_CYCLE_FLOOR=8t CF_DEPLOY=ic0207 cfd_run "$CF_TMP/deploy_block.sh"
  if [ "$CF_RC" -eq 1 ] && cf_has '--canister arb --amount 8t --identity anonymous'; then _ok "§6ay cold_start deploy block: the cure quotes the CURRENT floor knob (8t)"
  else _fail "§6ay cold_start deploy block (knob in cure): $(cf_show)"; fi
  CF_DEPLOY=other cfd_run "$CF_TMP/deploy_block.sh"
  if [ "$CF_RC" -eq 1 ] && cf_has 'err deploy failed' && ! cf_has 'top_up_cycles.sh' && cf_has 'Candid compatibility check failed' && ! cf_has 'CF-DEPLOY-REACHED'; then
    _ok "§6ay cold_start deploy block under a NON-cycles failure: plain 'deploy failed' with the replica text, no cycles cure (never a misdiagnosis), exit 1"
  else _fail "§6ay cold_start deploy block (other failure): $(cf_show)"; fi
  CF_DEPLOY=ok cfd_run "$CF_TMP/deploy_block.sh"
  if [ "$CF_RC" -eq 0 ] && cf_has 'ok backend + frontend deployed' && cf_has 'Deployed backend, bridge, arb, frontend (CF STUB)' && cf_has 'CF-DEPLOY-REACHED'; then
    _ok "§6ay cold_start deploy block on success: the deploy output is echoed (tail) and the ok line follows, exit 0"
  else _fail "§6ay cold_start deploy block (success): $(cf_show)"; fi
  CF_DEPLOY=ic0207 cfd_run "$CF_TMP/deploy_block_strip.sh"
  if [ "$CF_RC" -eq 1 ] && cf_has 'err deploy failed' && ! cf_has 'top_up_cycles.sh' && ! cf_has 'Cure:'; then _ok "§6ay negative control: with the reject detector stripped an IC0207 reject gets the bare 'deploy failed' and no cure — the probe sees the pre-fix text"
  else _fail "§6ay negative control (detector stripped) still named the cure: $(cf_show)"; fi
else _fail "§6ay: could not extract cold_start's deploy block (log \"icp deploy\" … ok \"backend + frontend deployed\") — the reject probe would test nothing"; fi
rm -rf "$CF_TMP"

# ── §6az 1788516198 → 1788731608: the PendingMatch / protection-window machinery is RETIRED and, at apiVersion 6.0.0, its Candid surfaces are REMOVED; its stable fields are fossils ──
# Operator decision 2026-09-06 (option 2, after 1788515326 recorded the
# dormancy chain): delete the dead machinery, keep the public interface
# byte-identical within apiVersion 5.x as inert stubs. The 6.0.0 hatch (task
# 1788731608) then took the stubs out. Pinned three ways — (1) the machinery
# is GONE from main.mo and the engine (the deferred-fill arm, the
# settlement-window ctx trio, the finaliser's pending scan, the AMM-quote
# window write, the 30 s constants); (2) the SURFACES are gone everywhere
# they were declared — main.mo, the engine's MatchResult, AMM.Pool, the
# Candid, the hand-written IDL, the inspect variant — and getApiDoc tells
# bots so; (3) the stable fields the machinery wrote stayed DECLARED through
# 6.0.0 — EOP refuses a stable-field drop or retype on a plain upgrade
# (IC0503) — as commented fossils cleared only by resetExchange, with
# Types.PendingMatch surviving ONLY as the fossil map's element type, until
# task 1788744109's one-shot migration (the sixth sweep; the NOTE above the
# actor) consumed and DROPPED all five plus AMM.Pool.protectionWindowSec —
# pinned below as the ABSENCE, with the one-shot's shape while it is ACTIVE.
# §6d/L3 pins the audit fixture's absence; candid/README.md "Major bumps so
# far" records the removal.
PMR_MAIN=$(mo_code < src/backend/main.mo)
PMR_ENGINE=$(mo_code < src/backend/lib/MatchingEngine.mo)
for FN in createPendingMatch finalisePendingMatch voidPendingMatch voidPendingMatchesForMaker settleOrVoidAmmPending matchDebits addPendingQty subPendingQty removePendingIndex; do
  src_lacks "§6az: main.mo no longer defines $FN" "$PMR_MAIN" "func $FN("
done
src_lacks "§6az: the 30 s window cap constant is gone"                                   "$PMR_MAIN"   "MAX_PROTECTION_WINDOW_NS"
src_lacks "§6az: ...and the 5 s default"                                                  "$PMR_MAIN"   "DEFAULT_PROTECTION_WINDOW_NS"
src_lacks "§6az: nothing writes the settlement-window fossil"                             "$PMR_MAIN"   "Map.add(orderSettlementWindows,"
src_lacks "§6az: nothing writes the pending-qty fossil"                                   "$PMR_MAIN"   "Map.add(pendingQtyByMaker,"
src_lacks "§6az: nothing writes the by-maker fossil"                                      "$PMR_MAIN"   "Map.add(pendingByMaker,"
src_lacks "§6az: nothing writes the pending-match fossil either (the fixture writer is gone)" "$PMR_MAIN" "Map.add(pendingMatches,"
for FIELD in "getMakerWindow :" "getMakerPending :" "onPendingFill :"; do
  src_lacks "§6az: the engine's ProtectionCtx dropped the settlement-window field '$FIELD'" "$PMR_ENGINE" "$FIELD"
done
src_lacks "§6az: the engine has no deferred-fill list left"                               "$PMR_ENGINE" "pendingList"
src_lacks "§6az: ...and never asks a maker's window"                                      "$PMR_ENGINE" "ctx.getMakerWindow("
src_lacks "§6az (6.0.0): the engine's MatchResult carries no pendingMatches field"        "$PMR_ENGINE" "pendingMatches"
src_lacks "§6az: no ctx literal in main.mo wires onPendingFill"                           "$PMR_MAIN"   "onPendingFill"
src_lacks "§6az (6.0.0): main.mo no longer defines getMyPendingMatches"                   "$PMR_MAIN"   "func getMyPendingMatches("
src_lacks "§6az (6.0.0): ...nor placeProtectedLimitOrder"                                 "$PMR_MAIN"   "func placeProtectedLimitOrder("
src_lacks "§6az (6.0.0): no result literal carries pendingMatches"                        "$PMR_MAIN"   "pendingMatches = []"
src_lacks "§6az (6.0.0): the inspect variant dropped #getMyPendingMatches"                "$(printf '%s\n' "$INSPECT_FN" | mo_code)" "#getMyPendingMatches"
src_lacks "§6az (6.0.0): ...and #placeProtectedLimitOrder"                                "$(printf '%s\n' "$INSPECT_FN" | mo_code)" "#placeProtectedLimitOrder"
PMR_SAC=$(mo_func src/backend/main.mo "func setAmmConfig(" | mo_code)
src_lacks "§6az (6.0.0): setAmmConfig takes no protectionWindowSec"                       "$PMR_SAC"    "protectionWindowSec"
src_has   "§6az: ...and is five parameters wide"                                          "$PMR_SAC"    "    levelSpacingBps : Nat,
  ) : async { #ok; #err : Text } {"
# The stored record kept protectionWindowSec as a fossil through 6.0.0 — EOP
# refused the record-field drop inside the stable `pools` map live (IC0503,
# 2026-09-07) — and the PUBLIC pool was AMM.PoolView, the projection without
# it. Task 1788744109's one-shot migration mapped every stored pool onto the
# field-less record, so the projection collapsed back into Pool: PoolView
# survives ONLY as an alias — the published Candid's record name (`type
# PoolView = record {…}`, byte-identical across the sweep) — and both queries
# hand out the stored record.
PMR_AMM=$(mo_code < src/backend/lib/AMM.mo)
src_lacks "§6az (1788744109): AMM.Pool no longer carries protectionWindowSec (swept by the sixth one-shot migration)" "$PMR_AMM" "protectionWindowSec"
src_lacks "§6az (1788744109): AMM.toView is gone (the 6.0.0 projection collapsed into Pool)"                         "$PMR_AMM" "func toView("
src_has   "§6az (1788744109): AMM.PoolView is an alias of Pool (the Candid's record name, kept)"                     "$PMR_AMM" "public type PoolView = Pool;"
for FN in getAmmPool getAmmPools; do
  src_lacks "§6az (1788744109): $FN hands out the stored Pool, not a projection" "$(mo_func src/backend/main.mo "func $FN(" | mo_code)" "AMM.toView"
done
src_has   "§6az (1788744109): getAmmPools returns the stored pools directly"              "$(mo_func src/backend/main.mo "func getAmmPools(" | mo_code)" "AMM.allPools(pools);"
src_has   "§6az: AMM.withConfig takes no window"                                          "$(mo_code < src/backend/lib/AMM.mo)" "levelSpacingBps : Nat,
  ) : Pool = {"
# The five stable fossils stayed DECLARED (EOP refuses the drop) and cleared
# by resetExchange through 6.0.0; task 1788744109's one-shot migration
# consumed and dropped them (empty / initial on every live target), so main.mo
# names none of them any more — not a declaration, not a clear, not the
# counter reset — and Types.PendingMatch / PendingMatchStatus went with the
# map (their frozen shape lives in src/backend/migration.mo until its
# retirement). getApiDoc's 6.0.0 BREAKING sentence still names the surfaces
# (a string, kept): the needles below are the declaration / clear shapes.
for DECL in "let orderSettlementWindows" "let pendingByMaker" "var nextPendingMatchId" "let pendingQtyByMaker" "let pendingMatches"; do
  src_lacks "§6az (1788744109): the swept fossil is no longer declared: $DECL" "$PMR_MAIN" "$DECL"
done
for M in orderSettlementWindows pendingByMaker pendingQtyByMaker pendingMatches; do
  src_lacks "§6az (1788744109): the wipe no longer clears the swept $M (nothing left to clear)" "$PMR_MAIN" "Map.clear($M);"
done
src_lacks "§6az (1788744109): ...nor resets the swept counter"                           "$PMR_MAIN" "nextPendingMatchId := 1;"
src_lacks "§6az (1788744109): ...and nothing sizes the swept map"                        "$PMR_MAIN" "Map.size(pendingMatches)"
src_has   "§6az (1788744109): getStagedIndexAudit.pmLive stays in the Candid as a constant 0" "$(mo_func src/backend/main.mo "func getStagedIndexAudit(" | mo_code)" "pmLive = 0;"
src_lacks "§6az (1788744109): Types.PendingMatch is gone with the swept map"             "$(mo_code < src/backend/lib/Types.mo)" "PendingMatch"
# The sweep's one-shot while ACTIVE: wired on the actor, its domain consumes
# the six, its unit fixture present. Retired (the file gone — the retirement
# task's shape): the fossils stay gone, no clause lingers, the fixture went too.
if [ -f src/backend/migration.mo ]; then
  PMR_MIG=$(mo_code < src/backend/migration.mo)
  for F in orderSettlementWindows pendingByMaker nextPendingMatchId pendingQtyByMaker pendingMatches pools; do
    src_has "§6az (1788744109): the ACTIVE one-shot's domain consumes $F" "$PMR_MIG" "$F "
  done
  src_has "§6az (1788744109): ...and maps the stored pool onto AMM.Pool"       "$PMR_MIG" "public func sweepPool(p : OldPool) : AMM.Pool"
  src_has "§6az (1788744109): main.mo wires the ACTIVE one-shot (the clause)"   "$PMR_MAIN" "(with migration = Migration.run)"
  src_has "§6az (1788744109): ...and imports it"                                "$PMR_MAIN" 'import Migration "migration";'
  if [ -f tests/Migration.test.mo ]; then _ok "§6az (1788744109): tests/Migration.test.mo pins the ACTIVE sweep"
  else _fail "§6az (1788744109): tests/Migration.test.mo must pin the sweep while migration.mo is ACTIVE"; fi
else
  _ok "§6az (1788744109): the sweep's one-shot is RETIRED (no src/backend/migration.mo); the fossils stay gone"
  src_lacks "§6az (1788744109): ...and no migration clause lingers on the actor" "$PMR_MAIN" "with migration"
  if [ -f tests/Migration.test.mo ]; then _fail "§6az (1788744109): tests/Migration.test.mo must go with the retired migration.mo"
  else _ok "§6az (1788744109): tests/Migration.test.mo retired with it"; fi
fi
src_has   "§6az (6.0.0): getApiDoc tells bots the pending surfaces are GONE"              "$PMR_MAIN"   "BREAKING at apiVersion 6.0.0: the retired protection-window surfaces are GONE"
PMR_DID=$(cat candid/backend.did)
for NEEDLE in getMyPendingMatches placeProtectedLimitOrder pendingMatches protectionWindowSec PendingMatch; do
  src_lacks "§6az (6.0.0): the Candid no longer mentions $NEEDLE" "$PMR_DID" "$NEEDLE"
done
src_has   "§6az (6.0.0): the Candid's setAmmConfig is five parameters wide"               "$(tr -d '\n' < candid/backend.did | tr -s ' ')" "levelSpacingBps: nat) -> (variant {"
PMR_JS=$(cat src/frontend/src/main.js)
src_lacks "§6az: the frontend no longer polls getMyPendingMatches"                        "$PMR_JS"     "actor.getMyPendingMatches("
src_lacks "§6az: ...and renders no pending-match rows"                                    "$PMR_JS"     "uomPendingMatches"
for NEEDLE in "getMyPendingMatches: IDL.Func" "pendingMatches:" "protectionWindowSec:" "const PendingMatch"; do
  src_lacks "§6az (6.0.0): the hand-written IDL no longer declares '$NEEDLE' (mirrors the .did)" "$PMR_JS" "$NEEDLE"
done
src_lacks "§6az: seed.sh has no pending mode"                                             "$(cat scripts/seed.sh)" "seed_pending"
src_has   "§6az: ...its staged-order fixture is the \`staged\` mode, placed through placeLimitOrder" "$(cat scripts/seed.sh)" "  staged)   seed_staged   ;;"
src_lacks "§6az: ...and no fixture places through placeProtectedLimitOrder"               "$(uncommented scripts/seed.sh)" "placeProtectedLimitOrder"
for S in scripts/seed.sh scripts/play_start.sh scripts/deploy.sh; do
  src_lacks "§6az (6.0.0): $S passes setAmmConfig five arguments (the window is gone)" "$(uncommented "$S")" "35:nat, 8:nat)"
done
for T in test_staged_settlement test_staged_cancel_refund test_zombie_free test_geptor_inflight_guard; do
  src_has "§6az: $T seeds the staged fixture" "$(cat tests/$T.sh)" "setup_mode staged"
done
src_lacks "§6az: test_market_walks_locked carries no Σ pendingMatches term"               "$(cat tests/test_market_walks_locked.sh)" "getMyPendingMatches"
src_has   "§6az (6.0.0): candid/README.md records the removal under 'Major bumps so far'"  "$(cat candid/README.md)" "6.0.0 — September 2026"
src_lacks "§6az (6.0.0): ...and no longer queues it"                                      "$(sed -n '/^### Queued for the next major bump/,/^### Major bumps so far/p' candid/README.md)" "PendingMatch"

# ── §6ba 1788731608: apiVersion 6.0.0 — depositLp / withdrawLp ARE the sealed LP doors; seedAmmPool is controller-only; no stageLp* alias ──
# Operator ruling 2026-09-06 (task 1788503312, docs/amm-vault-design.md §5
# "Sealed LP requests"): an LP request settles at the first NAV whose basket
# marks ALL postdate it. 5.1.0 landed that additively behind stageLpDeposit /
# stageLpWithdraw; the 6.0.0 hatch renamed them onto the public doors (their
# #ok is the request now — a Candid return type cannot change meaning under
# the same shape, hence the major) and dropped the stage* names outright:
# they existed for one unreleased minor and a second name for one door is
# exactly the surface a major window exists to remove. seedAmmPool stays the
# ONE immediate mint door and is controller-only (the seed scripts run it
# under paused timers) — an open immediate mint would be the pre-6.0.0
# sniping window the ruling closed. withdrawLp keeps its exit-set membership
# (§6c): staging the exit IS the exit a shed LP needs. The 11 depositLp-
# calling suites and every fixture that seeded as a non-controller mint
# through tests/_lib.sh's mdx_lp_deposit / mdx_lp_withdraw (stage, re-stamp
# the waited markets, requote, run the pass, read the outcome), which is
# what retired test_ghsa_round4's 30×3 s "LP deposit paused" retry.
src_has   "§6ba: MM_API_VERSION major is 6"                                               "$(cat src/backend/main.mo)" 'transient let MM_API_VERSION : Text = "6.'
for FN in stageLpDeposit stageLpWithdraw; do src_lacks "§6ba: main.mo no longer defines $FN (no alias kept)" "$PMR_MAIN" "func $FN("; done
src_lacks "§6ba: the inspect variant dropped #stageLpDeposit / #stageLpWithdraw"          "$(printf '%s\n' "$INSPECT_FN" | mo_code)" "#stageLp"
BA_DL=$(mo_func src/backend/main.mo "func depositLp(" | mo_code)
BA_WL=$(mo_func src/backend/main.mo "func withdrawLp(" | mo_code)
[ -n "$BA_DL" ] || _fail "§6ba: could not extract depositLp()"
[ -n "$BA_WL" ] || _fail "§6ba: could not extract withdrawLp()"
src_has   "§6ba: depositLp returns the staged request"                                    "$BA_DL"      ") : async { #ok : StagedLpRequest; #err : Text } {"
src_has   "§6ba: ...reserves the legs at the request"                                     "$BA_DL"      "addReserved(msg.caller,"
src_has   "§6ba: ...arms the GEPTOR on every market it waits on"                          "$BA_DL"      "armStagedLpGeptor("
src_has   "§6ba: ...refuses under the season-seal latch"                                  "$BA_DL"      "sealingRefusal()"
src_lacks "§6ba: ...and never mints in the entry (settlement runs in the pass — §8b honesty)" "$BA_DL"  "performLpDeposit("
src_has   "§6ba: withdrawLp returns the staged request"                                   "$BA_WL"      ": async { #ok : StagedLpRequest; #err : Text } {"
src_has   "§6ba: ...reserves the shares at the request"                                   "$BA_WL"      "Map.add(vaultLpReserved,"
src_lacks "§6ba: ...and never redeems in the entry"                                       "$BA_WL"      "performLpWithdraw("
BA_SS=$(mo_func src/backend/main.mo "func settleStagedLp(" | mo_code)
src_has   "§6ba: settlement mints through performLpDeposit at the post-request marks"     "$BA_SS"      "performLpDeposit(r.owner,"
src_has   "§6ba: ...and redeems through performLpWithdraw"                                "$BA_SS"      "performLpWithdraw(r.owner,"
BA_SEED=$(mo_func src/backend/main.mo "func seedAmmPool(" | mo_code)
src_has   "§6ba: seedAmmPool refuses anonymous FIRST (the auth suite's rejection probe)"  "$BA_SEED"    "requireAuth(msg.caller);"
src_has   "§6ba: ...then is controller-only — the one immediate mint door"                "$BA_SEED"    "requireController(msg.caller);"
case " $(echo $EXIT_LIST) " in *" withdrawLp "*) _ok "§6ba: withdrawLp keeps its exit-set membership as the staged door (§6c ties the arms)" ;; *) _fail "§6ba: withdrawLp left EXIT_METHOD_SET — a shed LP could not stage an exit" ;; esac
BA_DID=$(tr -d '\n' < candid/backend.did | tr -s ' ')
src_has   "§6ba: the Candid's depositLp yields the request"                               "$BA_DID"     "depositLp: (marketId: MarketId, baseAmount: nat, quoteAmount: nat) -> (variant { err: text; ok: StagedLpRequest; });"
src_has   "§6ba: ...and withdrawLp too"                                                   "$BA_DID"     "withdrawLp: (lpAmount: nat) -> (variant { err: text; ok: StagedLpRequest; });"
src_lacks "§6ba: the Candid carries no stageLp* method"                                   "$BA_DID"     "stageLp"
src_has   "§6ba: the hand-written IDL's depositLp yields the request"                     "$PMR_JS"     "depositLp: IDL.Func([IDL.Text, IDL.Nat, IDL.Nat],
        [IDL.Variant({ ok: StagedLpRequest, err: IDL.Text })], []),"
src_has   "§6ba: ...and withdrawLp too"                                                   "$PMR_JS"     "withdrawLp: IDL.Func([IDL.Nat],
        [IDL.Variant({ ok: StagedLpRequest, err: IDL.Text })], []),"
for NEEDLE in stageLpDeposit stageLpWithdraw; do src_lacks "§6ba: the IDL / card no longer mention $NEEDLE" "$PMR_JS" "$NEEDLE"; done
src_has   "§6ba: the Earn card deposits through depositLp"                                "$PMR_JS"     "await appState.actor.depositLp("
src_has   "§6ba: ...and withdraws through withdrawLp"                                     "$PMR_JS"     "await appState.actor.withdrawLp("
src_has   "§6ba: ...polling the outcome (awaitStagedLp)"                                  "$PMR_JS"     "await awaitStagedLp(stagedId,"
BA_LIB=$(cat tests/_lib.sh)
src_has   "§6ba: _lib.sh carries mdx_lp_deposit"                                          "$BA_LIB"     "mdx_lp_deposit() {"
src_has   "§6ba: ...and mdx_lp_withdraw"                                                  "$BA_LIB"     "mdx_lp_withdraw() {"
src_has   "§6ba: ...which settle through the ops driver when nothing else fires"          "$BA_LIB"     "call adminRunStagedLp '()' >/dev/null 2>&1"
src_lacks "§6ba: test_ghsa_round4's 30×3 s 'LP deposit paused' retry is retired"          "$(uncommented tests/test_ghsa_round4.sh)" 'grep -q "LP deposit paused" || break'
BA_NONCTL=""
for f in tests/test_*.sh; do
  [ "$(basename "$f")" = "test_deploy_hygiene.sh" ] && continue   # this file's own needles
  grep_scan ba_seed "$(uncommented "$f")" 'seedAmmPool'
  grep_filter ba_seed '--identity (alice|anonymous)'
  grep_has "$ba_seed" 'seedAmmPool "' && BA_NONCTL="$BA_NONCTL $(basename "$f")"
done
if [ -z "$BA_NONCTL" ]; then _ok "§6ba: no suite seeds the vault through seedAmmPool as a non-controller (they mint through mdx_lp_deposit)"
else _fail "§6ba: seedAmmPool as a non-controller identity in:$BA_NONCTL — it is controller-only since 6.0.0; mint through mdx_lp_deposit"; fi
src_has   "§6ba: seed.sh seeds the vault as alice (a controller) through seedAmmPool"      "$(uncommented scripts/seed.sh)" 'seedAmmPool "(\"$market\", $(e8 $base_amt), $(e8 $quote_amt))" --identity alice'
src_has   "§6ba: docs/amm-vault-design.md §5 names the doors"                             "$(cat docs/amm-vault-design.md)" "Surface (apiVersion 6.0.0"
src_has   "§6ba: candid/README.md's 6.0.0 entry names the flip"                           "$(cat candid/README.md)" "depositLp\` / \`withdrawLp\` BECOME the sealed LP doors"

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
# Array literals count too (task 1788533845): the inspect gate's method lists
# (EXIT_METHODS, PRE_REGISTRATION_METHODS, DEV_PRE_REGISTRATION_METHODS) were
# plain `let … : [Text]`s — configuration read at runtime, implicitly stable,
# so an upgrade editing a list changed nothing on a live venue (caught live
# on the seat venue twice). The census is this one regex over main.mo: every
# match is either `transient` (not matched — the regex wants a bare `let`) or
# carries the STABLE-FOSSIL marker; and every fossil is declared ONCE and
# read NOWHERE (a read would see the first-installed value — §6c/§6d's pin,
# generalised), its literal parked at the empty / zero value.
STABLE_CONST_RE='^  let [A-Z][A-Z0-9_]* : (Nat|Int|Float|Bool|Text|\[(Nat|Int|Float|Bool|Text)\]) = '
N_STABLE_CONST=$(grep -E "$STABLE_CONST_RE" src/backend/main.mo | grep -cv 'STABLE-FOSSIL' || true)
if [ "${N_STABLE_CONST:-0}" -eq 0 ]; then _ok "§7b: no implicitly-stable scalar or array constant in main.mo (every actor-level UPPER_SNAKE literal is transient or a marked STABLE-FOSSIL)"
else
  _fail "§7b: $N_STABLE_CONST constant(s) in main.mo are implicitly stable — mark them 'transient let' (fresh name; fossil-park the old one) or the next upgrade silently keeps the first-installed value"
  grep -nE "$STABLE_CONST_RE" src/backend/main.mo | grep -v 'STABLE-FOSSIL' | head -5 | sed 's/^/      /' >&2
fi
STABLE_FOSSILS=$(grep -E "$STABLE_CONST_RE" src/backend/main.mo | grep 'STABLE-FOSSIL' | sed -E 's/^  let ([A-Z][A-Z0-9_]*) : .*/\1/')
[ -n "$STABLE_FOSSILS" ] && _ok "§7b: $(printf '%s\n' $STABLE_FOSSILS | grep -c .) STABLE-FOSSIL constant(s) in the census ($(echo $STABLE_FOSSILS))" || _fail "§7b: the census found no STABLE-FOSSIL constant — the known fossils (EPISODE_CAP, MARGIN_CASH_SETTLE_USD, the gate lists) were dropped or unmarked; EOP refuses stable drops (IC0503)"
for fossil in $STABLE_FOSSILS; do
  grep_count FOSSIL_READS "$(mo_code < src/backend/main.mo)" "\\b$fossil\\b"
  if [ "${FOSSIL_READS:-0}" -eq 1 ]; then _ok "§7b: STABLE-FOSSIL $fossil is declared once and read nowhere"
  else _fail "§7b: STABLE-FOSSIL $fossil occurs $FOSSIL_READS times outside comments — a fossil is declared exactly once and never read (a read sees the first-installed value on every upgraded venue); read its transient successor instead"; fi
done
# (subPendingQty — subReserved's fail-closed twin under #28.4 — was RETIRED
# with the PendingMatch machinery, task 1788516198; §6az pins its absence.
# subReserved's own fail-closed shape is unchanged.)

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
# The 83cf52c law-5/8 guards port put a `case "$TARGET"` ABOVE gen-did: the
# factory_primary_guard dispatch, which deploys nothing — matching the FIRST
# case blindly turned this assertion into a false positive. Pin the first
# case whose body is NOT the guard dispatch: that is where target branches
# start being able to ship, and gen-did must precede it.
CASE_LN=$(awk '/case "\$TARGET" in/ { ln=NR; if ((getline nxt) > 0 && nxt !~ /factory_primary_guard/) { print ln; exit } }' scripts/deploy.sh)
if [ -n "$GENDID_LN" ] && [ -n "$CASE_LN" ] && [ "$GENDID_LN" -lt "$CASE_LN" ]; then
  _ok "gen-did step precedes the target dispatch (every target inherits it)"
else
  _fail "gen-did step at line ${GENDID_LN:-none} does not precede the target case at ${CASE_LN:-none} — a target branch could ship without it"
fi
# cold_start.sh is the path every factory seat brings its venue up through,
# and it called `icp deploy` directly — so a cold start after an API edit
# shipped the PREVIOUS interface (task 1788483105, found live on a seat:
# a new method's reply printed as a raw hash variant, no candid diff).
# Same gate, same refusal wording, and it must sit BEFORE the deploy call.
# `uncommented` blanks comment lines in place, so its line numbers ARE the
# source's — the ordering check reads the comment-stripped text so that a
# comment naming gen-did can never satisfy the presence or ordering pin.
COLD_UNC=$(uncommented scripts/cold_start.sh)
src_has "cold_start regenerates candid before deploy (gen-did.sh)" "$COLD_UNC" 'gen-did.sh'
src_has "cold_start refuses on a gen-did failure (no stale interface ships)" "$COLD_UNC" "refusing to deploy a stale candid"
COLD_GENDID_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'gen-did.sh' | head -1 | cut -d: -f1)
COLD_DEPLOY_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'icp deploy --identity' | head -1 | cut -d: -f1)
if [ -n "$COLD_GENDID_LN" ] && [ -n "$COLD_DEPLOY_LN" ] && [ "$COLD_GENDID_LN" -lt "$COLD_DEPLOY_LN" ]; then
  _ok "cold_start's gen-did step precedes its icp deploy (line $COLD_GENDID_LN < $COLD_DEPLOY_LN)"
else
  _fail "cold_start's gen-did step at line ${COLD_GENDID_LN:-none} does not precede its icp deploy at ${COLD_DEPLOY_LN:-none} — a cold start ships a stale candid:service"
fi
# cold_start's closing summary printed the SCRIPT's mode default ("play") plus
# a `Bot log` line on deploy.sh's in-place upgrade path (`cold_start
# --no-seed` on a seat whose canister had just upgraded to #dev and which
# started NO fleet — task 3088507290, seat-3 2026-09-04, and task 3088509465,
# exec-a the same day: two seats, one lie). The summary now asks the CANISTER
# (getDeployMode, identity-pinned like every icp call) on EVERY path, with the
# comment-aware mdx_posture_of read taken before the deploy as the fallback,
# and the bot-log line follows the flag the two launch sites set where they
# ACTUALLY start a fleet — never the mode default. The full shape (the
# no-seed label, the launch-site order, the "fleet NOT started" spelling) is
# pinned in §6ai; the invariants first pinned here are kept in their merged
# spellings.
src_has   "cold_start's summary asks the canister its posture (getDeployMode, --identity pinned)" "$COLD_UNC" "getDeployMode '()' --query --identity anonymous"
src_has   "cold_start's --no-seed mode line derives from the canister's answer"          "$COLD_UNC" 'echo "  Mode    : $POSTURE_SHOWN (update, no seed; $POSTURE_SRC)"'
src_lacks "cold_start's seeded mode line no longer reports the bare script mode"         "$COLD_UNC" 'echo "  Mode    : $MODE"'
src_has   "cold_start's §4 launcher records that it started a fleet"                     "$COLD_UNC" 'FLEET_STARTED=true'
src_has   "cold_start's bot-log line is gated on the fleet flag"                         "$COLD_UNC" 'if $FLEET_STARTED; then'
src_lacks "cold_start's bot-log line no longer follows the mode default"                 "$COLD_UNC" '[ "$SIMULATE" = "yes" ] || { [ "$MODE" = "play" ]'
COLD_GDM_LN=$(printf '%s\n' "$COLD_UNC" | grep -n "getDeployMode '()' --query --identity anonymous" | head -1 | cut -d: -f1)
COLD_CMODE_LN=$(printf '%s\n' "$COLD_UNC" | grep -nF 'Mode    : $POSTURE_SHOWN (update, no seed;' | head -1 | cut -d: -f1)
if [ -n "$COLD_GDM_LN" ] && [ -n "$COLD_CMODE_LN" ] && [ "$COLD_GDM_LN" -lt "$COLD_CMODE_LN" ]; then
  _ok "cold_start's getDeployMode query precedes the --no-seed mode line (line $COLD_GDM_LN < $COLD_CMODE_LN)"
else
  _fail "cold_start's getDeployMode query at line ${COLD_GDM_LN:-none} does not precede its --no-seed mode line at ${COLD_CMODE_LN:-none} — the mode line cannot derive from the canister"
fi
COLD_BOTSTART_LN=$(printf '%s\n' "$COLD_UNC" | grep -nF 'bash "$SCRIPT_DIR/start_bots_local.sh"' | head -1 | cut -d: -f1)
COLD_FLAG_LN=$(printf '%s\n' "$COLD_UNC" | grep -nF 'FLEET_STARTED=true' | tail -1 | cut -d: -f1)
COLD_BOTLOG_LN=$(printf '%s\n' "$COLD_UNC" | grep -nF 'if $FLEET_STARTED; then' | head -1 | cut -d: -f1)
if [ -n "$COLD_BOTSTART_LN" ] && [ -n "$COLD_FLAG_LN" ] && [ -n "$COLD_BOTLOG_LN" ] \
   && [ "$COLD_BOTSTART_LN" -lt "$COLD_FLAG_LN" ] && [ "$COLD_FLAG_LN" -lt "$COLD_BOTLOG_LN" ]; then
  _ok "cold_start's fleet flag is set at the §4 launch site and read by the summary (lines $COLD_BOTSTART_LN < $COLD_FLAG_LN < $COLD_BOTLOG_LN)"
else
  _fail "cold_start's fleet flag ordering is wrong (start ${COLD_BOTSTART_LN:-none}, flag ${COLD_FLAG_LN:-none}, summary gate ${COLD_BOTLOG_LN:-none}) — the bot-log line does not follow an actual launch"
fi
# cold_start's network-start path is BOUNDED and DIAGNOSED (task 1788581044,
# the 1788580163 follow-up). `icp network start --background` used to run in
# the FOREGROUND: in the 2026-09-05 launcher wedge (docs/seat-venue-bring-up.md)
# the CLI never returns — it awaits a status.json the parked launcher never
# writes — so cold_start hung at that line indefinitely, silent. The start
# now runs backgrounded with its PID captured and a `kill -0` watchdog (no
# `timeout` binary on this machine, bash 3.2, never a process pattern) up to
# REPLICA_START_GRACE_S — the doctor's own env name, so the two agree — and
# on the deadline OR a returned start with no reachable gateway it runs the
# real `replica-doctor.sh --start-wedge` and prints the verdict verbatim
# before exit 1. It stays READ-ONLY: it never kills the CLI child (the
# human/seat decides per the bring-up note's "WEDGED twice -> HUMAN NEEDED").
# The happy path is byte-for-byte: the `ok "replica ready on :$GW_PORT"` line
# and the "already running" short-circuit are what seats and tests grep for.
src_has   "cold_start backgrounds icp network start into the run log (captured PID)"   "$COLD_UNC" '> "$MDX_NETWORK_START_LOG" 2>&1 &'
src_lacks "cold_start no longer runs icp network start in the foreground"             "$COLD_UNC" '> "$MDX_NETWORK_START_LOG" 2>&1 || true'
src_has   "cold_start watchdogs the start by its captured PID (kill -0, never a pattern)" "$COLD_UNC" 'kill -0 "$START_PID"'
src_has   "cold_start bounds the wait with the doctor's REPLICA_START_GRACE_S"       "$COLD_UNC" 'REPLICA_START_GRACE_S'
src_has   "cold_start runs the real start doctor on a wedged/failed start"           "$COLD_UNC" 'bash "$SCRIPT_DIR/replica-doctor.sh" --start-wedge "$(pwd)"'
src_has   "cold_start's happy-path ready line is untouched"                           "$COLD_UNC" 'ok "replica ready on :$GW_PORT"'
src_has   "cold_start's already-running short-circuit is untouched"                   "$COLD_UNC" 'ok "replica already running at 127.0.0.1:$GW_PORT (single master owns the gateway)"'
# play_start.sh is the other standalone build+install path (`icp build` then
# `install --mode reinstall`): same gap, same gate, gen-did before the build.
PLAY_UNC=$(uncommented scripts/play_start.sh)
src_has "play_start regenerates candid before building (gen-did.sh)" "$PLAY_UNC" 'gen-did.sh'
src_has "play_start refuses on a gen-did failure (no stale interface ships)" "$PLAY_UNC" "refusing to deploy a stale candid"
PLAY_GENDID_LN=$(printf '%s\n' "$PLAY_UNC" | grep -n 'gen-did.sh' | head -1 | cut -d: -f1)
PLAY_BUILD_LN=$(printf '%s\n' "$PLAY_UNC" | grep -n '^icp build' | head -1 | cut -d: -f1)
if [ -n "$PLAY_GENDID_LN" ] && [ -n "$PLAY_BUILD_LN" ] && [ "$PLAY_GENDID_LN" -lt "$PLAY_BUILD_LN" ]; then
  _ok "play_start's gen-did step precedes its icp build (line $PLAY_GENDID_LN < $PLAY_BUILD_LN)"
else
  _fail "play_start's gen-did step at line ${PLAY_GENDID_LN:-none} does not precede its icp build at ${PLAY_BUILD_LN:-none} — a play reinstall ships a stale candid:service"
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
  grep_count N_BUILDS "$(awk -v anchor="$REG_ANCHOR" '
    index($0, anchor) { f = 1 }
    f { print }
    f && /^[[:space:]]*\]\)?;[[:space:]]*$/ { exit }
  ' src/backend/main.mo | mo_code)" '\.build\(\)'
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

# ── §7i #51 follow-up items 2+3: no bare "ok" success oracle in tests/*.sh ──
# A bare `grep -q` for the substring "ok" matches the product's own refusals
# — baseToken, sellToken, buyToken, debtToken all contain it — so an #err at
# the owner cap read as the assertion's OPPOSITE; 84 sites carried it on
# 2026-09-04. The shared `mdx_ok` in tests/_lib.sh matches `variant { ok` on
# the whitespace-normalized reply and is the only sanctioned oracle. Banned
# here (comment lines excepted): `-q "ok"`, `-q 'ok'`, unquoted `-q ok`, and
# any -q alternation carrying a bare `ok` alternative ("ok|…", "…|ok|…",
# "…|ok", "(…|ok)"). The needles spell the token as [o]k, so this pin's own source
# lines and _lib.sh's helper (whose pattern begins `variant`) are exempt by
# construction — not by filename.
OK_HITS=$(perl -ne 'next if /^\s*#/; print "$ARGV:$.: $_" if /grep\s+-q[A-Za-z]*\s+(?:"[o]k"|\x27[o]k\x27|[o]k(?=[\s;&|)]|$))/ || /grep\s+-q[A-Za-z]*\s+["\x27]\(?(?:[^"\x27]*\|)?[o]k\)?(?:\||["\x27])/; close ARGV if eof' tests/*.sh 2>/dev/null || true)
if [ -z "$OK_HITS" ]; then
  _ok "no bare \"ok\" success oracle in tests/*.sh — every #ok check goes through mdx_ok (#51 follow-up)"
else
  _fail "bare \"ok\" success oracle in tests — it matches baseToken/sellToken/buyToken/debtToken inside the product's refusals, so an #err passes; use mdx_ok \"\$REPLY\" from tests/_lib.sh (#51 follow-up): $OK_HITS"
fi
# The same oracle in assert_contains clothing: `assert_contains <name> "$R" "ok"`
# passed the Bridge's "…dev-only hook (posture: play/production)" refusal on
# the "ok" inside "hook" (test_bridge_deposit_claim §14, seat-2 2026-09-04)
# and a Candid parse error on the one inside "Unrecognized token". assert_ok
# is the assertion form of mdx_ok; the needle is spelled [o]k as above.
AC_HITS=$(perl -ne 'next if /^\s*#/; print "$ARGV:$.: $_" if /assert_contains\s+.*\s(?:"[o]k"|\x27[o]k\x27)\s*(?:#.*)?$/; close ARGV if eof' tests/*.sh 2>/dev/null || true)
if [ -z "$AC_HITS" ]; then
  _ok "no assert_contains with a bare \"ok\" needle in tests/*.sh — use assert_ok <name> \"\$REPLY\" (#51 follow-up)"
else
  _fail "assert_contains with a bare \"ok\" needle — it passes any refusal whose text contains ok (hook, token, …); use assert_ok <name> \"\$REPLY\" from tests/_lib.sh (#51 follow-up): $AC_HITS"
fi
# A suite that CALLS mdx_ok/assert_ok must actually source _lib.sh — a file
# that merely mentions _lib.sh in a comment (two did) leaves the helper
# undefined, and `mdx_ok "$R" || nok …` then reds every #ok it guards.
MDX_UNSOURCED=""
for f in tests/*.sh; do
  [ "$f" = "tests/_lib.sh" ] && continue
  mu_src=$(cat "$f")
  if grep_has "$mu_src" '^[^#]*\b(mdx_ok|assert_ok)\b' && ! grep_has "$mu_src" '^\s*(source|\.)\s+.*_lib\.sh'; then MDX_UNSOURCED="$MDX_UNSOURCED $f"; fi
done
if [ -z "$MDX_UNSOURCED" ]; then
  _ok "every suite calling mdx_ok/assert_ok sources tests/_lib.sh"
else
  _fail "suite calls mdx_ok/assert_ok without sourcing tests/_lib.sh (the helper is undefined there — every #ok it guards reds):$MDX_UNSOURCED"
fi
# Since task 1788508007 mdx_ok carries no needle of its own: it routes the
# reply to scripts/lib/reply.sh's mdx_reply_ok (sourced by _lib.sh), whose
# needle accepts the named AND the hash-spelled ok (`24_860`, printed when
# icp's candid fetch misses) — §3d pins that needle in the lib, §6af drives
# mdx_ok itself with both spellings. The pin here is the ROUTING: a second
# copy of the regex in _lib.sh is exactly the drift the lib exists to end.
if grep -qE '^mdx_ok\(\) \{' tests/_lib.sh && grep -qF 'mdx_reply_ok "$reply"' tests/_lib.sh && grep -qF 'source "$SCRIPT_DIR/scripts/lib/reply.sh"' tests/_lib.sh; then
  _ok "tests/_lib.sh defines mdx_ok on the Result success shape, routed through scripts/lib/reply.sh's mdx_reply_ok (ok or 24_860)"
else
  _fail "tests/_lib.sh lost mdx_ok, its mdx_reply_ok routing, or the reply.sh source line — the shared oracle the §7i ban routes every suite to (task 1788508007)"
fi
grep_scan LIB_PRIV_NEEDLE "$(uncommented tests/_lib.sh)" "grep -[a-zA-Z]*E? *'variant"
if [ -z "$LIB_PRIV_NEEDLE" ]; then
  _ok "tests/_lib.sh carries no private 'variant …' needle (the lib is the only copy)"
else
  _fail "tests/_lib.sh regrew a private 'variant …' needle — mdx_ok must route through the lib's mdx_reply_ok, the ONE copy (task 1788508007): $(printf '%s' "$LIB_PRIV_NEEDLE" | tr '\n' ' ' | head -c 200)"
fi
# simulate_trading.sh's is_ok is the DELIBERATE un-sourced copy (live fleets
# run the file for hours; it stays self-contained), so its needle is pinned
# LITERALLY — the hashed-ok alternation included (task 1788508007) — and the
# function is column-0 multi-line so §6af can slice and drive it.
if grep -qE '^is_ok\(\) \{$' scripts/simulate_trading.sh && grep -qF "grep -cE 'variant \\{ (ok|24_860)( \\}| =)' >/dev/null" scripts/simulate_trading.sh && ! grep_has "$(cat scripts/simulate_trading.sh)" "^is_ok\(\).*grep -q '[o]k'"; then _ok "scripts/simulate_trading.sh judges #ok by the variant tag — is_ok carries the lib's needle (ok or 24_860) un-sourced, the bare \"ok\" substring form is gone (1788495792, 1788508007)"; else _fail "scripts/simulate_trading.sh is_ok lost the 'variant { (ok|24_860)' needle, regrew the bare \"ok\" substring oracle, or is no longer a column-0 multi-line function — the simulator would tally a hashed-ok fill as a refusal, or a plain-text failure carrying ok as a fill (1788495792, 1788508007)"; fi
if grep -qE '^i1_tol_e8=[0-9]+$' tests/_lib.sh && grep -qF 'assert_abs_close "Σ user LP == vaultLPSupply' tests/test_invariants_battery.sh && grep -qF '"$i1_tol_e8"' tests/test_invariants_battery.sh; then
  _ok "I1 tolerance is one shared absolute number (i1_tol_e8) in _lib.sh, used by assert_invariants AND test_invariants_battery.sh (#51.5 both sites)"
else
  _fail "I1 tolerance drifted: _lib.sh must define file-scope i1_tol_e8=<n> and test_invariants_battery.sh must assert Σ user LP == vaultLPSupply with assert_abs_close … \"\$i1_tol_e8\" — a relative band there let ~300 whole tokens through (#51.5 second site)"
fi

# ── §6bb 1788727876: the vault lock index settles AT every loan-book mutation ─
# Task 1788475756's lock model detected repayment LAZILY — the per-token
# loan-book units diffed at the LP touches only — so a repayment followed by
# a fresh borrow of the same token between two touches netted to R = 0 and
# released no lock (six repay+reborrow rounds in one beat left a fully
# locked LP at cap $0). reprovisionPool is the one hook every loan-book
# mutator already runs (poolFundForFill's borrow at the fill, deleveragePool's
# repay, repayPoolDebt, absorbBadDebt, tryLiquidate, settleNettedPair's
# netted sides), so it settles the index there, synchronously, on the
# provision it just refreshed; the lazy touches stay as the belt. These pins
# keep the hook exhaustive: drop a mutator's reprovisionPool and the settle
# goes with it.
BB_RP=$(mo_func src/backend/main.mo "func reprovisionPool(" | mo_code)
BB_SM=$(mo_func src/backend/main.mo "func settleVaultLocksOnMutation(" | mo_code)
[ -n "$BB_RP" ] || _fail "§6bb: could not extract reprovisionPool()"
[ -n "$BB_SM" ] || _fail "§6bb: could not extract settleVaultLocksOnMutation()"
src_has   "§6bb: reprovisionPool refreshes the impairment provision first"                 "$BB_RP" 'reprovisionPoolImpairment(poolId, who);'
src_has   "§6bb: ...then settles the lock index at the same mutation"                      "$BB_RP" 'settleVaultLocksOnMutation();'
src_has   "§6bb: the mutation settle is a no-op without locks"                             "$BB_SM" 'if (vaultLockRawSum == 0) { return };'
src_has   "§6bb: ...and otherwise the PERSISTING settle on the live observables"           "$BB_SM" 'settleVaultLocks(vaultHoldingsUsd(), currentVaultValue().totalQuoteValue);'
src_lacks "§6bb: the mutation settle never awaits (it runs inside the matching pass)"      "$BB_SM" 'await'
src_lacks "§6bb: ...nor does reprovisionPool"                                              "$BB_RP" 'await'
for FN in poolFundForFill deleveragePool repayPoolDebt tryLiquidate; do
  src_has "§6bb: $FN re-provisions (and so settles the locks) after its loan-book mutation" "$(mo_func src/backend/main.mo "func $FN(" | mo_code)" 'reprovisionPool('
done
# absorbBadDebt re-provisions through the write-off hook (1788752774, §6bc): the
# same impairment refresh + settle, with the uncovered USD netted out.
src_has "§6bb: absorbBadDebt re-provisions (and so settles the locks, write-off netted — §6bc) after its write-off" "$(mo_func src/backend/main.mo "func absorbBadDebt(" | mo_code)" 'reprovisionPoolAfterWriteOff(user, uncovered);'
BB_TL=$(mo_func src/backend/main.mo "func runLiquidationBatch(" | mo_code)
src_has   "§6bb: runLiquidationBatch Phase 2 (settleNettedPair) re-provisions the netted seller"                  "$BB_TL" 'reprovisionPool(sArr[si].user);'
src_has   "§6bb: ...and the netted buyer"                                                  "$BB_TL" 'reprovisionPool(bArr[bi].user);'
src_has   "§6bb: the lazy belt stays: the heartbeat beat still settles while any lock exists" "$H06_MAIN" 'if (vaultLockRawSum > 0) { settleVaultLocks(vaultHoldingsUsd(), currentVaultValue().totalQuoteValue) };'
src_has   "§6bb: test_vault_lp §7 pins the repay-then-reborrow leg"                        "$(uncommented tests/test_vault_lp.sh)" 'repay-then-reborrow in one beat'
src_has   "§6bb: amm-vault-design §5 no longer lists the lazy detection as an accepted trade-off" "$(cat docs/amm-vault-design.md)" 'settles at every loan-book mutation'

# ── §6bc 1788752774: a WRITE-OFF moves no lock — the settle nets the uncovered USD out ─
# §6bb's settle measures a repayment as the shrink of the loan-book units,
# and the lib treated every shrink as cash arriving for the loan claimants —
# so absorbBadDebt's UNCOVERED residual (a pure loss) scaled the locks as if
# its USD had come back, unlocking a fully locked LP out of the stayers'
# cash. Classification is the actor's, by site: the write-off site passes
# the uncovered USD as an ARGUMENT (no accumulator, nothing lingers past the
# message) and the settle subtracts it from the units-diff before the lib;
# the snapshot still moves by the full shrink. Every cash-backed mutator —
# repayments, the seize (collateral lands in kind), the netted pair, the
# fund's covered slice — stays on the plain reprovisionPool. These pins keep
# the two paths distinct: fold the write-off back into the plain settle and
# the loss is a repayment again.
BC_NET=$(mo_func src/backend/main.mo "func settleVaultLocksNet(" | mo_code)
BC_WO=$(mo_func src/backend/main.mo "func settleVaultLocksOnWriteOff(" | mo_code)
BC_RPW=$(mo_func src/backend/main.mo "func reprovisionPoolAfterWriteOff(" | mo_code)
BC_ABD=$(mo_func src/backend/main.mo "func absorbBadDebt(" | mo_code)
BC_SVL=$(mo_func src/backend/main.mo "func settleVaultLocks(" | mo_code)
[ -n "$BC_NET" ] || _fail "§6bc: could not extract settleVaultLocksNet()"
[ -n "$BC_WO" ]  || _fail "§6bc: could not extract settleVaultLocksOnWriteOff()"
[ -n "$BC_RPW" ] || _fail "§6bc: could not extract reprovisionPoolAfterWriteOff()"
[ -n "$BC_ABD" ] || _fail "§6bc: could not extract absorbBadDebt()"
src_has   "§6bc: the netted settle subtracts the written-off USD from the units-diff BEFORE the lib" "$BC_NET" 'let repaidUsd = SafeMath.subOrZero(vaultLockRepaidUsd(), writtenOffUsd);'
src_has   "§6bc: ...and hands the lib the cash-backed shrink only"                          "$BC_NET" 'VaultLock.settle(vaultLockScale, vaultLockRawSum, vaultLPSupply, holdingsUsd, navUsd, repaidUsd);'
src_has   "§6bc: ...then moves the snapshot by the FULL shrink (the write-off is never re-measured)" "$BC_NET" 'vaultLockSnapshotNow();'
src_has   "§6bc: the plain settle is the netted one with nothing written off"               "$BC_SVL" 'settleVaultLocksNet(holdingsUsd, navUsd, 0)'
src_has   "§6bc: the write-off settle is a no-op without locks"                             "$BC_WO" 'if (vaultLockRawSum == 0) { return };'
src_has   "§6bc: ...and otherwise the netted settle on the live observables"                "$BC_WO" 'settleVaultLocksNet(vaultHoldingsUsd(), currentVaultValue().totalQuoteValue, writtenOffUsd);'
src_lacks "§6bc: the write-off settle never awaits"                                         "$BC_WO" 'await'
src_has   "§6bc: the write-off hook refreshes the impairment provision first"               "$BC_RPW" 'reprovisionPoolImpairment(poolId, who);'
src_has   "§6bc: ...then settles with the write-off netted out"                             "$BC_RPW" 'settleVaultLocksOnWriteOff(writtenOffUsd);'
src_lacks "§6bc: ...never the plain (repayment) settle"                                     "$BC_RPW" 'settleVaultLocksOnMutation('
src_lacks "§6bc: ...nor does it await"                                                      "$BC_RPW" 'await'
src_has   "§6bc: absorbBadDebt passes its UNCOVERED residual to the write-off hook"         "$BC_ABD" 'reprovisionPoolAfterWriteOff(user, uncovered);'
src_lacks "§6bc: ...and no longer takes the plain hook (which would classify the loss as a repayment)" "$BC_ABD" 'reprovisionPool(user)'
src_has   "§6bc: the uncovered slice is what absorbBadDebt tallies as the senior LPs' loss"   "$BC_ABD" 'if (uncovered > 0) { uncoveredBadDebtUsd += uncovered };'
src_has   "§6bc: the covered slice lands in the vault as CASH in the same message (it stays a repayment)" "$BC_ABD" 'Accounts.addBalance(accounts, ammPrincipal(), Types.QUOTE_TOKEN, covered);'
# The write-off hook is the ONE caller's: every other mutator stays cash-backed.
BC_CALLERS=$(printf '%s\n' "$(mo_code < src/backend/main.mo)" | grep -c 'reprovisionPoolAfterWriteOff(user, uncovered)' || true)
if [ "${BC_CALLERS:-0}" = "1" ]; then _ok "§6bc: exactly one write-off call site (absorbBadDebt) — the seize, the netted pair and every repayment stay on reprovisionPool"
else _fail "§6bc: expected exactly one reprovisionPoolAfterWriteOff(user, uncovered) call site, found ${BC_CALLERS:-0}"; fi
for FN in deleveragePool repayPoolDebt tryLiquidate; do
  src_lacks "§6bc: $FN is cash-backed and never routes through the write-off hook" "$(mo_func src/backend/main.mo "func $FN(" | mo_code)" 'reprovisionPoolAfterWriteOff('
done
src_has   "§6bc: VaultLock.mo's header classifies the write-off (e_i unchanged, only the clamp may move Λ)" "$(cat src/backend/lib/VaultLock.mo)" 'WRITE-OFF (task 1788752774)'
src_has   "§6bc: tests/VaultLock.test.mo pins the pure loss against the per-LP truth"      "$(cat tests/VaultLock.test.mo)" 'pure loss: A'"'"'s cash entitlement e_A is unchanged (the per-LP truth)'
src_has   "§6bc: ...and the mixed covered-cash + uncovered-loss message"                    "$(cat tests/VaultLock.test.mo)" 'mixed cash + loss: locks survive and the index shrank by the CASH only'
src_has   "§6bc: test_vault_lp §8b pins the live write-off (bob's cap moves by the cash-backed slice only)" "$(uncommented tests/test_vault_lp.sh)" 'after the write-off bob'"'"'s cap == his slice of the CASH-BACKED shrink only'
src_has   "§6bc: amm-vault-design §5 records the write-off classification as closed and names what remains" "$(cat docs/amm-vault-design.md)" 'nets the uncovered write-off out of the shrink'

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
  grep_count AW "$(mo_code < "$VF")" '\bawait\b'
  if [ "${AW:-0}" -eq 0 ]; then _ok "no await in $(basename "$VF") (single-message value path)"
  else _fail "$VF has $AW await(s) outside comments — this removes the property that closes the reentrancy/double-spend class (docs/security-review.md:143); custody needs a saga, not a bare await"; fi
done

# ── §8b the same property, per ENTRY POINT in main.mo (OhShii #55, round 18) ──
# W5-05 scoped the four files above deliberately ("where the property
# lives") — and that scope is narrower than its subject: the value paths
# ENTER through main.mo's public update methods, and main.mo legitimately
# holds ~60 awaits (archive spawns, XRC, fuel, AI, the GEPTOR continuation),
# so the whole-file assertion above cannot be applied to it. An `await`
# planted as the first line of `closePosition` left §8 green. This block
# slices each entry point's BODY with mo_func — the function, never the
# file — and asserts it await-free. The list is EXPLICIT, in two groups:
#
#   SETTLE (13) — the methods that debit or credit a user balance in the
#   same message. The inspect EXIT SET (§6c above; W1-05) contributes its
#   seven main.mo members — cancelMyOrder, cancelAllMyOrders, closePosition,
#   withdrawMarginPool, unstakeInsurance, withdrawLp, cancelPoolOrder (the
#   eighth, `withdraw`, lives in mixins/UserAccount.mo and is covered whole
#   by the loop above) — and the six value-IN mirrors of those exits: swap,
#   placeMarketOrder, depositLp, openPosition, stakeInsurance,
#   fundMarginPool. That is the thirteen the issue names; the count is
#   FLOORED at 13 so the list can only grow, and the exit set is re-derived
#   from inspect's switch below so a method added to the exit set must be
#   classified here too (the census is compiler-pinned; this list is not,
#   hence the tie). repayPoolDebt (task 1788523828, the ninth exit) is the
#   fourteenth: it moves pool quote/base to the vault in the same message.
#   cancelStagedLpRequest (task 1788731609, the tenth exit) is the
#   fifteenth: it releases the owner's staged-LP reservation (the deposit
#   legs' soft lock or the withdrawal's share reservation) in the same
#   message — the refund of a staged request IS reservation value moving.
#
#   STAGE (6) — the limit-order entries. They move value too (a reservation
#   is a debit of available balance, docs/security-review.md's "reservation
#   ledger" coverage line), so they get the same assertion; they are kept
#   apart from the thirteen only so the floor keeps meaning what the issue
#   said.
#
# Not on the list, and why: `geptorFetchAndSweep` is a heartbeat-driven
# continuation (a controller-side sweep, not a user value path) and its
# awaits are the design — the doc claim is "no await in any USER value
# path" and this gate does not widen it. Admin/dev/test hooks are
# controller-gated (not user paths). cancelAllAfter arms a switch and moves
# nothing. The slice is the entry BODY; the private main.mo helpers an entry
# delegates its value work to are followed ONE HOP by NOAWAIT_HELPERS below
# (1788480909) — the settlement libs those helpers call are the four files
# above, so entry + helper + lib closes each path end to end.
#   apiVersion 6.0.0 (task 1788731608): depositLp / withdrawLp ARE the
#   staged LP doors — depositLp reserves the deposit legs (addReserved) and
#   withdrawLp reserves the shares (vaultLpReserved) in the caller's message
#   (a reservation is value work); the mint / redemption itself runs in the
#   heartbeat / requote continuation (processStagedLp → settleStagedLp →
#   performLpDeposit / performLpWithdraw, one-hop list below), NOT in the
#   entry — the HONEST reading of "no await in the entry" for these two.
#   placeProtectedLimitOrder and the stageLp* names left the exchange (and
#   this list) at the same bump.
#   cancelStagedLpRequest (task 1788731609, the tenth exit) releases the
#   owner's own reservation in the entry — value work, on the SETTLE list.
NOAWAIT_SETTLE="withdrawLp closePosition swap placeMarketOrder depositLp openPosition stakeInsurance unstakeInsurance fundMarginPool withdrawMarginPool cancelMyOrder cancelAllMyOrders cancelPoolOrder repayPoolDebt cancelStagedLpRequest"
NOAWAIT_STAGE="placeLimitOrder placeLimitOrderExp placeLimitOrderPO placeLimitOrdersBulk replaceMyOrder"
NOAWAIT_N=$(printf '%s\n' $NOAWAIT_SETTLE | grep -c .)
if [ "$NOAWAIT_N" -ge 13 ]; then _ok "§8b: the settlement entry-point list holds the thirteen ($NOAWAIT_N)"
else _fail "§8b: the settlement entry-point list shrank to $NOAWAIT_N (floor 13) — an entry point was removed from the gate, not from the exchange; re-classify rather than drop"; fi
MAIN_MO_IMG=$(mo_code < src/backend/main.mo)
for FN in $NOAWAIT_SETTLE $NOAWAIT_STAGE; do
  SIGS=$(printf '%s\n' "$MAIN_MO_IMG" | grep -cF "func $FN(")
  if [ "${SIGS:-0}" -ne 1 ]; then
    _fail "§8b: 'func $FN(' occurs $SIGS times in main.mo (need exactly 1: mo_func slices the FIRST match, so a duplicate would let the gate test the wrong body) — renamed, moved to a mixin, or shadowed? re-classify it here"
    continue
  fi
  FN_BODY=$(mo_func src/backend/main.mo "func $FN(")
  # The slice must end at the actor-member closer. Every function on these
  # lists is a multi-line actor member at indent 2, so a slice whose last
  # line is anything else is a TRUNCATED window — and a truncated window
  # passes the no-await grep vacuously (placeLimitOrdersBulk did, on its
  # signature alone, before mo_func learned to track parens).
  FN_LAST=$(printf '%s\n' "$FN_BODY" | tail -1)
  case "$FN_LAST" in "  };"|"  }") ;; *)
    _fail "§8b: the slice of $FN ends at '$(printf '%s' "$FN_LAST" | sed 's/^[[:space:]]*//')' instead of the actor-member closer '  };' — mo_func stopped before the body, so a no-await verdict on it would be vacuous; fix the slicer (or the signature shape that fooled it) before trusting this gate"
    continue ;;
  esac
  grep_count AW "$(printf '%s\n' "$FN_BODY" | mo_code)" '\bawait\b'
  if [ "${AW:-0}" -eq 0 ]; then _ok "§8b: no await in $FN (single-message entry point)"
  else _fail "§8b: $FN carries $AW await(s) outside comments — an interleaving point in a user value path removes the property that closes the reentrancy/double-spend class (docs/security-review.md:143); custody needs a saga, not a bare await (mixins/UserAccount.mo's custody comment)"; fi
done
# ONE HOP DOWN (1788480909, the follow-up #55's reporter would have filed
# next): several of the nineteen are thin wrappers — `seedAmmPool` is a few
# lines around `performLpDeposit`, `cancelPoolOrder` five around
# `cancelPoolOrderInternal`, every limit-order entry ends in
# `placeLimitInner` — so an `await` planted in the helper left the entry
# loop above green, exactly the shape #55 reported one level up. This list
# is the private main.mo functions the nineteen delegate VALUE WORK to,
# derived by slicing each entry body with mo_func and intersecting the
# identifiers it calls with main.mo's own `func` definitions (one hop; not a
# call-graph walk — re-derive the same way when an entry changes shape).
# Format: `helper:caller[,caller]` — the callers are the entries above
# that reach it, and the loop below asserts each helper is STILL called
# from at least one of them, so the list cannot rot into naming helpers
# nobody delegates to while the replacement goes unguarded. Pure readers
# and touches an entry also calls (requireAuth, sealingRefusal, deadmanTouch,
# bumpUserVersion, ownsPool, poolPrincipalOf, the r2n/r6n formatters,
# getAvailable/getReserved, priceBandCheck, openOrderCapCheck, …) move no
# value and are left off — they are one grep away if that ever changes.
#
# Deliberately NOT on the list, and why: the helpers that legitimately
# await — geptorFetchAndSweep (heartbeat continuation), fuelStage2 /
# tickAutoFuel (fuel), spawnArchive / fundArchive (archive spawns),
# refreshMultiSourcePrice / fetchAndSetRefPrice (XRC + feeds) — are not
# reached from any of the nineteen entries (the derivation above finds no
# call to them in any entry body) and are not user value paths; the doc
# claim stays "no await in any USER value path" and this list does not
# widen it. If one of them ever appears in an entry body, that is the
# saga conversation, not a list edit.
NOAWAIT_HELPERS="
settleStagedLp:processStagedLp
performLpWithdraw:settleStagedLp
subVaultLp:performLpWithdraw
sweepZeroSupplyVaultToTreasury:performLpWithdraw
refreshVaultImpairment:performLpWithdraw
currentVaultValue:performLpWithdraw
parkDeferred:closePosition,placeMarketOrder,openPosition
executeSwapDirect:swap
executeSwapCross:swap
performLpDeposit:seedAmmPool,settleStagedLp
addInsuranceShares:stakeInsurance,unstakeInsurance
subInsuranceShares:unstakeInsurance
insuranceRedeemValue:unstakeInsurance
recordPoolTransfer:fundMarginPool,withdrawMarginPool
cancelPoolOrderInternal:cancelMyOrder,cancelPoolOrder
subReserved:cancelMyOrder
removeDeferredExec:cancelMyOrder
removeDeferredSwap:cancelMyOrder
cancelAllOrdersFor:cancelAllMyOrders
placeLimitInner:placeLimitOrder,placeLimitOrderExp,placeLimitOrderPO,placeLimitOrdersBulk,replaceMyOrder
cancelOwnSpotOrder:replaceMyOrder
repayPoolFromFree:repayPoolDebt
exitFolds:performLpWithdraw,unstakeInsurance,withdrawMarginPool
foldDustExit:performLpWithdraw,unstakeInsurance,withdrawMarginPool
cancelStagedLp:cancelStagedLpRequest
"
# Per helper, what it does on the path (why it is value work):
#   settleStagedLp                 the settlement of a READY LP request (6.0.0:
#                                  processStagedLp, inside every releasing
#                                  requote and the finaliser, reaches the
#                                  mint / redemption ONLY through it)
#   performLpWithdraw              the redemption itself (task 1788503312
#                                  factored it out of the then-immediate
#                                  withdrawLp; since 6.0.0 settleStagedLp is
#                                  its only caller, so the helpers below
#                                  are one hop from it)
#   subVaultLp                     withdrawLp burns the shares BEFORE the
#                                  payout (the burns-before-transfer line in
#                                  docs/security-review.md's coverage)
#   sweepZeroSupplyVaultToTreasury the last withdrawer's residue sweep
#   refreshVaultImpairment         re-marks the impairment the exit is priced at
#   currentVaultValue              values the vault the payout is pro-rata of
#   parkDeferred                   parks the deferred exec — the reservation
#                                  debit for closePosition / placeMarketOrder /
#                                  openPosition happens here
#   executeSwapDirect/Cross        the swap settlement itself (swap is a
#                                  dispatcher over the two)
#   performLpDeposit               the LP mint (seedAmmPool's body; a staged
#                                  deposit settles through it from
#                                  settleStagedLp — depositLp only reserves)
#   addInsuranceShares             insurance share credit
#   subInsuranceShares             insurance share burn before the payout
#   cancelStagedLp                 the owner cancel's refund (task 1788731609):
#                                  releases the request's reservation and
#                                  records the outcome — the same body the
#                                  TTL backstop runs
#   insuranceRedeemValue           prices the redemption
#   recordPoolTransfer             the margin-pool fund/withdraw ledger record
#   cancelPoolOrderInternal        pool-order cancel + reservation release
#                                  (cancelPoolOrder is a wrapper; cancelMyOrder
#                                  routes pool-owned orders to it)
#   subReserved                    reservation release on a spot cancel
#   removeDeferredExec/Swap        unparks staged value on cancel
#   cancelAllOrdersFor             the loop cancelAllMyOrders wraps
#   placeLimitInner                the reservation + stage every limit entry
#                                  (and the bulk closure) ends in
#   cancelOwnSpotOrder             the cancel half of replaceMyOrder
#   repayPoolFromFree              the pool→vault repay itself (repayPoolDebt
#                                  is a wrapper; deleveragePool's two in-kind
#                                  legs share it)
#   exitFolds / foldDustExit       H-32: the exit window's decide + fold —
#                                  the fold MOVES the exit's journal rows
#                                  into the window (value-record work on the
#                                  exit path; `withdraw`'s half, recordWithdrawal,
#                                  is pinned in §6at — its entry is the mixin)
NOAWAIT_H_N=$(printf '%s\n' $NOAWAIT_HELPERS | grep -c .)
if [ "$NOAWAIT_H_N" -ge 20 ]; then _ok "§8b: the one-hop helper list holds its twenty ($NOAWAIT_H_N)"
else _fail "§8b: the one-hop helper list shrank to $NOAWAIT_H_N (floor 20) — a helper was removed from the gate, not from the exchange; re-derive from the entry bodies rather than drop"; fi
for TOK in $NOAWAIT_HELPERS; do
  FN=${TOK%%:*}; CALLERS=${TOK#*:}
  SIGS=$(printf '%s\n' "$MAIN_MO_IMG" | grep -cF "func $FN(")
  if [ "${SIGS:-0}" -ne 1 ]; then
    _fail "§8b: 'func $FN(' occurs $SIGS times in main.mo (need exactly 1: mo_func slices the FIRST match, so a duplicate would let the gate test the wrong body) — renamed, moved to a mixin, or shadowed? re-derive the one-hop list from its caller(s) $CALLERS"
    continue
  fi
  FN_BODY=$(mo_func src/backend/main.mo "func $FN(")
  FN_LAST=$(printf '%s\n' "$FN_BODY" | tail -1)
  case "$FN_LAST" in "  };"|"  }") ;; *)
    _fail "§8b: the slice of helper $FN ends at '$(printf '%s' "$FN_LAST" | sed 's/^[[:space:]]*//')' instead of the actor-member closer '  };' — mo_func stopped before the body, so a no-await verdict on it would be vacuous; fix the slicer (or the signature shape that fooled it) before trusting this gate"
    continue ;;
  esac
  grep_count AW "$(printf '%s\n' "$FN_BODY" | mo_code)" '\bawait\b'
  if [ "${AW:-0}" -eq 0 ]; then _ok "§8b: no await in helper $FN (one hop from $CALLERS)"
  else _fail "§8b: helper $FN (one hop from $CALLERS) carries $AW await(s) outside comments — an interleaving point in a user value path removes the property that closes the reentrancy/double-spend class (docs/security-review.md:143); custody needs a saga, not a bare await (mixins/UserAccount.mo's custody comment)"; fi
  REACHED=""
  for C in $(printf '%s' "$CALLERS" | tr ',' ' '); do
    if mo_func src/backend/main.mo "func $C(" | mo_code | grep -cF "$FN(" >/dev/null; then REACHED="$REACHED $C"; fi
  done
  if [ -n "$REACHED" ]; then _ok "§8b: $FN is still one hop from$REACHED"
  else _fail "§8b: none of $CALLERS calls $FN( any more — the one-hop list has rotted: a helper nobody delegates to guards nothing, and whatever replaced it in the entry body is unguarded; re-derive from the entry bodies"; fi
done
# The tie to the census: every member of inspect's exit set that is defined
# in main.mo must be in NOAWAIT_SETTLE. `withdraw` is the mixin exception.
EXIT_SET=$(printf '%s\n' "$INSPECT_FN" | mo_code | sed -n '/let exitCandidate : ?Text = switch (msg)/,/case _/p' | grep -oE '#[A-Za-z0-9_]+' | tr -d '#' | sort -u)
EXIT_MISSING=""
for m in $EXIT_SET; do
  [ "$m" = "withdraw" ] && continue
  case " $NOAWAIT_SETTLE " in *" $m "*) ;; *) EXIT_MISSING="$EXIT_MISSING $m" ;; esac
done
if [ -z "$EXIT_SET" ]; then _fail "§8b: could not read the exit set out of inspect's switch (msg) — the parser needs updating, the tie is inert"
elif [ -z "$EXIT_MISSING" ]; then _ok "§8b: every main.mo member of inspect's exit set ($(printf '%s\n' $EXIT_SET | grep -c .) methods) is on the no-await list"
else _fail "§8b: inspect's exit set names$EXIT_MISSING but the no-await list does not — a user exit path was added without classifying it here (add it to NOAWAIT_SETTLE)"; fi

# ── §6av 1788488022: a #dev DEX beside a #play Bridge is named LOUDLY on the local deploy path, never refused ─
# The Bridge carries its OWN DEPLOY_MODE literal and three hooks gate on it
# (devTestStrandAdmission, devTestHoldAdmission, getDeployMode). The seat
# posture rhythm flips BOTH files; the one-file flip (DEX #dev, Bridge #play)
# is legal under W3-09 (the Bridge is LESS permissive, never more) but it
# silently loses every Bridge dev-hook suite section (bridge_deposit_claim
# §14-15, bridge_write_ahead §1-2, season_wipe_fence §1-2 — all loud-skip),
# and until this task nothing on the deploy path said a word. The operator
# chose a NOTE (task 1788488022 (a)): one helper in targets.sh, called by
# cold_start.sh from the TREE before anything builds (a Ctrl-C still saves
# the deploy) and from the LIVE getDeployMode answers in the banner.
# `deploy.sh local` is `exec cold_start.sh [--no-seed]` on both of its
# branches, so both entry points share the one site. Happy paths are
# byte-for-byte (§6ai's Mode-line pins and the watchdog pins above stand).
TARGETS_UNC=$(uncommented scripts/lib/targets.sh)
src_has "§6av: targets.sh defines the one lag-note helper" "$TARGETS_UNC" 'mdx_note_bridge_posture_lag() {'
src_has "§6av: the helper fires on exactly the dev/play pair" "$TARGETS_UNC" '{ [ "$dex" = "dev" ] && [ "$bridge" = "play" ]; } || return 0'
LAG_FN=$(printf '%s\n' "$TARGETS_UNC" | sed -n '/^mdx_note_bridge_posture_lag() {/,/^}/p')
src_lacks "§6av: the note never carries the posture-skip glyph (run_all counts every one in a suite log)" "$LAG_FN" '⊘'
src_lacks "§6av: the helper never dies (a note, not a refusal)" "$LAG_FN" 'mdx_die'
src_lacks "§6av: the helper never exits (a note, not a refusal)" "$LAG_FN" 'exit 1'
COLD_UNC=$(uncommented scripts/cold_start.sh)
src_has "§6av: cold_start reads the Bridge literal through the comment-aware reader" "$COLD_UNC" 'BUILD_BRIDGE_POSTURE=$(mdx_posture_of src/bridge/main.mo || true)'
src_has "§6av: cold_start notes the TREE pair before the build, only when it deploys" "$COLD_UNC" 'if $DO_DEPLOY; then mdx_note_bridge_posture_lag "${BUILD_POSTURE:-}" "${BUILD_BRIDGE_POSTURE:-}" tree; fi'
src_has "§6av: the banner asks the Bridge its posture (getDeployMode, --identity pinned)" "$COLD_UNC" \
  "LIVE_BRIDGE_POSTURE=\$(echo y | icp canister call bridge getDeployMode '()' --query --identity anonymous"
src_has "§6av: the banner prints the Bridge's live posture on its own line" "$COLD_UNC" 'echo "  Bridge  : ${LIVE_BRIDGE_POSTURE:-unresolved} (live getDeployMode)"'
src_has "§6av: the banner notes the LIVE pair" "$COLD_UNC" 'mdx_note_bridge_posture_lag "${LIVE_POSTURE:-}" "${LIVE_BRIDGE_POSTURE:-}" live'
COLD_BBP_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'BUILD_BRIDGE_POSTURE=$(mdx_posture_of' | head -1 | cut -d: -f1)
COLD_DEP2_LN=$(printf '%s\n' "$COLD_UNC" | grep -n 'icp deploy --identity' | head -1 | cut -d: -f1)
if [ -n "$COLD_BBP_LN" ] && [ -n "$COLD_DEP2_LN" ] && [ "$COLD_BBP_LN" -lt "$COLD_DEP2_LN" ]; then
  _ok "§6av: the Bridge tree read (line $COLD_BBP_LN) precedes the icp deploy ($COLD_DEP2_LN)"
else
  _fail "§6av: the Bridge tree read (${COLD_BBP_LN:-none}) does not precede the icp deploy (${COLD_DEP2_LN:-none}) — the note would fire after the wasm shipped"
fi
DEPLOY_UNC=$(uncommented scripts/deploy.sh)
src_has "§6av: deploy.sh local's seed branch is the cold_start site"    "$DEPLOY_UNC" 'exec bash scripts/cold_start.sh ${PASS[@]+"${PASS[@]}"}'
src_has "§6av: deploy.sh local's update branch is the cold_start site"  "$DEPLOY_UNC" 'exec bash scripts/cold_start.sh --no-seed ${PASS[@]+"${PASS[@]}"}'
# Behavioural: drive the helper through the four pairs. Only dev/play speaks,
# it names the three suites and the both-files pattern, and every call
# returns 0 — under cold_start's set -e a non-zero here would be a refusal.
LAG_OUT=$(bash -c '. scripts/lib/targets.sh; mdx_note_bridge_posture_lag dev play tree; echo "rc=$?"' 2>&1)
if printf '%s' "$LAG_OUT" | grep -qF 'BRIDGE POSTURE LAG'; then _ok "§6av: dev DEX / play Bridge prints the loud note (fixture)"
else _fail "§6av: the dev/play pair printed no note — got: $(printf '%s' "$LAG_OUT" | tr -d '\n' | head -c 200)"; fi
src_has "§6av: the note names the three Bridge dev-hook suites" "$LAG_OUT" 'test_bridge_deposit_claim §14-15, test_bridge_write_ahead §1-2 and test_season_wipe_fence §1-2'
src_has "§6av: the tree note carries the both-files flip pattern" "$LAG_OUT" "perl -pi -e 's/^(\\s*transient let DEPLOY_MODE : DeployMode = )#play;/\$1#dev;/' src/backend/main.mo src/bridge/main.mo"
src_has "§6av: the note says it is not a refusal (W3-09 direction)" "$LAG_OUT" 'Not refused: a Bridge LESS permissive than its DEX is the W3-09 direction'
src_has "§6av: the dev/play call returns 0" "$LAG_OUT" 'rc=0'
LAG_LIVE=$(bash -c '. scripts/lib/targets.sh; mdx_note_bridge_posture_lag dev play live' 2>&1)
src_has "§6av: the live note names the two getDeployMode answers" "$LAG_LIVE" 'live: backend getDeployMode = dev, bridge getDeployMode = play'
src_has "§6av: the live note points at the rhythm redeploy" "$LAG_LIVE" 'redeploy under the posture rhythm with BOTH literals flipped'
for pair in "dev/dev" "play/play" "play/dev" "production/production" "/"; do
  LAG_Q=$(bash -c '. scripts/lib/targets.sh; mdx_note_bridge_posture_lag "$1" "$2"; echo "rc=$?"' _ "${pair%%/*}" "${pair#*/}" 2>&1)
  if [ "$LAG_Q" = "rc=0" ]; then _ok "§6av: pair '$pair' is silent and returns 0"
  else _fail "§6av: pair '$pair' should be silent with rc=0 — got: $(printf '%s' "$LAG_Q" | tr -d '\n' | head -c 200)"; fi
done

# ── §6bd 1789047001: replica-doctor's age read fails LOUD (-1), never to a smaller number ─
# `replica-doctor.sh --rss` is the recycle budget's only age source: factory.sh
# claim refuses RECYCLE-REQUIRED once the seat's oldest main passes
# REPLICA_MAX_AGE_HOURS, and the skill calls that belt "the recycling
# guarantee" because the footprint metric can gap. On seat-1 the belt read
# `0h` against a 22h main and `24h` against a 43h one (2 of ~55 hourly
# samples): a DEGRADED `ps -o etime=` read - empty, or day-prefixed with a
# truncated remainder - parsed to 0 / a whole-day multiple, and the max over
# owned mains took it. Now: the parser is pure (etime_secs) and strict, the
# pid read retries 3x with a short sleep (age_read), an unparseable read is
# the -1 sentinel that keeps the previous best and prints a loud note, and
# the raw etime rides the TOTAL line ("22h [22:14:33]") so the next wobble is
# diagnosable from the one line seats already log. factory.sh's two sed
# shapes (`oldest main <n>h`, `is <n>h old`) are pinned byte-compatible.
DOCTOR_UNC=$(uncommented scripts/replica-doctor.sh)
src_has "§6bd: the doctor defines the pure etime parser"                    "$DOCTOR_UNC" 'etime_secs() {'
src_has "§6bd: ...and the retrying pid read that sets AGE_SECS/AGE_RAW"      "$DOCTOR_UNC" 'age_read() {'
src_has "§6bd: age_read gives up after 3 reads"                             "$DOCTOR_UNC" '[ "$try" -ge 3 ] && return 0'
src_has "§6bd: ...with a short sleep between reads"                         "$DOCTOR_UNC" 'sleep 0.2'
src_has "§6bd: the sentinel is -1, never 0"                                 "$DOCTOR_UNC" "printf -- '-1'; return"
src_lacks "§6bd: no arm of the parser prints 0 for an unreadable etime"     "$(printf '%s\n' "$DOCTOR_UNC" | sed -n '/^etime_secs() {/,/^}/p')" "printf '0'"
src_has "§6bd: the --rss loop keeps the previous best on an unreadable age"  "$DOCTOR_UNC" 'if [ "$a" -lt 0 ]; then'
src_has "§6bd: ...and says so loudly, with the raw read"                     "$DOCTOR_UNC" 'info "note: age of main PID $pid unreadable this pass (raw: '"'"'$AGE_RAW'"'"') after 3 ps reads - previous best kept, never a smaller number"'
src_has "§6bd: the TOTAL line carries the raw etime beside the hours"       "$DOCTOR_UNC" 'OLDEST_LABEL="$(( OLDEST_AGE / 3600 ))h [$OLDEST_RAW]"'
src_has "§6bd: the age-belt line keeps 'is <n>h old' first, raw after"      "$DOCTOR_UNC" 'info "is $(( OLDEST_AGE / 3600 ))h old [$OLDEST_RAW] - past the ${MAX_AGE_H}h AGE BELT'
src_has "§6bd: the start doctor never turns an unreadable age into WEDGED"  "$DOCTOR_UNC" 'if [ "$elapsed" -lt 0 ]; then'
src_has "§6bd: the lib seam stops before the arg parser"                    "$DOCTOR_UNC" 'if [ "${REPLICA_DOCTOR_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi'
FACTORY_UNC=$(uncommented scripts/factory.sh)
src_has "§6bd: factory.sh's claim gate still parses 'is <n>h old'"          "$FACTORY_UNC" "s/.*is \\([0-9][0-9]*\\)h old.*/\\1/p"
src_has "§6bd: ...and 'oldest main <n>h'"                                   "$FACTORY_UNC" "s/.*oldest main \\([0-9][0-9]*\\)h.*/\\1/p"
src_has "§6bd: ...and only acts on the doctor's exit 3"                     "$FACTORY_UNC" '3) : ;;          # the doctor'"'"'s explicit recycle verdict'
# Behavioural, no venue: the parser through the lib seam.
DR_LIB='REPLICA_DOCTOR_LIB=1 . scripts/replica-doctor.sh'
dr_parse() { bash -c "$DR_LIB; etime_secs \"\$1\"" _ "$1" 2>/dev/null; }
for pair in "01-19:22:50=156170" "22:14:33=80073" "05:07=307" "00:00=0" "=-1" "01-19=-1" "01-19:22=-1" "1:2:3:4=-1" "ab:cd=-1" "x-19:22:50=-1"; do
  want="${pair#*=}"; et="${pair%%=*}"; got="$(dr_parse "$et")"
  if [ "$got" = "$want" ]; then _ok "§6bd: etime_secs '$et' -> $want"
  else _fail "§6bd: etime_secs '$et' -> '$got', expected $want (a degraded read must be -1, a whole read exact)"; fi
done
DR_BOGUS="$(bash -c "$DR_LIB; age_secs 99998" 2>/dev/null)"
if [ "$DR_BOGUS" = "-1" ]; then _ok "§6bd: age_secs on a bogus pid yields the -1 sentinel, not 0"
else _fail "§6bd: age_secs on a bogus pid yielded '$DR_BOGUS' — an unreadable age must be -1, never a number the belt compares LOW"; fi
# The retry, under a PATH-stubbed ps: two empty reads then a whole one must
# parse on the third; three empty reads must be -1 after EXACTLY 3 calls.
DR_TMP=$(mktemp -d "${TEST_SCRATCH:-${TMPDIR:-/tmp}}/dr.XXXXXX")
cat > "$DR_TMP/ps" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$DR_COUNT" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s' "$n" > "$DR_COUNT"
case "$*" in
  "-o etime= -p "*) [ "$n" -ge "${DR_OK_AT:-99}" ] && printf ' 01-19:22:50\n' ;;
  *) exec /bin/ps "$@" ;;
esac
EOF
chmod +x "$DR_TMP/ps"
: > "$DR_TMP/count"
DR_RETRY="$(cd "$ROOT" && DR_COUNT="$DR_TMP/count" DR_OK_AT=3 PATH="$DR_TMP:$PATH" bash -c "$DR_LIB; age_read 12345; echo \"\$AGE_SECS \$AGE_RAW\"" 2>/dev/null)"
if [ "$DR_RETRY" = "156170 01-19:22:50" ] && [ "$(cat "$DR_TMP/count")" = "3" ]; then _ok "§6bd: age_read parses the third read after two empty ones (3 ps calls)"
else _fail "§6bd: age_read under a twice-degraded ps gave '$DR_RETRY' after $(cat "$DR_TMP/count") call(s) — expected '156170 01-19:22:50' on the third"; fi
: > "$DR_TMP/count"
DR_NEVER="$(cd "$ROOT" && DR_COUNT="$DR_TMP/count" DR_OK_AT=99 PATH="$DR_TMP:$PATH" bash -c "$DR_LIB; age_read 12345; echo \"\$AGE_SECS [\$AGE_RAW]\"" 2>/dev/null)"
if [ "$DR_NEVER" = "-1 []" ] && [ "$(cat "$DR_TMP/count")" = "3" ]; then _ok "§6bd: age_read is -1 with an empty raw after exactly 3 empty reads"
else _fail "§6bd: age_read under an always-empty ps gave '$DR_NEVER' after $(cat "$DR_TMP/count") call(s) — expected '-1 []' after exactly 3"; fi
[ -n "${TEST_SCRATCH:-}" ] || rm -rf "$DR_TMP"
# The exit-code contract, byte-compatible with factory.sh's parser: the
# regexes above, applied verbatim to the new line shapes, still yield the
# hours (and nothing for the UNREADABLE label, which factory.sh renders '?').
dr_age_of() { printf '%s\n' "$1" | sed -n -e 's/.*is \([0-9][0-9]*\)h old.*/\1/p' -e 's/.*oldest main \([0-9][0-9]*\)h.*/\1/p' | head -1; }
assert_eq "§6bd: factory.sh's parser reads the OVER line with the raw etime"  "22" "$(dr_age_of '  TOTAL: 3500 MB footprint - OVER the 3GB budget (oldest main 22h [22:14:33])')"
assert_eq "§6bd: ...and the age-belt line with the raw etime"                 "43" "$(dr_age_of '  is 43h old [01-19:22:50] - past the 48h AGE BELT (override REPLICA_MAX_AGE_HOURS; 0 disables).')"
assert_eq "§6bd: ...and yields nothing (-> ?) for an UNREADABLE label"        ""   "$(dr_age_of '  TOTAL: 3500 MB footprint - OVER the 3GB budget (oldest main UNREADABLE this pass (no owned main'"'"'s etime parsed - see the note above))')"
# Live smoke (read-only ps/lsof/top, no icp): whatever this worktree owns,
# --rss exits 0 or 3 - never 2 - and any TOTAL line carries a bracketed raw
# etime or the UNREADABLE label, never a bare hour.
DR_LIVE="$(cd "$ROOT" && bash scripts/replica-doctor.sh --rss "$ROOT" 2>&1)"; DR_RC=$?
case "$DR_RC" in 0|3) _ok "§6bd: --rss on this worktree exits $DR_RC (the 0/3 contract)" ;;
  *) _fail "§6bd: --rss on this worktree exited $DR_RC — factory.sh treats anything but 0/3 as a broken measurement: $(printf '%s' "$DR_LIVE" | tr '\n' '|' | head -c 300)" ;; esac
DR_TOTAL="$(printf '%s\n' "$DR_LIVE" | grep -E 'TOTAL:|is [0-9]+h old' | head -1)"
if [ -z "$DR_TOTAL" ]; then
  src_has "§6bd: no owned replica -> the doctor says so (nothing to measure)" "$DR_LIVE" 'no PocketIC instance owned by this worktree - nothing to measure'
elif printf '%s' "$DR_TOTAL" | grep -qE '[0-9]+h (old )?\[([0-9]+-)?[0-9]+:[0-9]+(:[0-9]+)?\]|UNREADABLE this pass'; then
  _ok "§6bd: the live age line carries the raw etime: $(printf '%s' "$DR_TOTAL" | sed 's/^ *//')"
else
  _fail "§6bd: the live age line has no bracketed raw etime: $DR_TOTAL"
fi

# ── §6be 1789609263: a controller-designated FUNDING AUTHORITY signs the fleet's refills ─
# The unattended launchd subnet fleet refilled its bots via `fund_call` =
# setTestBalance signed with the TARGET's controller identity — on the
# subnet the sole human-held controller of the live exchange, which
# therefore could not leave the keychain's unattended grant (task
# 1788467589) without silently breaking refills (`|| true`). Now: a
# controller designates ONE non-controller principal (`setFundingAuthority`,
# stable `_fundingAuthority`, #config on the tape) admitted to EXACTLY the
# two balance setters + the scoped getTestBalance read, on #play/#dev only
# (lib/Funding.mintAdmitted, exhaustive; tests/Funding.test.mo pins the
# #production refusal), inspect routes it to those two tags and nothing
# else; every refill path signs with MDX_FUNDING_IDENTITY (targets.sh
# resolves env → the target conf's SN_/CE_FUNDING_IDENTITY → the controller
# fallback, named LOUDLY) and no refill line names SN_IDENTITY / CE_IDENTITY
# / BOT_IDENTITY; whyAmIRefused names the role.
FUND_LIB="$(mo_code < src/backend/lib/Funding.mo)"
src_has "§6be: lib/Funding declares the mint verdict"                              "$FUND_LIB" 'public func mintAdmitted(posture : Posture, isController : Bool, isFundingAuthority : Bool) : Bool {'
src_has "§6be: ...#production never mints, whoever asks"                            "$(mo_func src/backend/lib/Funding.mo "func mintAdmitted(" | mo_code)" 'case (#production) { false };'
src_has "§6be: ...#play admits a controller or the authority"                       "$(mo_func src/backend/lib/Funding.mo "func mintAdmitted(" | mo_code)" 'case (#play)       { isController or isFundingAuthority };'
src_has "§6be: lib/Funding declares the designation verdict"                        "$FUND_LIB" 'public func designable(posture : Posture, isAnonymous : Bool) : Bool {'
src_has "§6be: ...the anonymous principal is never designable on #play"             "$(mo_func src/backend/lib/Funding.mo "func designable(" | mo_code)" 'case (#play)       { not isAnonymous };'
src_has "§6be: ...and nothing is designable on #production"                         "$(mo_func src/backend/lib/Funding.mo "func designable(" | mo_code)" 'case (#production) { false };'
[ -f tests/Funding.test.mo ] && _ok "§6be: tests/Funding.test.mo exists (mops test pins all three postures)" || _fail "§6be: tests/Funding.test.mo missing — the #production refusal and the anonymous refusal are unpinned"
src_has "§6be: the unit test pins the #production refusal for the authority"        "$(cat tests/Funding.test.mo)" 'not Funding.mintAdmitted(#production, false, true)'
AO_CODE="$(mo_code < src/backend/mixins/AdminOps.mo)"
src_has  "§6be: AdminOps receives the authority READER"                             "$AO_CODE" 'isFundingAuthority : Principal -> Bool,'
src_lacks "§6be: AdminOps no longer takes requireController (one gate, not two)"    "$AO_CODE" 'requireController'
src_has  "§6be: AdminOps' gate asks the lib verdict with the live posture"          "$AO_CODE" 'if (not Funding.mintAdmitted(posture, Principal.isController(caller), isFundingAuthority(caller))) {'
src_has  "§6be: ...and its refusal keeps the historical phrase suites grep"         "$AO_CODE" 'not a canister controller and not the designated funding authority'
src_has  "§6be: ...and names the designation path"                                  "$AO_CODE" 'a controller designates one via setFundingAuthority'
SET_FN_BE="$(mo_func src/backend/mixins/AdminOps.mo "func setTestBalance(" | mo_code)"
src_has  "§6be: setTestBalance gates through requireMinter"                         "$SET_FN_BE" 'requireMinter(msg.caller, "setTestBalance");'
SET_PROD_LN=$(printf '%s\n' "$SET_FN_BE" | grep -n 'setTestBalance is not available on #production' | head -1 | cut -d: -f1)
SET_MINT_LN=$(printf '%s\n' "$SET_FN_BE" | grep -n 'requireMinter(msg.caller' | head -1 | cut -d: -f1)
if [ -n "${SET_PROD_LN:-}" ] && [ -n "${SET_MINT_LN:-}" ] && [ "$SET_PROD_LN" -lt "$SET_MINT_LN" ]; then _ok "§6be: setTestBalance's #production trap precedes the caller gate (prod=$SET_PROD_LN gate=$SET_MINT_LN)"
else _fail "§6be: setTestBalance must trap on #production BEFORE asking who the caller is (prod=${SET_PROD_LN:-none} gate=${SET_MINT_LN:-none})"; fi
src_has  "§6be: bulkSetTestBalances gates through requireMinter"                    "$(mo_func src/backend/mixins/AdminOps.mo "func bulkSetTestBalances(" | mo_code)" 'requireMinter(msg.caller, "bulkSetTestBalances");'
src_has  "§6be: getTestBalance's scope admits the authority (the refill loop READS before it refills)" "$(mo_func src/backend/mixins/AdminOps.mo "func getTestBalance(" | mo_code)" 'or isFundingAuthority(msg.caller))) { return 0 };'
MAIN_CODE_BE="$(mo_code < src/backend/main.mo)"
src_has  "§6be: main.mo holds the authority as a STABLE ?Principal (survives upgrades)" "$MAIN_CODE_BE" 'var _fundingAuthority : ?Principal = null;'
src_lacks "§6be: ...never transient"                                                "$MAIN_CODE_BE" 'transient var _fundingAuthority'
src_has  "§6be: main.mo defines the reader the mixin and inspect share"             "$MAIN_CODE_BE" 'func isFundingAuthority(p : Principal) : Bool {'
SET_FA_FN="$(mo_func src/backend/main.mo "func setFundingAuthority(" | mo_code)"
[ -n "$SET_FA_FN" ] || _fail "§6be: could not extract setFundingAuthority()"
src_has  "§6be: setFundingAuthority is controller-only"                             "$SET_FA_FN" 'requireController(msg.caller);'
src_has  "§6be: ...refused by posture on #production"                               "$SET_FA_FN" 'setFundingAuthority is not available on #production'
src_has  "§6be: ...asks the lib whether the principal is designable (anonymous never)" "$SET_FA_FN" 'Funding.designable(DEPLOY_MODE, Principal.isAnonymous(a))'
src_has  "§6be: ...emits #config on the tape (the seventh authority setter)"        "$SET_FA_FN" 'emitConfig(msg.caller, "setFundingAuthority", v);'
src_has  "§6be: getFundingAuthority reads the designation back"                     "$MAIN_CODE_BE" 'public query func getFundingAuthority() : async ?Principal { _fundingAuthority };'
src_has  "§6be: inspect enumerates setFundingAuthority"                             "$INSPECT_FN" '#setFundingAuthority : Any'
src_has  "§6be: inspect enumerates getFundingAuthority"                             "$INSPECT_FN" '#getFundingAuthority : Any'
src_has  "§6be: inspect routes the authority AFTER the controller check"            "$INSPECT_FN" 'if (isFundingAuthority(caller)) {'
FA_ARM_TAGS=$(printf '%s\n' "$INSPECT_FN" | mo_code | sed -n '/if (isFundingAuthority(caller)) {/,/let key = Principal.toText(caller);/p' | grep -oE '#[A-Za-z0-9_]+' | tr -d '#' | sort -u | tr '\n' ' ' | sed 's/ $//')
assert_eq "§6be: the authority's inspect arm admits EXACTLY the two balance setters" "bulkSetTestBalances setTestBalance" "$FA_ARM_TAGS"
FA_CTRL_LN=$(printf '%s\n' "$INSPECT_FN" | mo_code | grep -n 'if (Principal.isController(caller)) { return true };' | head -1 | cut -d: -f1)
FA_ARM_LN=$(printf '%s\n' "$INSPECT_FN" | mo_code | grep -n 'if (isFundingAuthority(caller)) {' | head -1 | cut -d: -f1)
FA_POLICY_LN=$(printf '%s\n' "$INSPECT_FN" | mo_code | grep -n 'if (not callerAdmitted(caller, registered)) {' | head -1 | cut -d: -f1)
if [ -n "${FA_CTRL_LN:-}" ] && [ -n "${FA_ARM_LN:-}" ] && [ -n "${FA_POLICY_LN:-}" ] && [ "$FA_CTRL_LN" -lt "$FA_ARM_LN" ] && [ "$FA_ARM_LN" -lt "$FA_POLICY_LN" ]; then _ok "§6be: inspect orders controller → authority arm → the shared caller policy (ctrl=$FA_CTRL_LN arm=$FA_ARM_LN policy=$FA_POLICY_LN)"
else _fail "§6be: the authority arm must sit between the controller check and callerAdmitted — an unregistered authority is refused pre-consensus otherwise (ctrl=${FA_CTRL_LN:-none} arm=${FA_ARM_LN:-none} policy=${FA_POLICY_LN:-none})"; fi
src_has  "§6be: whyAmIRefused names the role"                                       "$(mo_func src/backend/main.mo "func whyAmIRefused(" | mo_code)" 'fundingAuthority = isFundingAuthority(msg.caller);'
src_has  "§6be: getApiDoc records the funding authority"                            "$MAIN_CODE_BE" 'FUNDING AUTHORITY (task 1789609263, 2026-09-17): a controller may designate ONE non-controller principal via setFundingAuthority(?principal)'
src_has  "§6be: the published candid carries setFundingAuthority"                   "$(cat candid/backend.did)" 'setFundingAuthority: (p: opt principal) -> ();'
src_has  "§6be: ...and getFundingAuthority"                                         "$(cat candid/backend.did)" 'getFundingAuthority: () -> (opt principal) query;'
src_has  "§6be: ...and whyAmIRefused's fundingAuthority field"                      "$(cat candid/backend.did)" 'fundingAuthority: bool;'
src_has  "§6be: deployment-modes kill-matrix carries the setter's row"              "$(cat docs/deployment-modes.md)" '| `setFundingAuthority(?principal)` / `getFundingAuthority` (task `1789609263`, keychain hardening F17) | ✅ | ✅ | ❌ |'
# The scripts: every refill signs with the FUNDING identity, resolved once.
TARGETS_UNC_BE=$(uncommented scripts/lib/targets.sh)
src_has "§6be: targets.sh defines the one funding-identity resolver"                "$TARGETS_UNC_BE" 'mdx_funding_identity_for() {'
src_has "§6be: ...the environment wins"                                             "$TARGETS_UNC_BE" 'if [ -n "${MDX_FUNDING_IDENTITY:-}" ]; then echo "$MDX_FUNDING_IDENTITY"; return 0; fi'
src_has "§6be: ...then the subnet conf's SN_FUNDING_IDENTITY"                       "$TARGETS_UNC_BE" 'echo "${SN_FUNDING_IDENTITY:-}" ;;'
src_has "§6be: ...then the engine conf's CE_FUNDING_IDENTITY"                       "$TARGETS_UNC_BE" 'echo "${CE_FUNDING_IDENTITY:-}" ;;'
FA_ENV="$(cd "$ROOT" && MDX_FUNDING_IDENTITY=fa-stub bash -c '. scripts/lib/targets.sh; mdx_funding_identity_for subnet' 2>/dev/null)"
assert_eq "§6be: MDX_FUNDING_IDENTITY in the environment resolves first (fixture)" "fa-stub" "$FA_ENV"
FA_LOCAL="$(cd "$ROOT" && env -u MDX_FUNDING_IDENTITY bash -c '. scripts/lib/targets.sh; mdx_funding_identity_for local' 2>/dev/null)"
assert_eq "§6be: local resolves to nothing (anonymous is its controller by construction)" "" "$FA_LOCAL"
BOTS_UNC_BE=$(uncommented scripts/lib/bots.sh)
src_has "§6be: bots.sh resolves the funding identity once per start"                "$BOTS_UNC_BE" 'local funding; funding=$(mdx_funding_identity_for "$target")'
src_has "§6be: ...verifies a configured one is usable before launching"             "$BOTS_UNC_BE" 'icp identity principal --identity "$funding" >/dev/null 2>&1'
src_has "§6be: ...and names the controller fallback LOUDLY"                         "$BOTS_UNC_BE" 'refills will sign as the CONTROLLER identity'
assert_eq "§6be: both remote launch lines hand MDX_FUNDING_IDENTITY to the engine" "2" "$(printf '%s\n' "$BOTS_UNC_BE" | grep -c 'MDX_FUNDING_IDENTITY="$funding"')"
assert_eq "§6be: ...beside BOT_IDENTITY on the same two lines"                    "2" "$(printf '%s\n' "$BOTS_UNC_BE" | grep -c 'BOT_IDENTITY="$identity" MDX_FUNDING_IDENTITY="$funding"')"
for SIM in scripts/sim_trading.sh scripts/trading_simulation.sh; do
  SIM_UNC=$(uncommented "$SIM")
  src_has "§6be: $SIM resolves FUND_IDENTITY from MDX_FUNDING_IDENTITY, the controller only as the fallback" "$SIM_UNC" 'if $REMOTE; then FUND_IDENTITY="${MDX_FUNDING_IDENTITY:-$CE_IDENTITY}"'
  src_has "§6be: $SIM local funds as anonymous unless overridden"                   "$SIM_UNC" 'FUND_IDENTITY="${MDX_FUNDING_IDENTITY:-anonymous}"; fi'
  FUND_BODY=$(printf '%s\n' "$SIM_UNC" | sed -n '/^fund_call() {/,/^}/p')
  BAL_BODY=$(printf '%s\n' "$SIM_UNC" | sed -n '/^bal_of() {/,/^}/p')
  [ -n "$FUND_BODY" ] || _fail "§6be: could not extract fund_call() from $SIM"
  [ -n "$BAL_BODY" ]  || _fail "§6be: could not extract bal_of() from $SIM"
  for BAD in CE_IDENTITY SN_IDENTITY BOT_IDENTITY anonymous_only_marker; do
    [ "$BAD" = anonymous_only_marker ] && continue
    src_lacks "§6be: $SIM fund_call never names $BAD"                               "$FUND_BODY" "$BAD"
    src_lacks "§6be: $SIM bal_of never names $BAD"                                  "$BAL_BODY"  "$BAD"
  done
  src_has "§6be: $SIM fund_call signs as FUND_IDENTITY"                             "$FUND_BODY" 'FUND_IDENTITY'
  src_has "§6be: $SIM bal_of reads as FUND_IDENTITY (mint AND read, or the loop refills forever)" "$BAL_BODY" 'FUND_IDENTITY'
  # No setTestBalance line anywhere in the engine names a controller variable.
  grep_scan SIM_REFILL_LINES "$SIM_UNC" 'setTestBalance'
  grep_filter -k SIM_REFILL_LINES 'CE_IDENTITY|SN_IDENTITY|BOT_IDENTITY'
  [ -z "$SIM_REFILL_LINES" ] && _ok "§6be: no setTestBalance line in $SIM names SN_/CE_/BOT_IDENTITY" || _fail "§6be: $SIM still signs a refill with a controller variable: $(printf '%s' "$SIM_REFILL_LINES" | head -c 200)"
done
DEPLOY_UNC_BE=$(uncommented scripts/deploy.sh)
src_has "§6be: deploy.sh's engine conf carries CE_FUNDING_IDENTITY across re-deploys" "$DEPLOY_UNC_BE" 'CE_FUNDING_IDENTITY=%q'
src_has "§6be: deploy.sh's subnet conf carries SN_FUNDING_IDENTITY across re-deploys" "$DEPLOY_UNC_BE" 'SN_FUNDING_IDENTITY=%q'
src_has "§6be: ...and load_subnet_conf initialises it (set -u)"                     "$DEPLOY_UNC_BE" 'SN_FUNDING_IDENTITY=""'
CB_BODY=$(printf '%s\n' "$DEPLOY_UNC_BE" | sed -n '/^cloud_bots() {/,/^}/p')
[ -n "$CB_BODY" ] || _fail "§6be: could not extract cloud_bots() from deploy.sh"
src_has  "§6be: cloud_bots resolves its funding identity env → conf → controller fallback" "$CB_BODY" 'local cb_fund="${MDX_FUNDING_IDENTITY:-${CE_FUNDING_IDENTITY:-$CE_IDENTITY}}"'
src_has  "§6be: cloud_bots names the controller fallback loudly"                    "$CB_BODY" 'refills sign as the CONTROLLER'
src_lacks "§6be: no cloud_bots refill signs with CE_IDENTITY directly"              "$(printf '%s\n' "$CB_BODY" | grep setTestBalance)" '--identity "$CE_IDENTITY"'
src_has  "§6be: cloud_bots pre-funds as the resolved funding identity"              "$(printf '%s\n' "$CB_BODY" | grep setTestBalance)" '--identity "$cb_fund"'
src_has  "§6be: cloud_bots hands the same identity to the engine it launches"       "$CB_BODY" 'MDX_FUNDING_IDENTITY="$cb_fund" nohup bash scripts/sim_trading.sh'

# ── §6bf · Release version agreement (task 1793461377 — 2.0.0, 2026-10-31) ──
# The product version lives in THREE places that must agree: package.json's
# "version" (vite bakes it into the bundle as __APP_VERSION__, the build-time
# loading-page badge and /version.json), package-lock.json's root record (the
# next `npm install` rewrites it otherwise), and main.mo's APP_VERSION (the
# backend's diagnostic half — getAppVersion / getCanisterInfo.appVersion — so
# a mixed frontend/backend deploy is visible). Nothing pinned them before
# 2.0.0: 1.60.0 sat on the loading page for twelve weeks of shipped change,
# and the 2.0.0 brief assumed a pin that did not exist. Also pinned: the
# badge text is `VERSION <x.y>` with ONLY a trailing ".0" stripped, at both
# stamp sites (the build injection and the runtime re-stamp write identical
# text), so "2.0.0" reads "2.0" and never "2".
PKG_VER=$(sed -n 's/^  "version": "\([^"]*\)",$/\1/p' package.json | head -1)
LOCK_TOP_VER=$(sed -n '1,12p' package-lock.json | sed -n 's/^  "version": "\([^"]*\)",$/\1/p' | head -1)
LOCK_ROOT_VER=$(sed -n '1,12p' package-lock.json | sed -n 's/^      "version": "\([^"]*\)",$/\1/p' | head -1)
MO_VER=$(sed -n 's/^  transient let APP_VERSION : Text = "\([^"]*\)";$/\1/p' src/backend/main.mo | head -1)
[ -n "$PKG_VER" ] || _fail "§6bf: could not read package.json's version"
[ -n "$MO_VER" ]  || _fail "§6bf: could not read main.mo's APP_VERSION literal"
assert_eq "§6bf: main.mo APP_VERSION agrees with package.json's version"             "$PKG_VER" "$MO_VER"
assert_eq "§6bf: package-lock.json's top-level version agrees with package.json"     "$PKG_VER" "$LOCK_TOP_VER"
assert_eq "§6bf: package-lock.json's root package record agrees with package.json"   "$PKG_VER" "$LOCK_ROOT_VER"
case "$PKG_VER" in
  *.*.*) _ok "§6bf: the version is three-part x.y.z ($PKG_VER) — the badge strips one trailing .0" ;;
  *)     _fail "§6bf: the version must be x.y.z (got '$PKG_VER'): the badge regexp strips exactly one trailing .0" ;;
esac
src_has "§6bf: vite's build-time badge strips exactly one trailing .0"                "$(cat vite.config.mjs)" 'const badge = `VERSION ${APP_VERSION.replace(/\.0$/, "")}`;'
src_has "§6bf: main.js's runtime re-stamp writes the identical text"                 "$(cat src/frontend/src/main.js)" 'el.textContent = "VERSION " + APP_VERSION.replace(/\.0$/, "");'
src_has "§6bf: index.html keeps the EMPTY badge span the build fills (its contract)" "$(cat src/frontend/index.html)" '<span class="app-version"></span>'

# ── §6bh 1793552080: the remote FULL path REFUSES a reinstall among the forwarded args; frontend-only and local keep theirs ──
# `deploy.sh engine|subnet` (remote_deploy) forwards every extra argument
# `${PASS[@]}` to EACH of its four `icp deploy` calls, and nothing guarded a
# reinstall riding there: `bash scripts/deploy.sh subnet --mode reinstall` —
# one word short of the frontend-only form that task 1793503326 made the ONE
# legal remote reinstall (a frontend still on the legacy asset-canister wasm)
# — would have reinstalled the production backend, bridge and arb: every
# balance, order, position and the live tape. deploy.sh now refuses every
# spelling icp accepts (`--mode reinstall`, `-m reinstall`, `--mode=reinstall`,
# `-mreinstall` — `icp deploy --help`, clap; the value is case-sensitive) on
# the full path, BEFORE gen-did, the posture gate and any icp call, naming the
# cure; the frontend-only form and `local` (cold_start / play_start reinstall
# deliberately) are untouched. Static pins first; then the real deploy.sh is
# DRIVEN inside a throwaway copy of the tree (the H-02 harness's shape: a #play
# fixture main.mo, a stub gen-did.sh and cold_start.sh, fake conf files that
# exist ONLY in the copy — never the primary's — and FACTORY_WORKER unset so
# the seat belt is not what refuses) against a recording icp stub that answers
# the reads and REFUSES every deploy (exit 9) unless a case opts in: no remote
# is ever touched (law 8). The control (an upgrade walks through the pre-flight
# to the stubbed backend deploy) and the negative control (the copy with the
# guard's die stripped reaches the backend deploy WITH the reinstall) prove the
# refusals are the guard's and that the probe sees the bug it pins.
DEPLOY_UNC_BG="$(uncommented scripts/deploy.sh)"
src_has "§6bh: deploy.sh defines the reinstall-spelling reader, marked pure (prints the spelling, never fails)" "$DEPLOY_UNC_BG" 'pass_reinstall_spelling() {  # pure:'
src_has "§6bh: ...which reads icp's one-word forms as single arguments"            "$DEPLOY_UNC_BG" '--mode=reinstall|-mreinstall) printf'
src_has "§6bh: ...and the two-word forms as two adjacent arguments"                "$DEPLOY_UNC_BG" 'reinstall) case "$prev" in --mode|-m) printf'
src_has "§6bh: the guard keys on the remote FULL path only — frontend-only excluded by construction, local and plain untouched" "$DEPLOY_UNC_BG" 'if ! $FRONTEND_ONLY && { [ "$TARGET" = "engine" ] || [ "$TARGET" = "subnet" ]; }; then'
src_has "§6bh: the guard reads the forwarded arguments through the reader"         "$DEPLOY_UNC_BG" 'REINSTALL_SPELLING="$(pass_reinstall_spelling ${PASS[@]+"${PASS[@]}"})"'
src_has "§6bh: the refusal names the cure (the stateless frontend-only form) and what a reinstall wipes" "$DEPLOY_UNC_BG" 'scripts/deploy.sh $TARGET frontend --mode reinstall (the backend, bridge and arb hold state; a reinstall wipes it'
src_has "§6bh: the frontend-only deploy still forwards the extra arguments (the cure rides them)" "$DEPLOY_UNC_BG" 'icp deploy frontend -e "$FO_ENV" ${FO_SUBNET[@]+"${FO_SUBNET[@]}"} ${FO_MODE[@]+"${FO_MODE[@]}"} --identity "$FO_ID" ${PASS[@]+"${PASS[@]}"}'
BG_GUARD_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -nF -- 'REINSTALL_SPELLING="$(pass_reinstall_spelling' | head -1 | cut -d: -f1)"
BG_GENDID_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -nF -- 'bash scripts/gen-did.sh' | head -1 | cut -d: -f1)"
BG_DEPLOY_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | code_only | grep -nF -- 'icp deploy ' | head -1 | cut -d: -f1)"
if [ -n "$BG_GUARD_LN" ] && [ -n "$BG_GENDID_LN" ] && [ -n "$BG_DEPLOY_LN" ] && [ "$BG_GUARD_LN" -lt "$BG_GENDID_LN" ] && [ "$BG_GUARD_LN" -lt "$BG_DEPLOY_LN" ]; then
  _ok "§6bh: the guard (line $BG_GUARD_LN) precedes gen-did (line $BG_GENDID_LN) and the first icp deploy in code (line $BG_DEPLOY_LN)"
else _fail "§6bh: the guard (line '${BG_GUARD_LN:-none}') must precede gen-did (line '${BG_GENDID_LN:-none}') and the first icp deploy in code (line '${BG_DEPLOY_LN:-none}') — after gen-did the refusal is no longer the only line printed; after a deploy it is no guard"; fi
RI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/reinst6bh.XXXXXX")"
RI_REPO="$RI_TMP/repo"; RI_LOG="$RI_TMP/calls.log"
mkdir -p "$RI_REPO/scripts/lib" "$RI_REPO/src/backend" "$RI_REPO/src/bridge" "$RI_REPO/.icp/data/mappings" "$RI_TMP/bin"
cp scripts/deploy.sh scripts/factory_guard.sh "$RI_REPO/scripts/"
cp scripts/lib/*.sh "$RI_REPO/scripts/lib/"
cp .icp/data/mappings/subnet.ids.json .icp/data/mappings/engine.ids.json "$RI_REPO/.icp/data/mappings/"
printf '#!/bin/bash\nexit 0\n' > "$RI_REPO/scripts/gen-did.sh"
printf '#!/bin/bash\necho "RI-COLD-START-REACHED $*"\n' > "$RI_REPO/scripts/cold_start.sh"
for f in src/backend/main.mo src/bridge/main.mo; do
  printf 'actor {\n  public type DeployMode = { #dev; #play; #production };\n  transient let DEPLOY_MODE : DeployMode = #play;\n  transient let IS_PRODUCTION : Bool = DEPLOY_MODE == #production;\n  transient let IS_DEV : Bool = DEPLOY_MODE == #dev;\n}\n' > "$RI_REPO/$f"
done
printf "SN_IDENTITY=ri-stub-wallet\nSN_SUBNET=ri-stub-subnet\nSN_FRONTEND_ORIGINS=''\n" > "$RI_REPO/scripts/.subnet.conf"
printf "CE_IDENTITY=ri-stub-engine\nCE_SUBNET=ri-stub-engine-subnet\nCE_CONSOLE=https://console.invalid\nCE_FRONTEND_ORIGINS=''\n" > "$RI_REPO/scripts/.cloud-engine.conf"
cat > "$RI_TMP/bin/icp" <<'RIEOF'
#!/bin/bash
# Recording icp stub (the H-02 harness's shape). Identity and status READS
# answer from the copy's own mapping with the live controller shape — the
# deployer plus the extras pinned for (env, canister) in the copied
# targets.sh — so the pre-flight passes; a canister call answers exit 1
# ("not the legacy wasm", the frontend-only legacy probe) or exit 0 under
# RI_LEGACY=1; every deploy is logged and REFUSED (exit 9) unless
# RI_DEPLOY_RC=0 lets a frontend-only run complete. No remote is touched.
printf '%s\n' "$*" >> "$RI_LOG"
name=""; env=""; prev=""
for a in "$@"; do
  case "$a" in backend|bridge|arb|frontend) name="$a" ;; esac
  case "$prev" in -e|--environment) env="$a" ;; esac
  prev="$a"
done
case "$1 $2" in
  "identity principal") echo "ri-stub-principal-aaaaa-aa" ;;
  "canister status")
    id="$(sed -n "s/.*\"$name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$RI_REPO/.icp/data/mappings/${env:-subnet}.ids.json")"
    extras="$( . "$RI_REPO/scripts/lib/targets.sh" >/dev/null 2>&1; mdx_expected_extra_controllers "${env:-subnet}" "$name" )"
    printf 'Canister Id: %s\nCanister Name: %s\nCanister Status Report:\n  Status: Running\n  Controllers: %s\n  Memory Size: 1\n' "$id" "$name" "ri-stub-principal-aaaaa-aa${extras:+ $extras}" ;;
  "canister call") [ "${RI_LEGACY:-0}" = 1 ] && exit 0; exit 1 ;;
  "deploy "*) [ "${RI_DEPLOY_RC:-9}" = 0 ] && exit 0; echo "icp stub: FORBIDDEN remote act attempted: icp $*" >&2; exit 9 ;;
  *) exit 0 ;;
esac
RIEOF
chmod +x "$RI_TMP/bin/icp"
ri_run() {  # ri_run <deploy.sh args…> → $out, $rc, $saw (the stub log, one line): the real deploy.sh inside the copy, FACTORY_WORKER unset so the seat belt is not what refuses
  : > "$RI_LOG"
  out="$(cd "$RI_REPO" && env -u FACTORY_WORKER -u FACTORY_FORCE -u DEPLOY_TARGET PATH="$RI_TMP/bin:$PATH" RI_LOG="$RI_LOG" RI_REPO="$RI_REPO" \
        RI_DEPLOY_RC="${RI_DEPLOY_RC:-9}" RI_LEGACY="${RI_LEGACY:-0}" SEED=false RUN_BOTS=false bash scripts/deploy.sh "$@" </dev/null 2>&1)"; rc=$?
  saw="$(tr '\n' ';' < "$RI_LOG")"
}
# (1) the FULL path, every spelling icp accepts: exit non-zero, NO icp deploy stub-called, the cure in the message
for sp in "--mode reinstall" "-m reinstall" "--mode=reinstall" "-mreinstall"; do
  # shellcheck disable=SC2086 — the two-word spellings must arrive as two arguments, exactly as an operator's shell delivers them
  ri_run subnet $sp
  if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' \
     && printf '%s\n' "$out" | grep -cF -- "scripts/deploy.sh subnet frontend --mode reinstall" >/dev/null \
     && printf '%s\n' "$out" | grep -cF -- "hold state; a reinstall wipes it" >/dev/null; then
    _ok "§6bh: deploy.sh subnet $sp is REFUSED (exit $rc) before any icp deploy, naming the frontend-only cure (icp saw: ${saw:-nothing})"
  else _fail "§6bh: deploy.sh subnet $sp must be refused before any icp deploy, naming the cure: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
done
# ...and the dry read prints the refusal ALONE: no gen-did line, no posture line, no icp call at all
ri_run subnet --mode reinstall
BG_LINES="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$rc" -ne 0 ] && [ "${BG_LINES:-0}" -eq 1 ] && [ ! -s "$RI_LOG" ] && printf '%s\n' "$out" | grep -cF -- "REFUSING 'deploy.sh subnet' with '--mode reinstall'" >/dev/null; then
  _ok "§6bh: the dry read of 'deploy.sh subnet --mode reinstall' prints the refusal and nothing else, and icp is never invoked"
else _fail "§6bh: the dry read of 'deploy.sh subnet --mode reinstall' should print the refusal alone before any icp call: exit $rc, ${BG_LINES:-?} line(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
ri_run engine --mode reinstall
if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' && printf '%s\n' "$out" | grep -cF -- "scripts/deploy.sh engine frontend --mode reinstall" >/dev/null; then
  _ok "§6bh: deploy.sh engine --mode reinstall is REFUSED the same way, the cure naming engine (icp saw: ${saw:-nothing})"
else _fail "§6bh: deploy.sh engine --mode reinstall must be refused before any icp deploy, the cure naming engine: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# control: an UPGRADE on the same path walks through the pre-flight to the (stubbed, refused) backend deploy — the refusals above are the guard's, not an earlier gate's
ri_run subnet --mode upgrade
if [ "$rc" -ne 0 ] && grep_has "$(cat "$RI_LOG")" '^canister status backend' && grep_has "$(cat "$RI_LOG")" '^deploy backend .* --mode upgrade$' \
   && printf '%s\n' "$out" | grep -cF -- "Backend deploy failed" >/dev/null && ! printf '%s\n' "$out" | grep -cF -- "REFUSING 'deploy.sh" >/dev/null; then
  _ok "§6bh control: deploy.sh subnet --mode upgrade passes the guard and the pre-flight and reaches the (stubbed, refused) backend deploy carrying --mode upgrade"
else _fail "§6bh control: deploy.sh subnet --mode upgrade should reach the backend deploy through the guard: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# negative control: the copy with the guard's die stripped runs the SAME mistype to the backend deploy WITH the reinstall — the wipe the guard exists for; the probe sees it
sed 's/^  \[ -z "\$REINSTALL_SPELLING" \] || die .*$/  : # 6bh negative control: the guard is stripped here/' scripts/deploy.sh > "$RI_REPO/scripts/deploy.sh"
if cmp -s scripts/deploy.sh "$RI_REPO/scripts/deploy.sh"; then _fail "§6bh negative control: stripping the guard changed nothing — its die line moved or was reworded; the control tests nothing"
else
  ri_run subnet --mode reinstall
  if [ "$rc" -ne 0 ] && grep_has "$(cat "$RI_LOG")" '^deploy backend .* --mode reinstall$' && ! printf '%s\n' "$out" | grep -cF -- "REFUSING 'deploy.sh" >/dev/null; then
    _ok "§6bh negative control: with the guard stripped, deploy.sh subnet --mode reinstall reaches the (stubbed, refused) backend deploy CARRYING --mode reinstall — the probe sees the wipe it pins"
  else _fail "§6bh negative control: with the guard stripped the run should reach the backend deploy with the reinstall: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
fi
cp scripts/deploy.sh "$RI_REPO/scripts/deploy.sh"
# (2) the frontend-only form — the ONE legal remote reinstall — still reaches exactly one icp deploy, the frontend's, carrying the reinstall, and completes
RI_DEPLOY_RC=0 ri_run subnet frontend --mode reinstall
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy frontend -e subnet --subnet ri-stub-subnet --identity ri-stub-wallet --mode reinstall$' \
   && printf '%s\n' "$out" | grep -cF -- "Frontend synced" >/dev/null; then
  _ok "§6bh: deploy.sh subnet frontend --mode reinstall still reaches exactly one icp deploy — frontend, carrying --mode reinstall — and completes"
else _fail "§6bh: the frontend-only form must reach exactly one icp deploy frontend with the reinstall and complete: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
RI_DEPLOY_RC=0 RI_LEGACY=1 ri_run subnet frontend --mode reinstall
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy frontend -e subnet --subnet ri-stub-subnet --identity ri-stub-wallet --mode reinstall$' \
   && printf '%s\n' "$out" | grep -cF -- "reinstalling it as requested (--mode reinstall)" >/dev/null; then
  _ok "§6bh: ...and on a frontend still on the legacy asset-canister wasm (task 1793503326's case) the same form forwards the operator's reinstall once, the legacy note printed"
else _fail "§6bh: the legacy-wasm frontend-only form must forward the reinstall once with the legacy note: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
RI_DEPLOY_RC=0 ri_run engine frontend --mode reinstall
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy frontend -e engine --subnet ri-stub-engine-subnet --identity ri-stub-engine --mode reinstall$'; then
  _ok "§6bh: deploy.sh engine frontend --mode reinstall reaches exactly one icp deploy frontend carrying the reinstall too"
else _fail "§6bh: the engine frontend-only form must reach exactly one icp deploy frontend with the reinstall: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# (3) local is unchanged: the reinstall rides to cold_start (the local deploys — cold_start / play_start reinstall deliberately)
ri_run local --mode reinstall
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -cF -- "RI-COLD-START-REACHED --no-seed --mode reinstall" >/dev/null && ! printf '%s\n' "$out" | grep -cF -- "REFUSING 'deploy.sh" >/dev/null; then
  _ok "§6bh: deploy.sh local --mode reinstall is unchanged — it reaches cold_start with the reinstall forwarded"
else _fail "§6bh: deploy.sh local --mode reinstall must reach cold_start with the reinstall forwarded, unrefused: exit $rc — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi

# ── §6bi 1793553523: the legacy PLAIN passthrough REFUSES a reinstall aimed at engine/subnet unless the ONLY canister named is `frontend` ──
# With no target keyword and a non-empty PASS, deploy.sh sets TARGET=plain and
# the plain block ends in `exec icp deploy ${PASS[@]}` — the caller spells the
# whole icp command — a door 1793552080's full-path guard deliberately left
# alone. Through it, `deploy.sh --environment=subnet --mode reinstall` (NO
# canister named: icp reinstalls EVERY canister on the production stack) and
# `deploy.sh backend -esubnet -m reinstall` (the backend alone) wiped every
# balance, order, position and the live tape. (At 1793553523 the two-word
# `-e subnet` never reached the door: the argument parser read a bare
# `subnet`/`engine` ANYWHERE in argv as the target keyword and routed the rest
# to the FULL path, whose guard refused the reinstall. Since task 1793556403
# the parser forwards a valued flag's VALUE instead — `-e subnet`, `--identity
# local`, `-ye subnet` are the pair the caller spelled, never a keyword — so
# every clap spelling reaches the door; the parser is pinned, sliced and
# driven at the end of this section.) deploy.sh now reads
# PASS with three pure readers — pass_remote_env (every clap spelling of
# -e/--environment: two words, `--environment=X`, `-e=X`, `-eX`, `-e` folded
# behind -y, and the ICP_ENVIRONMENT variable clap reads when the flag is
# absent), pass_reinstall_spelling (now also `-m=reinstall` — clap strips the
# `=` after a short flag; measured: icp 1.6.0 rejects `-m=REINSTALLX` as the
# VALUE 'REINSTALLX' — and the `-ym` cluster forms; the full path inherits
# both) and pass_canister_names (icp's positionals: not a flag, not a valued
# flag's value, everything after `--`; none = ALL) — and refuses, beside the
# full-path guard and BEFORE gen-did and the posture gate (a plain run prints
# gen-did's line and the posture's ✓ before the plain block is even reached, so
# a guard inside the block could never print the refusal alone), unless the
# names are exactly `frontend`. The plain block's zombie-network check keys on
# the same read (the inline grep it replaces missed the attached spellings).
# Static pins; the three readers sliced out of deploy.sh and driven directly;
# then §6bh's harness drives the real deploy.sh through the plain door.
src_has "§6bi: deploy.sh defines the remote-environment reader, marked pure (prints subnet|engine, never fails)" "$DEPLOY_UNC_BG" 'pass_remote_env() {  # pure:'
src_has "§6bi: ...which reads clap's attached long form"                                        "$DEPLOY_UNC_BG" '--environment=*) env="${n#--environment=}" ;;'
src_has "§6bi: ...the attached short forms (-e=X, -eX)"                                        "$DEPLOY_UNC_BG" '-e?*)            env="${n#-e}" ;;'
src_has "§6bi: ...the two-word forms"                                                           "$DEPLOY_UNC_BG" '*) case "$prev" in -e|--environment) env="$a" ;; esac ;;'
src_has "§6bi: ...and falls back to the ICP_ENVIRONMENT variable clap reads when the flag is absent" "$DEPLOY_UNC_BG" '[ -n "$env" ] || env="${ICP_ENVIRONMENT:-}"'
src_has "§6bi: ...answering only the two remote stacks"                                         "$DEPLOY_UNC_BG" 'case "$env" in subnet|engine) printf '"'"'%s'"'"' "$env" ;; esac'
src_has "§6bi: deploy.sh defines the canister-names reader, marked pure"                        "$DEPLOY_UNC_BG" 'pass_canister_names() {  # pure:'
src_has "§6bi: ...which skips the value of every valued flag icp deploy 1.6.0 has"              "$DEPLOY_UNC_BG" '-m|--mode|-e|--environment|--subnet|--proxy|--controller|--cycles|--args|--args-file|--args-format|--identity|--project-root-override) : ;;'
src_has "§6bi: the reinstall reader gained clap's fifth spelling, -m=reinstall"                 "$DEPLOY_UNC_BG" '-m=reinstall) printf '"'"'%s'"'"' "$a"; return 0 ;;'
src_has "§6bi: ...and the short-cluster read all three readers share (-ym reinstall / -ymreinstall / -ym=reinstall; -yesubnet)" "$DEPLOY_UNC_BG" 'n="${a#-}"; n="-${n#"${n%%[!yh]*}"}"; [ "$n" != "-" ] || n="$a" ;;'
src_has "§6bi: the plain guard reads the remote environment through the shared reader"          "$DEPLOY_UNC_BG" 'PLAIN_ENV="$(pass_remote_env ${PASS[@]+"${PASS[@]}"})"'
src_has "§6bi: ...the reinstall spelling through the full path's"                                "$DEPLOY_UNC_BG" 'PLAIN_REINSTALL="$(pass_reinstall_spelling ${PASS[@]+"${PASS[@]}"})"'
src_has "§6bi: ...and the names through theirs"                                                 "$DEPLOY_UNC_BG" 'PLAIN_NAMES="$(pass_canister_names ${PASS[@]+"${PASS[@]}"})"'
src_has "§6bi: ...passing exactly \`frontend\` alone"                                           "$DEPLOY_UNC_BG" 'frontend) : ;;   # the ONE legal remote reinstall through this door: the stateless frontend, alone'
src_has "§6bi: the refusal names both cures — the guided frontend-only form and the attached-environment plain form" "$DEPLOY_UNC_BG" 'scripts/deploy.sh $PLAIN_ENV frontend --mode reinstall (the guided frontend-only form), or through this door scripts/deploy.sh frontend --environment=$PLAIN_ENV --mode reinstall --identity <controller>'
src_has "§6bi: ...and what a reinstall wipes"                                                   "$DEPLOY_UNC_BG" 'the backend, bridge and arb hold state; a reinstall wipes it — every balance, order, position and the live tape). Nothing was deployed." ;;'
src_has "§6bi: the plain block's zombie-network check keys on the same read"                    "$DEPLOY_UNC_BG" 'if [ -z "$PLAIN_ENV" ]; then'
src_lacks "§6bi: ...the inline grep that missed the attached spellings is gone"                  "$DEPLOY_UNC_BG" "grep -qE '(-e|--environment) *(subnet|engine)"
PL_GUARD_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -nF -- 'PLAIN_ENV="$(pass_remote_env' | head -1 | cut -d: -f1)"
PL_ZOMBIE_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -nF -- 'for pid in $(mdx_stray_masters || true); do' | head -1 | cut -d: -f1)"
PL_EXEC_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -nF -- 'exec icp deploy ${PASS[@]+"${PASS[@]}"}' | head -1 | cut -d: -f1)"
if [ -n "$PL_GUARD_LN" ] && [ -n "$BG_GENDID_LN" ] && [ -n "$PL_ZOMBIE_LN" ] && [ -n "$PL_EXEC_LN" ] \
   && [ "$PL_GUARD_LN" -lt "$BG_GENDID_LN" ] && [ "$BG_GENDID_LN" -lt "$PL_ZOMBIE_LN" ] && [ "$PL_ZOMBIE_LN" -lt "$PL_EXEC_LN" ]; then
  _ok "§6bi: the plain guard (line $PL_GUARD_LN) precedes gen-did (line $BG_GENDID_LN), which precedes the plain block's zombie check (line $PL_ZOMBIE_LN) and its exec (line $PL_EXEC_LN) — the refusal is the only line a refused run prints"
else _fail "§6bi: the plain guard (line '${PL_GUARD_LN:-none}') must precede gen-did (line '${BG_GENDID_LN:-none}'), the plain block's zombie check (line '${PL_ZOMBIE_LN:-none}') and its exec (line '${PL_EXEC_LN:-none}') — inside the plain block the refusal would follow gen-did's and the posture gate's lines"; fi
# the three readers, sliced out of deploy.sh by their column-0 definitions and driven directly (the §6ap mdx_stray_masters idiom); ICP_ENVIRONMENT unset unless a case sets it
for fn in pass_reinstall_spelling pass_remote_env pass_canister_names; do
  awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^\}/ {p=0}' scripts/deploy.sh
done > "$RI_TMP/readers.sh"
grep_count n "$(cat "$RI_TMP/readers.sh")" '^(pass_reinstall_spelling|pass_remote_env|pass_canister_names)\(\) \{'
assert_eq "§6bi: the three readers slice out of deploy.sh by name (definitions found)" 3 "$n"
ri_rd()  { env -u ICP_ENVIRONMENT bash -c '. "$1"; fn="$2"; shift 2; "$fn" "$@"' _ "$RI_TMP/readers.sh" "$@"; }   # ri_rd <reader> <icp deploy args…> → what the reader prints
ri_rde() { local e="$1"; shift; ICP_ENVIRONMENT="$e" bash -c '. "$1"; fn="$2"; shift 2; "$fn" "$@"' _ "$RI_TMP/readers.sh" "$@"; }   # ri_rde <ICP_ENVIRONMENT value> <reader> <args…>
assert_eq "§6bi reader: pass_reinstall_spelling --mode reinstall"                                              '--mode reinstall' "$(ri_rd pass_reinstall_spelling --mode reinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling -m reinstall"                                                  '-m reinstall'     "$(ri_rd pass_reinstall_spelling -m reinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling --mode=reinstall"                                              '--mode=reinstall' "$(ri_rd pass_reinstall_spelling --mode=reinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling -m=reinstall (clap strips the = after a short flag)"           '-m=reinstall'     "$(ri_rd pass_reinstall_spelling -m=reinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling -mreinstall"                                                   '-mreinstall'      "$(ri_rd pass_reinstall_spelling -mreinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling -ymreinstall (the -y boolean folded in front)"                 '-ymreinstall'     "$(ri_rd pass_reinstall_spelling -ymreinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling -ym=reinstall"                                                 '-ym=reinstall'    "$(ri_rd pass_reinstall_spelling -ym=reinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling -ym reinstall reports as -m reinstall"                         '-m reinstall'     "$(ri_rd pass_reinstall_spelling -ym reinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling finds the spelling among other arguments"                      '-m reinstall'     "$(ri_rd pass_reinstall_spelling backend -e=subnet -m reinstall --identity x)"
assert_eq "§6bi reader: pass_reinstall_spelling --mode REINSTALL is nothing (case-sensitive: a clap parse error)" ''              "$(ri_rd pass_reinstall_spelling --mode REINSTALL)"
assert_eq "§6bi reader: pass_reinstall_spelling -- --mode reinstall is nothing (after -- they are names)"     ''                 "$(ri_rd pass_reinstall_spelling -- --mode reinstall)"
assert_eq "§6bi reader: pass_reinstall_spelling --mode upgrade is nothing"                                     ''                 "$(ri_rd pass_reinstall_spelling --mode upgrade)"
assert_eq "§6bi reader: pass_remote_env -e subnet -mreinstall (a later short carrying an e never clobbers the read)" 'subnet'    "$(ri_rd pass_remote_env -e subnet -mreinstall)"
assert_eq "§6bi reader: pass_remote_env --environment=engine"                                                  'engine'           "$(ri_rd pass_remote_env --environment=engine)"
assert_eq "§6bi reader: pass_remote_env --environment subnet"                                                  'subnet'           "$(ri_rd pass_remote_env --environment subnet)"
assert_eq "§6bi reader: pass_remote_env -esubnet"                                                              'subnet'           "$(ri_rd pass_remote_env -esubnet)"
assert_eq "§6bi reader: pass_remote_env -e=engine"                                                             'engine'           "$(ri_rd pass_remote_env -e=engine)"
assert_eq "§6bi reader: pass_remote_env -yesubnet (the -y boolean folded in front)"                            'subnet'           "$(ri_rd pass_remote_env -yesubnet)"
assert_eq "§6bi reader: pass_remote_env -e local is nothing"                                                   ''                 "$(ri_rd pass_remote_env -e local)"
assert_eq "§6bi reader: pass_remote_env with no -e is nothing"                                                 ''                 "$(ri_rd pass_remote_env backend --mode reinstall)"
assert_eq "§6bi reader: pass_remote_env -- -e subnet is nothing (after -- they are names)"                     ''                 "$(ri_rd pass_remote_env -- -e subnet)"
assert_eq "§6bi reader: pass_remote_env reads ICP_ENVIRONMENT=engine when the flag is absent"                  'engine'           "$(ri_rde engine pass_remote_env --mode reinstall)"
assert_eq "§6bi reader: pass_remote_env -e local beats ICP_ENVIRONMENT=engine (clap: the flag wins)"           ''                 "$(ri_rde engine pass_remote_env -e local)"
assert_eq "§6bi reader: pass_canister_names -e subnet --mode reinstall names nothing (icp: ALL)"               ''                 "$(ri_rd pass_canister_names -e subnet --mode reinstall)"
assert_eq "§6bi reader: pass_canister_names frontend -e subnet --mode reinstall"                               'frontend'         "$(ri_rd pass_canister_names frontend -e subnet --mode reinstall)"
assert_eq "§6bi reader: pass_canister_names backend -e subnet -m reinstall"                                    'backend'          "$(ri_rd pass_canister_names backend -e subnet -m reinstall)"
assert_eq "§6bi reader: pass_canister_names frontend backend -e subnet --mode reinstall"                       'frontend backend' "$(ri_rd pass_canister_names frontend backend -e subnet --mode reinstall)"
assert_eq "§6bi reader: pass_canister_names --identity frontend -e subnet --mode reinstall names nothing (a valued flag's value is not a name)" '' "$(ri_rd pass_canister_names --identity frontend -e subnet --mode reinstall)"
assert_eq "§6bi reader: pass_canister_names -y frontend -e subnet (a boolean flag's neighbour is)"             'frontend'         "$(ri_rd pass_canister_names -y frontend -e subnet)"
assert_eq "§6bi reader: pass_canister_names -ym reinstall frontend"                                            'frontend'         "$(ri_rd pass_canister_names -ym reinstall frontend)"
assert_eq "§6bi reader: pass_canister_names -e subnet -- frontend bridge (everything after -- is a name)"     'frontend bridge'  "$(ri_rd pass_canister_names -e subnet -- frontend bridge)"
assert_eq "§6bi reader: pass_canister_names --mode=reinstall arb"                                              'arb'              "$(ri_rd pass_canister_names --mode=reinstall arb)"
# (1) the plain door with NO canister named — icp would reinstall EVERY canister on the stack — in every attached environment spelling and every reinstall spelling icp accepts: refused before any icp call, both cures named
for sp in "--environment=subnet --mode reinstall" "-esubnet -m reinstall" "-e=subnet --mode=reinstall" "-yesubnet -m=reinstall" "--environment=subnet -mreinstall" "-esubnet -ym reinstall" "-e=subnet -ymreinstall" "--environment=subnet -ym=reinstall"; do
  # shellcheck disable=SC2086 — the two-word spellings must arrive as two arguments, exactly as an operator's shell delivers them
  ri_run $sp
  if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' \
     && printf '%s\n' "$out" | grep -cF -- "REFUSING the plain passthrough 'icp deploy $sp'" >/dev/null \
     && printf '%s\n' "$out" | grep -cF -- "scripts/deploy.sh subnet frontend --mode reinstall (the guided frontend-only form)" >/dev/null \
     && printf '%s\n' "$out" | grep -cF -- "scripts/deploy.sh frontend --environment=subnet --mode reinstall --identity <controller>" >/dev/null \
     && printf '%s\n' "$out" | grep -cF -- "hold state; a reinstall wipes it" >/dev/null; then
    _ok "§6bi: deploy.sh $sp is REFUSED (exit $rc) before any icp deploy, naming both frontend-only cures (icp saw: ${saw:-nothing})"
  else _fail "§6bi: deploy.sh $sp must be refused before any icp deploy, naming the cures: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
done
# ...and the dry read prints the refusal ALONE: no gen-did line, no posture line, no icp call at all
ri_run --environment=subnet --mode reinstall
PL_LINES="$(printf '%s\n' "$out" | grep -c . || true)"
if [ "$rc" -ne 0 ] && [ "${PL_LINES:-0}" -eq 1 ] && [ ! -s "$RI_LOG" ] \
   && printf '%s\n' "$out" | grep -cF -- "REFUSING the plain passthrough 'icp deploy --environment=subnet --mode reinstall': it carries '--mode reinstall' against the remote environment 'subnet' and names NO canister, which icp reads as ALL of them" >/dev/null; then
  _ok "§6bi: the dry read of 'deploy.sh --environment=subnet --mode reinstall' prints the refusal and nothing else — the spelling, the environment and the no-name-means-ALL reading — and icp is never invoked"
else _fail "§6bi: the dry read of 'deploy.sh --environment=subnet --mode reinstall' should print the refusal alone before any icp call: exit $rc, ${PL_LINES:-?} line(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# ...and the environment clap reads from ICP_ENVIRONMENT when no flag names one is the same remote target
ICP_ENVIRONMENT=subnet ri_run --mode reinstall
if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' && printf '%s\n' "$out" | grep -cF -- "against the remote environment 'subnet' and names NO canister" >/dev/null; then
  _ok "§6bi: ICP_ENVIRONMENT=subnet deploy.sh --mode reinstall — no -e at all — is REFUSED the same way: the reader honours the variable clap reads (icp saw: ${saw:-nothing})"
else _fail "§6bi: ICP_ENVIRONMENT=subnet deploy.sh --mode reinstall must be refused before any icp deploy: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
ICP_ENVIRONMENT=engine ri_run backend -m reinstall
if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' && printf '%s\n' "$out" | grep -cF -- "against the remote environment 'engine' and names backend." >/dev/null; then
  _ok "§6bi: ICP_ENVIRONMENT=engine deploy.sh backend -m reinstall is REFUSED naming the backend and the engine (icp saw: ${saw:-nothing})"
else _fail "§6bi: ICP_ENVIRONMENT=engine deploy.sh backend -m reinstall must be refused naming backend and engine: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# (2) every naming but `frontend` alone, every attached environment spelling: refused, the message naming the environment, the names and the cure for THAT environment
while IFS='|' read -r args env phrase; do
  [ -n "$args" ] || continue
  # shellcheck disable=SC2086 — the operator's shell delivers these as separate arguments
  ri_run $args
  if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' \
     && printf '%s\n' "$out" | grep -cF -- "against the remote environment '$env' and $phrase" >/dev/null \
     && printf '%s\n' "$out" | grep -cF -- "scripts/deploy.sh frontend --environment=$env --mode reinstall" >/dev/null; then
    _ok "§6bi: deploy.sh $args is REFUSED (exit $rc) before any icp deploy — '$env', $phrase — the cure naming $env (icp saw: ${saw:-nothing})"
  else _fail "§6bi: deploy.sh $args must be refused before any icp deploy naming '$env' and '$phrase': exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
done <<'PLEOF'
backend --environment=subnet -m reinstall|subnet|names backend.
bridge arb -esubnet --mode reinstall|subnet|names bridge arb.
backend frontend -e=subnet --mode reinstall|subnet|names frontend backend.
frontend --environment=engine --mode reinstall -- backend|engine|names frontend backend.
-e=engine --mode=reinstall|engine|names NO canister
--environment=engine --mode reinstall --identity ri-stub-engine|engine|names NO canister
-esubnet -y --mode reinstall|subnet|names NO canister
PLEOF
# the two-word `-e subnet` IS this door since task 1793556403 (the parser forwards a valued flag's value instead of reading it as the target keyword; at 1793553523 these landed on the FULL path with a dangling -e and §6bh's guard refused them — the tripwire that stood here): refused by the PLAIN guard before any icp deploy, naming the spelling, the environment and the names — never the full path's refusal
for args in "-e subnet --mode reinstall|names NO canister, which icp reads as ALL of them" "backend -e subnet -m reinstall|names backend." "--environment subnet --mode=reinstall|names NO canister" "bridge -ye subnet -m reinstall|names bridge."; do
  phrase="${args#*|}"; args="${args%%|*}"
  # shellcheck disable=SC2086 — separate arguments, as the operator's shell delivers them
  ri_run $args
  if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' && printf '%s\n' "$out" | grep -cF -- "REFUSING the plain passthrough 'icp deploy $args': it carries" >/dev/null \
     && printf '%s\n' "$out" | grep -cF -- "against the remote environment 'subnet' and $phrase" >/dev/null && ! printf '%s\n' "$out" | grep -cF -- "REFUSING 'deploy.sh subnet'" >/dev/null; then
    _ok "§6bi: deploy.sh $args (the two-word environment) reaches the PLAIN door and is REFUSED there (exit $rc) before any icp deploy — $phrase (task 1793556403; icp saw: ${saw:-nothing})"
  else _fail "§6bi: deploy.sh $args must reach the plain door and be refused there — not the FULL path's refusal, not an icp deploy: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
done
# ...and the frontend alone, two-word (1793553523's original pin 3, impossible under the old parser): exactly one icp deploy, the frontend's, the pair forwarded, completes
RI_DEPLOY_RC=0 ri_run frontend -e subnet --mode reinstall
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy frontend -e subnet --mode reinstall$' && ! printf '%s\n' "$out" | grep -cF -- "REFUSING" >/dev/null; then
  _ok "§6bi: deploy.sh frontend -e subnet --mode reinstall (the two-word environment, frontend alone) reaches exactly one icp deploy — frontend, carrying the reinstall, -e subnet forwarded as the pair — and completes (task 1793556403)"
else _fail "§6bi: the frontend-alone two-word plain form must reach exactly one icp deploy frontend -e subnet --mode reinstall and complete: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# the parser itself (task 1793556403): a valued flag's VALUE is forwarded, never a keyword — the arm pinned, the valued-flag list equal to pass_canister_names's, the check ahead of the keyword case; then the loop sliced out of deploy.sh and DRIVEN on the shapes the task measured (TARGET|FRONTEND_ONLY|PASS), the bare keyword forms as controls
src_has "§6bi parser: the valued-flag arm forwards the next word and skips the keyword case"                      "$DEPLOY_UNC_BG" '      PASS+=("$1"); PREV_ARG=""; shift; continue ;;'
src_has "§6bi parser: ...a short cluster reads as its valued short (-ye subnet is -e subnet), the readers' shape" "$DEPLOY_UNC_BG" 'PREV_ARG="${1#-}"; PREV_ARG="-${PREV_ARG#"${PREV_ARG%%[!yh]*}"}"; [ "$PREV_ARG" != "-" ] || PREV_ARG="$1" ;;'
src_has "§6bi parser: the keyword arm itself is unchanged"                                                          "$DEPLOY_UNC_BG" '    local|cloud|engine|subnet) if [ -z "$TARGET" ]; then TARGET="$1"; else PASS+=("$1"); fi ;;'
PV_N="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -cF -- '-m|--mode|-e|--environment|--subnet|--proxy|--controller|--cycles|--args|--args-file|--args-format|--identity|--project-root-override)' || true)"
assert_eq "§6bi parser: the valued-flag list appears exactly twice in deploy.sh — the parser's arm and pass_canister_names's — so a flag icp adds later is added to both or the count reds" 2 "$PV_N"
PV_ARM_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -nF -- 'case "$PREV_ARG" in' | head -1 | cut -d: -f1)"
PV_KW_LN="$(printf '%s\n' "$DEPLOY_UNC_BG" | grep -nF -- '    local|cloud|engine|subnet) if [ -z "$TARGET" ]' | head -1 | cut -d: -f1)"
if [ -n "$PV_ARM_LN" ] && [ -n "$PV_KW_LN" ] && [ "$PV_ARM_LN" -lt "$PV_KW_LN" ]; then _ok "§6bi parser: the valued-flag check (line $PV_ARM_LN) precedes the keyword case (line $PV_KW_LN) inside the loop"
else _fail "§6bi parser: the valued-flag check (line '${PV_ARM_LN:-none}') must precede the keyword case (line '${PV_KW_LN:-none}') — after it the keyword has already been taken"; fi
awk 'index($0, "TARGET=\"${DEPLOY_TARGET:-}\"") == 1 {q=1} q && index($0, "TARGET_GIVEN=\"$TARGET\"") == 1 {q=0} q {print}' scripts/deploy.sh \
  | sed 's|^\. scripts/factory_guard\.sh$|factory_primary_guard() { :; }|' > "$RI_TMP/parser.sh"
grep_count n "$(cat "$RI_TMP/parser.sh")" '^while \[ \$# -gt 0 \]; do$'
assert_eq "§6bi parser: the argument loop slices out of deploy.sh (TARGET=\"\${DEPLOY_TARGET:-}\" up to the canonicalisation, the guard source line stubbed; one while loop)" 1 "$n"
ri_parse() { env -u DEPLOY_TARGET -u CLOUD_ENGINE bash -c 'set -euo pipefail; ask() { echo l; }; truthy() { case "$1" in true|1|yes) return 0;; *) return 1;; esac; }; P="$1"; shift; . "$P"; printf "%s|%s|%s" "$TARGET" "$FRONTEND_ONLY" "${PASS[*]:-}"' _ "$RI_TMP/parser.sh" "$@" 2>&1; }   # ri_parse <deploy.sh args…> → TARGET|FRONTEND_ONLY|PASS (the parser alone; `cloud` is canonicalised later, so it reads as cloud here)
assert_eq "§6bi parser: -e subnet --mode reinstall → the plain door, the pair forwarded"                                'plain|false|-e subnet --mode reinstall'                      "$(ri_parse -e subnet --mode reinstall)"
assert_eq "§6bi parser: backend -e subnet -m reinstall → plain"                                                        'plain|false|backend -e subnet -m reinstall'                  "$(ri_parse backend -e subnet -m reinstall)"
assert_eq "§6bi parser: frontend -e subnet --mode reinstall → plain, frontend restored to the front"                   'plain|false|frontend -e subnet --mode reinstall'             "$(ri_parse frontend -e subnet --mode reinstall)"
assert_eq "§6bi parser: -e subnet --subnet abc (the usage header's legacy example) → plain"                            'plain|false|-e subnet --subnet abc'                          "$(ri_parse -e subnet --subnet abc)"
assert_eq "§6bi parser: --environment subnet --mode upgrade → plain"                                                   'plain|false|--environment subnet --mode upgrade'             "$(ri_parse --environment subnet --mode upgrade)"
assert_eq "§6bi parser: -ye subnet --mode upgrade → plain (the -y boolean folded in front of -e)"                      'plain|false|-ye subnet --mode upgrade'                       "$(ri_parse -ye subnet --mode upgrade)"
assert_eq "§6bi parser: --identity local --mode upgrade → plain (an identity named local is a value)"                  'plain|false|--identity local --mode upgrade'                 "$(ri_parse --identity local --mode upgrade)"
assert_eq "§6bi parser: --subnet engine → plain (a subnet id spelled engine is a value)"                               'plain|false|--subnet engine'                                 "$(ri_parse --subnet engine)"
assert_eq "§6bi parser: --identity frontend -e subnet --mode reinstall → plain, frontend a value not the frontend-only switch" 'plain|false|--identity frontend -e subnet --mode reinstall' "$(ri_parse --identity frontend -e subnet --mode reinstall)"
assert_eq "§6bi parser: subnet → the guided subnet path (a bare keyword, unchanged)"                                   'subnet|false|'                                               "$(ri_parse subnet)"
assert_eq "§6bi parser: subnet --mode reinstall → subnet, the spelling forwarded (unchanged; §6bh refuses it)"         'subnet|false|--mode reinstall'                               "$(ri_parse subnet --mode reinstall)"
assert_eq "§6bi parser: subnet frontend --mode reinstall → frontend-only (unchanged)"                                  'subnet|true|--mode reinstall'                                "$(ri_parse subnet frontend --mode reinstall)"
assert_eq "§6bi parser: subnet -e subnet → subnet, icp's own pair forwarded (a keyword first; unchanged)"               'subnet|false|-e subnet'                                      "$(ri_parse subnet -e subnet)"
assert_eq "§6bi parser: --target subnet frontend → frontend-only (deploy.sh's own valued flag, unchanged)"             'subnet|true|'                                                "$(ri_parse --target subnet frontend)"
assert_eq "§6bi parser: --environment=subnet --mode reinstall → plain (the attached spelling, unchanged)"              'plain|false|--environment=subnet --mode reinstall'           "$(ri_parse --environment=subnet --mode reinstall)"
assert_eq "§6bi parser: backend --mode reinstall --identity anonymous → plain (local, unchanged)"                      'plain|false|backend --mode reinstall --identity anonymous'   "$(ri_parse backend --mode reinstall --identity anonymous)"
# (3) the ONE legal plain-door remote reinstall — the stateless frontend alone — still reaches exactly one icp deploy, the frontend's, carrying the reinstall, in each attached spelling, and completes
RI_DEPLOY_RC=0 ri_run frontend --environment=subnet --mode reinstall
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy frontend --environment=subnet --mode reinstall$' && ! printf '%s\n' "$out" | grep -cF -- "REFUSING" >/dev/null; then
  _ok "§6bi: deploy.sh frontend --environment=subnet --mode reinstall reaches exactly one icp deploy — frontend, carrying the reinstall — and completes"
else _fail "§6bi: the frontend-alone plain form must reach exactly one icp deploy frontend with the reinstall and complete: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
RI_DEPLOY_RC=0 ri_run -esubnet -mreinstall frontend --identity ri-stub-wallet
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy frontend -esubnet -mreinstall --identity ri-stub-wallet$'; then
  _ok "§6bi: deploy.sh -esubnet -mreinstall frontend --identity … (frontend restored to the front, the attached spellings) reaches exactly one icp deploy frontend carrying the reinstall"
else _fail "§6bi: the -esubnet -mreinstall frontend form must reach exactly one icp deploy frontend with the reinstall: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
RI_DEPLOY_RC=0 ri_run -e=engine --mode reinstall frontend
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy frontend -e=engine --mode reinstall$'; then
  _ok "§6bi: deploy.sh -e=engine --mode reinstall frontend reaches exactly one icp deploy frontend carrying the reinstall on the engine too"
else _fail "§6bi: the -e=engine frontend form must reach exactly one icp deploy frontend with the reinstall: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# (4) LOCAL plain reinstalls are untouched: no -e (the zombie check runs — mdx_stray_masters answers nothing for the copy, no replica owns it), or a local environment spelled
RI_DEPLOY_RC=0 ri_run backend --mode reinstall --identity anonymous
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy backend --mode reinstall --identity anonymous$' && printf '%s\n' "$out" | grep -cF -- "Plain passthrough" >/dev/null && ! printf '%s\n' "$out" | grep -cF -- "REFUSING" >/dev/null; then
  _ok "§6bi: deploy.sh backend --mode reinstall --identity anonymous (LOCAL plain, no -e) still reaches icp deploy backend carrying the reinstall through the zombie check"
else _fail "§6bi: the local plain reinstall must still reach icp deploy backend with the reinstall: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
RI_DEPLOY_RC=0 ri_run backend --environment=local --mode reinstall --identity anonymous
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy backend --environment=local --mode reinstall --identity anonymous$'; then
  _ok "§6bi: deploy.sh backend --environment=local --mode reinstall --identity anonymous (a local environment spelled) still reaches icp deploy backend carrying the reinstall"
else _fail "§6bi: the --environment=local plain reinstall must still reach icp deploy backend: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
RI_DEPLOY_RC=0 ri_run bridge -mreinstall
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy bridge -mreinstall$' && printf '%s\n' "$out" | grep -cF -- "no --identity in the passthrough args" >/dev/null; then
  _ok "§6bi: deploy.sh bridge -mreinstall (local, no identity) still reaches icp deploy bridge, the no-identity warning printed as before"
else _fail "§6bi: the local bridge -mreinstall form must still reach icp deploy bridge with the warning: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# control: a remote plain UPGRADE walks through to the (stubbed) icp deploy — the refusals above are the guard's, keyed on the reinstall alone, not an earlier gate's
RI_DEPLOY_RC=0 ri_run --environment=subnet --mode upgrade --identity ri-stub-wallet
grep_count n "$(cat "$RI_LOG")" '^deploy '
if [ "$rc" -eq 0 ] && [ "${n:-0}" -eq 1 ] && grep_has "$(cat "$RI_LOG")" '^deploy --environment=subnet --mode upgrade --identity ri-stub-wallet$' && ! printf '%s\n' "$out" | grep -cF -- "REFUSING" >/dev/null; then
  _ok "§6bi control: deploy.sh --environment=subnet --mode upgrade --identity … passes the guard and reaches the (stubbed) icp deploy carrying --mode upgrade — the guard keys on the reinstall alone"
else _fail "§6bi control: a remote plain --mode upgrade should pass the guard to icp deploy: exit $rc, ${n:-?} deploy call(s), icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
# negative control: the copy with the plain guard's die stripped runs the SAME mistype to the icp deploy WITH the reinstall and NO canister named — the wipe the guard exists for; the probe sees it
sed 's/^        \*) die "REFUSING the plain passthrough .*$/        *) : ;; # 6bi negative control: the plain guard is stripped here/' scripts/deploy.sh > "$RI_REPO/scripts/deploy.sh"
if cmp -s scripts/deploy.sh "$RI_REPO/scripts/deploy.sh"; then _fail "§6bi negative control: stripping the plain guard changed nothing — its die line moved or was reworded; the control tests nothing"
else
  ri_run --environment=subnet --mode reinstall
  if [ "$rc" -ne 0 ] && grep_has "$(cat "$RI_LOG")" '^deploy --environment=subnet --mode reinstall$' && ! printf '%s\n' "$out" | grep -cF -- "REFUSING" >/dev/null; then
    _ok "§6bi negative control: with the plain guard stripped, deploy.sh --environment=subnet --mode reinstall reaches the (stubbed, refused) icp deploy CARRYING the reinstall and naming NO canister — the probe sees the wipe it pins"
  else _fail "§6bi negative control: with the plain guard stripped the run should reach icp deploy with the reinstall: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
fi
cp scripts/deploy.sh "$RI_REPO/scripts/deploy.sh"
# the FULL path inherits the reader's new spellings: -m=reinstall and the -ym cluster forms are refused there too
for sp in "-m=reinstall" "-ym reinstall" "-ymreinstall" "-ym=reinstall"; do
  # shellcheck disable=SC2086 — the two-word spelling must arrive as two arguments
  ri_run subnet $sp
  if [ "$rc" -ne 0 ] && ! grep_has "$(cat "$RI_LOG")" '^deploy ' && printf '%s\n' "$out" | grep -cF -- "REFUSING 'deploy.sh subnet' with" >/dev/null; then
    _ok "§6bi: the FULL path inherits the reader — deploy.sh subnet $sp is REFUSED (exit $rc) before any icp deploy (icp saw: ${saw:-nothing})"
  else _fail "§6bi: deploy.sh subnet $sp must be refused on the full path before any icp deploy: exit $rc, icp saw '${saw:-nothing}' — $(printf '%s' "$out" | tr '\n' ' ' | head -c 400)"; fi
done
rm -rf "$RI_TMP"

# ── §6bj 1793569495: a MISSING archive segment is tolerated, named, and droppable ──
# The engine's first sealed segment (srh6u…, seq 0..526_277) no longer existed
# while getArchives still routed to it (2026-11-01): every history walk hit a
# dead hop, adminUpgradeArchives said "1 failed (see log)" with no id, and
# the fuel pass blind-funded a canister that was not there. Pins: the
# not-found classifier keys on the IC's reject CODE (#destination_invalid)
# with the management canister's own wording as the belt — naming THIS
# canister, so no segment's trap text can pass as the class; both federation
# pagers answer `unavailable` (a value naming the cause) instead of rejecting,
# the filtered twin skipping its fallback on the not-found class; the upgrade
# reply names each failed hop with the reject text and never says "see log";
# the drop door is controller-only on EVERY posture (a repair, not a dev
# hook), verifies with canister_status INSIDE the call — an existing canister
# refused, any reject class but not-found refused — refuses the tip, the
# successor, a closed season's row and a non-row, re-resolves after the
# await, and writes the gap tuple + the hash-committed #gap + #config + the
# SHARED balance re-baseline (the shed's rows, extracted — one definition of
# "reopen the tape"); the fixture hook is dev-gated and scoped to our sealed
# rows; the fuel pass names a missing segment and funds nothing; inspect
# enumerates both methods; the frontend closes an `unavailable` source and
# names it in the progress line; the live twin drives it all. Live twin:
# tests/test_archive_fills_paged.sh §5.
NF_FN=$(mo_func src/backend/main.mo "func isCanisterNotFound(")
[ -n "$NF_FN" ] || _fail "§6bj: could not extract isCanisterNotFound()"
NF_CODE=$(printf '%s\n' "$NF_FN" | mo_code)
src_has   "§6bj: the not-found classifier keys on the reject code"                 "$NF_CODE" 'case (#destination_invalid) { true };'
src_has   "§6bj: the message belt names THIS canister (the management canister's wording)" "$NF_CODE" '"Canister " # Principal.toText(cid) # " not found"'
FQ_FN=$(mo_func src/backend/main.mo "func getMyArchivedEventsFiltered(")
[ -n "$FQ_FN" ] || _fail "§6bj: could not extract getMyArchivedEventsFiltered()"
FQ_CODE=$(printf '%s\n' "$FQ_FN" | mo_code)
src_has   "§6bj: the filtered pager classifies the not-found class before any fallback" "$FQ_CODE" 'if (isCanisterNotFound(archiveId, e)) {'
src_has   "§6bj: …and answers unavailable with the cause"                              "$FQ_CODE" 'unavailable = ?archiveUnavailableText(archiveId, e)'
src_has   "§6bj: a fallback that rejects too answers unavailable, never a trap"      "$FQ_CODE" 'catch (e2) {'
src_lacks "§6bj: the filtered pager no longer discards the reject"                   "$FQ_CODE" 'catch (_)'
MQ_FN=$(mo_func src/backend/main.mo "func getMyArchivedEvents(")
[ -n "$MQ_FN" ] || _fail "§6bj: could not extract getMyArchivedEvents()"
src_has   "§6bj: the legacy pager answers unavailable instead of rejecting"          "$(printf '%s\n' "$MQ_FN" | mo_code)" 'unavailable = ?archiveUnavailableText(archiveId, e)'
UPG6_FN=$(mo_func src/backend/main.mo "func adminUpgradeArchives(")
[ -n "$UPG6_FN" ] || _fail "§6bj: could not extract adminUpgradeArchives()"
UPG6_CODE=$(printf '%s\n' "$UPG6_FN" | mo_code)
src_has   "§6bj: the upgrade reply collects every failed hop with its reject text"   "$UPG6_CODE" 'failures #= (if (failures == "") "" else "; ") # Principal.toText(cid) # ": " # Error.message(e);'
src_has   "§6bj: …and names the drop door for a not-found cause"                     "$UPG6_CODE" 'adminDropMissingArchive(<id>) retires its routing row'
src_lacks "§6bj: the reply no longer says 'see log'"                                 "$UPG6_CODE" 'see log'
DROP_FN=$(mo_func src/backend/main.mo "func adminDropMissingArchive(")
[ -n "$DROP_FN" ] || _fail "§6bj: could not extract adminDropMissingArchive()"
DROP_CODE=$(printf '%s\n' "$DROP_FN" | mo_code)
src_has   "§6bj: the drop door is controller-gated"                                  "$DROP_CODE" 'requireController(msg.caller);'
src_lacks "§6bj: the drop door is NOT dev-gated (an ops repair on every posture)"    "$DROP_CODE" 'requireDevHook('
src_has   "§6bj: the active tip is refused"                                          "$DROP_CODE" 'is the active archive of the current chain; refusing'
src_has   "§6bj: the pre-spawned successor is refused"                               "$DROP_CODE" 'is the pre-spawned successor of the current chain; refusing'
src_has   "§6bj: a closed season's row is refused (out of scope by design)"          "$DROP_CODE" 'is a sealed segment of a CLOSED season'
src_has   "§6bj: a principal that is not a sealed row is refused"                    "$DROP_CODE" '#err("not a sealed segment of the current chain: "'
src_has   "§6bj: the management canister is asked INSIDE the call"                   "$DROP_CODE" 'await ic00.canister_status({ canister_id = cid });'
src_has   "§6bj: a canister that EXISTS is refused"                                  "$DROP_CODE" 'a segment that exists is never dropped; refusing'
src_has   "§6bj: a reject of any other class is refused"                             "$DROP_CODE" 'if (not isCanisterNotFound(cid, e)) {'
src_has   "§6bj: the row is re-resolved after the await"                             "$DROP_CODE" 'left the chain while its status was being read; nothing done'
src_has   "§6bj: the lost range is recorded as a ledger-gap tuple"                   "$DROP_CODE" 'let (declFrom, declTo) = recordGap(gapFrom, gapTo);'
src_has   "§6bj: …declared ON the tape as a hash-committed #gap"                     "$DROP_CODE" 'emitEventRaw(Principal.fromActor(Uplands), null, #gap { fromSeq = declFrom; toSeq = declTo });'
src_has   "§6bj: …closed for replayers by the SHARED re-baseline"                    "$DROP_CODE" 'let (bFrom, bTo) = emitBalanceRebaseline();'
src_has   "§6bj: …with the exit windows flushed and the journal drained first"       "$DROP_CODE" 'flushExitWindows(true);'
src_has   "§6bj: the action lands as #config on the tape"                            "$DROP_CODE" 'emitConfig(msg.caller, "adminDropMissingArchive", v);'
src_has   "§6bj: the action logs on the ring"                                        "$DROP_CODE" 'logEvent("warn", "system", "ARCHIVE CHAIN: dropped MISSING sealed segment " # v'
SHED6_FN=$(mo_func src/backend/main.mo "func shedOldestEvents(")
[ -n "$SHED6_FN" ] || _fail "§6bj: could not extract shedOldestEvents()"
src_has   "§6bj: the L2 shed re-baselines through the same helper (one definition)" "$(printf '%s\n' "$SHED6_FN" | mo_code)" 'let (bFrom, bTo) = emitBalanceRebaseline();'
RB_FN=$(mo_func src/backend/main.mo "func emitBalanceRebaseline(")
[ -n "$RB_FN" ] || _fail "§6bj: could not extract emitBalanceRebaseline()"
src_has   "§6bj: the helper records its range in _shedBaselines"                     "$(printf '%s\n' "$RB_FN" | mo_code)" '_shedBaselines := Array.tabulate<(Nat, Nat)>(m + 1'
DEL_FN=$(mo_func src/backend/main.mo "func setTestArchiveDeleted(")
[ -n "$DEL_FN" ] || _fail "§6bj: could not extract setTestArchiveDeleted()"
DEL_CODE=$(printf '%s\n' "$DEL_FN" | mo_code)
src_has   "§6bj: the fixture hook is dev-gated"                                      "$DEL_CODE" 'requireDevHook("setTestArchiveDeleted")'
src_has   "§6bj: the fixture hook is scoped to our SEALED rows (tip + successor refused)" "$DEL_CODE" 'not a sealed archive segment of this exchange'
src_has   "§6bj: the fixture hook deletes with the wipe's ic00 pair"                 "$DEL_CODE" 'await ic00.delete_canister({ canister_id = cid });'
FUEL6_FN=$(mo_func src/backend/main.mo "func tickArchiveFuel(")
[ -n "$FUEL6_FN" ] || _fail "§6bj: could not extract tickArchiveFuel()"
FUEL6_CODE=$(printf '%s\n' "$FUEL6_FN" | mo_code)
src_has   "§6bj: the fuel pass classifies a missing sealed segment"                  "$FUEL6_CODE" 'if (isCanisterNotFound(cid, e0)) {'
src_has   "§6bj: …names the door and funds nothing"                                  "$FUEL6_CODE" 'retires the row and declares the gap; not funding'
src_has   "§6bj: inspect enumerates adminDropMissingArchive"                         "$INSPECT_FN" '#adminDropMissingArchive : Any'
src_has   "§6bj: inspect enumerates setTestArchiveDeleted"                           "$INSPECT_FN" '#setTestArchiveDeleted : Any'
MAINJS6=$(cat src/frontend/src/main.js)
src_has   "§6bj: the IDL lists the filtered pager's unavailable field"               "$MAINJS6" 'total: IDL.Nat, filtered: IDL.Bool, unavailable: IDL.Opt(IDL.Text)'
src_has   "§6bj: the IDL lists the legacy pager's unavailable field"                 "$MAINJS6" 'total: IDL.Nat, unavailable: IDL.Opt(IDL.Text)'
src_has   "§6bj: the archived-fills walk closes an unavailable source and goes on"  "$MAINJS6" 'src.failed = true; src.unavailable = why; src.total = 0;'
src_has   "§6bj: …and the progress line names it"                                    "$MAINJS6" '${down.join(", ")} unavailable` : ""'
src_has   "§6bj: the Account → Archive pager skips a dead hop instead of parking"    "$MAINJS6" '_archSkipped.push(`segment ${sources.indexOf(src) + 1} of ${sources.length} (${src.id}) unavailable'
AFP6=$(uncommented tests/test_archive_fills_paged.sh)
src_has   "§6bj: the live twin manufactures a real missing segment"                 "$AFP6" 'setTestArchiveDeleted "(principal \"$C\")"'
src_has   "§6bj: the live twin drives the drop door"                                 "$AFP6" 'adminDropMissingArchive "(principal \"$C\")"'
src_has   "§6bj: the live twin pins the refusal while the canister exists"           "$AFP6" 'EXISTS (canister_status answered'
src_has   "§6bj: the live twin pins the #gap row on the tape"                        "$AFP6" 'the chain declares its hole'

if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_deploy_hygiene\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_deploy_hygiene ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
