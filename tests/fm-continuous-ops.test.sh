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

run_refresh() {  # <case-dir> <ready-ids> [reason] [ready-mode] [local-cert-ids] [hosted-cert-ids]
  local dir=$1 ids=$2 reason=${3:-test} mode=${4:-ready} local_ids=${5:-} hosted_ids=${6:-}
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
    FM_CONTINUOUS_OPS_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c '. "$1"; fm_continuous_ops_refresh "$2"' _ "$HELPER" "$reason"
}

run_drain() {  # <case-dir> <ready-ids>
  local dir=$1 ids=$2 home state fakebin
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  fakebin=$(fakebin_of "$dir")
  PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_READY_IDS="$ids" \
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

wake_count() {  # <case-dir>
  local queue
  queue="$(state_of "$1")/.wake-queue"
  if [ -f "$queue" ]; then
    grep -c "$(printf '\tcheck\tcontinuous-ops-ready\t')" "$queue" 2>/dev/null || true
  else
    printf '0\n'
  fi
}

write_meta() {  # <case-dir> <id> <key=value>...
  local dir=$1 id=$2 state
  shift 2
  state=$(state_of "$dir")
  fm_write_meta "$state/$id.meta" "$@"
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

test_hosted_waits_do_not_consume_local_cert_capacity() {
  local dir state i
  dir=$(make_case hosted-waits)
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
  write_meta "$dir" hosted-a \
    "window=fm:hosted-a" "worktree=$dir/wt-hosted-a" "project=$dir/project" \
    "harness=opencode" "kind=ship" "mode=no-mistakes"
  write_meta "$dir" hosted-b \
    "window=fm:hosted-b" "worktree=$dir/wt-hosted-b" "project=$dir/project" \
    "harness=grok" "kind=ship" "mode=no-mistakes"
  run_refresh "$dir" "ready-a" hosted ready "" "hosted-a hosted-b" >/dev/null
  assert_present "$state/.continuous-ops-ready" "hosted-check waits incorrectly consumed local certification capacity"
  assert_grep "local_cert_active=0" "$state/.continuous-ops-ready" "hosted waits were counted as local certification streams"
  pass "external hosted-check waits do not consume local certification capacity"
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
  assert_grep "ordinary_workers=5" "$state/.continuous-ops-ready" "stale reused-worktree binding counted as a live worker"
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
  assert_grep "ordinary_workers=4" "$state/.continuous-ops-ready" "axis-varied metadata was not counted through the backend-neutral path"
  pass "continuous ops behavior is harness- and runtime-backend-agnostic"
}

test_success_creates_one_notification_and_supervision_need
test_empty_heartbeat_discovers_ready_work
test_non_ready_task_classes_do_not_trigger
test_repeated_checks_dedupe_and_new_ready_transition_survives
test_capacity_and_ready_changes_clear_or_reopen_marker
test_hosted_waits_do_not_consume_local_cert_capacity
test_reused_worktree_stale_binding_does_not_consume_capacity
test_harness_and_runtime_backend_axes_are_metadata_neutral
