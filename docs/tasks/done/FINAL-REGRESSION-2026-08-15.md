# Final regression ledger — 2026-08-15 (post-queue full suite)

First full run since the queue: **79 passed / 6 failed** → every failure
diagnosed to root cause; two were REAL product bugs. All six green
(individually + coupling-chains + rerun-tolerance double-passes) before the
confirming full re-run.

## The six, with causes

1. **test_swap_outcome** — real interaction with W4-04: §A's 0.1% maxSlippage
   is below the new 1% floor (refused at placement). Repair in two steps: the
   first attempt widened the SELL leg's spread and §A still filled — the
   cross-swap sizes fills against the BUY market's asks capped at THAT pool's
   refPrice×(1+slip) (`buyCap`, main.mo). Widening BTC-ICPUSD (restored for
   §B) makes 1% genuinely unreachable. 5/5.
2. **test_ghsa_round4 / test_oracle_time_bases** — in-suite venue noise only;
   pass standalone and in chains.
3. **test_market_walks_locked** — the W5-01 repair was venue-dependent after
   all: a 50/50 $400k seed breaches the vault concentration cap on any small
   ambient vault (pre-compaction green rode the $1M play vault; the empty
   fixture's `T == 0` never rejects, but run_all's evolved venue did). Now
   quote-heavy (100 ETH / 600k ICPUSD ≈ 25% leg), refusal non-fatal when a
   walkable ladder already exists (asks asserted after requote), LP reclaim
   attempted for reruns, and — critically — a **trap EXIT resumes
   setTestTimersPaused** so a failing walk can no longer strand the venue.
4. **test_matching_engine** — pure downstream victim: market_walks' failure
   path exited with timers paused, so the finaliser (heartbeat-dispatched,
   0.5s pacing) never ran `processDeferredExpiry` and poolless releases
   stalled. Release latency measured at 17s (expiry 15s + one ~2.4s beat) —
   inside the test's window once timers survive. No code change needed.
5. **test_archive_hop_isolation** — two stacked causes:
   - PRODUCT BUG (fixed): `archiveExecute`'s walk skipped segments whose
     LAST fuel-pass observation read `frozen`, conflating a stale (or, on
     pocket-ic, outright wrong lean-endowment) observation with "cannot
     answer now" — a restarted/topped-up segment stayed degraded until the
     next 300s pass. The skip is removed; the try/catch degrades real
     failures at the cost of one fast-failing call; `_archiveObs` still
     feeds the chain table (the W4-10 deliverable).
   - PRODUCT BUG (fixed): `performWorldWipe`'s full-wipe branch deletes
     every archive INCLUDING prior seasons' (`allArchivePrincipals` spans
     the season registry) but never cleared `_seasonArchives` — the walk
     then reported the corpses degraded forever (`canister_not_found`
     verified). The registry is now cleared on the DELETE path only
     (resetSeason detaches and rightly keeps its rows). Test also gained
     stranded-state hygiene: full-chain-table restarts before its baseline.

## The class, named

Three of the six trace to ONE class: **tests that mutate venue-global state
(timers, stopped segments, vault weights) must restore it on every exit path
and tolerate their own prior failures** — a failing test's debris reads as a
different test's regression. The timer trap, the segment restarts, and the
LP reclaim are the instances; assert_invariants' venue checks (W5-14) plus
this ledger are the detection net.
