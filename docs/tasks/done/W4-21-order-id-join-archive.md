# W4-21 — The `order.id` ↔ `fill.orderId` join is only half-closed

**Issue:** [#8](https://github.com/dfinity/public-multidex/issues/8) item 4a — OhShii Labs
**Status:** **HALF-CLOSED** at `01d2b23` (2026-08-14) — recorded as such in the 1.60 triage §6
**Severity:** `#play` LOW / `#production` LOW
**Effort:** M

## What's wrong

`order.id` de-anonymises partially-filled resting orders by joining against `fill.orderId`. The OQL
half is **already shut** — the public `userEvent` projection carries no `orderId` — but the archive's
raw `getEventsRange` still returns the whole `#fill` variant, so the join survives there.

`id` cannot simply be dropped from the `order` projection: it is that entity's declared primary key
and the executor traps on a hidden pk.

## Where this sits against the transparency doctrine

The doctrine makes the tape deliberately public and principal-attributed, and that is a requirement,
not an accident. So this is **not** a claim that the rows should be private. It is narrower: the
docs describe a scoping guarantee that the archive surface does not deliver, so either the surface
or the sentence has to move. Closing it properly means **per-kind redaction on the archive surface**,
which is a real change rather than a tweak.

Sequence this **after** the docs decision in
[W6-01](W6-01-refresh-triage-document.md)/#8 — if the answer is "the tape is public and the docs were
wrong", this task shrinks to a documentation fix and the code stays as it is.

## Evidence

- The public `userEvent` OQL projection carries no `orderId` (the closed half)
- `ArchiveCanister.getEventsRange` returns the full `#fill` variant (the open half)
- `oql/Executor.mo:649` — traps on a hidden primary key, which is why `id` cannot be dropped

## Fix

Decide first, then implement:

- **If the guarantee is kept:** per-kind redaction on the archive read surface, so `#fill` rows served
  raw omit `orderId` for callers outside the owner scope.
- **If the doctrine wins:** correct `getApiDoc()` and `docs.js` to describe what is actually served,
  and close this as documentation.

## Done when

- [x] The decision (redact vs document) is written down and public
- [x] Code and docs agree, whichever way it went
- [x] `tests/test_archive_replay.sh` still passes — it depends on the current behaviour

## Completed 2026-08-15 — decision: the doctrine wins, and the verifier forces it

Redaction on the raw archive surface is not merely undesirable — it is IMPOSSIBLE without breaking
the product's core guarantee: chain verification hashes the complete canonical row, so a redacted
`getEventsRange` could never re-derive the certified head. The decision is recorded publicly in
`getApiDoc()` (DECISION paragraph: the order.id ↔ fill.orderId join IS derivable from the tape;
de-identification applies to the live convenience queries only) and in docs.js's transparency
section. `test_archive_replay.sh` 15/0 (after the extMarketSwap arity migration it needed anyway).
