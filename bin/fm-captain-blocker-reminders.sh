#!/usr/bin/env bash
# fm-captain-blocker-reminders.sh - recurring reminders for captain-action blockers.
#
# This script is the deterministic, agent-facing owner for recurring captain-action
# reminder discovery and deduplication.
# It reads the canonical local fleet snapshot, never task-controlled scripts or
# terminal prose, and writes only private state under the active home's state dir.
#
# Discovery source:
#   bin/fm-fleet-snapshot.sh --json
#
# Eligible blockers:
#   - Structured tasks-axi captain holds that are currently captain_actionable.
#   - Reconciled open status decisions with needs-decision or blocked verbs.
#   - PR release approvals where a live task's current state says checks are green
#     or PR ready and a PR URL is recorded.
#
# Exclusions are inherited from the fleet snapshot and status classifier:
# benign queued waits, declared external waits, resolved/deferred/completed work,
# and stale historical status lines do not enter this script's blocker set.
#
# Reminder cadence and active local-time window:
#   FM_CAPTAIN_REMINDER_SECS          default 3600 seconds.
#   FM_CAPTAIN_REMINDER_START_HOUR    default 9.
#   FM_CAPTAIN_REMINDER_END_HOUR      default 23.
#   FM_CAPTAIN_REMINDER_TZ            optional timezone for date(1); absent uses
#                                     the home process's local timezone.
#   FM_CAPTAIN_REMINDER_NOW_EPOCH     test seam for current epoch seconds.
#
# The default active window is 09:00 through 23:59 local time.
# Outside the active window the script reconciles state and emits nothing.
# Repeated execution is idempotent: the same blocker emits at most once per
# cadence window, emits again after the interval while still unresolved, and resets
# immediately when the blocker resolves or its material summary changes.
#
# Usage:
#   fm-captain-blocker-reminders.sh
#   fm-captain-blocker-reminders.sh --list
#   fm-captain-blocker-reminders.sh -h|--help
#
# Default mode prints due captain-facing reminder lines and updates dedupe state.
# --list prints the current eligible blockers without changing dedupe state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SNAPSHOT_BIN="${FM_CAPTAIN_REMINDER_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
REMINDER_DIR="${FM_CAPTAIN_REMINDER_STATE_DIR:-$STATE/.captain-blocker-reminders}"

MODE=emit
case "${1:-}" in
  "") ;;
  --list) MODE=list ;;
  -h|--help)
    awk '
      NR == 1 { next }
      /^#/ { sub(/^# ?/, ""); print; next }
      { exit }
    ' "$0"
    exit 0
    ;;
  *) echo "fm-captain-blocker-reminders: unknown argument: $1" >&2; exit 2 ;;
esac

fail() {
  printf 'fm-captain-blocker-reminders: %s\n' "$*" >&2
  exit 1
}

validate_positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) fail "$1 must be a positive integer" ;;
  esac
}

validate_hour() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*) fail "$1 must be an integer hour from 0 through 23" ;;
  esac
  [ "$2" -ge 0 ] && [ "$2" -le 23 ] || fail "$1 must be an integer hour from 0 through 23"
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

now_epoch() {
  if [ -n "${FM_CAPTAIN_REMINDER_NOW_EPOCH:-}" ]; then
    case "$FM_CAPTAIN_REMINDER_NOW_EPOCH" in
      *[!0-9]*) fail "FM_CAPTAIN_REMINDER_NOW_EPOCH must be an epoch integer" ;;
    esac
    printf '%s\n' "$FM_CAPTAIN_REMINDER_NOW_EPOCH"
  else
    date +%s
  fi
}

local_hour() {  # <epoch>
  local epoch=$1 tz=${FM_CAPTAIN_REMINDER_TZ:-} hour
  if [ -n "$tz" ]; then
    hour=$(TZ="$tz" date -r "$epoch" +%H 2>/dev/null \
      || TZ="$tz" date -d "@$epoch" +%H 2>/dev/null) || return 1
  else
    hour=$(date -r "$epoch" +%H 2>/dev/null \
      || date -d "@$epoch" +%H 2>/dev/null) || return 1
  fi
  case "$hour" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((10#$hour))"
}

within_active_window() {  # <hour> <start-hour> <end-hour>
  local hour=$1 start=$2 end=$3
  if [ "$start" -le "$end" ]; then
    [ "$hour" -ge "$start" ] && [ "$hour" -le "$end" ]
  else
    [ "$hour" -ge "$start" ] || [ "$hour" -le "$end" ]
  fi
}

validate_reminder_state_dir() {
  local f base
  [ -d "$REMINDER_DIR" ] || return 0
  [ ! -L "$REMINDER_DIR" ] || fail "unsafe reminder state dir: $REMINDER_DIR"
  for f in "$REMINDER_DIR"/*; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || fail "unsafe reminder state entry: $f"
    base=$(basename "$f")
    case "$base" in
      current) ;;
      sent-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
      *) fail "malformed reminder state entry: $f" ;;
    esac
  done
}

snapshot_json() {
  "$SNAPSHOT_BIN" --json
}

blocker_lines() {
  snapshot_json | jq -r '
    def trunc($n):
      tostring | gsub("\\s+"; " ")
      | if length > $n then .[:$n] + "..." else . end;
    def line($type; $owner; $id; $key; $summary):
      [$type, $owner, $id, $key, ($summary | trunc(220))] | @tsv;
    (
      [ .backlog.records[]?
        | select(.structured and .captain_actionable == true)
        | line("captain-hold"; "(main)"; .id; .id;
            ((.title // .id) + ": " + (.hold_reason // "captain decision pending"))) ]
      + [ .tasks[]? as $t
          | ($t.hints.open_decisions // [])[]?
          | select(.verb == "needs-decision" or .verb == "blocked")
          | line(("status-" + .verb); "(main)"; $t.id; (.key // "default");
              (.summary // (if .verb == "blocked" then "blocker needs action" else "decision needed" end))) ]
      + [ .tasks[]?
          | select(.kind != "secondmate")
          | select(.current_state.state == "done")
          | select(.pr.url != null)
          | select(((.current_state.detail // "") | test("checks green|PR ready"; "i")))
          | line("release-approval"; "(main)"; .id; "pr";
              ("Release approval needed for " + .id + " (" + .pr.url + ")")) ]
      + [ (.secondmate_current.records // [])[] as $m
          | ($m.decisions_open // [])[]?
          | select(.verb == "captain-hold" or .verb == "needs-decision" or .verb == "blocked")
          | line(("secondmate-" + .verb); $m.id; .id; (.key // .id);
              ((.summary // .id) + ": " + (.reason // "captain action pending"))) ]
    )
    | unique
    | sort
    | .[]
  '
}

cadence=${FM_CAPTAIN_REMINDER_SECS:-3600}
start_hour=${FM_CAPTAIN_REMINDER_START_HOUR:-9}
end_hour=${FM_CAPTAIN_REMINDER_END_HOUR:-23}
validate_positive_int FM_CAPTAIN_REMINDER_SECS "$cadence"
validate_hour FM_CAPTAIN_REMINDER_START_HOUR "$start_hour"
validate_hour FM_CAPTAIN_REMINDER_END_HOUR "$end_hour"
command -v jq >/dev/null 2>&1 || fail "jq not found"

mkdir -p "$REMINDER_DIR" || fail "could not create reminder state dir"
validate_reminder_state_dir

now=$(now_epoch)
hour=$(local_hour "$now") || fail "could not resolve local reminder hour"
active=0
within_active_window "$hour" "$start_hour" "$end_hour" && active=1

current_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-captain-reminders.XXXXXX") || fail "mktemp failed"
blockers_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-captain-blockers.XXXXXX") || fail "mktemp failed"
trap 'rm -f "$current_tmp" "$blockers_tmp"' EXIT

blocker_lines > "$blockers_tmp" || fail "could not discover captain-action blockers"

due=''
seen_hashes=''
while IFS=$(printf '\t') read -r type owner id key summary; do
  [ -n "$type" ] || continue
  record="${type}"$'\t'"${owner}"$'\t'"${id}"$'\t'"${key}"$'\t'"${summary}"
  hash=$(sha256_text "$record")
  printf '%s\t%s\n' "$hash" "$record" >> "$current_tmp" || fail "could not write current reminder inventory"
  seen_hashes="${seen_hashes}${hash}"$'\n'
  if [ "$MODE" = list ]; then
    printf '%s\n' "$summary"
    continue
  fi
  [ "$active" -eq 1 ] || continue
  marker="$REMINDER_DIR/sent-$hash"
  last=$(cat "$marker" 2>/dev/null || true)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ ! -e "$marker" ] || [ $((now - last)) -ge "$cadence" ]; then
    due="${due}Captain action still needed: ${summary}"$'\n'
    printf '%s\n' "$now" > "$marker" || fail "could not update reminder marker"
  fi
done < "$blockers_tmp"

if [ "$MODE" = emit ]; then
  for marker in "$REMINDER_DIR"/sent-*; do
    [ -e "$marker" ] || continue
    hash=${marker##*/sent-}
    case "$seen_hashes" in
      *$'\n'"$hash"$'\n'*|"$hash"$'\n'*|*$'\n'"$hash") ;;
      *) rm -f "$marker" || fail "could not remove resolved reminder marker: $marker" ;;
    esac
  done
  mv "$current_tmp" "$REMINDER_DIR/current" || fail "could not publish current reminder inventory"
  current_tmp=
  [ -n "$due" ] && printf '%s' "$due"
fi
exit 0
