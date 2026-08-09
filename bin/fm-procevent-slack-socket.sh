#!/usr/bin/env bash
# Slack Socket Mode adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-slack-socket.sh arm
#   fm-procevent-slack-socket.sh show <result-file>
#   fm-procevent-slack-socket.sh classify <result-file>
#   fm-procevent-slack-socket.sh terminal <result-file>
#   fm-procevent-slack-socket.sh source-id
#   fm-procevent-slack-socket.sh retire
#
# `arm` records one fixed source for #alexa (C01BGF5FY8P). The child obtains the
# bot identity and each one-use WebSocket ticket from the fixed cick-bot exe.dev
# integration. No xapp token or ticket is accepted from local configuration.
#
# A valid result ends one connection generation but not the registered source.
# The generic runner keeps that registration and restart reconciliation opens
# the next generation. This adapter never acknowledges a result: firstmate must
# process the untrusted message and then call fm-procevent.sh handled itself.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SOURCE_ID=slack-alexa-C01BGF5FY8P
SOURCE="$SCRIPT_DIR/fm-slack-socket-source.mjs"
RUNNER="$SCRIPT_DIR/fm-procevent.sh"
REG="$STATE/procevent"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }
node_path() { command -v node 2>/dev/null || die "node is not installed"; }

register_source() {
  local node
  node=$(node_path) || return 1
  "$RUNNER" register slack-socket "$SOURCE_ID" -- "$node" "$SOURCE" --state-dir "$STATE" --source-id "$SOURCE_ID"
}

source_is_exact() {
  local record="$REG/$SOURCE_ID.source" node adapter argc marker arg1 arg2 arg3 arg4 arg5 arg6
  node=$(node_path) || return 1
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  {
    IFS= read -r adapter && IFS= read -r argc && IFS= read -r marker \
      && IFS= read -r arg1 && IFS= read -r arg2 && IFS= read -r arg3 \
      && IFS= read -r arg4 && IFS= read -r arg5 && IFS= read -r arg6 \
      && ! IFS= read -r _
  } < "$record" || return 1
  [ "$adapter" = adapter=slack-socket ] && [ "$argc" = argc=6 ] && [ "$marker" = argv: ] \
    && [ "$arg1" = "$node" ] && [ "$arg2" = "$SOURCE" ] && [ "$arg3" = --state-dir ] \
    && [ "$arg4" = "$STATE" ] && [ "$arg5" = --source-id ] && [ "$arg6" = "$SOURCE_ID" ]
}

cmd_source_id() { [ "$#" -eq 0 ] || usage; printf '%s\n' "$SOURCE_ID"; }

cmd_arm() {
  [ "$#" -eq 0 ] || usage
  [ -x "$SOURCE" ] || die "Slack Socket Mode source is not executable"
  if source_is_exact; then
    printf 'armed: %s\n' "$SOURCE_ID"
    return 0
  fi
  register_source || die "cannot register Slack Socket Mode source"
  printf 'armed: %s\n' "$SOURCE_ID"
}

cmd_show() {
  local result=${1-} node
  [ "$#" -eq 1 ] && [ -n "$result" ] || usage
  node=$(node_path) || return 1
  "$node" "$SOURCE" --show-result "$result"
}

cmd_classify() {
  [ "$#" -eq 1 ] || usage
  if cmd_show "$1" >/dev/null 2>&1; then printf 'message\n'; else printf 'unknown\n'; fi
}

cmd_terminal() {
  [ "$#" -eq 1 ] || usage
  cmd_show "$1" >/dev/null 2>&1 || return 1
  # A message ends only this WebSocket generation, never the durable source.
  return 1
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  "$RUNNER" retire "$SOURCE_ID"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  show) shift; cmd_show "$@" ;;
  classify) shift; cmd_classify "$@" ;;
  terminal) shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
