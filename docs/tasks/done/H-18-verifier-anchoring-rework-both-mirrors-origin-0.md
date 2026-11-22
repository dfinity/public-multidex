# H-18 — Verifier anchoring, the two gaps round 18 left: the CLI tail-skew concession never exits 0 unanchored (F10); a re-anchor with an unsealed predecessor is refused or justified in both mirrors (F21)

*Source: [hardening-plan-2026-09.md](../hardening-plan-2026-09.md) · Wave V (verifier & frontend track (asset deploy + CLI; parallel with Waves 1–2)) · findings F10 + F21 · MEDIUM ×2 · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium` · `touches: verifier, frontend, tests, docs`


> **Narrowed 2026-09-03 22:45 — round-18 overlap.** Public issue #55 (OhShii, round 18) was triaged and filed 40 minutes before this set: F9 = `1788465027` (#55.1, default origin), F11 = `1788465028` (#55.3, sealed-segment cert), the F30 verifier half = `1788465029` (#55.4, contiguous `#gap` tiling; exact merged match, superset refused — see H-16 for why the backend coalesced emit is still needed). Those three are NOT re-done here. What remains is F10 and F21 below; this task lands after `1788465027`, `1788465028`, `1788465029` and `1788465046` (the `wrong-head` stub scenario) and rebases the stub scenario list on whatever landed first.

**Mechanism.**
- ~~F9 (covered by `1788465027`):~~ `verify_ledger.mjs:466-472` / `ledger.js:275-279` default the origin to the active head's
  `chainStartSeq`, which `ArchiveCanister.mo:197,218-219` sets to that canister's own first seq;
  the successor is anchored at `_activeFirstSeq := shippedSeq` (`main.mo:8778, 9107`). On any
  rolled chain (the live one: g24jr → g55pf) `archives[0].firstSeq > ORIGIN` is inert, so a list
  that omits every sealed segment passes. The stub models `chainStartSeq: 0` with `firstSeq: 2`
  (`tests/fixtures/verify-ledger-stub/stub-agent.js:134,145-150`) — a shape the canister never
  produces — so `test_verify_ledger_gate.sh:94-98` is green against fiction. The honest origin
  is a constant: `performWorldWipe` resets `nextEventSeq := 0` every season.
- F10 (CLI only): the tail-skew concession (`--last` `:437-455`, `--full` `:516-533`) `continue`s
  past the head comparison (`:536-538`) and `validateArchiveCert` (`:542`); `classifyEmptyPage`
  (`:364-376`) skips every probe when the empty seq is the head seq; the genuine certificate is
  then validated and VALID printed, exit 0 — over a walked window never compared to anything
  certified. `test_verify_ledger_gate.sh:79-84` pins `WITHHOLD=2` as the passing control. W2-02
  chose "bound, don't remove"; the bound is on the wrong axis.
- ~~F11 (covered by `1788465028`):~~ `ledger.js:169-174` maps every `Certificate.create` exception to
  `ok:null`; the sealed loop (`:320-327`) throws only on `ok === false`; the verdict
  (`:355-361`) depends on the active head alone. After a real re-anchor (seed `null` at
  `:305-309`) a pre-gap segment is vouched only by its own certificate — which can be garbage.
  The CLI twin `validateArchiveCert` (`verify_ledger.mjs:250-253`) fails hard.
- F21 (both): coverage-jump and re-anchor justification are guarded on
  `archives[i-1].lastSeq.length` (`mjs:489,506`; `ledger.js:292,305`); a served list with an
  unsealed non-final entry makes the tentative re-anchor final with nothing to justify; the CLI
  concession keys on `!a.lastSeq.length` (`:516`), not on being last.
- ~~F30 verifier half (covered by `1788465029`):~~ exact-range rule at `mjs:551` / `ledger.js:331`.

**Fix criteria.** ~~(1) covered by `1788465027`:~~ Default `ORIGIN = 0`; a first archive with `firstSeq > 0` must be justified
by a chain-committed `#gap [0..firstSeq)` or an explicit `--expect-start`/`opts.expectStart`;
fix the stub so the successor's head reports `chainStartSeq == firstSeq`; correct the verdict
copy, `docs.js:1375-1380` and the W2-04 record. (2) CLI: on truncation, re-fetch
`getCertifiedHead` (bounded retries) and require the readable tape to reach `headSeq`, or anchor
at a fresh certified head inside the readable window (compare the recomputed hash *at that seq*,
validate *that* certificate); otherwise exit a distinct non-zero "inconclusive" code and never
print VALID / "chain links verified" as covering the walk; both `--full` and `--last`.
~~(3) covered by `1788465028`:~~ Browser: off `isLocalReplicaOrigin()`, any `Certificate.create` exception is `ok:false`
(hard fail) for every segment; green requires `segCertsOk === heads`; `null` reserved for local.
(4) Both: reject a served list where any non-final entry has `lastSeq null` or ranges are not
strictly ascending; push a justification whenever `seed` is nulled at `i > 0` regardless of the
predecessor's shape; limit the CLI concession to `i === archives.length − 1`. ~~(5) covered by `1788465029`:~~ Both: accept a
discontinuity equal to one `#gap`, exactly tiled by adjacent `#gap`s, or covered by a single
`#gap` superset ending at the same `to`.

**Verify.** `test_verify_ledger_gate.sh`: realistic stub (successor `chainStartSeq == firstSeq`)
with truncated-list still exit 1; fabricated prefix + withheld head under a genuine certificate
→ non-zero; honest-skew control passes only once anchored (stub "catches up on retry" mode);
unsealed-predecessor + gap tuple → both verifiers fail; `#gap[a,b)+#gap[b,c)` with jump `[a,c)`
verifies, `[a,c)` with only `#gap[a,b)` fails. `frontend_security.test.mjs` gains the
per-segment fail-closed pin. Existing `fabricated-gap`, `bad-cert`, `MDX_STUB_TAIL=1` controls
stay green. Live: `verify_ledger.mjs --full --fold` against the subnet venue exits 0.

**done 2026-09-04** (task `1788467615`, branch claude/seat-2, code commit `2dbeb47`, merged `54cb3d6`): verifier + frontend + tests only — no canister change, no candid change, no stable-layout change; the bookkeeping half landed in a second seat pass (claude/seat-1) once the H-wave corpus was committed (`59906ee`, task `1788470219`). **F10** — a truncated CLI walk is anchored to a fresh certified head (bounded re-fetch of `getCertifiedHead`: the tape catches up, or a fresh head inside the readable window is compared AT that seq with THAT certificate validated) or the run exits 3 INCONCLUSIVE, never VALID — both `--full` and `--last`. **F21** — `validateArchiveList` in both mirrors (`verify_ledger.mjs` + `ledger.js`, drift-locked) refuses a non-final open row / non-ascending list before the walk; a nulled seed at `i > 0` is always justified; the CLI concession is limited to the last open entry. (Fix criteria (1), (3) and (5) landed under the round-18 tasks `1788465027` / `1788465028` / `1788465029`, as struck above.) **Verified**: `test_verify_ledger_gate` 28→38 (11 RED pre-fix), `verify_chain_client` page twins 48→62 (14 RED), 4 security pins; `frontend_security` 254, `display_integrity` 124, `eventchain_equivalence`, deploy hygiene PASS; seat venue: `--full --fold` exit 0, archive trio (replay/failover) + season seal green. NOT run: full `run_all.sh`. **Deferred**: the brief's Live item — `verify_ledger.mjs --full --fold` against the SUBNET venue — is DEFERRED (law 8) to the operator's folded deploy sitting (`1788469062`). Bookkeeping: brief → done/, README row struck, plan §10 F10/F21 rows + §11 filed row marked done; merged from claude/seat-1.

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags ((2) + (4) here; (1)/(3)/(5) by the round-18 tasks — verifier + frontend + tests only, no canister, candid or stable change)
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task" (gate 28→38 with 11 RED pre-fix, page twins 48→62 with 14 RED; the Live subnet item DEFERRED to the deploy sitting `1788469062`)
- [ ] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS (full `run_all.sh` NOT run by seat-2 — only the named gates, the security pins, hygiene PASS and the seat-venue archive trio + season seal; posture `#play` at merge `54cb3d6`)
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
