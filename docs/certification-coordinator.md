# Final certification coordinator

`bin/fm-certification.sh` is the one authoritative owner of the final-certification state machine, ledger format, admission lock, preflight, terminal reconciliation, and worker notification.
This document records the design and safety rationale without duplicating the script's command mechanics.

## Scope

The coordinator governs final heavy No Mistakes certifications only.
Implementation, focused tests, ordinary worker activity, direct-PR delivery, and local-only delivery remain outside its capacity accounting and continue in parallel.
The ordinary backlog remains the owner of task lifecycle and dependencies, while the certification ledger records only final-validation admission and never moves or duplicates backlog items.
The default shared capacity is one.
The first mutation records the configured positive capacity in the machine-global coordinator root, and a caller presenting a different value is refused rather than creating inconsistent limits.
The ledger defaults to `~/.no-mistakes/firstmate-certification`, so primary and secondmate homes on the same machine contend through one owner instead of independent per-home slots.

## Safety invariants

- Every state mutation holds the single machine-global coordinator lock.
- FIFO sequence is durable, and blocked ineligible work does not strand the next eligible request.
- Live records never exceed the durable configured capacity.
- Admission binds one Firstmate home, task identity, ship metadata record, project local copy, isolated copy, attached branch, and exact expected commit.
- Both admission and worker start repeat preflight against current facts.
- Detached HEAD, wrong branch, changed head, dirty isolated copy, non-isolated location, missing or changed task metadata, uncoordinated active validation, obsolete custody, or ambiguous tool output refuses certification.
- A slot is released only by a matching run whose branch and commit ancestry bind it to the admitted expected head and whose authoritative outcome is `checks-passed`, `passed`, `failed`, or `cancelled`.
- Notification moves to an in-progress durable state before submission, so crash ambiguity can lose a steer but cannot automatically duplicate it.
- Explicit retry is required after ambiguous or failed delivery.
- The worker invokes the admitted `start` command in its own process and remains the sole driver of every No Mistakes gate and response.
- The coordinator never invokes `no-mistakes axi respond`, `abort`, `rerun`, `sync`, custody recovery, branch mutation, work disposal, task cleanup, or daemon lifecycle commands.

## States and transitions

`queued` means the request has durable FIFO position but no capacity.
A successful current preflight moves the oldest eligible `queued` request to `admitted` and reserves capacity.
A failed preflight moves only that request to `blocked` with an actionable reason, then admission continues with the next eligible request.
Successful worker-side preflight moves `admitted` to `launching`, after which the worker process starts or reattaches to the matching run.
Reconciliation moves `launching` to `running` once a matching active run is authoritative.
A matching authoritative final result moves `launching` or `running` to `terminal`, releases capacity, and immediately considers the next queued request.
An ambiguous run identity retains the live state and capacity instead of guessing ownership.
`retry` may move a corrected `blocked` request back to `queued`, or explicitly retry a failed or ambiguous notification, without changing its bound branch or expected head.
A changed expected head requires a new explicit request rather than silent rebinding.

## Crash and restart recovery

The queue, sequence, capacity, intent, admission token, notification state, run identity, and final outcome are regular owner-only files under the shared durable root.
Atomic replacement publishes every record transition.
A stale coordinator process lock is reclaimed only through Firstmate's process-identity-aware shared lock owner.
Session start reconciles the queue after the per-home session lock is acquired.
The ordinary watcher also reconciles before status-signal handling, which advances the queue after a worker's terminal result without a repeated manual nudge.
Repeated reconciliation is idempotent.
A crash before notification leaves a pending notification that reconciliation can send.
A crash during notification leaves an ambiguous delivery that requires explicit inspection and retry rather than a possible duplicate.
A crash after worker-side launch custody but before No Mistakes starts retains the slot and refuses an automatic second launch.
After inspection proves no matching run exists, explicit `retry` republishes one token-bound worker instruction; when a matching run does exist, the original start command reattaches to it.
No recovery path changes Git history or invokes No Mistakes custody recovery.

## Authority boundary

Admission, read-only reconciliation, one worker steer, retry after a proven failed delivery, and advancement after an authoritative terminal result are automatic reversible actions.
Changing shared capacity, discarding or rewriting work, cancelling a run, selecting keep-local custody recovery, restarting the shared daemon, and any existing destructive, irreversible, security-sensitive, merge, delivery-mode, or product decision retain their existing captain authority.
The coordinator does not reinterpret project `yolo` posture and never grants merge or gate-decision authority.

## Runtime and worker compatibility

The coordinator reads the backend-neutral `state/<id>.meta` worktree and project fields and delegates delivery through `fm-send`'s recorded endpoint abstraction.
It neither creates, captures, interrupts, resumes, nor destroys an endpoint, so tmux, Herdr, Zellij, Orca, and cmux need no coordinator-specific lifecycle operation.
Orca's worktree provider difference is non-applicable after metadata publication because the same isolated-copy Git preflight applies.
Codex App remains non-applicable because it is not a supported task runtime backend.
The worker instruction names the same shell entry point for Claude, Codex, OpenCode, Pi, and Grok, so slash-command syntax, popup behavior, model flags, effort flags, and busy signatures are non-applicable.
Worker-owned synchronous No Mistakes execution remains unchanged across all five adapters because `start` execs the command inside the worker's own process and returns every gate result to that worker.

## Evidence

Focused behavior coverage lives in `tests/fm-certification.test.sh`.
The suite covers concurrent admission, restart reconciliation, detached and wrong branches, changed expected heads, obsolete custody, preserved unpublished work, uncoordinated active runs, terminal advancement, duplicate-notification suppression, and command failure paths.
