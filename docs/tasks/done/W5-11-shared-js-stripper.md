# W5-11 — A nested template literal drives the shared JS stripper out of phase

**Issue:** [#38](https://github.com/dfinity/public-multidex/issues/38) item 3 — OhShii Labs
**Status:** VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (of the class it fails to catch)
**Effort:** S

## What's wrong

`tests/_lib.mjs` (63 lines, **new in 1.60**) is the shared oracle for both Node suites.
`stripJsComments` treats every backtick alike, so a template literal whose interpolation contains
**another** template closes at the *inner* backtick. From there the scanner is out of phase — code
scanned as string, string as code — until it happens to re-synchronise, and **every needle fed from
that window fails open**.

Because it is shared, a desynchronised window silently weakens whichever assertions happen to read
through it, in either Node suite.

## Not the same as the other stripper findings

Worth keeping distinct, because three stripper items are open at once:

- [W5-10](W5-10-deploy-hygiene-harness.md) item 4 is a **shell** `sed 's/#.*//'` with no grammar that
  **under-strips**: it truncates a single line at its first `#`. It hides a **line**.
- This is a **JavaScript** character scanner with a `REGEX_OK` state machine, in a different file,
  added by a different release, failing in the opposite direction: it **loses phase across a region**
  and inverts a span.
- A fix to either does nothing for the other.

It also composes with [W5-17](W5-17-display-integrity-pins.md): that one is about needles pinning
identifier text rather than semantics; this is the stripper handing those needles a corrupted window.

## Evidence

- `tests/_lib.mjs:34-45` — `stripJsComments`, all backticks treated alike, no nesting depth
- Consumed by `tests/frontend_security.test.mjs` and `tests/frontend_display_integrity.test.mjs`

## Fix

Track template-literal nesting depth (a small stack: entering `${` inside a template pushes, the
matching `}` pops), or use a real tokenizer. Keep it small — the file is 63 lines and should stay
readable.

## Done when

- [ ] A nested template literal does not desynchronise the scanner
- [ ] A banned pattern placed after a nested template is still caught
- [ ] A fixture with nested templates is added, and fails on the pre-fix stripper

---
## Done — 2026-08-15

stripJsComments now tracks template-literal nesting: a backtick enters
template TEXT (emitted raw — `//` inside it is literal), `${` pushes a
per-interpolation brace counter and returns to code scanning, and the `}`
that zeroes the top counter pops back to the enclosing template's text.
Arbitrary depth (a template inside an interpolation inside a template)
works because the backtick branch and the counter stack compose. `"`/`'`
strings unchanged; the file stays a single readable scanner.

New tests/stripper.test.mjs (auto-discovered by run_all's *.test.mjs glob)
pins 12 fixtures: baseline comment/string behaviour, the nested-template
phase properties in BOTH failure directions (interpolation code mis-read as
string → banned text kept; template text mis-read as code → pinned text
wrongly stripped), needles after deep nesting, and object literals inside
${} not popping early. On the PRE-fix stripper the suite is red (2 of 12 —
both desync witnesses); post-fix 12/12, and both consumers stay green
(frontend_security 75, frontend_display_integrity 49) — no behaviour change
on the real files, phase correctness only.
