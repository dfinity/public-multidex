// SafeMath.mo — small saturating-arithmetic helpers for the integer ledger.
//
// Motoko's `Nat` subtraction TRAPS on underflow (it never wraps), so the
// codebase guards every defensive subtraction with `if (a > b) { a - b }
// else { 0 }`. That idiom is correct but the compiler can't see the guard, so
// it emits a conservative `M0155 — operator may trap` warning at every site.
//
// `subOrZero` is that idiom, named once. It computes the difference in `Int`
// (which never traps) and clamps to zero, so it is genuinely trap-free AND does
// not itself trigger M0155 — call sites read `SafeMath.subOrZero(a, b)` instead
// of an inline guard, which states the "clamp to zero" intent explicitly.
//
// Use it ONLY where clamping a negative result to 0 is the INTENDED semantics
// (e.g. `available = max(0, balance - reserved)`). Do NOT use it to silence a
// subtraction whose non-negativity is a real INVARIANT — there, the trap is a
// feature (it surfaces a violated invariant instead of masking it with a 0).
import Int "mo:core/Int";
import Nat "mo:core/Nat";

module {
  // max(0, a - b). Never traps; never warns.
  public func subOrZero(a : Nat, b : Nat) : Nat {
    let d = (a : Int) - b;
    if (d > 0) { Int.abs(d) } else { 0 };
  };

  // ── The RELAY CEILING (H-15 / H-27, finding F5) ──────────────────────
  // `Nat` is unbounded and `Nat.toText` is the per-decimal-digit bignum loop
  // (Θ(bits²)): a ~100 KB Nat formatted into a refusal text burns a
  // canister's whole 40 B instruction budget and traps (IC0522). Every
  // caller-supplied Nat that crosses the Bridge↔DEX relay (amount, seq,
  // pendingUnits, the outstanding hints) is therefore refused above this
  // ceiling BEFORE it is valued, compared against state, or formatted. The
  // value is the one the Bridge's AMOUNT_CEILING uses (src/bridge/main.mo),
  // so the two halves agree: fixed and price-independent, ~3.4e30 whole units
  // of any asset (no real deposit approaches it), and everything at or below
  // it has ≤ 39 decimal digits — the compare itself is one linear bignum op.
  public let RELAY_CEILING : Nat = 340_282_366_920_938_463_463_374_607_431_768_211_456;   // 2^128 (a module `let` must be static — no `**`)
  public let RELAY_CEILING_TEXT : Text = "≥2^128";

  public func withinRelayCeiling(n : Nat) : Bool { n <= RELAY_CEILING };

  // Format a Nat for a refusal/log text WITHOUT ever paying the quadratic
  // toText on a caller-sized value: at or below the ceiling it is the plain
  // decimal (≤ 39 digits, bounded cost); above it the text says so instead
  // of spelling the digits. Use this — never Nat.toText — for any value
  // that a caller could have sized (amounts, seqs, and anything derived from
  // them, e.g. a mark valuation or a seq difference).
  public func natDisplay(n : Nat) : Text {
    if (n <= RELAY_CEILING) { Nat.toText(n) } else { RELAY_CEILING_TEXT };
  };
};
