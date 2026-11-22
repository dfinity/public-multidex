#!/bin/bash
# tests/test_keychain_helper.sh — argv-hygiene self-test for
# scripts/fix_icp_keychain_prompts.sh (H-01 · findings F15 + F17).
#
# STATIC — no replica, no venue, and NEVER a real keychain. The helper is run
# against a PATH shim directory holding a fake `security` (logs its argv and
# its stdin to files, emulates the item dump `security -i` prints on success),
# a fake `icp` (a canned identity list) and a fake `codesign` (a canned Team
# ID, or "not set" for the unsigned case). Every assertion is about what the
# helper SENT, read back from those logs.
#
# What it pins, and why each one is here:
#
#   1. THE PASSWORD IS NEVER AN ARGV ELEMENT (F15). The old helper spawned one
#      `security … -k "$PASS"` per identity: 200+ children with the login
#      password in argv, readable via ps / KERN_PROCARGS2 by any same-user
#      process. Now exactly ONE `security -i` process is spawned and every
#      command line — password included — travels over its stdin.
#
#   2. NO `unsigned:` PARTITION (F17). That grant lifts the code-signature
#      gate on the item for ANY binary. The partition is the resolved icp
#      executable's Team ID (`teamid:<ID>`); an unsigned / ad-hoc executable
#      is REFUSED at runtime — the helper exits non-zero and sends nothing.
#
#   3. IDENTITIES ARE AN ALLOW-LIST; CONTROLLER KEYS ARE OPT-IN. The default
#      set is the launchd fleet's `<target>bot_N` family (scripts/lib/bots.sh
#      launches every fleet with BOT_PREFIX=<target>bot). SN_IDENTITY,
#      CE_IDENTITY and WALLET — the funded controller/wallet keys — are
#      skipped unless --include-controller is passed, even when named
#      explicitly with --identity.
#
#   4. THE CONSEQUENCE IS PRINTED BEFORE ANYTHING IS MUTATED. --dry-run
#      prints the exact `security` lines (password redacted) and spawns
#      nothing; without --yes the helper asks, and anything but "yes" aborts
#      with nothing spawned.
#
# Uses _lib.sh's _ok/_fail counters (and its private scratch dir) but its
# own verdict — like test_deploy_hygiene.sh, it never calls finish_test.

source "$(dirname "$0")/_lib.sh"

ROOT="$SCRIPT_DIR"
cd "$ROOT" || exit 1

echo "── test_keychain_helper ──"

HELPER="$ROOT/scripts/fix_icp_keychain_prompts.sh"
[ -f "$HELPER" ] || { _fail "helper missing at $HELPER"; exit 1; }

# ── The shim directory (private per-run scratch, H-04) ────────────
SHIM="$TEST_SCRATCH/shim"
LOGS="$TEST_SCRATCH/logs"
mkdir -p "$SHIM" "$LOGS"

# A password with a space, a double quote and a backslash — the characters
# the helper has to escape for `security -i`'s line parser.
PW='Hunter2 "zq\x'

# The canned identity list: the launchd fleet's two targets, the (fake)
# controller/wallet keys, an ordinary developer identity.
CANNED_IDS='subnetbot_1 subnetbot_2 enginebot_1 subnet-ctl engine-ctl wallet-ctl alice'

cat > "$SHIM/icp" <<'EOF'
#!/bin/bash
# fake icp: only `identity list` is answered (name + a fake principal per line,
# the real CLI's two-column shape).
if [ "${1:-}" = "identity" ] && [ "${2:-}" = "list" ]; then
  for n in $KC_SHIM_IDS; do printf '  %s aaaaa-aa\n' "$n"; done
  exit 0
fi
echo "fake icp: unexpected invocation: $*" >&2
exit 97
EOF

cat > "$SHIM/codesign" <<'EOF'
#!/bin/bash
# fake codesign: the -dvv shape, with a canned TeamIdentifier.
printf 'ARGV:' >> "$KC_SHIM_LOG/codesign.argv"; for a in "$@"; do printf ' [%s]' "$a" >> "$KC_SHIM_LOG/codesign.argv"; done; printf '\n' >> "$KC_SHIM_LOG/codesign.argv"
if [ "$KC_SHIM_TEAMID" = "not set" ]; then
  printf 'Executable=%s\nIdentifier=fake\nFormat=Mach-O thin (arm64)\nCodeDirectory v=20400 size=1 flags=0x2(adhoc) hashes=1+2 location=embedded\nSignature=adhoc\nTeamIdentifier=not set\n' "${!#}" >&2
else
  printf 'Executable=%s\nIdentifier=node\nFormat=Mach-O thin (arm64)\nAuthority=Developer ID Application: Fake Foundation (%s)\nTeamIdentifier=%s\n' "${!#}" "$KC_SHIM_TEAMID" "$KC_SHIM_TEAMID" >&2
fi
exit 0
EOF

cat > "$SHIM/security" <<'EOF'
#!/bin/bash
# fake security: log argv (one line per spawn) and stdin (verbatim), then
# emulate `security -i`: for every set-generic-password-partition-list line,
# print the item dump the real tool prints on success (the helper attributes
# success per account from the "acct" attribute line).
printf 'ARGV:' >> "$KC_SHIM_LOG/security.argv"; for a in "$@"; do printf ' [%s]' "$a" >> "$KC_SHIM_LOG/security.argv"; done; printf '\n' >> "$KC_SHIM_LOG/security.argv"
if [ "${1:-}" = "-i" ]; then
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$KC_SHIM_LOG/security.stdin"
    case "$line" in
      set-generic-password-partition-list*)
        acct=$(printf '%s\n' "$line" | sed -n 's/.* -a "\([^"]*\)".*/\1/p')
        printf 'keychain: "/fake/login.keychain-db"\nversion: 256\nclass: "genp"\nattributes:\n    "acct"<blob>="%s"\n    "svce"<blob>="icp-cli"\n' "$acct" ;;
    esac
  done
fi
exit 0
EOF
chmod +x "$SHIM/icp" "$SHIM/codesign" "$SHIM/security"

# One run of the helper under the shims. Args: <tag> <stdin-text> [helper args…]
# Leaves $LOGS/<tag>.out (stdout+stderr), $LOGS/<tag>.rc and the shim logs
# under $LOGS/<tag>/.
run_helper() {
  local tag="$1" input="$2"; shift 2
  local d="$LOGS/$tag"; mkdir -p "$d"
  set +e
  printf '%s' "$input" | env PATH="$SHIM:$PATH" KC_SHIM_LOG="$d" KC_SHIM_IDS="$CANNED_IDS" \
      KC_SHIM_TEAMID="${KC_TEAMID:-FAKETEAM01}" \
      SN_IDENTITY="subnet-ctl" CE_IDENTITY="engine-ctl" WALLET="wallet-ctl" \
      MDX_KEYCHAIN_CONTROLLER_IDENTITIES="subnet-ctl engine-ctl" \
      bash "$HELPER" "$@" > "$d/out" 2>&1
  echo $? > "$d/rc"
  set -e
}
out()       { cat "$LOGS/$1/out"; }
rc()        { cat "$LOGS/$1/rc"; }
argv_log()  { [ -f "$LOGS/$1/security.argv" ] && cat "$LOGS/$1/security.argv" || true; }
stdin_log() { [ -f "$LOGS/$1/security.stdin" ] && cat "$LOGS/$1/security.stdin" || true; }
spawns()    { argv_log "$1" | grep -c '^ARGV:' || true; }

has()   { if printf '%s\n' "$2" | grep -cF -- "$3" >/dev/null; then _ok "$1"; else _fail "$1 — expected to find: $3"; fi; }
lacks() { if printf '%s\n' "$2" | grep -cF -- "$3" >/dev/null; then _fail "$1 — found: $3"; printf '%s\n' "$2" | grep -nF -- "$3" | head -3 | sed 's/^/      /' >&2; else _ok "$1"; fi; }

# ── 1. --dry-run: the consequence, the exact lines, nothing spawned ──
echo "  [1] --dry-run prints the consequence and spawns nothing"
run_helper dry "" --dry-run
[ "$(rc dry)" = "0" ] && _ok "dry-run exits 0" || { _fail "dry-run exit $(rc dry)"; out dry | sed 's/^/      /' >&2; }
[ "$(spawns dry)" = "0" ] && _ok "dry-run spawns no security process" || _fail "dry-run spawned security $(spawns dry) time(s)"
DRY=$(out dry)
has   "dry-run names the partition list with the executable's Team ID"  "$DRY" 'apple-tool:,apple:,teamid:FAKETEAM01'
lacks "dry-run's partition list carries no unsigned grant"              "$DRY" 'unsigned'
has   "dry-run prints the exact security -i command line"               "$DRY" 'set-generic-password-partition-list -S "apple-tool:,apple:,teamid:FAKETEAM01" -k "<redacted>" -s "icp-cli" -a "subnetbot_1"'
has   "dry-run's default allow-list is the fleet family (subnetbot_2)"   "$DRY" '-a "subnetbot_2"'
has   "dry-run's default allow-list is the fleet family (enginebot_1)"   "$DRY" '-a "enginebot_1"'
lacks "dry-run's default allow-list leaves alice alone"                  "$DRY" '-a "alice"'
lacks "dry-run never sends the controller key (SN_IDENTITY)"            "$DRY" '-a "subnet-ctl"'
lacks "dry-run never sends the controller key (CE_IDENTITY)"            "$DRY" '-a "engine-ctl"'
lacks "dry-run never sends the wallet key (WALLET)"                     "$DRY" '-a "wallet-ctl"'
has   "dry-run lists the skipped controller key with its reason"        "$DRY" 'subnet-ctl'
has   "dry-run states the skip reason (controller, --include-controller)" "$DRY" '--include-controller'
lacks "dry-run never prints the real password (there is none to print)" "$DRY" "$PW"

# ── 2. A confirmed run: one security -i, password on stdin only ──
echo "  [2] confirmed run: ONE security -i process, the password only ever on its stdin"
run_helper yes "$PW"$'\n' --yes --identity subnetbot_1 --identity subnetbot_2
[ "$(rc yes)" = "0" ] && _ok "run exits 0" || { _fail "run exit $(rc yes)"; out yes | sed 's/^/      /' >&2; }
[ "$(spawns yes)" = "1" ] && _ok "exactly ONE security process was spawned" || _fail "security spawned $(spawns yes) time(s) (want 1)"
ARGV=$(argv_log yes)
has   "the one security process is the interactive reader (-i)"        "$ARGV" '[-i]'
lacks "the password is in NO security argv"                             "$ARGV" "$PW"
lacks "-k is never an argv element"                                     "$ARGV" '[-k]'
lacks "no argv carries a partition list at all"                         "$ARGV" 'apple-tool'
STDIN=$(stdin_log yes)
has   "the password travels over stdin (escaped for the line parser)"   "$STDIN" '-k "Hunter2 \"zq\\x"'
has   "stdin carries the partition list with the Team ID"               "$STDIN" '-S "apple-tool:,apple:,teamid:FAKETEAM01"'
lacks "stdin carries no unsigned grant"                                 "$STDIN" 'unsigned'
has   "stdin addresses the icp-cli service"                             "$STDIN" '-s "icp-cli"'
has   "stdin carries subnetbot_1"                                       "$STDIN" '-a "subnetbot_1"'
has   "stdin carries subnetbot_2"                                       "$STDIN" '-a "subnetbot_2"'
lacks "stdin does not carry enginebot_1 (not in the explicit allow-list)" "$STDIN" '-a "enginebot_1"'
lacks "stdin never carries a controller key"                            "$STDIN" 'ctl"'
[ "$(printf '%s\n' "$STDIN" | grep -c '^set-generic-password-partition-list')" = "2" ] \
  && _ok "exactly two partition-list commands were sent" || _fail "sent $(printf '%s\n' "$STDIN" | grep -c '^set-generic-password-partition-list') commands (want 2)"
OUT=$(out yes)
lacks "the helper's own output never echoes the password"              "$OUT" "$PW"
has   "the helper reports the per-item outcome"                         "$OUT" 'subnetbot_1'
has   "the helper reports the success count"                            "$OUT" '2 / 2'

# ── 3. Controller keys: excluded when named, included only with the flag ──
echo "  [3] controller keys are skipped even when named; --include-controller opts in"
run_helper ctl "$PW"$'\n' --yes --identity subnetbot_1 --identity subnet-ctl --identity engine-ctl --identity wallet-ctl
[ "$(rc ctl)" = "0" ] && _ok "run with controller names exits 0 (they are skipped, not fatal)" || { _fail "exit $(rc ctl)"; out ctl | sed 's/^/      /' >&2; }
STDIN=$(stdin_log ctl)
has   "the fleet identity was sent"                                     "$STDIN" '-a "subnetbot_1"'
lacks "SN_IDENTITY named on the command line is still NOT sent"         "$STDIN" '-a "subnet-ctl"'
lacks "CE_IDENTITY named on the command line is still NOT sent"         "$STDIN" '-a "engine-ctl"'
lacks "WALLET named on the command line is still NOT sent"              "$STDIN" '-a "wallet-ctl"'
OUT=$(out ctl)
has   "the skip is reported with the flag that lifts it"                "$OUT" '--include-controller'

run_helper inc "$PW"$'\n' --yes --include-controller --identity subnetbot_1 --identity subnet-ctl --identity engine-ctl --identity wallet-ctl
[ "$(rc inc)" = "0" ] && _ok "--include-controller run exits 0" || { _fail "exit $(rc inc)"; out inc | sed 's/^/      /' >&2; }
STDIN=$(stdin_log inc)
has   "--include-controller sends SN_IDENTITY"                          "$STDIN" '-a "subnet-ctl"'
has   "--include-controller sends CE_IDENTITY"                          "$STDIN" '-a "engine-ctl"'
has   "--include-controller sends WALLET"                               "$STDIN" '-a "wallet-ctl"'
lacks "--include-controller still grants no unsigned partition"         "$STDIN" 'unsigned'
has   "--include-controller still uses the Team ID partition"           "$STDIN" 'teamid:FAKETEAM01'
[ "$(spawns inc)" = "1" ] && _ok "still exactly one security process" || _fail "security spawned $(spawns inc) time(s)"
lacks "still no password in argv"                                       "$(argv_log inc)" "$PW"
OUT=$(out inc)
has   "the consequence print names the controller keys as INCLUDED"     "$OUT" 'controller'

# ── 4. Confirmation: anything but yes aborts before any spawn ──
echo "  [4] the confirmation gate"
run_helper no "no"$'\n'"$PW"$'\n' --identity subnetbot_1
[ "$(rc no)" != "0" ] && _ok "answering 'no' exits non-zero" || _fail "answering 'no' exited 0"
[ "$(spawns no)" = "0" ] && _ok "answering 'no' spawns nothing" || _fail "answering 'no' spawned security"
run_helper conf "yes"$'\n'"$PW"$'\n' --identity subnetbot_1
[ "$(rc conf)" = "0" ] && _ok "answering 'yes' then the password runs" || { _fail "exit $(rc conf)"; out conf | sed 's/^/      /' >&2; }
has   "the confirmed run sent the password over stdin"                  "$(stdin_log conf)" '-k "Hunter2 \"zq\\x"'
lacks "the confirmed run put no password in argv"                       "$(argv_log conf)" "$PW"

# ── 5. Unsigned / ad-hoc executable: refused, never widened ──
echo "  [5] an unsigned icp executable is refused, never granted unsigned:"
KC_TEAMID="not set" run_helper unsig "$PW"$'\n' --yes --identity subnetbot_1
[ "$(rc unsig)" != "0" ] && _ok "unsigned executable: helper exits non-zero" || _fail "unsigned executable: helper exited 0"
[ "$(spawns unsig)" = "0" ] && _ok "unsigned executable: nothing sent to security" || _fail "unsigned executable: security was spawned"
OUT=$(out unsig)
has   "the refusal names the reason (no Team ID)"                       "$OUT" 'Team ID'
has   "the refusal names the widening it refuses"                       "$OUT" 'unsigned'
lacks "the refusal path never prints a partition list with unsigned:"   "$OUT" 'unsigned:'

# ── 6. --teamid override and the empty-selection refusal ──
echo "  [6] --teamid override; an empty selection is a refusal"
run_helper tid "" --dry-run --teamid ABCDE12345 --identity subnetbot_1
has   "--teamid overrides the detected Team ID"                         "$(out tid)" 'teamid:ABCDE12345'
lacks "--teamid never carries unsigned"                                 "$(out tid)" 'unsigned'
run_helper bogus "" --dry-run --teamid 'unsigned' --identity subnetbot_1
[ "$(rc bogus)" != "0" ] && _ok "--teamid unsigned is refused" || _fail "--teamid unsigned was accepted"
run_helper none "$PW"$'\n' --yes --identity subnet-ctl --identity nosuch_identity
[ "$(rc none)" != "0" ] && _ok "nothing selectable (controller + unknown) exits non-zero" || _fail "empty selection exited 0"
[ "$(spawns none)" = "0" ] && _ok "empty selection spawns nothing" || _fail "empty selection spawned security"
has   "an unknown identity is reported as absent from icp identity list" "$(out none)" 'nosuch_identity'

# ── Verdict ──
if [ "$_TEST_ERRORS" -eq 0 ]; then
  echo -e "\n\033[0;32mPASS: test_keychain_helper\033[0m"; exit 0
else
  echo -e "\n\033[0;31mFAIL: test_keychain_helper ($_TEST_ERRORS failing assertions)\033[0m"; exit 1
fi
