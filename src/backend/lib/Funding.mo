// Funding.mo — the FUNDING AUTHORITY verdict for the balance mints
// (task 1789609263 — keychain hardening F17, staged plan ratified 2026-09-17).
//
// The finding: the unattended launchd subnet bot fleet refills its bots via
// `fund_call` = setTestBalance signed with the TARGET's controller identity —
// on the subnet that is the sole human-held controller of the live exchange.
// That key therefore could not leave the keychain's unattended `unsigned:`
// grant (task 1788467589) without silently breaking refills. The decision:
// the fleet gets its OWN funding principal, designated by a controller
// (`setFundingAuthority`), admitted to EXACTLY the two balance setters
// (setTestBalance / bulkSetTestBalances — and the scoped getTestBalance read
// the refill loop needs), on #play/#dev ONLY. Blast radius of that key =
// play-money refills; the controller key does one job again.
//
// Two verdicts, both pure functions of (posture, caller facts) so `mops
// test` (tests/Funding.test.mo) pins all three postures and a FOURTH posture
// cannot compile without deciding — the switches are exhaustive on purpose.
//
//   mintAdmitted   — may this caller run a balance mint?
//                    #production: never (the mixin's IS_PRODUCTION trap
//                    fires first and names the posture; the verdict agrees
//                    so the two gates can never disagree about a
//                    value-bearing venue). #dev / #play: a controller OR the
//                    designated authority.
//   designable     — may this principal BE the authority? Never on
//                    #production (there is nothing to authorise there — the
//                    mints are dead), and never the anonymous principal
//                    (designating 2vxsx-fae would open the mint to every
//                    unauthenticated caller — exactly the surface the
//                    controller gate closes).
//
// Genesis.mo's Posture is reused so the actor's DEPLOY_MODE literal passes
// straight through to both libs (a lib cannot import the actor).

import Genesis "Genesis";

module {
  public type Posture = Genesis.Posture;

  /// May `caller` run setTestBalance / bulkSetTestBalances (and read another
  /// principal's getTestBalance) on this posture?
  public func mintAdmitted(posture : Posture, isController : Bool, isFundingAuthority : Bool) : Bool {
    switch (posture) {
      case (#dev)        { isController or isFundingAuthority };
      case (#play)       { isController or isFundingAuthority };
      case (#production) { false };
    }
  };

  /// May a controller designate this principal as the funding authority?
  public func designable(posture : Posture, isAnonymous : Bool) : Bool {
    switch (posture) {
      case (#dev)        { not isAnonymous };
      case (#play)       { not isAnonymous };
      case (#production) { false };
    }
  };
};
