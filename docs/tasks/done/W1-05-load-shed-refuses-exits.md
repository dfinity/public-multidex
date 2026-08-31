# W1-05 — Load shedding is caller-scoped, so it refuses shed users' exits

**Issue:** [#27](https://github.com/dfinity/public-multidex/issues/27) item 1 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — maintainer: "the one I would fix first of the four"
**Severity:** `#play` LOW / `#production` HIGH
**Effort:** S

## What's wrong

`system func inspect({ caller : Principal })` destructures **only** `caller`. There is no `msg`
variant match anywhere in it, and that is deliberate — the policy comment argues it keeps the
gate from needing an edit every time a method is added. The reasoning is sound as an argument about
maintenance cost; the consequence was not followed through.

The verdict is one uniform answer for the caller, applied identically to every ingress update:

```motoko
if (_shedFloor == 0) { return true };
return levelRank(levelOfKey(key)) >= _shedFloor;
```

`levelRank` maps L0 → 0, so at `_shedFloor == 1` every rank-0 **registered** caller is refused
pre-consensus **on all updates** — including the exit set, none of which is reachable by query or
by inter-canister call from the user:

| endpoint | where |
|---|---|
| `cancelMyOrder` | `main.mo` |
| `cancelAllMyOrders` | `main.mo` |
| `closePosition` | `main.mo` |
| `withdrawMarginPool` | `main.mo` |
| `unstakeInsurance` | `main.mo` |
| `withdrawLp` | `main.mo` |
| `withdraw` | `mixins/UserAccount.mo` |

The floor is not a dev-only pin: `recomputeShedFloor` runs **unconditionally every heartbeat** off
`Map.size(deferredExecs)` against `SHED_SOFT_STAGED` / `SHED_HARD_STAGED`.

`inspect` is pre-consensus and is not a security boundary — nobody is claiming it is. It **is** an
availability boundary, and it is the one place where being stricter than the method body has no
repair path: the user cannot retry into consensus, cannot route around it, and receives no error
the UI can classify. The congestion that raised the floor is exactly what makes closing a position
urgent, and a user who cannot voluntarily de-lever is liquidated anyway.

## Evidence

- `src/backend/main.mo:8226` — `system func inspect({ caller : Principal }) : Bool`
- `:8240-8241` — the uniform verdict
- `:6439-6446` — `recomputeShedFloor`; `:6549` — called every heartbeat
- `main.mo:767-769` — `levelRank`, L0 → 0

## Fix

Accept a maintained list for the exit set only: a small `msg` variant match naming the seven exits
and returning `true` for them regardless of floor, with a comment saying **why** the list exists so
the next person does not "simplify" it away.

The alternative that preserves the never-edit-`inspect` property — moving the shed verdict into the
entry-side method bodies — costs the pre-consensus saving on exactly the methods where it is worth
having. The reporter recommends the first and so do I.

## Done when

- [x] With `_shedFloor` forced high, a rank-0 registered user can still cancel, close, unstake and withdraw
- [x] Entry-side methods are still shed at the gate
- [x] The exemption list carries a comment explaining the trade-off it encodes
- [x] A test pins the exemption so a new exit method added later fails loudly if omitted

## Completed 2026-08-15

- The exit set is exempted inside the registered-caller branch of `inspect`, after the floor-0
  short-circuit: a msg-variant switch returns true for **eight** methods regardless of floor — the
  reporter's seven plus `cancelPoolOrder` (a pool order locks pool collateral, so cancelling it is
  the pool-side de-lever). `cancelAllAfter` was considered and deliberately left sheddable (arming
  a dead-man is protective, not an immediate exit). The rationale lives in the switch's comment,
  ending with "DO NOT simplify this switch away — its absence was the finding".
- **The enumeration cost turned into the pin.** Matching msg at all forces the full method variant:
  moc's expected type turned out to include every public method — queries too, since any query can
  arrive as an ingress update call — 222 tags, payloads erased to `Any` (names only, no arg-type
  brittleness; the list was generated from the M0127 error's own expected-type printout). A new
  public method is now a compile error at `inspect` until its tag is added, which forces the
  exit-or-sheddable classification the old caller-only design silently defaulted.
- Pins: `test_deploy_hygiene.sh` §6c asserts the EXIT SET rationale marker, all eight `#name _`
  cases, and that the rank verdict still guards non-exits. New `tests/test_load_shed_exits.sh`
  (13 green on `#dev`, state-light — no reset, safe against any venue): registered rank-0 user at
  floor 4 → `placeLimitOrder` refused pre-consensus, all eight exits reach their bodies,
  `whyAmIRefused` reports `admittedNow = false`, floor restore re-admits entries.
- Regressions: hygiene + oql_guard green on the `#play` build; sealed-model re-confirmed 6/6 on
  `#dev` post-change (its 3/6 on `#play` is the documented posture physics, not this change).
- The policy comment above `requireDevHook` now describes admission as caller-scoped **with the
  one method-scoped carve-out**, and why the never-edit-inspect property was traded away.
