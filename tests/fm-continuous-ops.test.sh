#!/usr/bin/env bash
# Behavior tests for Continuous Operations v1.
#
# The tests drive bin/fm-continuous-ops-lib.sh through its sourced public
# functions, with a fake tasks-axi boundary. That keeps tasks-axi ready as the
# authoritative ready-work source and proves Firstmate does not parse blocked,
# held, date-gated, or captain-decision records itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-continuous-ops)
HELPER="$ROOT/bin/fm-continuous-ops-lib.sh"
SUP="$ROOT/bin/fm-supervision-lib.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

make_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf '# backlog fixture\n' > "$dir/home/data/backlog.md"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version|-v|-V)
    printf '%s\n' '0.2.4'
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [--archive-body]'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <dest> [<id>...]'
      exit 0
    fi
    ;;
  ready)
    case "$*" in *'--file '*) : ;; *) printf '%s\n' 'missing --file' >&2; exit 9 ;; esac
    ids=${FM_FAKE_READY_IDS:-}
    count=0
    for _id in $ids; do count=$((count + 1)); done
    printf 'count: %s\n' "$count"
    printf 'ready[%s]{id,state,kind,repo,title}:\n' "$count"
    for id in $ids; do
      printf '  %s,queued,ship,fixture,%s title\n' "$id" "$id"
    done
    case "${FM_FAKE_READY_MODE:-ready}" in
      blocked) printf 'note: blocked queued work is intentionally absent from ready\n' ;;
      held) printf 'note: held work is intentionally absent from ready\n' ;;
      date-gated) printf 'note: date-gated work is intentionally absent from ready\n' ;;
      captain-decision) printf 'note: captain-decision work is intentionally absent from ready\n' ;;
    esac
    printf 'ready_public_followups: 0 delivery-ready obligations\n'
    printf 'help[1]:\n'
    printf '%s\n' '  - Run `tasks-axi start <id>` to dispatch one of these'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
id=${1:-}
case " ${FM_FAKE_DONE_IDS:-} " in
  *" $id "*)
    printf '%s\n' 'state: done source: run-step run passed: PR merged/closed'
    exit 0
    ;;
esac
case " ${FM_FAKE_BLOCKED_IDS:-} " in
  *" $id "*)
    printf '%s\n' 'state: blocked source: status-log blocked on captain action'
    exit 0
    ;;
esac
case " ${FM_FAKE_MISSING_IDS:-} " in
  *" $id "*)
    printf '%s\n' 'state: unknown source: none backend target gone: default:w9:p1'
    exit 0
    ;;
esac
case " ${FM_FAKE_UNKNOWN_LIVE_IDS:-} " in
  *" $id "*)
    printf '%s\n' 'state: unknown source: pane harness state unavailable (unknown codex-unverified)'
    exit 0
    ;;
esac
case " ${FM_FAKE_HOSTED_CERT_IDS:-} " in
  *" $id "*)
    printf '%s\n' 'state: working source: run-step waiting for hosted CI checks to register'
    exit 0
    ;;
esac
case " ${FM_FAKE_LOCAL_CERT_IDS:-} " in
  *" $id "*)
    printf '%s\n' 'state: working source: run-step validating (running)'
    exit 0
    ;;
esac
printf '%s\n' 'state: working source: pane busy'
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$dir"
}

home_of() { printf '%s/home\n' "$1"; }
state_of() { printf '%s/home/state\n' "$1"; }
fakebin_of() { printf '%s/fakebin\n' "$1"; }

run_refresh() {  # <case-dir> <ready-ids> [reason] [ready-mode] [local-cert-ids] [hosted-cert-ids] [unknown-live-ids] [done-ids] [blocked-ids] [missing-ids]
  local dir=$1 ids=$2 reason=${3:-test} mode=${4:-ready} local_ids=${5:-} hosted_ids=${6:-}
  local unknown_live_ids=${7:-} done_ids=${8:-} blocked_ids=${9:-} missing_ids=${10:-}
  local home state fakebin
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  fakebin=$(fakebin_of "$dir")
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_READY_IDS="$ids" \
    FM_FAKE_READY_MODE="$mode" \
    FM_FAKE_LOCAL_CERT_IDS="$local_ids" \
    FM_FAKE_HOSTED_CERT_IDS="$hosted_ids" \
    FM_FAKE_UNKNOWN_LIVE_IDS="$unknown_live_ids" \
    FM_FAKE_DONE_IDS="$done_ids" \
    FM_FAKE_BLOCKED_IDS="$blocked_ids" \
    FM_FAKE_MISSING_IDS="$missing_ids" \
    FM_CONTINUOUS_OPS_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c '. "$1"; fm_continuous_ops_refresh "$2"' _ "$HELPER" "$reason"
}

run_drain() {  # <case-dir> <ready-ids> [local-cert-ids] [hosted-cert-ids] [unknown-live-ids] [done-ids] [blocked-ids] [missing-ids]
  local dir=$1 ids=$2 local_ids=${3:-} hosted_ids=${4:-}
  local unknown_live_ids=${5:-} done_ids=${6:-} blocked_ids=${7:-} missing_ids=${8:-}
  local home state fakebin
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  fakebin=$(fakebin_of "$dir")
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_READY_IDS="$ids" \
    FM_FAKE_LOCAL_CERT_IDS="$local_ids" \
    FM_FAKE_HOSTED_CERT_IDS="$hosted_ids" \
    FM_FAKE_UNKNOWN_LIVE_IDS="$unknown_live_ids" \
    FM_FAKE_DONE_IDS="$done_ids" \
    FM_FAKE_BLOCKED_IDS="$blocked_ids" \
    FM_FAKE_MISSING_IDS="$missing_ids" \
    FM_CONTINUOUS_OPS_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_SUPERVISION_MODEL=autoarm \
    "$DRAIN" 2>&1
}

supervision_line() {  # <case-dir>
  local dir=$1 home state
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1"; fm_supervision_status "$2" 300; printf "%s %s %s\n" "$FM_SUP_NEEDED" "$FM_SUP_CONTINUOUS_OPS" "$FM_SUP_IN_FLIGHT"' \
    _ "$SUP" "$state"
}

print_section() {  # <case-dir>
  local dir=$1 home state fakebin
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  fakebin=$(fakebin_of "$dir")
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '. "$1"; fm_continuous_ops_print_section' _ "$HELPER"
}

wake_count() {  # <case-dir>
  local queue
  queue="$(state_of "$1")/.wake-queue"
  if [ -f "$queue" ]; then
    grep -c "$(printf '\tcheck\tcontinuous-ops-ready\t')" "$queue" 2>/dev/null || true
  else
    printf '0\n'
  fi
}

assert_wake_count() {  # <case-dir> <expected> <message>
  local got
  got=$(wake_count "$1")
  [ "$got" -eq "$2" ] || fail "$3: got $got"
}

write_meta() {  # <case-dir> <id> <key=value>...
  local dir=$1 id=$2 state
  shift 2
  state=$(state_of "$dir")
  fm_write_meta "$state/$id.meta" "$@"
}

write_worker_meta() {  # <case-dir> <id> [mode] [kind]
  local dir=$1 id=$2 mode=${3:-direct-PR} kind=${4:-ship}
  write_meta "$dir" "$id" \
    "window=fm:$id" \
    "worktree=$dir/wt-$id" \
    "project=$dir/project" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$mode"
}

make_worktree_branch() {  # <path> <branch>
  local path=$1 branch=$2
  fm_git_init_commit "$path"
  git -C "$path" checkout -q -b "$branch"
}

test_success_creates_one_notification_and_supervision_need() {
  local dir state out sup
  dir=$(make_case success)
  state=$(state_of "$dir")
  out=$(run_refresh "$dir" "ready-a ready-b" teardown:done)
  assert_contains "$out" "queued one dispatch notification" "refresh did not report the queued notification"
  assert_present "$state/.continuous-ops-ready" "ready marker was not written"
  [ "$(wake_count "$dir")" -eq 1 ] || fail "expected exactly one continuous wake, got $(wake_count "$dir")"
  assert_grep "ready_count=2" "$state/.continuous-ops-ready" "marker did not record ready count"
  sup=$(supervision_line "$dir")
  [ "$sup" = "true 1 0" ] || fail "supervision predicate did not stay required for marker-only work: $sup"
  out=$(run_drain "$dir" "ready-a ready-b")
  assert_contains "$out" "continuous-ops-ready" "wake drain did not print the queued continuous-op wake"
  assert_contains "$out" "CONTINUOUS OPS" "wake drain did not print the marker section"
  pass "continuous ops writes one durable notification and keeps marker-only supervision required"
}

test_empty_heartbeat_discovers_ready_work() {
  local dir state out
  dir=$(make_case heartbeat)
  state=$(state_of "$dir")
  out=$(run_drain "$dir" "ready-heartbeat")
  assert_present "$state/.continuous-ops-ready" "empty wake drain did not refresh ready work"
  [ "$(wake_count "$dir")" -eq 1 ] || fail "empty wake drain queued $(wake_count "$dir") continuous wakes"
  assert_contains "$out" "CONTINUOUS OPS" "empty wake drain did not print the refreshed marker"
  assert_grep "ready_items=ready-heartbeat" "$state/.continuous-ops-ready" "empty wake drain marker lost ready item"
  out=$(run_drain "$dir" "ready-heartbeat")
  [ "$(wake_count "$dir")" -eq 0 ] || fail "same heartbeat transition requeued after drain"
  assert_contains "$out" "continuous-ops-ready" "second drain did not consume the heartbeat wake"
  pass "empty heartbeat discovers ready work and dedupes the durable wake"
}

test_non_ready_task_classes_do_not_trigger() {
  local mode dir state
  for mode in blocked held date-gated captain-decision; do
    dir=$(make_case "not-ready-$mode")
    state=$(state_of "$dir")
    run_refresh "$dir" "" "filter:$mode" "$mode" >/dev/null
    assert_absent "$state/.continuous-ops-ready" "$mode ready output unexpectedly wrote marker"
    [ "$(wake_count "$dir")" -eq 0 ] || fail "$mode ready output unexpectedly queued a wake"
  done
  pass "blocked, held, date-gated, and captain-decision work do not trigger continuous pulling"
}

test_repeated_checks_dedupe_and_new_ready_transition_survives() {
  local dir state out
  dir=$(make_case dedupe)
  state=$(state_of "$dir")
  run_refresh "$dir" "ready-a" first >/dev/null
  run_refresh "$dir" "ready-a" repeat >/dev/null
  [ "$(wake_count "$dir")" -eq 1 ] || fail "same ready signature queued duplicate wakes"
  out=$(run_drain "$dir" "ready-a")
  [ "$(printf '%s\n' "$out" | grep -c "$(printf '\tcheck\tcontinuous-ops-ready\t')")" -eq 1 ] \
    || fail "drain did not dedupe continuous wakes"$'\n'"$out"
  [ "$(wake_count "$dir")" -eq 0 ] || fail "drain left the consumed continuous wake queued"
  run_refresh "$dir" "ready-a" same-after-drain >/dev/null
  [ "$(wake_count "$dir")" -eq 0 ] || fail "same marker signature requeued after drain"
  run_refresh "$dir" "ready-b" new-ready >/dev/null
  [ "$(wake_count "$dir")" -eq 1 ] || fail "new ready transition did not queue a fresh wake"
  assert_grep "ready_items=ready-b" "$state/.continuous-ops-ready" "new ready transition did not supersede marker"
  pass "continuous ops dedupes repeats without losing a new ready transition"
}

test_capacity_and_ready_changes_clear_or_reopen_marker() {
  local dir state i
  dir=$(make_case capacity)
  state=$(state_of "$dir")
  for i in 1 2 3 4; do
    write_meta "$dir" "worker-$i" \
      "window=fm:worker-$i" \
      "worktree=$dir/wt-$i" \
      "project=$dir/project" \
      "harness=codex" \
      "kind=ship" \
      "mode=direct-PR"
  done
  write_meta "$dir" cert-a \
    "window=fm:cert-a" "worktree=$dir/wt-cert-a" "project=$dir/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  write_meta "$dir" cert-b \
    "window=fm:cert-b" "worktree=$dir/wt-cert-b" "project=$dir/project" \
    "harness=pi" "kind=ship" "mode=no-mistakes"
  run_refresh "$dir" "ready-a" full ready "cert-a cert-b" >/dev/null
  assert_absent "$state/.continuous-ops-ready" "full worker and local-cert capacity should clear marker"
  rm -f "$state/worker-4.meta"
  run_refresh "$dir" "ready-a" worker-open ready "cert-a cert-b" >/dev/null
  assert_present "$state/.continuous-ops-ready" "idle worker capacity should reopen marker"
  run_refresh "$dir" "" queue-empty ready "cert-a cert-b" >/dev/null
  assert_absent "$state/.continuous-ops-ready" "empty ready queue should clear marker"
  run_refresh "$dir" "ready-c" new-after-empty ready "cert-a cert-b" >/dev/null
  assert_present "$state/.continuous-ops-ready" "new ready work after empty queue should reopen marker"
  assert_grep "ready_items=ready-c" "$state/.continuous-ops-ready" "new ready work after empty queue was not recorded"
  pass "capacity and ready changes clear or reopen the idle-ready condition"
}

test_reused_worktree_stale_binding_does_not_consume_capacity() {
  local dir state reused sup
  dir=$(make_case reused-worktree)
  state=$(state_of "$dir")
  reused="$dir/reused-copy"
  make_worktree_branch "$reused" fm/current-owner
  write_meta "$dir" cert-a \
    "window=fm:cert-a" "worktree=$dir/wt-cert-a" "project=$dir/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  write_meta "$dir" cert-b \
    "window=fm:cert-b" "worktree=$dir/wt-cert-b" "project=$dir/project" \
    "harness=pi" "kind=ship" "mode=no-mistakes"
  write_meta "$dir" worker-a \
    "window=fm:worker-a" "worktree=$dir/wt-worker-a" "project=$dir/project" \
    "harness=codex" "kind=ship" "mode=direct-PR"
  write_meta "$dir" worker-b \
    "window=fm:worker-b" "worktree=$dir/wt-worker-b" "project=$dir/project" \
    "harness=grok" "kind=ship" "mode=direct-PR"
  write_meta "$dir" current-owner \
    "window=fm:current-owner" "worktree=$reused" "project=$dir/project" \
    "harness=opencode" "kind=ship" "mode=direct-PR"
  write_meta "$dir" stale-hold \
    "window=fm:stale-hold" "worktree=$reused" "project=$dir/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes"

  run_refresh "$dir" "ready-a" reused ready "cert-a cert-b stale-hold" >/dev/null
  assert_present "$state/.continuous-ops-ready" "stale reused-worktree binding consumed the last idle worker slot"
  assert_grep "active_workers=5" "$state/.continuous-ops-ready" "stale reused-worktree binding counted as a live worker"
  assert_grep "local_cert_active=2" "$state/.continuous-ops-ready" "stale reused-worktree binding was followed as an active local-cert stream"
  sup=$(supervision_line "$dir")
  [ "$sup" = "true 1 5" ] || fail "supervision counted the stale reused-worktree binding as active work: $sup"
  pass "reused worktree stale metadata does not consume capacity or supervision slots"
}

test_harness_and_runtime_backend_axes_are_metadata_neutral() {
  local dir state
  dir=$(make_case axes)
  state=$(state_of "$dir")
  write_meta "$dir" axis-a \
    "window=herdr:pane-a" "worktree=$dir/wt-a" "project=$dir/project" \
    "harness=codex" "kind=ship" "mode=direct-PR" "backend=herdr"
  write_meta "$dir" axis-b \
    "window=orca-window" "terminal=orca-terminal" "worktree=$dir/wt-b" "project=$dir/project" \
    "harness=claude" "kind=ship" "mode=direct-PR" "backend=orca"
  write_meta "$dir" axis-c \
    "window=zellij:pane-c" "worktree=$dir/wt-c" "project=$dir/project" \
    "harness=pi-signed" "kind=ship" "mode=direct-PR" "backend=zellij"
  write_meta "$dir" axis-d \
    "window=cmux:surface-d" "worktree=$dir/wt-d" "project=$dir/project" \
    "harness=muse" "kind=scout" "backend=cmux"
  run_refresh "$dir" "ready-axis" axes >/dev/null
  assert_present "$state/.continuous-ops-ready" "axis-varied metadata prevented continuous ops marker"
  assert_grep "active_workers=4" "$state/.continuous-ops-ready" "axis-varied metadata was not counted through the backend-neutral path"
  pass "continuous ops behavior is harness- and runtime-backend-agnostic"
}

test_current_failure_counts_only_active_workers() {
  local dir state i active_ids terminal_ids missing_ids blocked_ids out
  dir=$(make_case current-failure)
  state=$(state_of "$dir")
  active_ids="active-a active-b active-c"
  terminal_ids=""
  missing_ids=""
  blocked_ids=""
  for id in $active_ids; do
    write_worker_meta "$dir" "$id"
    printf 'working: moving\n' > "$state/$id.status"
  done
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    id="terminal-$i"
    write_worker_meta "$dir" "$id" no-mistakes
    printf 'done: preserved historical branch already landed\n' > "$state/$id.status"
    terminal_ids="$terminal_ids $id"
  done
  for i in 1 2 3 4; do
    id="missing-$i"
    write_worker_meta "$dir" "$id" no-mistakes
    printf 'working: old pane record with missing endpoint\n' > "$state/$id.status"
    missing_ids="$missing_ids $id"
  done
  for i in 1 2 3 4; do
    id="blocked-$i"
    write_worker_meta "$dir" "$id" no-mistakes
    printf 'blocked: preserved captain blocker\n' > "$state/$id.status"
    blocked_ids="$blocked_ids $id"
  done
  out=$(run_refresh "$dir" "ready-a ready-b" current ready "" "" "" "$terminal_ids" "$blocked_ids" "$missing_ids")
  assert_present "$state/.continuous-ops-ready" "three active workers with many historical records should request dispatch"
  assert_grep "active_workers=3" "$state/.continuous-ops-ready" "historical metadata consumed active worker slots"
  assert_grep "active_worker_limit=6" "$state/.continuous-ops-ready" "worker limit was not recorded"
  assert_contains "$out" "queued one dispatch notification" "active worker capacity did not emit a dispatch notification"
  assert_wake_count "$dir" 1 "expected exactly one dispatch wake"
  out=$(run_drain "$dir" "ready-a ready-b" "" "" "" "$terminal_ids" "$blocked_ids" "$missing_ids")
  assert_contains "$out" "capacity: active workers 3/6, local certification 0/2" \
    "wake drain did not print unambiguous active-worker capacity"
  pass "current failure fixture counts active workers instead of terminal, blocked, or missing metadata"
}

test_full_worker_limit_blocks_dispatch_even_with_free_cert_lane() {
  local dir state i
  dir=$(make_case worker-full)
  state=$(state_of "$dir")
  for i in 1 2 3 4 5 6; do
    write_worker_meta "$dir" "active-$i"
  done
  run_refresh "$dir" "ready-a" full-workers >/dev/null
  assert_absent "$state/.continuous-ops-ready" "six active workers must not request a seventh worker"
  assert_wake_count "$dir" 0 "free certification lane alone queued a dispatch wake"
  pass "full ordinary-worker capacity suppresses dispatch even when certification has room"
}

test_hosted_waits_are_workers_not_local_certification() {
  local dir state i
  dir=$(make_case hosted-workers)
  state=$(state_of "$dir")
  for i in 1 2; do
    write_worker_meta "$dir" "worker-$i"
  done
  write_worker_meta "$dir" hosted-a no-mistakes
  write_worker_meta "$dir" hosted-b no-mistakes
  run_refresh "$dir" "ready-a" hosted ready "" "hosted-a hosted-b" >/dev/null
  assert_present "$state/.continuous-ops-ready" "hosted-check waits should still leave room when active workers are below limit"
  assert_grep "active_workers=4" "$state/.continuous-ops-ready" "hosted waits were not counted as ordinary workers"
  assert_grep "local_cert_active=0" "$state/.continuous-ops-ready" "hosted waits consumed local certification capacity"
  pass "hosted CI waits count as ordinary work but not local certification"
}

test_two_local_validations_consume_local_certification_limit() {
  local dir state
  dir=$(make_case local-cert-full)
  state=$(state_of "$dir")
  write_worker_meta "$dir" cert-a no-mistakes
  write_worker_meta "$dir" cert-b no-mistakes
  run_refresh "$dir" "ready-a" local-cert ready "cert-a cert-b" >/dev/null
  assert_present "$state/.continuous-ops-ready" "worker capacity should still surface ready work"
  assert_grep "active_workers=2" "$state/.continuous-ops-ready" "local validations were not counted as active workers"
  assert_grep "local_cert_active=2" "$state/.continuous-ops-ready" "active local validations did not consume the certification limit"
  pass "current-code-matched local validations consume the local certification limit"
}

test_unknown_live_ownership_is_conservative_but_dead_terminal_is_not() {
  local dir state
  dir=$(make_case unknown-live)
  state=$(state_of "$dir")
  write_worker_meta "$dir" active-a
  write_worker_meta "$dir" unknown-live
  write_worker_meta "$dir" terminal-live
  write_worker_meta "$dir" dead-record
  printf 'working: active\n' > "$state/active-a.status"
  printf 'working: live endpoint with unknown harness state\n' > "$state/unknown-live.status"
  printf 'done: terminal historical record\n' > "$state/terminal-live.status"
  printf 'working: missing endpoint historical record\n' > "$state/dead-record.status"
  run_refresh "$dir" "ready-a" unknown ready "" "" "unknown-live terminal-live" "terminal-live" "" "dead-record" >/dev/null
  assert_present "$state/.continuous-ops-ready" "unknown live ownership plus one active worker should leave capacity"
  assert_grep "active_workers=2" "$state/.continuous-ops-ready" \
    "unknown-live should count, while terminal and dead records should not"
  pass "unknown-but-live ownership is conservative and dead or terminal history is idle"
}

test_reused_stale_binding_does_not_double_count_survivor() {
  local dir state reused
  dir=$(make_case reused-survivor)
  state=$(state_of "$dir")
  reused="$dir/reused-copy"
  make_worktree_branch "$reused" fm/current-owner
  write_worker_meta "$dir" current-owner
  write_meta "$dir" current-owner \
    "window=fm:current-owner" "worktree=$reused" "project=$dir/project" \
    "harness=opencode" "kind=ship" "mode=direct-PR"
  write_meta "$dir" stale-copy \
    "window=fm:stale-copy" "worktree=$reused" "project=$dir/project" \
    "harness=codex" "kind=ship" "mode=direct-PR"
  printf 'working: survivor owns reused copy\n' > "$state/current-owner.status"
  printf 'working: stale copy should not count\n' > "$state/stale-copy.status"
  run_refresh "$dir" "ready-a" reused-survivor >/dev/null
  assert_present "$state/.continuous-ops-ready" "single active reused-copy survivor should leave capacity"
  assert_grep "active_workers=1" "$state/.continuous-ops-ready" "stale reused-copy metadata double counted its survivor"
  pass "reused-copy stale metadata does not double count the surviving owner"
}

test_no_ready_work_emits_no_dispatch_request() {
  local dir state
  dir=$(make_case no-ready)
  state=$(state_of "$dir")
  write_worker_meta "$dir" active-a
  run_refresh "$dir" "" no-ready >/dev/null
  assert_absent "$state/.continuous-ops-ready" "empty Ready set wrote a dispatch marker"
  assert_wake_count "$dir" 0 "empty Ready set queued a dispatch wake"
  pass "no Ready work emits no continuous-ops dispatch request"
}

test_over_limit_legacy_marker_does_not_claim_dispatch_capacity() {
  local dir state out
  dir=$(make_case legacy-overlimit)
  state=$(state_of "$dir")
  cat > "$state/.continuous-ops-ready" <<'EOF'
version=1
ready_count=2
ready_items=ready-a,ready-b
ordinary_workers=7
ordinary_worker_limit=6
local_cert_active=0
local_cert_limit=2
payload=continuous-ops: approved ready work exists (2 item(s): ready-a,ready-b); idle capacity workers=7/6 local-cert=0/2; select and dispatch
EOF
  out=$(print_section "$dir")
  assert_contains "$out" "capacity: active workers 7/6, local certification 0/2" \
    "legacy marker did not render active-worker names"
  assert_contains "$out" "action: no dispatch request; active worker limit is full" \
    "over-limit marker still requested a worker dispatch"
  assert_not_contains "$out" "idle capacity workers=7/6" \
    "over-limit marker printed ambiguous idle-capacity wording"
  pass "over-limit legacy marker does not claim dispatch capacity"
}

test_success_creates_one_notification_and_supervision_need
test_empty_heartbeat_discovers_ready_work
test_non_ready_task_classes_do_not_trigger
test_repeated_checks_dedupe_and_new_ready_transition_survives
test_capacity_and_ready_changes_clear_or_reopen_marker
test_reused_worktree_stale_binding_does_not_consume_capacity
test_harness_and_runtime_backend_axes_are_metadata_neutral
test_current_failure_counts_only_active_workers
test_full_worker_limit_blocks_dispatch_even_with_free_cert_lane
test_hosted_waits_are_workers_not_local_certification
test_two_local_validations_consume_local_certification_limit
test_unknown_live_ownership_is_conservative_but_dead_terminal_is_not
test_reused_stale_binding_does_not_double_count_survivor
test_no_ready_work_emits_no_dispatch_request
test_over_limit_legacy_marker_does_not_claim_dispatch_capacity
