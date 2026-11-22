# W6-11 — 56,250 usernames collide by accident at ~279 profiles

**Issue:** internal red-team round 2, finding R7
**Status:** VERIFIED at `d8f4c58` (2026-08-17)
**Severity:** LOW — **product quality, not security**
**Effort:** S (one line)

## Facts, verified rather than assumed

`lib/Profiles.mo:11-27`, `:81-86`: `ADJECTIVES` = 25 entries (all distinct), `NOUNS` = 25 (all
distinct), `(d3 % 90) + 10` = 90 values. **25 × 25 × 90 = 56,250 exactly.** Birthday bound gives a
50% chance of *some* duplicate at **279 profiles**.

No uniqueness check exists: `createProfile` (`:89-96`) and `regenerate` (`:103-114`) both accept the
draw unconditionally, and the callers `getMyProfile` (`mixins/UserAccount.mo:69-87`) and
`regenerateUsername` (`:89-103`) add none. There is **no map keyed by username anywhere** in the
backend, so nothing breaks on a collision — it is purely display ambiguity.
`MAX_USERNAME_REGENS = 5` confirmed (`lib/Types.mo:416`).

The leaderboard genuinely carries no other identity: `PublicLeaderRow` (`main.mo:11067-11083`) has
rank, profit, capital, equity, return, fee level, badge count and `isMe` — all statistics. And the
identicon does not disambiguate: it is seeded from `r.username`, deliberately
(`src/frontend/src/main.js:5651`, `:5659-5663` — "seeded from the name, the glyph is a function of
public data"), so a name match yields a **byte-identical glyph**. R7 missed this; it is the sharpest
part of the finding.

## Why this is not the security issue R7 describes

- **Nothing resolves by username in any live path.** Every `.username` reference is display-only
  (`main.mo:11079`, `:11150`, `:15905`, and OQL `ownerName` on already-scoped entities `:16109`).
  The one lookup-by-name method, `debugInspectByUsername` (`:11266`), is **double-gated**:
  `requireDevHook` hard-*traps* on play and production (`:8756-8760`) *and* `requireController`
  (`:11283`). It is dead code outside dev.
- **There is nothing to impersonate into** — no messaging, DMs, referrals, or social graph. Rewards,
  badges and the market-maker program are all principal-keyed.
- **A matching name does not put you on the board.** `leaderRowFor` (`:11121-11144`) requires a
  profile *and* non-zero baseline or net, and `getLeaderboard` publishes only the **top 50 by
  profit** (`:11208`). Sitting beside a target needs real registered capital and genuine top-50
  profit.
- **The grinding cost is posture-dependent.** On `#production` the inspect gate (`:8899-8908`)
  returns `not IS_PRODUCTION` for unknown principals, so an unregistered fresh keypair cannot call
  `getMyProfile` at all and every identity costs a real deposit. On `#play` grinding is free, but
  funding the winning principal still needs a Google-verified email under
  `docs/play-anti-sybil-design.md`.

So the real case for fixing is the accidental collisions, which become likely at a few hundred
profiles, and the fact that a user who dislikes a collided name has only five escapes.

## Fix

One line — widen the number component at `lib/Profiles.mo:84` from `(d3 % 90) + 10` to
`(d3 % 9990) + 10`: **6,243,750** names, 50%-collision at ~2,940 profiles, no new state, no
migration.

If a hard guarantee is wanted instead, add a stable `usernameTaken : Map<Text, Bool>` claimed in
`getMyProfile` / `regenerateUsername` with a bounded redraw. That is an added stable field, which
the EOP accepts (additions are fine; only drops and class flips are refused).

**Do not** add a principal-derived suffix as a discriminator. That re-creates exactly the attack
`lib/Profiles.mo:68-80` and `main.mo:11091-11097` were written to close: the tape publishes every
principal, so any pure function of it rebuilds the whole mapping offline.

## Done when

- [x] Widened: `(d3 % 9_990) + 10` → 25 × 25 × 9,990 = **6,243,750** names, 50%-collision at
      ~2,940 profiles (was 56,250 / 279); arithmetic recorded in the code comment
- [x] No principal-derived component — new hygiene §6l pins BOTH halves (the widening literal,
      and `Principal` banned from the comment-stripped function body)
- [x] Identicon: still seeded from `r.username` (a function of public data) — under the wider
      space a collision still yields an identical glyph, which is the honest rendering of a
      name collision; confirmed unchanged in main.js

---
## Status 2026-08-17 — CLOSED (one line + pin)
