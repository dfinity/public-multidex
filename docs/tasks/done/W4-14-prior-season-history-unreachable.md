# W4-14 — After a season reset the prior season's history answers `{events = []; total = 0}` — a success

**Issue:** [#25](https://github.com/dfinity/public-multidex/issues/25) item 5 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer confirmed open
**Severity:** `#play` MEDIUM / `#production` N/A (reset refuses on `#production`)
**Effort:** M

## What's wrong

The `forSeason` branch sets `archive0 := null`, `_archiveNext := null` and clears `_archivesSealed`.
The canisters live on; only the **routing set** is emptied. `getMyArchivedEvents` builds its `known`
set from exactly those sources and, on a miss, returns `{ events = []; total = 0 }`.

So every event of the whole prior season is reported as **absent, with a success shape**, to a caller
who has no way to distinguish "you have no history" from "your history is no longer reachable from
here".

`seasonRecords` **does** record the archive principals — but **no read path consults it**, so the
provenance exists and is unreachable. That is arguably worse than not recording it, because it looks
like provenance is retained.

Same federation surface as #8 item 1 (`archiveExecute` over-serving other users' rows), opposite
polarity: that one returns too much, this returns too little while reporting success. A
`SeasonRecord` that advertises the sealed chain as the permanent ledger makes the contradiction
explicit.

## Evidence

- `src/backend/main.mo:14815-14817` — the detach (all three sources emptied)
- `:7140-7147` — `getMyArchivedEvents` builds `known` from `archive0` + `_archivesSealed`
- `:7148` — the `{ events = []; total = 0 }` miss return
- `:15267-15270` — `archiveExecute`'s visit list, same two sources
- `:14913` — `seasonRecords` records `archives = allArchivePrincipals()`; `:14869` — `getSeasonRecords` is its only reader

## Fix

Keep sealed season archives in a **separate additive registry** that the read paths consult even
after the active chain is detached, and **distinguish "no rows" from "chain detached"** in the
response shape so the UI can say which.

Land with [W4-15](W4-15-sealed-archive-funding.md) — that task needs the same surviving registry for
funding, and building it twice would be wasteful.

## Done when

- [x] Prior-season history is readable after a reset
- [x] The response distinguishes empty from detached
- [x] `seasonRecords` (or the new registry) has a real reader on the read path
- [x] A test resets a season and then reads a pre-reset user's history

## Completed 2026-08-15 (W4 batch 3, landed with W4-15)

Append-only `_seasonArchives` registry (canisterId, seq range, season), written by the detach
BEFORE it clears the routing sources, consulted by `getMyArchivedEvents`' known-set and
`archiveExecute`'s visit list. With every recorded segment resolvable there is no reachable
"detached" state left to distinguish from empty — the registry closes the gap the distinguishing
flag would have papered over. `seasonRecords` keeps the per-season snapshot
(`currentArchivePrincipals`), and the registry is the read-path form. `test_w4_batch3.sh` §1: the
same 13 events read back by the same segment id across a real reset.
