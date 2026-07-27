# Firstmate-Owned Extensions

`bin/fm-extension.sh` owns the Stage 0 local extension host mechanics and help output.
This page records the current operating boundary and the supported proof surface.

Stage 0 exists to validate one explicitly configured local extension pack.
It does not implement a plugin marketplace, automatic network installs, secondmate distribution, ACP proxying, new No Mistakes pipeline phases, an upstream No Mistakes fork, or production activation.

## Manifest Boundary

The only supported manifest API is `firstmate.extension/v1`.
The only supported config API is `firstmate.extension.config/v1`.
The config file names one absolute local manifest path and the expected SHA-256 of that manifest.
The manifest names an ID, version, local source path, version requirements, explicit capabilities, default-deny permissions, and hashed entrypoints.
The source path must be local and must stay inside the directory that contains the manifest.
Entry points must be regular owner-executable files, must not be symlinks, must not escape the source root, must not be group-writable, and must not be world-writable.
The extension source root, config file, manifest file, and entrypoint files must not be unsafe group-writable or world-writable paths.

Stage 0 accepts only these capabilities.

- `no_mistakes.repo_command` allows a generated wrapper to be used as a trusted No Mistakes `commands.lint`, `commands.test`, or `commands.format` command.
- `no_mistakes.wrapper` is reserved for wrapper entrypoints that call the installed No Mistakes binary without replacing it.
- `no_mistakes.axi_observe` allows read-only `no-mistakes axi status` and `no-mistakes axi logs` observation through the host.

Unknown capabilities fail closed.
Capability grants are not inherited across capability families.
The host never calls `no-mistakes axi run` or `no-mistakes axi respond`.

Stage 0 permissions are default-deny metadata, not an operating-system sandbox.
`permissions.network` must be absent or `false`.
`permissions.read` and `permissions.write` must be absent or empty arrays.
Any requested read, write, or network permission fails activation and execution.

## Local Lifecycle

Use `bin/fm-extension.sh doctor` to validate a configured extension without writing generated material.
Use `bin/fm-extension.sh activate` to render owner-marked local wrapper files under `<FM_HOME>/state/extensions/<id>/generated/`.
Use `bin/fm-extension.sh render-no-mistakes` to print the trusted `.no-mistakes.yaml` command snippet for activated wrappers.
Use `bin/fm-extension.sh run <id> <entrypoint> -- ...` to execute one validated entrypoint as a subprocess with a deterministic environment.
Use `bin/fm-extension.sh observe-no-mistakes <id> status` or `logs` for read-only AXI observation.
Use `bin/fm-extension.sh deactivate <id>` to remove only owner-marked generated files.

Deactivation leaves unmarked local files in place.
Deactivation leaves logs and other non-generated state in place.
This prevents the host from deleting material it did not create.

## No Mistakes Boundary

The host treats No Mistakes as an installed external binary.
It checks compatibility with `no-mistakes --version`.
It never replaces the installed `no-mistakes` binary.
It never mutates any No Mistakes project clone.
It never starts, stops, restarts, or updates the shared No Mistakes daemon.
Tests use disposable scratch repositories and isolated `NM_HOME` values.

The Stage 0 proof uses No Mistakes only through supported command and AXI seams.
Generated repo-command wrappers are ordinary subprocesses that No Mistakes can call from `commands.lint`, `commands.test`, or `commands.format`.
Read-only observability is limited to `axi status` and `axi logs`.
Pipeline ownership remains with the worker that starts a No Mistakes run, as required by `AGENTS.md`.

External No Mistakes PR #588 is outside this implementation path.
That PR is not required for implementation, certification, deployment, or release of the Firstmate-owned extension host.
Uncontrolled repositories, including `kunchenguid/no-mistakes` and any upstream fork, remain outside implementation, certification, deployment, and release for this milestone.
Any future workflow affected by branchsync custody behavior must be gated by installed No Mistakes version checks rather than by upstream PR status.

## Integration Review

The Stage 0 host is a standalone subprocess tool under `bin/`.
It does not change any supported worker harness launch adapter.
It does not change any supported runtime backend adapter.
It does not change `fm-spawn.sh`, `fm-harness.sh`, `fm-backend.sh`, or `bin/backends/*`.
Those axes are not applicable to this milestone because no dispatch, terminal, turn-end, watcher lifecycle, or backend protocol path invokes the host automatically.

The affected integration axes are local config discovery, generated local state, No Mistakes repo-command wrappers, and read-only No Mistakes AXI observation.
`tests/fm-extension.test.sh` covers malformed manifests, unknown capabilities, path traversal, symlinks, unsafe modes, world-writable paths, hash mismatches, incompatible versions, explicit write and network denial, activation ownership markers, clean deactivation, wrapper failure propagation, isolated `NM_HOME`, and read-only AXI observation.
