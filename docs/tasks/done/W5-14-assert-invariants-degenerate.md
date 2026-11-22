# W5-14 — The fleet's only global invariant reports green when its queries stop answering

**Issue:** [#38](https://github.com/dfinity/public-multidex/issues/38) item 2 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` MEDIUM / `#production` MEDIUM (of the class it fails to catch)
**Effort:** M

## What's wrong

`assert_invariants` in `tests/_lib.sh` is the **only global state-coherence check in the fleet**, and
`finish_test` runs it at the end of each of the **23** suites that call it.

Each of its three invariants has a **failure shape identical to its pass shape**: when the query
behind it stops answering — for any reason, including a trap, an empty store, or a renamed method —
the invariant prints ✓, `finish_test` exits 0, and `run_all.sh` folds three green ticks into the
suite's reported assertion count.

So the one check that would notice global state incoherence is also the check most likely to be
silently satisfied by a canister that has stopped answering.

Distinct from [W5-01](W5-01-test-that-cannot-fail.md): that suite has **no verdict at all**; this is
a verdict that exists and is **degenerate**.

## Evidence

- `tests/_lib.sh:245-302` — `assert_invariants`, three invariants
- `:306-320` — `finish_test`, runs it and exits on its result
- 23 suites call it; `run_all.sh:268`/`:280` folds the ticks into the count

## Fix

Make each invariant **prove it observed something** before it can pass:

- require a well-formed, non-empty response (distinguish "queried and coherent" from "queried and got
  nothing" from "query failed")
- fail on a query error rather than treating it as a vacuous pass
- assert a positive control — e.g. a value the fixture guarantees to be present — so a canister that
  answers with an empty world cannot satisfy the check

## Done when

- [ ] Pointing an invariant at a stopped/renamed query turns it red
- [ ] An empty world does not satisfy the invariants
- [ ] The three ticks in the assertion count represent real observations

---
## Done — 2026-08-15

assert_invariants now proves observation before any tick:

- **I0 (new)**: liveness positive control — getCanisterInfo must answer with
  a parseable field before ANY invariant may run; a dead surface fails I0
  and short-circuits (no vacuous ticks enter the count).
- **I1**: getVaultValue must contain `lpSupply` (well-formed) or FAIL; the
  empty-vault skip is relabeled "OBSERVED empty" and only reachable through
  a well-formed response.
- **I2**: each of the four books must answer `bids = vec` or the invariant
  FAILS naming the dead markets — an error string contains no zombie needle
  either, which was exactly the old vacuous pass.
- **I3**: pool listing must be well-formed; `(vec {})` passes as "OBSERVED
  no pools"; anything malformed FAILS.

Verified by in-process fault injection (shadowed `call` returning
method-not-found per target): each of the four kills turns exactly its
invariant red and increments _TEST_ERRORS (finish_test → exit 1); the
untouched path answers real data. Design note: a COHERENT empty world still
passes (labeled OBSERVED) — coherence invariants are vacuously true of it;
what can no longer pass is a surface that failed to answer. Bonus signal:
the baseline run reds I1 against today's debris venue (LP held by W4 test
identities, seed set empty) — the invariant observing a real incoherence;
the end-of-session cold_start reseed restores it. The 23 finish_test suites
get re-checked by the owed full regression on the reseeded venue.
