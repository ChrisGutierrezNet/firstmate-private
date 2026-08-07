#!/usr/bin/env bash
# Focused tests for recurring captain-action blocker reminders.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

REMIND="$ROOT/bin/fm-captain-blocker-reminders.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-reminders)

epoch_utc() {  # <YYYY-MM-DD HH:MM:SS>
  date -u -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null \
    || date -u -d "$1 UTC" +%s
}

write_snapshot_bin() {  # <home>
  local home=$1
  cat > "$home/fakebin/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --json ] || exit 2
cat "${FM_FAKE_SNAPSHOT_FILE:?FM_FAKE_SNAPSHOT_FILE unset}"
SH
  chmod +x "$home/fakebin/fm-fleet-snapshot.sh"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin"
  write_snapshot_bin "$home"
  printf '%s\n' "$home"
}

write_empty_snapshot() {  # <file>
  cat > "$1" <<'JSON'
{"schema":"fm-fleet-snapshot.v1","backlog":{"records":[]},"tasks":[],"secondmate_current":{"records":[]}}
JSON
}

write_hold_snapshot() {  # <file> <id> <title> <reason>
  local file=$1 id=$2 title=$3 reason=$4
  jq -n --arg id "$id" --arg title "$title" --arg reason "$reason" '{
    schema:"fm-fleet-snapshot.v1",
    backlog:{records:[{structured:true,captain_actionable:true,id:$id,title:$title,hold_reason:$reason}]},
    tasks:[],
    secondmate_current:{records:[]}
  }' > "$file"
}

write_status_snapshot() {  # <file>
  cat > "$1" <<'JSON'
{
  "schema":"fm-fleet-snapshot.v1",
  "backlog":{"records":[]},
  "tasks":[{
    "id":"access-task",
    "kind":"ship",
    "current_state":{"state":"blocked","detail":"blocked on credential"},
    "pr":{"url":null},
    "paths":{"status_log":{"last_event":{"raw":"blocked [key=credential]: need production credential"}}},
    "hints":{"open_decisions":[{"key":"credential","verb":"blocked","summary":"Need production credential"}]}
  }],
  "secondmate_current":{"records":[]}
}
JSON
}

write_release_snapshot() {  # <file>
  cat > "$1" <<'JSON'
{
  "schema":"fm-fleet-snapshot.v1",
  "backlog":{"records":[]},
  "tasks":[{
    "id":"release-task",
    "kind":"ship",
    "current_state":{"state":"done","detail":"checks green: PR ready for review"},
    "pr":{"url":"https://example.test/repo/pull/7"},
    "paths":{"status_log":{"last_event":{"raw":"done: PR https://example.test/repo/pull/7 checks green"}}},
    "hints":{"open_decisions":[]}
  }],
  "secondmate_current":{"records":[]}
}
JSON
}

write_benign_snapshot() {  # <file>
  cat > "$1" <<'JSON'
{
  "schema":"fm-fleet-snapshot.v1",
  "backlog":{"records":[
    {"structured":true,"captain_actionable":false,"id":"queued-wait","title":"Serialized follow-up","blocked_by_ids":["predecessor"],"unresolved_blocker_ids":["predecessor"],"state":"queued"},
    {"structured":true,"captain_actionable":false,"id":"deferred-item","title":"DEFERRED optional cleanup","body_excerpt":"DEFERRED until next quarter","state":"queued"}
  ]},
  "tasks":[{
    "id":"paused-task",
    "kind":"ship",
    "current_state":{"state":"paused","detail":"awaiting vendor release"},
    "pr":{"url":null},
    "paths":{"status_log":{"last_event":{"raw":"paused: awaiting vendor release"}}},
    "hints":{"open_decisions":[]}
  },{
    "id":"stale-done-task",
    "kind":"scout",
    "current_state":{"state":"done","detail":"report complete"},
    "pr":{"url":null},
    "paths":{"status_log":{"last_event":{"raw":"needs-decision: stale historical line"}}},
    "hints":{"open_decisions":[]}
  },{
    "id":"merged-task",
    "kind":"ship",
    "current_state":{"state":"done","detail":"run passed: PR merged/closed"},
    "pr":{"url":"https://example.test/repo/pull/9"},
    "paths":{"status_log":{"last_event":{"raw":"done: PR https://example.test/repo/pull/9 checks green"}}},
    "hints":{"open_decisions":[]}
  }],
  "secondmate_current":{"records":[]}
}
JSON
}

run_remind() {  # <home> <snapshot-file> <epoch> [extra env...]
  local home=$1 snapshot=$2 epoch=$3
  shift 3
  env \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CAPTAIN_REMINDER_SNAPSHOT_BIN="$home/fakebin/fm-fleet-snapshot.sh" \
    FM_FAKE_SNAPSHOT_FILE="$snapshot" \
    FM_CAPTAIN_REMINDER_TZ=UTC \
    FM_CAPTAIN_REMINDER_NOW_EPOCH="$epoch" \
    "$@" "$REMIND"
}

marker_count() {  # <home>
  find "$1/state/.captain-blocker-reminders" -type f -name 'sent-*' 2>/dev/null | wc -l | tr -d ' '
}

test_initial_eligibility_cadence_and_restart_durability() {
  local home snap t9 out
  home=$(make_home initial)
  snap="$home/snapshot.json"
  t9=$(epoch_utc '2026-01-01 09:00:00')
  write_hold_snapshot "$snap" approve-release "Approve release" "captain release approval pending"

  out=$(run_remind "$home" "$snap" "$t9") || fail "initial reminder run failed"
  assert_contains "$out" "Captain action still needed: Approve release: captain release approval pending" \
    "initial eligible hold did not emit"
  out=$(run_remind "$home" "$snap" "$((t9 + 120))") || fail "restart suppression run failed"
  [ -z "$out" ] || fail "same blocker emitted before cadence elapsed after process restart: $out"
  out=$(run_remind "$home" "$snap" "$((t9 + 3600))") || fail "recurrence run failed"
  assert_contains "$out" "Captain action still needed: Approve release" \
    "same blocker did not recur after the default hourly cadence"
  pass "initial eligibility, cadence suppression, hourly recurrence, and restart durability"
}

test_status_blocker_and_release_approval_are_eligible() {
  local home status_snap release_snap t10 out
  home=$(make_home eligible-types)
  status_snap="$home/status.json"
  release_snap="$home/release.json"
  t10=$(epoch_utc '2026-01-01 10:00:00')
  write_status_snapshot "$status_snap"
  out=$(run_remind "$home" "$status_snap" "$t10") || fail "status blocker run failed"
  assert_contains "$out" "Need production credential" "blocked status decision did not emit"
  write_release_snapshot "$release_snap"
  out=$(run_remind "$home" "$release_snap" "$t10") || fail "release approval run failed"
  assert_contains "$out" "Release approval needed for release-task" "green PR release approval did not emit"
  pass "status blockers and green PR release approvals are eligible"
}

test_resolution_and_material_change_cleanup() {
  local home snap t10 out
  home=$(make_home resolution)
  snap="$home/snapshot.json"
  t10=$(epoch_utc '2026-01-01 10:00:00')
  write_hold_snapshot "$snap" decide-route "Choose route" "captain route choice pending"
  run_remind "$home" "$snap" "$t10" >/dev/null || fail "setup reminder failed"
  [ "$(marker_count "$home")" = 1 ] || fail "setup marker missing"

  write_empty_snapshot "$snap"
  out=$(run_remind "$home" "$snap" "$((t10 + 60))") || fail "resolution cleanup run failed"
  [ -z "$out" ] || fail "resolved blocker emitted: $out"
  [ "$(marker_count "$home")" = 0 ] || fail "resolved blocker marker was not cleaned up"

  write_hold_snapshot "$snap" decide-route "Choose route" "captain route choice pending"
  out=$(run_remind "$home" "$snap" "$((t10 + 120))") || fail "reopened reminder run failed"
  assert_contains "$out" "Choose route" "reopened blocker did not reset cadence"
  write_hold_snapshot "$snap" decide-route "Choose route" "captain route choice changed"
  out=$(run_remind "$home" "$snap" "$((t10 + 180))") || fail "material-change run failed"
  assert_contains "$out" "captain route choice changed" "materially changed blocker did not reset cadence"
  pass "resolution cleanup and material-change cadence reset"
}

test_benign_waits_and_stale_history_are_excluded() {
  local home snap t10 out
  home=$(make_home benign)
  snap="$home/benign.json"
  t10=$(epoch_utc '2026-01-01 10:00:00')
  write_benign_snapshot "$snap"
  out=$(run_remind "$home" "$snap" "$t10") || fail "benign exclusion run failed"
  [ -z "$out" ] || fail "benign waits or stale history emitted reminders: $out"
  pass "benign queue waits, declared pauses, deferred work, and stale history are excluded"
}

test_malformed_state_fails_closed() {
  local home snap t10 out rc
  home=$(make_home malformed)
  snap="$home/snapshot.json"
  t10=$(epoch_utc '2026-01-01 10:00:00')
  write_hold_snapshot "$snap" approve-release "Approve release" "captain release approval pending"
  mkdir -p "$home/state/.captain-blocker-reminders"
  printf 'bad\n' > "$home/state/.captain-blocker-reminders/not-a-marker"
  set +e
  out=$(run_remind "$home" "$snap" "$t10" 2>"$home/err")
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "malformed state did not fail"
  [ -z "$out" ] || fail "malformed state emitted output: $out"
  assert_contains "$(cat "$home/err")" "malformed reminder state entry" \
    "malformed state failure did not explain the unsafe entry"
  pass "malformed private reminder state fails closed without output"
}

test_home_isolation() {
  local home_a home_b snap_a snap_b t10 out
  home_a=$(make_home home-a)
  home_b=$(make_home home-b)
  snap_a="$home_a/snapshot.json"
  snap_b="$home_b/snapshot.json"
  t10=$(epoch_utc '2026-01-01 10:00:00')
  write_hold_snapshot "$snap_a" decide "Choose deployment" "captain deployment approval pending"
  cp "$snap_a" "$snap_b"
  run_remind "$home_a" "$snap_a" "$t10" >/dev/null || fail "home A initial run failed"
  out=$(run_remind "$home_b" "$snap_b" "$((t10 + 60))") || fail "home B initial run failed"
  assert_contains "$out" "Choose deployment" "home B reused home A dedupe state"
  out=$(run_remind "$home_a" "$snap_a" "$((t10 + 60))") || fail "home A suppression run failed"
  [ -z "$out" ] || fail "home A did not retain its own suppression state: $out"
  pass "dedupe state is isolated per FM_HOME"
}

test_active_window_boundaries_and_overnight_suppression() {
  local home snap t0859 t0900 t2300 t2359 out
  home=$(make_home active-window)
  snap="$home/snapshot.json"
  write_hold_snapshot "$snap" approve-window "Approve deployment" "captain approval pending"
  t0859=$(epoch_utc '2026-01-01 08:59:00')
  t0900=$(epoch_utc '2026-01-01 09:00:00')
  t2300=$(epoch_utc '2026-01-01 23:00:00')
  t2359=$(epoch_utc '2026-01-01 23:59:00')

  out=$(run_remind "$home" "$snap" "$t0859") || fail "08:59 run failed"
  [ -z "$out" ] || fail "overnight 08:59 emitted: $out"
  out=$(run_remind "$home" "$snap" "$t0900") || fail "09:00 run failed"
  assert_contains "$out" "Approve deployment" "09:00 boundary did not emit"
  out=$(run_remind "$home" "$snap" "$t2300" FM_CAPTAIN_REMINDER_SECS=1) || fail "23:00 run failed"
  assert_contains "$out" "Approve deployment" "23:00 boundary did not emit"
  out=$(run_remind "$home" "$snap" "$t2359" FM_CAPTAIN_REMINDER_SECS=1) || fail "23:xx run failed"
  assert_contains "$out" "Approve deployment" "23:xx hour should remain inside the inclusive 23:00 window"
  pass "active window includes 09:00 and the 23:00 hour while suppressing overnight"
}

test_window_configuration_can_suppress_default_hours() {
  local home snap t10 out
  home=$(make_home configured-window)
  snap="$home/snapshot.json"
  t10=$(epoch_utc '2026-01-01 10:00:00')
  write_hold_snapshot "$snap" approve-custom "Approve custom window" "captain approval pending"
  out=$(run_remind "$home" "$snap" "$t10" FM_CAPTAIN_REMINDER_START_HOUR=11 FM_CAPTAIN_REMINDER_END_HOUR=12) \
    || fail "configured-window run failed"
  [ -z "$out" ] || fail "configured active window did not suppress 10:00: $out"
  pass "active reminder window is configurable"
}

test_watcher_integration_enqueues_reminder() {
  local dir state fakebin snap out drain_out t10 pid
  dir=$(make_case watcher-reminder)
  state="$dir/state"
  fakebin="$dir/fakebin"
  snap="$dir/snapshot.json"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  t10=$(epoch_utc '2026-01-01 10:00:00')
  write_snapshot_bin "$dir"
  write_hold_snapshot "$snap" approve-watch "Approve watched release" "captain release approval pending"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_CAPTAIN_REMINDER_SNAPSHOT_BIN="$dir/fakebin/fm-fleet-snapshot.sh" \
    FM_FAKE_SNAPSHOT_FILE="$snap" \
    FM_CAPTAIN_REMINDER_TZ=UTC \
    FM_CAPTAIN_REMINDER_NOW_EPOCH="$t10" \
    FM_CAPTAIN_REMINDER_SCAN_INTERVAL=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for reminder"
  grep -F "reminder: Captain action still needed: Approve watched release" "$out" >/dev/null \
    || fail "watcher did not print reminder wake: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$drain_out" 2>/dev/null \
    || fail "drain after reminder wake failed"
  grep "$(printf '\treminder\tcaptain-blockers\t')" "$drain_out" >/dev/null \
    || fail "reminder wake was not queued: $(cat "$drain_out")"
  pass "watcher integrates recurring reminders through the durable wake queue"
}

test_initial_eligibility_cadence_and_restart_durability
test_status_blocker_and_release_approval_are_eligible
test_resolution_and_material_change_cleanup
test_benign_waits_and_stale_history_are_excluded
test_malformed_state_fails_closed
test_home_isolation
test_active_window_boundaries_and_overnight_suppression
test_window_configuration_can_suppress_default_hours
test_watcher_integration_enqueues_reminder
