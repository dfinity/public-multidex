# W5-10 — Three defects in the harness that judges the deploy gates

**Issue:** [#36](https://github.com/dfinity/public-multidex/issues/36) items 3, 4, 7 — OhShii Labs
**Status:** ALL VERIFIED LIVE at `01d2b23` (2026-08-14)
**Severity:** `#play` LOW / `#production` MEDIUM (of the classes they fail to catch)
**Effort:** M (one file, one commit)

## Context — why the mutation battery missed these

`tests/test_deploy_hygiene.sh` was mutation-tested against 13 deliberately reintroduced bugs. That
measures **sensitivity** — can it see a bug that came back — and never **specificity**: can it be
wrong when nothing came back, and can the bug come back in a shape the needle was not written for.
The unscored run is the green one on the unmutated tree. All three items below live there.

## Item 3 — the two matchers take their branch from a SIGPIPE race

`:65` and `:69` pipe `printf` into `grep -qF` under the `pipefail` set inherited from `_lib.sh`.
`grep -q` exits at the first match **without draining**, the producer takes SIGPIPE, and `pipefail`
promotes 141 into the pipeline status — so **a matched needle can produce the failure branch**. On a
byte-identical tree the same assertion came back both ways across repeated runs.

This is the 14th mutation and the one the 13 could not find: it is not a mutation of the code under
test but a defect already present in the harness that judges it, whose test case is the **empty
diff**. A single green baseline run cannot see an intermittent red.

*Bounded:* the false-GREEN direction is latent — every real haystack in this suite is 287–6,779
characters against an onset measured near 48 KB.
**Item 3 FIXED (2026-08-15, during W3-05):** the predicted bigger haystack arrived
(`mo_code < main.mo` ≈ 488KB for the §6e pins) and the race fired deterministically — a matched
needle took the failure branch on every run. Both matchers now drain (`grep -cF -- ... >/dev/null`),
per the reporter's fix; three consecutive full runs give identical verdicts (117 ✓). Items 4 and 7
remain open.
**Bound moved (2026-08-14, W1-02):** §6b now feeds `uncommented scripts/deploy.sh` (≈30.2 KB) and
`uncommented scripts/play_start.sh` (≈11.6 KB) to the matchers — still under the onset, but no
longer by an order of magnitude. Fix item 3 before anyone adds a bigger haystack.

*Fix:* drain the producer (`grep -c`/`grep -F … >/dev/null` with the read completed), or drop
`pipefail` for these two matchers with a comment saying why.

## Item 4 — the comment stripper cuts at the first `#`, including inside a string

```bash
uncommented() { sed 's/#.*//' "$1"; }
```

No shell grammar — it cuts at the first `#` **byte**. All thirteen reintroduced mutations were
written bare; a fourteenth with the same banned pattern written after a `#` **inside a double-quoted
string** is invisible to all three ban scans and to both `src_lacks` pins.

*Bounded:* no instance of the shape exists in the tree today — 17 of 17 raw hits are genuine
full-line comments. This is a missing tripwire, not a live false negative.

*Fix (reporter's, tested green on the pristine tree and red on all three hidden mutations):*
`sed 's/^[[:space:]]*#.*//'`.

Same class as [W1-02](W1-02-deploy-mode-gate-comment-blind.md) — different consumer, and that one is
far more consequential.

## Item 7 — the function slicer counts braces with no lexer

`mo_func` extracts a Motoko function body by counting `{` and `}` without a lexer, so braces inside
comments and string literals are counted. **Sixteen `src_has`/`src_lacks` call sites take a window
from it — including all six structural liquidation-breaker assertions.**

The two directions are asymmetric and only one is dangerous: a phantom `{` over-runs the function end
and fails loudly on unrelated code; a phantom `}` **ends the window early and every `src_lacks` below
it passes vacuously**.

It already mis-slices a live function: `src/backend/lib/PriceFeed.mo:549` `extractFromBody` is
extracted as 86 lines instead of 85, because of a `{` inside a string literal at `:569`. So "this
shape does not occur in our code" is not available as an answer.

Executed by the reporter: a note quoting `_liqDispatches += 1 };` placed above a reverted pacing line
truncates the heartbeat window from 64 lines to 43 and leaves **all six** liquidation-breaker
assertions green with the pre-fix defect live. `moc --check` returns 0 throughout.

*Fix:* strip comments and string literals before counting, or anchor the window on the next
top-level `func`/`public` declaration rather than brace depth.

## Done when

- [ ] Repeated runs on a byte-identical tree give identical verdicts (item 3)
- [ ] A banned pattern hidden after a `#` inside a string is caught (item 4)
- [ ] `mo_func` slices `extractFromBody` as 85 lines, and the reporter's truncation mutant turns the
      six liquidation assertions red (item 7)
- [ ] The 13-mutation battery still passes

---
## Done — 2026-08-15 (items 4 + 7; item 3 was closed 2026-08-15 during W3-05)

**Item 4** — `uncommented()` is now anchored: `sed 's/^[[:space:]]*#.*//'`
(full-line comments only). Trailing-comment text is scanned on purpose; the
helper's comment says to reword comments rather than weaken the stripper.
Verified: pristine tree green (no trailing comment in the scanned set trips
the ban scans), and the hidden shape — `W510_NOTE="see docs # pkill -f …"`
appended to deploy.sh — turns §3 red, which the old byte-cut stripper
provably could not see.

**Item 7** — `mo_func` now counts braces on a CODE-ONLY image of each line:
an awk scanner tracking `//`, NESTED `/* */`, and string/char literals with
escapes. Output lines remain the originals; the signature match also reads
the code image, so a comment quoting a signature cannot open a window.
Verified: `extractFromBody` slices as exactly 85 lines (the old slicer's 86
reproduced first); the reporter's mutant — a comment quoting
`_liqDispatches += 1 };` inside heartbeat with the banned completion-stamp
pacing reverted below it — truncated the OLD window 81→42 while the NEW
slicer holds 83 and the "does not pace off the completion stamp" assertion
goes red through it. Cost: ~0.1s per slice.

**Box 4 honestly:** the 13-mutation battery was the reporter's exercise,
not an in-repo script; the regression evidence is the full suite green on
the pristine tree after both helper rewrites (run repeatedly during
verification, including under W5-05's §8 additions).
