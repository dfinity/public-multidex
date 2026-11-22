// Release-link index maintenance (W1-07), factored out of main.mo so the
// start-time reverse rebuild is a pure function `mops test` can exercise.
//
// Two maps, kept as exact mirrors:
//   fwd : handle (placement / staged id) → the live order id it resolves to
//         (main.mo's `stagedReleasedAs`, STABLE)
//   rev : live order id → the handles that currently resolve to it
//         (main.mo's `stagedReleasedFrom`, TRANSIENT — derived, rebuilt on
//         every start by `rebuildReverse`)
//
// Public issue #55 "rebuild loop" (round 18): the actor-body rebuild was
//   for ((k, v) in Map.entries(fwd)) { revAppend(v, k) }
// and revAppend DELETES from fwd once an id carries more than `cap` handles —
// a delete under a live entries() cursor. Reproduced on core@2.5.0: 40
// handles on one id → the cursor silently skips entries and leaves stale
// forward links; 64 → traps inside Map.internalEntries ("leaf kvIndex out of
// bounds"), which in the actor body is a REFUSED install_code. The rebuild
// now walks an array SNAPSHOT of fwd, so every delete lands on a map nobody
// is iterating, and the outcome is deterministic: per id, the NEWEST `cap`
// handles survive (ids are monotone, so ascending key order is age order)
// and the older ones are dropped from both maps.
//
// Why no insert-time assertion instead: revAppend already trims at every
// insert, so a chain longer than `cap` can only enter fwd from a build that
// predates the cap (stable state written before W1-07, or the W4-07
// intermediate). A trap at insert time would fire inside tickAmm's awaitless
// per-pool message — the exact AMM-offline shape W1-07 closed — and would
// not remove the need to trim pre-existing chains at start anyway.
import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Option "mo:core/Option";
import Iter "mo:core/Iter";

module {
  public type Fwd = Map.Map<Nat, Nat>;
  public type Rev = Map.Map<Nat, [Nat]>;

  // Detach `key` from `orderId`'s reverse entry (drops the entry when empty).
  public func revDrop(rev : Rev, orderId : Nat, key : Nat) {
    switch (Map.get(rev, Nat.compare, orderId)) {
      case (?ks) {
        let left = Array.filter<Nat>(ks, func(k : Nat) : Bool { k != key });
        if (left.size() == 0) { ignore Map.delete(rev, Nat.compare, orderId) }
        else { Map.add(rev, Nat.compare, orderId, left) };
      };
      case null {};
    };
  };

  // Append `key` to `orderId`'s reverse entry, applying the per-order cap:
  // when the chain exceeds `cap`, the OLDEST handles are evicted and their
  // forward links deleted too, so the two maps never disagree. Callers must
  // not hold a live iterator over `fwd` (see `rebuildReverse`).
  public func revAppend(fwd : Fwd, rev : Rev, cap : Nat, orderId : Nat, key : Nat) {
    var next = Array.concat(Option.get(Map.get(rev, Nat.compare, orderId), ([] : [Nat])), [key]);
    if (next.size() > cap) {
      let drop : Nat = next.size() - cap;
      for (i in Nat.range(0, drop)) { ignore Map.delete(fwd, Nat.compare, next[i]) };
      next := Array.sliceToArray(next, drop, next.size());
    };
    Map.add(rev, Nat.compare, orderId, next);
  };

  // Rebuild `rev` from `fwd` (clearing it first), trimming any chain longer
  // than `cap` to its newest `cap` handles. Iterates a snapshot: no delete
  // ever happens on `fwd` while an entries() cursor over it is live.
  public func rebuildReverse(fwd : Fwd, rev : Rev, cap : Nat) {
    Map.clear(rev);
    let snapshot = Iter.toArray(Map.entries(fwd));
    for ((k, v) in snapshot.vals()) { revAppend(fwd, rev, cap, v, k) };
  };
};
