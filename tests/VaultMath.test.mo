// Unit tests for src/backend/lib/VaultMath.mo in integer base units (10^8). Pins
// the ERC-4626 donation-inflation guard on the mint ratio and the over-weight
// deposit-fee curve.

import VM "../src/backend/lib/VaultMath";
import Fixed "../src/backend/lib/Fixed";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

func eqN(name : Text, a : Nat, b : Nat) {
  if (a != b) { Runtime.trap("FAIL: " # name # " — expected " # debug_show b # " got " # debug_show a) };
  Debug.print("  ✓ " # name);
};
func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

Debug.print("── VaultMath.test ──");

// ── mintAmount ──
// First deposit of 1000 → 1000 LP (valuePerLP = 1.0).
eqN("mint: first deposit = its value", VM.mintAmount(100_000_000_000, 0, 0), 100_000_000_000);
// Equal-value follow-on (supply 1000, vault 1000, deposit 1000) → ~1000 LP.
eqN("mint: fair follow-on deposit", VM.mintAmount(100_000_000_000, 100_000_000_000, 100_000_000_000), 100_000_000_000);

// ── ERC-4626 donation-inflation guard ──
// Attacker dust supply (0.001 LP), DONATES to inflate vault to 1000, victim
// deposits 1000. Unguarded: value×supply/vaultValue = 1000×0.001/1000 = 0.001 LP.
// Guarded: ~1.0 LP (≈1000× more) — attack neutralised.
let naive : Nat = 100_000;                                   // 0.001 LP (the unguarded mint)
let guarded = VM.mintAmount(100_000_000_000, 100_000, 100_000_000_000); // dust supply 0.001
eqN("mint: guard yields ~1.0 LP", guarded, 100_000_000);
truth("mint: guard mints >> the naive (drained) amount", guarded > naive * 100);

// ── feeMultiplier (weights at 10^8: 0.125 = 12_500_000) ──
eqN("fee: at target = 1.0",     VM.feeMultiplier(12_500_000, 12_500_000), 100_000_000);
eqN("fee: under-weight = 1.0",  VM.feeMultiplier(5_000_000, 12_500_000), 100_000_000);
eqN("fee: zero target = 1.0",   VM.feeMultiplier(50_000_000, 0), 100_000_000);
// 2× target → gap 1.0 → MAX fee → multiplier 0.90
eqN("fee: 2× target → max fee", VM.feeMultiplier(25_000_000, 12_500_000), 90_000_000);
// 1.2× target → gap 0.2 → fee 0.10×0.04 = 0.004 → multiplier 0.996
eqN("fee: mild over-weight",    VM.feeMultiplier(15_000_000, 12_500_000), 99_600_000);
// 4× target → gap² clamped to 1 → fee stays MAX → multiplier 0.90
eqN("fee: capped at max beyond 2×", VM.feeMultiplier(50_000_000, 12_500_000), 90_000_000);

// ── Redemption at NAV + the pro-rata instant-liquidity cap (task 1788465539) ──
// Vault: held H = 150k, loan book L = 50k, no arrears → NAV = 200k, supply
// 200k (valuePerLP 1.0). Two equal LPs of 100k shares each. keepBps = 9960.
let H : Nat = 15_000_000_000_000;   // $150k
let NAV : Nat = 20_000_000_000_000; // $200k
let S : Nat = 20_000_000_000_000;   // 200k LP
let LP : Nat = 10_000_000_000_000;  // 100k LP (one LP's balance)
let KEEP : Nat = 9_960;

// F2/F3: a share redeems at NAV × keepBps — the loan book is NOT forfeited.
eqN("redeem: 100k LP at NAV 1.0 pays 99,600 (NAV × 0.996)", VM.redeemValue(LP, S, NAV, KEEP), 9_960_000_000_000);
eqN("redeem: gross NAV of 100k LP is 100k", VM.navValue(LP, S, NAV), LP);
eqN("redeem: zero supply pays 0", VM.redeemValue(LP, 0, NAV, KEEP), 0);

// F1: the instant cap is the caller's share of HOLDINGS — 100k/200k × 150k = 75k
// of gross NAV, i.e. 75k shares; 75,000.00000001 LP is refused. Exact integer
// comparison, no rounding.
eqN("cap: max instant shares = lpBal × H / NAV = 75k LP", VM.instantCapLp(LP, H, NAV), 7_500_000_000_000);
truth("cap: exactly the cap is within", VM.withinInstantCap(7_500_000_000_000, LP, H, NAV));
truth("cap: one base unit past the cap is refused", not VM.withinInstantCap(7_500_000_000_001, LP, H, NAV));
truth("cap: the full balance is refused while 25% is lent out", not VM.withinInstantCap(LP, LP, H, NAV));
// The USD cap is the same 75k of gross value net of the fee: 74,700.
eqN("cap: max instant USD = share of holdings × 0.996", VM.instantCapUsd(LP, S, H, KEEP), 7_470_000_000_000);
// Zero utilisation: NAV == H → every share is instantly redeemable.
eqN("cap: zero utilisation → whole balance", VM.instantCapLp(LP, NAV, NAV), LP);
truth("cap: zero utilisation → full exit within cap", VM.withinInstantCap(LP, LP, NAV, NAV));
// Liabilities beyond the loan book (NAV < H): still capped by the balance.
eqN("cap: NAV below holdings caps at the balance, never above", VM.instantCapLp(LP, H, 10_000_000_000_000), LP);
eqN("cap: NAV 0 → every (worthless) share passes the cap", VM.instantCapLp(LP, H, 0), LP);

// F5: the in-kind legs. Held cash 150k (the whole basket) — redeeming the cap
// (75k shares) pays 75k × 0.996 = 74,700 of it: payout / holdings scaling.
eqN("leg: cash leg for the capped exit = 74,700", VM.redeemLeg(H, 7_500_000_000_000, S, NAV, H, KEEP), 7_470_000_000_000);
// With NAV == H (no loans, no arrears) the leg is the classic pro-rata basket × keepBps:
// 1 BTC held, half the supply exits → 0.498 BTC.
eqN("leg: zero utilisation = held × f × keepBps", VM.redeemLeg(100_000_000, S / 2, S, NAV, NAV, KEEP), 49_800_000);
// Rounding is DOWN at the base unit (vault's favour): 3 units held, 1 of 3 shares → 0.996 → 0.
eqN("leg: floors to the base unit in the vault's favour", VM.redeemLeg(3, 1, 3, 3, 3, KEEP), 0);
eqN("leg: zero holdings pay nothing", VM.redeemLeg(0, LP, S, NAV, 0, KEEP), 0);
// Round trip identity at the cap: the legs' value equals redeemValue exactly
// when the basket is a single leg (one mulDiv chain, same rounding).
eqN("leg sums to the payout (single-leg basket)", VM.redeemLeg(H, 7_500_000_000_000, S, NAV, H, KEEP), VM.redeemValue(7_500_000_000_000, S, NAV, KEEP));

// ── Per-loan impairment reserve (task 1788475754): PD × LGD at the band edges ──
// D = $100k of debt; C is the LTV-weighted collateral. h = C / D.
// LGD = max(0, D − 0.85 C); PD = 0 at h ≥ 1.15, (1.15 − h)/0.15 on [1.0, 1.15), 1 below.
let D : Nat = 10_000_000_000_000;   // $100k
func atH(hE8 : Nat) : Nat { VM.expectedLoss(D, Fixed.mulDiv(D, hE8, 100_000_000, false)) };
eqN("impair: no debt → 0", VM.expectedLoss(0, D), 0);
eqN("impair: h = 1.25 (initial) → 0", atH(125_000_000), 0);
eqN("impair: h = 1.15 (maintenance, top edge) → 0", atH(115_000_000), 0);
// One base unit of health below maintenance: a positive, tiny provision — the
// ramp is continuous at the top edge (LGD there is D × (1 − 0.85 × 1.15) = 2.25% of D,
// PD = 1e-8 / 0.15, rounded UP).
let justBelow = atH(114_999_999);
truth("impair: just below maintenance is positive", justBelow > 0);
truth("impair: just below maintenance is tiny (≤ $0.001)", justBelow <= 100_000);
// Mid-band h = 1.075: PD = ½, LGD = D − 0.85 × 1.075 D = 0.08625 D → $4,312.50 exactly.
eqN("impair: h = 1.075 (mid-band) → $4,312.50 = ½ × $8,625", atH(107_500_000), 431_250_000_000);
// Bottom edge h = 1.0: PD = 1, LGD = 0.15 D → $15,000 (meets the under-water band).
eqN("impair: h = 1.0 (bottom edge) → $15,000 = 15% of debt", atH(100_000_000), 1_500_000_000_000);
// One base unit of health below 1.0: PD = 1, LGD = D − 0.85 × (D − 100_000) =
// $15,000 + $0.00085 — continuous at the bottom edge to the base unit.
eqN("impair: h = 1.0 − 1e-8 → $15,000.00085 (continuous at the bottom edge)", atH(99_999_999), 1_500_000_085_000);
// Under water: the stressed shortfall. h = 0.5 → D − 0.85 × 0.5 D = 0.575 D.
eqN("impair: h = 0.5 → $57,500", atH(50_000_000), 5_750_000_000_000);
eqN("impair: no collateral → the whole debt", VM.expectedLoss(D, 0), D);
// Monotone: h = 1.1 sits strictly between the mid-band and top-edge values,
// and h = 1.05 strictly between mid-band and bottom edge.
truth("impair: monotone in h (1.1 between 1.15 and 1.075)", atH(110_000_000) > 0 and atH(110_000_000) < atH(107_500_000));
truth("impair: monotone in h (1.05 between 1.075 and 1.0)", atH(105_000_000) > atH(107_500_000) and atH(105_000_000) < atH(100_000_000));
truth("impair: monotone in collateral below 1.0", atH(80_000_000) > atH(90_000_000) and atH(50_000_000) > atH(80_000_000));
// The exact ramp value at h = 1.1: LGD = D(1 − 0.935) = $6,500; PD = 1/3 → $2,166.67 (rounded up).
eqN("impair: h = 1.1 → $2,166.666667 (ramp ⅓ of $6,500, rounded up)", atH(110_000_000), 216_666_666_667);

// The vault-level reserve: gross Σ EL netted against the insurance fund's cash
// in aggregate, clamped to the loan book.
eqN("reserve: fund smaller than gross → the excess", VM.impairmentReserve(1_000_000_000_000, 400_000_000_000, 5_000_000_000_000), 600_000_000_000);
eqN("reserve: fund covers gross → 0 (no double count)", VM.impairmentReserve(1_000_000_000_000, 1_000_000_000_000, 5_000_000_000_000), 0);
eqN("reserve: fund larger than gross → 0", VM.impairmentReserve(1_000_000_000_000, 9_000_000_000_000, 5_000_000_000_000), 0);
eqN("reserve: never exceeds the loan book", VM.impairmentReserve(1_000_000_000_000, 0, 700_000_000_000), 700_000_000_000);
eqN("reserve: empty book → 0", VM.impairmentReserve(1_000_000_000_000, 0, 0), 0);
eqN("reserve: no fund → gross", VM.impairmentReserve(1_000_000_000_000, 0, 5_000_000_000_000), 1_000_000_000_000);

Debug.print("── VaultMath.test PASSED ──");
