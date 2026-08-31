// Pins the FIFTH latent OQL defect (W6-08 watch list; filed 2026-08-10 into
// the #21 thread): Registry.build (src/backend/oql/Registry.mo) inserts decls
// with Map.add, which silently OVERWRITES on a duplicate key — two entities
// declared with the same name collapse to whichever comes LAST, `.auth(...)`
// policy included. A later `.public_()` decl would silently replace an
// owner-scoped one, with no diagnostic anywhere.
//
// Two pins, both load-bearing:
//   1. build() does NOT trap on a duplicate — and the fix must NEVER become a
//      trap: build runs in the `transient` initializer, which executes during
//      upgrade, so a trapping duplicate check makes the release carrying the
//      duplicate UNSHIPPABLE (the upgrade itself fails). If this test starts
//      trapping, read src/backend/oql/README.md's latent-defect watch before
//      "fixing" anything.
//   2. Last-wins, auth included — the silent collision this documents.
//
// A .mo unit test cannot reach the REAL decl arrays in main.mo (they close
// over actor state); those are guarded statically by
// tests/test_deploy_hygiene.sh §7g (no duplicate entity names per registry).

// NatValue is imported for its `_toRow` instance — the compiler resolves the
// builder's implicit `Nat -> Value` argument against directly imported modules.
import Entity   "../src/backend/oql/Entity";
import Registry "../src/backend/oql/Registry";
import NatValue "../src/backend/oql/NatValue";
import Debug   "mo:core/Debug";
import Iter    "mo:core/Iter";
import Option  "mo:core/Option";
import Runtime "mo:core/Runtime";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

Debug.print("── OqlRegistry.test ──");

// Minimal pure decl — no actor state, rows from a literal array.
func decl(name : Text, rows : [Nat], pub : Bool) : Entity.Decl {
  let b = Entity.manual<Nat>(name, func () = rows.values(), "Row", "id")
    .sample(0)
    .payload("id", func n = n);
  (if (pub) { b.public_() } else { b.controllerOnly() }).build()
};

// ── Baseline: unique names all land ──
let r1 = Registry.build([decl("a", [1], true), decl("b", [2], false)]);
truth("unique names: 'a' present", Option.isSome(Registry.lookup(r1, "a")));
truth("unique names: 'b' present", Option.isSome(Registry.lookup(r1, "b")));
truth("unique names: unknown lookup is null", Option.isNull(Registry.lookup(r1, "c")));

// ── The defect: a duplicate name is a silent overwrite, not an error ──
// First decl: #controllerOnly with 1 row. Second: #public_ with 2 rows.
let r2 = Registry.build([decl("dup", [1], false), decl("dup", [2, 3], true)]);
// Reaching this line IS pin 1 — build() must not trap on the duplicate
// (upgrade-initializer constraint above).
truth("duplicate name: build() does not trap (must stay non-trapping — see oql/README latent-defect watch)", true);
switch (Registry.lookup(r2, "dup")) {
  case (?d) {
    truth("duplicate name: LAST decl's auth silently wins (#controllerOnly -> #public_)",
      d.auth == #public_);
    truth("duplicate name: LAST decl's rows silently win (2 rows, not 1)",
      Iter.size(d.rows(null)) == 2);
  };
  case null { Runtime.trap("FAIL: 'dup' entity vanished from the registry entirely") };
};

Debug.print("── OqlRegistry.test PASSED ──");
