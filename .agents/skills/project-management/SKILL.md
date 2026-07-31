---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project, and before retiring an out-of-registry project tree.
  Cloning or registering a project is add intake and uses the same trigger.
  Owns project add, create, clone, remove, retire, initialization, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project, and before retiring an out-of-registry project tree.
Cloning or registering a project is add intake and uses the same trigger.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Before adding, cloning, creating, or registering any project in the main home, inspect the authoritative `data/secondmates.md` routing table and judge every existing natural-language `scope:` against the proposed project or domain.
Apply `AGENTS.md` section 7's authoritative secondmate routing rules; if an existing scope owns that domain, route the new-project operation or work there instead of creating or registering a duplicate main-home clone.
Absence from the main `data/projects.md` registry is never evidence that no second mate owns the domain.
If the owning second mate cannot accept the route, report that concrete blocker or obtain an explicit captain redirection rather than silently duplicating the project in the main home.

Resolve the project name, destination, delivery mode, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

## Delivery posture

Choose the delivery mode when adding or creating the project:

- `no-mistakes` runs the full validation pipeline before a PR and is the default when the captain does not specify a mode.
- `direct-PR` pushes and opens a PR without the no-mistakes pipeline.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.

The optional `+yolo` posture changes routine approval authority but does not change the delivery mode.
Default it off, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the complete authority boundary and exceptions when it is on.

## Add or clone an existing project

Confirm the source URL, local project name, delivery mode, and autonomy posture.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
A `no-mistakes` project must have an `origin` remote and must complete the initialization procedure below.
A `direct-PR` project needs an `origin` remote but skips no-mistakes initialization.
A `local-only` project may have no remote and skips no-mistakes initialization.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery mode, defaulting visibility to private and delivery mode to `no-mistakes`, then obtain the captain's explicit consent for those values.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, add the registry entry, and initialize it according to its delivery mode.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Initialize

Run no-mistakes initialization only for `no-mistakes` projects:

```sh
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

Initialization configures the local gate and does not vendor a no-mistakes skill into the project.
Do not create a commit merely because initialization ran.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.

## Remove or retire

Project removal is destructive, and so is retiring an out-of-registry legacy tree left behind by an earlier layout.
Both start from the same preflight, and they differ only in what performs the removal.

First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing anything.
Never issue a raw removal command from Firstmate.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.

### Remove a registered project

A project registered in `data/projects.md` and living under this home's `projects/` keeps its own path.
Once that preflight confirms none of the above and the captain's approval is concrete, AGENTS.md hard rule 1's captain-approved project operation exception authorizes firstmate to remove the clone directly and update its registry entry to match.
`bin/fm-project-retire.sh` does not cover this case: it refuses on any path inside this home's `projects/` or named by the registry, and that refusal is a deliberate scope boundary, not a step to work around.

### Retire an out-of-registry tree

A legacy tree outside `projects/`, such as an old clone plus its linked Treehouse pool left behind by an earlier layout, is retired only through the guarded helper.

`bin/fm-project-retire.sh` is the single guarded owner of that removal itself.
Its header and `--help` own the exact flags, the complete refusal list, the landing-proof ladder, and every mechanic; do not restate them here or anywhere else.
The order that matters is:

1. Get the captain's concrete approval for that specific tree.
2. Retire any stale registry line that still names the tree first, because the helper refuses while `data/projects.md` or `data/secondmates.md` names the path; a registry line without a clone is navigable, a clone the registry still points at is not. Never delete a live registered project's line to move it out of the helper's refusal list; that project uses the direct path above.
3. Run the helper's preflight, read the printed plan end to end, and confirm it names exactly the tree and linked pool the captain approved.
4. Execute only with the plan id that preflight printed, so evidence that changed in between refuses instead of removing a tree nobody approved.

A refusal from that helper is a stop-and-report result, never an obstacle to route around: do not force, prune, stash, reset, or discard anything to make a check pass, and do not fall back to a raw removal command.
Once the captain's approval is concrete and the helper's own checks pass, AGENTS.md hard rule 1's guarded out-of-registry project-tree retirement exception authorizes running it.
