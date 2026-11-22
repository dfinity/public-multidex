# Contributors

MULTI/DEX is developed in the open and hardened in the open. It is a piece of
community infrastructure — it benefits everyone who uses the Internet Computer
and it is owned by no one. This file is the standing, public record of how we
assess the work people outside the core team do to harden it, and it exists so
that the people being assessed can read the criteria rather than infer them.

**Recognition is the point.** The durable thing this project can offer is
credit — a public, permanent record that you found what you found and that it
mattered. We are not looking for mercenaries, and this file is not a price
list. There is no standing bug-bounty program and no payment is owed for any
report (see [SECURITY.md](SECURITY.md)); DFINITY may recognise or reward
contributions it values at its sole discretion. What is written down here is
the *basis* on which contributions are weighed — not a promise of anything in
particular.

- **How we assess:** [§ How assessment works](#how-assessment-works)
- **Verification behind the August 2026 review:** [docs/issue-triage-2026-08.md](docs/issue-triage-2026-08.md)

---

## How assessment works

We weigh **verified impact**, not claimed impact and not volume of prose. Every
finding is re-checked against the tree by symbol lookup before it counts; a
claim that does not hold counts for nothing, however well it is written.

Assessment is **per finding, not per issue**. Splitting one finding across five
issues does not multiply it, and grouping ten findings into one issue does not
divide it.

### Base — by verified severity

| Severity | Weight | Meaning |
|---|---|---|
| Critical | 100 | A core guarantee fails protocol-wide, or silently, or with no in-canister recovery |
| High | 50 | A stated guarantee breaks on a value, integrity or availability path, bounded in scope |
| Medium | 20 | Real defect with a narrow precondition or bounded blast radius |
| Low | 8 | Correctness or robustness wart; no stated guarantee broken |
| Informational | 3 | Drift, stale docs, readiness gaps |

Severity follows [SECURITY.md](SECURITY.md)'s own scope list: solvency and
conservation, authorization and scoping, ledger integrity, matching fairness,
availability.

**Play money caps value-theft magnitude. It does not cap availability,
integrity, or anything that targets users rather than the protocol** — those
weigh at full severity.

### Modifiers — per finding

| Modifier | Weight | Applied when |
|---|---|---|
| Reproduced | +15 | Working steps or measurements on an unmodified build |
| Root cause | +10 | Identifies the mechanism, not just the symptom |
| Fix quality | +5 | Suggested fix is correct and reuses a pattern already in the tree |
| Overstated | −10 | Claimed severity materially exceeds verified impact |
| Refuted | ×0 | The claim does not hold against the code |

### Conduct — per report

| Bonus | Weight | Applied when |
|---|---|---|
| Responsible restraint | +25 | Withheld a reproduction that would arm attacks on **end users**, pending a private channel |
| Honest confidence | +10 | Explicitly separates what was confirmed from what was not established |
| Cross-crediting | +10 | Credits another contributor's finding instead of absorbing it |
| Independent confirmation | 25% of base | Reached an already-reported finding independently, with added evidence |

### Not counted

Per SECURITY.md's stated scope: findings that require a malicious controller
(unless the finding *is* that the controller-trust boundary does not hold),
volumetric denial of service against IC boundary infrastructure, and dev-only
surfaces (`#dev` hooks, `xrc-mock`, `fuel-mock`) unless reachable on a live
posture.

---

## How this is applied

Every finding in the linked verification document was weighed against the
rubric above, and we keep that tally as the reviews continue. We don't publish
a running per-contributor scoreboard: how any single finding was assessed is a
conversation to have on that finding's own thread, where the code is, rather
than a number to rank people by. If you want to know how a finding of yours was
weighed, ask on its issue and we will walk the rubric line by line.

The August 2026 reviews — from OhShii Labs, the Menese DeFi Team, and
`andreij6`, working independently — were together the most valuable external
contribution this project has had. Several findings turned out **worse** than
the reporters claimed once verified; several corrected fixes we had already
shipped; and the reviewers repeatedly killed their own drafts in review rather
than pad a queue. That is the behaviour this rubric exists to weigh heavily,
and it did.

---

## Contributing

Security reports: see [SECURITY.md](SECURITY.md). Findings in the listed scope
categories weigh highest. A report that includes reproduction steps, identifies
the mechanism rather than the symptom, and proposes a fix that fits the
existing code will weigh roughly twice what the same finding weighs without
them.

If a finding would arm an attack against end users rather than against the
protocol, please tell us the class and ask for a private channel rather than
publishing the reproduction. That weighs here, and it is the right thing to do.
