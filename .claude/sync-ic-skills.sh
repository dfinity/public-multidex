#!/usr/bin/env bash
# sync-ic-skills.sh — mirror the latest Internet Computer skills into .claude/skills/
#
# Differential sync: fetches the discovery index once and re-downloads only the
# skills whose published `hash` changed (or are new). Skills already at the current
# hash are skipped entirely — no per-file downloads. Prints a one-line summary only
# when something actually changed.
#
# Idempotent and offline-safe. Only skills this script installed are ever pruned,
# so your own local skills are never touched.
#
# H-03 (F7, 2026-09-04): the manifest is the ONLY authority over what this
# script may replace or prune. A name the remote index carries is INSTALLED only
# when $DEST/<name> is absent or was installed by this script (listed in the
# manifest); an existing directory the manifest does not list — a skill the
# repo owns, or anything else someone put there — is never moved aside,
# replaced, recorded or pruned, whatever the index says. Git-tracked paths
# under $DEST (the repo's own guardrail skills, .gitignore's exceptions) are
# refused even when a poisoned manifest names them. The mirror's fetches are
# pinned to the origin: https only, redirects may not leave $BASE. SYNC_BASE
# overrides the origin for OFFLINE fixtures (file:///…) — tests only; the
# hygiene suite (tests/test_deploy_hygiene.sh §3f) drives every refusal.
set -euo pipefail

BASE="${SYNC_BASE:-https://skills.internetcomputer.org/.well-known/skills}"
BASE="${BASE%/}"
case "$BASE" in
  https://*) PROTO="https" ;;
  file:///*) PROTO="file" ;;   # offline fixture tree (tests); never a network scheme
  *) echo "[autosync-ic-skills] SYNC_BASE must be https://… or file:///… (got: $BASE) — keeping cached skills" >&2; exit 0 ;;
esac
INDEX_URL="$BASE/index.json"
DEST=".claude/skills"
MANIFEST="$DEST/.ic-managed.json"   # { "<skill>": "<hash>" } of skills this script manages

mkdir -p "$DEST"

# --- Temp files. NEW_MANIFEST is built up as we go, then swapped in atomically.
#     STAGING holds the skill dir currently being downloaded, so the trap can
#     remove a half-written skill if the run is interrupted. ---
TMP_INDEX="$(mktemp)"
NEW_MANIFEST="$(mktemp)"
STAGING=""
trap 'rm -f "$TMP_INDEX" "$NEW_MANIFEST"; [ -n "$STAGING" ] && rm -rf "$STAGING"' EXIT

# Remove any staging dirs left by a previously interrupted run — an in-progress
# download is always safe to discard. (.old-* backups are handled by the recovery
# step below, which never deletes one that is still the only copy of a skill.)
rm -rf "${DEST:?}"/.staging-* 2>/dev/null || true

# --- Path-safety guards. `name` and `f` come from the remote index and flow into
#     rm -rf / mv / file writes, so reject anything that could escape $DEST. ---
is_safe_name() {   # a flat skill slug: non-empty, no slash, no ".."
  case "$1" in
    ""|.|..|*/*|*..*) return 1 ;;
    *) return 0 ;;
  esac
}
is_safe_relpath() {  # a file path within a skill: subdirs ok, but not absolute or ".."
  case "$1" in
    ""|/*|*..*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- Ownership guards (H-03). `is_tracked` asks git whether anything under
#     $DEST/<name> is committed — the repo's own skills are, the mirror never is
#     (.gitignore). Outside a git checkout, or without git, it answers "no" and
#     the manifest guard below still applies: unknown directories are refused,
#     tracked ones are refused twice. ---
is_tracked() {   # is_tracked <name>: 0 iff git tracks a file under $DEST/<name>
  git ls-files --error-unmatch -- "$DEST/$1" >/dev/null 2>&1
}
is_managed() {   # is_managed <name>: 0 iff the CURRENT manifest lists <name>
  grep -qxF -- "$1" <<<"$MANAGED"
}

# --- Origin-pinned fetch. The scheme is the one $BASE carries (https, or file
#     for offline fixtures) — nothing else, on the first hop or after a
#     redirect — and the URL curl ends up at must still sit under $BASE: a
#     redirect that leaves the origin discards the download and fails the fetch. ---
fetch() {   # fetch <url> <out-file>
  local eff
  if ! eff="$(curl -fsSL --max-time 20 --proto "=$PROTO" --proto-redir "=$PROTO" \
              -w '%{url_effective}' -o "$2" -- "$1")"; then
    rm -f "$2"; return 1
  fi
  case "$eff" in
    "$BASE"/*) return 0 ;;
  esac
  echo "[autosync-ic-skills] warning: $1 redirected off-origin to $eff — discarded" >&2
  rm -f "$2"
  return 1
}

# --- Recover from a run interrupted mid-swap. A `.old-<name>.<pid>` dir is the
#     previous good copy of <name>, moved aside just before its swap. If that swap
#     never finished (the skill dir is now missing), restore it; otherwise it is
#     stale and safe to drop. This runs BEFORE the index fetch, so an interrupted
#     skill is restored even on an offline run — keeping the cached copy available. ---
for backup in "$DEST"/.old-*; do
  [ -e "$backup" ] || continue                 # unmatched glob stays literal — skip
  bname="$(basename "$backup")"; bname="${bname#.old-}"; bname="${bname%.*}"
  if is_safe_name "$bname" && [ ! -e "$DEST/$bname" ]; then
    mv "$backup" "$DEST/$bname"
    echo "[autosync-ic-skills] recovered '$bname' from an interrupted sync" >&2
  else
    rm -rf "$backup"
  fi
done

# --- Fetch the index. On any network failure, keep cached skills and exit cleanly. ---
if ! fetch "$INDEX_URL" "$TMP_INDEX"; then
  echo "[autosync-ic-skills] could not reach $INDEX_URL — keeping cached skills" >&2
  exit 0
fi

# --- jq is required to parse the index. If absent, warn and exit without failing. ---
if ! command -v jq >/dev/null 2>&1; then
  echo "[autosync-ic-skills] 'jq' not found — install jq to enable IC skill sync" >&2
  exit 0
fi

# --- Previously-managed skill names. Supports the legacy manifest format
#     (a bare array of names, no hashes) as well as the current object form. ---
managed_names() {
  [ -f "$MANIFEST" ] || return 0
  jq -r 'if type == "object" then keys[] elif type == "array" then .[] else empty end' \
    "$MANIFEST" 2>/dev/null || true
}

# --- Stored hash for a skill, or empty if unknown (new skill, or legacy manifest). ---
stored_hash() {
  [ -f "$MANIFEST" ] || return 0
  jq -r --arg n "$1" 'if type == "object" then (.[$n] // "") else "" end' \
    "$MANIFEST" 2>/dev/null || true
}

# --- Append a name->hash pair to the new manifest being built. ---
record() {
  local tmp; tmp="$(mktemp)"
  jq --arg n "$1" --arg h "$2" '.[$n] = $h' "$NEW_MANIFEST" > "$tmp" && mv "$tmp" "$NEW_MANIFEST"
}

NEW_NAMES="$(jq -r '.skills[].name' "$TMP_INDEX")"
MANAGED="$(managed_names)"
echo '{}' > "$NEW_MANIFEST"

# --- Prune: drop previously-managed skills that are no longer in the index.
#     A git-tracked name is never pruned even if the manifest lists it (a
#     manifest is a plain file; the repo's own skills are not its to give). ---
removed=0; refused=0
while IFS= read -r old; do
  [ -n "$old" ] || continue
  is_safe_name "$old" || { echo "[autosync-ic-skills] skipping unsafe managed name: $old" >&2; continue; }
  if ! grep -qxF "$old" <<<"$NEW_NAMES"; then
    if is_tracked "$old"; then
      refused=$((refused + 1))
      echo "[autosync-ic-skills] refused to prune '$old': git-tracked (repo-owned), dropped from the manifest instead" >&2
      continue
    fi
    rm -rf "${DEST:?}/$old"
    removed=$((removed + 1))
    echo "[autosync-ic-skills] removed: $old" >&2
  fi
done <<<"$MANAGED"

# --- Sync: download only skills whose hash changed (new / hashless always download). ---
added=0; updated=0; unchanged=0
while IFS= read -r entry; do
  name="$(jq -r '.name' <<<"$entry")"
  [ -n "$name" ] && [ "$name" != "null" ] || continue
  is_safe_name "$name" || { echo "[autosync-ic-skills] skipping skill with unsafe name: $name" >&2; continue; }
  new_hash="$(jq -r '.hash // ""' <<<"$entry")"
  old_hash="$(stored_hash "$name")"

  # H-03: the index has no authority over a directory this script did not
  # install. Refuse — before any download, without recording — when the name
  # is git-tracked (repo-owned, whatever the manifest says) or when $DEST/$name
  # already exists and the manifest does not list it. The manifest is rebuilt
  # from what is recorded, so a refused name also leaves the manifest.
  if is_tracked "$name"; then
    refused=$((refused + 1))
    echo "[autosync-ic-skills] refused to install '$name': git-tracked (repo-owned) — the index does not get to replace it" >&2
    continue
  fi
  if [ -e "$DEST/$name" ] && ! is_managed "$name"; then
    refused=$((refused + 1))
    echo "[autosync-ic-skills] refused to install '$name': $DEST/$name exists and was not installed by this script — left untouched" >&2
    continue
  fi

  # Skip when the hash is known, unchanged, and the files are already on disk.
  if [ -n "$new_hash" ] && [ "$new_hash" = "$old_hash" ] && [ -d "$DEST/$name" ]; then
    unchanged=$((unchanged + 1))
    record "$name" "$new_hash"
    continue
  fi

  # Otherwise download this skill into a fresh staging dir, then swap it in
  # atomically. A clean staging dir means an intra-skill file rename or removal
  # leaves no orphaned files behind, and a mid-download failure keeps the existing
  # copy intact — the swap happens only after every file downloaded successfully.
  ok=1
  STAGING="$(mktemp -d "${DEST}/.staging-${name}.XXXXXX")"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! is_safe_relpath "$f"; then
      echo "[autosync-ic-skills] warning: unsafe file path in $name: $f — skipping skill" >&2
      ok=0
      break
    fi
    mkdir -p "$(dirname "$STAGING/$f")"   # files may live in subdirs (e.g. scripts/)
    if ! fetch "$BASE/$name/$f" "$STAGING/$f"; then
      echo "[autosync-ic-skills] warning: failed to fetch $name/$f" >&2
      ok=0
      break
    fi
  done < <(jq -r '.files[]?' <<<"$entry")

  if [ "$ok" -eq 1 ]; then
    # Swap in the fresh copy. Move any existing dir aside first, move the new one
    # into place, and only then drop the old copy — so a failed swap restores the
    # existing copy intact, while files removed or renamed upstream don't survive.
    backup=""
    if [ -e "$DEST/$name" ]; then
      backup="${DEST}/.old-${name}.$$"
      rm -rf "$backup"
      mv "$DEST/$name" "$backup"
    fi
    if mv "$STAGING" "$DEST/$name"; then
      STAGING=""
      [ -n "$backup" ] && rm -rf "$backup"
      # Record the new hash so the next run can skip this skill. A hashless server
      # records an empty hash, which never equals new_hash -> always re-downloads.
      record "$name" "$new_hash"
      if grep -qxF "$name" <<<"$MANAGED"; then
        updated=$((updated + 1))
      else
        added=$((added + 1))
      fi
    else
      # Swap failed: restore any existing copy and retry on the next run.
      echo "[autosync-ic-skills] warning: failed to install $name — kept any existing copy; will retry next run" >&2
      [ -n "$backup" ] && mv "$backup" "$DEST/$name"
      rm -rf "$STAGING"
      STAGING=""
      record "$name" "$old_hash"
    fi
  else
    # Download incomplete: discard the staging dir, keep the existing skill dir
    # untouched, and keep the old hash so the next run retries this skill.
    rm -rf "$STAGING"
    STAGING=""
    record "$name" "$old_hash"
  fi
done < <(jq -c '.skills[]' "$TMP_INDEX")

# --- Swap in the updated manifest. ---
mv "$NEW_MANIFEST" "$MANIFEST"

# --- Report only when something changed; stay silent on a no-op sync. ---
# SessionStart hook stdout/stderr is NOT shown in the Claude Code UI — only JSON
# fields are surfaced. We emit a single JSON object on stdout:
#   - systemMessage    -> rendered to the USER as a visible system notice
#   - additionalContext -> injected into Claude's context so it can mention it too
#   A refusal (H-03) is reported too — an index naming a directory this script
#   does not own is exactly the event the operator should see — without a
#   skills reload, since nothing on disk changed for it.
if [ $((added + updated + removed + refused)) -gt 0 ]; then
  summary="[autosync-ic-skills] ${added} added, ${updated} updated, ${removed} removed, ${refused} refused (${unchanged} unchanged) in $DEST"
  reload=false; [ $((added + updated + removed)) -gt 0 ] && reload=true
  jq -n --arg msg "$summary" --argjson reload "$reload" '{
    systemMessage: $msg,
    hookSpecificOutput: {
      reloadSkills: $reload,
      hookEventName: "SessionStart",
      additionalContext: $msg
    }
  }'
fi
