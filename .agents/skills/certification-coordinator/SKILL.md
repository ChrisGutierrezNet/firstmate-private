---
name: certification-coordinator
description: >-
  Agent-only final-certification admission procedure.
  Load before requesting, retrying, or reconciling a heavy No Mistakes certification, and when a certification coordinator notification is surfaced.
user-invocable: false
metadata:
  internal: true
---

# certification-coordinator

Load this before requesting, retrying, or reconciling a final heavy No Mistakes certification, and whenever monitoring surfaces a coordinator refusal.
`bin/fm-certification.sh` is the state-machine and command-contract owner.
[`docs/certification-coordinator.md`](../../../docs/certification-coordinator.md) owns the design rationale, safety invariants, recovery model, and authority boundary.
Do not reproduce either contract from memory.

## Request final certification

Confirm implementation and focused tests are committed before requesting capacity.
Write the accepted captain intent to a private task-local file, preserving the objective and material decisions rather than summarizing the diff.
Resolve the exact full expected commit from the worker's isolated branch.
Run `bin/fm-certification.sh enqueue <task-id> <expected-head> --intent-file <path>` with the active `FM_HOME` explicit when it is not already exported.
Treat a blocked result as the concrete safety refusal it names.
Do not bypass the coordinator by sending a harness-specific No Mistakes invocation directly.

The coordinator may admit immediately or retain durable FIFO position.
On admission it sends the worker a token-bound `fm-certification.sh start` command.
That command repeats preflight and execs No Mistakes inside the worker's process, so the worker continues to own all synchronous returns and every gate response.
Firstmate never runs `no-mistakes axi respond` for that worker.

## Reconcile and retry

Session start and ordinary monitoring invoke `reconcile --notify` automatically.
A terminal result advances the next eligible request without a manual nudge.
Use `status` for a read-only queue view.
Use `retry <task-id>` only after correcting the recorded refusal or inspecting an ambiguous notification delivery.
Retry never changes the bound branch or expected head.
A changed expected head needs a new explicit certification request and must not be silently substituted.

Never answer a coordinator refusal by resetting, rebasing, stashing, discarding, cancelling, restarting the shared daemon, retiring unpublished commits, or invoking custody recovery.
Use the authority those actions already require under the ordinary Firstmate and No Mistakes contracts.
