// Genesis.mo — the GENESIS WINDOW verdict for the controller bootstrap mints
// (operator decision 2026-09-06, task 1788529484 — F29-backend, the second
// half of H-17).
//
// The window: `_ammEverEnabled` (main.mo) flips on the install's first
// `enableAmm(_, true)` and never back — it survives upgrades AND season
// wipes; only a reinstall (a genuinely new venue) re-arms it. Before that
// flip the venue is being BUILT (a bring-up may inject a chart backdrop,
// bulk-fund seed accounts, seed the insurance pool); after it, anyone may be
// trading on the balances that exist, so an unbacked mint is a live-venue
// supply change.
//
// Which tools the window binds, per the decision (the DECISION paragraph in
// getApiDoc and docs/deployment-modes.md "The genesis window"):
//
//   BOUND (refused on #play once the latch is set)
//     injectHistoricalTrades   — main.mo, typed #err (has a Result channel)
//     seedInsuranceFund        — main.mo, trap, only into a pool that already
//                                holds value (the empty-pool refill is the
//                                post-wipe backstop and stays allowed)
//     bulkSetTestBalances      — mixins/AdminOps.mo, trap (this predicate).
//                                No #play path calls it (scripts/seed.sh is
//                                the #dev seeder), so post-genesis it was
//                                pure attack surface: one controller call
//                                re-minting every seed account at once.
//   RATIFIED LIVE on #play (deliberately NOT bound)
//     setTestBalance           — an absolute SET (a repeat re-mints only what
//                                was spent), controller-only, every delta
//                                recorded into extNetFlow (capital, never
//                                leaderboard profit): the fleet's standing
//                                refill and play_start.sh's per-market base
//                                legs INSIDE the loop, after the first
//                                enableAmm, need it live.
//     fundArbitrageur          — same shape (play_start step 6b, deploy.sh
//                                after the seed), appendDeposit-recorded.
//   Both stay refused by POSTURE on #production (the IS_PRODUCTION traps).
//
// The verdict is a pure function of (posture, latch) so `mops test`
// (tests/Genesis.test.mo) pins all three postures and a FOURTH posture
// cannot compile without deciding — the switch is exhaustive on purpose.

module {
  /// The venue posture, structurally identical to main.mo's DeployMode so the
  /// actor's literal passes straight through (a lib cannot import the actor).
  public type Posture = { #dev; #play; #production };

  /// Is the genesis window CLOSED for a bulk seed mint (bulkSetTestBalances)?
  ///   #dev        — never: the suites and scripts/seed.sh re-fund across
  ///                 enableAmm and resetExchange freely (dev hooks are live).
  ///   #play       — once the venue has gone live (the latch): a bulk
  ///                 re-mint after that is a live-venue supply change.
  ///   #production — always: the mixin's IS_PRODUCTION trap fires first and
  ///                 names the posture; the predicate agrees so the two
  ///                 gates can never disagree about a value-bearing venue.
  public func bulkSeedWindowClosed(posture : Posture, ammEverEnabled : Bool) : Bool {
    switch (posture) {
      case (#dev) { false };
      case (#play) { ammEverEnabled };
      case (#production) { true };
    }
  };
}
