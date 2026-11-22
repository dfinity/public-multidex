# The factory watch reaper — ops note

Backgrounded `scripts/factory.sh watch` processes on this machine are killed
by a harness-side background-task sweep on a machine-wide 30-minute grid
(local ticks at **hh:06:42 / hh:36:42**), across every CLI seat and project at
once. Identified in task 1787260290 (obituary hardening merged 5afb4e6; the
mechanism comment lives beside `watch_obituary()` in `scripts/factory.sh`).

The first captured obituary (task 1787265452) settled the open questions: the
reaper sends **SIGTERM** (catchable — the obituary trap fires; a bare
`[killed]` with no obituary would mean SIGKILL), the kill lands on the grid
tick, and it targets the watch process only (ppid stays alive). Age-based
selection is **falsified**: the captured victim was ~13 minutes old, so the
"~30-min age" theory and the derived "arm watches under ~25 min to dodge the
reaper" guidance (1787260290's completion note and fleet chat) are
**retracted** — no arming interval dodges the reaper. The robust rule is the
resume doctrine alone: treat every dead-watcher notice as a routine re-arm
signal — announce, re-arm the watch, continue; never conclude "deliberate
pattern, stop re-arming." Evidence, verbatim:

```
factory.sh watch: killed by SIGTERM at 2026-08-20T22:36:43Z (pid 41514, ppid 41512 alive)
```
