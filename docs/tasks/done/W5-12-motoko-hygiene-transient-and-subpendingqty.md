# W5-12 — Two Motoko hygiene fixes: unretunable constants, and a clamp that should fail closed

**Issue:** [#28](https://github.com/dfinity/public-multidex/issues/28) items 3 and 4 — OhShii Labs
**Status:** BOTH VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** INFO / LOW
**Effort:** S (both, one commit)

## Item 3 — two actor-level constants are missing `transient`

Under `persistent actor` with enhanced orthogonal persistence, every `let`/`var` in the actor body is
**implicitly stable** — which is why the tree contains zero `stable` keywords and why `transient` is
used deliberately throughout. The rule is documented in `main.mo` and called load-bearing in those
exact words:

> `transient` is load-bearing: a plain `let` in a `persistent actor` is implicitly STABLE, so an
> edited literal would be silently overwritten by the old stored value on `--mode upgrade` and the
> flip would never land.

The reporter counted the whole actor body rather than eyeballing it, because the naive version of
this finding would be wrong: 199 `transient let` vs 85 plain `let`, but **83 of those 85 are state
containers** (`Map.empty`, `List.empty`, `Accounts.emptyState()` …) which *should* be implicitly
stable, because they are the data. Exactly **two** are scalar tuning constants:

```motoko
main.mo:134    let MARGIN_CASH_SETTLE_USD : Nat = 5_000_000_000;   // $50 at 10^8 — currently unused
main.mo:3858   let EPISODE_CAP : Nat = 200;                        // live tuning knob
```

Both are frozen at their first-installed value, so a `--mode upgrade` that edits either literal has
**no effect** — the exact failure the rule warns about. `EPISODE_CAP` is live (used at `:3875`,
`:3881`); `MARGIN_CASH_SETTLE_USD` is unused, which is presumably why neither was noticed.

This corrects a clearance in the 1.60 audit notes, which asserted the constant set was uniformly
`transient`. INFO/LOW — but it is the kind of thing discovered during an incident, when the retune
does not take.

*Fix:* mark both `transient let`. Confirm no other scalar constant is a plain `let`.

## Item 4 — `subPendingQty` clamps where non-negativity is a real invariant

`SafeMath.mo`'s own header states the rule:

> Use it ONLY where clamping a negative result to 0 is the INTENDED semantics […] Do NOT use it to
> silence a subtraction whose non-negativity is a real INVARIANT — there, the trap is a feature.

`subReserved` follows that rule: on underflow it fails closed and logs the desync. `subPendingQty`,
its structural twin, calls `SafeMath.subOrZero` and silently produces 0. If the pending-quantity lock
ever desyncs, one path shouts and the other hides it.

The reporter read **all 26** `subOrZero` call sites before filing: twenty-five are legitimate clamps
whose zero case is intended and documented at the site. This is the one that is not — one of two
siblings given different treatment, not a pattern.

INFO/INFO today; no reachable desync was constructed. It is filed because the *next* change to the
pending-match accounting is the one that would need the alarm.

*Fix:* make `subPendingQty` fail closed and log, mirroring `subReserved`.

- `src/backend/main.mo:1221-1223` — `subPendingQty`
- `:1131-1136` — `subReserved`, the correct shape

## Done when

- [ ] Both constants are `transient let`, and an upgrade that edits `EPISODE_CAP` takes effect
- [ ] `subPendingQty` fails closed on underflow and logs the desync
- [ ] No other scalar tuning constant is implicitly stable

---
## Done — 2026-08-15

**Item 3 — with a real discovery.** The naive fix (`transient let` on the
same names) is NOT LANDABLE: flipping a name's persistence class in place is
a memory-incompatible upgrade, and — bisected live — EOP refuses even to
DROP a stable field without a migration (IC0503 on a pure deletion of the
unused constant). So: both old stable names stay declared as parked
STABLE-FOSSILs (unread, commented with the why), and the live tuning knob is
`transient let EPISODE_RETENTION_CAP` under a fresh name — landable in one
ordinary upgrade, verified deployed on local #dev. Retunes now take effect
by construction: transient re-initializes from the literal on every upgrade,
which is the exact failure mode (stored value wins) made impossible. The
fossils go out with the next one-shot migration sweep, whenever one is
needed for real reasons.

Census: zero other implicitly-stable scalar constants (UPPER_SNAKE scalar
grep over the actor body). New hygiene §7b pins the census at zero
(STABLE-FOSSIL-marked lines exempt — the marker is the conscious act) —
reintroduction mutation verified red.

**Item 4.** subPendingQty no longer clamps: on underflow it leaves the row
unchanged (conservative — quantity stays locked, mirroring subReserved's
fail-closed direction) and logs "pending-qty desync" via logEventF("warn"),
the same idiom as the reservation-desync log. §7b pins both properties
(no subOrZero in the body; the desync log present). Deployed with the same
upgrade.
