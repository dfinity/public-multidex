#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# factory-selftest.sh - exercise scripts/factory.sh against a THROWAWAY queue.
#
# The real queue coordinates every consumer seat at once, so it is the last
# place to try a change out. FACTORY_TASKS_ROOT points factory.sh at a temp
# directory instead, and FACTORY_PRIMARY points the merge gate at a temp git
# repo; nothing here touches tasks/ or the real checkout.
#
# Run it by hand after changing factory.sh:  bash scripts/factory-selftest.sh
# Not wired into run_all: it is a developer harness, not a deploy gate.
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
F="${1:-$HERE/factory.sh}"
R="$(mktemp -d)"
export FACTORY_TASKS_ROOT="$R"
trap 'rm -rf "$R"' EXIT

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
mk operator "subnet rollout A"
mk operator "subnet rollout B"
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
if grep -q "subnet rollout" "$out" 2>/dev/null; then ok "--operator claimed a lane task"; else bad "--operator content" "got '$out'"; fi

echo "== list filters =="
# plain grep (not -q): -q exits at the first match, and under pipefail the
# writer's SIGPIPE (141) would fail the pipeline once list prints more lines
# after the match.
if "$F" list | grep '\[operator\]' >/dev/null; then ok "list marks lane tasks"; else bad "list marker" "$("$F" list)"; fi
if [ "$("$F" list --consumer | grep -c 'subnet rollout')" = "0" ]; then ok "list --consumer hides the lane"; else bad "list --consumer" "$("$F" list --consumer)"; fi
if [ "$("$F" list --operator | grep -c 'subnet rollout')" = "1" ]; then ok "list --operator shows only the lane"; else bad "list --operator" "$("$F" list --operator)"; fi

echo "== board =="
b="$("$F" index)"
if grep -q '^## Operator lane' "$b"; then ok "board has an operator-lane section"; else bad "board section" "$(grep '^##' "$b")"; fi
if sed -n '/^## Queue/,/^## Operator lane/p' "$b" | grep -q "subnet rollout"; then
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
mkT backend "affinity backend one" >/dev/null
p_fe="$(mkT frontend "affinity frontend one")"
mkT backend "affinity backend two" >/dev/null
out="$("$F" claim seat-aff --affinity frontend)"
if grep -q "affinity frontend one" "$out" 2>/dev/null; then ok "affinity picks the matching task over the head"; else bad "affinity match" "got '$out'"; fi
if grep -q "(affinity)" "$out" 2>/dev/null; then ok "affinity pick is stamped"; else bad "affinity stamp" "$(tail -3 "$out")"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-af2 --affinity verifier)"
if grep -q "affinity backend one" "$out" 2>/dev/null; then ok "no match falls back to the plain head"; else bad "affinity fallback" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
# never cross bands: promote the backend task above a matching frontend task
p_two="$("$F" list --consumer | grep "affinity backend two" | head -1)"
id_two="${p_two%%.md*}"; id_two="${id_two#*-}"
mkT frontend "affinity frontend two" >/dev/null
"$F" reprioritize "$id_two" 05 >/dev/null
out="$("$F" claim seat-af3 --affinity frontend)"
if grep -q "affinity backend two" "$out" 2>/dev/null; then ok "affinity never crosses into a lower band"; else bad "band ceiling" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null
out="$("$F" claim seat-af4 --affinity frontend)"
if grep -q "affinity frontend two" "$out" 2>/dev/null; then ok "the frontend task is next once the band clears"; else bad "band drain" "got '$out'"; fi
id="$(basename "$out" .md)"; id="${id#*-}"; "$F" done "$id" done >/dev/null

echo "== targeted operator claim (--id): the safe-edit tweezers =="
p_t="$(mkT tests "targeted answer me")"
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
mo_body() {  # mo_body <posture>
  echo "  // transient let DEPLOY_MODE : DeployMode = #production  (decoy in a comment)"
  echo "  transient let DEPLOY_MODE : DeployMode = #$1;"
}
mo_body play > "$PG/src/backend/main.mo"
mo_body play > "$PG/src/bridge/main.mo"
printf 'networks:\n  local:\n    gateway: {}\n' > "$PG/icp.yaml"
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
if "$F" merge-lock acquire seat-nonbranch >/dev/null 2>"$R/pgerr4.txt"; then
  ok "a non-branch label acquires (gate skipped)"
  "$F" merge-lock release seat-nonbranch >/dev/null
else
  bad "non-branch skip" "$(cat "$R/pgerr4.txt")"
fi
if grep -q "gate skipped" "$R/pgerr4.txt"; then ok "the skip is loud"; else bad "skip message" "$(cat "$R/pgerr4.txt")"; fi
unset FACTORY_PRIMARY

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
echo "== spawn-successor: project-prefixed session names =="
printf 'cd %s && claude\n\n## Boot prompt\n\nYou are a TaskConsumer in executor mode. Work the queue.\n' "$wtd" > "$R/handoff/seat-nm.md"
out="$(FACTORY_PROJECT=fakeproj FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
if printf '%s' "$out" | grep -q "session name: fakeproj-executor-seat-nm"; then
  ok "FACTORY_PROJECT sets the prefix and an executor prompt gets <prefix>-executor-<seat>"
else
  bad "spawn name env" "got '$out'"
fi
printf 'cd %s && claude\n\n## Boot prompt\n\nRead the skill. Take over the seat.\n' "$wtd" > "$R/handoff/seat-nm.md"
out="$(FACTORY_PROJECT=fakeproj FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
if printf '%s' "$out" | grep -q "session name: fakeproj-worker-seat-nm"; then
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
echo "== spawn-successor: zero-residue window =="
out="$(FACTORY_SPAWN_DRYRUN=1 "$F" spawn-successor seat-nm 2>&1)"
if printf '%s' "$out" | grep -q '; exit 0'; then
  ok "the spawned command ends '; exit 0' (shell exits cleanly even when claude dies by signal)"
else
  bad "spawn exit suffix" "got '$out'"
fi
if printf '%s' "$out" | grep -q 'settings set "Factory"' && printf '%s' "$out" | grep -q 'on error'; then
  ok "the program applies the Factory settings set inside try/on error (graceful degrade without it)"
else
  bad "spawn settings set" "got '$out'"
fi
rm -rf "$wtd" "$R/handoff/seat-cli.md" "$R/handoff/seat-old.md" "$R/handoff/seat-nm.md"

echo "== new refuses unknown after: gates =="
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

echo "== operator signals are the control channel seats already poll =="
# A signal must (a) wake a parked watch at once, (b) refuse the addressee's next
# claim until it is acknowledged, (c) as all.md, refuse EVERY seat's, and (d)
# never touch a seat it is not addressed to. Cross-session messages did none of
# those (upstream postmortem 2026-08-19).
"$F" watch 90 > "$R/watch.out" 2>/dev/null &
w_pid=$!
sleep 2
"$F" signal seat-sig "stop claiming; hand off to your successor" >/dev/null
wait "$w_pid"
if [ "$(cat "$R/watch.out")" = "CHANGED" ]; then ok "a signal wakes a parked watch"; else bad "watch wake" "got '$(cat "$R/watch.out")'"; fi
out="$("$F" signal-list)"
if printf '%s' "$out" | grep -q "^seat-sig	"; then ok "signal-list shows the pending order"; else bad "signal-list" "got '$out'"; fi
mkT tests "work behind a signal" >/dev/null
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

if [ "$fail" = "0" ]; then echo "ALL PASSED"; else echo "FAILURES"; exit 1; fi
