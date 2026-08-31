# W4-15 — The season detach drops sealed archives out of every funding path

**Issue:** [#26](https://github.com/dfinity/public-multidex/issues/26) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` HIGH / `#production` N/A (reset refuses on `#production`)
**Effort:** M

## What's wrong

`allArchivePrincipals()` is built from exactly three sources — `_archivesSealed`, `archive0`,
`_archiveNext` — and `performWorldWipe(true)` empties all three in one message.

`tickArchiveFuel` is the **only** automatic funder and iterates exactly that list; both of its
`fundArchive` calls are inside the loop. `fundArchive` has three callers, two of them in that loop
and `adminFundArchive`, which funds `archive0` only. Repo-wide there is **no endpoint that deposits
cycles into an arbitrary canister id** — the other `deposit_cycles` sites take
`effectiveBridge`/`effectiveArb`. `List.add(_archivesSealed, …)` occurs only inside the ship path, so
there is **no re-attach**.

The prior season's archives therefore hold their data, are unreachable from the funding loop, and
**drain until the IC deletes them** — taking the "permanent" ledger with them. The `forSeason` branch
detaches *without* deleting (per #18 Finding 25's correction), so the canisters genuinely survive the
reset; they are simply no longer anyone's responsibility.

`seasonRecords` holds the principals, but `tickArchiveFuel` never consults it.

## Evidence

- `src/backend/main.mo:6636-6642` — `allArchivePrincipals`, the three sources
- `:14815-14817` — all three emptied by the detach
- `:6660` — `tickArchiveFuel` iterates exactly that list
- `:6713-6716` — `adminFundArchive` funds `archive0` only
- `:7454`, `:7776` — the only `List.add(_archivesSealed, …)` sites, both in the ship path

## Fix

Either (preferably both):

1. an **append-only registry of sealed principals** that survives the detach and that
   `tickArchiveFuel` iterates — the same registry [W4-14](W4-14-prior-season-history-unreachable.md)
   needs for reads, so build it once; and
2. `adminFundCanister(principal, amount)` gated to controllers, so a detached or otherwise stranded
   segment can be rescued at all.

## Done when

- [x] Sealed archives keep receiving fuel across a season boundary
- [x] A controller can fund an arbitrary owned canister id
- [x] A test resets a season and asserts the sealed segment is still in the funding set
- [x] Interaction with [W1-03](W1-03-archive-execute-hop-isolation.md) noted: a frozen segment must
      degrade the read, not fail it

## Completed 2026-08-15 (W4 batch 3, landed with W4-14)

`allArchivePrincipals` (the fuel loop's and upgrade path's set) now includes `_seasonArchives`;
`isSealedArchive` covers them (blind-fund path); `getArchiveChain` shows them as role "season" so
their health is visible; `adminFundCanister(cid, amount)` is the controller rescue hatch for any
stranded id. `test_w4_batch3.sh` §2/§3: post-reset the detached segment is observed by a fuel pass
and rescue-fundable. W1-03 interaction stands: a frozen segment degrades reads, never fails them.
