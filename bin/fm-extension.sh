#!/usr/bin/env bash
# fm-extension.sh - minimal Firstmate-owned local extension host.
#
# Stage 0 intentionally supports one explicit local extension at a time.
# The extension is discovered from a local config JSON file, validated against a
# `firstmate.extension/v1` manifest, and invoked only as a subprocess wrapper.
# No code is loaded in-process, no remote source is downloaded, and no upstream
# No Mistakes repository or shared daemon state is mutated by this host.
#
# Config discovery:
#   --config <path>                    use one explicit config file
#   --home <FM_HOME> <id>              use <FM_HOME>/config/extensions.d/<id>.json
#   --home <FM_HOME>                   discover only when that dir has exactly one JSON config
#
# Config JSON:
#   {
#     "api_version": "firstmate.extension.config/v1",
#     "id": "owned-nm-policy",
#     "manifest_path": "/absolute/local/extension/extension.json",
#     "manifest_sha256": "<64 lowercase hex sha256>"
#   }
#
# Manifest JSON:
#   {
#     "api_version": "firstmate.extension/v1",
#     "id": "owned-nm-policy",
#     "version": "0.1.0",
#     "source": { "type": "local_path", "path": "." },
#     "requires": { "firstmate": ">=0.0.0", "no_mistakes": ">=1.40.1" },
#     "capabilities": ["no_mistakes.repo_command", "no_mistakes.axi_observe"],
#     "permissions": { "network": false, "read": [], "write": [] },
#     "entrypoints": {
#       "lint": {
#         "path": "bin/lint-wrapper",
#         "sha256": "<64 lowercase hex sha256>",
#         "capabilities": ["no_mistakes.repo_command"],
#         "no_mistakes_command": "lint"
#       }
#     }
#   }
#
# Commands:
#   fm-extension.sh doctor [id]                         validate only
#   fm-extension.sh activate [id]                       render owner-marked local wrappers
#   fm-extension.sh deactivate [id]                     remove only owner-marked generated files
#   fm-extension.sh run <id> <entrypoint> -- [args...]  run one validated wrapper entrypoint
#   fm-extension.sh render-no-mistakes [id]             print trusted repo-command YAML snippets
#   fm-extension.sh observe-no-mistakes <id> status -- [args...]
#   fm-extension.sh observe-no-mistakes <id> logs -- [args...]
#
# Global options:
#   --home <FM_HOME>             local firstmate home for config/state
#   --config <path>              explicit extension config JSON
#   --no-mistakes-bin <path>     No Mistakes binary for version checks and AXI observation
#   -h, --help                   print this header
#
# Generated material lives under:
#   <FM_HOME>/state/extensions/<id>/generated/
#
# Deactivation only removes generated files carrying this host's owner marker.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,58{s/^# \{0,1\}//;p;}' "$0"
  exit 0
fi

exec node "$SELF_DIR/fm-extension-host.mjs" --fm-root "$ROOT" "$@"
