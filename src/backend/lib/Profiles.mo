import Principal "mo:core/Principal";
import Text     "mo:core/Text";
import Nat      "mo:core/Nat";
import Nat32    "mo:core/Nat32";
import Char     "mo:core/Char";
import Types    "Types";

module {

  // ── Word lists for name generation ─────────────────────────────
  let ADJECTIVES : [Text] = [
    "Amber",  "Bold",   "Brave",  "Calm",   "Cosmic",
    "Dark",   "Deep",   "Dusty",  "Fair",   "Fierce",
    "Frost",  "Gold",   "Iron",   "Jade",   "Keen",
    "Lone",   "Mystic", "Noble",  "Pure",   "Quick",
    "Silent", "Silver", "Swift",  "Wild",   "Wise",
  ];

  let NOUNS : [Text] = [
    "Bear",    "Buck",    "Crane",   "Crow",    "Drake",
    "Eagle",   "Falcon",  "Fox",     "Hawk",    "Heron",
    "Horse",   "Lynx",    "Moose",   "Nebula",  "Otter",
    "Phoenix", "Raven",   "Shark",   "Stag",    "Tiger",
    "Viper",   "Warden",  "Wolf",    "Wraith",  "Wren",
  ];

  let N_WORDS : Nat = 25;

  // ── Simple deterministic hash ───────────────────────────────────
  func simpleHash(s : Text, seed : Nat) : Nat {
    var h : Nat = seed + 1;
    for (c in s.chars()) {
      h := (h * 31 + Nat32.toNat(Char.toNat32(c))) % 999983;
    };
    h
  };

  // ── Uppercase a single ASCII char ──────────────────────────────
  func charUpper(c : Char) : Char {
    let code = Nat32.toNat(Char.toNat32(c));
    if (code >= 97 and code <= 122) {
      Char.fromNat32(Nat32.fromNat(code - 32))
    } else { c }
  };

  // ── Turn first principal segment into a short display ID ───────
  // Example: "ewhvm-sziio-..." → "EWHVM"
  public func makeUserId(p : Principal) : Text {
    let t = Principal.toText(p);
    var seg = "";
    for (c in t.chars()) {
      if (c == '-') {
        var up = "";
        for (ch in seg.chars()) { up #= Text.fromChar(charUpper(ch)) };
        return up;
      };
      seg #= Text.fromChar(c);
    };
    // No dash found — return whole text uppercased
    var up = "";
    for (ch in seg.chars()) { up #= Text.fromChar(charUpper(ch)) };
    up
  };

  // ── Build a username from three supplied draws ─────────────────
  // Format: "Adjective-Noun-NN".
  //
  // The draws MUST NOT be derived from the principal. This used to be
  // `generateUsername(p, regenCount)` — three hashes of Principal.toText(p) —
  // which made the friendly name a pure, public function of the principal.
  // With the event tape publishing every principal by design (anti-mixer /
  // proof-of-reserves), anyone could enumerate principals from the tape,
  // recompute each one's name for a few regeneration counts, and rebuild the
  // whole username↔principal mapping offline and retroactively. Withholding
  // the principal from the leaderboard is pointless while the NAME still
  // encodes it.
  //
  // The caller now supplies unpredictable draws (the actor's entropy pool,
  // seeded from the IC's randomness beacon), so there is no function to
  // invert: the mapping exists only in userProfiles, which is not public.
  public func usernameFromDraws(d1 : Nat, d2 : Nat, d3 : Nat) : Text {
    let adj  = ADJECTIVES[d1 % N_WORDS];
    let noun = NOUNS[d2 % N_WORDS];
    // W6-11 (R7): 25 × 25 × 9,990 = 6,243,750 names — 50% chance of SOME
    // accidental duplicate at ~2,940 profiles (birthday bound), up from 279
    // at the old 2-digit space (25 × 25 × 90 = 56,250). Purely display
    // ambiguity either way — nothing resolves by username in any live path,
    // and the identicon is deliberately seeded from the NAME (a function of
    // public data), so a collision yields an identical glyph rather than a
    // false distinguisher. Deliberately NOT a principal-derived suffix: the
    // tape publishes every principal, so any pure function of it would
    // rebuild the whole name↔principal mapping offline — the exact attack
    // the draws-based design above exists to close.
    let num  = (d3 % 9_990) + 10;   // 10–9999
    adj # "-" # noun # "-" # Nat.toText(num)
  };

  // ── Create a fresh profile for a new user ──────────────────────
  public func createProfile(p : Principal, timestamp : Int, name : Text) : Types.UserProfile {
    {
      userId     = makeUserId(p);
      username   = name;
      regenCount = 0;
      createdAt  = timestamp;
    }
  };

  // ── Regenerate username (up to MAX_USERNAME_REGENS) ────────────
  // `name` comes from the actor's entropy pool — see usernameFromDraws. A
  // regeneration that produced a principal-derived name would be worse than
  // useless: the point of regenerating is to shed a public identity, and a
  // recomputable name lets an observer follow you straight through it.
  public func regenerate(profile : Types.UserProfile, name : Text) : { #ok : Types.UserProfile; #err : Text } {
    if (profile.regenCount >= Types.MAX_USERNAME_REGENS) {
      return #err("Maximum regenerations (" # Nat.toText(Types.MAX_USERNAME_REGENS) # ") reached");
    };
    let newCount = profile.regenCount + 1;
    #ok({
      userId     = profile.userId;
      username   = name;
      regenCount = newCount;
      createdAt  = profile.createdAt;
    })
  };
};
