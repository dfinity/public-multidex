// Unit tests for the fan-out accumulator (H-37 / F34) — the decision that
// applies a mark on a ROBUST QUORUM, on every source reporting, or on the
// caller's deadline, never on the slowest provider.
//
// Before H-37 the refresh awaited all eight per-source futures in order, so
// one venue trickling its body set the cadence of every mark: staged orders
// missed DEFERRED_EXPIRY_NS (15s), FOKs died, marks went a timeout stale.
// Motoko cannot select on or abandon an await, so the fan-out records per
// source into PriceFeed.FanoutState and the FIRST arrival to satisfy the
// quorum (with acceptable dispersion) finalizes. The state machine is pure;
// main.mo does the I/O. These fixtures drive every transition: #wait,
// #finalize on quorum / completion, #late after finalization, the external
// close (deadline / drained) exactly once, failed readings counting toward
// completion but never toward the quorum, and a dispersion veto holding the
// quorum until the trimmed survivors reach it. The integration side
// (tests/test_oracle_fanout_deadline.sh) exercises the same transitions on a
// live venue through the devStallSource hook.

import PriceFeed "../src/backend/lib/PriceFeed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Float "mo:core/Float";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

func src(id : Text, quote : PriceFeed.QuoteAsset) : PriceFeed.Source {
  { id; quote; urlTemplate = "https://example.invalid/{asset}"; kind = #binance; maxResponseBytes = 8_192 };
};
// The shipped fleet's shape: two USD venues, six USDT.
let SOURCES : [PriceFeed.Source] = [
  src("usd-a", #usd), src("usd-b", #usd),
  src("t-a", #usdt), src("t-b", #usdt), src("t-c", #usdt),
  src("t-d", #usdt), src("t-e", #usdt), src("t-f", #usdt),
];
let FLOOR = PriceFeed.MIN_ROBUST_SOURCES;   // 3
let GATE : Float = 50.0;                    // PRICE_MAX_STDDEV_BPS
func rd(id : Text, price : Float) : PriceFeed.Reading {
  { sourceId = id; asset = "ICP"; price; fetchedAtNs = 1_000; ok = true; errMessage = null };
};
func failed(id : Text) : PriceFeed.Reading {
  { sourceId = id; asset = "ICP"; price = 0.0; fetchedAtNs = 1_000; ok = false; errMessage = ?"http 451" };
};
// The caller's aggregation — aggregateByQuote with the fleet and the floor —
// so the quorum test judges the same trimmed, per-quote sample the apply
// prices on (exactly what main.mo's fanoutAggregate hands the state).
func aggOf(rs : [PriceFeed.Reading]) : PriceFeed.Aggregate {
  PriceFeed.aggregateByQuote("ICP", rs, SOURCES, 2_000, 100, FLOOR).agg;
};
func step(st : PriceFeed.FanoutState, r : PriceFeed.Reading) : PriceFeed.FanoutStep {
  PriceFeed.fanoutRecord(st, r, aggOf, GATE);
};
func isWait(s : PriceFeed.FanoutStep) : Bool { switch (s) { case (#wait) { true }; case _ { false } } };
func isLate(s : PriceFeed.FanoutStep) : Bool { switch (s) { case (#late) { true }; case _ { false } } };
func finalizedAs(s : PriceFeed.FanoutStep, r : PriceFeed.FanoutReason) : Bool {
  switch (s) { case (#finalize(x)) { x == r }; case _ { false } };
};

Debug.print("── PriceFeedFanout.test ──");

// ── the robust quorum ──────────────────────────────────────────────
truth("robustQuorum(8, 3) = 5: a strict majority of the shipped fleet", PriceFeed.robustQuorum(8, FLOOR) == 5);
truth("robustQuorum(8, 6) = 6: never below the caller's floor",         PriceFeed.robustQuorum(8, 6) == 6);
truth("robustQuorum(2, 3) = 3: a two-source fleet cannot lower the floor", PriceFeed.robustQuorum(2, FLOOR) == 3);
truth("robustQuorum(8, 99) = 99: the test-pinned floor is unreachable by quorum (finalizes on completion/deadline)", PriceFeed.robustQuorum(8, 99) == 99);

// ── #quorum: the fifth agreeing arrival finalizes; the rest attach late ──
let q = PriceFeed.fanoutNew(8, PriceFeed.robustQuorum(8, FLOOR));
truth("a fresh fan-out is open",                          q.finalized == null and q.readings.size() == 0);
truth("1st arrival: wait",                                isWait(step(q, rd("t-a", 100.00))));
truth("2nd arrival: wait",                                isWait(step(q, rd("usd-a", 100.05))));
truth("3rd arrival (the floor) is NOT the quorum: wait",  isWait(step(q, rd("t-b", 99.95))));
truth("4th arrival: wait",                                isWait(step(q, rd("t-c", 100.02))));
truth("5th agreeing arrival: #finalize(#quorum)",         finalizedAs(step(q, rd("usd-b", 100.01)), #quorum));
truth("finalized on the five that arrived",               q.readings.size() == 5 and q.finalized == ?#quorum);
truth("the sixth arrival is #late",                       isLate(step(q, rd("t-d", 100.03))));
truth("the seventh arrival is #late",                     isLate(step(q, rd("t-e", 99.98))));
truth("late readings ATTACH (readings 7) and are counted (late 2)", q.readings.size() == 7 and q.late == 2);
truth("the reason never changes after finalization",      q.finalized == ?#quorum);
truth("fanoutClose on a finalized fan-out is a no-op (false)", not PriceFeed.fanoutClose(q, #deadline));
truth("a partial set aggregates: 7 readings → sourceCount 7, dispersion within the gate",
      aggOf(q.readings).sourceCount == 7 and aggOf(q.readings).stddevBps <= GATE);

// ── #complete: failed readings count toward completion, never the quorum ──
let c = PriceFeed.fanoutNew(5, 3);
truth("failed reading 1: wait",                           isWait(step(c, failed("t-a"))));
truth("failed reading 2: wait",                           isWait(step(c, failed("t-b"))));
truth("ok reading 1: wait",                               isWait(step(c, rd("usd-a", 10.0))));
truth("ok reading 2: wait (two survivors < quorum 3)",    isWait(step(c, rd("usd-b", 10.01))));
truth("5th arrival (a failure) completes the fleet: #finalize(#complete)", finalizedAs(step(c, failed("t-c")), #complete));
truth("the completed sample has 2 survivors (below the floor — the apply gate's problem, not the fan-out's)",
      aggOf(c.readings).sourceCount == 2);

// ── #deadline / #drained: the external close, exactly once ──
let d = PriceFeed.fanoutNew(8, 5);
ignore step(d, rd("t-a", 3.00)); ignore step(d, rd("t-b", 3.01)); ignore step(d, rd("usd-a", 3.00));
truth("three agreeing arrivals: still open (3 < quorum 5, 3 < expected 8)", d.finalized == null);
truth("fanoutClose(#deadline) closes an open fan-out (true — the caller applies now)", PriceFeed.fanoutClose(d, #deadline));
truth("the reason is #deadline",                          d.finalized == ?#deadline);
truth("a second close is refused (false — no double apply)", not PriceFeed.fanoutClose(d, #drained));
truth("an arrival after the deadline is #late",           isLate(step(d, rd("t-c", 3.02))));
truth("the deadline sample is what had arrived (3 survivors ≥ the floor)", aggOf(d.readings).sourceCount == 4 and d.late == 1);
let dr = PriceFeed.fanoutNew(8, 5);
ignore step(dr, rd("t-a", 3.00));
truth("fanoutClose(#drained) — an awaiting caller whose fleet returned — closes too", PriceFeed.fanoutClose(dr, #drained) and dr.finalized == ?#drained);

// ── dispersion holds the quorum until the trimmed survivors reach it ──
let v = PriceFeed.fanoutNew(8, 5);
ignore step(v, rd("t-a", 100.00)); ignore step(v, rd("t-b", 100.10)); ignore step(v, rd("usd-a", 100.20)); ignore step(v, rd("t-c", 100.30));
truth("four in-cluster arrivals: wait",                   v.finalized == null);
truth("a fifth reading 280bps off-cluster is TRIMMED — four survivors, not five: wait", isWait(step(v, rd("t-d", 103.0))));
truth("the sixth, in-cluster, makes five survivors: #finalize(#quorum)", finalizedAs(step(v, rd("usd-b", 100.15)), #quorum));
truth("the quorum sample is the trimmed cluster (5 survivors of 6 readings)", aggOf(v.readings).sourceCount == 5 and v.readings.size() == 6);

// ── quorumReached is the apply gate's floor with the quorum in place of it ──
let agg5 = aggOf([rd("t-a", 1.0), rd("t-b", 1.0), rd("t-c", 1.0), rd("usd-a", 1.0), rd("usd-b", 1.0)]);
truth("quorumReached: 5 agreeing survivors pass quorum 5",  PriceFeed.quorumReached(agg5, 5, GATE));
truth("quorumReached: the same sample fails quorum 6",      not PriceFeed.quorumReached(agg5, 6, GATE));
let split = aggOf([rd("usd-a", 100.0), rd("usd-b", 100.0), rd("t-a", 100.0), rd("t-b", 110.0), rd("t-c", 120.0)]);
truth("quorumReached: a sample the dispersion gate refuses never passes, whatever the count",
      not PriceFeed.quorumReached(split, 3, GATE) or split.stddevBps <= GATE);
truth("fanoutReasonText covers every reason",
      PriceFeed.fanoutReasonText(null) == "open" and PriceFeed.fanoutReasonText(?#quorum) == "quorum"
        and PriceFeed.fanoutReasonText(?#complete) == "complete" and PriceFeed.fanoutReasonText(?#deadline) == "deadline"
        and PriceFeed.fanoutReasonText(?#drained) == "drained");

Debug.print("── PriceFeedFanout.test PASS ──");
