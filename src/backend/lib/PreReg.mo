// PreReg.mo — the hard-capped, self-expiring index of PRE-REGISTRATION
// principals (H-36 / F33, per the D4 operator answer (a′)).
//
// The problem: `getMyProfile` creates a permanent profile and
// `setUserPreferences` a permanent preferences record on the first hit from
// ANY non-anonymous principal — before the first deposit, i.e. before the
// registration the H-30 gate keys on — and no purge existed. Free keypairs
// therefore bought permanent stable-heap growth at ingress rate.
//
// The answer (D4): peak memory is bounded BY CONSTRUCTION, not by a sweep.
// This module is the recency index that makes that possible:
//
//   byKey : principalText → seq      (membership + O(log n) touch)
//   bySeq : seq → (principalText, lastSeenNs)
//           a monotone sequence number is the recency clock, so the
//           LEAST-recently-seen entry is always `minEntry(bySeq)` — eviction
//           and expiry both pop from the front in O(log n); no scan, so an
//           at-cap insert costs the same at 10 entries and at 10,000.
//
// Three operations, all on the index only — the caller (main.mo) owns the
// profile / preferences maps and deletes the victims' records itself:
//
//   touch(key, now, cap)  — record activity for an UNREGISTERED principal.
//                           A new key at capacity evicts the least-recently-
//                           seen entry first (returned so the caller drops
//                           its records). Touching a present key never evicts.
//   forget(key)           — PROMOTION: registration lifts the principal out of
//                           the bounded store; its records stay in the
//                           permanent maps, untouched by cap or expiry.
//   expire(now, grace, n) — pop up to n entries older than the grace period
//                           from the front (the heartbeat's bounded step).
//   trim(cap, n)          — pop up to n entries while over the cap (a lowered
//                           cap constant re-converges over a few ticks).
//
// The record is STABLE state in the actor (a plain `let` — Maps + `var`
// counters are stable types). Additive only: no existing field changes shape.

import Map "mo:core/Map";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import List "mo:core/List";
import Iter "mo:core/Iter";

module {
  public type Store = {
    byKey : Map.Map<Text, Nat>;
    bySeq : Map.Map<Nat, (Text, Int)>;
    var nextSeq : Nat;
    // Lifetime counters (observability — getPreRegStoreStats).
    var evicted  : Nat;   // dropped by the cap on a write
    var expired  : Nat;   // aged out by the heartbeat step
    var promoted : Nat;   // lifted out on registration (forget with a hit)
  };

  /// The venue posture, structurally identical to main.mo's DeployMode so the
  /// actor's literal passes straight through (a lib cannot import the actor).
  public type Posture = { #dev; #play; #production };

  /// inspect's CALLER policy for a PRE-REGISTRATION-SET update (getMyProfile,
  /// setUserPreferences, getUserPreferences, regenerateUsername, the two
  /// Internet Identity legs): would this caller pass, before the method
  /// routing? Anonymous never; registered always (the ordinary floor-gated
  /// path); an UNKNOWN principal — signed in, never deposited — is admitted on
  /// EVERY posture: the operator decision of 2026-09-05 (task 1788499950)
  /// made onboarding between II sign-in and the first Bridge deposit a
  /// production requirement, and the bounded store in this module (H-36 / D4
  /// a′: hard cap, LRU eviction, heartbeat expiry, promotion on registration)
  /// is the safety that makes admitting free keypairs acceptable there. The
  /// posture is a parameter so the verdict is pinned per posture
  /// (PreReg.test.mo) and a FOURTH posture cannot compile without deciding —
  /// the switch is exhaustive on purpose, not `true`.
  public func admitted(posture : Posture, anonymous : Bool, registered : Bool) : Bool {
    if (anonymous) { return false };
    if (registered) { return true };
    switch (posture) {
      case (#dev or #play or #production) { true };
    }
  };

  public func empty() : Store {
    {
      byKey = Map.empty<Text, Nat>();
      bySeq = Map.empty<Nat, (Text, Int)>();
      var nextSeq = 0;
      var evicted = 0;
      var expired = 0;
      var promoted = 0;
    }
  };

  public func size(s : Store) : Nat { Map.size(s.byKey) };

  public func contains(s : Store, key : Text) : Bool {
    Map.get(s.byKey, Text.compare, key) != null
  };

  /// lastSeenNs of `key`, if present.
  public func lastSeen(s : Store, key : Text) : ?Int {
    switch (Map.get(s.byKey, Text.compare, key)) {
      case (?seq) {
        switch (Map.get(s.bySeq, Nat.compare, seq)) {
          case (?(_, t)) { ?t };
          case null { null };
        }
      };
      case null { null };
    }
  };

  /// The least-recently-seen entry's stamp (the front of the queue).
  public func oldestSeenNs(s : Store) : ?Int {
    switch (Map.minEntry(s.bySeq)) {
      case (?(_, (_, t))) { ?t };
      case null { null };
    }
  };

  // Pop the least-recently-seen entry off both maps; null when empty.
  func popOldest(s : Store) : ?(Text, Int) {
    switch (Map.minEntry(s.bySeq)) {
      case (?(seq, (key, t))) {
        ignore Map.delete(s.bySeq, Nat.compare, seq);
        ignore Map.delete(s.byKey, Text.compare, key);
        ?(key, t)
      };
      case null { null };
    }
  };

  // Stamp `key` as the most recently seen (a fresh seq at the back).
  func stamp(s : Store, key : Text, now : Int) {
    let seq = s.nextSeq;
    s.nextSeq += 1;
    Map.add(s.byKey, Text.compare, key, seq);
    Map.add(s.bySeq, Nat.compare, seq, (key, now));
  };

  /// Record activity for an unregistered principal. Returns the key EVICTED
  /// to make room (a NEW key arriving at capacity pops the least-recently-
  /// seen entry) — the caller drops that principal's profile/preferences.
  /// A key already present is re-stamped and nothing is evicted. `cap` must
  /// be ≥ 1 (a cap of 0 admits nothing: the key is not stored and null is
  /// returned, so the caller still serves the request statelessly).
  public func touch(s : Store, key : Text, now : Int, cap : Nat) : ?Text {
    switch (Map.get(s.byKey, Text.compare, key)) {
      case (?seq) {
        ignore Map.delete(s.bySeq, Nat.compare, seq);
        stamp(s, key, now);
        null
      };
      case null {
        if (cap == 0) { return null };
        var victim : ?Text = null;
        if (Map.size(s.byKey) >= cap) {
          switch (popOldest(s)) {
            case (?(k, _)) { s.evicted += 1; victim := ?k };
            case null {};
          };
        };
        stamp(s, key, now);
        victim
      };
    }
  };

  /// Promotion on registration: lift `key` out of the bounded store. True
  /// when it was present (counted as a promotion).
  public func forget(s : Store, key : Text) : Bool {
    switch (Map.take(s.byKey, Text.compare, key)) {
      case (?seq) {
        ignore Map.delete(s.bySeq, Nat.compare, seq);
        s.promoted += 1;
        true
      };
      case null { false };
    }
  };

  /// The heartbeat's bounded step: pop up to `budget` entries whose stamp is
  /// older than `graceNs`, oldest first. Returns the keys aged out — the
  /// caller drops their records (checking registration first: a key that
  /// registered without passing through `forget` is a promotion, not a drop).
  public func expire(s : Store, now : Int, graceNs : Int, budget : Nat) : [Text] {
    let out = List.empty<Text>();
    label pop while (List.size(out) < budget) {
      switch (Map.minEntry(s.bySeq)) {
        case (?(_, (_, t))) {
          if (now - t < graceNs) { break pop };
          switch (popOldest(s)) {
            case (?(k, _)) { s.expired += 1; List.add(out, k) };
            case null { break pop };
          };
        };
        case null { break pop };
      };
    };
    Iter.toArray(List.values(out))
  };

  /// Re-converge on a LOWERED cap: pop up to `budget` least-recently-seen
  /// entries while the store is over `cap`. Returns the keys dropped.
  public func trim(s : Store, cap : Nat, budget : Nat) : [Text] {
    let out = List.empty<Text>();
    label pop while (Map.size(s.byKey) > cap and List.size(out) < budget) {
      switch (popOldest(s)) {
        case (?(k, _)) { s.evicted += 1; List.add(out, k) };
        case null { break pop };
      };
    };
    Iter.toArray(List.values(out))
  };
}
