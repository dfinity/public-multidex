// Unit tests for src/backend/lib/PreReg.mo — the hard-capped, self-expiring
// pre-registration index (H-36 / F33, D4 (a′)). Pins: a new key at capacity
// evicts exactly the LEAST-recently-seen entry; touching a present key
// re-stamps without evicting; the store never exceeds the cap under a flood
// of fresh keys; forget lifts a key out (promotion) and frees its slot;
// expire pops only entries older than the grace, oldest first, at most the
// budget; trim re-converges on a lowered cap; cap 0 stores nothing.

import PreReg "../src/backend/lib/PreReg";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

let s = PreReg.empty();
truth("empty store has size 0", PreReg.size(s) == 0);
truth("empty store has no oldest", PreReg.oldestSeenNs(s) == null);

// ── cap = 3: fill, then the fourth evicts the least-recently-seen ──
truth("a: first touch stores, evicts nothing", PreReg.touch(s, "a", 100, 3) == null);
truth("b: stores", PreReg.touch(s, "b", 200, 3) == null);
truth("c: stores (at cap now)", PreReg.touch(s, "c", 300, 3) == null);
truth("size 3 at cap", PreReg.size(s) == 3);
truth("oldest is a's stamp", PreReg.oldestSeenNs(s) == ?100);
// Re-touch a: it becomes the most recent; b is now the oldest.
truth("re-touching a present key evicts nothing", PreReg.touch(s, "a", 400, 3) == null);
truth("size unchanged by a re-touch", PreReg.size(s) == 3);
truth("a's stamp moved", PreReg.lastSeen(s, "a") == ?400);
truth("oldest is now b", PreReg.oldestSeenNs(s) == ?200);
// A NEW key at cap evicts b (least recently seen), not a (recently touched).
truth("d at cap evicts b (LRU), not the re-touched a", PreReg.touch(s, "d", 500, 3) == ?"b");
truth("b is gone", not PreReg.contains(s, "b"));
truth("a survived", PreReg.contains(s, "a"));
truth("size still 3", PreReg.size(s) == 3);
truth("evicted counter 1", s.evicted == 1);

// ── flood: 50 fresh keys through cap 3 — size never exceeds the cap ──
var i = 0;
var evictions = 0;
while (i < 50) {
  switch (PreReg.touch(s, "f" # Nat.toText(i), 1000 + i, 3)) {
    case (?_) { evictions += 1 };
    case null {};
  };
  if (PreReg.size(s) > 3) { Runtime.trap("FAIL: size exceeded the cap mid-flood") };
  i += 1;
};
truth("50-key flood: size == cap", PreReg.size(s) == 3);
truth("50-key flood: one eviction per insert", evictions == 50);
truth("the three most recent survive", PreReg.contains(s, "f47") and PreReg.contains(s, "f48") and PreReg.contains(s, "f49"));

// ── forget = promotion: frees a slot, counts once, idempotent ──
truth("forget a present key → true", PreReg.forget(s, "f48"));
truth("forget frees the slot", PreReg.size(s) == 2);
truth("promoted counter 1", s.promoted == 1);
truth("forget an absent key → false", not PreReg.forget(s, "f48"));
truth("promoted counter unchanged by a miss", s.promoted == 1);
truth("next insert fills the freed slot without evicting", PreReg.touch(s, "g", 2000, 3) == null);

// ── expire: oldest first, only past the grace, at most the budget ──
let e = PreReg.empty();
ignore PreReg.touch(e, "p", 1_000, 10);
ignore PreReg.touch(e, "q", 2_000, 10);
ignore PreReg.touch(e, "r", 3_000, 10);
ignore PreReg.touch(e, "s", 9_000, 10);
// now = 10_000, grace 5_000: p, q, r are older than the grace; s is not.
let ex1 = PreReg.expire(e, 10_000, 5_000, 2);
truth("expire honours the budget (2 of 3 due)", ex1.size() == 2);
truth("expire pops oldest first (p, q)", ex1[0] == "p" and ex1[1] == "q");
let ex2 = PreReg.expire(e, 10_000, 5_000, 10);
truth("second step pops the remaining due entry only (r)", ex2.size() == 1 and ex2[0] == "r");
truth("s (inside the grace) survives", PreReg.contains(e, "s") and PreReg.size(e) == 1);
truth("expired counter 3", e.expired == 3);
truth("nothing due → empty step", PreReg.expire(e, 10_000, 5_000, 10).size() == 0);
// A re-touched key's age is measured from its LAST stamp, not its first.
ignore PreReg.touch(e, "s", 14_000, 10);
truth("re-touched s is not due at now = 15_000 (age 1_000 < grace)", PreReg.expire(e, 15_000, 5_000, 10).size() == 0);
truth("…and is due at now = 19_001", PreReg.expire(e, 19_001, 5_000, 10) == ["s"]);
truth("store empty after the last expiry", PreReg.size(e) == 0 and PreReg.oldestSeenNs(e) == null);

// ── trim: a lowered cap re-converges, oldest first, bounded ──
let t = PreReg.empty();
var j = 0;
while (j < 10) { ignore PreReg.touch(t, "t" # Nat.toText(j), j, 100); j += 1 };
truth("10 stored under cap 100", PreReg.size(t) == 10);
let tr1 = PreReg.trim(t, 4, 3);
truth("trim honours the budget (3 popped)", tr1.size() == 3 and PreReg.size(t) == 7);
truth("trim pops oldest first", tr1[0] == "t0" and tr1[2] == "t2");
let tr2 = PreReg.trim(t, 4, 100);
truth("trim stops AT the cap", tr2.size() == 3 and PreReg.size(t) == 4);
truth("trim at/under cap is a no-op", PreReg.trim(t, 4, 100).size() == 0);
truth("the four most recent survive the trim", PreReg.contains(t, "t6") and PreReg.contains(t, "t9"));

// ── cap 0: nothing is stored, nothing evicted, request still served ──
let z = PreReg.empty();
truth("cap 0: touch stores nothing and evicts nothing", PreReg.touch(z, "x", 1, 0) == null and PreReg.size(z) == 0);

// ── cap 1: every new key replaces the previous one ──
let o = PreReg.empty();
truth("cap 1: first stores", PreReg.touch(o, "m", 1, 1) == null);
truth("cap 1: second evicts the first", PreReg.touch(o, "n", 2, 1) == ?"m");
truth("cap 1: size stays 1", PreReg.size(o) == 1 and PreReg.contains(o, "n"));

// ── admitted: inspect's caller policy for the pre-registration set is
// posture-INDEPENDENT (operator decision 2026-09-05, task 1788499950) ──
// A signed-in, never-deposited principal reaches getMyProfile / preferences /
// username / the two II legs on #production exactly as on #dev and #play —
// the bounded store above is what makes that safe. Anonymous is refused on
// every posture; registered is admitted on every posture.
for (posture in [#dev, #play, #production].values()) {
  let tag = debug_show(posture);
  truth("admitted: unknown principal admitted on " # tag, PreReg.admitted(posture, false, false));
  truth("admitted: registered principal admitted on " # tag, PreReg.admitted(posture, false, true));
  truth("admitted: anonymous refused on " # tag, not PreReg.admitted(posture, true, false));
  truth("admitted: anonymous refused on " # tag # " even if marked registered", not PreReg.admitted(posture, true, true));
};

Debug.print("PreReg.test.mo: all pins hold");
