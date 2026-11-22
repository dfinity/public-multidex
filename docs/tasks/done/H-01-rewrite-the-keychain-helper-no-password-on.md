# H-01 — Rewrite the keychain helper: no password on argv, no `unsigned:` grant, controller identities excluded — and REVOKE the grants already applied

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave 0 (operator machine & pipeline (no canister upgrade)) · findings F15 + F17 · MEDIUM ×2 · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium` · `touches: deploy, tests` · `lane: operator` (the revocation half; the rewrite is consumer work)

**Mechanism (current).** `scripts/fix_icp_keychain_prompts.sh:24` reads the login password with
`read -s`, then `:34` loops every identity from `icp identity list` and `:49-53` runs
`security set-generic-password-partition-list -S 'apple-tool:,apple:,unsigned:' -k "$PASS" …`
per item — 200+ spawns (`:18` "~10 seconds") with the password in each child's argv, readable
via `ps`/`KERN_PROCARGS2` by any same-user process and by other local accounts. The `unsigned:`
partition lifts the code-signature gate on every icp-cli item — including the funded
controller/wallet identity `SN_IDENTITY`/`CE_IDENTITY` (`scripts/deploy.sh:943-951`,
`scripts/lib/targets.sh:71-78`) that `docs/deploy-to-subnet.md:96-100` names as sole
controller, deploy identity, archive owner, LP and insurance holder. Triage #10.3
(`docs/issue-triage-2026-08.md:266-267`) records the helper as having been run against that
identity on the operator Mac. The launchd bot fleet does need a prompt-free path for the
*fleet* identity (`targets.sh:127-134`), which is why the helper exists.

**Fix criteria.** (1) The password is never an argv element: drive one `security -i` process
over stdin (or omit `-k` and let it prompt once with the keychain pre-unlocked). (2) Replace
`unsigned:` with the icp binary's designated requirement / `teamid:` partition or an explicit
trusted-application ACL for the resolved `icp` path. (3) Identities are an explicit allow-list;
`SN_IDENTITY`, `CE_IDENTITY`, `WALLET` are excluded unless `--include-controller` is passed.
(4) The script prints the consequence before mutating anything. (5) **Operator action, now,
independent of the rewrite:** re-run the partition-list command against every currently
granted item with the narrowed list so the standing `unsigned:` grant on the controller key is
revoked; then verify an unrelated unsigned process reading an icp-cli item triggers the dialog.

**Verify.** `tests/test_deploy_hygiene.sh` gains `src_lacks '-k "$PASS"'`, `src_lacks 'unsigned:'`
on the script; during a full run `ps -eo args` never contains the password (manual check on the
operator machine, recorded in the task log).

**done 2026-09-04** (task `1788467588`, branch claude/seat-2, on top of `f14f4f4`, code commit `da1160e`): scripts + tests only — no canister change, no deploy. **Fix 1 (F15)**: exactly ONE `security -i` process; every `set-generic-password-partition-list` line, password included, is written to its stdin by a printf builtin — nothing is exec'd with the password in it and nothing is written to disk. The stdin variant was chosen over "omit `-k` + `unlock-keychain`" after verifying against a scratch keychain FILE in the seat scratchpad (never the login keychain) that macOS `security -i` accepts `-k` on the line, including a password with a space, a `"` and a `\` (escaped `\"`/`\\`); a missing item errors inside the session without aborting the rest, and success is attributed per item from the `"acct"` attribute the tool dumps (its exit status is 0 either way, so the verdict is parsed). **Fix 2 (F17)**: partition `apple-tool:,apple:,teamid:<ID>`, <ID> read at runtime with `codesign -dvv` from the executable that presents itself to Keychain Services — the resolved `icp` (symlinks followed), or its shebang interpreter when `icp` is a script. Codesign finding on this machine: `~/.local/bin/icp` → `@icp-sdk/icp-cli/bin/icp.js` (`#!/usr/bin/env node`; codesign: "code object is not signed at all"), so the process reading the item is `~/.local/bin/node` — Developer ID Application: Node.js Foundation, TeamIdentifier `HX7739G8FX` → partition `teamid:HX7739G8FX`. An executable with no Team ID (unsigned / ad-hoc) is REFUSED (exit 1, nothing sent, the message names the widening it refuses); `--teamid` accepts only a ten-character Team ID, never a partition keyword — the honest fallback is a Developer ID-signed interpreter or a verified `--teamid`, never `unsigned:`. **Fix 3**: `--identity` allow-list (default: the launchd fleet's `<target>bot_N` family, bots.sh's BOT_PREFIX); SN_IDENTITY / CE_IDENTITY (targets.sh → the gitignored conf files), WALLET (topup.sh) and MDX_KEYCHAIN_CONTROLLER_IDENTITIES are skipped even when named unless `--include-controller`; the header records that bots.sh funds a remote fleet AS the controller (BOT_IDENTITY=<controller>), so that opt-in is the operator's decision and still gets the Team ID partition. **Fix 4**: the consequence — executable + provenance, Team ID + how it was read, partition, every item, every skipped identity with its reason, the exact `security` lines with `-k "<redacted>"` — prints before anything is touched; typed `yes` or `--yes`; `--dry-run` stops before the password is read. **Verified**: hygiene §3e (`src_lacks '-k "$PASS"'`, `src_lacks 'unsigned:'` + 9 shape pins) RED 11 ✗ on the pre-fix script → PASS 889/0; new static `tests/test_keychain_helper.sh` (PATH shims for `security`/`icp`/`codesign` logging argv + stdin — never a real keychain; six sections: dry-run consequence, one `-i` spawn with the password on stdin only, controller skip/opt-in, confirmation gate, unsigned refusal, `--teamid` + empty selection) RED 38 ✗ / 25 ✓ on the pre-fix script (`security` spawned 7×, `[-k]` on argv) → GREEN 63/0, discovered by run_all (`--filter keychain_helper`: 1 passed); `bash -n` both files; a real `--dry-run` against the seat store (220 identities) resolved node/`HX7739G8FX` and sent nothing. Adjacent cases enumerated: controller named explicitly (skipped, non-fatal), controller absent from the default set (still reported skipped), unknown identity (reported absent, non-fatal), all-skipped selection (refused, nothing spawned), `--teamid unsigned` (refused), password with the parser's special characters, `--include-controller` with the default list (adds the store's controller keys). Not run: the full `run_all.sh` (no venue involvement in a scripts+tests change). **DEFERRED to `1788467589` (operator lane)**: criterion (5) — re-running the narrowed partition list over every currently granted item on the controller Mac so the standing `unsigned:` grant on the controller key is revoked, then checking that an unrelated unsigned process reading an icp-cli item prompts — and the brief's "`ps -eo args` never contains the password during a full run" check; this seat's ICP_HOME identities are plaintext with no keychain items, so neither can be exercised here. Bookkeeping: brief → done/, README row struck, plan §10 rows F15/F17 and the filed H-01 row marked.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
