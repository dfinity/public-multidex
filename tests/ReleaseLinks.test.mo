// Unit tests for src/backend/lib/ReleaseLinks.mo — the release-link reverse
// index and its START-TIME REBUILD (public issue #55 "rebuild loop").
//
// The pre-fix actor-body rebuild iterated stagedReleasedAs with a live
// entries() cursor while revAppend deleted evicted handles from the same map.
// Measured on core@2.5.0 (scratch negative control, task 1788465031): with
// 40 handles on one id the cursor visited 37 of 40 entries and left 35 forward
// links (3 stale, 3 unmirrored); with 64 it trapped inside Map.internalEntries
// ("leaf kvIndex out of bounds") — a refused install_code in the actor body.
// These tests pin the snapshot rebuild: no trap at any chain length, every
// surviving link mirrored, and the drop deterministic (newest `cap` per id).

import ReleaseLinks "../src/backend/lib/ReleaseLinks";
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Option "mo:core/Option";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

let CAP : Nat = 32;   // = main.mo's STAGED_HANDLES_PER_ORDER_CAP
let HOT : Nat = 7;    // the id carrying the long chain
let OTHER_BASE : Nat = 9_000;

// Seed `n` handles (keys 1000..1000+n-1, ascending = oldest first) resolving
// to HOT, plus `others` one-handle links to distinct ids interleaved in key
// space so the B-tree leaves mix hot and cold entries.
func seed(fwd : ReleaseLinks.Fwd, n : Nat, others : Nat) {
  Map.clear(fwd);
  for (i in Nat.range(0, n)) { Map.add(fwd, Nat.compare, 1_000 + i, HOT) };
  for (i in Nat.range(0, others)) { Map.add(fwd, Nat.compare, 500 + 3 * i, OTHER_BASE + i) };
};

func handlesOf(rev : ReleaseLinks.Rev, id : Nat) : [Nat] {
  Option.get(Map.get(rev, Nat.compare, id), ([] : [Nat]));
};

// Every forward link is in its target's reverse entry and every reverse
// handle points back — the same mirror rule getStagedIndexAudit checks live.
func mirrorsExact(fwd : ReleaseLinks.Fwd, rev : ReleaseLinks.Rev) : Bool {
  var ok = true;
  for ((k, v) in Map.entries(fwd)) {
    var found = false;
    for (x in handlesOf(rev, v).vals()) { if (x == k) { found := true } };
    if (not found) { ok := false };
  };
  for ((v, ks) in Map.entries(rev)) {
    for (k in ks.vals()) { if (Map.get(fwd, Nat.compare, k) != ?v) { ok := false } };
  };
  ok;
};

func ascending(ks : [Nat]) : Bool {
  var ok = true;
  var i = 1;
  while (i < ks.size()) { if (ks[i] <= ks[i - 1]) { ok := false }; i += 1 };
  ok;
};

Debug.print("── ReleaseLinks.test ──");

let fwd = Map.empty<Nat, Nat>();
let rev = Map.empty<Nat, [Nat]>();

// ── 1. At the cap: nothing dropped, exact mirror. ──
seed(fwd, CAP, 5);
ReleaseLinks.rebuildReverse(fwd, rev, CAP);
truth("cap-length chain keeps all forward links", Map.size(fwd) == CAP + 5);
truth("cap-length chain keeps all handles", handlesOf(rev, HOT).size() == CAP);
truth("cap-length chain mirrors exactly", mirrorsExact(fwd, rev));

// ── 2. The silent-skip shape (40 on one id): deterministic trim. ──
seed(fwd, 40, 5);
ReleaseLinks.rebuildReverse(fwd, rev, CAP);
truth("40-chain: forward map trimmed to cap + others", Map.size(fwd) == CAP + 5);
truth("40-chain: hot id keeps exactly cap handles", handlesOf(rev, HOT).size() == CAP);
truth("40-chain: the 8 OLDEST handles are gone", Map.get(fwd, Nat.compare, 1_000) == null and Map.get(fwd, Nat.compare, 1_007) == null);
truth("40-chain: the newest cap handles survive", Map.get(fwd, Nat.compare, 1_008) == ?HOT and Map.get(fwd, Nat.compare, 1_039) == ?HOT);
truth("40-chain: surviving chain is ascending (oldest-first order kept)", ascending(handlesOf(rev, HOT)));
truth("40-chain: other ids untouched", handlesOf(rev, OTHER_BASE + 4) == [500 + 12]);
truth("40-chain: mirrors exactly", mirrorsExact(fwd, rev));

// ── 3. The trapping shape (64, and far beyond), with and without neighbours. ──
for (n in [64, 100, 200, 1_000].vals()) {
  for (o in [0, 5, 100].vals()) {
    seed(fwd, n, o);
    ReleaseLinks.rebuildReverse(fwd, rev, CAP);
    let tag = Nat.toText(n) # "-chain/" # Nat.toText(o) # " others";
    truth(tag # ": no trap, forward map = cap + others", Map.size(fwd) == CAP + o);
    truth(tag # ": hot id keeps exactly cap handles", handlesOf(rev, HOT).size() == CAP);
    truth(tag # ": newest handle survives, oldest dropped",
      Map.get(fwd, Nat.compare, 1_000 + n - 1) == ?HOT and Map.get(fwd, Nat.compare, 1_000) == null);
    truth(tag # ": mirrors exactly", mirrorsExact(fwd, rev));
  };
};

// ── 4. Two long chains at once — each trimmed independently. ──
Map.clear(fwd);
for (i in Nat.range(0, 50)) { Map.add(fwd, Nat.compare, 1_000 + i, HOT) };
for (i in Nat.range(0, 70)) { Map.add(fwd, Nat.compare, 2_000 + i, HOT + 1) };
ReleaseLinks.rebuildReverse(fwd, rev, CAP);
truth("two chains: both trimmed to cap", handlesOf(rev, HOT).size() == CAP and handlesOf(rev, HOT + 1).size() == CAP);
truth("two chains: forward map = 2 × cap", Map.size(fwd) == 2 * CAP);
truth("two chains: mirrors exactly", mirrorsExact(fwd, rev));

// ── 5. Rebuild is idempotent and clears stale reverse state. ──
Map.add(rev, Nat.compare, 424_242, [1, 2, 3]);   // a stray reverse entry
ReleaseLinks.rebuildReverse(fwd, rev, CAP);
truth("rebuild clears stale reverse entries", Map.get(rev, Nat.compare, 424_242) == null);
truth("rebuild is idempotent", Map.size(fwd) == 2 * CAP and mirrorsExact(fwd, rev));

// ── 6. Empty input. ──
Map.clear(fwd);
ReleaseLinks.rebuildReverse(fwd, rev, CAP);
truth("empty forward map → empty reverse map", Map.size(rev) == 0);

// ── 7. Steady-state insert path: revAppend trims at insert, so a chain never
//      exceeds cap between rebuilds (why no insert-time assertion is needed). ──
Map.clear(fwd); Map.clear(rev);
for (i in Nat.range(0, 40)) {
  Map.add(fwd, Nat.compare, 3_000 + i, HOT);
  ReleaseLinks.revAppend(fwd, rev, CAP, HOT, 3_000 + i);
};
truth("insert path caps the chain at cap", handlesOf(rev, HOT).size() == CAP);
truth("insert path evicts the oldest forward links", Map.size(fwd) == CAP and Map.get(fwd, Nat.compare, 3_000) == null);
truth("insert path mirrors exactly", mirrorsExact(fwd, rev));

// ── 8. revDrop detaches one handle; the last detach removes the entry. ──
ReleaseLinks.revDrop(rev, HOT, 3_039);
truth("revDrop removes one handle", handlesOf(rev, HOT).size() == CAP - 1);
Map.clear(rev);
Map.add(rev, Nat.compare, 11, [5]);
ReleaseLinks.revDrop(rev, 11, 5);
truth("revDrop of the last handle deletes the entry", Map.get(rev, Nat.compare, 11) == null);
ReleaseLinks.revDrop(rev, 12, 5);
truth("revDrop on an absent id is a no-op", Map.size(rev) == 0);

Debug.print("── ReleaseLinks.test: all passed ──");
