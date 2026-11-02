// Unit pins for src/backend/lib/Funding.mo — the FUNDING AUTHORITY verdict
// for the balance mints (task 1789609263, keychain hardening F17). A
// controller designates one non-controller principal (the fleet's
// `mdex-bots` key) that may run setTestBalance / bulkSetTestBalances on
// #play/#dev ONLY, so the live controller key stops signing refills. The
// switches are exhaustive: a fourth posture cannot compile undecided.

import Funding "../src/backend/lib/Funding";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

func truth(name : Text, cond : Bool) {
  if (not cond) { Runtime.trap("FAIL: " # name) };
  Debug.print("  ✓ " # name);
};

// ── mintAdmitted(posture, isController, isFundingAuthority) ──────────────
// #dev and #play: a controller passes, the authority passes, a random
// principal (neither) is refused.
for (posture in [#dev, #play].values()) {
  let tag = debug_show(posture);
  truth(tag # ": a controller may mint",                       Funding.mintAdmitted(posture, true,  false));
  truth(tag # ": the funding authority may mint",              Funding.mintAdmitted(posture, false, true));
  truth(tag # ": a controller that is also the authority may", Funding.mintAdmitted(posture, true,  true));
  truth(tag # ": a random principal may NOT mint",             not Funding.mintAdmitted(posture, false, false));
};

// #production: nobody — not the controller, not the authority. The mixin's
// IS_PRODUCTION trap fires first and names the posture; the verdict agrees
// so the two gates can never disagree about a value-bearing venue.
truth("#production: a controller may NOT mint",            not Funding.mintAdmitted(#production, true,  false));
truth("#production: the funding authority may NOT mint",   not Funding.mintAdmitted(#production, false, true));
truth("#production: both flags together still refused",    not Funding.mintAdmitted(#production, true,  true));
truth("#production: a random principal refused",           not Funding.mintAdmitted(#production, false, false));

// The verdict is monotone in each flag on every posture: granting a flag can
// only admit, never refuse.
for (posture in [#dev, #play, #production].values()) {
  let tag = debug_show(posture);
  truth("mintAdmitted is monotone in isController on " # tag,
    (not Funding.mintAdmitted(posture, false, false)) or Funding.mintAdmitted(posture, true, false));
  truth("mintAdmitted is monotone in isFundingAuthority on " # tag,
    (not Funding.mintAdmitted(posture, false, false)) or Funding.mintAdmitted(posture, false, true));
};

// ── designable(posture, isAnonymous) ─────────────────────────────────────
// A named principal may be designated on #dev / #play; the anonymous
// principal never (2vxsx-fae as the authority would open the mint to every
// unauthenticated caller); nothing on #production (the mints are dead there).
truth("#dev: a named principal is designable",              Funding.designable(#dev,  false));
truth("#play: a named principal is designable",             Funding.designable(#play, false));
truth("#dev: the anonymous principal is NOT designable",    not Funding.designable(#dev,  true));
truth("#play: the anonymous principal is NOT designable",   not Funding.designable(#play, true));
truth("#production: a named principal is NOT designable",   not Funding.designable(#production, false));
truth("#production: the anonymous principal is NOT either", not Funding.designable(#production, true));

Debug.print("Funding.test.mo: all pins hold");
