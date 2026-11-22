# W6-10 — Four documentation corrections where comments claim more than the code does

**Issue:** internal red-team round 2 — R6, R11, plus two found on verification
**Status:** VERIFIED at `d8f4c58` (2026-08-17)
**Severity:** Informational — but two of the four would mislead an auditor
**Effort:** S

## 1. The pool ↔ owner join on the raw tape (from R6)

**R6's central framing is wrong and must not become a code task.** Its claim is that enumerable pool
principals "defeat the owner-gate". They do not: the gate at `ArchiveCanister.mo:412` is on
`getEventsForPrincipals`, the only **by-principal index** on the archive. `getEventsRange` is keyed
by **seq**, so enumerating pool principals gives no way to query them — an attacker must linearly
scan the whole tape at ≤200 events/call and filter client-side, and pool principals are already
self-identifying on the tape anyway (9 bytes, `0x70` tag). Enumeration adds essentially nothing.

Three of the four links in R6's chain are the venue's explicitly documented, deliberate design:
enumerable pool principals with authorization by registry (`lib/MarginPools.mo:50-53`), a public
tape (`docs/archive-design.md:456-457`, "KEEP `getEventsRange`"), and publicly-computable liquidation
prices — the last of which the venue *ships as a feature* (`getMarginHeatmap`), having retired its
k-anonymity floor because "it hid nothing" (`docs/margin-heatmap-design.md:118-135`). R6 is also
largely a re-report of OhShii #8.2, already closed in `docs/issue-triage-2026-08.md:234-237`.

**The one genuine residual:** `fundMarginPool` debits the human and credits the pool in the same
message with no `await` (`main.mo:10367-10370`), and `Accounts.setBalance` journals one entry per
mutation in insertion order (`lib/Accounts.mo:42-48`), so the tape carries two **consecutive-seq**
`#delta` rows — a deterministic owner↔pool join. That defeats a boundary `main.mo:7841-7850`
explicitly claims to hold: that comment fixed the raw-`counterparty` leak *because* it was "an
owner↔pool-principal INDEX on the public tape", and claims the fix keeps money flow "while dropping
the sub-account identity". The `#delta` adjacency re-supplies it.

Correction to R6's reasoning: the shared timestamp is **not** the discriminator — `emitEventRaw`
stamps `Time.now()` at drain time, so every row in one heartbeat drain shares a `ts`. The link is
consecutive seq plus matched magnitude.

**Why documentation and not code:** remapping pool→owner in `drainLedgerJournal` is not viable — the
`#delta` fold must reproduce every account balance *per principal* by construction
(`lib/Accounts.mo:13-22`, `docs/archive-design.md:299-320`), and folding pool deltas into the owner
breaks the replay invariant and `tests/test_archive_replay.sh`. Breaking adjacency alone is cosmetic
since the amounts still match. So take the W4-21 route — "the doctrine wins, and the verifier forces
it" (`done/W4-21-order-id-join-archive.md:50-57`).

**Action:** amend `ArchiveCanister.mo:405-406` ("no easy per-human attribution index") and
`main.mo:7849-7850` ("dropping the sub-account identity") to state that the pool↔owner join remains
derivable from adjacent `#delta` rows on the raw tape, and note it in the `getApiDoc()` DECISION
paragraph (`main.mo:10150`) beside the existing one.

## 2. `verifyChain` overclaims (from R11)

See [W2-04](W2-04-verifier-trust-anchors.md) for the full reasoning. Amend the `verifyChain`
docstring (`ArchiveCanister.mo:264-266`) to state that it verifies links **within** this archive only
and cannot check the join to its predecessor — the successor is never told the predecessor's head
(install arg is `(owner)` only, `main.mo:7501`). Correct `docs/archive-design.md:382-386`, which
says the chain "runs UNBROKEN across sealed archives … pinned by the test": the pinning is an
off-chain shell assertion (`tests/test_archive_chain.sh:149-152`), not on-canister enforcement.

## 3. A stale comment says the OQL surface is wide open (found on verification)

`main.mo:16059-16063` still reads: *"Auth is public_ for now: ANY caller can query EVERYTHING,
including other users' pools and positions. That's a deliberate, acknowledged gap"*.

**That is false.** Per-entity auth at `:16400-16412` makes `pool`, `position`, `balance` and
`closedOrder` `#controllerOrScoped`; join targets are indexed under the caller's own subject
(`oql/Executor.mo:554-560`); the `leaderboard` entity omits `user` (`:16674-16684`) and the `order`
entity omits `owner` (`:16615-16648`). An auditor reading this file draws exactly the wrong
conclusion — and this is the file a reviewer opens first when assessing read-surface exposure.

## 4. Arb constants drifted from the docs (found on verification)

`docs/amm-vault-design.md:239` says $2k per tick (actual $5k); `:182` / `:240` say $100k/hour
(actual $512.5k); `:258` says $250k funding (actual $1,281,250); `main.mo:5265` prose also still
says "$100k budget". The war-gaming math at `:190-193` is derived from the stale figures, so the
published risk analysis is wrong, not just the constants.

*(A background task was already spun off for this item — reconcile rather than duplicate.)*

## Done when

- [x] The two archive comments state the pool↔owner join honestly (consecutive-seq `#delta`
      adjacency, derivable-by-scan as a stated cost of the replay invariant), and `getApiDoc`
      gains a second DECISION paragraph (W6-10.1) beside the W4-21 one
- [x] `verifyChain`'s docstring and `archive-design.md` corrected — landed with
      [W2-04](done/W2-04-verifier-trust-anchors.md) (within-archive scope; off-chain shell pin;
      blackhole dependency stated)
- [x] The OQL auth comment now describes `#controllerOrScoped` reality (and says why the old
      "ANY caller can query EVERYTHING" claim had to die: it is the first file an auditor opens)
- [x] Arb figures: `amm-vault-design.md` was reconciled by `e805645` (verified: $5k/call,
      $512.5k/h, war-gaming derived from the live numbers); the last stale prose ("fresh $100k
      budget" beside `ARB_HOURLY_CAP_USD`) fixed with a keep-in-sync cite
- [x] Every correction cites its code (W6-10.n markers at each site)

---
## Status 2026-08-17 — CLOSED (docs/comments only, no behavior change)
