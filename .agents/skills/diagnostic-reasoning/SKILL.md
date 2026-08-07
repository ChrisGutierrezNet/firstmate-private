---
name: diagnostic-reasoning
description: >-
  Agent-only procedure for diagnosing reported bugs and other unexplained failures.
  Use before scoping a reported bug, a failing test, a build or integration failure, a performance problem, or a repeated failed repair, before acting on a diagnostic report, and whenever an obvious quick fix is tempting but unverified.
  Owns end-user-aligned reproduction, the red-capable reproduction loop, causal separation, divergent-path and history inspection, ranked falsifiable hypotheses, counterfactual testing, disconfirming evidence, and the root-cause fix and verification standard.
user-invocable: false
metadata:
  internal: true
---

# diagnostic-reasoning

Use this procedure before scoping a reported bug or any other unexplained failure, and before acting on a diagnostic report.
This skill is the single owner of Firstmate's bug-diagnosis reasoning procedure.
Firstmate applies it when briefing delegated investigation and evaluating the resulting evidence, without taking over project-specific investigation itself.

Load it for a reported bug, a failing test, unexpected production behavior, a build or integration failure, a performance problem, a repair that has already failed more than once, and the case where an obvious quick fix is tempting but nothing has verified it yet.
The last case is the most common way this procedure gets skipped, and a simple-looking fault still has a root cause.

The four stages below run in order.
Do not propose a fix from a stage you have not finished.

## Stage 1: establish the real failure

Read the complete error, warning, stack trace, log output, and surrounding output before forming any theory.
Start from the end user's experience rather than an internal error string or an implementation hypothesis.
Require an end-to-end reproduction aligned with the real user path whenever it is feasible and safe.
If a faithful reproduction is not feasible, record the exact limitation and use the closest representative path without presenting it as equivalent evidence.
Capture the expected behavior, observed behavior, setup, inputs, and repeatability before assigning a cause.

Build a tight reproduction loop and treat it as the diagnostic work rather than a formality.
The loop must be a fast, deterministic, agent-runnable command that fails on the exact reported symptom before the fix and passes after it.
A nearby failure, a generic "does not crash" assertion, or a clean compile alone is not a reproduction.
When a clean reproduction is hard, spend the effort raising the reproduction rate or building a minimal harness rather than guessing without a loop.

Inspect the recent relevant changes and configuration that could produce this behavior.
In a multi-component system, gather evidence at each component boundary so the point where correct data first becomes incorrect is located by evidence rather than assumption.
When the failure surfaces deep in a call stack, trace the bad value upstream to the place it originates rather than patching where it is observed.

Separate these three facts explicitly:

- The **initiating trigger** is the event, input, or transition that starts the faulty behavior.
- The **masking condition** is the independent state, environment, timing, cache, configuration, or path difference that hides or exposes the fault.
- The **visible symptom** is what the end user or operator can actually observe.

Do not collapse those facts into one label.
A masking condition may explain why a fault appears only sometimes without being the initiating cause, and the visible symptom may be several layers downstream from both.

## Stage 2: understand the pattern

Minimize the reproduction while it still fails, removing inputs, callers, configuration, data, and steps one at a time and re-running the loop after each removal.
Keep only what is load-bearing for the failure, because a minimal reproduction narrows the hypothesis space and usually becomes the cleanest regression test.

Inspect the failing path and a proven path where the intended behavior is known to work.
Find comparable working code in the same repository rather than reasoning from the failing path alone.
Read a reference implementation completely before applying its pattern, because a partial reading reliably reproduces the defect it was supposed to prevent.
List every meaningful difference between the working and failing paths, including differences that look too small to matter.
Understand the assumptions, dependencies, configuration, and environment each path relies on.

Compare their inputs, state transitions, dependencies, timing, and control flow to find the earliest meaningful divergence.
Inspect relevant history, including blame, commits, migrations, and prior implementations, when it can explain why the paths diverged or which invariant was intended.
Do not treat the most recent nearby change as causal without evidence.

## Stage 3: test falsifiable hypotheses

Form several plausible hypotheses before testing any one of them, and rank them by likelihood and by how cheaply each can be falsified.
State for each what observation would support it and what observation would reject it, and sharpen or discard any hypothesis that makes no testable prediction.
Test the cheapest and most likely hypothesis first.

Identify the smallest counterfactual that should change the outcome if the leading explanation is true.
Change one condition at a time where practical, and record whether the symptom appears, disappears, or remains unchanged.
Do not stack speculative fixes: when evidence disproves a hypothesis, return to investigation rather than layering another patch on top of the last one.
Seek disconfirming evidence deliberately: name what observation would falsify the leading explanation, run that check when feasible, and retain contradictory results instead of explaining them away.
Compare the final explanation against the proven path and show why the proposed causal boundary accounts for both the failure and the success.

## Stage 4: implement and verify the root-cause fix

Preserve the reproduction as an automated regression test whenever that is practical in the project.
Implement one fix that addresses the identified root cause, without unrelated refactoring or opportunistic cleanup bundled into it.
Re-run the exact reproduction that was red, then run the broader regression checks the project expects.

If three attempted fixes have failed, stop attempting further patches.
Repeated failure across three attempts, each revealing new coupling or new symptoms elsewhere, is evidence that the architecture or the underlying model is wrong rather than evidence that a fourth patch is needed.
Raise that architectural question through Firstmate's existing authority path instead of continuing to patch.

## Firstmate interaction rules

These override any upstream phrasing of the procedure above.

- Crewmates never address the captain.
  A product or human decision is reported as `needs-decision:` and a concrete inability to proceed is reported as `blocked:`, through the status protocol in the task brief.
- A known external wait that is expected to clear on its own uses the configured external-wait state rather than `blocked:`.
- The architectural stop after three failed fixes is an escalation, not an invitation to redesign unilaterally.
- The selected delivery path stays authoritative.
  When No Mistakes owns the run, its gates own review and fixes, and this procedure informs the investigation rather than competing with the pipeline.
- Never stop, restart, or otherwise interfere with a shared daemon in order to reproduce or verify a failure.

## Scope and act on the result

A diagnosis brief should ask for the reproduction, trigger/mask/symptom separation, divergent and proven path comparison, relevant history, smallest counterfactual, and disconfirming evidence in the report.
A diagnostic report should distinguish observed facts from hypotheses and state any unresolved uncertainty that could change the recommended scope.
Before acting on the report, verify that its claimed cause explains the end-user reproduction and the proven path without relying on an untested masking condition.
If a load-bearing element is missing, route a focused follow-up investigation instead of treating confidence or implementation detail as proof.
A diagnosis or implementation-ready recommendation is evidence, not authorization to change code.
Implementation still requires the captain's request or another existing lifecycle authority, and the reproduction should become the regression test when a fix is authorized.
