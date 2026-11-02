#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# factory-selftest.sh - exercise scripts/factory.sh against a THROWAWAY queue.
#
# The real queue coordinates every consumer seat at once, so it is the last
# place to try a change out. FACTORY_TASKS_ROOT points factory.sh at a temp
# directory instead; nothing here touches tasks/.
#
# Run it by hand after changing factory.sh:  ./scripts/factory-selftest.sh
# Not wired into lint-all/test-all: it is a developer harness, not a gate.
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
F="${1:-$HERE/factory.sh}"
R="$(mktemp -d)"
export FACTORY_TASKS_ROOT="$R"
# Identity is set PER CASE below: a seat's shell carries FACTORY_WORKER (the
# executor-env prefix, task 1791133471) and the operator's may carry
# FACTORY_DIRECT - neither may leak into the scratch tree's verdicts.
unset FACTORY_WORKER FACTORY_DIRECT FACTORY_FORCE
# Pin the recycle gate's test seam so every claim below is deterministic and
# fast regardless of this machine's real replicas (the recycle-gate section
# overrides it per case to drive the refusal arms).
export FACTORY_TEST_REPLICA_MB=0
trap 'rm -rf "$R"' EXIT

# ONE fake-session prefix PER RUN (task 1792510644). factory.sh attributes
# processes BY NAME machine-wide (name_pids / spawn_live_pids: pgrep over
# "--name <sname>"), so under the old fixed prefix two selftests running at
# once on this machine saw each other's sleepers - the foreign run's pids
# landed on the ORPHANED row and seat-recreate then KILLED the other run's
# fake (2026-10-20): a cross-run kill by name, inside a test harness. The pid
# is unique among live runs; the hex tail covers a stray sleeper of a killed
# run whose pid was reused. Letters + digits only (no dash, no dot): the word
# rides session names, launchd labels, boot lines and grep patterns verbatim.
# Every fake name, FACTORY_PROJECT / FACTORY_SESSION_NAME value and expected
# string below is built from it; the derived-prefix case (no FACTORY_PROJECT:
# the primary's basename) stands on its own and never uses it.
FP="fakeproj$$"; FP="$FP$(printf '%04x' "$RANDOM")"
fail=0
ok()  { echo "  ok $1"; }
bad() { echo "  FAIL $1 -- $2"; fail=1; }
mk() {  # mk <lane-or-empty> <title>
  local d="$R/draft.md"
  {
    if [ -n "$1" ]; then echo "---"; echo "lane: $1"; echo "touches: nothing-$$-$RANDOM"; echo "---"; fi
    echo "# $2"
  } > "$d"
  "$F" new "$d" >/dev/null
}
count() { find "$1" -name "$2" 2>/dev/null | wc -l | tr -d ' '; }

echo "== a literally empty queue says so =="
out="$("$F" claim seat-0)"
if [ "$out" = "EMPTY (queue 0)" ]; then ok "claim on an empty queue prints EMPTY (queue 0)"; else bad "empty-queue EMPTY" "got '$out'"; fi

echo "== operator lane: a seat is never handed forbidden work =="
mk operator "engine rollout A"
mk operator "engine rollout B"
out="$("$F" claim seat-1)"
if [ "$out" = "EMPTY (queue 2: 0 dep-gated, 2 operator-lane, 0 overlap-deferred)" ]; then
  ok "claim prints an itemized EMPTY rather than a forbidden task"
else
  bad "claim EMPTY" "got '$out'"
fi
n="$(count "$R/queue" '*.md')"
if [ "$n" = "2" ]; then ok "both operator tasks still queued"; else bad "queue intact" "$n files"; fi
# claim mkdir's the worker dir before searching, so an idle seat leaves an
# EMPTY dir behind. What must hold is that no task FILE moved.
c="$(count "$R/claimed" '*.md')"
if [ "$c" = "0" ]; then ok "no task file moved into claimed/"; else bad "claimed empty" "$c files"; fi

echo "== ordinary work is claimed, the lane is left alone =="
mk "" "ordinary consumer work"
out="$("$F" claim seat-1)"
if grep -q "ordinary consumer work" "$out" 2>/dev/null; then ok "claim took the ordinary task"; else bad "claim ordinary" "got '$out'"; fi
n="$(count "$R/queue" '*.md')"
if [ "$n" = "2" ]; then ok "operator tasks untouched"; else bad "operator untouched" "$n files"; fi

echo "== EMPTY itemizes dep-gating =="
id_ord="$(basename "$out" .md)"; id_ord="${id_ord#*-}"   # the claimed ordinary task is live
d="$R/draft.md"
{ echo "---"; echo "after: $id_ord"; echo "---"; echo "# blocked behind the ordinary task"; } > "$d"
"$F" new "$d" >/dev/null
out="$("$F" claim seat-3)"
if [ "$out" = "EMPTY (queue 3: 1 dep-gated, 2 operator-lane, 0 overlap-deferred)" ]; then
  ok "EMPTY counts dep-gated and lane tasks separately"
else
  bad "itemized EMPTY" "got '$out'"
fi
# the blocked task stays queued for the rest of the run: its prerequisite is
# claimed by seat-1 throughout, so every later consumer claim skips it.

echo "== --operator reaches the lane =="
out="$("$F" claim --operator)"
case "$out" in
  */claimed/operator/*) ok "--operator claimed into the operator worker dir" ;;
  *) bad "--operator dest" "got '$out'" ;;
esac
if grep -q "engine rollout" "$out" 2>/dev/null; then ok "--operator claimed a lane task"; else bad "--operator content" "got '$out'"; fi

echo "== list filters =="
# plain grep (not -q): -q exits at the first match, and under pipefail the
# writer's SIGPIPE (141) would fail the pipeline once list prints more lines
# after the match.
if "$F" list | grep '\[operator\]' >/dev/null; then ok "list marks lane tasks"; else bad "list marker" "$("$F" list)"; fi
if [ "$("$F" list --consumer | grep -c 'engine rollout')" = "0" ]; then ok "list --consumer hides the lane"; else bad "list --consumer" "$("$F" list --consumer)"; fi
if [ "$("$F" list --operator | grep -c 'engine rollout')" = "1" ]; then ok "list --operator shows only the lane"; else bad "list --operator" "$("$F" list --operator)"; fi

echo "== board =="
b="$("$F" index)"
if grep -q '^## Operator lane' "$b"; then ok "board has an operator-lane section"; else bad "board section" "$(grep '^##' "$b")"; fi
if sed -n '/^## Queue/,/^## Operator lane/p' "$b" | grep -q "engine rollout"; then
  bad "execution order" "a lane task is listed in the consumers' execution order"
else
  ok "lane tasks kept out of the execution order"
fi

echo "== lifecycle still works =="
mk "" "second ordinary"
out="$("$F" claim seat-2)"
if grep -q "ordinary" "$out" 2>/dev/null; then ok "unmarked tasks still claimable"; else bad "regression" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"
"$F" requeue "$id" "back you go" >/dev/null
if [ "$(count "$R/queue" "*-$id.md")" = "1" ]; then ok "requeue returns it to the queue"; else bad "requeue" "id $id"; fi
out="$("$F" claim seat-2)"; id="$(basename "$out" .md)"; id="${id#*-}"
"$F" done "$id" done "selftest" >/dev/null
if [ "$(count "$R/archive" "*$id*.md")" = "1" ]; then ok "done archives it"; else bad "done" "id $id"; fi

echo "== affinity prefers warm-context work, within the head band only =="
mkT() {  # mkT <touches> <title> -> prints the queue path
  local d="$R/draft.md"
  { echo "---"; echo "touches: $1"; echo "---"; echo "# $2"; } > "$d"
  "$F" new "$d"
}
# These seats close service-touching tasks with done, so the help gate (task
# 1786918240) requires their round markers to carry a help declaration.
for w in seat-aff seat-af2 seat-af3 seat-af4; do
  echo "help: no user-facing change" > "$R/$w.done"
done
mkT open-email "affinity email one" >/dev/null
p_crm="$(mkT open-crm "affinity crm one")"
mkT open-email "affinity email two" >/dev/null
out="$("$F" claim seat-aff --affinity open-crm)"
if grep -q "affinity crm one" "$out" 2>/dev/null; then ok "affinity picks the matching task over the head"; else bad "affinity match" "got '$out'"; fi
if grep -q "(affinity)" "$out" 2>/dev/null; then ok "affinity pick is stamped"; else bad "affinity stamp" "$(tail -3 "$out")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-af2 --affinity open-teamboard)"
if grep -q "affinity email one" "$out" 2>/dev/null; then ok "no match falls back to the plain head"; else bad "affinity fallback" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# never cross bands: promote the email task above a matching crm task
p_two="$("$F" list --consumer | grep "affinity email two" | head -1)"
id_two="${p_two%%.md*}"; id_two="${id_two#*-}"
mkT open-crm "affinity crm two" >/dev/null
"$F" reprioritize "$id_two" 05 >/dev/null
out="$("$F" claim seat-af3 --affinity open-crm)"
if grep -q "affinity email two" "$out" 2>/dev/null; then ok "affinity never crosses into a lower band"; else bad "band ceiling" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-af4 --affinity open-crm)"
if grep -q "affinity crm two" "$out" 2>/dev/null; then ok "the crm task is next once the band clears"; else bad "band drain" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null

echo "== overlap-defer ignores repo-wide tokens (docs, README) but still gates on service tokens =="
# These seats close service-touching tasks with done, so the help gate needs
# their round markers to carry a help declaration.
for w in seat-ov1 seat-ov2 seat-ov3 seat-ov4 seat-ov5 seat-ov6 seat-ov7; do
  echo "help: no user-facing change" > "$R/$w.done"
done
mkT "open-crm, docs, README" "overlap holder crm docs readme" >/dev/null
out="$("$F" claim seat-ov1)"
if grep -q "overlap holder" "$out" 2>/dev/null; then ok "holder claimed (the active claim lists open-crm, docs and README)"; else bad "overlap holder" "got '$out'"; fi
id_ov_hold="$(basename "$out" .md)"; id_ov_hold="${id_ov_hold#*-}"
mkT "open-email, docs" "overlap shares only docs" >/dev/null
# A free task BEHIND it, so the take-the-head-anyway fallback cannot pass
# this case on an engine that still defers on docs.
mkT "open-calendar" "overlap free behind docs" >/dev/null
out="$("$F" claim seat-ov2)"
if grep -q "overlap shares only docs" "$out" 2>/dev/null; then ok "a task sharing only docs with an active claim is offered ahead of the free task behind it, not overlap-deferred"; else bad "docs never gates" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-ov2)"
if grep -q "overlap free behind docs" "$out" 2>/dev/null; then ok "the free task is next"; else bad "docs case drain" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
mkT "open-crm, docs" "overlap shares crm" >/dev/null
mkT "open-hr" "overlap free behind crm" >/dev/null
out="$("$F" claim seat-ov3)"
if grep -q "overlap free behind crm" "$out" 2>/dev/null; then ok "a shared service token still defers: the free task behind it is taken"; else bad "service token gates" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
mkT "README, open-hr" "overlap shares only readme" >/dev/null
out="$("$F" claim seat-ov3)"
if grep -q "overlap shares only readme" "$out" 2>/dev/null; then ok "README is repo-wide too: offered past the deferred crm task"; else bad "readme never gates" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# A custom list: open-crm is ignored BESIDE a code token (open-signing), so the
# crm gate lifts for that task, while "overlap shares crm" (open-crm, docs -
# every token on the list, so none is skipped: the docs-only rule below) stays
# deferred behind it.
mkT "open-crm, docs, open-signing" "overlap shares crm beside signing" >/dev/null
out="$(env FACTORY_OVERLAP_IGNORE=docs,open-crm "$F" claim seat-ov5)"
if grep -q "overlap shares crm beside signing" "$out" 2>/dev/null; then ok "a custom comma list (docs,open-crm) lifts the crm gate for a task that also names a code token"; else bad "custom list" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
mkT "open-email, docs" "overlap docs strict" >/dev/null
mkT "open-hr" "overlap free strict" >/dev/null
out="$(env FACTORY_OVERLAP_IGNORE= "$F" claim seat-ov4)"
if grep -q "overlap free strict" "$out" 2>/dev/null; then ok "FACTORY_OVERLAP_IGNORE= (empty) gates on docs again"; else bad "strict mode" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-ov5 --affinity docs)"
if grep -q "overlap docs strict" "$out" 2>/dev/null && grep -q "(affinity)" "$out" 2>/dev/null; then ok "affinity still matches on docs (only the defer side ignores it)"; else bad "affinity keeps docs" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# The refinement (2026-10-03): a repo-wide token is skipped only BESIDE a code
# token. A docs-only task's tokens are its whole surface, so they all count:
# it defers behind a claim naming docs, and two docs-only tasks defer each
# other - the same standards page is where they would meet.
mkT "docs" "overlap docs only" >/dev/null
mkT "open-it-assets" "overlap free behind docs only" >/dev/null
out="$("$F" claim seat-ov6)"
if grep -q "overlap free behind docs only" "$out" 2>/dev/null; then ok "a docs-only task (touches: docs) still defers behind the active claim naming docs: the free task behind it is taken"; else bad "docs-only defers" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
"$F" done "$id_ov_hold" done >/dev/null
if [ "$(count "$R/claimed" "*-$id_ov_hold.md")" = "0" ]; then ok "holder released"; else bad "holder cleanup" "id $id_ov_hold"; fi
out="$("$F" claim seat-ov5)"
if grep -q "overlap shares crm" "$out" 2>/dev/null; then ok "the crm task flows once the holder is released"; else bad "crm drain" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-ov6)"
if grep -q "overlap docs only" "$out" 2>/dev/null; then ok "the docs-only task is claimed next - the active claim for the two checks below"; else bad "docs-only holder" "got '$out'"; fi
id_docs_hold="$(basename "$out" .md)"; id_docs_hold="${id_docs_hold#*-}"
mkT "open-email, docs" "overlap code past docs-only holder" >/dev/null
out="$("$F" claim seat-ov7)"
if grep -q "overlap code past docs-only holder" "$out" 2>/dev/null; then ok "a code task's docs token is ignored against a docs-only active claim: offered"; else bad "code past docs-only" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
mkT "docs" "overlap second docs only" >/dev/null
mkT "open-expenses" "overlap free behind second docs only" >/dev/null
out="$("$F" claim seat-ov7)"
if grep -q "overlap free behind second docs only" "$out" 2>/dev/null; then ok "two docs-only tasks defer each other: the free task behind the second is taken"; else bad "docs-only pair" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
"$F" done "$id_docs_hold" done >/dev/null
out="$("$F" claim seat-ov7)"
if grep -q "overlap second docs only" "$out" 2>/dev/null; then ok "the second docs-only task flows once the first is done; queue back to its pre-section state"; else bad "docs-only drain" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null

echo "== graded overlap fallback: a suite-wide claim never collapses the gate (task 1792508144) =="
# The 2026-10-20 shape: one seat holds a suite-wide wave (every queued task
# overlaps through the suite rule, for hours), another holds the factory
# script, and the queue's head shares that script with the second claim while
# a task free of every token sits behind it. The fallback order is suite-only
# before DIRECT - never the plain head - and the claim says which it took, on
# stderr and on its Factory log stamp; the board marks a DIRECT claim.
for w in seat-gf1 seat-gf2 seat-gf3 seat-gf4 seat-gf5; do
  echo "help: no user-facing change" > "$R/$w.done"
done
# Still active from the first sections: seat-1's claim (no touches at all -
# it overlaps nothing) and the operator's lane claim (touches nothing-<pid>-<n>),
# so the suite-wide task below is itself a suite-only fallback by the
# task-side rule (a suite task waits behind ANY claim) - never DIRECT.
mkT "suite" "graded holder suite wave" >/dev/null
out="$("$F" claim seat-gf1 2>"$R/gf1.err")"
if grep -q "graded holder suite wave" "$out" 2>/dev/null; then ok "the suite-wide holder is claimed"; else bad "suite holder" "got '$out'"; fi
id_gf_suite="$(basename "$out" .md)"; id_gf_suite="${id_gf_suite#*-}"
if ! grep -q "overlap fallback: DIRECT" "$R/gf1.err" && ! grep -q "overlap fallback: DIRECT" "$out" 2>/dev/null; then ok "a suite-wide task behind an unrelated claim is at most a suite-only fallback, never DIRECT"; else bad "suite task grade" "$(cat "$R/gf1.err"; tail -1 "$out")"; fi
mkT "scripts/factory.sh, .claude/skills/mdex-software-factory/SKILL.md" "graded holder factory script" >/dev/null
out="$("$F" claim seat-gf2 2>"$R/gf2.err")"
if grep -q "graded holder factory script" "$out" 2>/dev/null; then ok "under the suite-wide claim the script holder is still handed out: suite-only is a fallback, not a refusal"; else bad "script holder" "got '$out'"; fi
id_gf_script="$(basename "$out" .md)"; id_gf_script="${id_gf_script#*-}"
if grep -q "^factory: overlap fallback: suite-only (behind seat-gf1's $id_gf_suite)\$" "$R/gf2.err"; then ok "stderr names the suite-only fallback and the suite-wide claim it sits behind"; else bad "suite-only stderr" "$(cat "$R/gf2.err")"; fi
if grep -q "^- claimed by seat-gf2 at [0-9TZ:-]* - overlap fallback: suite-only (behind seat-gf1's $id_gf_suite)\$" "$out"; then ok "the Factory log stamp carries the same words after the instant"; else bad "suite-only stamp" "$(tail -2 "$out")"; fi
p_gf_collide="$(mkT "scripts/factory.sh, .claude/skills/mdex-software-factory/SKILL.md" "graded collides on factory script")"
id_gf_collide="$(basename "$p_gf_collide" .md)"; id_gf_collide="${id_gf_collide#*-}"
mkT "packages/auth-session" "graded free of every token" >/dev/null
out="$("$F" claim seat-gf3 2>"$R/gf3.err")"
if grep -q "graded free of every token" "$out" 2>/dev/null; then ok "the head shares scripts/factory.sh with seat-gf2's claim: passed over for the task behind it that overlaps only through suite"; else bad "graded order" "got '$out'"; fi
if grep -q "^factory: overlap fallback: suite-only (behind seat-gf1's $id_gf_suite)\$" "$R/gf3.err"; then ok "that claim logs suite-only"; else bad "graded stderr" "$(cat "$R/gf3.err")"; fi
if [ "$(count "$R/queue" "*-$id_gf_collide.md")" = "1" ]; then ok "the colliding task stays queued"; else bad "colliding task queued" "$(ls "$R/queue")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-gf4 2>"$R/gf4.err")"
if grep -q "graded collides on factory script" "$out" 2>/dev/null; then ok "with only the colliding task left it is taken: a DIRECT collision is the last resort, not a refusal"; else bad "direct last resort" "got '$out'"; fi
if grep -q "^factory: overlap fallback: DIRECT - shares 'scripts/factory.sh' with seat-gf2's $id_gf_script\$" "$R/gf4.err"; then ok "stderr names the DIRECT fallback, the shared token and the claim it collides with"; else bad "direct stderr" "$(cat "$R/gf4.err")"; fi
if grep -q "^- claimed by seat-gf4 at [0-9TZ:-]* - overlap fallback: DIRECT - shares 'scripts/factory.sh' with seat-gf2's $id_gf_script\$" "$out"; then ok "the DIRECT stamp carries the same words"; else bad "direct stamp" "$(tail -2 "$out")"; fi
"$F" index >/dev/null
if grep -q "^- \`$(basename "$out")\` <- seat-gf4 ([0-9]*m) \*\*DIRECT-OVERLAP\*\* graded collides on factory script\$" "$R/factory/index.md"; then ok "the board marks the DIRECT claim's row DIRECT-OVERLAP"; else bad "board marker" "$(grep 'seat-gf' "$R/factory/index.md")"; fi
if grep -q "<- seat-gf2 ([0-9]*m) graded holder factory script\$" "$R/factory/index.md" && grep -q "<- seat-gf1 ([0-9]*m) graded holder suite wave\$" "$R/factory/index.md"; then ok "the suite-only and plain claims' rows carry no marker"; else bad "board marker scope" "$(grep 'seat-gf' "$R/factory/index.md")"; fi
if [ "$(grep -c "overlap fallback" "$R/gf3.err")" = "1" ] && [ "$(grep -c "overlap fallback" "$R/gf4.err")" = "1" ]; then ok "exactly one fallback line per fallback claim"; else bad "fallback line count" "$(cat "$R/gf3.err" "$R/gf4.err")"; fi
for id in "$id_gf_collide" "$id_gf_script" "$id_gf_suite"; do "$F" done "$id" done >/dev/null; done
if [ "$(count "$R/claimed" "*-$id_gf_suite.md")$(count "$R/claimed" "*-$id_gf_script.md")$(count "$R/claimed" "*-$id_gf_collide.md")" = "000" ]; then ok "the section's holders are released"; else bad "graded cleanup" "$(ls "$R"/claimed/*/)"; fi
# No suite-wide claim and no shared token left: a plain claim carries no
# fallback words at all - stderr and stamp alike.
mkT "packages/theme" "graded plain after release" >/dev/null
out="$("$F" claim seat-gf5 2>"$R/gf5.err")"
if grep -q "graded plain after release" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/gf5.err" && ! grep -q "overlap fallback" "$out"; then ok "a claim with nothing to overlap carries no fallback words (stderr and stamp); queue back to its pre-section state"; else bad "no-fallback silence" "$(cat "$R/gf5.err"; tail -1 "$out")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null

echo "== band precedence beats the suite rule's soft defer (task 1792540242) =="
# The 2026-10-21 shape: every seat holds a claim, the operator-ruled suite
# wave sits at band 03, and a band-30 hygiene task is the first FREE task -
# the loop consulted the soft slots only when nothing was free, so the wave
# starved behind the hygiene pool for as long as any claim was active. Now a
# suite-only soft candidate in a STRICTLY higher band than the task about to
# be chosen IS the claim, and the stamp says why; equal bands keep the free
# task (the defer still protects same-rank work), a lower-ranked suite task
# waits as before, and a DIRECT candidate never gains precedence.
for w in seat-bp1 seat-bp2 seat-bp3 seat-bp4 seat-bp5; do
  echo "help: no user-facing change" > "$R/$w.done"
done
# Still active from the first sections: seat-1's claim (no touches - it
# overlaps nothing) and the operator's lane claim (touches nothing-<pid>-<n>)
# - the FIRST claim in glob order that a suite-wide task overlaps, so the
# fallback's "behind" names it.
op_claim=""; for f in "$R"/claimed/operator/*.md; do op_claim="$f"; done
id_bp_op="$(basename "$op_claim" .md)"; id_bp_op="${id_bp_op#*-}"
if [ "$(count "$R/claimed/operator" '*.md')" = "1" ]; then ok "one operator-lane claim is active (the claim a suite-wide task is reported behind)"; else bad "operator claim count" "$(ls "$R"/claimed/operator/)"; fi
mkT "open-crm" "band holder crm" >/dev/null
out="$("$F" claim seat-bp1 2>"$R/bp1.err")"
if grep -q "band holder crm" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/bp1.err"; then ok "a seat holds a concrete token (open-crm), claimed plainly"; else bad "band holder" "got '$out' / $(cat "$R/bp1.err")"; fi
id_bp_hold="$(basename "$out" .md)"; id_bp_hold="${id_bp_hold#*-}"
p_bp="$(mkT "suite, packages/ask-ai" "band suite wave")"
id_bp_suite="$(basename "$p_bp" .md)"; id_bp_suite="${id_bp_suite#*-}"
p_bp="$(mkT "open-email" "band free hygiene")"
id_bp_free="$(basename "$p_bp" .md)"; id_bp_free="${id_bp_free#*-}"
"$F" reprioritize "$id_bp_suite" 03 >/dev/null
"$F" reprioritize "$id_bp_free" 30 >/dev/null
out="$("$F" claim seat-bp2 2>"$R/bp2.err")"
if grep -q "band suite wave" "$out" 2>/dev/null; then ok "(a) a band-03 suite task and a band-30 free task under an active claim: the suite task is claimed"; else bad "band precedence" "got '$out'"; fi
if grep -q "^factory: overlap fallback: suite-only (band 03 outranks the free band 30; behind operator's $id_bp_op)\$" "$R/bp2.err"; then ok "stderr says why: the band that outranks, the free band passed over, the claim it sits behind"; else bad "precedence stderr" "$(cat "$R/bp2.err")"; fi
if grep -q "^- claimed by seat-bp2 at [0-9TZ:-]* - overlap fallback: suite-only (band 03 outranks the free band 30; behind operator's $id_bp_op)\$" "$out"; then ok "the Factory log stamp carries the same words after the instant"; else bad "precedence stamp" "$(tail -2 "$out")"; fi
if [ "$(count "$R/queue" "*-$id_bp_free.md")" = "1" ]; then ok "the band-30 free task stays queued"; else bad "free task queued" "$(ls "$R/queue")"; fi
"$F" index >/dev/null
if grep -q "<- seat-bp2 ([0-9]*m) band suite wave\$" "$R/factory/index.md"; then ok "the board carries no DIRECT-OVERLAP marker on the precedence claim"; else bad "board marker" "$(grep 'seat-bp' "$R/factory/index.md")"; fi
"$F" done "$id_bp_suite" done >/dev/null
# Affinity is unchanged: it reorders within the head band only, and a suite
# task that outranks that band simply IS the claim - stamped as the fallback,
# never "(affinity)".
p_bp="$(mkT "suite" "band suite wave two")"
id_bp_suite2="$(basename "$p_bp" .md)"; id_bp_suite2="${id_bp_suite2#*-}"
"$F" reprioritize "$id_bp_suite2" 03 >/dev/null
out="$("$F" claim seat-bp3 --affinity open-email 2>"$R/bp3.err")"
if grep -q "band suite wave two" "$out" 2>/dev/null; then ok "with --affinity matching the band-30 free task, the band-03 suite task still wins"; else bad "affinity vs precedence" "got '$out'"; fi
if grep -q "^- claimed by seat-bp3 at [0-9TZ:-]* - overlap fallback: suite-only (band 03 outranks the free band 30; behind operator's $id_bp_op)\$" "$out" && ! grep -q "(affinity)" "$out"; then ok "stamped as the fallback, never (affinity)"; else bad "affinity stamp" "$(tail -2 "$out")"; fi
"$F" done "$id_bp_suite2" done >/dev/null
# (b) equal bands: today's rule - the free task wins, no fallback words.
p_bp="$(mkT "suite" "band suite wave three")"
id_bp_suite3="$(basename "$p_bp" .md)"; id_bp_suite3="${id_bp_suite3#*-}"
mkT "open-hr" "band free equal" >/dev/null
out="$("$F" claim seat-bp4 2>"$R/bp4.err")"
if grep -q "band free equal" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/bp4.err" && ! grep -q "overlap fallback" "$out"; then ok "(b) both at band 17: the free task is taken, plainly"; else bad "equal bands" "got '$out' / $(cat "$R/bp4.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# (c) the suite task in a LOWER band than the free task: the free task wins.
"$F" reprioritize "$id_bp_suite3" 30 >/dev/null
mkT "open-hr" "band free outranks" >/dev/null
out="$("$F" claim seat-bp4 2>"$R/bp4.err")"
if grep -q "band free outranks" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/bp4.err"; then ok "(c) suite at band 30, free at band 17: the free task is taken, plainly"; else bad "lower suite band" "got '$out' / $(cat "$R/bp4.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# Drain: the band-30 free task ahead of the equal-band suite task, then the
# suite task as the plain suite-only fallback (nothing free left - the
# pre-task words, unchanged).
out="$("$F" claim seat-bp5 2>"$R/bp5.err")"
if grep -q "band free hygiene" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/bp5.err"; then ok "the band-30 free task is taken ahead of the equal-band suite task"; else bad "band-30 drain" "got '$out' / $(cat "$R/bp5.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-bp5 2>"$R/bp5.err")"
if grep -q "band suite wave three" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: suite-only (behind operator's $id_bp_op)\$" "$R/bp5.err"; then ok "with nothing free left the suite task is the plain suite-only fallback, in the pre-task words"; else bad "plain suite-only" "got '$out' / $(cat "$R/bp5.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
"$F" done "$id_bp_hold" done >/dev/null
if [ "$(count "$R/claimed" "*-$id_bp_hold.md")$(count "$R/claimed" "*-$id_bp_suite.md")$(count "$R/claimed" "*-$id_bp_suite2.md")$(count "$R/claimed" "*-$id_bp_suite3.md")" = "0000" ]; then ok "the section's holders are released; queue back to its pre-section state"; else bad "band cleanup" "$(ls "$R"/claimed/*/)"; fi

echo "== expedited precedence over the DIRECT soft defer (task 1792553976) =="
# The 2026-10-21 shape: the band-05 fix for the red story-smoke gate shared
# scripts/story-smoke with four live band-30 story promotions (whose LAST
# verify step was that very gate), and the DIRECT soft slot was consulted
# only when nothing was free - hours of red gate behind every free band-30
# task. Now a DIRECT soft candidate in an EXPEDITED band (00-09) strictly
# higher (lower-numbered) than the band of the pick in hand IS the claim,
# stamped with the band words (still a DIRECT stamp: the board marks the
# row); equal bands keep the pick in hand, the band ORDER rules inside the
# zone (05 still waits behind free 03), and from band 10 up a DIRECT
# candidate never gains precedence - the pre-task words, unchanged.
for w in seat-xd0 seat-xd1 seat-xd2 seat-xd3 seat-xd4 seat-xd5 seat-xd6 seat-xd7 seat-xs; do
  echo "help: no user-facing change" > "$R/$w.done"
done
op_claim=""; for f in "$R"/claimed/operator/*.md; do op_claim="$f"; done
id_xd_op="$(basename "$op_claim" .md)"; id_xd_op="${id_xd_op#*-}"
mkT "open-crm, scripts/story-smoke" "expedite holder story promotion" >/dev/null
out="$("$F" claim seat-xd0 2>"$R/xd0.err")"
if grep -q "expedite holder story promotion" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/xd0.err"; then ok "a seat holds a concrete token (scripts/story-smoke), claimed plainly"; else bad "expedite holder" "got '$out' / $(cat "$R/xd0.err")"; fi
id_xd_hold="$(basename "$out" .md)"; id_xd_hold="${id_xd_hold#*-}"
xd_words="DIRECT - shares 'scripts/story-smoke' with seat-xd0's $id_xd_hold"
# (a) a band-05 DIRECT task vs a free band-30 task: the 05 is the claim.
p_xd="$(mkT "scripts/story-smoke, open-email" "expedite gate fix")"
id_xd_fix="$(basename "$p_xd" .md)"; id_xd_fix="${id_xd_fix#*-}"
p_xd="$(mkT "open-hr" "expedite free hygiene")"
id_xd_free="$(basename "$p_xd" .md)"; id_xd_free="${id_xd_free#*-}"
"$F" reprioritize "$id_xd_fix" 05 >/dev/null
"$F" reprioritize "$id_xd_free" 30 >/dev/null
out="$("$F" claim seat-xd1 2>"$R/xd1.err")"
if grep -q "expedite gate fix" "$out" 2>/dev/null; then ok "(a) a band-05 task sharing scripts/story-smoke with the holder and a band-30 free task: the band-05 task is claimed"; else bad "expedited precedence" "got '$out'"; fi
if grep -q "^factory: overlap fallback: $xd_words (band 05 outranks the free band 30)\$" "$R/xd1.err"; then ok "stderr says why: the DIRECT words, then the band that outranks and the free band passed over"; else bad "expedited stderr" "$(cat "$R/xd1.err")"; fi
if grep -q "^- claimed by seat-xd1 at [0-9TZ:-]* - overlap fallback: $xd_words (band 05 outranks the free band 30)\$" "$out"; then ok "the Factory log stamp carries the same words after the instant"; else bad "expedited stamp" "$(tail -2 "$out")"; fi
if [ "$(count "$R/queue" "*-$id_xd_free.md")" = "1" ]; then ok "the band-30 free task stays queued"; else bad "free task queued" "$(ls "$R/queue")"; fi
"$F" index >/dev/null
if grep -q "^- \`$(basename "$out")\` <- seat-xd1 ([0-9]*m) \*\*DIRECT-OVERLAP\*\* expedite gate fix\$" "$R/factory/index.md"; then ok "the board still marks the row DIRECT-OVERLAP: a collision taken on purpose stays visible"; else bad "board marker" "$(grep 'seat-xd' "$R/factory/index.md")"; fi
"$F" done "$id_xd_fix" done >/dev/null
# (b) equal bands: a band-05 DIRECT task vs a free band-05 task - the free
# task wins, plainly (the defer still protects same-rank work).
p_xd="$(mkT "scripts/story-smoke" "expedite gate fix two")"
id_xd_fix2="$(basename "$p_xd" .md)"; id_xd_fix2="${id_xd_fix2#*-}"
p_xd="$(mkT "open-projects" "expedite free equal")"
id_xd_eq="$(basename "$p_xd" .md)"; id_xd_eq="${id_xd_eq#*-}"
"$F" reprioritize "$id_xd_fix2" 05 >/dev/null
"$F" reprioritize "$id_xd_eq" 05 >/dev/null
out="$("$F" claim seat-xd2 2>"$R/xd2.err")"
if grep -q "expedite free equal" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/xd2.err" && ! grep -q "overlap fallback" "$out"; then ok "(b) both at band 05: the free task is taken, plainly"; else bad "equal bands" "got '$out' / $(cat "$R/xd2.err")"; fi
if [ "$(count "$R/queue" "*-$id_xd_fix2.md")" = "1" ]; then ok "the band-05 DIRECT task stays queued"; else bad "equal-band direct queued" "$(ls "$R/queue")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# The band ORDER rules inside the expedited zone: a band-05 DIRECT task vs
# a free band-03 task - the band-03 task is taken (03 outranks 05; a fix
# that must go ahead of band-03 work is banded 00-02).
p_xd="$(mkT "open-knowledge" "expedite free architecture")"
id_xd_arch="$(basename "$p_xd" .md)"; id_xd_arch="${id_xd_arch#*-}"
"$F" reprioritize "$id_xd_arch" 03 >/dev/null
out="$("$F" claim seat-xd2 2>"$R/xd2.err")"
if grep -q "expedite free architecture" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/xd2.err"; then ok "a band-05 DIRECT task vs a free band-03 task: the band-03 task is taken, plainly (the band order rules inside the zone)"; else bad "band order inside the zone" "got '$out' / $(cat "$R/xd2.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# (e) band 00 - emergency: vs a free band-03 task the 00 wins.
p_xd="$(mkT "scripts/story-smoke" "expedite emergency fix")"
id_xd_em="$(basename "$p_xd" .md)"; id_xd_em="${id_xd_em#*-}"
p_xd="$(mkT "open-signing" "expedite free architecture two")"
id_xd_arch2="$(basename "$p_xd" .md)"; id_xd_arch2="${id_xd_arch2#*-}"
"$F" reprioritize "$id_xd_em" 00 >/dev/null
"$F" reprioritize "$id_xd_arch2" 03 >/dev/null
out="$("$F" claim seat-xd3 2>"$R/xd3.err")"
if grep -q "expedite emergency fix" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: $xd_words (band 00 outranks the free band 03)\$" "$R/xd3.err"; then ok "(e) a band-00 DIRECT task vs a free band-03 task: the emergency is claimed, stamped (band 00 outranks the free band 03)"; else bad "band 00" "got '$out' / $(cat "$R/xd3.err")"; fi
"$F" done "$id_xd_em" done >/dev/null
# Drain the band-03 free task (ahead of the band-05 DIRECT task: the order),
# then the band-05 task over the band-30 free task.
out="$("$F" claim seat-xd3 2>"$R/xd3.err")"
if grep -q "expedite free architecture two" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/xd3.err"; then ok "the band-03 free task drains ahead of the band-05 DIRECT task"; else bad "band-03 drain" "got '$out' / $(cat "$R/xd3.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-xd3 2>"$R/xd3.err")"
if grep -q "expedite gate fix two" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: $xd_words (band 05 outranks the free band 30)\$" "$R/xd3.err"; then ok "then the band-05 DIRECT task over the band-30 free task"; else bad "band-05 drain" "got '$out' / $(cat "$R/xd3.err")"; fi
"$F" done "$id_xd_fix2" done >/dev/null
# (c) from band 10 up nothing changes: a band-17 DIRECT task vs a free
# band-30 task - the free task wins; alone, the DIRECT task is the plain
# last-resort fallback in the pre-task words (no band clause).
p_xd="$(mkT "scripts/story-smoke" "expedite natural collision")"
id_xd_nat="$(basename "$p_xd" .md)"; id_xd_nat="${id_xd_nat#*-}"
out="$("$F" claim seat-xd4 2>"$R/xd4.err")"
if grep -q "expedite free hygiene" "$out" 2>/dev/null && ! grep -q "overlap fallback" "$R/xd4.err"; then ok "(c) a band-17 DIRECT task vs a free band-30 task: the free task is taken, plainly (no precedence from band 10 up)"; else bad "natural zone unchanged" "got '$out' / $(cat "$R/xd4.err")"; fi
"$F" done "$id_xd_free" done >/dev/null
out="$("$F" claim seat-xd4 2>"$R/xd4.err")"
if grep -q "expedite natural collision" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: $xd_words\$" "$R/xd4.err"; then ok "with nothing free left the band-17 DIRECT task is the plain last resort, in the pre-task words (no band clause)"; else bad "plain direct" "got '$out' / $(cat "$R/xd4.err")"; fi
"$F" done "$id_xd_nat" done >/dev/null
# (d) a DIRECT task at band 03, a suite-wide task at band 05, a free task at
# band 30: the suite-precedence block picks the suite task first, then the
# DIRECT task outranks THAT pick - the clause names the band displaced.
p_xd="$(mkT "scripts/story-smoke" "expedite fix over suite pick")"
id_xd_fixd="$(basename "$p_xd" .md)"; id_xd_fixd="${id_xd_fixd#*-}"
p_xd="$(mkT "suite" "expedite suite wave")"
id_xd_suite="$(basename "$p_xd" .md)"; id_xd_suite="${id_xd_suite#*-}"
p_xd="$(mkT "open-hr" "expedite free hygiene two")"
id_xd_free2="$(basename "$p_xd" .md)"; id_xd_free2="${id_xd_free2#*-}"
"$F" reprioritize "$id_xd_fixd" 03 >/dev/null
"$F" reprioritize "$id_xd_suite" 05 >/dev/null
"$F" reprioritize "$id_xd_free2" 30 >/dev/null
out="$("$F" claim seat-xd5 2>"$R/xd5.err")"
if grep -q "expedite fix over suite pick" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: $xd_words (band 03 outranks the free band 05)\$" "$R/xd5.err"; then ok "(d) DIRECT at 03 + suite at 05 + free at 30: the DIRECT task outranks the suite-precedence pick, stamped (band 03 outranks the free band 05)"; else bad "direct over suite pick" "got '$out' / $(cat "$R/xd5.err")"; fi
if [ "$(count "$R/queue" "*-$id_xd_suite.md")$(count "$R/queue" "*-$id_xd_free2.md")" = "11" ]; then ok "the suite task and the free task stay queued"; else bad "d queued" "$(ls "$R/queue")"; fi
"$F" done "$id_xd_fixd" done >/dev/null
# Equal: a DIRECT task at band 05 beside the band-05 suite task - the suite
# pick stands, in the suite words.
p_xd="$(mkT "scripts/story-smoke" "expedite fix equal to suite pick")"
id_xd_fixe="$(basename "$p_xd" .md)"; id_xd_fixe="${id_xd_fixe#*-}"
"$F" reprioritize "$id_xd_fixe" 05 >/dev/null
out="$("$F" claim seat-xd5 2>"$R/xd5.err")"
if grep -q "expedite suite wave" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: suite-only (band 05 outranks the free band 30; behind operator's $id_xd_op)\$" "$R/xd5.err"; then ok "a band-05 DIRECT task beside the band-05 suite-precedence pick: the suite pick stands, in the suite words"; else bad "equal to suite pick" "got '$out' / $(cat "$R/xd5.err")"; fi
"$F" done "$id_xd_suite" done >/dev/null
# (f) affinity: two band-17 free tasks, --affinity naming the second, and
# the band-05 DIRECT task queued - the DIRECT task wins, never stamped
# "(affinity)"; without it affinity still picks the second.
mkT "open-signing" "expedite free natural one" >/dev/null
mkT "open-email" "expedite free natural two" >/dev/null
out="$("$F" claim seat-xd6 --affinity open-email 2>"$R/xd6.err")"
if grep -q "expedite fix equal to suite pick" "$out" 2>/dev/null; then ok "(f) with --affinity matching a band-17 free task, the band-05 DIRECT task still wins"; else bad "affinity vs expedited" "got '$out'"; fi
if grep -q "^- claimed by seat-xd6 at [0-9TZ:-]* - overlap fallback: $xd_words (band 05 outranks the free band 17)\$" "$out" && ! grep -q "(affinity)" "$out"; then ok "stamped as the fallback (band 05 outranks the free band 17), never (affinity)"; else bad "affinity stamp" "$(tail -2 "$out")"; fi
"$F" done "$id_xd_fixe" done >/dev/null
out="$("$F" claim seat-xd6 --affinity open-email 2>"$R/xd6.err")"
if grep -q "expedite free natural two" "$out" 2>/dev/null && grep -q "(affinity)" "$out" && ! grep -q "overlap fallback" "$R/xd6.err"; then ok "with no expedited collision queued, affinity picks its match as before"; else bad "affinity intact" "got '$out' / $(cat "$R/xd6.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-xd6)"; id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-xd6)"
if grep -q "expedite free hygiene two" "$out" 2>/dev/null; then ok "the remaining free tasks drain plainly"; else bad "f drain" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# (g) under a suite-wide claim NOTHING is free: the graded fallback picks
# the first suite-only task, and an expedited DIRECT task in a strictly
# higher band outranks that pick too (the live 2026-10-21 queue: one seat
# holding `suite`, the band-05 gate fix behind natural-zone work).
mkT "suite" "expedite holder suite wave" >/dev/null
out="$("$F" claim seat-xs 2>"$R/xs.err")"
if grep -q "expedite holder suite wave" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: suite-only (behind operator's $id_xd_op)\$" "$R/xs.err"; then ok "a seat holds a suite-wide claim (itself the plain suite-only fallback)"; else bad "suite holder" "got '$out' / $(cat "$R/xs.err")"; fi
id_xs="$(basename "$out" .md)"; id_xs="${id_xs#*-}"
p_xd="$(mkT "scripts/story-smoke" "expedite fix under suite claim")"
id_xd_fixg="$(basename "$p_xd" .md)"; id_xd_fixg="${id_xd_fixg#*-}"
mkT "open-hr" "expedite blanket only natural" >/dev/null
"$F" reprioritize "$id_xd_fixg" 05 >/dev/null
out="$("$F" claim seat-xd7 2>"$R/xd7.err")"
if grep -q "expedite fix under suite claim" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: $xd_words (band 05 outranks the free band 17)\$" "$R/xd7.err"; then ok "(g) nothing free under the suite-wide claim: the band-05 DIRECT task outranks the band-17 suite-only fallback pick"; else bad "direct over suite-only fallback" "got '$out' / $(cat "$R/xd7.err")"; fi
"$F" done "$id_xd_fixg" done >/dev/null
p_xd="$(mkT "scripts/story-smoke" "expedite fix under suite claim two")"
id_xd_fixh="$(basename "$p_xd" .md)"; id_xd_fixh="${id_xd_fixh#*-}"
p_xd="$(mkT "open-projects" "expedite blanket only equal")"
id_xd_blk="$(basename "$p_xd" .md)"; id_xd_blk="${id_xd_blk#*-}"
"$F" reprioritize "$id_xd_fixh" 05 >/dev/null
"$F" reprioritize "$id_xd_blk" 05 >/dev/null
out="$("$F" claim seat-xd7 2>"$R/xd7.err")"
if grep -q "expedite blanket only equal" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: suite-only (behind seat-xs's $id_xs)\$" "$R/xd7.err"; then ok "equal bands under the suite-wide claim: the suite-only pick stands, in the plain suite-only words"; else bad "equal under suite claim" "got '$out' / $(cat "$R/xd7.err")"; fi
"$F" done "$id_xd_blk" done >/dev/null
out="$("$F" claim seat-xd7 2>"$R/xd7.err")"
if grep -q "expedite fix under suite claim two" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: $xd_words (band 05 outranks the free band 17)\$" "$R/xd7.err"; then ok "then the band-05 DIRECT task over the band-17 suite-only pick"; else bad "g drain" "got '$out' / $(cat "$R/xd7.err")"; fi
"$F" done "$id_xd_fixh" done >/dev/null
out="$("$F" claim seat-xd7 2>"$R/xd7.err")"
if grep -q "expedite blanket only natural" "$out" 2>/dev/null && grep -q "^factory: overlap fallback: suite-only (behind seat-xs's $id_xs)\$" "$R/xd7.err"; then ok "the band-17 suite-only task drains last, in the plain words"; else bad "blanket drain" "got '$out' / $(cat "$R/xd7.err")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
"$F" done "$id_xs" done >/dev/null
"$F" done "$id_xd_hold" done >/dev/null
if [ "$(count "$R/claimed" "*-$id_xd_hold.md")$(count "$R/claimed" "*-$id_xs.md")" = "00" ] && ! grep -q "^# expedite" "$R"/queue/*.md 2>/dev/null; then ok "the section's holders are released; queue back to its pre-section state"; else bad "expedite cleanup" "$(ls "$R"/claimed/*/ "$R"/queue)"; fi

echo "== targeted operator claim (--id): the safe-edit tweezers =="
p_t="$(mkT open-hr "targeted answer me")"
id_t="$(basename "$p_t" .md)"; id_t="${id_t#*-}"
if "$F" claim seat-x --id "$id_t" >/dev/null 2>&1; then bad "--id gate" "--id without --operator was allowed"; else ok "--id refused without --operator"; fi
out="$("$F" claim --operator --id "$id_t")"
case "$out" in
  */claimed/operator/*) ok "targeted claim lands in the operator dir" ;;
  *) bad "targeted claim" "got '$out'" ;;
esac
if grep -q "(targeted)" "$out" 2>/dev/null; then ok "targeted claim is stamped"; else bad "targeted stamp" "$(tail -2 "$out" 2>/dev/null)"; fi
"$F" requeue "$id_t" "answered by the operator" >/dev/null
if [ "$(count "$R/queue" "*-$id_t.md")" = "1" ]; then ok "requeue releases it back to the queue"; else bad "release" "id $id_t"; fi
if "$F" claim --operator --id 1111111111 >/dev/null 2>&1; then bad "bogus id" "was allowed"; else ok "unknown id refused"; fi

echo "== FACTORY_WORKER pins the claim identity (backgrounded-cwd drift) =="
out="$(FACTORY_WORKER=seat-env "$F" claim 2>"$R/err1.txt")"
case "$out" in
  */claimed/seat-env/*) ok "env var names the worker when no arg is given" ;;
  *) bad "env worker" "got '$out'" ;;
esac
if grep -q "worker: seat-env" "$R/err1.txt"; then ok "claim prints the effective worker on stderr"; else bad "worker print" "$(cat "$R/err1.txt")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"
"$F" requeue "$id" "selftest: back" >/dev/null
out="$(FACTORY_WORKER=seat-env "$F" claim seat-arg 2>"$R/err2.txt")"
case "$out" in
  */claimed/seat-arg/*) ok "explicit worker arg beats FACTORY_WORKER" ;;
  *) bad "arg precedence" "got '$out'" ;;
esac
if grep -q "worker: seat-arg" "$R/err2.txt"; then ok "printed worker follows the arg"; else bad "worker print arg" "$(cat "$R/err2.txt")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"
"$F" requeue "$id" "selftest: back" >/dev/null
out="$(FACTORY_WORKER=seat-env "$F" claim --operator 2>/dev/null)"
case "$out" in
  */claimed/operator/*) ok "--operator ignores FACTORY_WORKER (the lane stays the operator's)" ;;
  *) bad "operator precedence" "got '$out'" ;;
esac
id="$(basename "$out" .md)"; id="${id#*-}"
"$F" requeue "$id" "selftest: back" >/dev/null

echo "== the help-declaration gate refuses silent service closes (1786918240) =="
# Drain earlier sections' leftovers so each claim below gets the task this
# section just minted (claims take the queue head, not the newest task).
while :; do
  out="$("$F" claim seat-drain 2>/dev/null)" || break
  case "$out" in EMPTY*) break ;; esac
  id="$(basename "$out" .md)"; id="${id#*-}"
  FACTORY_FORCE=1 "$F" done "$id" done "selftest drain" >/dev/null 2>&1
done
mkT open-email "help gate service task" >/dev/null
out="$("$F" claim seat-hg)"; id_hg="$(basename "$out" .md)"; id_hg="${id_hg#*-}"
if "$F" done "$id_hg" done "no declaration" >/dev/null 2>"$R/hgerr.txt"; then
  bad "help gate refusal" "a service-touching task closed with no help line"
else
  ok "done refused while tasks/<worker>.done has no help line"
fi
if grep -q "help declaration" "$R/hgerr.txt"; then ok "refusal names the missing declaration"; else bad "refusal message" "$(cat "$R/hgerr.txt")"; fi
if [ "$(count "$R/claimed" "*-$id_hg.md")" = "1" ]; then ok "the refused task stays claimed"; else bad "refusal state" "task left claimed/"; fi
echo "help: no user-facing change" > "$R/seat-hg.done"
if "$F" done "$id_hg" done "declared" >/dev/null 2>&1; then ok "a help line unlocks the close"; else bad "help gate pass" "declaration did not unlock done"; fi
mkT open-crm "help gate forced close" >/dev/null
out="$("$F" claim seat-hg2)"; id_hg2="$(basename "$out" .md)"; id_hg2="${id_hg2#*-}"
if FACTORY_FORCE=1 "$F" done "$id_hg2" done "forced" >/dev/null 2>"$R/hgerr2.txt"; then
  ok "FACTORY_FORCE=1 overrides the gate"
else
  bad "force override" "$(cat "$R/hgerr2.txt")"
fi
if grep -q "overridden" "$R/hgerr2.txt"; then ok "the override warns on stderr"; else bad "override warning" "$(cat "$R/hgerr2.txt")"; fi
mkT "scripts/factory.sh, docs/skills/software-factory" "help gate non-service" >/dev/null
out="$("$F" claim seat-hg3)"; id_hg3="$(basename "$out" .md)"; id_hg3="${id_hg3#*-}"
if "$F" done "$id_hg3" done "docs only" >/dev/null 2>&1; then ok "non-service touches close without a declaration"; else bad "non-service gate" "docs-only task was refused"; fi
mkT suite "help gate suite-wide" >/dev/null
out="$("$F" claim seat-hg4)"; id_hg4="$(basename "$out" .md)"; id_hg4="${id_hg4#*-}"
if "$F" done "$id_hg4" done >/dev/null 2>&1; then bad "suite gate" "a suite-wide task closed silently"; else ok "suite-wide touches are service touches (refused)"; fi
echo "Help: updated the suite pages" > "$R/seat-hg4.done"
if "$F" done "$id_hg4" done >/dev/null 2>&1; then ok "the declaration match is case-insensitive"; else bad "case fold" "Help: line did not unlock"; fi
d_hg5="$R/draft.md"
{ echo "---"; echo "lane: operator"; echo "touches: open-email"; echo "---"; echo "# help gate operator exempt"; } > "$d_hg5"
p_hg5="$("$F" new "$d_hg5")"
id_hg5="$(basename "$p_hg5" .md)"; id_hg5="${id_hg5#*-}"
"$F" claim --operator --id "$id_hg5" >/dev/null
if "$F" done "$id_hg5" done "engine rollout ran" >/dev/null 2>&1; then ok "operator-lane closes stay exempt"; else bad "operator exemption" "lane task was refused"; fi
mkT open-email "help gate folded marker" >/dev/null
out="$("$F" claim seat-hg6)"; id_hg6="$(basename "$out" .md)"; id_hg6="${id_hg6#*-}"
mkdir -p "$R/sessions-done"
echo "help: no user-facing change" > "$R/sessions-done/seat-hg6.done"
if "$F" done "$id_hg6" done "folded declaration" >/dev/null 2>&1; then ok "a declaration folded into sessions-done/ still unlocks the close"; else bad "folded marker gate" "sessions-done declaration did not unlock done"; fi

echo "== seat handoffs survive where chips do not =="
out="$("$F" handoff-list)"
if [ "$out" = "NONE" ]; then ok "handoff-list on an empty tree prints NONE"; else bad "handoff NONE" "got '$out'"; fi
printf 'boot prompt\n' > "$R/handoff/seat-alpha.md"
printf 'boot prompt\n' > "$R/handoff/seat-beta.md"
out="$("$F" handoff-list)"
if [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = "2" ] && printf '%s' "$out" | grep -q "^seat-alpha	"; then
  ok "handoff-list prints one <worktree>TAB<age> line per pending file"
else
  bad "handoff-list rows" "got '$out'"
fi
"$F" index >/dev/null
if grep -q "^- .seat-alpha. staged " "$R/factory/index.md"; then
  ok "the board shows seats awaiting a successor"
else
  bad "board handoff section" "$(grep -A3 'awaiting successor' "$R/factory/index.md" || echo missing)"
fi
"$F" handoff-clear seat-alpha >/dev/null
if [ ! -f "$R/handoff/seat-alpha.md" ] && [ -f "$R/handoff/seat-beta.md" ]; then
  ok "handoff-clear drops exactly the successor's own file"
else
  bad "handoff-clear" "alpha gone? $([ -f "$R/handoff/seat-alpha.md" ] && echo no || echo yes); beta kept? $([ -f "$R/handoff/seat-beta.md" ] && echo yes || echo no)"
fi
if "$F" handoff-clear seat-alpha >/dev/null 2>&1; then
  bad "handoff-clear unknown" "clearing a non-existent handoff succeeded"
else
  ok "handoff-clear refuses an unknown seat (a typo never passes silently)"
fi
"$F" handoff-clear seat-beta >/dev/null

echo "== spawn-successor: the handoff file is the token =="
if "$F" spawn-successor seat-none >/dev/null 2>&1; then
  bad "spawn refuse" "spawn-successor without a handoff file succeeded"
else
  ok "spawn-successor refuses when no handoff file exists (handoff first, spawn second)"
fi
wtd="$(mktemp -d)"
printf 'cd %s && claude\n\n## Boot prompt\n\nRead the skill. Take over the seat.\n' "$wtd" > "$R/handoff/seat-cli.md"
out="$(FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-cli 2>&1)"
if printf '%s' "$out" | grep -q "claude-fable-5" && printf '%s' "$out" | grep -q "Read the skill. Take over the seat."; then
  ok "dry-run prints the Terminal program carrying the pinned model + boot prompt"
else
  bad "spawn dryrun" "got '$out'"
fi
if [ -f "$R/handoff/seat-cli.md" ]; then
  ok "spawn leaves the handoff file in place (the successor's handoff-clear is the ack)"
else
  bad "handoff kept" "spawn removed the handoff file"
fi
printf 'cd %s && claude\n\nLegacy prompt after the boot line.\n' "$wtd" > "$R/handoff/seat-old.md"
out="$(FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-old 2>&1)"
if printf '%s' "$out" | grep -q "Legacy prompt after the boot line."; then
  ok "legacy handoff files (prompt after the cd line, no marker) still parse"
else
  bad "spawn legacy" "got '$out'"
fi
echo "== spawn-successor: project-prefixed session names (task 1787175232) =="
printf 'cd %s && claude\n\n## Boot prompt\n\nYou are a TaskConsumer in executor mode. Work the queue.\n' "$wtd" > "$R/handoff/seat-nm.md"
out="$(FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
if printf '%s' "$out" | grep -q "session name: $FP-executor-seat-nm"; then
  ok "FACTORY_PROJECT sets the prefix and an executor prompt gets <prefix>-executor-<seat>"
else
  bad "spawn name env" "got '$out'"
fi
printf 'cd %s && claude\n\n## Boot prompt\n\nRead the skill. Take over the seat.\n' "$wtd" > "$R/handoff/seat-nm.md"
out="$(FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
if printf '%s' "$out" | grep -q "session name: $FP-worker-seat-nm"; then
  ok "a non-executor boot prompt gets <prefix>-worker-<seat>"
else
  bad "spawn name worker" "got '$out'"
fi
pri="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true)"
if [ -n "$pri" ]; then
  exp="$(basename "$pri")"; exp="${exp%-ng}"; exp="${exp%-main}"
  out="$(FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
  if printf '%s' "$out" | grep -q "session name: $exp-worker-seat-nm"; then
    ok "unset FACTORY_PROJECT derives the prefix from the primary basename ($exp)"
  else
    bad "spawn name derived" "expected '$exp-worker-seat-nm' in '$out'"
  fi
fi
echo "== spawn-successor: zero-residue window (task 1787177577) =="
out="$(FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
if printf '%s' "$out" | grep -q '; exit 0'; then
  ok "the spawned command ends '; exit 0' (shell exits cleanly even when claude dies by signal)"
else
  bad "spawn exit suffix" "got '$out'"
fi
boot="$(printf '%s\n' "$out" | sed -n '/^DRYRUN osascript program:/,/^DRYRUN post-live profile program/p')"
prof="$(printf '%s\n' "$out" | sed -n '/^DRYRUN post-live profile program/,$p')"
if [ -n "$boot" ] && ! printf '%s' "$boot" | grep -q 'settings set' && ! printf '%s' "$boot" | grep -q 'activate'; then
  ok "the boot program is the bare 'do script' - no settings set, no activate, while the shell starts (task 1788301542)"
else
  bad "spawn boot program" "got '$out'"
fi
if printf '%s' "$prof" | grep -q 'settings set "Factory"' && printf '%s' "$prof" | grep -q 'on error' && printf '%s' "$prof" | grep -q 'exists settings set'; then
  ok "the post-live profile program applies the Factory settings set inside try/on error (graceful degrade without it)"
else
  bad "spawn settings set" "got '$out'"
fi
# Tab title (task 1789581980): the same post-live program sets the tab's
# custom title to the session name, AFTER the settings-set switch (so the
# switch can never clobber it) and outside the profile's existence check
# (so a dead-prompt window without the profile is still identifiable).
sn="$(printf '%s\n' "$out" | sed -n 's/^DRYRUN session name: //p' | head -1)"
if [ -n "$sn" ] && printf '%s' "$prof" | sed -n '/settings set "Factory"/,$p' | grep -q "set custom title of selected tab of window id <wid> to \"$sn\"" \
   && ! printf '%s' "$boot" | grep -q 'custom title'; then
  ok "the post-live program titles the tab with the session name ($sn) after the settings-set switch, never in the boot program"
else
  bad "spawn tab title" "got '$out'"
fi
if printf '%s' "$out" | grep -q 'wid:'; then
  ok "the program returns the window id (wid:) for the post-spawn re-drive"
else
  bad "spawn wid" "got '$out'"
fi

echo "== spawn-successor: pre-spawn duplicate guard (task 1788278149) =="
# A live process already carrying the session name in its argv (the way a
# booted claude session does) must refuse the spawn; FACTORY_FORCE overrides.
printf '#!/bin/bash\nsleep 60\n' > "$R/spawnfake.sh"
chmod +x "$R/spawnfake.sh"
printf 'cd %s && claude\n\n## Boot prompt\n\nYou are a TaskConsumer in executor mode. Work the queue.\n' "$wtd" > "$R/handoff/seat-nm.md"
"$R/spawnfake.sh" --name $FP-executor-seat-nm >/dev/null 2>&1 &
fake_pid=$!
sleep 1
if out="$(FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"; then
  bad "spawn dup guard" "spawn proceeded past a live '--name $FP-executor-seat-nm' process: $out"
else
  if printf '%s' "$out" | grep -q "already live"; then
    ok "a live process carrying the session name refuses the spawn (duplicate guard)"
  else
    bad "spawn dup guard msg" "refused, but not for the duplicate: '$out'"
  fi
fi
out="$(FACTORY_FORCE=1 FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)" \
  && printf '%s' "$out" | grep -q "session name: $FP-executor-seat-nm" \
  && ok "FACTORY_FORCE=1 overrides the duplicate guard" \
  || bad "spawn dup force" "got '$out'"
# A guard against a NEAR name (seat-nm1 vs seat-nm) must NOT fire: the match
# is word-bounded, not a prefix match.
printf 'cd %s && claude\n\n## Boot prompt\n\nYou are a TaskConsumer in executor mode. Work the queue.\n' "$wtd" > "$R/handoff/seat-nm1.md"
out="$(FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm1 2>&1)" \
  && printf '%s' "$out" | grep -q "session name: $FP-executor-seat-nm1" \
  && ok "the guard is word-bounded (a live seat-nm never blocks seat-nm1)" \
  || bad "spawn guard bound" "got '$out'"
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
sleep 1
out="$(FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)" \
  && printf '%s' "$out" | grep -q "session name: $FP-executor-seat-nm" \
  && ok "with the process gone the spawn proceeds again (guard is live-state, not a latch)" \
  || bad "spawn guard clear" "got '$out'"
echo "== spawn-successor: an AppleEvent timeout is SPAWN PENDING, never a failure (task 1789588684: the 2026-09-16 respawn storm) =="
# A fake osascript prints Terminal's -1712 line and exits 1 - the shape that
# booted nine sessions onto one seat once Terminal flushed its queue. The
# claude binary is any executable (only its existence is checked).
printf '#!/bin/bash\necho "44:670: execution error: Terminal got an error: AppleEvent timed out. (-1712)" >&2\nexit 1\n' > "$R/osafake.sh"; chmod +x "$R/osafake.sh"
out="$(FACTORY_PROJECT=$FP FACTORY_OSASCRIPT_BIN="$R/osafake.sh" FACTORY_CLAUDE_BIN="$R/spawnfake.sh" FACTORY_SPAWN_VERIFY_SECS=1 "$F" spawn-successor seat-nm 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -q "spawn PENDING (AppleEvent timed out - Terminal may still run it)"; then ok "a -1712 osascript failure reports spawn PENDING and exits 3"; else bad "spawn pending" "rc=$rc: '$out'"; fi
if ! printf '%s' "$out" | grep -q "boot by hand"; then ok "the PENDING report never prints the hand-boot line (it invites a second boot)"; else bad "spawn pending hand-boot" "'$out'"; fi
if [ -f "$R/factory/spawn-pending/seat-nm" ] && grep -q "^session: $FP-executor-seat-nm" "$R/factory/spawn-pending/seat-nm" && grep -q "^since: 20" "$R/factory/spawn-pending/seat-nm"; then ok "the stamp tasks/factory/spawn-pending/<seat> carries the instant + session name"; else bad "spawn pending stamp" "$(cat "$R/factory/spawn-pending/seat-nm" 2>&1)"; fi
if [ -f "$R/handoff/seat-nm.md" ]; then ok "the handoff file stays (the token for the boot that may still run)"; else bad "pending handoff kept" "handoff removed"; fi
stamp_before="$(cat "$R/factory/spawn-pending/seat-nm")"
if out="$(FACTORY_PROJECT=$FP FACTORY_OSASCRIPT_BIN="$R/osafake.sh" FACTORY_CLAUDE_BIN="$R/spawnfake.sh" FACTORY_SPAWN_VERIFY_SECS=1 "$F" spawn-successor seat-nm 2>&1)"; then
  bad "spawn pending guard" "a second spawn proceeded past a fresh stamp: $out"
elif printf '%s' "$out" | grep -q "spawn PENDING for seat-nm since 20" && ! printf '%s' "$out" | grep -q "boot by hand"; then
  ok "a second spawn refuses on the stamp (no second do script, no hand-boot line)"
else
  bad "spawn pending guard msg" "'$out'"
fi
if [ "$(cat "$R/factory/spawn-pending/seat-nm")" = "$stamp_before" ]; then ok "the refusal leaves the stamp as it was"; else bad "stamp rewritten" "$(cat "$R/factory/spawn-pending/seat-nm")"; fi
if out="$(FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"; then bad "spawn pending dryrun" "a dry run proceeded past the stamp: $out"; else ok "the stamp guard sits before the dry run too (like the live-duplicate guard)"; fi
out="$(FACTORY_FORCE=1 FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)" \
  && printf '%s' "$out" | grep -q "session name: $FP-executor-seat-nm" \
  && ok "FACTORY_FORCE=1 overrides the stamp" \
  || bad "spawn pending force" "got '$out'"
sleep 2
out="$(FACTORY_SPAWN_PENDING_TTL=1s FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)" \
  && printf '%s' "$out" | grep -q "session name: $FP-executor-seat-nm" \
  && ok "a spawn after FACTORY_SPAWN_PENDING_TTL (here 1s) proceeds - an expired stamp is inert" \
  || bad "spawn pending ttl" "got '$out'"
out="$(FACTORY_SPAWN_PENDING_TTL=bogus FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
if [ $? -ne 0 ]; then ok "an unparseable TTL falls back to the 6h default (the fresh stamp still holds)"; else bad "spawn pending ttl default" "got '$out'"; fi
# The seat's process appears (Terminal ran the queued event): the stamp is
# spent and the ordinary duplicate refusal applies.
"$R/spawnfake.sh" --name $FP-executor-seat-nm >/dev/null 2>&1 &
fake_pid=$!
sleep 1
if out="$(FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"; then
  bad "spawn pending live" "spawn proceeded beside a live named process: $out"
elif printf '%s' "$out" | grep -q "already live" && [ ! -f "$R/factory/spawn-pending/seat-nm" ]; then
  ok "with the named process live the stamp is cleared and the duplicate refusal applies"
else
  bad "spawn pending live msg" "'$out' / stamp: $(ls "$R/factory/spawn-pending/" 2>&1)"
fi
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
sleep 1
# handoff-clear (the successor's ack) spends a stamp too.
FACTORY_PROJECT=$FP FACTORY_OSASCRIPT_BIN="$R/osafake.sh" FACTORY_CLAUDE_BIN="$R/spawnfake.sh" FACTORY_SPAWN_VERIFY_SECS=1 "$F" spawn-successor seat-nm >/dev/null 2>&1
out="$("$F" handoff-clear seat-nm 2>&1)"
if [ ! -f "$R/factory/spawn-pending/seat-nm" ] && printf '%s' "$out" | grep -q "spawn-pending stamp for seat-nm cleared"; then ok "handoff-clear spends the stamp (the successor booted)"; else bad "handoff-clear stamp" "'$out' / $(ls "$R/factory/spawn-pending/" 2>&1)"; fi
# Any other osascript failure is still the hard refusal with the hand-boot line.
printf 'cd %s && claude\n\n## Boot prompt\n\nYou are a TaskConsumer in executor mode. Work the queue.\n' "$wtd" > "$R/handoff/seat-nm.md"
printf '#!/bin/bash\necho "execution error: Not authorized to send Apple events to Terminal. (-1743)" >&2\nexit 1\n' > "$R/osafake2.sh"; chmod +x "$R/osafake2.sh"
if out="$(FACTORY_PROJECT=$FP FACTORY_OSASCRIPT_BIN="$R/osafake2.sh" FACTORY_CLAUDE_BIN="$R/spawnfake.sh" FACTORY_SPAWN_VERIFY_SECS=1 "$F" spawn-successor seat-nm 2>&1)"; then
  bad "spawn refusal" "a -1743 osascript failure succeeded: $out"
elif printf '%s' "$out" | grep -q "Terminal automation failed" && printf '%s' "$out" | grep -q "boot by hand" && [ ! -f "$R/factory/spawn-pending/seat-nm" ]; then
  ok "a non-timeout osascript failure stays the hard refusal (hand-boot line, no stamp)"
else
  bad "spawn refusal msg" "'$out' / $(ls "$R/factory/spawn-pending/" 2>&1)"
fi
rm -rf "$wtd" "$R/spawnfake.sh" "$R/osafake.sh" "$R/osafake2.sh" "$R/handoff/seat-cli.md" "$R/handoff/seat-old.md" "$R/handoff/seat-nm.md" "$R/handoff/seat-nm1.md"

echo "== executor-watch: a dead executor cannot strand its seat (machine-sleep postmortem 2026-08-20) =="
ew="$R/ew"; mkdir -p "$ew"
# Pin candidate resolution to a throwaway QUIET dir: without the pin the REAL
# seat's activity dirs ride along (the 2026-08-25 auto-resolution) and their
# live writes would make every timing case here nondeterministic.
ewq="$R/ew-quiet"; mkdir -p "$ewq"
export FACTORY_ACTIVITY_DIRS="$ewq"
# ...and pin the worktree-edits source (task 1789684290) to a NON-repo dir,
# which disables it: unset, it would resolve the REAL seat worktree whose
# live edits keep every "fires on the first poll" case below quiet.
export FACTORY_WATCH_ROOT="$ewq"
touch -t 202601010000 "$ew/stale.txt"
out="$("$F" executor-watch "$ew/stale.txt" 60 1 2>/dev/null)"
if printf '%s' "$out" | grep -q "^EXECUTOR-STALE idle .*$ew/stale.txt"; then
  ok "a long-idle transcript file fires EXECUTOR-STALE on the first poll"
else
  bad "stale fire" "got '$out'"
fi
touch "$ew/fresh.txt"    # directory mode: the NEWEST file's mtime is the liveness signal
"$F" executor-watch "$ew" 3 1 > "$R/ew.out" 2>/dev/null &
ew_pid=$!
sleep 2
if kill -0 "$ew_pid" 2>/dev/null; then
  ok "a fresh write keeps the watchdog quiet (dir mode: newest file counts, the stale one does not)"
else
  bad "fresh quiet" "watchdog exited early: $(cat "$R/ew.out")"
fi
wait "$ew_pid"
if grep -q "^EXECUTOR-STALE idle .*$ew" "$R/ew.out"; then
  ok "the same watchdog fires once writes stop past the threshold"
else
  bad "dir fire" "$(cat "$R/ew.out")"
fi
out="$("$F" executor-watch "$R/ew-nosuch" 2 1 2>/dev/null)"
if printf '%s' "$out" | grep -q "^EXECUTOR-STALE no file ever appeared"; then
  ok "a transcript that never appears gets the grace window, then fires as stale"
else
  bad "missing grace" "got '$out'"
fi
# The 2026-08-25 false-STALE regression: on CLI-harness seats the old recipe
# watched the stubs-only ~/.claude/projects dir while live activity streamed
# into the /private/tmp session dir. An explicit stub path is now ADDED to
# the resolved candidates, so a live candidate suppresses the stale verdict.
stub="$R/ew-stub"; mkdir -p "$stub"
touch -t 202601010000 "$stub/agent-x.meta.json"
touch "$ewq/bg.output"                     # the live activity dir has a fresh write
"$F" executor-watch "$stub" 3 1 > "$R/ew2.out" 2>/dev/null &
ew_pid=$!
sleep 2
if kill -0 "$ew_pid" 2>/dev/null; then
  ok "a stub explicit path cannot false-STALE while a resolved activity dir is live"
else
  bad "stub false-stale" "watchdog exited early: $(cat "$R/ew2.out")"
fi
wait "$ew_pid"
if grep -q "^EXECUTOR-STALE idle " "$R/ew2.out"; then
  ok "the same watchdog still fires once the activity dir goes quiet too"
else
  bad "stub eventual fire" "$(cat "$R/ew2.out")"
fi
if "$F" executor-watch "$ew" abc 1 >/dev/null 2>&1; then
  bad "arg validation" "a non-numeric stale threshold was accepted"
else
  ok "non-numeric thresholds are refused"
fi
# The third source (task 1789684290, seat-9 2026-09-18): an executor editing
# the WORKTREE with foreground Edit/Write for 30+ min writes nothing into
# either harness dir, and the watchdog false-STALEd a live one. The
# worktree's own modified/untracked (non-ignored) files + its git index now
# count as activity; ignored paths (.icp/cache replica ticks) never do.
# FACTORY_WATCH_ROOT now points at a throwaway repo whose .gitignore mirrors
# the suite's (.icp/cache/ + node_modules/ ignored); the harness dirs stay
# silent throughout, so every verdict below is the third source's alone.
ewwt="$R/ew-wt"; mkdir -p "$ewwt/.icp/cache/networks/local"
( cd "$ewwt" && git init -q && git config user.email t@t && git config user.name t \
  && printf '.icp/cache/\nnode_modules/\n' > .gitignore && echo one > tracked.txt \
  && git add -A && git commit -qm init ) 2>/dev/null
ewq2="$R/ew-quiet2"; mkdir -p "$ewq2"          # harness dirs: present but NEVER written
export FACTORY_ACTIVITY_DIRS="$ewq2" FACTORY_WATCH_ROOT="$ewwt"
backdate_wt() {  # every worktree signal older than any window: tracked files + the admin index
  touch -t 202601010000 "$ewwt/tracked.txt" "$ewwt/.gitignore" "$ewwt/.git/index"
}
backdate_wt
echo two > "$ewwt/tracked.txt"                 # a foreground Edit on a tracked file, nothing else anywhere
"$F" executor-watch auto 3 1 > "$R/ew3.out" 2>/dev/null &
ew_pid=$!
sleep 2
if kill -0 "$ew_pid" 2>/dev/null; then
  ok "a modified worktree file inside the window keeps the watchdog quiet with both harness dirs silent (the foreground-edit stretch)"
else
  bad "worktree edit quiet" "watchdog exited early: $(cat "$R/ew3.out")"
fi
wait "$ew_pid"
if grep -q "^EXECUTOR-STALE idle .*newest write .* from: worktree edits under $ewwt" "$R/ew3.out"; then
  ok "it still fires once the edits stop, and the STALE line names the worktree edits as the newest source"
else
  bad "worktree eventual fire" "$(cat "$R/ew3.out")"
fi
backdate_wt
echo untracked > "$ewwt/new-file.txt"          # an untracked, non-ignored file counts too
"$F" executor-watch auto 3 1 > "$R/ew4.out" 2>/dev/null &
ew_pid=$!
sleep 2
if kill -0 "$ew_pid" 2>/dev/null; then ok "an untracked (non-ignored) worktree file counts as activity"; else bad "untracked quiet" "$(cat "$R/ew4.out")"; fi
wait "$ew_pid"
rm -f "$ewwt/new-file.txt"
backdate_wt
( cd "$ewwt" && echo three > tracked.txt && git commit -qam edit ) 2>/dev/null   # a commit moves the admin index
touch -t 202601010000 "$ewwt/tracked.txt"      # ...so only the index is fresh
"$F" executor-watch auto 3 1 > "$R/ew5.out" 2>/dev/null &
ew_pid=$!
sleep 2
if kill -0 "$ew_pid" 2>/dev/null; then ok "a commit (the git admin index moving) counts as activity"; else bad "index quiet" "$(cat "$R/ew5.out")"; fi
wait "$ew_pid"
backdate_wt
touch "$ewwt/.icp/cache/networks/local/tick"   # the replica ticking under an IGNORED path: not the executor
t0="$(date +%s)"
out="$("$F" executor-watch auto 60 1 2>/dev/null)"
t1="$(date +%s)"
if printf '%s' "$out" | grep -q "^EXECUTOR-STALE idle .* from: worktree edits under $ewwt" && [ $((t1 - t0)) -lt 20 ]; then
  ok "only an ignored path (.icp/cache/...) changing still fires STALE on the first poll (.gitignore honoured)"
else
  bad "ignored path fires" "after $((t1 - t0))s: '$out'"
fi
# The FOURTH source (task 1792595837, seat-7 2026-10-21): a tee'd deploy-all
# reaches lib.sh suite_output_guard - stdout is a PIPE, so after ONE announce
# line it `exec >>`s every further write into <root>/.icp/cache/
# <label>.<YYYYmmdd-HHMMSS>.<pid>.log and the pipe (the executor's live log)
# goes silent for the whole wave; a reproduction runs BEFORE the fix, so the
# worktree has no edits, and nothing backgrounded writes to tasks/. Every
# source above sat idle for 28 minutes while the run was alive - a false
# STALE on any wave longer than the threshold. The guard's own per-run logs
# at the TOP of .icp/cache count now; networks/ (and any subdirectory) never.
backdate_wt
glog="$ewwt/.icp/cache/deploy-all.20260101-000000.1.log"
touch "$glog"                                  # a live guard log, nothing else written anywhere
"$F" executor-watch auto 3 1 > "$R/ew6.out" 2>/dev/null &
ew_pid=$!
sleep 2
if kill -0 "$ew_pid" 2>/dev/null; then
  ok "a fresh suite_output_guard log at the top of .icp/cache keeps the watchdog quiet (the tee'd deploy-all wave)"
else
  bad "guard log quiet" "watchdog exited early: $(cat "$R/ew6.out")"
fi
wait "$ew_pid"
if grep -q "^EXECUTOR-STALE idle .* from: suite_output_guard logs under $ewwt/.icp/cache" "$R/ew6.out"; then
  ok "it fires once the guard log stops growing, and the STALE line names the guard-log source"
else
  bad "guard log eventual fire" "$(cat "$R/ew6.out")"
fi
touch -t 202601010001 "$glog"                  # the same file older than the threshold (a minute past the backdated tree: still the newest source)
touch "$ewwt/.icp/cache/networks/local/tick"   # fresh replica ticks under networks/ ...
mkdir -p "$ewwt/.icp/cache/networks/local" && touch "$ewwt/.icp/cache/networks/deploy-all.20260101-000000.2.log"   # ... and a guard-shaped name BELOW the top level: neither counts
t0="$(date +%s)"
out="$("$F" executor-watch auto 60 1 2>/dev/null)"
t1="$(date +%s)"
if printf '%s' "$out" | grep -q "^EXECUTOR-STALE idle .* from: suite_output_guard logs under $ewwt/.icp/cache" && [ $((t1 - t0)) -lt 20 ]; then
  ok "the same guard log older than the threshold fires STALE on the first poll naming the guard-log source (networks/ ticks and a guard-shaped name below the top level never count)"
else
  bad "old guard log fires" "after $((t1 - t0))s: '$out'"
fi
rm -f "$glog" "$ewwt/.icp/cache/networks/deploy-all.20260101-000000.2.log"
out="$(FACTORY_WATCH_ROOT="$ewq2" "$F" executor-watch auto 2 1 2>/dev/null)"
if printf '%s' "$out" | grep -q "^EXECUTOR-STALE no file ever appeared"; then
  ok "a non-repo watch root contributes nothing (the source is git-derived, never a tree walk)"
else
  bad "non-repo root" "got '$out'"
fi
unset FACTORY_ACTIVITY_DIRS FACTORY_WATCH_ROOT
rm -rf "$ew" "$ewq" "$ewq2" "$ewwt" "$stub" "$R/ew.out" "$R/ew2.out" "$R/ew3.out" "$R/ew4.out" "$R/ew5.out" "$R/ew6.out"

echo "== new refuses unknown after: gates (task 1786983440) =="
# A guessed id gates nothing (claim's live-ids-only rule reads unknown ids
# as satisfied), so new must refuse the filing before a broken chain exists.
d_ag1="$R/draft.md"
{ echo "---"; echo "after: 1999999999"; echo "---"; echo "# gated by a never-minted id"; } > "$d_ag1"
out_ag="$("$F" new "$d_ag1" 2>&1)" && ag_rc=0 || ag_rc=$?
if [ "$ag_rc" = "0" ]; then
  bad "after unknown" "a never-minted after: id was accepted"
else
  ok "new refuses an after: id that was never minted"
fi
if printf '%s' "$out_ag" | grep -q "1999999999"; then
  ok "the refusal names the bad id"
else
  bad "after refusal message" "$out_ag"
fi
d_ag2="$R/draft.md"
{ echo "---"; echo "---"; echo "# after-gate prerequisite"; } > "$d_ag2"
p_ag2="$("$F" new "$d_ag2")"
id_ag2="$(basename "$p_ag2" .md)"; id_ag2="${id_ag2#*-}"
d_ag3="$R/draft.md"
{ echo "---"; echo "after: $id_ag2"; echo "---"; echo "# gated by a real queued id"; } > "$d_ag3"
if p_ag3="$("$F" new "$d_ag3" 2>/dev/null)"; then ok "a QUEUED prerequisite id is accepted"; else bad "after queued" "real queued id refused"; fi
id_ag3="$(basename "$p_ag3" .md)"; id_ag3="${id_ag3#*-}"
"$F" claim --operator --id "$id_ag2" >/dev/null
"$F" done "$id_ag2" superseded "selftest" >/dev/null
d_ag4="$R/draft.md"
{ echo "---"; echo "after: $id_ag2"; echo "---"; echo "# gated by an archived id"; } > "$d_ag4"
if "$F" new "$d_ag4" >/dev/null 2>&1; then ok "an ARCHIVED prerequisite id is accepted (history gates nothing, validly)"; else bad "after archived" "archived id refused"; fi
"$F" claim --operator --id "$id_ag3" >/dev/null
"$F" done "$id_ag3" superseded "selftest" >/dev/null

echo "== new warns when a seat's draft cites its own in-flight claim with no after: naming it (task 1792508238) =="
# Four follow-ups filed on 2026-10-20 named the filing seat's still-CLAIMED
# parent with no after: - the next seat claimed one, failed its step-2 sanity
# check (the parent's code not on main yet) and bounced it. The check is
# advisory: ONE stderr line per held claim the draft cites and its after: does
# not name, the task queued regardless (stdout + rc as before), nothing added
# to the draft. Identity = new's producer rule (FACTORY_WORKER > pin > cwd
# branch); a caller holding nothing is untouched. Isolated tasks root (RC):
# the shared queue carries leftovers and this seat's claim must take ITS task.
RC="$(mktemp -d)"
FC() { FACTORY_TASKS_ROOT="$RC" "$F" "$@"; }   # factory.sh against the isolated root
CW="$RC/seatwt"; mkdir -p "$CW"; git init -q "$CW" 2>/dev/null; printf 'seat-cite\n' > "$CW/.factory-worker"
{ echo "---"; echo "touches: scripts/factory.sh"; echo "---"; echo "# cite: the parent this seat holds"; } > "$RC/draft.md"
p_c="$(FC new "$RC/draft.md")"; id_c="$(basename "$p_c" .md)"; id_c="${id_c#*-}"
out="$(cd "$CW" && FC claim 2>/dev/null)"
case "$out" in */claimed/seat-cite/*) ok "the pinned seat holds the parent" ;; *) bad "cite claim" "got '$out'" ;; esac
want_c="factory: new: this draft cites your in-flight claim $id_c but its after: does not name it - if the work needs that task's merge on main, re-file with 'after: $id_c' (a follow-up that stands on its own needs nothing)"
cite_draft() {  # cite_draft <after-id-or-empty> <title>: a follow-up naming the parent in its producer line and its body
  { echo "---"; echo "producer: seat-cite (task $id_c follow-up)"; [ -z "$1" ] || echo "after: $1"; echo "touches: scripts/factory.sh"; echo "---"; echo "# $2"; echo; echo "Follow-up of task $id_c: reads the views that task adds."; } > "$RC/draft.md"
}
cite_draft "" "cite: follow-up with no gate"
p_f="$(cd "$CW" && FC new "$RC/draft.md" 2>"$RC/c1.err")"; rc_f=$?
if [ "$rc_f" = "0" ] && [ -f "$p_f" ] && [ "$(dirname "$p_f")" = "$RC/queue" ]; then ok "the follow-up is still queued: rc 0, the queue path on stdout as before"; else bad "cite queued" "rc $rc_f: '$p_f'"; fi
if [ "$(cat "$RC/c1.err")" = "$want_c" ]; then ok "exactly one stderr line, the brief's words, naming the claim and the after: to add"; else bad "cite warning" "$(cat "$RC/c1.err")"; fi
if grep -q "^after:" "$p_f"; then bad "cite silent add" "new added an after: line to the filed task"; else ok "the line is never added for the filer (a bug found in passing is often independent of the parent)"; fi
cite_draft "$id_c" "cite: follow-up with the gate"
p_g="$(cd "$CW" && FC new "$RC/draft.md" 2>"$RC/c2.err")"
if [ -f "$p_g" ] && [ ! -s "$RC/c2.err" ]; then ok "the same draft with 'after: <id>' files silently"; else bad "cite after" "$(cat "$RC/c2.err")"; fi
{ echo "---"; echo "touches: scripts/factory.sh"; echo "---"; echo "# cite: an unrelated filing from the same seat"; } > "$RC/draft.md"
p_u="$(cd "$CW" && FC new "$RC/draft.md" 2>"$RC/c3.err")"
if [ -f "$p_u" ] && [ ! -s "$RC/c3.err" ]; then ok "a draft that cites no held claim is silent"; else bad "cite unrelated" "$(cat "$RC/c3.err")"; fi
cite_draft "" "cite: filed by a seat holding nothing"
p_n="$(cd "$CW" && FACTORY_WORKER=seat-free FC new "$RC/draft.md" 2>"$RC/c4.err")"
if [ -f "$p_n" ] && [ ! -s "$RC/c4.err" ]; then ok "FACTORY_WORKER beats the pin: a worker holding no claim is untouched"; else bad "cite other worker" "$(cat "$RC/c4.err")"; fi
cite_draft "" "cite: filed from outside the seat under FACTORY_WORKER"
p_e="$(cd "$RC" && FACTORY_WORKER=seat-cite FC new "$RC/draft.md" 2>"$RC/c5.err")"
if [ -f "$p_e" ] && [ "$(cat "$RC/c5.err")" = "$want_c" ]; then ok "FACTORY_WORKER alone (no pin at the cwd) resolves the holder and warns"; else bad "cite env" "$(cat "$RC/c5.err")"; fi
rm -rf "$RC"

echo "== new bands the filing by class; band: / --band override it (task 1792609968) =="
# Every filing used to land at the natural band (the key = the id) whatever
# its class:, and the prioritizer's reband came on its NEXT pass - a consumer
# freed in that window saw a fresh hygiene filing as the HEAD of the natural
# band and claimed it over 27 banded hygiene tasks (2026-10-21, 41 s after
# the filing). Now the class decides the filing band - hygiene 30, cosmetic
# 40, parked 90; everything else (and no class) the natural band: the
# DEMOTING defaults only, every promotion stays the prioritizer's - and a
# 'band: NN' line or --band NN (the flag wins) overrides it. stdout stays the
# queue path alone; a banded filing adds ONE stderr line naming the band and
# why; an unbanded filing stays silent. The key is computed HERE from the
# band table's formula, independently of factory.sh. Isolated root (RN): the
# drain at the end must see only these tasks.
RN="$(mktemp -d)"
FN() { FACTORY_TASKS_ROOT="$RN" "$F" "$@"; }   # factory.sh against the isolated root
key_of() { printf '%010d' "$((10#$1 * 100000000 + 10#$2 % 100000000))"; }   # key_of <band> <id>
split_path() { local b; b="$(basename "$1" .md)"; SP_P="${b%%-*}"; SP_I="${b#*-}"; }   # -> SP_P (key) SP_I (id)
band_draft() {  # band_draft <front-matter lines> <title> -> $RN/draft.md
  { echo "---"; printf '%s\n' "$1"; echo "---"; echo "# $2"; } > "$RN/draft.md"
}
want_b() { echo "factory: new: filed at band $1 ($2) - the prioritizer reviews every filing and may move it"; }   # want_b <NN> <why>
band_draft "class: hygiene" "band: a hygiene filing"
p_bh="$(FN new "$RN/draft.md" 2>"$RN/b1.err")"; rc=$?
split_path "$p_bh"; id_bh="$SP_I"
if [ "$rc" = "0" ] && [ -f "$p_bh" ] && [ "$(dirname "$p_bh")" = "$RN/queue" ] && [ "$SP_P" = "$(key_of 30 "$SP_I")" ] && [ "${SP_P%????????}" = "30" ]; then ok "a class: hygiene draft files at band 30 - 30<id mod 10^8>-<id>.md - rc 0, the queue path on stdout as before"; else bad "band hygiene" "rc $rc: $p_bh"; fi
if [ "$(cat "$RN/b1.err")" = "$(want_b 30 "class: hygiene")" ]; then ok "...and says so on stderr: ONE line naming the band and the class"; else bad "band hygiene stderr" "$(cat "$RN/b1.err")"; fi
if grep -q "^class: hygiene$" "$p_bh" && ! grep -q "^band:" "$p_bh"; then ok "the filed task is the draft verbatim (no band: line added)"; else bad "band hygiene body" "$(head -5 "$p_bh")"; fi
band_draft "class: feature" "band: a feature filing"
p_bf="$(FN new "$RN/draft.md" 2>"$RN/b2.err")"; split_path "$p_bf"; id_bf="$SP_I"; nat_band="${SP_I%????????}"
if [ -f "$p_bf" ] && [ "$SP_P" = "$SP_I" ] && [ ! -s "$RN/b2.err" ]; then ok "a class: feature draft files at the natural band (the key = the id), silently - as before"; else bad "band feature" "$p_bf / $(cat "$RN/b2.err")"; fi
bx_ok=1
for c in security-high architecture prerequisite bug ops ""; do
  if [ -n "$c" ]; then band_draft "class: $c" "band: a $c filing"; else band_draft "touches: nothing-$$" "band: a filing with no class"; fi
  p_bx="$(FN new "$RN/draft.md" 2>"$RN/b2x.err")"; split_path "$p_bx"
  if [ -f "$p_bx" ] && [ "$SP_P" = "$SP_I" ] && [ ! -s "$RN/b2x.err" ]; then :; else bx_ok=0; bad "band class '$c'" "$p_bx / $(cat "$RN/b2x.err")"; fi
done
if [ "$bx_ok" = "1" ]; then ok "security-high / architecture / prerequisite / bug / ops / no class file at the natural band, silently: the DEMOTING defaults only - every promotion stays the prioritizer's"; fi
band_draft "class: cosmetic" "band: a cosmetic filing"
p_bc="$(FN new "$RN/draft.md" 2>"$RN/b3.err")"; split_path "$p_bc"
if [ -f "$p_bc" ] && [ "$SP_P" = "$(key_of 40 "$SP_I")" ] && [ "$(cat "$RN/b3.err")" = "$(want_b 40 "class: cosmetic")" ]; then ok "class: cosmetic files at band 40"; else bad "band cosmetic" "$p_bc / $(cat "$RN/b3.err")"; fi
band_draft "class: parked" "band: a parked filing"
p_bp="$(FN new "$RN/draft.md" 2>"$RN/b4.err")"; split_path "$p_bp"; id_bp="$SP_I"
if [ -f "$p_bp" ] && [ "$SP_P" = "$(key_of 90 "$SP_I")" ] && [ "$(cat "$RN/b4.err")" = "$(want_b 90 "class: parked")" ]; then ok "class: parked files at band 90"; else bad "band parked" "$p_bp / $(cat "$RN/b4.err")"; fi
band_draft "class: HYGIENE (lint debt)" "band: a Hygiene (lint debt) filing"
p_bu="$(FN new "$RN/draft.md" 2>"$RN/b5.err")"; split_path "$p_bu"
if [ -f "$p_bu" ] && [ "$SP_P" = "$(key_of 30 "$SP_I")" ] && [ "$(cat "$RN/b5.err")" = "$(want_b 30 "class: hygiene")" ]; then ok "the class match is case-insensitive on the field's first word ('HYGIENE (lint debt)' reads hygiene)"; else bad "band class fold" "$p_bu / $(cat "$RN/b5.err")"; fi
band_draft "class: hygiene
band: 05" "band: hygiene with band: 05"
p_b5="$(FN new "$RN/draft.md" 2>"$RN/b6.err")"; split_path "$p_b5"; id_b5="$SP_I"
if [ -f "$p_b5" ] && [ "$SP_P" = "$(key_of 5 "$SP_I")" ] && [ "${SP_P%????????}" = "05" ]; then ok "a class: hygiene draft with 'band: 05' files at band 05: the front-matter line overrides the class default"; else bad "band fm" "$p_b5"; fi
if [ "$(cat "$RN/b6.err")" = "$(want_b 05 "band: 05 on the draft")" ]; then ok "...the stderr line names the override"; else bad "band fm stderr" "$(cat "$RN/b6.err")"; fi
band_draft "class: hygiene
band: $nat_band" "band: hygiene with band: $nat_band (the natural band)"
p_bn="$(FN new "$RN/draft.md" 2>"$RN/b7.err")"; split_path "$p_bn"
if [ -f "$p_bn" ] && [ "$SP_P" = "$SP_I" ] && [ "$(cat "$RN/b7.err")" = "$(want_b "$nat_band" "band: $nat_band on the draft")" ]; then ok "the same draft with 'band: $nat_band' (today's natural band) lands at the natural key - the id itself"; else bad "band fm natural" "$p_bn / $(cat "$RN/b7.err")"; fi
band_draft "class: hygiene
band: 05" "band: hygiene with band: 05 and --band 7"
p_b7="$(FN new "$RN/draft.md" --band 7 2>"$RN/b8.err")"; split_path "$p_b7"
if [ -f "$p_b7" ] && [ "$SP_P" = "$(key_of 7 "$SP_I")" ] && [ "${SP_P%????????}" = "07" ]; then ok "--band 7 files at band 07: the flag wins over the draft's band: line and the class"; else bad "band flag" "$p_b7"; fi
if [ "$(cat "$RN/b8.err")" = "$(want_b 07 "--band 07, over the draft's band: 05")" ]; then ok "...and the stderr line says what it overrode"; else bad "band flag stderr" "$(cat "$RN/b8.err")"; fi
band_draft "class: feature" "band: a feature filing with --band 40 first"
p_b4="$(FN new --band 40 "$RN/draft.md" 2>"$RN/b9.err")"; split_path "$p_b4"
if [ -f "$p_b4" ] && [ "$SP_P" = "$(key_of 40 "$SP_I")" ] && [ "$(cat "$RN/b9.err")" = "$(want_b 40 "--band 40")" ]; then ok "--band before the draft path works too, over a class with no default"; else bad "band flag first" "$p_b4 / $(cat "$RN/b9.err")"; fi
# Refusals happen BEFORE the mint: nothing lands, no id is spent.
before_q="$(count "$RN/queue" '*.md')"; before_ids="$(ls "$RN/factory/.ids" | wc -l | tr -d ' ')"
band_draft "class: hygiene
band: 3x" "band: a bad band: line"
if FN new "$RN/draft.md" >/dev/null 2>"$RN/b10.err"; then bad "band bad fm" "a 'band: 3x' draft was filed"; else ok "a draft with 'band: 3x' is refused"; fi
if grep -q "band: must be a 1-2 digit band (00-99), got 'band: 3x'" "$RN/b10.err"; then ok "...naming the line"; else bad "band bad fm text" "$(cat "$RN/b10.err")"; fi
band_draft "class: hygiene" "band: a bad --band"
if FN new "$RN/draft.md" --band 123 >/dev/null 2>"$RN/b11.err"; then bad "band bad flag" "--band 123 was accepted"; else ok "--band 123 is refused (1-2 digits only)"; fi
if grep -q "\-\-band needs a 1-2 digit band (00-99), got '123'" "$RN/b11.err"; then ok "...naming the value"; else bad "band bad flag text" "$(cat "$RN/b11.err")"; fi
if FN new "$RN/draft.md" --band >/dev/null 2>"$RN/b12.err"; then bad "band no value" "--band without a value was accepted"; else ok "--band without a value is refused"; fi
if [ "$(count "$RN/queue" '*.md')" = "$before_q" ] && [ "$(ls "$RN/factory/.ids" | wc -l | tr -d ' ')" = "$before_ids" ]; then ok "a refused filing mints nothing: the queue and the id allocator are untouched"; else bad "band refused mint" "queue $(count "$RN/queue" '*.md') vs $before_q; ids $(ls "$RN/factory/.ids" | wc -l | tr -d ' ') vs $before_ids"; fi
# --attach is unchanged beside the band.
printf 'svg' > "$RN/logo.svg"
band_draft "class: hygiene
touches: bandattach" "band: a hygiene filing with a file"
p_ba="$(FACTORY_WORKER=seat-batt FN new "$RN/draft.md" --attach "$RN/logo.svg" 2>"$RN/b13.err")"; split_path "$p_ba"
if [ -f "$p_ba" ] && [ "$SP_P" = "$(key_of 30 "$SP_I")" ] && [ -f "$RN/attachments/$SP_I/logo.svg" ] && grep -q "^## Attachments$" "$p_ba" && grep -q "^- attachments/$SP_I/logo.svg (3 bytes, sha256 " "$p_ba" && [ "$(cat "$RN/b13.err")" = "$(want_b 30 "class: hygiene")" ]; then ok "--attach is unchanged beside the band: the file lands under tasks/attachments/<id>/ and the section rides the band-30 filing"; else bad "band attach" "$p_ba / $(cat "$RN/b13.err") / $(ls "$RN/attachments" 2>/dev/null | tr '\n' ' ')"; fi
# reprioritize on a banded filing is the same rename as ever.
out="$(FN reprioritize "$id_bh" 17 2>&1)"; rc=$?
if [ "$rc" = "0" ] && [ "$out" = "$RN/queue/$(key_of 17 "$id_bh")-$id_bh.md" ] && [ -f "$out" ] && [ ! -e "$p_bh" ]; then ok "reprioritize <id> 17 on the band-30 filing still works: the band table's key, the band-30 file gone"; else bad "band reprioritize" "rc $rc: $out"; fi
out="$(FN reprioritize "$id_bh" 30 2>&1)"
if [ "$out" = "$p_bh" ] && [ -f "$p_bh" ]; then ok "...and back to 30 lands on the filing's own name"; else bad "band reprioritize back" "$out"; fi
# The point of it all: the queue drains in KEY order, so a hygiene filing
# (filed FIRST here) never heads the natural band - the band-05 override
# first, the band-90 parked filing last, and the hygiene task after every
# natural-band task filed after it.
order=""; n_cl=0; first_id=""; last_id=""; pos_h=0; pos_f=0
while :; do
  out="$(FN claim seat-band 2>/dev/null)"
  case "$out" in EMPTY*) break ;; esac
  [ -f "$out" ] || { bad "band drain" "claim answered '$out'"; break; }
  split_path "$out"; n_cl=$((n_cl+1)); order="$order${order:+
}$SP_P"
  [ -n "$first_id" ] || first_id="$SP_I"; last_id="$SP_I"
  [ "$SP_I" != "$id_bh" ] || pos_h=$n_cl
  [ "$SP_I" != "$id_bf" ] || pos_f=$n_cl
  [ "$n_cl" -lt 40 ] || { bad "band drain" "runaway after 40 claims"; break; }
done
if [ "$n_cl" -ge 12 ] && printf '%s\n' "$order" | sort -c 2>/dev/null; then ok "claims drain in KEY order ($n_cl tasks)"; else bad "band order" "$n_cl claims: $(printf '%s' "$order" | tr '\n' ' ')"; fi
if [ "$first_id" = "$id_b5" ] && [ "$last_id" = "$id_bp" ]; then ok "the band-05 override is claimed first, the band-90 parked filing last"; else bad "band ends" "first $first_id (want $id_b5) last $last_id (want $id_bp)"; fi
if [ "$pos_h" -gt "$pos_f" ] && [ "$pos_f" -gt 0 ]; then ok "the hygiene task filed FIRST is claimed after the feature task filed second: a fresh hygiene filing never heads the natural band"; else bad "band head" "hygiene at claim $pos_h, feature at $pos_f"; fi
rm -rf "$RN"

echo "== operator signals are the control channel seats already poll =="
# A signal must (a) wake a parked watch at once, (b) refuse the addressee's next
# claim until it is acknowledged, (c) as all.md, refuse EVERY seat's, and (d)
# never touch a seat it is not addressed to. Cross-session messages did none of
# those (postmortem 2026-08-19).
"$F" watch 90 > "$R/watch.out" 2>/dev/null &
w_pid=$!
sleep 2
"$F" signal seat-sig "stop claiming; hand off to your successor" >/dev/null
wait "$w_pid"
if [ "$(cat "$R/watch.out")" = "CHANGED" ]; then ok "a signal wakes a parked watch"; else bad "watch wake" "got '$(cat "$R/watch.out")'"; fi
out="$("$F" signal-list)"
if printf '%s' "$out" | grep -q "^seat-sig	"; then ok "signal-list shows the pending order"; else bad "signal-list" "got '$out'"; fi
mkT open-hr "work behind a signal" >/dev/null
if out="$("$F" claim seat-sig 2>"$R/sigerr.txt")"; then
  bad "signal gate" "seat-sig claimed '$out' with an unread order standing"
else
  ok "claim refused while a signal addresses that worker"
fi
if grep -q "signal is waiting for 'seat-sig'" "$R/sigerr.txt"; then ok "the refusal names the addressee"; else bad "refusal message" "$(cat "$R/sigerr.txt")"; fi
if grep -q "hand off to your successor" "$R/sigerr.txt"; then ok "the refusal prints the order itself"; else bad "order text" "$(cat "$R/sigerr.txt")"; fi
out="$("$F" claim seat-unsignalled 2>/dev/null)"
case "$out" in
  */claimed/seat-unsignalled/*) ok "a signal to one worker does not block another" ;;
  *) bad "cross-worker block" "got '$out'" ;;
esac
id_sg="$(basename "$out" .md)"; id_sg="${id_sg#*-}"
"$F" requeue "$id_sg" "selftest: back" >/dev/null
if out="$(FACTORY_FORCE=1 "$F" claim seat-sig 2>"$R/sigerr2.txt")"; then
  ok "FACTORY_FORCE=1 overrides the signal gate"
  id_sg="$(basename "$out" .md)"; id_sg="${id_sg#*-}"
  "$F" requeue "$id_sg" "selftest: back" >/dev/null
else
  bad "signal force" "$(cat "$R/sigerr2.txt")"
fi
"$F" index >/dev/null
if grep -q "^- .seat-sig. sent " "$R/factory/index.md"; then ok "the board lists unacknowledged signals"; else bad "board signals" "$(grep -A3 'Operator signals' "$R/factory/index.md" || echo missing)"; fi
"$F" signal-clear seat-sig >/dev/null
out="$("$F" claim seat-sig 2>/dev/null)"
case "$out" in
  */claimed/seat-sig/*) ok "clearing the signal releases the seat" ;;
  *) bad "signal release" "got '$out'" ;;
esac
id_sg="$(basename "$out" .md)"; id_sg="${id_sg#*-}"
"$F" requeue "$id_sg" "selftest: back" >/dev/null
printf 'all seats: stop and report\n' > "$R/broadcast.txt"
"$F" signal all "$R/broadcast.txt" >/dev/null
for w in seat-sig seat-unsignalled seat-elsewhere; do
  if "$F" claim "$w" >/dev/null 2>&1; then bad "broadcast gate" "$w claimed despite tasks/signal/all.md"; fi
done
ok "a broadcast (all.md) blocks every seat's claim"
# capture, never pipe: the refusal exits 1 and pipefail would fail the test on
# the WRITER's status even when grep matched.
out="$("$F" claim seat-sig 2>&1 || true)"
if printf '%s' "$out" | grep -q "stop and report"; then ok "signal <who> <file> takes the order from a file"; else bad "signal from file" "got '$out'"; fi
"$F" signal-clear all >/dev/null
if [ "$("$F" signal-list)" = "NONE" ]; then ok "signal-list prints NONE once acknowledged"; else bad "signal drain" "$("$F" signal-list)"; fi
if "$F" signal-clear seat-nobody >/dev/null 2>&1; then bad "signal-clear unknown" "clearing a non-existent signal succeeded"; else ok "signal-clear refuses an unknown addressee"; fi

echo "== a broadcast is acknowledged PER SEAT (tasks/signal/all.acked/) =="
# all.md is one file for every seat; deleting it on the first ack released the
# other nine before they read it (2026-09-02). So `signal-clear <worker>` with a
# broadcast standing records that worker in the ack ledger and all.md keeps
# blocking every OTHER seat; a re-sent broadcast resets the ledger; only
# `signal-clear all` (the operator) deletes the file and the ledger together.
"$F" signal all "everyone: recycle your replica" >/dev/null
if "$F" claim seat-ack-a >/dev/null 2>&1; then bad "bcast unacked" "seat-ack-a claimed with the broadcast unacked"; else ok "a fresh broadcast blocks an unacked seat"; fi
out="$("$F" signal-clear seat-ack-a)"
if [ "$out" = "acked broadcast for seat-ack-a" ]; then ok "signal-clear <worker> under a broadcast records the seat's ack"; else bad "bcast ack" "got '$out'"; fi
if [ -e "$R/signal/all.acked/seat-ack-a" ]; then ok "the ack is a marker file in signal/all.acked/"; else bad "ack marker" "$(ls -la "$R/signal" 2>&1)"; fi
out="$("$F" claim seat-ack-a 2>/dev/null)"
case "$out" in
  */claimed/seat-ack-a/*) ok "the acked seat claims while the broadcast still stands" ;;
  *) bad "acked claim" "got '$out'" ;;
esac
id_ba="$(basename "$out" .md)"; id_ba="${id_ba#*-}"
"$F" requeue "$id_ba" "selftest: back" >/dev/null
if "$F" claim seat-ack-b >/dev/null 2>&1; then bad "bcast other seat" "seat-ack-b claimed without acking"; else ok "an unacked seat is still refused after another seat's ack"; fi
out="$("$F" signal-clear seat-ack-a)"
if [ "$out" = "already acked broadcast for seat-ack-a" ]; then ok "a repeated ack is idempotent"; else bad "bcast re-ack" "got '$out'"; fi
out="$("$F" signal-list)"
if printf '%s' "$out" | grep -q "^all	[0-9]*m	acked 1: seat-ack-a$"; then ok "signal-list shows the broadcast's ack ledger"; else bad "bcast list" "got '$out'"; fi
"$F" index >/dev/null
if grep -q '^- `all` (broadcast) sent .* - acked 1: seat-ack-a - ' "$R/factory/index.md"; then ok "the board mirrors the ack ledger"; else bad "board bcast" "$(grep -A3 'Operator signals' "$R/factory/index.md" || echo missing)"; fi
# A per-seat order and the broadcast both standing: signal-clear <worker>
# deletes the per-seat file first (today's behavior) and points at the broadcast.
"$F" signal seat-ack-b "and you: also stop" >/dev/null
out="$("$F" signal-clear seat-ack-b 2>"$R/bcast-warn.txt")"
if [ "$out" = "cleared seat-ack-b" ] && [ ! -e "$R/signal/seat-ack-b.md" ]; then ok "a per-seat order clears first when both stand"; else bad "per-seat first" "out='$out'"; fi
if grep -q "a broadcast (all.md) still addresses 'seat-ack-b'" "$R/bcast-warn.txt"; then ok "...and the seat is told the broadcast still awaits its ack"; else bad "bcast reminder" "$(cat "$R/bcast-warn.txt")"; fi
if "$F" claim seat-ack-b >/dev/null 2>&1; then bad "bcast after per-seat" "seat-ack-b claimed with the broadcast unacked"; else ok "the broadcast still blocks that seat until its own ack"; fi
# An ack must NOT wake every other seat's parked watch (ten seats acking one
# broadcast would wake every poll ten times for nothing); a broadcast must.
"$F" watch 25 > "$R/watch2.out" 2>/dev/null &
w_pid=$!
sleep 2
"$F" signal-clear seat-ack-b >/dev/null
wait "$w_pid"
if [ "$(cat "$R/watch2.out")" = "TIMEOUT" ]; then ok "a broadcast ack does not wake a parked watch"; else bad "ack wake" "got '$(cat "$R/watch2.out")'"; fi
"$F" watch 90 > "$R/watch3.out" 2>/dev/null &
w_pid=$!
sleep 2
"$F" signal all "everyone: the order changed" >"$R/bcast2.txt" 2>&1
wait "$w_pid"
if [ "$(cat "$R/watch3.out")" = "CHANGED" ]; then ok "a re-sent broadcast wakes a parked watch"; else bad "bcast wake" "got '$(cat "$R/watch3.out")'"; fi
if grep -q "ack ledger reset" "$R/bcast2.txt"; then ok "a re-sent broadcast announces the ledger reset"; else bad "ledger reset note" "$(cat "$R/bcast2.txt")"; fi
if [ -e "$R/signal/all.acked" ]; then bad "ledger reset" "all.acked/ survived a re-sent broadcast"; else ok "a re-sent broadcast resets the ledger"; fi
if "$F" claim seat-ack-a >/dev/null 2>&1; then bad "re-block" "seat-ack-a claimed without acking the changed order"; else ok "the changed order re-blocks a previously acked seat"; fi
out="$("$F" signal-list)"
if printf '%s' "$out" | grep -q "^all	[0-9]*m	acked 0$"; then ok "signal-list shows acked 0 after the reset"; else bad "bcast list reset" "got '$out'"; fi
"$F" signal-clear seat-ack-a >/dev/null
"$F" signal-clear all >/dev/null
if [ "$("$F" signal-list)" = "NONE" ] && [ ! -e "$R/signal/all.acked" ]; then ok "signal-clear all deletes the broadcast and its ledger"; else bad "bcast hard delete" "$(ls -la "$R/signal" 2>&1)"; fi
if "$F" signal-clear seat-ack-a >/dev/null 2>&1; then bad "no-signal ack" "signal-clear succeeded with nothing standing"; else ok "signal-clear <worker> with no signal standing still errors"; fi
out="$("$F" claim seat-sig 2>/dev/null)"
case "$out" in
  */claimed/seat-sig/*) ok "claims flow again once the broadcast is cleared" ;;
  *) bad "post-broadcast claim" "got '$out'" ;;
esac

echo "== the seat pin (.factory-worker) survives cwd drift =="
# The realistic drift: an executor subagent or a backgrounded shell runs inside
# a worktree whose BRANCH names another seat. A throwaway git repo reproduces
# it exactly - branch says one thing, the pin says the seat's own name.
SEAT="$R/seatwt"
mkdir -p "$SEAT/deep/dir" "$R/nopin"
git init -q "$SEAT" 2>/dev/null
git -C "$SEAT" symbolic-ref HEAD refs/heads/claude-drifted-seat 2>/dev/null
mk "" "pin task one"
out="$(cd "$R/nopin" && FACTORY_WORKER=seat-nopin "$F" claim 2>/dev/null)"
case "$out" in
  */claimed/seat-nopin/*) ok "no pin present: behaviour is exactly as before" ;;
  *) bad "pin absent" "got '$out'" ;;
esac
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" requeue "$id" "selftest" >/dev/null
if (cd "$R/nopin" && "$F" claim >/dev/null 2>&1); then
  bad "no identity" "a claim with no arg, no env, no pin and no branch succeeded"
else
  ok "no arg, no env, no pin, no branch: claim still refuses"
fi
printf 'seat-pinned\n' > "$SEAT/.factory-worker"
out="$(cd "$SEAT" && "$F" claim 2>"$R/pin1.txt")"
case "$out" in
  */claimed/seat-pinned/*) ok "the pin names the worker when no arg/env is given" ;;
  *) bad "pin claim" "got '$out'" ;;
esac
if grep -q "overrode the cwd branch" "$R/pin1.txt"; then ok "the pin beating the branch is reported"; else bad "drift report" "$(cat "$R/pin1.txt")"; fi
if grep -q "worker: seat-pinned" "$R/pin1.txt"; then ok "the effective worker is still printed"; else bad "pin worker print" "$(cat "$R/pin1.txt")"; fi
id_pin="$(basename "$out" .md)"; id_pin="${id_pin#*-}"
out="$(cd "$SEAT/deep/dir" && "$F" requeue "$id_pin" "selftest" 2>/dev/null)"
mk "" "pin task two"
out="$(cd "$SEAT/deep/dir" && "$F" claim 2>/dev/null)"
case "$out" in
  */claimed/seat-pinned/*) ok "a SUBDIRECTORY of the seat resolves the same pin (the subagent case)" ;;
  *) bad "pin search-up" "got '$out'" ;;
esac
id_pin="$(basename "$out" .md)"; id_pin="${id_pin#*-}"
out="$(cd "$SEAT" && "$F" requeue "$id_pin" "selftest" 2>"$R/pin2.txt")"
if grep -q "law 3" "$R/pin2.txt"; then bad "owner warning" "requeue warned about a task the seat itself holds"; else ok "requeue is quiet when the pin owns the claim"; fi
mk "" "pin task three"
out="$(cd "$SEAT" && "$F" claim seat-other 2>"$R/pin3.txt")"
case "$out" in
  */claimed/seat-other/*) ok "an explicit worker arg still beats the pin" ;;
  *) bad "arg over pin" "got '$out'" ;;
esac
if grep -q "pinned as 'seat-pinned'" "$R/pin3.txt"; then ok "the disagreement is warned about"; else bad "disagreement warning" "$(cat "$R/pin3.txt")"; fi
id_other="$(basename "$out" .md)"; id_other="${id_other#*-}"
out="$(cd "$SEAT" && "$F" requeue "$id_other" "selftest" 2>"$R/pin4.txt")"
if grep -q "law 3" "$R/pin4.txt"; then ok "requeue warns when the pin does not own the claim"; else bad "owner mismatch" "$(cat "$R/pin4.txt")"; fi
out="$(cd "$SEAT" && FACTORY_WORKER=seat-env2 "$F" worker 2>/dev/null | cut -f1)"
if [ "$out" = "seat-env2" ]; then ok "worker reports FACTORY_WORKER ahead of the pin"; else bad "worker env" "got '$out'"; fi
out="$(cd "$SEAT/deep" && "$F" worker 2>/dev/null | cut -f1)"
if [ "$out" = "seat-pinned" ]; then ok "worker reports the pin from a subdirectory"; else bad "worker pin" "got '$out'"; fi
rm -f "$SEAT/.factory-worker"
out="$(cd "$SEAT" && "$F" worker-pin 2>/dev/null)"
# (the printed path is the git toplevel, which on macOS resolves /var -> /private/var)
if [ "$(basename "$out")" = ".factory-worker" ] && [ "$(cat "$SEAT/.factory-worker")" = "claude-drifted-seat" ]; then
  ok "worker-pin writes the flattened branch to the worktree root"
else
  bad "worker-pin" "got '$out' / '$(cat "$SEAT/.factory-worker" 2>/dev/null)'"
fi
out="$(cd "$SEAT" && "$F" worker-pin seat-renamed 2>/dev/null)"
if [ "$(cat "$SEAT/.factory-worker")" = "seat-renamed" ]; then ok "worker-pin <name> repins"; else bad "worker-pin name" "$(cat "$SEAT/.factory-worker")"; fi
if (cd "$SEAT" && "$F" worker-pin "bad/name" >/dev/null 2>&1); then
  bad "pin validation" "a slash-bearing worker name was accepted"
else
  ok "worker-pin refuses a name that is not a directory name"
fi
printf '   \n' > "$SEAT/.factory-worker"
mk "" "pin task four"
out="$(cd "$SEAT" && FACTORY_WORKER=seat-blank "$F" claim 2>/dev/null)"
case "$out" in
  */claimed/seat-blank/*) ok "a blank pin file is ignored, not fatal" ;;
  *) bad "blank pin" "got '$out'" ;;
esac
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" requeue "$id" "selftest" >/dev/null
printf 'seat-pinned\n' > "$SEAT/.factory-worker"
printf 'boot prompt\n' > "$R/handoff/seatwt.md"
(cd "$SEAT" && "$F" handoff-clear seatwt >/dev/null 2>&1)
if [ "$(cat "$SEAT/.factory-worker")" = "claude-drifted-seat" ]; then
  ok "handoff-clear repins the seat for the successor"
else
  bad "handoff repin" "$(cat "$SEAT/.factory-worker")"
fi

echo "== the law-5 primary-checkout guards (task 1787719645) =="
# A throwaway "primary" repo with a linked worktree reproduces the breach
# layout exactly; nothing here touches the real checkout.
HOOK="$HERE/../.githooks/pre-commit"
GP="$R/guard-primary"
mkdir -p "$GP"
git init -q "$GP" 2>/dev/null
git -C "$GP" symbolic-ref HEAD refs/heads/main 2>/dev/null
git -C "$GP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
git -C "$GP" worktree add -q "$R/guard-wt" -b claude/guard-seat 2>/dev/null
if (cd "$GP" && FACTORY_WORKER=seat-x "$HOOK" >/dev/null 2>"$R/g1.txt"); then
  bad "hook seat refusal" "a seat-identified commit on primary main was allowed"
else
  ok "pre-commit refuses a consumer-seat commit on the primary's main"
fi
if grep -q "law 5" "$R/g1.txt" && grep -q "merge protocol" "$R/g1.txt"; then
  ok "the refusal names the law and the remedy"
else
  bad "hook message" "$(cat "$R/g1.txt")"
fi
if (cd "$GP" && env -u FACTORY_WORKER "$HOOK" >/dev/null 2>&1); then
  ok "no seat identity: operator-shaped commits in the primary pass (fail-open)"
else
  bad "hook operator" "an identity-free primary commit was refused"
fi
if (cd "$GP" && FACTORY_WORKER=operator "$HOOK" >/dev/null 2>&1); then
  ok "the 'operator' identity passes"
else
  bad "hook operator id" "FACTORY_WORKER=operator was refused"
fi
if (cd "$R/guard-wt" && FACTORY_WORKER=seat-x "$HOOK" >/dev/null 2>&1); then
  ok "a seat committing in its OWN worktree passes (git-dir != common-dir)"
else
  bad "hook worktree" "a seat commit in a linked worktree was refused"
fi
git -C "$GP" checkout -q -b not-main 2>/dev/null
if (cd "$GP" && FACTORY_WORKER=seat-x "$HOOK" >/dev/null 2>&1); then
  ok "a non-main branch in the primary passes (main is the guarded ref)"
else
  bad "hook branch" "a non-main primary commit was refused"
fi
git -C "$GP" checkout -q main 2>/dev/null
if (cd "$GP" && FACTORY_WORKER=seat-x FACTORY_FORCE=1 "$HOOK" >/dev/null 2>"$R/g2.txt"); then
  ok "FACTORY_FORCE=1 overrides the hook"
else
  bad "hook force" "$(cat "$R/g2.txt")"
fi
# The pin path: a .factory-worker file at/above the cwd counts as identity too.
printf 'seat-pin-x\n' > "$GP/.factory-worker"
if (cd "$GP" && env -u FACTORY_WORKER "$HOOK" >/dev/null 2>"$R/g3.txt"); then
  bad "hook pin refusal" "a pin-identified primary commit was allowed"
else
  ok "a .factory-worker pin (no env) also refuses"
fi
rm -f "$GP/.factory-worker"
echo "== the no-identity belt: a factory running + no identity + primary main (task 1791133471) =="
# A pinned seat under the seat root means a factory is RUNNING: an identity-free
# commit on the primary's main must now declare itself (FACTORY_DIRECT=1).
mkdir -p "$GP/.factory/seats/seat-pinned" && printf 'claude-seat-pinned\n' > "$GP/.factory/seats/seat-pinned/.factory-worker"
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT "$HOOK" >/dev/null 2>"$R/g5.txt"); then
  bad "belt refusal" "an identity-free commit on primary main passed while a seat is pinned"
else
  ok "pinned seat + no identity + primary main: refused"
fi
if grep -q "FACTORY_DIRECT=1" "$R/g5.txt" && grep -q "executor-env" "$R/g5.txt" && grep -q "seat-pinned" "$R/g5.txt"; then
  ok "the refusal names FACTORY_DIRECT=1, the executor-env line and the pinned seat"
else
  bad "belt message" "$(cat "$R/g5.txt")"
fi
if (cd "$GP" && env -u FACTORY_WORKER FACTORY_DIRECT=1 "$HOOK" >/dev/null 2>&1); then
  ok "FACTORY_DIRECT=1 (the operator's direct round) passes"
else
  bad "belt direct" "FACTORY_DIRECT=1 was refused"
fi
if (cd "$GP" && FACTORY_WORKER=operator env -u FACTORY_DIRECT "$HOOK" >/dev/null 2>&1); then
  ok "FACTORY_WORKER=operator (the declared operator identity) passes"
else
  bad "belt operator" "the operator identity was refused under the belt"
fi
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT FACTORY_FORCE=1 "$HOOK" >/dev/null 2>"$R/g6.txt") && grep -q "overridden" "$R/g6.txt"; then
  ok "FACTORY_FORCE=1 overrides the belt with a warning"
else
  bad "belt force" "$(cat "$R/g6.txt")"
fi
if (cd "$GP" && FACTORY_WORKER=seat-x env -u FACTORY_DIRECT "$HOOK" >/dev/null 2>"$R/g7.txt"); then
  bad "belt seat" "a seat-identified commit passed with pins present"
else
  grep -q "law 5" "$R/g7.txt" && ok "a seat-identified commit on the primary's main stays refused (guard B, unchanged)" || bad "belt seat msg" "$(cat "$R/g7.txt")"
fi
if (cd "$R/guard-wt" && env -u FACTORY_WORKER -u FACTORY_DIRECT "$HOOK" >/dev/null 2>&1); then
  ok "a commit in a linked worktree passes with pins present (the belt guards the primary only)"
else
  bad "belt worktree" "a worktree commit was refused under the belt"
fi
git -C "$GP" checkout -q -b belt-side 2>/dev/null
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT "$HOOK" >/dev/null 2>&1); then
  ok "a non-main branch in the primary passes with pins present"
else
  bad "belt branch" "a non-main primary commit was refused under the belt"
fi
git -C "$GP" checkout -q main 2>/dev/null
# The legacy pin location counts too, as does a linked worktree's pin anywhere.
rm -rf "$GP/.factory"
mkdir -p "$GP/.claude/worktrees/old-seat" && printf 'claude-old-seat\n' > "$GP/.claude/worktrees/old-seat/.factory-worker"
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT "$HOOK" >/dev/null 2>&1); then
  bad "belt legacy pin" "a legacy .claude/worktrees pin did not count as a running factory"
else
  ok "a pin at the legacy .claude/worktrees/<seat> location counts"
fi
rm -rf "$GP/.claude"
printf 'claude-guard-seat\n' > "$R/guard-wt/.factory-worker"
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT "$HOOK" >/dev/null 2>"$R/g8.txt"); then
  bad "belt wt pin" "a linked worktree's pin outside both seat roots did not count"
else
  grep -q "guard-wt" "$R/g8.txt" && ok "a linked worktree's pin anywhere counts (git worktree list)" || bad "belt wt pin msg" "$(cat "$R/g8.txt")"
fi
rm -f "$R/guard-wt/.factory-worker"
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT "$HOOK" >/dev/null 2>&1); then
  ok "no pins anywhere: an identity-free primary commit passes again (fail-open only when no factory runs)"
else
  bad "belt no pins" "an identity-free commit was refused with no seat pinned"
fi
# End-to-end: with core.hooksPath set, git itself consults the hook.
git -C "$GP" config core.hooksPath "$HERE/../.githooks"
if (cd "$GP" && FACTORY_WORKER=seat-x git -c user.email=t@t -c user.name=t commit -q --allow-empty -m breach >/dev/null 2>&1); then
  bad "hooked commit" "git commit with a seat identity succeeded on primary main"
else
  ok "a real 'git commit' under core.hooksPath is refused end-to-end"
fi
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT git -c user.email=t@t -c user.name=t commit -q --allow-empty -m ok-round >/dev/null 2>&1); then
  ok "a real identity-free commit still lands under the hook (no factory running)"
else
  bad "hooked operator commit" "an identity-free commit was refused"
fi
mkdir -p "$GP/.factory/seats/seat-pinned" && printf 'claude-seat-pinned\n' > "$GP/.factory/seats/seat-pinned/.factory-worker"
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT git -c user.email=t@t -c user.name=t commit -q --allow-empty -m drifted >/dev/null 2>"$R/g9.txt"); then
  bad "hooked belt" "a real identity-free 'git commit' on primary main landed while a seat is pinned"
else
  grep -q "FACTORY_DIRECT=1" "$R/g9.txt" && ok "a real identity-free 'git commit' is refused end-to-end while a seat is pinned, naming FACTORY_DIRECT=1" || bad "hooked belt msg" "$(cat "$R/g9.txt")"
fi
if (cd "$GP" && env -u FACTORY_WORKER FACTORY_DIRECT=1 git -c user.email=t@t -c user.name=t commit -q --allow-empty -m direct-round >/dev/null 2>&1); then
  ok "FACTORY_DIRECT=1 git commit lands end-to-end"
else
  bad "hooked direct" "a FACTORY_DIRECT=1 commit was refused"
fi
# THE MERGE PATH: a seat's `git -C <primary> merge --no-ff` must keep landing -
# with pins present and under a seat identity (git-merge runs pre-merge-commit,
# never pre-commit; none is shipped). The branch gets a commit in the worktree.
(cd "$R/guard-wt" && printf 'x\n' > merged-file && git add merged-file && git -c user.email=t@t -c user.name=t commit -q -m seat-work) >/dev/null 2>&1
if (cd "$GP" && FACTORY_WORKER=seat-x env -u FACTORY_DIRECT git -c user.email=t@t -c user.name=t merge --no-ff -q -m "merge: seat-work" claude/guard-seat >/dev/null 2>"$R/g10.txt"); then
  ok "a seat-identified 'git merge --no-ff' into the primary's main lands with pins present (the merge protocol is untouched)"
else
  bad "hooked merge" "$(cat "$R/g10.txt")"
fi
(cd "$R/guard-wt" && printf 'y\n' > merged-file-2 && git add merged-file-2 && git -c user.email=t@t -c user.name=t commit -q -m seat-work-2) >/dev/null 2>&1
if (cd "$GP" && env -u FACTORY_WORKER -u FACTORY_DIRECT git -c user.email=t@t -c user.name=t merge --no-ff -q -m "merge: seat-work-2" claude/guard-seat >/dev/null 2>"$R/g11.txt"); then
  ok "an identity-free 'git merge --no-ff' lands too (the belt guards commits, not merges)"
else
  bad "hooked merge no-id" "$(cat "$R/g11.txt")"
fi
rm -rf "$GP/.factory"

echo "== factory.sh executor-env: the line a seat pastes into its executor prompt (task 1791133471) =="
printf 'claude-guard-seat\n' > "$R/guard-wt/.factory-worker"
out="$(cd "$R/guard-wt" && env -u FACTORY_WORKER "$F" executor-env 2>/dev/null)"
if [ "$out" = "FACTORY_WORKER=claude-guard-seat FACTORY_SEAT_ROOT=$(cd "$R/guard-wt" && pwd -P)" ]; then
  ok "executor-env prints FACTORY_WORKER=<pin> FACTORY_SEAT_ROOT=<worktree> from inside the pinned worktree"
else
  bad "executor-env" "got '$out'"
fi
out="$(cd "$R/guard-wt" && FACTORY_WORKER=claude-drifted "$F" executor-env 2>"$R/g13.txt")"
if [ "$out" = "FACTORY_WORKER=claude-guard-seat FACTORY_SEAT_ROOT=$(cd "$R/guard-wt" && pwd -P)" ] && grep -q "the pin wins" "$R/g13.txt"; then
  ok "a differing FACTORY_WORKER in the shell loses to the pin (noted on stderr)"
else
  bad "executor-env drift" "got '$out' / $(cat "$R/g13.txt")"
fi
if (cd "$GP" && env -u FACTORY_WORKER "$F" executor-env >/dev/null 2>"$R/g14.txt"); then
  bad "executor-env primary" "the unpinned primary minted a line"
else
  grep -q "no .factory-worker pin" "$R/g14.txt" && ok "from the unpinned primary it refuses (a line cannot be minted there)" || bad "executor-env primary msg" "$(cat "$R/g14.txt")"
fi
rm -f "$R/guard-wt/.factory-worker"

echo "== boot-env sets the effort variable the CLI READS =="
# CLAUDE_CODE_EFFORT_LEVEL is the input ("apply_flag_settings: CLAUDE_CODE_EFFORT_LEVEL
# overrides effort for this session"); CLAUDE_EFFORT is what the CLI reports to
# hooks and Bash and never reads - BOOT_ENV_SET set only that until 2026-10-03.
out="$("$F" boot-env)"
case " $out " in *" CLAUDE_CODE_EFFORT_LEVEL=max "*) ok "boot-env carries CLAUDE_CODE_EFFORT_LEVEL=max" ;; *) bad "boot-env effort" "$out" ;; esac
case " $out " in *" CLAUDE_EFFORT="*) bad "boot-env stale effort" "CLAUDE_EFFORT= (the CLI's OUTPUT variable) is still set: $out" ;; *) ok "boot-env no longer sets CLAUDE_EFFORT (output-only, never read)" ;; esac

echo "== merge-lock acquire warns when there is nothing to merge =="
# The direct-to-main signature: the branch tip carries no commits beyond main.
out="$(cd "$GP" && "$F" merge-lock acquire claude/guard-seat 2>"$R/g5.txt")"
if [ "$out" = "acquired" ]; then ok "acquire still succeeds (warn, never refuse)"; else bad "acquire warn" "got '$out'"; fi
if grep -q "NO commits beyond main" "$R/g5.txt"; then
  ok "acquire warns when the branch has nothing beyond main"
else
  bad "nothing-to-merge warn" "$(cat "$R/g5.txt")"
fi
"$F" merge-lock release claude/guard-seat >/dev/null
git -C "$R/guard-wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work 2>/dev/null
out="$(cd "$GP" && "$F" merge-lock acquire claude/guard-seat 2>"$R/g6.txt")"
if grep -q "NO commits beyond main" "$R/g6.txt"; then
  bad "warn false positive" "a branch WITH unmerged commits was warned about"
else
  ok "a branch with unmerged commits acquires silently (no false positive)"
fi
"$F" merge-lock release claude/guard-seat >/dev/null
out="$(cd "$GP" && "$F" merge-lock acquire some-worker-name 2>"$R/g7.txt")"
if [ "$out" = "acquired" ] && ! grep -q "NO commits" "$R/g7.txt"; then
  ok "a worker-name label (no such ref) skips the check cleanly"
else
  bad "non-ref label" "out='$out' err='$(cat "$R/g7.txt")'"
fi
"$F" merge-lock release some-worker-name >/dev/null
git -C "$GP" worktree remove --force "$R/guard-wt" 2>/dev/null
rm -rf "$GP" "$R/guard-wt"

echo "== merge-lock acquire --task <id>: the claim belt (a requeued task never merges behind the lock) =="
# Nothing between execute and merge read tasks/claimed/ before (a reviewer's
# note on open-saas PR #17): a claim requeued under a working seat merged anyway. The
# seat identity is the done/requeue one: FACTORY_WORKER > pin > cwd branch.
# Isolated tasks root (RB): the shared queue carries leftovers from earlier
# sections, and this section's claim must take ITS task.
RB="$(mktemp -d)"
FB() { FACTORY_TASKS_ROOT="$RB" "$F" "$@"; }   # factory.sh against the isolated root
echo "help: no user-facing change" > "$RB/seat-belt.done"
{ echo "---"; echo "touches: open-hr"; echo "---"; echo "# belt task still claimed"; } > "$RB/draft.md"
p_b="$(FB new "$RB/draft.md")"
id_b="$(basename "$p_b" .md)"; id_b="${id_b#*-}"
out="$(FB claim seat-belt)"
if grep -q "belt task still claimed" "$out" 2>/dev/null; then ok "the belt task is claimed by seat-belt"; else bad "belt claim" "got '$out'"; fi
out="$(FACTORY_WORKER=seat-belt FB merge-lock acquire some-worker-name 240 --task "$id_b" 2>"$RB/g8.txt")"
if [ "$out" = "acquired" ]; then ok "--task on a task CLAIMED by this seat acquires (max-wait still positional)"; else bad "belt acquire" "out='$out' err='$(cat "$RB/g8.txt")'"; fi
FB merge-lock release some-worker-name >/dev/null
FB requeue "$id_b" "requeued under the seat" >/dev/null
if out="$(FACTORY_WORKER=seat-belt FB merge-lock acquire some-worker-name --task "$id_b" 2>"$RB/g9.txt")"; then bad "belt requeued" "a requeued task acquired: '$out'"; else ok "--task on a task back in the QUEUE is refused (rc 1)"; fi
if grep -q "back in the QUEUE" "$RB/g9.txt" && grep -q "claim again" "$RB/g9.txt"; then ok "the refusal names the requeue and the remedy"; else bad "belt refusal text" "$(cat "$RB/g9.txt")"; fi
if [ "$(FB merge-lock status)" = "free" ]; then ok "a refused acquire holds no lock"; else bad "belt lock leak" "$(FB merge-lock status)"; fi
out="$(FB claim seat-belt)"
if grep -q "belt task still claimed" "$out" 2>/dev/null; then ok "re-claimed by seat-belt"; else bad "belt re-claim" "got '$out'"; fi
if out="$(FACTORY_WORKER=seat-other FB merge-lock acquire some-worker-name --task "$id_b" 2>"$RB/g10.txt")"; then bad "belt other seat" "another seat acquired on this claim: '$out'"; else ok "a seat that is not the holder is refused (law 3)"; fi
if grep -q "claimed by 'seat-belt'" "$RB/g10.txt" && grep -q "resolves as 'seat-other'" "$RB/g10.txt"; then ok "the refusal names the holder and this seat"; else bad "belt identity text" "$(cat "$RB/g10.txt")"; fi
out="$(FACTORY_WORKER=seat-other FACTORY_FORCE=1 FB merge-lock acquire some-worker-name --task "$id_b" 2>"$RB/g11.txt")"
if [ "$out" = "acquired" ] && grep -q "claim belt overridden" "$RB/g11.txt"; then ok "FACTORY_FORCE=1 turns the refusal into a warning"; else bad "belt force" "out='$out' err='$(cat "$RB/g11.txt")'"; fi
FB merge-lock release some-worker-name >/dev/null
if out="$(FACTORY_WORKER=seat-belt FB merge-lock acquire some-worker-name --task 9999999999 2>"$RB/g12.txt")"; then bad "belt unknown" "an unknown id acquired: '$out'"; else ok "--task on an id that is nowhere is refused"; fi
if out="$(FACTORY_WORKER=seat-belt FB merge-lock acquire some-worker-name --task 2>"$RB/g13.txt")"; then bad "belt no id" "--task without an id acquired"; else ok "--task without an id is a usage error"; fi
out="$(FB merge-lock acquire some-worker-name 2>/dev/null)"
if [ "$out" = "acquired" ]; then ok "without --task the acquire is as before (the operator's shape)"; else bad "belt plain" "got '$out'"; fi
FB merge-lock release some-worker-name >/dev/null
FB done "$id_b" done >/dev/null
rm -rf "$RB"

echo "== merge-land: step 6d-6h as one door, with the proof that main moved (task 1792601027) =="
# A throwaway primary + a linked seat worktree, an isolated tasks root for the
# lock, and STUB lints under FACTORY_LINT_DIR (the real ones read this repo).
# The incident (2026-10-21): the hand chain's `git -C "$PRIMARY" merge --no-ff`
# answered "Already up to date." with exit 0, and every later step read that
# as a landing. Here the door must prove main moved, refuse the self-merge
# shape, and never leave the lock held after a refusal.
RB="$(mktemp -d)"
FB() { FACTORY_TASKS_ROOT="$RB" "$F" "$@"; }   # factory.sh against the isolated root
MP="$RB/land-primary"; MW="$RB/land-wt"; LD="$RB/lints"
mkdir -p "$MP" "$LD"
git init -q "$MP" 2>/dev/null
git -C "$MP" symbolic-ref HEAD refs/heads/main 2>/dev/null
git -C "$MP" config user.email t@t; git -C "$MP" config user.name t
git -C "$MP" commit -q --allow-empty -m init 2>/dev/null
git -C "$MP" worktree add -q "$MW" -b claude/land-seat 2>/dev/null
seatwork() { (cd "$MW" && printf '%s\n' "$1" > "$1" && git add "$1" && git commit -q -m "$1") >/dev/null 2>&1; }   # one commit on the seat branch
sync6a() { (cd "$MW" && git merge -q main) >/dev/null 2>&1; }   # step 6a: main INTO the branch (after a landing the branch is behind main by the merge commit)
printf '#!/bin/bash\necho "stub ratchet$*"\nexit ${STUB_RATCHET_RC:-0}\n' > "$LD/lint-ratchet.sh"   # MULTI/DEX: the ONE merge-gate lint
chmod +x "$LD"/*.sh
land() { (cd "$MW" && FACTORY_LINT_DIR="$LD" FB merge-land "$@"); }   # the door, from the seat's worktree
seatwork work-1
m0="$(git -C "$MP" rev-parse main)"
# the lock first: free, or another label's, refuses and touches nothing
if out="$(land claude/land-seat -m "merge: work-1 from claude/land-seat" 2>"$RB/l1.err")"; then bad "land no lock" "landed without the lock: '$out'"; else ok "merge-land refuses when the merge lock is free (rc 1)"; fi
if grep -q "merge lock is FREE" "$RB/l1.err" && grep -q "merge-lock acquire claude/land-seat" "$RB/l1.err"; then ok "the refusal names step 6c"; else bad "no-lock text" "$(cat "$RB/l1.err")"; fi
FB merge-lock acquire other-seat >/dev/null
if out="$(land claude/land-seat -m "merge: work-1 from claude/land-seat" 2>"$RB/l2.err")"; then bad "land other lock" "landed under another label's lock: '$out'"; else ok "merge-land refuses under a lock held for another label"; fi
if grep -q "held by 'other-seat', not 'claude/land-seat'" "$RB/l2.err"; then ok "the refusal names both labels"; else bad "other-lock text" "$(cat "$RB/l2.err")"; fi
case "$(FB merge-lock status)" in "held by other-seat for "*) ok "another label's lock is left standing by the refusal" ;; *) bad "other lock kept" "$(FB merge-lock status)" ;; esac
FB merge-lock release other-seat >/dev/null
if [ "$(git -C "$MP" rev-parse main)" = "$m0" ]; then ok "main untouched by the refusals"; else bad "main moved on refusal" "$(git -C "$MP" log --oneline -3 main)"; fi
# usage: the message is required; an arg error comes before the lock check
FB merge-lock acquire claude/land-seat >/dev/null
if out="$(land claude/land-seat 2>"$RB/l3.err")"; then bad "land no msg" "landed without a message"; else ok "the merge message is required (-m or -F)"; fi
if grep -q "merge message is required" "$RB/l3.err"; then ok "the usage names -m / -F"; else bad "no-msg text" "$(cat "$RB/l3.err")"; fi
case "$(FB merge-lock status)" in "held by claude/land-seat for "*) ok "a usage error (before the lock check) leaves the lock held" ;; *) bad "usage lock" "$(FB merge-lock status)" ;; esac
# the landing
out="$(land claude/land-seat -m "merge: work-1 from claude/land-seat" 2>"$RB/l4.err")"; rc=$?
m1="$(git -C "$MP" rev-parse main)"
if [ "$rc" = "0" ] && [ "$m1" != "$m0" ]; then ok "merge-land lands the branch: rc 0 and main moved"; else bad "land" "rc=$rc main $m0 -> $m1 out='$out' err='$(cat "$RB/l4.err")'"; fi
if git -C "$MP" merge-base --is-ancestor claude/land-seat main 2>/dev/null; then ok "the branch is an ancestor of main after the landing"; else bad "land ancestor" "$(git -C "$MP" log --oneline -4 main)"; fi
if [ "$(git -C "$MP" rev-parse main^2 2>/dev/null)" = "$(git -C "$MP" rev-parse claude/land-seat)" ]; then ok "a --no-ff merge commit: main's second parent is the branch tip"; else bad "land no-ff" "$(git -C "$MP" log --oneline -4 main)"; fi
if [ "$(git -C "$MP" log -1 --format=%s main)" = "merge: work-1 from claude/land-seat" ]; then ok "the merge message is the -m text"; else bad "land msg" "$(git -C "$MP" log -1 --format=%s main)"; fi
if printf '%s\n' "$out" | grep -q "^main before: $m0\$" && printf '%s\n' "$out" | grep -q "^main after:  $m1\$"; then ok "the before/after main shas are printed"; else bad "land shas" "$out"; fi
if printf '%s\n' "$out" | grep -q "^stub ratchet\$"; then ok "the step-6d lint (lint-ratchet.sh) ran from the seat worktree, no --changed flag"; else bad "land lints" "$out"; fi
if printf '%s\n' "$out" | grep -q "^PUSH FAILED: "; then ok "a failed push (no origin here) prints PUSH FAILED and never blocks (rc stayed 0)"; else bad "land push line" "$out"; fi
if [ "$(printf '%s\n' "$out" | tail -1)" = "merged $m1" ]; then ok "the last line is 'merged <sha>' (the archive note)"; else bad "land last line" "$(printf '%s\n' "$out" | tail -1)"; fi
if [ "$(FB merge-lock status)" = "free" ]; then ok "the lock is released after the landing"; else bad "land release" "$(FB merge-lock status)"; fi
# a second landing of the same branch (no 6a sync, no new work): nothing to merge - answered
# before the ancestor check, so a re-run after a landing never reads "main moved"
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
if out="$(land claude/land-seat -m "merge: again from claude/land-seat" 2>"$RB/l5.err")"; then bad "land twice" "a second merge-land landed: '$out'"; else ok "a second merge-land on the same branch refuses (rc 1)"; fi
if grep -q "nothing to merge" "$RB/l5.err" && grep -q "NO commits beyond main" "$RB/l5.err"; then ok "the refusal says 'nothing to merge' and names the law-5 check"; else bad "twice text" "$(cat "$RB/l5.err")"; fi
if [ "$(git -C "$MP" rev-parse main)" = "$m1" ]; then ok "main untouched by the refusal"; else bad "twice main" "$(git -C "$MP" log --oneline -3 main)"; fi
if [ "$(FB merge-lock status)" = "free" ]; then ok "the refusal released the lock"; else bad "twice lock" "$(FB merge-lock status)"; fi
# -F <file>, and the protocol's recorded lint skips (skipped BEFORE any lookup: no scripts/ here)
sync6a; seatwork work-2
printf 'merge: work-2 from claude/land-seat\n\nthe body line\n' > "$RB/msg.txt"
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
out="$(cd "$MW" && LINT_RATCHET=0 FB merge-land claude/land-seat -F "$RB/msg.txt" 2>"$RB/l6.err")"; rc=$?
m2="$(git -C "$MP" rev-parse main)"
if [ "$rc" = "0" ] && [ "$m2" != "$m1" ] && [ "$(git -C "$MP" log -1 --format=%s main)" = "merge: work-2 from claude/land-seat" ] && git -C "$MP" log -1 --format=%B main | grep -q "the body line"; then ok "-F <file> lands with the file's message"; else bad "land -F" "rc=$rc $(git -C "$MP" log -1 --format=%B main) err='$(cat "$RB/l6.err")'"; fi
if printf '%s\n' "$out" | grep -q "SKIPPED (LINT_RATCHET=0"; then ok "LINT_RATCHET=0 is the recorded skip, announced"; else bad "land skips" "$out"; fi
# a lint FAIL refuses, releases, lands nothing
sync6a; seatwork work-3
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
if out="$(cd "$MW" && STUB_RATCHET_RC=1 FACTORY_LINT_DIR="$LD" FB merge-land claude/land-seat -m "merge: work-3 from claude/land-seat" 2>"$RB/l7.err")"; then bad "land lint fail" "landed over a failing lint: '$out'"; else ok "a failing lint-stable-compat refuses the landing (rc 1)"; fi
if grep -q "lint-ratchet.sh FAILED" "$RB/l7.err"; then ok "the refusal names the failed lint"; else bad "lint-fail text" "$(cat "$RB/l7.err")"; fi
if [ "$(git -C "$MP" rev-parse main)" = "$m2" ] && [ "$(FB merge-lock status)" = "free" ]; then ok "nothing landed and the lock was released"; else bad "lint-fail state" "main $(git -C "$MP" rev-parse main) lock $(FB merge-lock status)"; fi
# a lint that is not found is a refusal, never a silent pass
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
if out="$(cd "$MW" && FACTORY_LINT_DIR="$RB/no-such-dir" FB merge-land claude/land-seat -m "merge: work-3 from claude/land-seat" 2>"$RB/l8.err")"; then bad "land lint missing" "landed with no lint found: '$out'"; else ok "a lint script that is not found refuses (fail-closed)"; fi
if printf '%s\n' "$out" | grep -q "not found at $RB/no-such-dir/lint-ratchet.sh"; then ok "the refusal names the path and FACTORY_LINT_DIR"; else bad "lint-missing text" "$out / $(cat "$RB/l8.err")"; fi
# main moved under the seat (6e): refused, back to 6a
git -C "$MP" commit -q --allow-empty -m "someone else landed" 2>/dev/null
m3="$(git -C "$MP" rev-parse main)"
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
if out="$(land claude/land-seat -m "merge: work-3 from claude/land-seat" 2>"$RB/l9.err")"; then bad "land main moved" "landed over a moved main: '$out'"; else ok "main moved since the branch's last merge of it: refused (rc 1)"; fi
if grep -q "NOT an ancestor of claude/land-seat" "$RB/l9.err" && grep -q "step 6a again" "$RB/l9.err"; then ok "the refusal names step 6a"; else bad "main-moved text" "$(cat "$RB/l9.err")"; fi
if [ "$(git -C "$MP" rev-parse main)" = "$m3" ] && [ "$(FB merge-lock status)" = "free" ]; then ok "nothing landed, lock released"; else bad "main-moved state" "$(FB merge-lock status)"; fi
sync6a   # a real merge commit this time: the branch carries work-3
# the primary mid-merge (MERGE_HEAD) and index.lock: refused, escalate
GD="$(git -C "$MP" rev-parse --git-dir)"; case "$GD" in /*) ;; *) GD="$MP/$GD" ;; esac
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
printf '%s\n' "$m3" > "$GD/MERGE_HEAD"
if out="$(land claude/land-seat -m "merge: work-3 from claude/land-seat" 2>"$RB/l10.err")"; then bad "land MERGE_HEAD" "landed over a half-finished merge: '$out'"; else ok "a half-finished merge in the primary (MERGE_HEAD) refuses"; fi
if grep -q "HALF-FINISHED merge" "$RB/l10.err" && grep -q "escalate to the operator" "$RB/l10.err"; then ok "the refusal says escalate"; else bad "MERGE_HEAD text" "$(cat "$RB/l10.err")"; fi
rm -f "$GD/MERGE_HEAD"
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
: > "$GD/index.lock"
if out="$(land claude/land-seat -m "merge: work-3 from claude/land-seat" 2>"$RB/l11.err")"; then bad "land index.lock" "landed over an index.lock: '$out'"; else ok "an index.lock in the primary refuses"; fi
if grep -q "index.lock exists" "$RB/l11.err" && grep -q "never rm a git lock file" "$RB/l11.err"; then ok "the refusal names GitHub Desktop's lock and the rule"; else bad "index.lock text" "$(cat "$RB/l11.err")"; fi
rm -f "$GD/index.lock"
if [ "$(FB merge-lock status)" = "free" ]; then ok "both preflight refusals released the lock"; else bad "preflight lock" "$(FB merge-lock status)"; fi
# the primary with anything but main checked out: refused
git -C "$MP" checkout -q -b elsewhere 2>/dev/null
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
if out="$(land claude/land-seat -m "merge: work-3 from claude/land-seat" 2>"$RB/l12.err")"; then bad "land not-main" "landed with 'elsewhere' checked out in the primary: '$out'"; else ok "a primary with anything but main checked out refuses"; fi
if grep -q "has 'elsewhere' checked out, not main" "$RB/l12.err"; then ok "the refusal names the branch found"; else bad "not-main text" "$(cat "$RB/l12.err")"; fi
git -C "$MP" checkout -q main 2>/dev/null; git -C "$MP" branch -q -D elsewhere 2>/dev/null
# --task: the claim belt once more, right before the merge
{ echo "---"; echo "touches: scripts"; echo "---"; echo "# the landing task"; } > "$RB/draft.md"
p_l="$(FB new "$RB/draft.md")"; id_l="$(basename "$p_l" .md)"; id_l="${id_l#*-}"
FB claim seat-land >/dev/null
FB requeue "$id_l" "requeued under the seat" >/dev/null
FACTORY_WORKER=seat-land FB merge-lock acquire claude/land-seat >/dev/null 2>&1
if out="$(cd "$MW" && FACTORY_WORKER=seat-land FACTORY_LINT_DIR="$LD" FB merge-land claude/land-seat -m "merge: work-3 from claude/land-seat" --task "$id_l" 2>"$RB/l13.err")"; then bad "land --task requeued" "landed a requeued claim: '$out'"; else ok "--task on a task back in the QUEUE refuses right before the merge"; fi
if grep -q "back in the QUEUE" "$RB/l13.err"; then ok "the refusal is the claim belt's"; else bad "--task text" "$(cat "$RB/l13.err")"; fi
if [ "$(git -C "$MP" rev-parse main)" = "$m3" ] && [ "$(FB merge-lock status)" = "free" ]; then ok "nothing landed, lock released"; else bad "--task state" "$(FB merge-lock status)"; fi
FB claim seat-land >/dev/null
FACTORY_WORKER=seat-land FB merge-lock acquire claude/land-seat --task "$id_l" >/dev/null 2>&1
out="$(cd "$MW" && FACTORY_WORKER=seat-land FACTORY_LINT_DIR="$LD" FB merge-land claude/land-seat -m "merge: work-3 from claude/land-seat" --task "$id_l" 2>"$RB/l14.err")"; rc=$?
m4="$(git -C "$MP" rev-parse main)"
if [ "$rc" = "0" ] && [ "$m4" != "$m3" ] && git -C "$MP" merge-base --is-ancestor claude/land-seat main 2>/dev/null; then ok "--task on a claim this seat holds lands (work-3 + the 6a merge of main)"; else bad "land --task" "rc=$rc out='$out' err='$(cat "$RB/l14.err")'"; fi
FB done "$id_l" done >/dev/null
# THE INCIDENT BELT: a merge that answers "Already up to date." with exit 0 must FAIL loudly
sync6a; seatwork work-4
SHIM="$RB/shim"; mkdir -p "$SHIM"; REALGIT="$(command -v git)"
printf '#!/bin/bash\n# the 2026-10-21 git: a merge that answers without landing\nfor a in "$@"; do case "$a" in merge) echo "Already up to date."; exit 0 ;; esac; done\nexec %s "$@"\n' "$REALGIT" > "$SHIM/git"
chmod +x "$SHIM/git"
FB merge-lock acquire claude/land-seat >/dev/null 2>&1
if out="$(cd "$MW" && PATH="$SHIM:$PATH" FACTORY_LINT_DIR="$LD" FB merge-land claude/land-seat -m "merge: work-4 from claude/land-seat" 2>"$RB/l15.err")"; then bad "land already-up-to-date" "'Already up to date.' passed as a landing (rc 0): '$out'"; else ok "a merge answering 'Already up to date.' (exit 0) FAILS the door (rc 1), never a landing"; fi
if grep -q "main did NOT move" "$RB/l15.err" && grep -q "do not archive" "$RB/l15.err"; then ok "the failure names the unmoved main and forbids the archive"; else bad "already text" "$(cat "$RB/l15.err")"; fi
if printf '%s\n' "$out" | grep -q "^main before: $m4\$" && ! printf '%s\n' "$out" | grep -q "^merged "; then ok "the before sha was printed, no 'merged' line"; else bad "already out" "$out"; fi
if [ "$(git -C "$MP" rev-parse main)" = "$m4" ] && [ "$(FB merge-lock status)" = "free" ]; then ok "main untouched, lock released"; else bad "already state" "$(FB merge-lock status)"; fi
# THE SELF-MERGE SHAPE: the primary resolving to the branch's own worktree (the
# empty-$PRIMARY incident: git -C "" stays in the cwd, where the branch is HEAD)
SR="$RB/self-repo"; mkdir -p "$SR"
git init -q "$SR" 2>/dev/null; git -C "$SR" symbolic-ref HEAD refs/heads/main 2>/dev/null
git -C "$SR" config user.email t@t; git -C "$SR" config user.name t
git -C "$SR" commit -q --allow-empty -m init 2>/dev/null
git -C "$SR" checkout -q -b claude/self-seat 2>/dev/null
git -C "$SR" commit -q --allow-empty -m self-work 2>/dev/null
s0="$(git -C "$SR" rev-parse main)"
(cd "$SR" && FB merge-lock acquire claude/self-seat >/dev/null 2>&1)
if out="$(cd "$SR" && FACTORY_LINT_DIR="$LD" FB merge-land claude/self-seat -m "merge: self-work from claude/self-seat" 2>"$RB/l16.err")"; then bad "self-merge" "the self-merge shape exited 0: '$out'"; else ok "the self-merge shape (the primary IS the branch's worktree) FAILS loudly (rc 1)"; fi
if grep -q "SELF-MERGE shape" "$RB/l16.err" && grep -q "Already up to date" "$RB/l16.err"; then ok "the refusal names the shape and the symptom"; else bad "self-merge text" "$(cat "$RB/l16.err")"; fi
if [ "$(git -C "$SR" rev-parse main)" = "$s0" ] && [ "$(git -C "$SR" symbolic-ref --short HEAD)" = "claude/self-seat" ]; then ok "nothing merged, HEAD untouched"; else bad "self-merge state" "$(git -C "$SR" log --oneline -3 --all)"; fi
if [ "$(FB merge-lock status)" = "free" ]; then ok "the refusal released the lock"; else bad "self-merge lock" "$(FB merge-lock status)"; fi
git -C "$MP" worktree remove --force "$MW" 2>/dev/null
unset -f land seatwork sync6a
rm -rf "$RB"

echo "== the recycle gate: a consumer claim refuses an over-budget/over-age seat replica =="
# Isolated queue for this section so leftover tasks from earlier sections
# cannot interleave with the probe claims. Seam values ride per-invocation
# env (task 1787910816; the seam is test-only - see recycle_gate).
R2="$(mktemp -d)"
d2="$R2/draft.md"
printf '# recycle gate probe one\n' > "$d2"
FACTORY_TASKS_ROOT="$R2" "$F" new "$d2" >/dev/null
out="$(FACTORY_TASKS_ROOT="$R2" FACTORY_TEST_REPLICA_MB=4000 "$F" claim seat-rg 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'RECYCLE-REQUIRED (4000MB, age 0h): scripts/factory.sh replica-recycle from .*, then re-claim'; then
  ok "over-budget seam refuses with the RECYCLE-REQUIRED shape"
else
  bad "recycle refuse (budget)" "rc=$rc out='$out'"
fi
out="$(FACTORY_TASKS_ROOT="$R2" FACTORY_TEST_REPLICA_AGE_H=72 "$F" claim seat-rg 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'RECYCLE-REQUIRED (0MB, age 72h): scripts/factory.sh replica-recycle from'; then
  ok "over-age seam refuses too (the age belt)"
else
  bad "recycle refuse (age)" "rc=$rc out='$out'"
fi
n="$(count "$R2/queue" '*.md')"
if [ "$n" = "1" ]; then ok "refused claims left the queue untouched"; else bad "recycle queue intact" "$n files"; fi
out="$(FACTORY_TASKS_ROOT="$R2" FACTORY_TEST_REPLICA_MB=4000 FACTORY_FORCE=1 "$F" claim seat-rg 2>"$R2/rg1.txt")"
if grep -q "recycle gate probe one" "$out" 2>/dev/null && grep -q "recycle gate skipped (FACTORY_FORCE=1)" "$R2/rg1.txt"; then
  ok "FACTORY_FORCE=1 overrides the gate and the claim proceeds"
else
  bad "recycle force" "out='$out' err='$(cat "$R2/rg1.txt")'"
fi
printf '# recycle gate probe two\n' > "$d2"
FACTORY_TASKS_ROOT="$R2" "$F" new "$d2" >/dev/null
out="$(FACTORY_TASKS_ROOT="$R2" FACTORY_TEST_REPLICA_MB=banana "$F" claim seat-rg 2>"$R2/rg2.txt")"
if grep -q "recycle gate probe two" "$out" 2>/dev/null && grep -q "non-numeric FACTORY_TEST_REPLICA" "$R2/rg2.txt"; then
  ok "a broken measurement fails OPEN: skip note + the claim proceeds"
else
  bad "recycle fail-open" "out='$out' err='$(cat "$R2/rg2.txt")'"
fi
printf '# recycle gate probe three\n' > "$d2"
FACTORY_TASKS_ROOT="$R2" "$F" new "$d2" >/dev/null
out="$(FACTORY_TASKS_ROOT="$R2" "$F" claim seat-rg 2>/dev/null)"
if grep -q "recycle gate probe three" "$out" 2>/dev/null; then
  ok "an under-budget seat claims normally (seam MB=0)"
else
  bad "recycle pass" "out='$out'"
fi
rm -rf "$R2"

echo "== replica-recycle: the allowlisted stop acts on the calling seat's OWN worktree only =="
# A throwaway primary + linked worktree again (the guard section removed its
# own). Only the REFUSAL arms and --dry-run run here: nothing in the selftest
# ever stops a replica.
RP="$R/rr-primary"
mkdir -p "$RP"
git init -q "$RP" 2>/dev/null
git -C "$RP" symbolic-ref HEAD refs/heads/main 2>/dev/null
git -C "$RP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
git -C "$RP" worktree add -q "$R/rr-wt" -b claude/rr-seat 2>/dev/null
if (cd "$RP" && FACTORY_WORKER=seat-x "$F" replica-recycle --dry-run >/dev/null 2>"$R/rr1.txt"); then
  bad "rr primary refusal" "a seat-identified recycle in the PRIMARY was allowed"
else
  ok "the PRIMARY checkout is refused under a seat identity"
fi
if grep -q "PRIMARY checkout" "$R/rr1.txt" && grep -q "law 5" "$R/rr1.txt"; then ok "the refusal names the primary and the law"; else bad "rr primary message" "$(cat "$R/rr1.txt")"; fi
if (cd "$RP" && FACTORY_WORKER=seat-x FACTORY_FORCE=1 "$F" replica-recycle --dry-run >/dev/null 2>&1); then
  bad "rr primary force" "FACTORY_FORCE=1 let a recycle target the PRIMARY"
else
  ok "no FACTORY_FORCE override for the primary refusal"
fi
if (cd "$R/rr-wt" && env -u FACTORY_WORKER "$F" replica-recycle --dry-run >/dev/null 2>"$R/rr2.txt"); then
  bad "rr no-identity refusal" "a recycle with no pin and no FACTORY_WORKER was allowed"
else
  ok "no seat identity (no pin, no FACTORY_WORKER) is refused"
fi
if grep -q "no seat identity" "$R/rr2.txt"; then ok "the refusal names the missing identity"; else bad "rr identity message" "$(cat "$R/rr2.txt")"; fi
printf 'seat-rr\n' > "$R/rr-wt/.factory-worker"
if (cd "$R/rr-wt" && FACTORY_WORKER=seat-other "$F" replica-recycle --dry-run >/dev/null 2>"$R/rr3.txt"); then
  bad "rr drift refusal" "a FACTORY_WORKER disagreeing with the pin was allowed"
else
  ok "FACTORY_WORKER disagreeing with the seat pin is refused (cwd drift)"
fi
out="$(cd "$R/rr-wt" && env -u FACTORY_WORKER "$F" replica-recycle --dry-run 2>"$R/rr4.txt")"
case "$out" in
  "DRY-RUN $R/rr-wt (mains 0, launchers 0,"*|"DRY-RUN /private$R/rr-wt (mains 0, launchers 0,"*)
    ok "--dry-run in a pinned worktree with no replica reports mains 0 / launchers 0 and touches nothing" ;;
  *) bad "rr dry-run" "out='$out' err='$(cat "$R/rr4.txt")'" ;;
esac
if grep -q "seat 'seat-rr' (pin " "$R/rr4.txt"; then ok "the run names the pinned seat and its worktree"; else bad "rr pin echo" "$(cat "$R/rr4.txt")"; fi
if (cd "$R/rr-wt" && "$F" replica-recycle --bogus >/dev/null 2>&1); then bad "rr usage" "an unknown flag was accepted"; else ok "an unknown flag is refused (usage)"; fi
FSLEDGER="$R/fsev-ledger.tsv"; rm -f "$FSLEDGER"   # the fake FSEvents ledger (its own section was pruned in the MULTI/DEX re-sync; fleet-doctor still writes it)
echo "== fleet-doctor + heartbeat: the stall self-heal (the 2026-09-03 fleet-wide silent park) =="
# rr-wt is a pinned seat worktree (seat-rr) of the throwaway primary RP. The
# activity-dir resolution is pinned to an empty dir so only the heartbeat,
# the git index and the tree decide; a fake process carrying the session
# name plays the parked seat; ageing is `touch -t` on everything. The
# doctor's FSEvents probe (task 1791198753) stays OFF here - a real node
# watcher per pass is seconds, and a load-flaked DEAD would reach the
# remedy; the header still reads the (scratch) ledger.
mkdir -p "$R/fd-act"
export FACTORY_ACTIVITY_DIRS="$R/fd-act"
export SUITE_FSEVENTS_PROBE=0
export FSEVENTS_LEDGER="$FSLEDGER"
# The CLI login pre-check (task 1792504454) runs `claude auth status` on every
# pass: a stub answers it from a JSON file (logged in here; the login-expiry
# section below flips it), so no case ever reads the machine's real Keychain
# state - and a logged-out machine cannot fail the stall cases. The seat's
# transcript lookup is pinned to a fixture tree the same way (never the real
# ~/.claude/projects), and osascript to a recorder (no real notification).
export FACTORY_TRANSCRIPT_ROOT="$R/fd-tr"
printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n' > "$R/authfake.json"
printf '#!/bin/bash\nif [ "${1:-} ${2:-}" = "auth status" ]; then cat "%s"; exit 0; fi\nsleep 90\n' "$R/authfake.json" > "$R/claudefake.sh"; chmod +x "$R/claudefake.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$R/osanote.log" > "$R/osanote.sh"; chmod +x "$R/osanote.sh"
export FACTORY_CLAUDE_BIN="$R/claudefake.sh" FACTORY_OSASCRIPT_BIN="$R/osanote.sh"
fd_age() {  # age every liveness signal of rr-wt to 2026-01-01
  find "$R/rr-wt" -exec touch -t 202601010000 {} + 2>/dev/null
  touch -t 202601010000 "$(git -C "$R/rr-wt" rev-parse --git-dir)/index" 2>/dev/null
}
fd_iso() { date -u -r "$(stat -f %m "$1")" +%Y-%m-%dT%H:%M:%SZ; }  # the instant the doctor's note prints for a file's mtime (task 1792601787)
rm -f "$R/rr-wt/.factory-heartbeat"
(cd "$R/rr-wt" && "$F" worker >/dev/null 2>&1)
if [ -f "$R/rr-wt/.factory-heartbeat" ]; then ok "any factory command run inside a pinned worktree touches .factory-heartbeat"; else bad "heartbeat auto" "no .factory-heartbeat after 'factory.sh worker' in the pinned tree"; fi
out="$(cd "$R/rr-wt" && "$F" heartbeat 2>/dev/null)"
case "$out" in */rr-wt/.factory-heartbeat) ok "factory.sh heartbeat prints the mark it touched" ;; *) bad "heartbeat cmd" "got '$out'" ;; esac
if (cd "$RP" && "$F" heartbeat >/dev/null 2>&1); then bad "heartbeat unpinned" "a heartbeat with no pin was accepted"; else ok "heartbeat refuses where no seat pin resolves (the primary)"; fi
printf '#!/bin/bash\nsleep 90\n' > "$R/spawnfake.sh"; chmod +x "$R/spawnfake.sh"
# The fake prioritizer (task 1792506027): a sleeper whose argv carries
# --name $FP-prioritizer; TERM takes the sleep with it (no 10-min stray).
printf '#!/bin/bash\ntrap '"'"'kill $s 2>/dev/null; exit 0'"'"' TERM INT\nsleep 600 & s=$!\nwait $s\n' > "$R/prifake.sh"; chmod +x "$R/prifake.sh"
"$R/spawnfake.sh" --name $FP-executor-rr-wt >/dev/null 2>&1 &
fd_pid=$!
disown "$fd_pid" 2>/dev/null || true   # the doctor kills it below; no job-control obituary
sleep 1
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	seat-rr	idle 0m	pid $fd_pid"; then ok "a fresh heartbeat + live process reads ACTIVE (pid named)"; else bad "fd active" "$out"; fi
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	seat-rr	idle 0m	pid $fd_pid	claim none	newest write 20[0-9-]*T[0-9:]*Z from: heartbeat$"; then ok "the ACTIVE row's note names the newest-write source and its instant - newest write <instant> from: heartbeat (task 1792601787)"; else bad "fd active source" "$out"; fi
if printf '%s\n' "$out" | grep -q "^UNMANNED	prioritizer	-	board [0-9?]*m	pid none	claim -	no process named $FP-prioritizer - boot: scripts/factory.sh prioritizer-boot$"; then ok "the prioritizer line names its door (boot: scripts/factory.sh prioritizer-boot) when no process carries its name - task 1792506027"; else bad "fd prioritizer" "$out"; fi
if printf '%s\n' "$out" | grep -q "^HOSTED	"; then bad "fd hosted row local" "a HOSTED row in LOCAL mode: $out"; else ok "no HOSTED row in local mode (the prioritizer's verdict row stays local mode's, byte-identical - task 1791137234)"; fi
# From here a fake prioritizer is LIVE with a fresh board (ACTIVE), so the
# seat cases below exercise the seat path alone - since task 1792506027 an
# UNMANNED prioritizer is itself revived on every --respawn pass, which
# would add its own "would:" / DRYRUN lines to the assertions that expect
# none. Its own cases follow the roster section.
"$R/prifake.sh" --name $FP-prioritizer >/dev/null 2>&1 &
pri_pid=$!
disown "$pri_pid" 2>/dev/null || true
touch "$R/factory/index.md"
sleep 1
# Bait: one claimable consumer task, so silence counts as DEAD rather than idle.
printf -- '---\ntouches: fleet-bait\n---\n# fleet-doctor bait\n' > "$R/fd-draft.md"
bait="$("$F" new "$R/fd-draft.md")"; bait_id="$(basename "$bait" .md)"; bait_id="${bait_id#*-}"
fd_age
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^STALLED	rr-wt	seat-rr	idle [0-9]*m	pid $fd_pid	claim none	silent .* claimable task(s) queued - dead, not idle"; then ok "silent past the threshold with claimable work + a live process = STALLED (dead, not idle)"; else bad "fd stalled" "$out"; fi
if printf '%s\n' "$out" | grep -q "^STALLED	rr-wt	seat-rr	idle [0-9]*m	pid $fd_pid	claim none	silent .* claimable task(s) queued - dead, not idle; newest write $(fd_iso "$R/rr-wt/.factory-heartbeat") from: heartbeat$"; then ok "the STALLED row names the last source seen with its instant AFTER today's words (the aged heartbeat - a tie keeps the first source in the doctor's order)"; else bad "fd stalled source" "$out"; fi
if printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-STALLED 1 stalled, 0 unmanned of 1 seats (report-only"; then ok "the summary line counts it and names the report-only default"; else bad "fd summary" "$(printf '%s\n' "$out" | tail -1)"; fi
if printf '%s\n' "$out" | head -1 | grep -q "mode report-only"; then ok "report-only is the default mode (no respawn without opt-in)"; else bad "fd mode" "$(printf '%s\n' "$out" | head -1)"; fi
# The guard-log source (task 1792598009): a tee'd deploy-all wave writes
# NOTHING but lib.sh suite_output_guard's per-run log at the TOP of
# <seat>/.icp/cache for its whole run (executor-watch's fourth source, task
# 1792595837), and the doctor's tree walk prunes .icp wholesale - so a seat
# in a wave longer than the bar read STALLED, and --respawn killed its live
# fleet run from under it. A fresh guard log alone = ACTIVE; the same file
# aged past the bar = STALLED again; a fresh replica tick under networks/
# alone never counts (the walk stays pruned; the guard's naming at the top
# level only). fd_age ages the guard log with everything else.
fd_glog="$R/rr-wt/.icp/cache/deploy-all.20260101-000000.1.log"
mkdir -p "$R/rr-wt/.icp/cache/networks/local"
fd_age
touch "$fd_glog"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	seat-rr	idle 0m	pid $fd_pid"; then ok "a fresh suite_output_guard log at the top of the seat's .icp/cache alone reads ACTIVE (the tee'd deploy-all wave - task 1792598009)"; else bad "fd guard log active" "$out"; fi
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	seat-rr	idle 0m	pid $fd_pid	claim none	newest write 20[0-9-]*T[0-9:]*Z from: guard log .*/rr-wt/.icp/cache/deploy-all.20260101-000000.1.log$"; then ok "the ACTIVE row names the guard log BY FILE (newest write <instant> from: guard log <...>/rr-wt/.icp/cache/deploy-all.20260101-000000.1.log)"; else bad "fd guard log source" "$out"; fi
fd_age
touch -t 202601010001 "$fd_glog"   # a minute past the aged tree: still past the bar, still the newest source (the executor-watch case's shape)
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^STALLED	rr-wt	seat-rr	idle [0-9]*m	pid $fd_pid	claim none	silent .* claimable task(s) queued - dead, not idle"; then ok "the same guard log aged past the bar reads STALLED again"; else bad "fd guard log aged" "$out"; fi
if printf '%s\n' "$out" | grep -q "^STALLED	rr-wt	seat-rr	idle [0-9]*m	pid $fd_pid	claim none	silent .* claimable task(s) queued - dead, not idle; newest write $(fd_iso "$fd_glog") from: guard log .*/rr-wt/.icp/cache/deploy-all.20260101-000000.1.log$"; then ok "the STALLED row names the aged guard log as the last source seen, with its instant (a minute past the rest - a false STALLED is diagnosable from the log alone)"; else bad "fd stalled guard source" "$out"; fi
fd_age
rm -f "$fd_glog"
touch "$R/rr-wt/.icp/cache/networks/local/tick"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^STALLED	rr-wt	seat-rr	idle [0-9]*m	pid $fd_pid	claim none	silent .* claimable task(s) queued - dead, not idle"; then ok "a fresh replica tick under .icp/cache/networks/ alone stays STALLED (the .icp walk stays pruned; only the guard's naming at the top level counts)"; else bad "fd networks tick" "$out"; fi
rm -rf "$R/rr-wt/.icp"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "would: write takeover handoff .*/handoff/rr-wt.md; kill parked pid(s) $fd_pid (TERM then KILL); spawn-successor rr-wt"; then ok "--respawn --dry-run prints the revive plan (handoff, kill the named pid, spawn)"; else bad "fd dry plan" "$out"; fi
if [ ! -f "$R/handoff/rr-wt.md" ] && kill -0 "$fd_pid" 2>/dev/null; then ok "the dry run touched nothing (no handoff written, process still alive)"; else bad "fd dry inert" "handoff $([ -f "$R/handoff/rr-wt.md" ] && echo written || echo absent), process $(kill -0 "$fd_pid" 2>/dev/null && echo alive || echo dead)"; fi
# With a claim held the stall is the executor-loss shape: the triage note rides the handoff.
(cd "$RP" && "$F" claim --operator --id "$bait_id" seat-rr >/dev/null 2>&1)
fd_age
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^STALLED	rr-wt	seat-rr	.*	claim $bait_id	silent .* claim $bait_id held - dead, not idle"; then ok "a held claim makes silence STALLED even with nothing else queued"; else bad "fd stalled claim" "$out"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 FACTORY_FLEET_RESPAWN=1 "$F" fleet-doctor 2>&1)"
if printf '%s\n' "$out" | head -1 | grep -q "mode respawn"; then ok "FACTORY_FLEET_RESPAWN=1 is the env form of --respawn"; else bad "fd env respawn" "$(printf '%s\n' "$out" | head -1)"; fi
if [ -f "$R/handoff/rr-wt.md" ] && grep -q "^cd .*/rr-wt && claude .*--name '$FP-executor-rr-wt'" "$R/handoff/rr-wt.md" && grep -q "You INHERIT claim $bait_id (tasks/claimed/seat-rr/" "$R/handoff/rr-wt.md" && grep -q "COMPLETE .* PARTIAL .* ABSENT" "$R/handoff/rr-wt.md"; then ok "the respawn wrote a takeover handoff carrying the boot line + the COMPLETE/PARTIAL/ABSENT triage note for the held claim"; else bad "fd handoff" "$(cat "$R/handoff/rr-wt.md" 2>/dev/null)"; fi
sleep 1
if kill -0 "$fd_pid" 2>/dev/null; then bad "fd kill" "the parked process $fd_pid survived the respawn"; else ok "the parked process carrying the seat's session name was killed"; fi
if printf '%s\n' "$out" | grep -q "DRYRUN session name: $FP-executor-rr-wt" && printf '%s\n' "$out" | grep -q "revived rr-wt"; then ok "then spawn-successor booted the successor from that handoff (dry-run program shown)"; else bad "fd spawn" "$out"; fi
# UNMANNED: no process at all, handoff pending from the respawn above.
fd_age
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^UNMANNED	rr-wt	seat-rr	.*no process named $FP-executor-rr-wt; handoff-pending"; then ok "no process = UNMANNED, and a pending handoff file is named"; else bad "fd unmanned" "$out"; fi
echo "== fleet-doctor: a timed-out respawn is SPAWN PENDING - reported, never respawned again (task 1789588684) =="
# The doctor's own respawn hits the -1712 fake: the seat gets a stamp and the
# next passes report it instead of queueing more boots.
printf '#!/bin/bash\necho "44:670: execution error: Terminal got an error: AppleEvent timed out. (-1712)" >&2\nexit 1\n' > "$R/osafake.sh"; chmod +x "$R/osafake.sh"
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_OSASCRIPT_BIN="$R/osafake.sh" FACTORY_CLAUDE_BIN="$R/claudefake.sh" FACTORY_SPAWN_VERIFY_SECS=1 "$F" fleet-doctor --respawn 2>&1)"
if printf '%s\n' "$out" | grep -q "respawn of rr-wt PENDING (AppleEvent timed out - Terminal may still run it)" && [ -f "$R/factory/spawn-pending/rr-wt" ]; then ok "a respawn whose AppleEvent timed out reports PENDING and stamps the seat (the pass goes on)"; else bad "fd respawn pending" "$out / $(ls "$R/factory/spawn-pending/" 2>&1)"; fi
fd_age
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^UNMANNED	rr-wt	seat-rr	.*spawn pending since 20[0-9-]*T[0-9:]*Z, Terminal AppleEvents timing out - check Terminal: a modal, a hung tab, or Automation permission"; then ok "the seat reads UNMANNED (spawn pending since <instant>, Terminal AppleEvents timing out - check Terminal ...)"; else bad "fd pending line" "$out"; fi
if ! printf '%s\n' "$out" | grep -q "would:" && printf '%s\n' "$out" | grep -q "spawn pending since .* - no respawn"; then ok "--respawn plans no revive while the stamp stands (one line of forensics, not a queue of boots)"; else bad "fd pending no respawn" "$out"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 FACTORY_FLEET_RESPAWN=1 "$F" fleet-doctor 2>&1)"
if ! printf '%s\n' "$out" | grep -q "DRYRUN session name" && printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-STALLED 0 stalled, 1 unmanned"; then ok "a live respawn pass spawns nothing for a pending seat and still counts it unmanned"; else bad "fd pending live pass" "$out"; fi
echo "== worker-pin / claim: DUPLICATE-SESSION - the extra boot exits at its first command (task 1789588684) =="
# The timed-out boot finally runs beside a session that already holds the
# seat: a like-named process OLDER than the caller is the refusal. The
# caller's name is pinned (FACTORY_SESSION_NAME) because this selftest may
# itself run inside a named seat, whose --name the gate would read instead.
"$R/spawnfake.sh" --name $FP-executor-rr-wt >/dev/null 2>&1 &
fd_pid=$!
sleep 1
if out="$(cd "$R/rr-wt" && FACTORY_SESSION_NAME=$FP-executor-rr-wt FACTORY_DUP_GRACE_S=0 "$F" worker-pin seat-rr 2>&1)"; then
  bad "dup pin" "worker-pin proceeded beside an older like-named process: $out"
elif printf '%s' "$out" | grep -q "DUPLICATE-SESSION: $fd_pid already runs this seat - exit now"; then
  ok "worker-pin refuses DUPLICATE-SESSION naming the older pid"
else
  bad "dup pin msg" "'$out'"
fi
if out="$(cd "$R/rr-wt" && FACTORY_SESSION_NAME=$FP-executor-rr-wt FACTORY_DUP_GRACE_S=0 "$F" claim seat-rr 2>&1)"; then
  bad "dup claim" "claim proceeded beside an older like-named process: $out"
elif printf '%s' "$out" | grep -q "DUPLICATE-SESSION: $fd_pid already runs this seat - exit now"; then
  ok "claim carries the same gate (an extra boot never claims under the shared identity)"
else
  bad "dup claim msg" "'$out'"
fi
if (cd "$R/rr-wt" && FACTORY_FORCE=1 FACTORY_SESSION_NAME=$FP-executor-rr-wt FACTORY_DUP_GRACE_S=0 "$F" worker-pin seat-rr >/dev/null 2>&1); then ok "FACTORY_FORCE=1 overrides the duplicate gate"; else bad "dup pin force" "refused under FACTORY_FORCE=1"; fi
if (cd "$R/rr-wt" && FACTORY_SESSION_NAME=otherproj-executor-rr-wt FACTORY_DUP_GRACE_S=0 "$F" worker-pin seat-rr >/dev/null 2>&1); then ok "the gate is bound to the session NAME (another prefix's process is not this seat)"; else bad "dup pin bound" "refused for a differently-prefixed process"; fi
# A manned seat spends its stamp on the doctor's pass (the pending boot arrived).
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if [ ! -f "$R/factory/spawn-pending/rr-wt" ] && printf '%s\n' "$out" | grep -q "	rr-wt	seat-rr	.*pid $fd_pid"; then ok "the doctor clears the stamp once the seat's process exists"; else bad "fd stamp spent" "$out / $(ls "$R/factory/spawn-pending/" 2>&1)"; fi
kill "$fd_pid" 2>/dev/null || true; wait "$fd_pid" 2>/dev/null || true
sleep 1
if (cd "$R/rr-wt" && FACTORY_SESSION_NAME=$FP-executor-rr-wt FACTORY_DUP_GRACE_S=0 "$F" worker-pin seat-rr >/dev/null 2>&1); then ok "with the older process gone worker-pin proceeds (the gate is live-state)"; else bad "dup pin clear" "still refused"; fi
rm -f "$R/osafake.sh"
# QUIET: silent, but nothing claimable and no claim - undecidable, never a respawn.
(cd "$RP" && "$F" done "$bait_id" abandoned "selftest" >/dev/null 2>&1)
mv "$R/queue" "$R/queue.aside"; mkdir -p "$R/queue"
"$R/spawnfake.sh" --name $FP-executor-rr-wt >/dev/null 2>&1 &
fd_pid=$!
sleep 1
fd_age
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^QUIET	rr-wt	seat-rr	.*nothing claimable" && ! printf '%s\n' "$out" | grep -q "would:"; then ok "silent with nothing claimable = QUIET, and even --respawn leaves it alone"; else bad "fd quiet" "$out"; fi
if printf '%s\n' "$out" | grep -q "^QUIET	rr-wt	seat-rr	idle [0-9]*m	pid $fd_pid	claim none	silent [0-9]*m, nothing claimable - healthy idle or parked, undecidable until work arrives; newest write $(fd_iso "$R/rr-wt/.factory-heartbeat") from: heartbeat$"; then ok "the QUIET row names the last source seen with its instant after today's words (the aged heartbeat)"; else bad "fd quiet source" "$out"; fi
if printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-OK seats 1"; then ok "a fleet with no STALLED/UNMANNED seat summarizes FLEET-OK"; else bad "fd ok summary" "$(printf '%s\n' "$out" | tail -1)"; fi
rm -rf "$R/queue"; mv "$R/queue.aside" "$R/queue"
kill "$fd_pid" 2>/dev/null || true; wait "$fd_pid" 2>/dev/null || true
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --launchd-plist 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "<string>$FP.factory-fleet-doctor</string>" && printf '%s\n' "$out" | grep -q "<string>fleet-doctor</string>" && printf '%s\n' "$out" | grep -q "<integer>900</integer>"; then ok "--launchd-plist prints the 15-min operator job with the project-prefixed label"; else bad "fd plist" "$out"; fi
if (cd "$RP" && "$F" fleet-doctor --bogus >/dev/null 2>&1); then bad "fd usage" "an unknown flag was accepted"; else ok "an unknown flag is refused (usage)"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --dry-run 2>/dev/null)"
if printf '%s\n' "$out" | sed -n 2p | grep -q "^fsevents restarts: 0 (none on record) - unattended fseventsd restarts on record (ledger $FSLEDGER)$"; then ok "the fleet-doctor header's second line reads the ledger: fsevents restarts: N (last <when>, trigger) - dry-run included"; else bad "fd fsevents header" "$(printf '%s\n' "$out" | sed -n 1,3p)"; fi
if (cd "$RP" && "$F" fleet-doctor --stale-min abc >/dev/null 2>&1); then bad "fd stale arg" "a non-numeric --stale-min was accepted"; else ok "--stale-min must be minutes"; fi
echo "== fleet-doctor: CLI login expiry - FLEET-LOGGED-OUT, the LOGGED-OUT verdict, replace-after-login (task 1792504454) =="
# The 17.5-hour dead fleet of 2026-10-19/20: every seat parked alive on the
# CLI's synthetic "Login expired <middle dot> Please run /login" entry, the
# doctor read ACTIVE, then respawned successors that died on turn one. Here
# the claude stub answers `auth status` from authfake.json (flipped per case);
# the seat's transcript is a fixture under FACTORY_TRANSCRIPT_ROOT whose tail
# has the real file's shape (the message, then the bookkeeping lines - the
# middle dot is written as its UTF-8 bytes by printf, this file staying
# ASCII); the fake process carries the session name; osascript records.
export FACTORY_FLEET_LOG="$R/fleet.log"
fd_wt="$(git -C "$RP" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/rr-wt$' | head -1 || true)"
fd_tdir="$R/fd-tr/$(printf '%s' "$fd_wt" | sed 's#[/.]#-#g')"
fd_sid="11111111-2222-3333-4444-555555555555"
fd_transcript() {  # fd_transcript <dir> <session-name|-> <kind: expired|past|quote> [file]: a transcript fixture whose newest conversation entry is of that kind
  local d="$1" sname="$2" kind="$3" f="${4:-$fd_sid.jsonl}"
  mkdir -p "$d"
  {
    printf '{"parentUuid":null,"isSidechain":false,"type":"user","uuid":"u1","timestamp":"2026-10-20T12:59:30.000Z","message":{"role":"user","content":"Read .claude/skills/mdex-software-factory/SKILL.md. You are a TaskConsumer in executor mode. Work the queue continuously."},"cwd":"%s","sessionId":"%s","version":"2.1.257"}\n' "$fd_wt" "$fd_sid"
    case "$kind" in
      quote)
        # Prose quoting the text (a seat reporting the verdict): inside a JSON
        # string every quote is escaped, so no key of the error entry can
        # appear - the matcher must not bite.
        printf '{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-10-20T13:00:00.476Z","message":{"id":"m1","model":"claude-fable-5-1","role":"assistant","type":"message","content":[{"type":"text","text":"The doctor matches \\"isApiErrorMessage\\":true and the text Login expired \302\267 Please run /login - LOGGED-OUT verdict reported."}]},"sessionId":"%s","version":"2.1.257"}\n' "$fd_sid"
        ;;
      *)
        printf '{"parentUuid":"u1","isSidechain":false,"type":"assistant","uuid":"a1","timestamp":"2026-10-20T13:00:00.476Z","message":{"id":"m1","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","type":"message","content":[{"type":"text","text":"Login expired \302\267 Please run /login"}]},"error":"authentication_failed","isApiErrorMessage":true,"sessionId":"%s","version":"2.1.257"}\n' "$fd_sid"
        ;;
    esac
    if [ "$kind" = "past" ]; then
      printf '{"parentUuid":"a1","isSidechain":false,"type":"user","uuid":"u2","timestamp":"2026-10-20T13:50:00.000Z","message":{"role":"user","content":"logged in again - continue"},"sessionId":"%s","version":"2.1.257"}\n' "$fd_sid"
      printf '{"parentUuid":"u2","isSidechain":false,"type":"assistant","uuid":"a2","timestamp":"2026-10-20T13:50:05.000Z","message":{"id":"m2","model":"claude-fable-5-1","role":"assistant","type":"message","content":[{"type":"text","text":"Resuming."}]},"sessionId":"%s","version":"2.1.257"}\n' "$fd_sid"
    fi
    # The bookkeeping tail of a real transcript: the message is never the last LINE.
    printf '{"parentUuid":"a1","isSidechain":false,"type":"system","subtype":"turn_duration","durationMs":29,"timestamp":"2026-10-20T13:00:00.500Z","sessionId":"%s"}\n' "$fd_sid"
    printf '{"type":"last-prompt","lastPrompt":"Read .claude/skills/mdex-software-factory/SKILL.md.","sessionId":"%s"}\n' "$fd_sid"
    if [ "$sname" != "-" ]; then
      printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$sname" "$fd_sid"
      printf '{"type":"agent-name","agentName":"%s","sessionId":"%s"}\n' "$sname" "$fd_sid"
    fi
    printf '{"type":"cost-state","sessionId":"%s","totalCostUSD":0,"modelUsage":{}}\n' "$fd_sid"
  } > "$d/$f"
}
"$R/spawnfake.sh" --name $FP-executor-rr-wt >/dev/null 2>&1 &
fd_pid=$!
disown "$fd_pid" 2>/dev/null || true
sleep 1
rm -f "$R/osanote.log" "$R/factory/fleet-logged-out" "$R/fleet.log" "$R/handoff/rr-wt.md"   # the stall cases above left their takeover token
(cd "$R/rr-wt" && "$F" heartbeat >/dev/null 2>&1)
printf '{\n  "loggedIn": false,\n  "authMethod": "claude.ai"\n}\n' > "$R/authfake.json"
fd_transcript "$fd_tdir" $FP-executor-rr-wt expired
# A. logged out + the seat parked on the message: FLEET-LOGGED-OUT, the LOGGED-OUT row, zero spawns planned.
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^LOGGED-OUT	rr-wt	seat-rr	idle [0-9?]*m	pid $fd_pid	claim none	parked on an expired CLI login - its last transcript entry is the CLI's \"Login expired - Please run /login\" message ($fd_sid.jsonl at 2026-10-20T13:00:00.476Z); FLEET-LOGGED-OUT: one login covers every seat and the prioritizer"; then ok "a live process whose own transcript ends on the login-expired entry reads LOGGED-OUT (file + instant named, the remedy on the line) - it had read ACTIVE"; else bad "lo row" "$out"; fi
if printf '%s\n' "$out" | grep -q "FLEET-LOGGED-OUT (since this pass): $R/claudefake.sh auth status reads loggedIn false" && printf '%s\n' "$out" | grep -q 'run `claude auth login` as the seat user, or /login inside any one seat window (the desktop app login is a separate Keychain item and never carries over)'; then ok "the loud FLEET-LOGGED-OUT line names the auth verdict and the one-login remedy (desktop login does not count)"; else bad "lo loud" "$out"; fi
if printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-LOGGED-OUT 1 logged out, 0 stalled, 0 unmanned of 1 seats - every respawn held this pass; one login covers every seat"; then ok "the summary (last line) is FLEET-LOGGED-OUT n logged out ... every respawn held"; else bad "lo summary" "$(printf '%s\n' "$out" | tail -1)"; fi
if ! printf '%s\n' "$out" | grep -q "would:" && printf '%s\n' "$out" | grep -q "held: FLEET-LOGGED-OUT - no respawn of rr-wt this pass (a successor booted logged out dies on its first turn)"; then ok "--respawn --dry-run plans 0 spawns while logged out (held, with the reason)"; else bad "lo held" "$out"; fi
if printf '%s\n' "$out" | grep -q "^cli login: LOGGED OUT (dry-run: the stamp .*/fleet-logged-out and the notification are skipped)" && [ ! -f "$R/factory/fleet-logged-out" ] && [ ! -f "$R/osanote.log" ] && [ ! -f "$R/fleet.log" ]; then ok "the dry run stamps nothing, logs nothing and notifies nobody"; else bad "lo dry inert" "$(printf '%s\n' "$out" | grep '^cli login'); stamp $(ls "$R/factory/fleet-logged-out" 2>&1); osa $(cat "$R/osanote.log" 2>&1); log $(cat "$R/fleet.log" 2>&1)"; fi
# B. a live report-only pass: the stamp, the notification, the fleet log, the board line; the second pass stays quiet.
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>&1)"
if [ -f "$R/factory/fleet-logged-out" ] && grep -q "^since: 20" "$R/factory/fleet-logged-out" && printf '%s\n' "$out" | grep -q "^cli login: LOGGED OUT since 20.* - stamp .*/fleet-logged-out written, notification sent"; then ok "a live pass stamps tasks/factory/fleet-logged-out (since <instant>) and sends the notification"; else bad "lo stamp" "$out / $(cat "$R/factory/fleet-logged-out" 2>&1)"; fi
if [ "$(grep -c 'FLEET-LOGGED-OUT: the seat CLI login expired' "$R/osanote.log" 2>/dev/null)" = "1" ] && grep -q 'with title "Open SaaS fleet doctor"' "$R/osanote.log"; then ok "exactly one macOS notification, titled as the fsevents one"; else bad "lo notify" "$(cat "$R/osanote.log" 2>&1)"; fi
if [ "$(grep -c 'FLEET-LOGGED-OUT (since this pass)' "$R/fleet.log" 2>/dev/null)" = "1" ]; then ok "the fleet log carries the loud line of the live pass (not the dry run's)"; else bad "lo log" "$(cat "$R/fleet.log" 2>&1)"; fi
since1="$(sed -n 's/^since: //p' "$R/factory/fleet-logged-out")"
sleep 1
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>&1)"
if [ "$(sed -n 's/^since: //p' "$R/factory/fleet-logged-out")" = "$since1" ] && [ "$(grep -c 'FLEET-LOGGED-OUT' "$R/osanote.log")" = "1" ] && printf '%s\n' "$out" | grep -q "stamp .*/fleet-logged-out refreshed (notified within the hour)" && grep -q "FLEET-LOGGED-OUT (since $since1)" "$R/fleet.log"; then ok "a second pass keeps the first instant, logs it, and does not notify again within the hour"; else bad "lo second pass" "$out / $(cat "$R/osanote.log" 2>&1)"; fi
"$F" index >/dev/null
if grep -q "^- CLI login: LOGGED OUT since $since1 (FLEET-LOGGED-OUT: every seat and the prioritizer die on their next turn, every respawn is held) - one login covers every seat" "$R/factory/index.md"; then ok "the board carries the CLI login line from the stamp (the fsevents pattern)"; else bad "lo board" "$(grep -A1 'CLI login' "$R/factory/index.md" || echo missing)"; fi
# C. a STALLED seat is held too while the fleet is logged out.
printf -- '---\ntouches: fleet-bait-2\n---\n# fleet-doctor login bait\n' > "$R/fd-draft2.md"
bait2="$("$F" new "$R/fd-draft2.md")"
fd_transcript "$fd_tdir" $FP-executor-rr-wt past   # this seat is past the login ...
fd_age                                                  # ... but silent past the bar with claimable work: STALLED
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^STALLED	rr-wt	" && ! printf '%s\n' "$out" | grep -q "would:" && printf '%s\n' "$out" | grep -q "held: FLEET-LOGGED-OUT - no respawn of rr-wt"; then ok "a STALLED seat is held too while the fleet is logged out (its successor would die on turn one)"; else bad "lo stalled held" "$out"; fi
# D. the login is back: the parked seat is replaced (plan, then the live clearance).
printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n' > "$R/authfake.json"
(cd "$R/rr-wt" && "$F" heartbeat >/dev/null 2>&1)
fd_transcript "$fd_tdir" $FP-executor-rr-wt expired
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^LOGGED-OUT	rr-wt	seat-rr	.*pid $fd_pid	.*the login is back but a parked session never re-reads it: replaced under --respawn"; then ok "once auth status reads logged in, the parked seat's row says it is replaced under --respawn"; else bad "lo back row" "$out"; fi
if [ "$(printf '%s\n' "$out" | grep -c 'would:')" = "1" ] && printf '%s\n' "$out" | grep -q "would: write takeover handoff .*/handoff/rr-wt.md; kill parked pid(s) $fd_pid (TERM then KILL); spawn-successor rr-wt (replacing the logged-out session: the login is back)"; then ok "--respawn --dry-run plans the replacement for that seat only: kill parked pid(s) ...; spawn-successor rr-wt"; else bad "lo back plan" "$out"; fi
if printf '%s\n' "$out" | grep -q "^cli login: logged in again (FLEET-LOGGED-OUT stood since $since1; dry-run: the stamp .* stays)" && [ -f "$R/factory/fleet-logged-out" ]; then ok "the dry run reports the login is back and leaves the stamp"; else bad "lo back dry" "$(printf '%s\n' "$out" | grep '^cli login')"; fi
if printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-STALLED 0 stalled, 0 unmanned, 1 logged-out (parked on the expired CLI login: replaced under --respawn once auth status reads logged in) of 1 seats$"; then ok "the summary counts the parked seat as logged-out (never FLEET-OK with one parked)"; else bad "lo back summary" "$(printf '%s\n' "$out" | tail -1)"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>&1)"
if [ ! -f "$R/factory/fleet-logged-out" ] && printf '%s\n' "$out" | grep -q "FLEET-LOGGED-OUT cleared: .* auth status reads logged in again (stood since $since1)" && grep -q "FLEET-LOGGED-OUT cleared" "$R/fleet.log"; then ok "the first live logged-in pass clears the stamp and logs the clearance"; else bad "lo clear" "$out"; fi
"$F" index >/dev/null
if grep -q "^- CLI login: no logged-out sighting standing" "$R/factory/index.md"; then ok "the board line reads clear again"; else bad "lo board clear" "$(grep 'CLI login' "$R/factory/index.md")"; fi
if printf '%s\n' "$out" | grep -q "^LOGGED-OUT	rr-wt	.*(report-only now: kill pid $fd_pid and factory.sh spawn-successor rr-wt by hand)"; then ok "report-only mode names the hand remedy for the parked seat"; else bad "lo report-only" "$out"; fi
# E-H. what is NOT logged out: past the login, prose quoting the text, a predecessor's transcript; the newest-file fallback.
fd_transcript "$fd_tdir" $FP-executor-rr-wt past
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	" && ! printf '%s\n' "$out" | grep -q "LOGGED-OUT"; then ok "a seat whose transcript moved past the login (a later user turn) is KEPT: ACTIVE, no plan"; else bad "lo past" "$out"; fi
fd_transcript "$fd_tdir" $FP-executor-rr-wt quote
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	" && ! printf '%s\n' "$out" | grep -q "LOGGED-OUT"; then ok "assistant prose QUOTING the text (no isApiErrorMessage key) never matches: a seat reporting the verdict is not logged out"; else bad "lo quote" "$out"; fi
fd_transcript "$fd_tdir" $FP-executor-rr-wt expired
touch -t 202601010000 "$fd_tdir/$fd_sid.jsonl"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	" && ! printf '%s\n' "$out" | grep -q "LOGGED-OUT"; then ok "a transcript OLDER than the live process is a predecessor's and never judges this session (a fresh successor is not re-killed)"; else bad "lo old transcript" "$out"; fi
rm -f "$fd_tdir/$fd_sid.jsonl"
fd_transcript "$fd_tdir" - expired 22222222-2222-3333-4444-555555555555.jsonl   # no agent-name line: the newest-file fallback
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^LOGGED-OUT	rr-wt	.*(22222222-2222-3333-4444-555555555555.jsonl at 2026-10-20T13:00:00.476Z)"; then ok "with no agent-name line the seat's newest transcript is read (the fallback)"; else bad "lo noname" "$out"; fi
# I. the live replacement: handoff naming the reason, the parked pid killed, the successor spawned.
rm -f "$R/handoff/rr-wt.md"
fd_transcript "$fd_tdir" $FP-executor-rr-wt expired
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 FACTORY_FLEET_RESPAWN=1 "$F" fleet-doctor 2>&1)"
if [ -f "$R/handoff/rr-wt.md" ] && grep -q "fleet-doctor REPLACED this seat: its session was parked on an expired CLI login" "$R/handoff/rr-wt.md" && grep -q "^cd .*/rr-wt && claude .*--name '$FP-executor-rr-wt'" "$R/handoff/rr-wt.md"; then ok "the live replacement writes a takeover handoff naming the expired-login reason"; else bad "lo handoff" "$(cat "$R/handoff/rr-wt.md" 2>&1)"; fi
sleep 1
if ! kill -0 "$fd_pid" 2>/dev/null && printf '%s\n' "$out" | grep -q "killing parked $FP-executor-rr-wt pid(s) $fd_pid (parked on the expired login; the login is back)" && printf '%s\n' "$out" | grep -q "revived rr-wt"; then ok "the parked process was killed by pid (TERM then KILL) and the successor spawned (dry-run program shown)"; else bad "lo replace" "$out / alive=$(kill -0 "$fd_pid" 2>/dev/null && echo yes || echo no)"; fi
# J. the prioritizer: its transcript sits in the PRIMARY's dir beside a NEWER operator session - the one naming its session counts; the boot line still prints; never auto-booted.
fd_pdir="$R/fd-tr/$(cd "$RP" && pwd -P | sed 's#[/.]#-#g')"
fd_transcript "$fd_pdir" $FP-prioritizer expired 33333333-3333-3333-4444-555555555555.jsonl
# The row's pid is the stall section's live fake prioritizer (pri_pid, a 600 s
# sleeper whose argv carries the name) - a second like-named fake would make
# the row list two pids; its own cases after the roster section still expect
# it alive, so nothing here kills it (every pass below is dry or report-only).
if kill -0 "$pri_pid" 2>/dev/null; then pp_pid="$pri_pid"; pp_own=0; else "$R/prifake.sh" --name $FP-prioritizer >/dev/null 2>&1 & pp_pid=$!; pp_own=1; disown "$pp_pid" 2>/dev/null || true; fi
sleep 1
touch "$fd_pdir/33333333-3333-3333-4444-555555555555.jsonl"   # at least as new as the process
fd_transcript "$fd_pdir" - past 44444444-4444-3333-4444-555555555555.jsonl   # the newer operator session: not the prioritizer's
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^LOGGED-OUT	prioritizer	-	board [0-9?]*m	pid $pp_pid	claim -	parked on an expired CLI login - .*(33333333-3333-3333-4444-555555555555.jsonl at 2026-10-20T13:00:00.476Z); the login is back but a parked session never re-reads it: replaced under --respawn$"; then ok "the prioritizer row reads LOGGED-OUT from ITS transcript (the one naming its session, not the newer operator one)"; else bad "lo prioritizer" "$out"; fi
if printf '%s\n' "$out" | grep -q "would: kill parked pid(s) $pp_pid (TERM then KILL); prioritizer-boot (replacing the logged-out session: the login is back)$"; then ok "--respawn --dry-run plans its replacement like a seat's: kill the parked pid, then prioritizer-boot (task 1792506027's door)"; else bad "lo prio plan" "$out"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>&1)"
if printf '%s\n' "$out" | grep -q "^LOGGED-OUT	prioritizer	-	.*(report-only now: kill pid $pp_pid and scripts/factory.sh prioritizer-boot by hand)$"; then ok "report-only names the prioritizer's hand remedy (the door, no paste line)"; else bad "lo prio report-only" "$out"; fi
printf '{\n  "loggedIn": false,\n  "authMethod": "claude.ai"\n}\n' > "$R/authfake.json"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^LOGGED-OUT	prioritizer	-	.*FLEET-LOGGED-OUT: one login covers every seat and the prioritizer" && printf '%s\n' "$out" | grep -q "held: FLEET-LOGGED-OUT - no respawn of the prioritizer this pass" && ! printf '%s\n' "$out" | grep -q "would:"; then ok "while the fleet is logged out the prioritizer's revive is held like a seat's"; else bad "lo prio held" "$out"; fi
printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n' > "$R/authfake.json"
rm -f "$R/factory/fleet-logged-out"
if [ "$pp_own" = 1 ]; then kill "$pp_pid" 2>/dev/null || true; wait "$pp_pid" 2>/dev/null || true; fi
rm -rf "$fd_pdir"
# K-L. an unreadable auth status never holds the fleet and never replaces; a hung one is killed by pid.
printf 'not json at all\n' > "$R/authfake.json"
"$R/spawnfake.sh" --name $FP-executor-rr-wt >/dev/null 2>&1 &
fd_pid=$!
disown "$fd_pid" 2>/dev/null || true
sleep 1
(cd "$R/rr-wt" && "$F" heartbeat >/dev/null 2>&1)
fd_transcript "$fd_tdir" $FP-executor-rr-wt expired
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^cli login: unknown: .*claudefake.sh auth status printed no loggedIn field - the verdicts judge as logged in" && printf '%s\n' "$out" | grep -q "^LOGGED-OUT	rr-wt	.*auth status unreadable this pass - report-only" && ! printf '%s\n' "$out" | grep -q "would:"; then ok "an unreadable auth status is reported, never holds the fleet, and never replaces a parked seat (report-only)"; else bad "lo unknown" "$out"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_CLAUDE_BIN="$R/spawnfake.sh" FACTORY_AUTH_STATUS_SECS=2 "$F" fleet-doctor --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^cli login: unknown: .*spawnfake.sh auth status gave no answer in 2s (its own process tree killed by pid)"; then ok "a hung auth status is killed by pid after the bar and reads unknown"; else bad "lo hang" "$(printf '%s\n' "$out" | grep '^cli login')"; fi
kill "$fd_pid" 2>/dev/null || true; wait "$fd_pid" 2>/dev/null || true
printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n' > "$R/authfake.json"
rm -rf "$R/fd-tr" "$R/handoff/rr-wt.md" "$bait2" "$R/osanote.log"
echo "== the fleet roster: ORPHANED + FLEET-DEGRADED, seat-recreate, seat-retire (task 1788956135: vanished worktrees) =="
# rr-wt vanishes under a LIVE named process (the seat-14 shape, 2026-09-08).
# Everything runs against the throwaway primary RP; the fake process is a
# sleep whose argv carries the session name; the fleet log is redirected.
export FACTORY_FLEET_LOG="$R/fleet.log"
out="$(cd "$R/rr-wt" && "$F" worker-pin seat-rr 2>/dev/null)"
if grep -q "^rr-wt	.*	seat-rr	claude/rr-seat	20" "$R/factory/fleet-roster" 2>/dev/null; then ok "worker-pin writes the seat's roster row (seat, worktree, worker, branch, registered)"; else bad "roster row" "$(cat "$R/factory/fleet-roster" 2>/dev/null)"; fi
if [ "$(cat "$RP/.git/worktrees/rr-wt/factory-seat" 2>/dev/null)" = "rr-wt" ]; then ok "worker-pin stamps the git admin tripwire .git/worktrees/<seat>/factory-seat"; else bad "tripwire" "$(ls "$RP/.git/worktrees/" 2>/dev/null)"; fi
out="$(cd "$RP" && "$F" seat-roster 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^rr-wt	" && ! printf '%s\n' "$out" | grep -q ORPHANED; then ok "seat-roster lists the seat, not orphaned"; else bad "seat-roster" "$out"; fi
"$R/spawnfake.sh" --name $FP-executor-rr-wt >/dev/null 2>&1 &
fd_pid=$!
disown "$fd_pid" 2>/dev/null || true
sleep 1
rm -rf "$R/rr-wt"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
line="$(printf '%s\n' "$out" | grep "^ORPHANED	rr-wt	seat-rr	idle -	pid $fd_pid	claim none	" || true)"
if [ -n "$line" ]; then ok "a roster seat whose worktree is gone reads ORPHANED (worker + the husk pid named)"; else bad "fd orphaned" "$out"; fi
case "$line" in
  *"MISSING since 20"*"(first pass that saw it)"*"ALIVE with no tree"*"branch claude/rr-seat 0 ahead / 0 behind main"*".done absent"*"prunable: yes"*"git admin dir present"*"factory-seat rr-wt"*"parent "*"mtime 20"*"seat-recreate rr-wt"*"seat-retire rr-wt"*)
    ok "the ORPHANED line carries the forensic anchors: first-missing instant, husk, branch ahead/behind, .done, prunable + admin dir (rm -rf shape) with the tripwire name, parent mtime, both remedies" ;;
  *) bad "fd orphaned detail" "$line" ;;
esac
if printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-DEGRADED 1 missing of 1 seats (0 stalled, 0 unmanned;"; then ok "the summary reads FLEET-DEGRADED n missing of N, never FLEET-OK"; else bad "fd degraded" "$(printf '%s\n' "$out" | tail -1)"; fi
first="$(grep "^rr-wt	" "$R/factory/fleet-orphaned" 2>/dev/null | cut -f2)"
if [ -n "$first" ]; then ok "the first pass that saw it missing is recorded in fleet-orphaned ($first)"; else bad "fd orphan record" "$(cat "$R/factory/fleet-orphaned" 2>/dev/null)"; fi
sleep 1
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^ORPHANED	rr-wt	.*MISSING since $first " && [ "$(grep "^rr-wt	" "$R/factory/fleet-orphaned" | cut -f2)" = "$first" ]; then ok "a later pass keeps the FIRST instant (the anchor never moves)"; else bad "fd orphan anchor" "$out"; fi
if ! printf '%s\n' "$out" | grep -q "would:"; then ok "--respawn never plans a revive for an orphan (no tree to boot into)"; else bad "fd orphan respawn" "$out"; fi
out="$(cd "$RP" && "$F" seat-roster 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^rr-wt	.*	ORPHANED since $first"; then ok "seat-roster marks it ORPHANED since the anchor"; else bad "seat-roster orphaned" "$out"; fi
# seat-recreate rebuilds it: husk killed, admin entry dropped, branch ff'd, tree added UNDER THE SEAT ROOT
# (task 1789581979: <primary>/.factory/seats/<seat>, outside the desktop app's GC'd pool root), pinned, handoff, spawn (dry-run).
RPP="$(cd "$RP" && pwd -P)"
NW="$RPP/.factory/seats/rr-wt"
out="$(cd "$RP" && "$F" seat-root 2>/dev/null)"
if [ "$out" = "$RPP/.factory/seats" ] && [ -d "$RPP/.factory/seats" ]; then ok "seat-root prints <primary>/.factory/seats and creates it"; else bad "seat-root" "got '$out'"; fi
out="$(cd "$RP" && "$F" seat-root rr-wt 2>/dev/null)"
if [ "$out" = "$NW" ]; then ok "seat-root <seat> prints the path the seat lives at"; else bad "seat-root seat" "got '$out'"; fi
if (cd "$RP" && "$F" seat-root a b >/dev/null 2>&1); then bad "seat-root usage" "two args accepted"; else ok "seat-root takes at most one seat name"; fi
rm -f "$R/handoff/rr-wt.md"   # the respawn case above left its takeover token; a pending file would be kept as is
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" seat-recreate rr-wt 2>&1)"
if [ -d "$NW/.git" ] || [ -f "$NW/.git" ]; then ok "seat-recreate re-added the worktree"; else bad "recreate tree" "$out"; fi
if printf '%s\n' "$out" | grep -q "^seat-recreate rr-wt: worktree $NW (was .*/rr-wt - a seat lives under the seat root $RPP/.factory/seats, outside the desktop app's worktree pool)"; then ok "the rebuilt seat is minted under the seat root and the banner names the old location"; else bad "recreate relocation" "$out"; fi
if [ ! -e "$R/rr-wt" ]; then ok "nothing was recreated at the roster's old path"; else bad "recreate old path" "$(ls -la "$R/rr-wt" 2>&1)"; fi
if [ -f "$NW/.worktree-keep" ]; then ok "worker-pin dropped the desktop app's keep sentinel (.worktree-keep) into the seat"; else bad "keep sentinel" "$(ls -la "$NW" 2>&1)"; fi
if grep -q "^rr-wt	$NW	seat-rr	claude/rr-seat	20" "$R/factory/fleet-roster" 2>/dev/null; then ok "the roster row now carries the seat-root path"; else bad "roster relocated" "$(cat "$R/factory/fleet-roster" 2>/dev/null)"; fi
if [ "$(git -C "$NW" branch --show-current 2>/dev/null)" = "claude/rr-seat" ]; then ok "on branch claude/rr-seat"; else bad "recreate branch" "$(git -C "$NW" branch --show-current 2>&1)"; fi
if printf '%s\n' "$out" | grep -q "branch claude/rr-seat: fast-forwarded to main (was 0 ahead)"; then ok "a 0-ahead branch is fast-forwarded to main"; else bad "recreate ff" "$out"; fi
if printf '%s\n' "$out" | grep -q "killed dead-husk pid(s): $fd_pid" && ! kill -0 "$fd_pid" 2>/dev/null; then ok "the dead-husk process carrying the session name was killed"; else bad "recreate husk" "$out"; fi
if [ "$(cat "$NW/.factory-worker" 2>/dev/null)" = "seat-rr" ]; then ok "re-pinned as seat-rr"; else bad "recreate pin" "$(cat "$NW/.factory-worker" 2>&1)"; fi
if printf '%s\n' "$out" | grep -q "handoff: wrote .*/handoff/rr-wt.md (recreated after its worktree vanished)" && grep -q "recreated after its worktree vanished" "$R/handoff/rr-wt.md" && grep -q "^cd .*/rr-wt && claude .*--name '$FP-executor-rr-wt'" "$R/handoff/rr-wt.md"; then ok "a takeover handoff says the seat was recreated after its worktree vanished"; else bad "recreate handoff" "$(cat "$R/handoff/rr-wt.md" 2>&1)"; fi
if printf '%s\n' "$out" | grep -q "DRYRUN session name: $FP-executor-rr-wt" && printf '%s\n' "$out" | grep -q "bootstrap: skipped (no scripts/bootstrap.sh"; then ok "then spawn-successor booted it (dry-run program shown); bootstrap skipped where the tree has none"; else bad "recreate spawn" "$out"; fi
if printf '%s\n' "$out" | grep -q "^roster:" && printf '%s\n' "$out" | grep -q "^  rr-wt	" && ! grep -q "^rr-wt	" "$R/factory/fleet-orphaned" 2>/dev/null; then ok "the roster is printed afterwards and the orphan mark is gone"; else bad "recreate roster" "$out"; fi
if grep -q "^seat-recreate 20.* rr-wt: worktree .*rebuilt from claude/rr-seat" "$R/fleet.log" 2>/dev/null; then ok "seat-recreate appended to the fleet-doctor log"; else bad "recreate log" "$(cat "$R/fleet.log" 2>&1)"; fi
if (cd "$RP" && FACTORY_SPAWN_DRYRUN=1 "$F" seat-recreate rr-wt >/dev/null 2>"$R/sr.txt"); then bad "recreate exists" "seat-recreate rebuilt a PRESENT worktree"; else ok "seat-recreate refuses while the worktree exists"; fi
if grep -q "exists - this command rebuilds a VANISHED worktree only" "$R/sr.txt"; then ok "the refusal says why"; else bad "recreate refusal text" "$(cat "$R/sr.txt")"; fi
# The successor boots (a fake again): the next pass reads FLEET-OK.
"$R/spawnfake.sh" --name $FP-executor-rr-wt >/dev/null 2>&1 &
fd_pid=$!
disown "$fd_pid" 2>/dev/null || true
sleep 1
(cd "$NW" && "$F" heartbeat >/dev/null 2>&1)
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	rr-wt	seat-rr	" && printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-OK seats 1"; then ok "with the seat rebuilt and manned the next pass reads FLEET-OK again"; else bad "fd ok after recreate" "$out"; fi
# seat-retire: refuses from inside the seat, refuses while a foreign live cwd is in the tree, then retires.
if (cd "$NW" && FACTORY_PROJECT=$FP "$F" seat-retire rr-wt >/dev/null 2>"$R/st1.txt"); then bad "retire inside" "seat-retire ran from inside the seat"; else ok "seat-retire refuses to run from inside the seat being retired"; fi
if grep -q "standing INSIDE" "$R/st1.txt"; then ok "the refusal names the reason"; else bad "retire inside text" "$(cat "$R/st1.txt")"; fi
(cd "$NW" && exec sleep 60) &
cwd_pid=$!
disown "$cwd_pid" 2>/dev/null || true
sleep 1
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" seat-retire rr-wt --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^DRY-RUN would: kill .*replica-recycle in .*git worktree remove --force .*git branch -d claude/rr-seat.*REFUSAL PENDING: live cwd(s) $cwd_pid(sleep)" && [ -d "$NW" ] && kill -0 "$fd_pid" 2>/dev/null; then ok "--dry-run prints the plan, names the live foreign cwd, touches nothing"; else bad "retire dry" "$out"; fi
if (cd "$RP" && FACTORY_PROJECT=$FP "$F" seat-retire rr-wt >/dev/null 2>"$R/st2.txt"); then bad "retire live cwd" "seat-retire removed a tree a live process stands in"; else ok "seat-retire refuses while another live process has its cwd inside the tree (lsof)"; fi
if grep -q "live process(es) have their cwd inside .*$cwd_pid(sleep)" "$R/st2.txt" && [ -d "$NW" ]; then ok "the refusal names the pid and the tree survives"; else bad "retire live cwd text" "$(cat "$R/st2.txt")"; fi
if ! kill -0 "$fd_pid" 2>/dev/null; then ok "the seat's own named process was already killed before the cwd check (it is never the reason to refuse)"; else bad "retire named kill" "pid $fd_pid still alive"; fi
kill "$cwd_pid" 2>/dev/null || true; wait "$cwd_pid" 2>/dev/null || true
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" seat-retire rr-wt 2>&1)"
if printf '%s\n' "$out" | grep -q "^RETIRED rr-wt" && [ ! -e "$NW" ]; then ok "seat-retire removed the worktree"; else bad "retire" "$out"; fi
if printf '%s\n' "$out" | grep -q "replica: recycled" && printf '%s\n' "$out" | grep -q "NOTHING-RUNNING"; then ok "replica-recycle ran in the tree first (nothing was running)"; else bad "retire recycle" "$out"; fi
if printf '%s\n' "$out" | grep -q "branch claude/rr-seat: deleted (was merged)" && ! git -C "$RP" rev-parse -q --verify refs/heads/claude/rr-seat >/dev/null 2>&1; then ok "the merged branch was deleted (git branch -d)"; else bad "retire branch" "$out"; fi
if [ ! -d "$RP/.git/worktrees/rr-wt" ] && ! grep -q "^rr-wt	" "$R/factory/fleet-roster" 2>/dev/null && [ ! -f "$R/handoff/rr-wt.md" ]; then ok "admin entry, roster row and handoff file are gone"; else bad "retire records" "admin $([ -d "$RP/.git/worktrees/rr-wt" ] && echo present || echo absent), roster '$(cat "$R/factory/fleet-roster" 2>/dev/null)', handoff $([ -f "$R/handoff/rr-wt.md" ] && echo present || echo absent)"; fi
if grep -q "^seat-retire 20.* rr-wt: worker seat-rr" "$R/fleet.log"; then ok "seat-retire appended to the fleet-doctor log"; else bad "retire log" "$(cat "$R/fleet.log")"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if ! printf '%s\n' "$out" | grep -q "^ORPHANED" && printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-OK seats 0"; then ok "a retired seat is simply gone: no ORPHANED line, FLEET-OK"; else bad "fd after retire" "$out"; fi
if (cd "$RP" && FACTORY_PROJECT=$FP "$F" seat-retire rr-wt >/dev/null 2>"$R/st3.txt"); then bad "retire unknown" "seat-retire accepted an unknown seat"; else ok "retiring an unknown seat is refused"; fi
if grep -q "nothing to retire" "$R/st3.txt"; then ok "the refusal says nothing to retire"; else bad "retire unknown text" "$(cat "$R/st3.txt")"; fi
echo "== the legacy location: a seat under .claude/worktrees/ (the desktop app's GC root) is belted, named, and relocated on recreate (task 1789581979) =="
LG="$RPP/.claude/worktrees/lg-wt"
mkdir -p "$RPP/.claude/worktrees"
git -C "$RP" worktree add -q "$LG" -b claude/lg-seat 2>/dev/null
out="$(cd "$LG" && "$F" worker-pin seat-lg 2>&1 >/dev/null)"
if [ -f "$LG/.worktree-keep" ]; then ok "worker-pin on a legacy-located seat drops .worktree-keep (the GC's keep-sentinel verdict)"; else bad "legacy sentinel" "$(ls -la "$LG" 2>&1)"; fi
if printf '%s\n' "$out" | grep -q "legacy location: $LG sits in the desktop app's worktree pool root (.claude/worktrees)" && printf '%s\n' "$out" | grep -q "New seats mint under $RPP/.factory/seats"; then ok "worker-pin names the legacy location and the seat root on stderr"; else bad "legacy pin note" "$out"; fi
rm -f "$LG/.worktree-keep"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^UNMANNED	lg-wt	seat-lg	.*legacy-location .claude/worktrees (desktop-app GC root; .worktree-keep in place; moves to .factory/seats at its next seat-recreate)"; then ok "fleet-doctor tags a legacy-located seat on its line"; else bad "fd legacy tag" "$out"; fi
if [ -f "$LG/.worktree-keep" ]; then ok "every fleet-doctor pass re-drops the sentinel (a running fleet converges with no seat action)"; else bad "fd sentinel" "$(ls -la "$LG" 2>&1)"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" seat-recreate lg-wt 2>&1 >/dev/null)"
if printf '%s' "$out" | grep -q "exists - this command rebuilds a VANISHED worktree only"; then ok "seat-recreate still refuses while the legacy tree exists (a live seat is never moved)"; else bad "legacy recreate present" "$out"; fi
# The GC's removal shape: git worktree remove --force (admin entry gone too).
git -C "$RP" worktree remove --force "$LG" >/dev/null 2>&1
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" seat-recreate lg-wt --no-spawn 2>&1)"
if [ -f "$RPP/.factory/seats/lg-wt/.git" ] && [ ! -e "$LG" ]; then ok "seat-recreate rebuilt the vanished legacy seat under the seat root, not at .claude/worktrees"; else bad "legacy relocate" "$out"; fi
if printf '%s\n' "$out" | grep -q "worktree $RPP/.factory/seats/lg-wt (was $LG - a seat lives under the seat root"; then ok "the banner says where it was"; else bad "legacy relocate banner" "$out"; fi
if [ "$(git -C "$RPP/.factory/seats/lg-wt" branch --show-current 2>/dev/null)" = "claude/lg-seat" ] && [ "$(cat "$RPP/.factory/seats/lg-wt/.factory-worker" 2>/dev/null)" = "seat-lg" ]; then ok "same branch, same pin - only the location changed"; else bad "legacy relocate identity" "$out"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor 2>/dev/null)"
if printf '%s\n' "$out" | grep -q "^UNMANNED	lg-wt	seat-lg	" && ! printf '%s\n' "$out" | grep -q "legacy-location"; then ok "a seat under the seat root carries no legacy tag"; else bad "fd no legacy tag" "$out"; fi
rm -f "$R/handoff/lg-wt.md"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" seat-retire lg-wt 2>&1)"
if printf '%s\n' "$out" | grep -q "^RETIRED lg-wt" && [ ! -e "$RPP/.factory/seats/lg-wt" ]; then ok "seat-retire drops a seat-root seat the same way"; else bad "legacy retire" "$out"; fi
unset FACTORY_FLEET_LOG
unset FACTORY_ACTIVITY_DIRS
rm -rf "$R/fd-act" "$R/fd-draft.md" "$R/handoff/rr-wt.md" "$R/spawnfake.sh"
kill "$pri_pid" 2>/dev/null || true; wait "$pri_pid" 2>/dev/null || true
sleep 1
echo "== prioritizer-boot: the TaskPrioritizer through the spawn path (task 1792506027) =="
# The prioritizer has no worktree and no seat handoff: the boot writes its OWN
# token (tasks/handoff/prioritizer.md) just before the spawn, names the
# session <prefix>-prioritizer, runs the SAME guards / pending stamp / verify
# / profile as spawn-successor, and the doctor's --respawn revives it like a
# seat. Fakes as above: the sleeper plays the live prioritizer, a fake
# osascript plays Terminal (one that times out, one that runs the command).
rm -f "$R/handoff/prioritizer.md" "$R/factory/spawn-pending/prioritizer"
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" prioritizer-boot 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "^DRYRUN session name: $FP-prioritizer$"; then ok "dry-run names the session <prefix>-prioritizer"; else bad "pb dryrun name" "rc=$rc: $out"; fi
bl="$(printf '%s\n' "$out" | sed -n 's/^DRYRUN boot line ([0-9]* bytes, limit 1000): //p')"
bn="$(printf '%s\n' "$out" | sed -n 's/^DRYRUN boot line (\([0-9]*\) bytes, limit 1000): .*/\1/p')"
if [ -n "$bl" ] && [ "${#bl}" = "$bn" ] && [ "$bn" -lt 1000 ]; then ok "the typed boot line is printed with its byte count ($bn, under 1000)"; else bad "pb boot line" "'$bl' / '$bn'"; fi
case "$bl" in
  "cd '$RPP' && FACTORY_TASKS_ROOT='"*"' FACTORY_PROJECT='$FP' '"*"/factory.sh' boot-exec prioritizer --model 'claude-fable-5-1' --name '$FP-prioritizer'; exit 0") ok "the line is cd <primary> && <seams> <self> boot-exec prioritizer --model <m> --name <sname>; exit 0 (FACTORY_TASKS_ROOT + FACTORY_PROJECT ride it when set; every word sq-quoted like a seat's line)" ;;
  *) bad "pb boot line shape" "$bl" ;;
esac
case "$bl" in *TaskPrioritizer*|*"env -u"*) bad "pb line clean" "the typed line carries the prompt or the environment: $bl" ;; *) ok "neither the prompt nor the boot environment rides the typed line (boot-exec reads both inside the window)" ;; esac
if printf '%s\n' "$out" | grep -q "^DRYRUN boot prompt (boot-exec reads it from $R/handoff/prioritizer.md inside the new window): Read .claude/skills/mdex-software-factory/SKILL.md. You are the TaskPrioritizer. .*handoff-clear prioritizer.* Run continuously.$"; then ok "the prompt line names the token and tells the prioritizer to clear it first"; else bad "pb prompt" "$out"; fi
boot="$(printf '%s\n' "$out" | sed -n '/^DRYRUN osascript program:/,/^DRYRUN post-live profile program/p')"
prof="$(printf '%s\n' "$out" | sed -n '/^DRYRUN post-live profile program/,$p')"
if printf '%s' "$boot" | grep -q 'do script' && printf '%s' "$boot" | grep -q 'wid:' && ! printf '%s' "$boot" | grep -q 'settings set' && ! printf '%s' "$boot" | grep -q 'activate' && printf '%s' "$prof" | grep -q "set custom title of selected tab of window id <wid> to \"$FP-prioritizer\""; then ok "the bare do-script boot program + the post-live profile/title program, titled <prefix>-prioritizer"; else bad "pb programs" "$out"; fi
if [ ! -f "$R/handoff/prioritizer.md" ] && [ ! -f "$R/factory/spawn-pending/prioritizer" ]; then ok "the dry run writes neither the token nor a stamp"; else bad "pb dryrun inert" "$(ls "$R/handoff" "$R/factory/spawn-pending" 2>&1)"; fi
if (cd "$RP" && FACTORY_SPAWN_DRYRUN=1 "$F" prioritizer-boot extra >/dev/null 2>&1); then bad "pb usage" "an argument was accepted"; else ok "prioritizer-boot takes no arguments (usage refusal)"; fi
# Hosted: refused with the reason (the canister runs that pass), nothing written.
mkdir -p "$R/pb-remote"; printf '{"url":"http://x","factoryId":"F-000001","runnerId":"R-1"}\n' > "$R/pb-remote/config.json"
if out="$(cd "$RP" && FACTORY_REMOTE_DIR="$R/pb-remote" FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" prioritizer-boot 2>&1)"; then bad "pb hosted" "a hosted checkout booted a prioritizer: $out"; elif printf '%s' "$out" | grep -q "HOSTED" && printf '%s' "$out" | grep -q "canister's own pass" && [ ! -f "$R/handoff/prioritizer.md" ]; then ok "a HOSTED checkout refuses the boot with that reason (the canister's pass; no token written)"; else bad "pb hosted text" "$out"; fi
rm -rf "$R/pb-remote"
# The name guard: a live <prefix>-prioritizer refuses (the dry run too); FACTORY_FORCE=1 overrides.
"$R/prifake.sh" --name $FP-prioritizer >/dev/null 2>&1 &
pri_pid=$!
disown "$pri_pid" 2>/dev/null || true
sleep 1
if out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" prioritizer-boot 2>&1)"; then bad "pb dup" "booted beside a live $FP-prioritizer: $out"; elif printf '%s' "$out" | grep -q "a session named '$FP-prioritizer' is already live (pid $pri_pid)"; then ok "a live process carrying the name refuses the boot, naming its pid (no window, no token)"; else bad "pb dup msg" "$out"; fi
if out="$(cd "$RP" && FACTORY_FORCE=1 FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" prioritizer-boot 2>&1)" && printf '%s' "$out" | grep -q "DRYRUN session name: $FP-prioritizer"; then ok "FACTORY_FORCE=1 overrides the name guard"; else bad "pb force" "$out"; fi
# The doctor: ACTIVE with a fresh board (nothing planned); STALLED once the
# board is old with claimable work - and --respawn revives it like a seat.
printf -- '---\ntouches: pb-bait\n---\n# prioritizer-boot bait\n' > "$R/pb-draft.md"
pb_bait="$("$F" new "$R/pb-draft.md")"; pb_bait_id="$(basename "$pb_bait" .md)"; pb_bait_id="${pb_bait_id#*-}"
touch "$R/factory/index.md"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	prioritizer	-	board 0m	pid $pri_pid	claim -	$" && ! printf '%s\n' "$out" | grep -q "would:.*prioritizer-boot"; then ok "a live prioritizer with a fresh board reads ACTIVE and --respawn plans nothing for it"; else bad "pb fd active" "$out"; fi
touch -t 202601010000 "$R/factory/index.md"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^STALLED	prioritizer	-	board [0-9]*m	pid $pri_pid	claim -	board not regenerated for [0-9]*m with [0-9]* claimable task(s) queued - dead, not idle$"; then ok "an old board with claimable work reads STALLED - dead, not idle (the 'never auto-respawned ... boot by hand' note is gone)"; else bad "pb fd stalled" "$out"; fi
if printf '%s\n' "$out" | grep -q "would: kill parked pid(s) $pri_pid (TERM then KILL); prioritizer-boot$"; then ok "--respawn --dry-run plans the revive: kill the parked pid (TERM then KILL), then prioritizer-boot"; else bad "pb fd dry plan" "$out"; fi
if kill -0 "$pri_pid" 2>/dev/null && [ ! -f "$R/handoff/prioritizer.md" ]; then ok "the dry run touched nothing (process alive, no token)"; else bad "pb fd dry inert" "$(kill -0 "$pri_pid" 2>/dev/null && echo alive || echo dead) / $(ls "$R/handoff" 2>&1)"; fi
if printf '%s\n' "$out" | tail -1 | grep -q "^FLEET-STALLED 1 stalled, 0 unmanned of 0 seats$"; then ok "a stalled prioritizer counts in the summary as before"; else bad "pb fd summary" "$(printf '%s\n' "$out" | tail -1)"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 FACTORY_FLEET_RESPAWN=1 "$F" fleet-doctor 2>&1)"
sleep 1
if ! kill -0 "$pri_pid" 2>/dev/null; then ok "the live respawn pass killed the parked prioritizer by pid"; else bad "pb fd kill" "pid $pri_pid survived"; fi
if printf '%s\n' "$out" | grep -q "killing parked $FP-prioritizer pid(s) $pri_pid" && printf '%s\n' "$out" | grep -q "DRYRUN session name: $FP-prioritizer" && printf '%s\n' "$out" | grep -q "revived prioritizer"; then ok "then prioritizer-boot ran (dry-run program shown) and the pass reports 'revived prioritizer'"; else bad "pb fd revive" "$out"; fi
# UNMANNED: no process - the note is the door, the plan is the door.
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^UNMANNED	prioritizer	-	board [0-9]*m	pid none	claim -	no process named $FP-prioritizer - boot: scripts/factory.sh prioritizer-boot$"; then ok "no process = UNMANNED; the note names the door and nothing else (a short compat surface)"; else bad "pb fd unmanned" "$out"; fi
if printf '%s\n' "$out" | grep -q "would: prioritizer-boot$"; then ok "--respawn --dry-run plans 'would: prioritizer-boot' for it"; else bad "pb fd unmanned plan" "$out"; fi
# The doctor's own revive hits the -1712 fake: PENDING, the stamp keyed
# prioritizer, the token written, the next passes report instead of booting.
printf '#!/bin/bash\necho "44:670: execution error: Terminal got an error: AppleEvent timed out. (-1712)" >&2\nexit 1\n' > "$R/osafake.sh"; chmod +x "$R/osafake.sh"
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_OSASCRIPT_BIN="$R/osafake.sh" FACTORY_CLAUDE_BIN="$R/prifake.sh" FACTORY_SPAWN_VERIFY_SECS=1 "$F" fleet-doctor --respawn 2>&1)"
if printf '%s\n' "$out" | grep -q "respawn of the prioritizer PENDING (AppleEvent timed out - Terminal may still run it)" && grep -q "^session: $FP-prioritizer" "$R/factory/spawn-pending/prioritizer" 2>/dev/null && ! printf '%s\n' "$out" | grep -q "boot by hand"; then ok "a revive whose AppleEvent timed out reports PENDING, stamps 'prioritizer' and never prints a hand-boot line (the pass goes on)"; else bad "pb fd pending" "$out / $(ls "$R/factory/spawn-pending/" 2>&1)"; fi
if [ -f "$R/handoff/prioritizer.md" ] && grep -q "^cd $RPP && claude --model claude-fable-5-1 --name '$FP-prioritizer'$" "$R/handoff/prioritizer.md" && grep -q "^## Boot prompt$" "$R/handoff/prioritizer.md" && grep -q "^Read .claude/skills/mdex-software-factory/SKILL.md. You are the TaskPrioritizer. " "$R/handoff/prioritizer.md"; then ok "the token tasks/handoff/prioritizer.md was written in the seat-token shape (hand-boot line, ## Boot prompt, the prompt)"; else bad "pb token" "$(cat "$R/handoff/prioritizer.md" 2>&1)"; fi
out="$("$F" handoff-list)"
if printf '%s\n' "$out" | grep -q "^prioritizer	"; then ok "handoff-list lists the prioritizer's token while the boot is in flight"; else bad "pb handoff-list" "$out"; fi
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^UNMANNED	prioritizer	-	board [0-9]*m	pid none	claim -	spawn pending since 20[0-9-]*T[0-9:]*Z, Terminal AppleEvents timing out - check Terminal: a modal, a hung tab, or Automation permission (no respawn until .*spawn-pending/prioritizer expires, FACTORY_SPAWN_PENDING_TTL default 6h, or the process appears); handoff-pending$" && ! printf '%s\n' "$out" | grep -q "would:" && printf '%s\n' "$out" | grep -q "spawn pending since .* - no respawn (the timed-out AppleEvent may still boot $FP-prioritizer"; then ok "while the stamp stands the row reads UNMANNED (spawn pending since ...; handoff-pending) and --respawn plans no revive"; else bad "pb fd pending line" "$out"; fi
if out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_SPAWN_DRYRUN=1 "$F" prioritizer-boot 2>&1)"; then bad "pb pending guard" "a boot proceeded past a fresh stamp: $out"; elif printf '%s' "$out" | grep -q "spawn PENDING for prioritizer since 20"; then ok "a direct prioritizer-boot refuses on the stamp too"; else bad "pb pending guard msg" "$out"; fi
# boot-exec (what the typed line runs inside the window) reads the prioritizer's
# token like a seat's: with the token present it gets as far as the claude
# binary check; without it the hint names prioritizer-boot as the re-spawn.
# FACTORY_BOOT_EXEC_HOLD_S=0 skips the 10-min error hold a real window keeps.
out="$(FACTORY_BOOT_EXEC_HOLD_S=0 FACTORY_CLAUDE_BIN=/nonexistent/claude "$F" boot-exec prioritizer --model m --name $FP-prioritizer 2>&1 </dev/null || true)"
if printf '%s' "$out" | grep -q "claude CLI not executable at /nonexistent/claude"; then ok "boot-exec prioritizer reads the token's prompt (it reaches the claude binary check)"; else bad "pb boot-exec" "$out"; fi
out="$(cd "$RP" && "$F" handoff-clear prioritizer 2>&1)"
if [ ! -f "$R/handoff/prioritizer.md" ] && [ ! -f "$R/factory/spawn-pending/prioritizer" ] && printf '%s' "$out" | grep -q "spawn-pending stamp for prioritizer cleared"; then ok "handoff-clear prioritizer (the booted prioritizer's first act) drops the token AND spends the stamp"; else bad "pb handoff-clear" "$out / $(ls "$R/handoff" "$R/factory/spawn-pending" 2>&1)"; fi
out="$(FACTORY_BOOT_EXEC_HOLD_S=0 FACTORY_CLAUDE_BIN=/nonexistent/claude "$F" boot-exec prioritizer --model m --name $FP-prioritizer 2>&1 </dev/null || true)"
if printf '%s' "$out" | grep -q "no handoff file .*/handoff/prioritizer.md .*spawn again (factory.sh prioritizer-boot"; then ok "boot-exec with no token names prioritizer-boot as the re-spawn (a seat's names spawn-successor)"; else bad "pb boot-exec hint" "$out"; fi
# A Terminal that RUNS the command: the fake osascript launches the sleeper
# (the window's claude) and returns a window id; its second call answers the
# post-live profile program. The banner is spawn-successor's shape.
cat > "$R/osaok.sh" <<OSA
#!/bin/bash
case "\$*" in
  *"do script"*) "$R/prifake.sh" --name $FP-prioritizer >/dev/null 2>&1 & echo \$! > "$R/prifake.pid"; echo "wid:7" ;;
  *) echo "profile: Factory title: set" ;;
esac
OSA
chmod +x "$R/osaok.sh"
out="$(cd "$RP" && FACTORY_PROJECT=$FP FACTORY_OSASCRIPT_BIN="$R/osaok.sh" FACTORY_CLAUDE_BIN="$R/prifake.sh" FACTORY_SPAWN_VERIFY_SECS=3 "$F" prioritizer-boot 2>&1)"; rc=$?
pri_pid="$(cat "$R/prifake.pid" 2>/dev/null)"
if [ "$rc" = 0 ] && [ -n "$pri_pid" ] && printf '%s\n' "$out" | grep -q "^spawned prioritizer Terminal in $RPP - session '$FP-prioritizer' live (pid $pri_pid, window id 7, profile: Factory, title: set)$"; then ok "a boot Terminal runs reports spawn-successor's banner shape: spawned ... - session '<name>' live (pid N, window id W, profile: ..., title: ...)"; else bad "pb live banner" "rc=$rc: $out"; fi
if [ -f "$R/handoff/prioritizer.md" ] && [ ! -f "$R/factory/spawn-pending/prioritizer" ]; then ok "the token stands until the booted prioritizer's handoff-clear (the spawn never clears it); no stamp on a clean boot"; else bad "pb token kept" "token $([ -f "$R/handoff/prioritizer.md" ] && echo present || echo MISSING), stamp $([ -f "$R/factory/spawn-pending/prioritizer" ] && echo present || echo absent)"; fi
touch "$R/factory/index.md"
out="$(cd "$RP" && FACTORY_PROJECT=$FP "$F" fleet-doctor --respawn --dry-run 2>&1)"
if printf '%s\n' "$out" | grep -q "^ACTIVE	prioritizer	-	board 0m	pid $pri_pid	claim -	handoff-pending$"; then ok "the doctor reads the booted prioritizer ACTIVE and names its still-standing token (handoff-pending)"; else bad "pb fd booted" "$out"; fi
kill "$pri_pid" 2>/dev/null || true
sleep 1
(cd "$RP" && "$F" handoff-clear prioritizer >/dev/null 2>&1)
(cd "$RP" && "$F" claim --operator --id "$pb_bait_id" seat-pb >/dev/null 2>&1)
(cd "$RP" && "$F" done "$pb_bait_id" abandoned "selftest" >/dev/null 2>&1)
touch "$R/factory/index.md"
rm -f "$R/prifake.sh" "$R/prifake.pid" "$R/osafake.sh" "$R/osaok.sh" "$R/pb-draft.md" "$R/handoff/prioritizer.md" "$R/factory/spawn-pending/prioritizer"
git -C "$RP" worktree remove --force "$R/rr-wt" 2>/dev/null
rm -rf "$RP" "$R/rr-wt"

echo "== local mode: new --attach copies the files under tasks/attachments/<id>/ (task 1791312774) =="
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' > "$R/logo.svg"; head -c 300 /dev/urandom > "$R/mark.png"
printf -- '---\ntouches: attachprobe\n---\n# a task with files\n' > "$R/att.md"
out="$(FACTORY_WORKER=seat-att "$F" new "$R/att.md" --attach "$R/logo.svg" --attach "$R/mark.png" 2>"$R/att.err")"; rc=$?
aid="$(basename "$out" .md | cut -d- -f2)"
if [ "$rc" = "0" ] && [ -f "$out" ] && [ -f "$R/attachments/$aid/logo.svg" ] && [ -f "$R/attachments/$aid/mark.png" ] && cmp -s "$R/mark.png" "$R/attachments/$aid/mark.png"; then ok "new --attach copies both files to tasks/attachments/<id>/<basename> byte-identical"; else bad "local attach copy" "rc $rc: $out / $(cat "$R/att.err") / $(ls "$R/attachments" 2>/dev/null)"; fi
lsha="$(shasum -a 256 "$R/logo.svg" | cut -d' ' -f1)"
if grep -q "^## Attachments$" "$out" && grep -q "^- attachments/$aid/logo.svg ($(wc -c < "$R/logo.svg" | tr -d ' ') bytes, sha256 $lsha, uploaded by seat-att)$" "$out" && grep -q "^- attachments/$aid/mark.png (300 bytes, sha256 " "$out"; then ok "the queued file ends with the ## Attachments section: tasks-root-relative path, size, sha256, uploader"; else bad "local attach section" "$(tail -4 "$out")"; fi
out2="$(FACTORY_WORKER=seat-att "$F" claim seat-att --affinity attachprobe 2>/dev/null)"
if [ -f "$out2" ] && [ -f "$R/attachments/$aid/logo.svg" ] && grep -q "^- attachments/$aid/logo.svg" "$out2"; then ok "a local claim leaves the files where they are (the section's path stays valid)"; else bad "local attach claim" "aid $aid; claimed $out2; files: $(ls "$R/attachments/$aid" 2>&1 | tr '\n' ' '); section: $(grep -c '^- attachments/' "$out2" 2>/dev/null)"; fi
"$F" requeue "$aid" 30 "back" >/dev/null 2>&1 || true
if "$F" new "$R/att.md" --attach "$R/nope.svg" >/dev/null 2>"$R/att2.err"; then bad "local attach missing" "a missing --attach file was accepted"; else ok "a missing --attach file is refused"; fi
if grep -q "no such file" "$R/att2.err"; then ok "...naming the file"; else bad "local attach missing text" "$(cat "$R/att2.err")"; fi
head -c 2000001 /dev/zero > "$R/big.bin"
if "$F" new "$R/att.md" --attach "$R/big.bin" >/dev/null 2>"$R/att3.err"; then bad "local attach big" "a 2 MB + 1 file was accepted"; else ok "a file over 2 MB is refused before any id is minted"; fi
if grep -q "over the 2 MB per-file cap" "$R/att3.err"; then ok "...with the cap named"; else bad "local attach big text" "$(cat "$R/att3.err")"; fi
if "$F" new "$R/att.md" --attach "$R/logo.svg" --attach "$R/logo.svg" --attach "$R/logo.svg" --attach "$R/logo.svg" --attach "$R/logo.svg" --attach "$R/logo.svg" >/dev/null 2>"$R/att4.err"; then bad "local attach count" "six files were accepted"; else ok "a sixth file is refused"; fi
if "$F" amend 1 "x" >/dev/null 2>"$R/att5.err"; then bad "local amend" "amend ran in local mode"; else ok "amend has no local arm (hosted-mode command)"; fi
if grep -q "amend is a hosted-mode command" "$R/att5.err"; then ok "...and says so"; else bad "local amend text" "$(cat "$R/att5.err")"; fi
rm -f "$R/big.bin"

echo "== drill-worktree-prune: the doctor's rows drive the arms, the belts refuse by construction (task 1791286192) =="
# A throwaway PRIMARY with registered worktrees + a fake doctor (FACTORY_DOCTOR_BIN)
# whose DRILL-WORKTREE rows name every arm. The only git write is the prunable
# row's `git worktree remove --force` + the final `git worktree prune`; the
# belts (the primary, a pinned tree) and the refusing verdicts touch nothing.
DP="$R/drillprim"; mkdir -p "$DP"; git init -q "$DP" 2>/dev/null
git -C "$DP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
DW1="$R/drill-scratch/one"; DW2="$R/drill-scratch/two"; DW3="$R/drill-scratch/gone"; DW4="$R/drill-scratch/pinned"
mkdir -p "$R/drill-scratch"
for w in "$DW1" "$DW2" "$DW3" "$DW4"; do git -C "$DP" worktree add -q --detach "$w" HEAD 2>/dev/null; done
rm -rf "$DW3"                                  # the harness-GC shape: dir gone, admin entry left
printf 'seat-x\n' > "$DW4/.factory-worker"     # a seat wherever it sits
FD="$R/fakedoc.sh"
{
  echo '#!/bin/sh'
  echo '[ "$1" = "--drill-worktrees" ] || { echo "fake doctor: unexpected flag $1" >&2; exit 2; }'
  printf 'printf "DRILL-WORKTREE\\t%%s\\t%%s\\t%%s\\t%%s\\n" "%s" 12 prunable "no live main"\n' "$DW1"
  printf 'printf "DRILL-WORKTREE\\t%%s\\t%%s\\t%%s\\t%%s\\n" "%s" 7 live-replica "main pid 1 attributed"\n' "$DW2"
  printf 'printf "DRILL-WORKTREE\\t%%s\\t%%s\\t%%s\\t%%s\\n" "%s" 0 gone "dir gone"\n' "$DW3"
  printf 'printf "DRILL-WORKTREE\\t%%s\\t%%s\\t%%s\\t%%s\\n" "%s" 3 prunable "a seat the rule should never admit"\n' "$DW4"
  printf 'printf "DRILL-WORKTREE\\t%%s\\t%%s\\t%%s\\t%%s\\n" "%s" 0 prunable "the primary itself"\n' "$DP"
  echo 'echo "DRILL-WORKTREES 5 (3 prunable, 0.0 GB)"'
} > "$FD"; chmod +x "$FD"
dwp() { (cd "$DP" && FACTORY_DOCTOR_BIN="$FD" FACTORY_FLEET_LOG="$R/fleet.log" "$F" drill-worktree-prune "$@" 2>&1); }   # from the fake primary: resolve_root derives PRIMARY from the cwd
out="$(dwp --dry-run)"
case "$out" in *"WOULD PRUNE $DW1 (state 12 MB"*) ok "dry-run names the prunable tree with its state size" ;; *) bad "dry-run prunable" "$out" ;; esac
case "$out" in *"REFUSED $DW2: live-replica"*) ok "a live replica attributed to the tree is refused by name" ;; *) bad "dry-run live" "$out" ;; esac
case "$out" in *"WOULD PRUNE admin entry for $DW3"*) ok "a dir the harness GC'd under git is a prunable admin entry" ;; *) bad "dry-run gone" "$out" ;; esac
case "$out" in *"REFUSED $DW4: carries .factory-worker (seat-x)"*) ok "a pinned tree (a seat) is refused whatever the doctor said" ;; *) bad "dry-run pinned" "$out" ;; esac
case "$out" in *"REFUSED $DP: the PRIMARY checkout"*) ok "the primary is refused whatever the doctor said" ;; *) bad "dry-run primary" "$out" ;; esac
case "$out" in *"dry-run: 1 of 5 would be removed (0.0 GB of state), 1 admin entry pruned, 3 refused - nothing touched"*) ok "the dry-run summary counts prunable / admin / refused" ;; *) bad "dry-run summary" "$out" ;; esac
n="$(git -C "$DP" worktree list --porcelain | grep -c '^worktree ')"
if [ "$n" = "5" ] && [ -d "$DW1" ]; then ok "dry-run touched no tree (5 registered, the prunable dir still there)"; else bad "dry-run no-op" "$n registered, one present: $([ -d "$DW1" ] && echo yes || echo no)"; fi
out="$(dwp)"
case "$out" in *"PRUNED $DW1 (state 12 MB freed; git worktree remove --force ok)"*) ok "the real run removes the prunable tree from the primary" ;; *) bad "prune" "$out" ;; esac
case "$out" in *"git worktree prune: ok"*) ok "...and runs git worktree prune once for the GC'd admin entry" ;; *) bad "prune admin" "$out" ;; esac
case "$out" in *"DRILL-WORKTREE-PRUNE pruned 1 of 5 (0.0 GB of state freed), 1 admin entry pruned, 3 refused"*) ok "the run summary" ;; *) bad "prune summary" "$out" ;; esac
n="$(git -C "$DP" worktree list --porcelain | grep -c '^worktree ')"
if [ "$n" = "3" ] && [ ! -e "$DW1" ] && [ -d "$DW2" ] && [ -d "$DW4" ] && [ -d "$DP/.git" ]; then ok "registry: primary + two + pinned remain (3); the prunable dir and the GC'd entry are gone; refused trees untouched"; else bad "registry after" "$n registered; one $([ -e "$DW1" ] && echo present || echo gone), two $([ -d "$DW2" ] && echo present || echo GONE), pinned $([ -d "$DW4" ] && echo present || echo GONE)"; fi
if grep -q "drill-worktree-prune .*pruned 1 of 5" "$R/fleet.log" 2>/dev/null; then ok "the run is appended to the fleet log"; else bad "fleet log" "$(cat "$R/fleet.log" 2>/dev/null)"; fi
out="$(dwp --bogus)"; rc=$?
if [ "$rc" != "0" ] && case "$out" in *"usage: factory.sh drill-worktree-prune [--dry-run]"*) true ;; *) false ;; esac; then ok "an unknown flag is a usage refusal"; else bad "usage" "rc $rc: $out"; fi

# ── MULTI/DEX-specific sections (kept across the 2026-10-31 engine re-sync) ──
echo "== the bookkeeping gate refuses closes with an unmoved docs/tasks brief =="
# Drain earlier sections' leftovers so each claim below gets the task this
# section just minted (claims take the queue head, not the newest task).
while :; do
  out="$("$F" claim seat-drain 2>/dev/null)" || break
  case "$out" in EMPTY*) break ;; esac
  id="$(basename "$out" .md)"; id="${id#*-}"
  FACTORY_FORCE=1 "$F" done "$id" done "selftest drain" >/dev/null 2>&1
done
# A throwaway checkout: the gate resolves docs/tasks from the CLOSING cwd.
CK="$R/checkout"
mkdir -p "$CK/docs/tasks/done"
git -C "$CK" init -q
echo "# brief" > "$CK/docs/tasks/W9-99-selftest.md"
d_bk="$R/draft.md"
{ echo "---"; echo "docfile: docs/tasks/W9-99-selftest.md"; echo "touches: docs"; echo "---"; echo "# bookkeeping gate task"; } > "$d_bk"
"$F" new "$d_bk" >/dev/null
out="$("$F" claim seat-bk)"; id_bk="$(basename "$out" .md)"; id_bk="${id_bk#*-}"
if (cd "$CK" && "$F" done "$id_bk" done "no move" >/dev/null 2>"$R/bkerr.txt"); then
  bad "bookkeeping refusal" "a docfile task closed while the brief sat at its original path"
else
  ok "done refused while the brief sits at its original path"
fi
if grep -q "bookkeeping law" "$R/bkerr.txt"; then ok "refusal names the bookkeeping law"; else bad "refusal message" "$(cat "$R/bkerr.txt")"; fi
if [ "$(count "$R/claimed" "*-$id_bk.md")" = "1" ]; then ok "the refused task stays claimed"; else bad "refusal state" "task left claimed/"; fi
mv "$CK/docs/tasks/W9-99-selftest.md" "$CK/docs/tasks/done/"
if (cd "$CK" && "$F" done "$id_bk" done "moved" >/dev/null 2>&1); then ok "the moved brief unlocks the close"; else bad "bookkeeping pass" "move did not unlock done"; fi
echo "# brief2" > "$CK/docs/tasks/W9-98-selftest.md"
{ echo "---"; echo "docfile: docs/tasks/W9-98-selftest.md"; echo "---"; echo "# bookkeeping forced close"; } > "$d_bk"
"$F" new "$d_bk" >/dev/null
out="$("$F" claim seat-bk2)"; id_bk2="$(basename "$out" .md)"; id_bk2="${id_bk2#*-}"
if (cd "$CK" && FACTORY_FORCE=1 "$F" done "$id_bk2" done "forced" >/dev/null 2>"$R/bkerr2.txt"); then
  ok "FACTORY_FORCE=1 overrides the gate"
else
  bad "force override" "$(cat "$R/bkerr2.txt")"
fi
if grep -q "overridden" "$R/bkerr2.txt"; then ok "the override warns on stderr"; else bad "override warning" "$(cat "$R/bkerr2.txt")"; fi
{ echo "---"; echo "lane: operator"; echo "docfile: docs/tasks/W9-98-selftest.md"; echo "---"; echo "# bookkeeping operator exempt"; } > "$d_bk"
p_bk3="$("$F" new "$d_bk")"
id_bk3="$(basename "$p_bk3" .md)"; id_bk3="${id_bk3#*-}"
"$F" claim --operator --id "$id_bk3" >/dev/null
if (cd "$CK" && "$F" done "$id_bk3" done "rollout ran" >/dev/null 2>&1); then ok "operator-lane closes stay exempt"; else bad "operator exemption" "lane task was refused"; fi
mk "" "no docfile task"
out="$("$F" claim seat-bk4)"; id_bk4="$(basename "$out" .md)"; id_bk4="${id_bk4#*-}"
if "$F" done "$id_bk4" done "inline task" >/dev/null 2>&1; then ok "tasks without a docfile close without the gate"; else bad "no-docfile gate" "an inline task was refused"; fi

echo "== the posture gate refuses merges off the committed defaults =="
# A throwaway git repo standing in for the primary: the REAL mdx_posture_of
# (copied from this checkout's scripts/lib/targets.sh) reads the branch's
# files, so this also exercises the one true reader end to end.
PG="$R/posture-repo"
mkdir -p "$PG/src/backend" "$PG/src/bridge" "$PG/scripts/lib"
git -C "$PG" init -q -b main
cp "$HERE/lib/targets.sh" "$PG/scripts/lib/targets.sh"
mo_body() {  # mo_body <posture> — the real four-line block (H-02 byte-diffs it against main)
  echo "  // transient let DEPLOY_MODE : DeployMode = #production  (decoy in a comment)"
  echo "  public type DeployMode = { #dev; #play; #production };"
  echo "  transient let DEPLOY_MODE : DeployMode = #$1;"
  echo "  transient let IS_PRODUCTION : Bool = DEPLOY_MODE == #production;"
  echo "  transient let IS_DEV : Bool = DEPLOY_MODE == #dev;"
}
mo_body play > "$PG/src/backend/main.mo"
mo_body play > "$PG/src/bridge/main.mo"
printf 'networks:\n  local:\n    gateway: {}\n' > "$PG/icp.yaml"
mkdir -p "$PG/.icp/data/mappings"
cp "$HERE/../.icp/data/mappings/subnet.ids.json" "$HERE/../.icp/data/mappings/engine.ids.json" "$PG/.icp/data/mappings/"
git -C "$PG" add -A && git -C "$PG" -c user.email=s@s -c user.name=selftest commit -qm base
git -C "$PG" branch claude/good
git -C "$PG" checkout -qb claude/bad-posture
mo_body dev > "$PG/src/backend/main.mo"
git -C "$PG" -c user.email=s@s -c user.name=selftest commit -qam "flip to dev"
git -C "$PG" checkout -q main
git -C "$PG" checkout -qb claude/bad-port
printf 'networks:\n  local:\n    gateway:\n      port: 0\n' > "$PG/icp.yaml"
git -C "$PG" -c user.email=s@s -c user.name=selftest commit -qam "port 0"
git -C "$PG" checkout -q main
# H-02 fixtures: a mapping edit (operator-lane), the F20 payload (a re-spaced
# real #dev beside a block-comment #play decoy the old reader read as play),
# IS_DEV forced true beside a #play literal (only the byte-diff sees it), and
# a benign edit elsewhere in main.mo that must still merge.
git -C "$PG" checkout -qb claude/bad-mapping
sed 's/"backend": *"[^"]*"/"backend": "aaaaa-aa"/' "$HERE/../.icp/data/mappings/subnet.ids.json" > "$PG/.icp/data/mappings/subnet.ids.json"
git -C "$PG" -c user.email=s@s -c user.name=selftest commit -qam "poison one mapping id"
git -C "$PG" checkout -q main
git -C "$PG" checkout -qb claude/f20-payload
{ echo "  public type DeployMode = { #dev; #play; #production };"
  echo "  transient let DEPLOY_MODE  : DeployMode = #dev; /* transient let DEPLOY_MODE : DeployMode = #play; */"
  echo "  transient let IS_PRODUCTION : Bool = DEPLOY_MODE == #production;"
  echo "  transient let IS_DEV : Bool = DEPLOY_MODE == #dev;"; } > "$PG/src/backend/main.mo"
git -C "$PG" -c user.email=s@s -c user.name=selftest commit -qam "F20 payload"
git -C "$PG" checkout -q main
git -C "$PG" checkout -qb claude/bad-isdev
mo_body play | sed 's/IS_DEV : Bool = DEPLOY_MODE == #dev/IS_DEV : Bool = true/' > "$PG/src/backend/main.mo"
git -C "$PG" -c user.email=s@s -c user.name=selftest commit -qam "IS_DEV forced true"
git -C "$PG" checkout -q main
git -C "$PG" checkout -qb claude/good-elsewhere
echo "  let unrelated = 1;" >> "$PG/src/backend/main.mo"
git -C "$PG" -c user.email=s@s -c user.name=selftest commit -qam "benign edit elsewhere"
git -C "$PG" checkout -q main
export FACTORY_PRIMARY="$PG"
if "$F" merge-lock acquire claude/good >/dev/null 2>&1; then ok "a clean branch acquires the lock"; else bad "clean acquire" "refused"; fi
"$F" merge-lock release claude/good >/dev/null
if "$F" merge-lock acquire claude/bad-posture >/dev/null 2>"$R/pgerr.txt"; then
  bad "posture refusal" "a #dev backend acquired the merge lock"
  "$F" merge-lock release claude/bad-posture >/dev/null 2>&1
else
  ok "a #dev backend is refused the merge lock"
fi
if grep -q "src/backend/main.mo:#dev" "$R/pgerr.txt"; then ok "refusal names the file and posture"; else bad "posture message" "$(cat "$R/pgerr.txt")"; fi
if [ "$("$F" merge-lock status)" = "free" ]; then ok "a refused acquire leaves the lock free"; else bad "lock state" "$("$F" merge-lock status)"; fi
if FACTORY_FORCE=1 "$F" merge-lock acquire claude/bad-posture >/dev/null 2>"$R/pgerr2.txt"; then
  ok "FACTORY_FORCE=1 overrides the posture gate"
  "$F" merge-lock release claude/bad-posture >/dev/null
else
  bad "posture force" "$(cat "$R/pgerr2.txt")"
fi
if grep -q "overridden" "$R/pgerr2.txt"; then ok "the override warns on stderr"; else bad "posture override warning" "$(cat "$R/pgerr2.txt")"; fi
if "$F" merge-lock acquire claude/bad-port >/dev/null 2>"$R/pgerr3.txt"; then
  bad "port refusal" "a port-0 icp.yaml acquired the merge lock"
  "$F" merge-lock release claude/bad-port >/dev/null 2>&1
else
  ok "a port-0 icp.yaml is refused the merge lock"
fi
if grep -q "icp.yaml:port-0" "$R/pgerr3.txt"; then ok "refusal names the port-0 line"; else bad "port message" "$(cat "$R/pgerr3.txt")"; fi
echo "== H-02: the merge gate refuses mapping edits and DEPLOY_MODE-block drift =="
if "$F" merge-lock acquire claude/good-elsewhere >/dev/null 2>"$R/pgerr6.txt"; then ok "a benign edit elsewhere in main.mo still acquires the lock"; "$F" merge-lock release claude/good-elsewhere >/dev/null
else bad "benign acquire" "$(cat "$R/pgerr6.txt")"; fi
if "$F" merge-lock acquire claude/bad-mapping >/dev/null 2>"$R/pgerr4.txt"; then
  bad "mapping refusal" "a branch editing .icp/data/mappings acquired the merge lock"
  "$F" merge-lock release claude/bad-mapping >/dev/null 2>&1
else
  ok "a branch editing .icp/data/mappings/*.ids.json is refused the merge lock (mapping edits are operator-lane)"
fi
if grep -q "subnet.ids.json:mapping-edit" "$R/pgerr4.txt"; then ok "refusal names the mapping file"; else bad "mapping message" "$(cat "$R/pgerr4.txt")"; fi
if FACTORY_FORCE=1 "$F" merge-lock acquire claude/bad-mapping >/dev/null 2>"$R/pgerr4b.txt"; then
  ok "FACTORY_FORCE=1 overrides the mapping gate (the operator's own lane)"
  "$F" merge-lock release claude/bad-mapping >/dev/null
else bad "mapping force" "$(cat "$R/pgerr4b.txt")"; fi
if "$F" merge-lock acquire claude/f20-payload >/dev/null 2>"$R/pgerr5.txt"; then
  bad "F20 refusal" "the F20 payload (re-spaced #dev + block-comment #play decoy) acquired the merge lock"
  "$F" merge-lock release claude/f20-payload >/dev/null 2>&1
else
  ok "the F20 payload (re-spaced #dev + block-comment #play decoy) is refused the merge lock"
fi
if grep -q "src/backend/main.mo:#unresolved" "$R/pgerr5.txt"; then ok "the reader refuses the payload outright (no posture resolved)"; else bad "F20 reader message" "$(cat "$R/pgerr5.txt")"; fi
if grep -q "src/backend/main.mo:DEPLOY_MODE-block-differs-from-main" "$R/pgerr5.txt"; then ok "the byte-diff against main flags the payload too"; else bad "F20 byte-diff message" "$(cat "$R/pgerr5.txt")"; fi
if "$F" merge-lock acquire claude/bad-isdev >/dev/null 2>"$R/pgerr7.txt"; then
  bad "IS_DEV refusal" "IS_DEV := true beside a #play literal acquired the merge lock"
  "$F" merge-lock release claude/bad-isdev >/dev/null 2>&1
else
  ok "IS_DEV forced true beside a #play literal is refused (the byte-diff against main sees what the reader cannot)"
fi
if grep -q "src/backend/main.mo:DEPLOY_MODE-block-differs-from-main" "$R/pgerr7.txt"; then ok "refusal names the block drift"; else bad "IS_DEV message" "$(cat "$R/pgerr7.txt")"; fi
if [ "$("$F" merge-lock status)" = "free" ]; then ok "the H-02 refusals leave the lock free"; else bad "H-02 lock state" "$("$F" merge-lock status)"; fi
if "$F" merge-lock acquire seat-nonbranch >/dev/null 2>"$R/pgerr4.txt"; then
  ok "a non-branch label acquires (gate skipped)"
  "$F" merge-lock release seat-nonbranch >/dev/null
else
  bad "non-branch skip" "$(cat "$R/pgerr4.txt")"
fi
if grep -q "gate skipped" "$R/pgerr4.txt"; then ok "the skip is loud"; else bad "skip message" "$(cat "$R/pgerr4.txt")"; fi

echo "== the merge lock has exactly one holder under contention (issue #55) =="

echo "== the law-5 primary-checkout guards (ported from open-saas a6e6e6e44) =="
HOOK="$(cd "$HERE/.." && pwd)/.githooks/pre-commit"
GP="$R/guard-primary"
mkdir -p "$GP"
git init -q "$GP" 2>/dev/null
git -C "$GP" symbolic-ref HEAD refs/heads/main 2>/dev/null
git -C "$GP" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
git -C "$GP" worktree add -q "$R/guard-wt" -b claude/guard-seat 2>/dev/null
if (cd "$GP" && FACTORY_WORKER=seat-x "$HOOK" >/dev/null 2>"$R/g1.txt"); then
  bad "hook seat refusal" "a seat-identified commit on primary main was allowed"
else
  ok "pre-commit refuses a consumer-seat commit on the primary's main"
fi
if grep -q "law 5" "$R/g1.txt" && grep -q "merge protocol" "$R/g1.txt"; then
  ok "the refusal names the law and the remedy"
else
  bad "hook message" "$(cat "$R/g1.txt")"
fi
if (cd "$GP" && env -u FACTORY_WORKER "$HOOK" >/dev/null 2>&1); then
  ok "no seat identity: operator-shaped commits in the primary pass (fail-open)"
else
  bad "hook operator" "an identity-free primary commit was refused"
fi
for opid in operator claude-operator; do
  if (cd "$GP" && FACTORY_WORKER="$opid" "$HOOK" >/dev/null 2>&1); then
    ok "the '$opid' identity passes"
  else
    bad "hook operator id" "FACTORY_WORKER=$opid was refused"
  fi
done
if (cd "$R/guard-wt" && FACTORY_WORKER=seat-x "$HOOK" >/dev/null 2>&1); then
  ok "a seat committing in its OWN worktree passes (git-dir != common-dir)"
else
  bad "hook worktree" "a seat commit in a linked worktree was refused"
fi
if (cd "$GP" && FACTORY_WORKER=seat-x FACTORY_FORCE=1 "$HOOK" >/dev/null 2>"$R/g2.txt"); then
  ok "FACTORY_FORCE=1 overrides the hook"
else
  bad "hook force" "$(cat "$R/g2.txt")"
fi
printf 'seat-pin-x\n' > "$GP/.factory-worker"
if (cd "$GP" && env -u FACTORY_WORKER "$HOOK" >/dev/null 2>"$R/g3.txt"); then
  bad "hook pin refusal" "a pin-identified primary commit was allowed"
else
  ok "a .factory-worker pin (no env) also refuses"
fi
rm -f "$GP/.factory-worker"
GUARD="$(cd "$HERE" && pwd)/factory_guard.sh"
out="$(cd "$R/guard-wt" && bash -c ". '$GUARD'; FACTORY_WORKER=seat-x factory_primary_guard probe remote" 2>&1 || true)"
case "$out" in
  *"law 8"*) ok "factory_primary_guard refuses a seat's remote deploy (law 8)" ;;
  *) bad "guard remote" "got '$out'" ;;
esac
out="$(cd "$R/guard-wt" && bash -c ". '$GUARD'; env -u FACTORY_WORKER true; factory_primary_guard probe remote && echo PASSED-OPEN" 2>&1 || true)"
case "$out" in
  *PASSED-OPEN*) ok "factory_primary_guard fails open without a seat identity" ;;
  *) bad "guard open" "got '$out'" ;;
esac


if [ "$fail" = "0" ]; then echo "ALL PASSED"; else echo "FAILURES"; exit 1; fi
