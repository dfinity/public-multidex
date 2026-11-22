# H-16 — A merged shed emits a `#gap` event covering the coalesced range

*Source: [hardening-plan-2026-09.md](../../hardening-plan-2026-09.md) · Wave 1 (backend upgrade #1: solvency & book poisoning) · findings F30-backend · LOW · filed 2026-09-03 from the 2026-09-02 scan, re-verified against `f3fbcf6`.*

`class: security-medium` (tape integrity)

**Mechanism.** `recordGap` (`:8733-8742`) coalesces adjacent tuples, but `shedOldestEvents`
(`:8796-8842`) emits one `#gap {fromSeq; toSeq}` per shed; two L2/L3 sheds inside one archive
outage (spawn blocked, `:8930-8937` retry) leave the archive list with ONE coverage jump
`[g1from, g2to)` and two `#gap` events — and, worse than reported, shed 2 can drop shed 1's
`#gap` event itself (it sits at the front of the post-shed queue; the baseline-bisect loop
`:8811-8818` extends the drop). Both verifiers' exact-range rule then rejects the honest tape
permanently. No test sheds twice (`test_archive_failover.sh` C/F shed once).

**Fix criteria.** When `recordGap` merges, emit `#gap {fromSeq = prev.0; toSeq = gapTo}` (payload
shape unchanged → no candid, no hash-format change). H-18's verifiers accept exact match,
adjacent tiling, or a superset ending at the same `to`, so old tapes still verify.

**Verify.** `test_archive_failover.sh` gains a two-consecutive-sheds-then-verify case: CLI exit 0,
browser green, with the chain-declared gap reported as documented, not tampering.

**done 2026-09-04** (task `1788467613`, branch claude/steady-brattain-70eed1, verified against the brief on `2cc268f`): **landed by 3de535e (task `1788469743`, claude/seat-2, archived 2026-09-03T23:01Z)** — this task changed NO code; the code credit is 3de535e. Fix criteria, verified on the current tree: `recordGap` (`src/backend/main.mo:9945-9956`) returns the range AS RECORDED — `(prev.0, to)` when it coalesces with the previous tuple, `(from, to)` otherwise — and `shedOldestEvents` emits `#gap { fromSeq = declFrom; toSeq = declTo }` from that pair (`:10042` + `:10075`), i.e. exactly the brief's `#gap {fromSeq = prev.0; toSeq = gapTo}` at the merge point; payload shape unchanged (no candid, no hash-format change), no new stable field, `_ledgerGaps`/`_shedBaselines` untouched. The brief's H-18 clause ("exact match, adjacent tiling, or a superset ending at the same `to`") is deliberately NOT what the verifiers do: `1788465029` (#55.4, `a2e669d`) accepts a jump only when it EXACTLY equals a run of contiguous, chain-collected `#gap` events (`mergeContiguousGaps`, `scripts/verify_ledger.mjs:510/:581`, `src/frontend/src/ledger.js:615/:337`, byte-identical twins) — a superset re-admits the fabricated-tuple attack (`over-shed` refused) — and the coalesced emit is what makes the chain-collected set cover the jump exactly when shed 2 drops shed 1's `#gap` event (an overlapping surviving half is never merged with the coalesced one, so nothing over-approximates). Verify items, present and green: `tests/test_archive_failover.sh` §G (two back-to-back sheds, nothing acked → asserts via `getEventsRange` that the fresh archive opens with shed 1's `[a..b)` AND that shed 2's declaration reads the coalesced `[a..c)`, then `verify_ledger.mjs --full` exit 0) and §H (a THIRD shed whose drop passes gap1 + gap2 → exactly ONE `#gap` on the fresh archive spanning `[a..d)`, `--full` exit 0; RED-verified pre-3de535e by seat-2), plus the offline pins `dropped-first-gap` / `overlap-first-gap` in `tests/test_verify_ledger_gate.sh` (CLI) and `tests/verify_chain_client.test.mjs` (the page walker — the brief's "browser green" half; the chain-declared gap is reported as a documented re-anchor, not tampering). Re-run here on `2cc268f` (venue backend == HEAD's main.mo, at `#dev`): `test_archive_failover.sh` 72/0 live (§G: shed 2 declared `[597..707)` with shed 1's `[597..677)` surviving at seq 707, `--full` 456 links across 3 gaps; §H: three sheds `[891..1200)`, the fresh archive at 1200 carries ONE declaration spanning the whole outage, `--full` 542 links across 4 gaps), `test_verify_ledger_gate.sh` 45/45, `verify_chain_client.test.mjs` 87/0, `bash tests/test_deploy_hygiene.sh` PASS; `mops test` and `gen-did.sh` not re-run (no `.mo` change since 3de535e, which ran them; candid unchanged by construction). Venue reseeded after §I's season reset. Adjacent sites enumerated (README §"Closing a task"): the only other `recordGap` caller (`:10282`, a refused ack's gap on the ops surface) deliberately declares nothing on the chain — not a shed, out of scope; the L3 shear path reuses `shedOldestEvents` (`:10144/:10146`) so it inherits the coalesced emit; the season boundary's `_seasonGaps` preservation (§I, `1788474114`) carries the coalesced tuples unchanged. Remote: the backend upgrade is DEFERRED to the plan's Wave 1 operator rollout (the plan carries it; no separate rollout task filed).

## Done when

- [x] Every **Fix criteria** item above is implemented; no stable-field drops, no candid change beyond what the brief flags
- [x] Every **Verify** item is a test that is RED on the pre-fix tree and GREEN after (record the red run in the task log); adjacent cases enumerated per README §"Closing a task"
- [x] Full suite green on `#dev`; posture restored to `#play` before merge; deploy hygiene PASS
- [x] Bookkeeping: this brief moved to `docs/tasks/done/` with a `**done <date>**:` note, its README row struck, and its row in `docs/hardening-plan-2026-09.md` §10 marked done with the merge sha
