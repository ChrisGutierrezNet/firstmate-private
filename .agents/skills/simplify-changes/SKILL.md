---
name: simplify-changes
description: >-
  Optional cleanup review of recent changes from four narrow perspectives - reuse, quality, efficiency, and altitude.
  Use only when the captain explicitly asks to simplify, clean up, or tidy recent changes.
  Owns the four review perspectives, the evidence and risk-classification bar, and the aggregation and application rules.
user-invocable: true
metadata:
  internal: true
---

# simplify-changes

An optional cleanup pass over a specific set of recent changes, reviewed from four narrow perspectives instead of one broad one.
This improves code that already works.
It is not a bug hunt, and it is not a correctness or security review.

## Strictly opt-in

Run this only when the captain explicitly asks for it.
It never runs automatically after an edit, a commit, a task, or a pipeline stage, and it is never appended to an unrelated task as a bonus pass.
`AGENTS.md` section 7 forbids adding an independent reviewer to the delivery path; this skill stays inside the exception section 7 already grants for a review the captain explicitly requested as the deliverable.

Honor whatever the captain scopes: a named diff, branch, commit, or path, a single perspective, or a report-only run with nothing applied.
The default scope is the change set the captain named; if none was named, ask which changes rather than guessing.

## Delegation

Use Firstmate's existing delegation lifecycle: brief and spawn crewmates with `bin/fm-brief.sh` and `bin/fm-spawn.sh` exactly as for any other work.
Do not build a new fan-out mechanism, agent runtime, or review pipeline for this skill.
Firstmate never edits a project itself, so any change this pass produces is delivered by a crewmate through that project's selected delivery path, with its normal branch, validation, PR, and merge-authority rules intact.
When delegation is unavailable or disproportionate for a very small diff, work the four perspectives sequentially yourself and say plainly in the report that it was a single-pass review rather than four independent ones.

## The four perspectives

Give each perspective the complete diff under review plus repository access, because cross-file duplication and cross-file waste are invisible in a fragment.

**Reuse.**
Search the repository for existing helpers, constants, utilities, abstractions, and patterns before accepting anything new as necessary.
Flag new code that reimplements something the repository already provides, and name the existing thing and where it lives.

**Quality.**
Look for redundant state, parameter sprawl, copy-paste variation that should share an abstraction, leaky abstractions, needless nesting, stringly typed logic where a constant or registry already exists, inconsistent patterns, and low-value generated-code noise such as comments restating the obvious line beneath them.

**Efficiency.**
Look for duplicated work, unnecessary reads or API calls, independent operations left serial where concurrency is safe, hot-path bloat, unbounded growth, leaks, overly broad reads, silently swallowed errors, and existence pre-checks that create a time-of-check to time-of-use gap instead of attempting the operation and handling failure.

**Altitude.**
Determine whether the change fixes the shared underlying mechanism or leaves the broader defect in place behind a caller-specific bandage, workaround, magic escape hatch, or special case.
Name the mechanism the change is avoiding and describe the deeper fix.

## Evidence bar for every finding

A finding that does not meet all of these is dropped rather than reported.

- Inspect the surrounding repository, not the diff alone.
- Cite concrete `file:line` evidence for both the problem and any existing thing you say should be used instead.
- State the actual cost: what is duplicated, wasted, slowed, or made harder to maintain.
  A finding that cannot say what it costs is a nit.
- State confidence.
- Classify risk as `SAFE`, `CAREFUL`, or `RISKY`.
  `SAFE` cannot affect behavior.
  `CAREFUL` improves the code without changing semantics.
  `RISKY` may change behavior or touches a public contract.
- Before recommending removal of code that looks unusual or unnecessary, inspect its history and surrounding intent.
  Compatibility shims, staged migrations, deliberate isolation layers, and intentionally ignored errors are designs, not accidents; when the intent cannot be established, mark confidence low and do not recommend removal.
- Do not report style-only churn or unsupported guesses.

## Aggregation

1. Deduplicate overlapping findings; when two perspectives name the same line or the same underlying mechanism, collapse them into one.
2. Discard findings that do not meet the evidence bar, without arguing them out.
3. Resolve conflicts with correctness first, then the captain's stated focus, then clarity and reuse, then micro-performance.
4. Apply changes only when the captain asked for changes rather than a report:
   - apply `SAFE` findings;
   - apply `CAREFUL` findings individually, verifying each before continuing and reverting any that break something;
   - never apply a `RISKY` architectural or public-contract change automatically, and present it for the captain's decision instead.
5. Report a deeper altitude finding as separately scoped work when the right fix is larger than this cleanup pass, rather than rebuilding shared infrastructure inside it.
6. If a genuine correctness bug surfaces, report it prominently as its own finding and route it through the normal diagnostic and delivery path; do not fold it into cleanup.

## Reporting

Report to the captain in the outcome language `AGENTS.md` section 9 requires: what changed, what was deliberately left alone, what needs their decision, and any deeper work worth scoping separately.
