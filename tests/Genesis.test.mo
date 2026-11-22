// Unit pins for src/backend/lib/Genesis.mo — the genesis-window verdict for
// the bulk seed mint (operator decision 2026-09-06, task 1788529484 — the
// second half of H-17 / F29-backend). bulkSetTestBalances is bound to the
// `_ammEverEnabled` latch on #play ONLY: #dev never refuses (the suites and
// scripts/seed.sh re-fund across enableAmm and resetExchange), #play refuses
// exactly when the latch is set, #production always (the mixin's posture trap
// fires first; the predicate agrees so the two gates cannot disagree). The
// switch is exhaustive, so a fourth posture cannot compile undecided.

import Genesis "../src/backend/lib/Genesis";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

// #dev: the window never closes — dev hooks are live, seed.sh full re-runs
// bulkSetTestBalances on a venue whose markets are already enabled.
truth("#dev, latch unset: window open", not Genesis.bulkSeedWindowClosed(#dev, false));
truth("#dev, latch set: window STILL open (seed.sh re-funds after enableAmm)", not Genesis.bulkSeedWindowClosed(#dev, true));

// #play: the latch is the verdict — open before the first enableAmm (a
// bring-up may bulk-fund), closed after (a live venue).
truth("#play, latch unset: window open (bring-up before the first enableAmm)", not Genesis.bulkSeedWindowClosed(#play, false));
truth("#play, latch set: window CLOSED (the venue has gone live)", Genesis.bulkSeedWindowClosed(#play, true));

// #production: closed regardless of the latch — a value-bearing venue never
// takes a bulk mint (the IS_PRODUCTION trap upstream names the posture).
truth("#production, latch unset: window closed", Genesis.bulkSeedWindowClosed(#production, false));
truth("#production, latch set: window closed", Genesis.bulkSeedWindowClosed(#production, true));

// The verdict is monotone in the latch on every posture: setting the latch
// can only close the window, never open it (a season wipe keeps the latch,
// so a wiped #play venue stays closed).
for (posture in [#dev, #play, #production].values()) {
  let tag = debug_show(posture);
  truth("latch is monotone on " # tag # " (set ⇒ closed if unset was closed)",
    (not Genesis.bulkSeedWindowClosed(posture, false)) or Genesis.bulkSeedWindowClosed(posture, true));
};

Debug.print("Genesis.test.mo: all pins hold");
