// Unit tests for src/backend/lib/VaultLock.mo — per-LP locked shares + the
// global lock-scale index (task 1788475756), in integer base units (10^8).
// Every expectation below is computed from the PER-LP TRUTH the model
// compresses (cash entitlement e_i, loan claim λ_i = NAV_i − e_i, repayment
// pro rata to λ), never from the lib's own formulas — RED/GREEN by
// construction: a wrong factor cannot agree with an independent derivation.

import VL "../src/backend/lib/VaultLock";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";
import Nat "mo:core/Nat";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func nearN(name : Text, a : Nat, b : Nat, tol : Nat) {
  let d = if (a > b) { (a - b) : Nat } else { (b - a) : Nat };
  if (d > tol) { Runtime.trap("FAIL: " # name # " — expected ≈" # debug_show b # " got " # debug_show a # " (diff " # debug_show d # ")") };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

Debug.print("── VaultLock.test ──");

let KEEP : Nat = 9_960;   // LP_EXIT_FEE_BPS = 40
let SC = VL.SCALE;

// ── The worked example of task 1788475756: two equal LPs, H = L = $100k ──
// S = 200k LP, A = B = 100k LP, H = $100k held, NAV = $200k (loan book $100k).
var S : Nat = 20_000_000_000_000;
var sA : Nat = 10_000_000_000_000; var sB : Nat = 10_000_000_000_000;
var H : Nat = 10_000_000_000_000;
var NAV : Nat = 20_000_000_000_000;
// the actor's state: raw locks, their sum, the index
var rawA : Nat = 0; var rawB : Nat = 0; var rawSum : Nat = 0; var scale : Nat = SC;

func lockA() : Nat { VL.lockOf(rawA, scale, sA) };
func lockB() : Nat { VL.lockOf(rawB, scale, sB) };
func lam() : Nat { VL.totalLock(rawSum, scale, S) };
func capUsdA() : Nat { VL.capUsd(sA, lockA(), S, lam(), H, KEEP) };
func capUsdB() : Nat { VL.capUsd(sB, lockB(), S, lam(), H, KEEP) };
func capLpA() : Nat { VL.capLp(sA, lockA(), S, lam(), H, NAV) };
// gross NAV of x shares, and the net payout the vault hands out
func gross(x : Nat) : Nat { x * NAV / S };
func paid(x : Nat) : Nat { x * NAV * KEEP / (S * 10_000) };

// No locks: the caps ARE the stateless cap — A's share of holdings × 0.996.
eqN("no locks: A's cap = s_A/S × H × 0.996", capUsdA(), 4_980_000_000_000);
eqN("no locks: A's max shares = s_A × H / NAV = 50k LP", capLpA(), 5_000_000_000_000);
truth("no locks: exactly the cap is within", VL.withinCap(5_000_000_000_000, sA, 0, S, 0, H, NAV));
truth("no locks: one unit past the cap is refused", not VL.withinCap(5_000_000_000_001, sA, 0, S, 0, H, NAV));
truth("no locks: the full balance is refused at 50% utilisation", not VL.withinCap(sA, sA, 0, S, 0, H, NAV));

// A's MAX exit: x = 50k LP, gross $50k, paid $49.8k; the fee stays as cash.
let eB0 = capUsdB();
let x1 = capLpA();
let g1 = gross(x1); let p1 = paid(x1);
let newLockA = VL.lockAfterExit(sA, lockA(), x1, S, lam(), H, NAV);
// apply the exit to the world
S -= x1; sA -= x1; H -= p1; NAV -= p1;
rawA := VL.rawFor(newLockA, scale); rawSum := rawA + rawB;
eqN("max exit: A's remaining 50k shares are ALL locked", lockA(), sA);
eqN("max exit: A's cap is 0 — nothing left to iterate on", capUsdA(), 0);
eqN("max exit: A's max shares 0", capLpA(), 0);
truth("max exit: a second 1-unit request is refused", not VL.withinCap(1, sA, lockA(), S, lam(), H, NAV));
let eB1 = capUsdB();
truth("invariance: B's cap did not fall on A's exit", eB1 >= eB0);
truth("invariance: B's cap rose by at most A's fee (the cash the exit left behind)", eB1 <= eB0 + (g1 - p1));
nearN("invariance: B's cap = her whole (unchanged) cash claim + A's fee, × 0.996", eB1, (H * KEEP) / 10_000, 2);
eqN("Σ e_i = H: B holds every unlocked share, so her gross cash claim is exactly H", VL.capUsd(sB, lockB(), S, lam(), H, 10_000), H);

// The harmonic drain, bounded: ten further "max exits" by A take NOTHING.
var taken = p1;
var i = 0;
while (i < 10) {
  let x = capLpA();
  if (x > 0) { taken += paid(x); S -= x; sA -= x };
  i += 1;
};
eqN("harmonic drain: ten more max exits by A take nothing beyond the first (A ≤ her share of held cash)", taken, p1);
eqN("harmonic drain: B's cap after A's eleven exits is her full cash claim", capUsdB(), eB1);

// ISSUANCE / interest / mark moves change no lock (R = 0): the index is untouched.
let s0 = VL.settle(scale, rawSum, S, H, NAV + 1_000_000_000_000, 0);   // NAV up $10k (interest / issuance)
truth("issuance: R = 0 leaves the index unchanged", (not s0.clear) and s0.scale == scale);

// PARTIAL REPAYMENT R = $50k of the $100k loan book: cash comes back to every
// LP pro rata to their LOAN claim (the per-LP truth), and the model's single
// index must reproduce it for BOTH LPs.
let R = 5_000_000_000_000;
let lxPre : Nat = NAV - H;
let navA = sA * NAV / S; let navB = sB * NAV / S;
let eA_pre = VL.capUsd(sA, lockA(), S, lam(), H, 10_000);   // 0
let eB_pre = VL.capUsd(sB, lockB(), S, lam(), H, 10_000);   // H
let lamA : Nat = navA - eA_pre; let lamB : Nat = navB - eB_pre;
let truthA = eA_pre + R * lamA / lxPre;
let truthB = eB_pre + R * lamB / lxPre;
H += R;   // the repayment lands as cash; NAV is unchanged
let s1 = VL.settle(scale, rawSum, S, H, NAV, R);
truth("partial repayment: locks survive (not cleared)", not s1.clear);
truth("partial repayment: the index SHRANK (locks release by a common factor)", s1.scale < scale);
scale := s1.scale;
nearN("partial repayment: A's cash claim = R × λ_A / Lx (pro rata to her loan claim)", VL.capUsd(sA, lockA(), S, lam(), H, 10_000), truthA, 4);
nearN("partial repayment: B's cash claim = e_B + R × λ_B / Lx", VL.capUsd(sB, lockB(), S, lam(), H, 10_000), truthB, 4);
nearN("partial repayment: Σ e_i still == H", VL.capUsd(sA, lockA(), S, lam(), H, 10_000) + VL.capUsd(sB, lockB(), S, lam(), H, 10_000), H, 4);
truth("partial repayment: A's cap is now > 0 and A still holds locked shares", capUsdA() > 0 and lockA() > 0 and lockA() < sA);

// A second partial repayment of the remaining $50k = a FULL repayment: c = 0.
let s2 = VL.settle(scale, rawSum, S, H + R, NAV, R);
truth("full repayment: every lock clears (c = 0)", s2.clear);
// And with NAV ≤ H (arrears past the loan book) locks are meaningless: clear.
let s3 = VL.settle(scale, rawSum, S, H, H, 0);
truth("NAV ≤ H: locks clear", s3.clear);

// CONSISTENCY CLAMP: mark drift that makes locked shares claim more loan
// value than exists (Λ·NAV > S·Lx) is clamped to Λ = S·Lx/NAV.
let s4 = VL.settle(SC, rawSum, S, H, H + 1_000_000_000, 0);   // Lx = $10, Λ = 50k LP
truth("clamp: the index drops so that Λ·NAV ≤ S·Lx", not s4.clear and VL.totalLock(rawSum, s4.scale, S) * (H + 1_000_000_000) <= S * 1_000_000_000);

// ── WRITE-OFF classification (task 1788752774) ──
// A loss written off (absorbBadDebt's uncovered residual) shrinks the loan
// book WITHOUT cash arriving: per LP, λ_i falls pro rata and e_i is
// UNCHANGED — no lock moves. The actor nets the written-off USD out of the
// units-diff, so the lib sees repaidUsd = 0 for a pure loss; the old
// classification (every shrink is a repayment) is the RED control below.
// World here: A partially locked (after the $50k repayment), H = $100.2k,
// NAV = $150.2k (Lx = $50k), S = 150k LP.
let eA_w = VL.capUsd(sA, lockA(), S, lam(), H, 10_000);
let eB_w = VL.capUsd(sB, lockB(), S, lam(), H, 10_000);
let U1 = 1_000_000_000_000;   // a $10k write-off, well inside the clamp's slack
truth("write-off fixture: A is partially locked and Λ·(NAV − U) ≤ S·(Lx − U) (the clamp has slack)",
  lockA() > 0 and lockA() < sA and lam() * (NAV - U1) <= S * ((NAV - H) - U1));
let sW = VL.settle(scale, rawSum, S, H, NAV - U1, 0);   // NAV fell by the loss, H unchanged, repaidUsd = 0
truth("pure loss: the index is UNCHANGED (no lock moves, nothing cleared)", (not sW.clear) and sW.scale == scale);
eqN("pure loss: A's cash entitlement e_A is unchanged (the per-LP truth)", VL.capUsd(sA, lockA(), S, lam(), H, 10_000), eA_w);
eqN("pure loss: B's cash entitlement e_B is unchanged", VL.capUsd(sB, lockB(), S, lam(), H, 10_000), eB_w);
nearN("pure loss: Σ e_i == H still (caps round DOWN: at most a base unit under)", eA_w + eB_w, H, 2);
// The RED control: classified as a repayment the same shrink would have
// scaled the locks down and handed A cash out of B's — the pre-fix bug.
let sWold = VL.settle(scale, rawSum, S, H, NAV - U1, U1);
truth("pure loss misclassified as a repayment WOULD shrink the index (the bug this task closes)", (not sWold.clear) and sWold.scale < scale);
truth("...and hand the locked LP cash that never arrived", VL.capUsd(sA, VL.lockOf(rawA, sWold.scale, sA), S, VL.totalLock(rawSum, sWold.scale, S), H, 10_000) > eA_w);
// Apply the loss to the world.
NAV -= U1;

// MIXED: covered cash C (the insurance fund paying the vault) + uncovered loss
// U in ONE message — absorbBadDebt's shape. The loss lands on NAV ONE SHARE
// CLASS (NAV_i = s_i·NAV/S always; e_i unchanged, so λ_i' = s_i·NAV_post/S −
// e_i — a locked LP's claim falls by U·s_i/S, not U·λ_i/Lx: the half of the
// per-LP truth the representation cannot carry), then the cash lands pro
// rata to that post-loss claim: e_i' = e_i + C·λ_i'/Lx' with Lx' = Lx − U.
// The lib reproduces it from the post observables with repaidUsd = C (its
// Lx_pre = Lx_post + C = Lx − U).
let C2 = 500_000_000_000;     // $5k of cash
let U2 = 1_000_000_000_000;   // $10k written off
let lxPostLoss : Nat = (NAV - H) - U2;                       // Lx once the loss is out
let navA_m = sA * (NAV - U2) / S; let navB_m = sB * (NAV - U2) / S;   // one share class, post-loss
let eA_m = VL.capUsd(sA, lockA(), S, lam(), H, 10_000);
let eB_m = VL.capUsd(sB, lockB(), S, lam(), H, 10_000);
let lamA_m : Nat = navA_m - eA_m; let lamB_m : Nat = navB_m - eB_m;
let truthA_m = eA_m + C2 * lamA_m / lxPostLoss;
let truthB_m = eB_m + C2 * lamB_m / lxPostLoss;
H += C2; NAV -= U2;   // the cash lands (NAV unchanged by it), the loss leaves NAV
let sM = VL.settle(scale, rawSum, S, H, NAV, C2);
truth("mixed cash + loss: locks survive and the index shrank by the CASH only", (not sM.clear) and sM.scale < scale);
truth("mixed: the index shrank LESS than the old classification (C + U as cash) would have", sM.scale > VL.settle(scale, rawSum, S, H, NAV, C2 + U2).scale);
scale := sM.scale;
nearN("mixed: A's cash claim = e_A + C × λ_A / Lx_pre (the loss moved nothing)", VL.capUsd(sA, lockA(), S, lam(), H, 10_000), truthA_m, 4);
nearN("mixed: B's cash claim = e_B + C × λ_B / Lx_pre", VL.capUsd(sB, lockB(), S, lam(), H, 10_000), truthB_m, 4);
nearN("mixed: Σ e_i == H", VL.capUsd(sA, lockA(), S, lam(), H, 10_000) + VL.capUsd(sB, lockB(), S, lam(), H, 10_000), H, 4);

// A loss LARGER than the clamp's slack: the one share class cannot carry a
// locked LP's loan claim above the book, so Λ is clamped to S·Lx/NAV — the
// ONLY lock movement a loss may cause, and Σ e_i == H holds through it.
let lxNow : Nat = NAV - H;
let U3 : Nat = lxNow - lxNow / 10;   // 90% of the remaining loan value is lost
let sBig = VL.settle(scale, rawSum, S, H, NAV - U3, 0);
truth("big loss: locks survive (some loan value remains) but the clamp binds", (not sBig.clear) and sBig.scale < scale);
let lamBig = VL.totalLock(rawSum, sBig.scale, S);
truth("big loss: Λ·NAV ≤ S·Lx after the clamp", lamBig * (NAV - U3) <= S * (lxNow - U3));
nearN("big loss: Σ e_i == H through the clamp", VL.capUsd(sA, VL.lockOf(rawA, sBig.scale, sA), S, lamBig, H, 10_000) + VL.capUsd(sB, VL.lockOf(rawB, sBig.scale, sB), S, lamBig, H, 10_000), H, 4);
truth("big loss: the locked LP's cash rises by the clamp only — never above her one-share-class NAV",
  VL.capUsd(sA, VL.lockOf(rawA, sBig.scale, sA), S, lamBig, H, 10_000) <= sA * (NAV - U3) / S + 1);

// RENORMALISATION: below the floor the raw locks absorb the index; no lock
// shrinks and the effective locks are preserved to the unit.
let tiny = VL.RENORM_FLOOR / 7;
truth("renorm: a scale under the floor asks for it", VL.needsRenorm(tiny) and not VL.needsRenorm(SC));
let lockAtTiny = VL.lockOf(rawA, tiny, sA);
let rawA2 = VL.renormRaw(rawA, tiny);
let lockAfter = VL.lockOf(rawA2, SC, sA);
truth("renorm: the effective lock is preserved (never smaller)", lockAfter >= lockAtTiny and lockAfter <= lockAtTiny + 1);

// ROUNDING: rawFor/lockOf round UP (a lock never under-states); Λ rounds DOWN.
let r = VL.rawFor(3, SC / 3);
truth("rounding: rawFor rounds up", VL.lockOf(r, SC / 3, 1_000) >= 3);
eqN("rounding: Λ rounds down", VL.totalLock(1, SC / 3, 1_000), 0);
eqN("rounding: ℓ rounds up", VL.lockOf(1, SC / 3, 1_000), 1);

// ZERO-UTILISATION EXIT locks nothing: with NAV == H the claim equals x.
eqN("zero utilisation: an exit locks nothing", VL.lockAfterExit(1_000, 0, 100, 10_000, 0, 5_000, 5_000), 0);
// A hair of utilisation locks a hair — rounded UP to the unit (the vault's favour).
eqN("near-zero utilisation: the lock rounds up to one unit", VL.lockAfterExit(1_000, 0, 100, 10_000, 0, 5_000, 5_001), 1);
// lockedNavUsd = Λ × NAV / S.
eqN("lockedNavUsd = Λ × NAV / S", VL.lockedNavUsd(5_000, 10_000, 200_000), 100_000);

Debug.print("VaultLock.test: all passed");
