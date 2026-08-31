# W5-04 — The root-key pin fails on absence, not on reintroduction

**Issue:** [#36](https://github.com/dfinity/public-multidex/issues/36) item 6 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14) — **`host.js` itself is correct**
**Severity:** `#play` MEDIUM / `#production` HIGH (of the class it fails to catch)
**Effort:** M

## What's wrong

The shipped predicate and call site are correct: `fetchRootKey` is gated on an exact-hostname
`isLocalReplicaOrigin()` check ported from the CLI's guard, and the suite genuinely fails on the
pre-fix tree. What "pinned" does not cover is **reintroduction**.

The ban that is supposed to prevent substring matching names three methods and **never inspects the
argument**:

```js
!/\.includes\(|\.indexOf\(|\.match\(/.test(host)
```

So three unbanned substring forms — `/localhost/.test(h)`, `h.search(…)`, `h.lastIndexOf(…)` — make
`localhost.evil.example` itself resolve LOCAL while the assertion titled *"host.js never
substring-matches the hostname"*, whose own failure text names that hostname, still prints ✓. (Note
`.indexOf(` is matched but `.lastIndexOf(` is not, because the needle is lowercase-anchored.)

The reporter also demonstrated **nine parse-clean edits** that keep every needle satisfied while
changing behaviour — the simplest being one added line:

```js
      || h.endsWith("localhost");
```

after the existing `|| h.endsWith(".localhost")`, which makes `isLocalReplicaHost("notlocalhost")`
and `("evil-localhost")` return `true` — both named in that file's own header as *"correctly treated
as REMOTE"* — with the suite silent at `PASS — 53`.

**Bounded honestly by the reporter:** gate blindness is confirmed by execution; *exploitation* is
plausible at best, since `localhost` is an RFC 6761 special-use TLD and not publicly delegable, so a
`*localhost` name needs DNS the attacker controls. The three substring variants are the exception —
they newly classify the ordinarily-registrable `localhost.evil.example` as local.

## Evidence

- `tests/frontend_security.test.mjs:188-190` — the ban, method names only, argument never inspected
- `src/frontend/src/host.js:26-33` — the shipped predicate (correct)
- `src/frontend/src/main.js:1016` — the shipped call site (correct)
- `scripts/verify_ledger.mjs:62-63` — the CLI rule it was ported from

## Fix

Assert the **shape of the predicate**, not the absence of three method names — e.g. parse `host.js`
and require the hostname test to be an exact-equality/suffix set, or extend the ban to the whole
substring family (`.test(/…/`, `.search(`, `.lastIndexOf(`, `.indexOf(`, `.includes(`, `.match(`)
**and** assert on behaviour by importing the real predicate and running a hostname battery through
it — including `notlocalhost`, `evil-localhost`, `localhost.evil.example`.

The behavioural battery is the part that actually closes it; the ban list is a backstop.

## Done when

- [ ] Each of the reporter's nine parse-clean edits turns the suite red
- [ ] `localhost.evil.example`, `notlocalhost`, `evil-localhost` are asserted REMOTE by execution
- [ ] The assertion's title matches what it tests

---
## Done — 2026-08-15

Closed by execution, exactly as the reporter prescribed. The suite now
imports the REAL `isLocalReplicaHost` from the checked ROOT (works for the
`<root>` other-checkout form too) and classifies a 20-hostname battery:
7 LOCAL (incl. case-folding and `.localhost` subdomains), 12 REMOTE (incl.
`notlocalhost`, `evil-localhost`, `localhost.evil.example`,
`127.0.0.1.evil.example`, a URL-shaped string, empty) plus null, and pins
`isLocalReplicaOrigin()` failing CLOSED with no window. The needle ban stays
as a backstop, widened to the whole family case-insensitively
(includes/indexOf/lastIndexOf/search/match/matchAll/test) and retitled
"(family ban)" so the title matches what it tests.

Verified: all nine parse-clean edits red (the five substring adds, equality→
startsWith, suffix-dot drop, `[::1]` arm drop, equality→indexOf), restored
tree green — PASS 74 (was 53). host.js itself unchanged (it was correct),
so the verify_ledger.mjs twin needs no sync.
