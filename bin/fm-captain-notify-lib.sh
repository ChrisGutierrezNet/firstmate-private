#!/usr/bin/env bash
# Shared non-blocking wrapper for captain Slack milestone notifications.
# Callers pass one stable event key and the exact captain-ready text.
# Notification failure is reported to stderr but never changes the caller's
# own delivery or approval result.

fm_captain_notify_nonblocking() {
  local event_key=$1 text=$2 out rc script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  set +e
  out=$("$script_dir/fm-captain-notify.sh" "$event_key" --text "$text" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf 'warning: captain Slack notification failed: %s\n' "$out" >&2
  fi
  return 0
}
