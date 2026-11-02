#!/bin/bash
# scripts/fix_icp_keychain_prompts.sh — pre-authorise the icp CLI on a chosen
# set of its keychain items so the launchd bot fleet runs without the
# "icp wants to use your confidential information" dialog.
#
# Why this exists: icp-cli stores private keys with `--storage keyring` by
# default. Each identity becomes a login-keychain item under service
# "icp-cli", and keychain ACLs are per-ITEM, so clicking "Always Allow"
# authorises the calling binary for ONE item — a fleet of N bots prompts N
# times, and the icp npm package's symlinked script path changes on every
# version bump, which silently invalidates path-based grants. The one grant
# that survives version bumps is the PARTITION LIST: a set of code-signing
# partitions any process must match to read the item without a prompt.
#
# What the first version of this helper did, and why it was rewritten (H-01,
# findings F15 + F17 in docs/hardening-plan-2026-09.md):
#   · it ran `security set-generic-password-partition-list … -k "$PASS"` once
#     per identity — 200+ child processes with the LOGIN PASSWORD in each
#     argv, readable via `ps` / KERN_PROCARGS2 by every same-user process;
#   · it granted the `unsigned:` partition — "any binary, signed or not" —
#     on EVERY icp-cli item, including the funded controller/wallet identity
#     that docs/deploy-to-subnet.md §2 names as sole controller, deploy
#     identity, archive owner, LP and insurance holder.
#
# What this version does instead:
#   1. THE PASSWORD IS NEVER AN ARGV ELEMENT. Exactly ONE `security -i`
#      process is spawned (its interactive mode reads commands from stdin);
#      every set-generic-password-partition-list line — password included —
#      is written to that pipe by a printf BUILTIN. Nothing with the password
#      in it is ever exec'd, and nothing is written to disk.
#   2. NO `unsigned:` GRANT. The partition list is
#      `apple-tool:,apple:,teamid:<ID>` where <ID> is the Team ID of the
#      executable that actually presents itself to Keychain Services: the
#      resolved `icp` (command -v, symlinks followed) — or, when that is a
#      script, its shebang INTERPRETER. On this machine `icp` is
#      @icp-sdk/icp-cli's icp.js under `#!/usr/bin/env node`, and the
#      process reading the item is `node`, Developer ID-signed by the Node.js
#      Foundation (Team ID HX7739G8FX) — so that is the partition, and a
#      `node` upgrade keeps working while an unsigned impostor at any path
#      still prompts. If the executable has NO Team ID (unsigned or ad-hoc
#      signed), the helper REFUSES: there is no honest partition narrower
#      than "any binary" for such a binary, and widening to that is exactly
#      the grant this rewrite removes. The fallback then is to install a
#      Developer ID-signed node (nodejs.org builds are) and re-run, or to
#      pass --teamid explicitly for a signed binary you have verified with
#      `codesign -dvv`.
#   3. IDENTITIES ARE AN EXPLICIT ALLOW-LIST. --identity <name> (repeatable);
#      the default is the launchd fleet's own family — every identity named
#      `<target>bot_<n>` (scripts/lib/bots.sh launches each fleet with
#      BOT_PREFIX=<target>bot). The controller/wallet keys — SN_IDENTITY and
#      CE_IDENTITY from scripts/.subnet.conf / scripts/.cloud-engine.conf
#      (resolved through scripts/lib/targets.sh), WALLET (topup.sh's cycles
#      wallet), plus MDX_KEYCHAIN_CONTROLLER_IDENTITIES — are SKIPPED even
#      when named, unless --include-controller is passed. Note for the
#      operator: bots.sh hands the fleet BOT_IDENTITY=<the controller> to
#      fund bots on a remote target, so a launchd-supervised remote fleet
#      may genuinely need the controller item prompt-free too; that is a
#      deliberate --include-controller decision, and it still gets the
#      Team ID partition, never the open one.
#   4. THE CONSEQUENCE IS PRINTED BEFORE ANYTHING IS MUTATED — the resolved
#      executable and Team ID, the partition list, every item that will be
#      touched, every identity skipped and why — and the run proceeds only
#      on a typed "yes" (or --yes). --dry-run prints the exact `security`
#      lines that WOULD be sent, password redacted, and exits.
#
# Usage:
#   bash scripts/fix_icp_keychain_prompts.sh [--dry-run] [--yes]
#        [--identity <name>]… [--include-controller] [--teamid <TEAMID>]
#
# Tested without a real keychain by tests/test_keychain_helper.sh (PATH
# shims for security/icp/codesign); source shape pinned by
# tests/test_deploy_hygiene.sh §3e. Bash 3.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="icp-cli"

die()  { printf '\033[0;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[0;36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '\033[0;31m✗\033[0m %s\n' "$*" >&2; }

usage() {
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Arguments ──────────────────────────────────────────────────────
ALLOW=""                 # explicit allow-list (space-separated)
INCLUDE_CONTROLLER=false
YES=false
DRY_RUN=false
TEAMID_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --identity)           [ $# -ge 2 ] || die "--identity needs a name"; ALLOW="$ALLOW $2"; shift 2 ;;
    --include-controller) INCLUDE_CONTROLLER=true; shift ;;
    --yes)                YES=true; shift ;;
    --dry-run)            DRY_RUN=true; shift ;;
    --teamid)             [ $# -ge 2 ] || die "--teamid needs a Team ID"; TEAMID_OVERRIDE="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)                    usage >&2; die "unknown argument: $1" ;;
  esac
done

# `is_in <word> <space-separated list>`
is_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# An Apple Team ID is exactly ten upper-case alphanumerics — anything else
# (a partition keyword, an empty string, codesign's "not set") is refused
# before it can reach a partition list.
valid_teamid() { printf '%s' "$1" | grep -qE '^[A-Z0-9]{10}$'; }

# ── 1. The executable that will present itself to Keychain Services ─
# Every capture on this path is gated BY NAME (task 1788552433): under
# `set -euo pipefail` a failing `$(resolve_path …)` — a shebang interpreter
# that does not exist, so realpath exits 1 — or a failing `$(head -n 1 …)`
# ended the script with only the tool's own stderr line and none of the
# `die`s below ever spoke; and the perl fallback answers '' with exit 0 for
# the same missing path, which would have reached codesign as "" and been
# refused as "no Team ID" — the wrong diagnosis. So each gate tests the
# status AND the value. (A dangling `icp` symlink never gets this far:
# `command -v` does not report a link whose target is missing, so that case
# is the "icp is not on PATH" die.)
resolve_path() {
  if command -v realpath >/dev/null 2>&1; then realpath "$1"
  else perl -MCwd -e 'print Cwd::abs_path($ARGV[0])' "$1"; fi
}
ICP_CMD=$(command -v icp 2>/dev/null) || die "icp is not on PATH"
ICP_REAL=$(resolve_path "$ICP_CMD") && [ -n "$ICP_REAL" ] || die "cannot resolve the real path of icp at $ICP_CMD (realpath/perl failed or answered nothing) — ICP_REAL=''"
EXEC_PATH="$ICP_REAL"
EXEC_VIA=""
if [ "$(head -c 2 "$ICP_REAL" 2>/dev/null)" = "#!" ]; then
  SHEBANG=$(head -n 1 "$ICP_REAL") || die "cannot read the first line of $ICP_REAL (it answered #! a moment ago — unreadable wrapper?) — SHEBANG=''"
  SHEBANG=${SHEBANG#\#!}
  # shellcheck disable=SC2086
  set -- $SHEBANG
  INTERP="${1:-}"
  if [ "$INTERP" = "/usr/bin/env" ]; then
    [ -n "${2:-}" ] || die "cannot parse the shebang of $ICP_REAL"
    INTERP=$(command -v "$2" 2>/dev/null) || die "shebang interpreter '$2' of $ICP_REAL is not on PATH"
  fi
  [ -n "$INTERP" ] || die "cannot parse the shebang of $ICP_REAL"
  EXEC_PATH=$(resolve_path "$INTERP") && [ -n "$EXEC_PATH" ] || die "cannot resolve the real path of the shebang interpreter $INTERP of $ICP_REAL (missing interpreter? realpath/perl failed or answered nothing) — EXEC_PATH=''"
  EXEC_VIA="script $ICP_REAL, interpreter #!$SHEBANG"
fi

if [ -n "$TEAMID_OVERRIDE" ]; then
  valid_teamid "$TEAMID_OVERRIDE" || die "--teamid '$TEAMID_OVERRIDE' is not a Team ID (ten upper-case alphanumerics); a partition keyword is not accepted here"
  TEAMID="$TEAMID_OVERRIDE"
  TEAMID_SRC="--teamid (operator-supplied; verify with: codesign -dvv $EXEC_PATH)"
else
  CODESIGN=$(codesign -dvv "$EXEC_PATH" 2>&1 || true)
  TEAMID=$(printf '%s\n' "$CODESIGN" | sed -n 's/^TeamIdentifier=//p' | head -1)
  AUTHORITY=$(printf '%s\n' "$CODESIGN" | sed -n 's/^Authority=//p' | head -1)
  if ! valid_teamid "${TEAMID:-}"; then
    bad "the executable that reads the keychain, $EXEC_PATH, has no Team ID (codesign says: ${TEAMID:-unsigned})."
    bad "There is no partition narrower than \"any binary\" for an unsigned or ad-hoc-signed executable, and"
    bad "widening the items to the unsigned partition is exactly the grant this helper no longer makes."
    bad "Install a Developer ID-signed interpreter (nodejs.org builds are signed by the Node.js Foundation)"
    bad "and re-run, or pass --teamid <ID> for a signed binary you have checked with: codesign -dvv <path>"
    exit 1
  fi
  TEAMID_SRC="codesign -dvv $EXEC_PATH${AUTHORITY:+ ($AUTHORITY)}"
fi
PARTITION="apple-tool:,apple:,teamid:$TEAMID"

# ── 2. Identities: the store, the controller set, the allow-list ──
IDS=$(icp identity list 2>/dev/null | awk '{print $1}' | grep -v '^$' | sort -u | tr '\n' ' ' || true)
[ -n "${IDS// /}" ] || die "no icp identities found (icp identity list is empty)"

# Controller/wallet keys: SN_IDENTITY / CE_IDENTITY through targets.sh (which
# sources the gitignored conf files), WALLET (topup.sh), plus an explicit
# extra list. Resolved in a subshell so targets.sh's own settings stay there.
CONTROLLERS=""
if [ -f "$SCRIPT_DIR/lib/targets.sh" ]; then
  CONTROLLERS=$( ( source "$SCRIPT_DIR/lib/targets.sh"; mdx_identity_for subnet; mdx_identity_for engine ) 2>/dev/null | tr '\n' ' ' || true)
fi
CONTROLLERS="$CONTROLLERS ${WALLET:-} ${MDX_KEYCHAIN_CONTROLLER_IDENTITIES:-}"
CONTROLLERS=$(printf '%s\n' $CONTROLLERS | grep -v -e '^$' -e '^anonymous$' | sort -u | tr '\n' ' ' || true)

# The default allow-list: the fleet family `<target>bot_<n>`.
FLEET=""
for id in $IDS; do
  case "$id" in localbot_[0-9]*|enginebot_[0-9]*|subnetbot_[0-9]*) FLEET="$FLEET $id" ;; esac
done
ALLOW_SRC="--identity"
if [ -z "${ALLOW// /}" ]; then
  ALLOW="$FLEET"; ALLOW_SRC="default: the fleet family <target>bot_<n>"
  if [ "$INCLUDE_CONTROLLER" = "true" ]; then ALLOW="$ALLOW $CONTROLLERS"; ALLOW_SRC="$ALLOW_SRC + the controller/wallet keys (--include-controller)"; fi
fi

SELECTED=""; SKIP_CTL=""; SKIP_ABSENT=""; INCLUDED_CTL=""
for id in $ALLOW; do
  is_in "$id" "$SELECTED" && continue
  if ! is_in "$id" "$IDS"; then SKIP_ABSENT="$SKIP_ABSENT $id"; continue; fi
  if is_in "$id" "$CONTROLLERS"; then
    if [ "$INCLUDE_CONTROLLER" = "true" ]; then INCLUDED_CTL="$INCLUDED_CTL $id"
    else SKIP_CTL="$SKIP_CTL $id"; continue; fi
  fi
  SELECTED="$SELECTED $id"
done
# Every controller/wallet key that IS in the store and is NOT being touched is
# reported as skipped — whether it was named, or simply not on the default
# allow-list — so the operator sees the exclusion and the flag that lifts it.
for id in $CONTROLLERS; do
  is_in "$id" "$IDS" || continue
  is_in "$id" "$SELECTED" && continue
  is_in "$id" "$SKIP_CTL" || SKIP_CTL="$SKIP_CTL $id"
done
N_SELECTED=$(printf '%s\n' $SELECTED | grep -c . || true)
N_IDS=$(printf '%s\n' $IDS | grep -c . || true)

# ── 3. The consequence, before anything is touched ─────────────────
echo
info "executable that reads the keychain: $EXEC_PATH${EXEC_VIA:+  ($EXEC_VIA)}"
info "Team ID: $TEAMID  — from: $TEAMID_SRC"
info "partition list to set on each item: $PARTITION"
info "identities: $N_IDS in the icp store; allow-list from $ALLOW_SRC"
if [ -n "${SKIP_CTL// /}" ]; then
  info "SKIPPED — controller/wallet keys (SN_IDENTITY / CE_IDENTITY / WALLET; pass --include-controller to opt in):$SKIP_CTL"
fi
if [ -n "${INCLUDED_CTL// /}" ]; then
  info "INCLUDED controller/wallet keys (--include-controller):$INCLUDED_CTL"
fi
if [ -n "${SKIP_ABSENT// /}" ]; then
  info "SKIPPED — not in \`icp identity list\`:$SKIP_ABSENT"
fi
UNTOUCHED=$(( N_IDS - N_SELECTED ))
info "untouched: $UNTOUCHED identit$( [ "$UNTOUCHED" = 1 ] && echo y || echo ies ) not on the allow-list (their items keep whatever ACL they have)"
info "keychain items to update (service \"$SERVICE\", login keychain): $N_SELECTED"
info "security lines that will be sent to ONE \`security -i\` over stdin (password redacted):"
for id in $SELECTED; do
  printf '    set-generic-password-partition-list -S "%s" -k "<redacted>" -s "%s" -a "%s"\n' "$PARTITION" "$SERVICE" "$id"
done
[ "$N_SELECTED" -gt 0 ] || die "nothing to do: no selectable identity (see the skips above)"

if [ "$DRY_RUN" = "true" ]; then
  echo
  ok "dry run — nothing was sent to security, no password was read"
  exit 0
fi

if [ "$YES" != "true" ]; then
  echo
  printf 'Type yes to apply the %s update(s) above: ' "$N_SELECTED"
  ANSWER=""
  IFS= read -r ANSWER || true
  [ "$ANSWER" = "yes" ] || die "not confirmed — nothing was changed"
fi

# ── 4. The password, read once, escaped for security -i's line parser ─
# `-k` on a set-generic-password-partition-list line is the login-keychain
# password: the item's ACL cannot be rewritten while the keychain is locked.
# The line goes over the pipe, so the password is never in any argv.
PASS=""
IFS= read -r -s -p "macOS login password (will not echo): " PASS || true
echo
[ -n "$PASS" ] || die "aborted: no password supplied"
# Backslash and double quote are the two characters the interactive parser
# treats specially inside a double-quoted token.
PASS_ESC=$(printf '%s' "$PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')

LINES=""
for id in $SELECTED; do
  ID_ESC=$(printf '%s' "$id" | sed 's/\\/\\\\/g; s/"/\\"/g')
  LINES="${LINES}set-generic-password-partition-list -S \"$PARTITION\" -k \"$PASS_ESC\" -s \"$SERVICE\" -a \"$ID_ESC\"
"
done

# ── 5. One security -i process; success attributed per item ─────────
# `security -i` exits 0 even when a command inside fails, so the verdict
# comes from its output: a successful update dumps the item (its "acct"
# attribute names the identity); a failure prints `<cmd>: returned <code>`.
SEC_RC=0
OUTPUT=$(printf '%s' "$LINES" | security -i 2>&1) || SEC_RC=$?
PASS=""; PASS_ESC=""; LINES=""
DONE_IDS=$(printf '%s\n' "$OUTPUT" | sed -n 's/^[[:space:]]*"acct"<blob>="\(.*\)"$/\1/p' | sort -u | tr '\n' ' ')
ERRORS=$(printf '%s\n' "$OUTPUT" | grep -E 'returned [-0-9]+|^security: ' || true)

echo
N_DONE=0; N_FAIL=0
for id in $SELECTED; do
  if is_in "$id" "$DONE_IDS"; then ok "$id"; N_DONE=$((N_DONE+1))
  else bad "$id — not updated"; N_FAIL=$((N_FAIL+1)); fi
done
if [ -n "$ERRORS" ]; then
  echo "security reported:" >&2
  printf '%s\n' "$ERRORS" | sed 's/^/    /' >&2
fi
echo
echo "Updated $N_DONE / $N_SELECTED keychain items (partition: $PARTITION)."
if [ "$N_FAIL" -gt 0 ] || [ "$SEC_RC" -ne 0 ]; then
  die "$N_FAIL item(s) not updated (security -i exit $SEC_RC) — a wrong login password fails every item; an item with no keychain entry (an identity stored as plaintext, or created under another ICP_HOME) fails on its own"
fi
echo "Try 'icp identity principal --identity <one of them>' now — the dialog should not appear for a signed $EXEC_PATH."
