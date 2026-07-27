---
name: release-batching-protocol
description: >-
  Agent-only policy for Firstmate risk-class parallel certification and release batching.
  Use before initial intake, dispatch, or spawn decisions that may let multiple ship lanes proceed; when risk class affects queued-work re-evaluation; before deciding that multiple ship lanes may certify or release together; and before batching captain-facing release status.
user-invocable: false
metadata:
  internal: true
---

# release-batching-protocol

This skill is the single owner of Firstmate's risk-class parallel certification and release-batching policy.
It applies across every supported primary harness and runtime backend because it constrains shared dispatch, queue re-evaluation, validation, release, and captain-facing status behavior before backend-specific mechanics run.
It never expands project-write, cleanup, merge, production, destructive, irreversible, security-sensitive, no-mistakes ownership, or approval authority.

## Evidence Inputs

Classify from current durable evidence, not conversational memory.
Use the task brief, current backlog dependencies and time gates, relevant reports, task metadata, current `bin/fm-crew-state.sh` output when validation state matters, the selected delivery mode, configured `yolo` posture, and current PR or branch evidence from the forge or guarded local helpers.
If the evidence does not establish independence and the class would affect whether work proceeds in parallel, treat the lane as serialized or escalate the uncertainty when production, destructive, irreversible, or security-sensitive consequences are possible.

## Low-Risk Certification Lanes

Independent low-risk certification may run in parallel for UI, documentation, tooling, lint rules, labels, and templates.
A low-risk lane is independent only when it has no semantic dependency on another active lane, no shared mutable external state, no incompatible migration or rollout sequence, and a selected delivery path that can reconcile ordinary rebase or conflict work.
Same-file overlap alone is not a blocker.
File overlap becomes a blocker only when the edits encode a real semantic dependency, mutate a shared generated artifact, compete for one external resource, or make one lane's validation result stale.
Parallel certification means each lane still runs its own selected delivery path, tests, review gates, PR or ready-branch checks, and current-code validation evidence.

## Serialized Classes

Migrations remain isolated and serialized.
Authentication, billing, runtime state machines, and deployment infrastructure remain isolated and serialized.
Security-sensitive changes are never batched for speed.
Unrelated migrations are never batched for speed.
Production migration remains singular.
Container cutover remains singular.
Production release remains singular unless the captain gives explicit release authority for that concrete production action.
Dark-feature activation is not authorized by parallel certification or release batching.
Destructive or irreversible action is not authorized by parallel certification or release batching.
If a lane mixes low-risk work with any serialized class, classify the whole lane by the serialized class until the risky work is split out or complete.

## Dispatch And Queue Re-Evaluation

At intake, classify the requested ship work before using concurrency as a reason to spawn, hold, or route multiple lanes.
At backlog re-evaluation, apply the same classification to every queued item whose dependencies and time gates have cleared.
Dispatch all eligible independent low-risk lanes that can proceed without shared mutable external state.
Do not hold an eligible low-risk lane only because another low-risk lane touches the same file.
Hold or serialize a lane when it depends on an active high-risk lane, modifies the same migration or rollout sequence, changes the same production or deployment resource, or could make another lane's validation evidence obsolete.
Keep the blocker durable in the backlog rather than relying on the next agent to remember the reason.

## Validation And Release

Parallel certification does not combine validation runs.
Each lane's worker remains responsible for its own no-mistakes run, direct-PR checks, or local-only ready branch under the selected delivery path.
Firstmate may treat multiple independent low-risk lanes as concurrently releaseable only after each lane is independently ready under its own delivery path and approval posture.
Release batching is an administrative grouping of already-ready low-risk lanes.
It never replaces per-task `bin/fm-pr-check.sh`, `bin/fm-pr-merge.sh`, `bin/fm-merge-local.sh`, `bin/fm-teardown.sh`, or the guarded fleet-sync path.
Run those helpers per task so merge metadata, landed-work proof, cleanup refusal, and clone refresh behavior remain intact.
If one merge, local landing, or sync could invalidate another lane's validation basis, re-check that lane before landing it.
Never merge a red PR, never infer approval from batching, and never use batching to bypass an ask-user, captain approval, security, destructive, irreversible, or production boundary.

## Captain-Facing Status

Batch non-urgent ready updates only when the grouping reflects independent low-risk lanes that are ready under their own delivery paths.
Describe the concrete outcome and consequence, not the internal risk-class mechanics.
When approval is still required, present the ready lanes together but ask for the same approval that each lane would have required individually.
When `yolo` authorizes routine green low-risk merges, report the finished PR URLs or local-main outcomes after each helper completes.
Never phrase certification batching as feature activation, production release, migration execution, deployment cutover, or approval for destructive, irreversible, or security-sensitive work.
