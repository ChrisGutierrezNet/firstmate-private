#!/usr/bin/env bash
# Focused regression tests for the durable final-certification coordinator.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-certification.sh"

new_fixture() {
  FIX=$(fm_test_tmproot fm-certification)
  HOME_DIR="$FIX/home"
  CERT="$FIX/cert"
  SEND_LOG="$FIX/send.log"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$FIX/bin"
  cat > "$FIX/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_CERT_TEST_NM_CALL_LOG:?}"
case "$*" in
  axi)
    if [ -f .nm-home-fail ]; then exit 1; fi
    if [ -f .nm-home ]; then cat .nm-home; else printf 'current_branch: %s\nruns: 0 runs yet in this repository\n' "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"; fi
    ;;
  "runs --limit 200") [ ! -f .nm-runs-fail ] || exit 1; [ ! -f .nm-runs ] || cat .nm-runs ;;
  "axi status") [ ! -f .nm-status-fail ] || exit 1; if [ -f .nm-status ]; then cat .nm-status; else printf 'error: no runs yet\n'; fi ;;
  "axi run --intent "*) printf 'run\n' >> "${FM_CERT_TEST_RUN_LOG:?}" ;;
  *) printf 'unexpected no-mistakes args: %s\n' "$*" >&2; exit 2 ;;
esac
SH
  cat > "$FIX/bin/fm-send" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "${FM_CERT_TEST_SEND_LOG:?}"
[ ! -f "${FM_CERT_TEST_SEND_FAIL:-/nonexistent}" ]
SH
  chmod +x "$FIX/bin/no-mistakes" "$FIX/bin/fm-send"
  export FM_CERTIFICATION_ROOT="$CERT"
  export FM_CERTIFICATION_CAPACITY=1
  export FM_CERT_NM_BIN="$FIX/bin/no-mistakes"
  export FM_CERT_SEND_BIN="$FIX/bin/fm-send"
  export FM_CERT_TEST_SEND_LOG="$SEND_LOG"
  export FM_CERT_TEST_RUN_LOG="$FIX/run.log"
  export FM_CERT_TEST_NM_CALL_LOG="$FIX/nm-calls.log"
  export FM_CERT_NO_EXEC=1
}

add_task() { # <id> <project-name>
  local id=$1 name=$2 primary wt
  primary="$FIX/$name-primary"
  wt="$FIX/$name-wt"
  fm_git_worktree "$primary" "$wt" "fm/$id"
  mkdir -p "$HOME_DIR/data/$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=fm-$id" "worktree=$wt" "project=$primary" "harness=pi" \
    "kind=ship" "mode=no-mistakes" "yolo=off"
  printf 'Validate task %s safely.\n' "$id" > "$HOME_DIR/data/$id/intent"
  printf '%s\n' "$wt"
}

head_of() { git -C "$1" rev-parse HEAD; }
run_cert() { FM_HOME="$HOME_DIR" "$SCRIPT" "$@"; }
record_for() { find "$CERT/queue" -name "*-$1.record" -print | head -1; }
field() { grep "^$2=" "$1" | cut -d= -f2-; }

assert_state() {
  local id=$1 expected=$2 rec
  rec=$(record_for "$id")
  [ "$(field "$rec" state)" = "$expected" ] || fail "$id expected state $expected, got $(field "$rec" state)"
}

test_concurrent_admission_and_duplicate_notification() {
  new_fixture
  local wt1 wt2 h1 h2
  wt1=$(add_task alpha alpha); wt2=$(add_task beta beta)
  h1=$(head_of "$wt1"); h2=$(head_of "$wt2")
  run_cert enqueue alpha "$h1" --intent-file "$HOME_DIR/data/alpha/intent" >"$FIX/alpha.out" 2>&1 &
  local p1=$!
  run_cert enqueue beta "$h2" --intent-file "$HOME_DIR/data/beta/intent" >"$FIX/beta.out" 2>&1 &
  local p2=$!
  wait "$p1" || fail "first concurrent enqueue failed"
  wait "$p2" || fail "second concurrent enqueue failed"
  local alpha_state beta_state
  alpha_state=$(field "$(record_for alpha)" state)
  beta_state=$(field "$(record_for beta)" state)
  case "$alpha_state:$beta_state" in admitted:queued|queued:admitted) ;; *) fail "concurrent admission states were $alpha_state/$beta_state" ;; esac
  [ "$(wc -l < "$SEND_LOG")" -eq 1 ] || fail "capacity one sent more than one admission"
  run_cert reconcile --notify >/dev/null
  [ "$(wc -l < "$SEND_LOG")" -eq 1 ] || fail "reconcile duplicated an admission notification"
  pass "capacity serializes concurrent requests and notification replay is idempotent"
}

test_duplicate_start_claim_is_refused() {
  new_fixture
  local wt h rec token out
  wt=$(add_task once once); h=$(head_of "$wt")
  run_cert enqueue once "$h" --intent-file "$HOME_DIR/data/once/intent" >/dev/null
  rec=$(record_for once); token=$(field "$rec" token)
  run_cert start once "$token" >/dev/null
  if out=$(run_cert start once "$token" 2>&1); then fail "a second unbound launch claim was allowed"; fi
  assert_contains "$out" "already claimed" "duplicate-start refusal was not actionable"
  [ ! -e "$FIX/run.log" ] || [ "$(wc -l < "$FIX/run.log")" -eq 0 ] || fail "duplicate start invoked a second run"
  pass "a launch claim cannot create a duplicate certification run"
}

test_restart_terminal_advances_queue() {
  new_fixture
  local wt1 wt2 h1 h2 rec token
  wt1=$(add_task first first); wt2=$(add_task next next)
  h1=$(head_of "$wt1"); h2=$(head_of "$wt2")
  run_cert enqueue first "$h1" --intent-file "$HOME_DIR/data/first/intent" >/dev/null
  run_cert enqueue next "$h2" --intent-file "$HOME_DIR/data/next/intent" >/dev/null
  rec=$(record_for first); token=$(field "$rec" token)
  run_cert start first "$token" >/dev/null
  cat > "$wt1/.nm-status" <<EOF
id: run-first
branch: fm/first
head: $h1
status: completed
outcome: checks-passed
EOF
  git -C "$wt1" add -N .nm-status >/dev/null 2>&1 || true
  # The status stub is test instrumentation. Hide it from git cleanliness because
  # reconciliation of a launched run intentionally does not rerun clean preflight.
  run_cert reconcile --notify >/dev/null
  assert_state first terminal
  assert_state next admitted
  [ "$(wc -l < "$SEND_LOG")" -eq 2 ] || fail "terminal result did not notify the next queued task exactly once"
  run_cert reconcile --notify >/dev/null
  [ "$(wc -l < "$SEND_LOG")" -eq 2 ] || fail "restart reconciliation duplicated the next notification"
  pass "authoritative terminal reconciliation survives restart and advances FIFO"
}

test_detached_wrong_branch_and_changed_head_stop() {
  new_fixture
  local wt h rec token old
  wt=$(add_task branchy branchy); h=$(head_of "$wt")
  run_cert enqueue branchy "$h" --intent-file "$HOME_DIR/data/branchy/intent" >/dev/null
  rec=$(record_for branchy); token=$(field "$rec" token)
  git -C "$wt" checkout --detach -q
  if out=$(run_cert start branchy "$token" 2>&1); then fail "detached HEAD was admitted"; fi
  assert_contains "$out" "detached HEAD" "detached HEAD refusal was not actionable"
  git -C "$wt" checkout -q -b wrong
  if out=$(run_cert retry branchy 2>&1); then fail "wrong branch should remain blocked after retry"; fi
  assert_state branchy blocked
  assert_contains "$(field "$(record_for branchy)" reason)" "wrong branch" "wrong branch was not recorded"
  git -C "$wt" checkout -q fm/branchy
  run_cert retry branchy >/dev/null
  assert_state branchy admitted
  old=$h
  printf change >> "$wt/README.md"
  git -C "$wt" add README.md && git -C "$wt" -c user.name=test -c user.email=test@example.invalid commit -qm changed
  if out=$(run_cert start branchy "$token" 2>&1); then fail "changed expected head was admitted"; fi
  assert_contains "$out" "changed head" "changed-head refusal was not actionable"
  [ "$(git -C "$wt" rev-parse HEAD)" != "$old" ] || fail "changed-head refusal rewrote the branch"
  pass "detached, wrong, and changed branch identities stop without rewriting work"
}

test_stale_custody_skips_to_next() {
  new_fixture
  local wt1 wt2 h1 h2 out
  wt1=$(add_task stale stale); wt2=$(add_task eligible eligible)
  h1=$(head_of "$wt1"); h2=$(head_of "$wt2")
  printf 'branch_sync:\n  next_action:\n    code: recover_custody\nhelp: no-mistakes axi sync --recover\n' > "$wt1/.nm-home"
  git -C "$wt1" add .nm-home && git -C "$wt1" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  # Record the committed fixture head so stale custody, rather than changed head, is the refusal.
  h1=$(head_of "$wt1")
  if out=$(run_cert enqueue stale "$h1" --intent-file "$HOME_DIR/data/stale/intent" 2>&1); then fail "obsolete custody request should report a blocked item"; fi
  assert_state stale blocked
  assert_contains "$out" "obsolete no-mistakes custody" "custody refusal was not actionable"
  run_cert enqueue eligible "$h2" --intent-file "$HOME_DIR/data/eligible/intent" >/dev/null
  assert_state eligible admitted
  assert_no_grep "sync" "$FIX/nm-calls.log" "coordinator invoked custody recovery"
  assert_no_grep "abort" "$FIX/nm-calls.log" "coordinator cancelled a run"
  assert_no_grep "daemon" "$FIX/nm-calls.log" "coordinator touched the shared daemon"
  pass "obsolete custody blocks only that item and never performs recovery"
}

test_unpublished_dirty_work_is_preserved() {
  new_fixture
  local wt h out
  wt=$(add_task dirty dirty); h=$(head_of "$wt")
  printf 'do not discard\n' > "$wt/unpublished.txt"
  if out=$(run_cert enqueue dirty "$h" --intent-file "$HOME_DIR/data/dirty/intent" 2>&1); then fail "dirty worktree should block admission"; fi
  assert_state dirty blocked
  assert_contains "$out" "not clean" "dirty-copy refusal was not actionable"
  assert_grep "do not discard" "$wt/unpublished.txt" "dirty work was modified or discarded"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$h" ] || fail "dirty refusal changed HEAD"
  pass "dirty unpublished work is preserved byte-for-byte"
}

test_active_uncoordinated_run_blocks() {
  new_fixture
  local wt h out
  wt=$(add_task active active); h=$(head_of "$wt")
  printf 'running other/branch %s 2026-01-01\n' "${h:0:7}" > "$wt/.nm-runs"
  git -C "$wt" add .nm-runs && git -C "$wt" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  h=$(head_of "$wt")
  if out=$(run_cert enqueue active "$h" --intent-file "$HOME_DIR/data/active/intent" 2>&1); then fail "uncoordinated active run should block"; fi
  assert_state active blocked
  assert_contains "$out" "uncoordinated active validation" "active-run refusal was not actionable"
  pass "an active validation outside coordinator ownership stops admission"
}

test_restart_hooks_own_automatic_reconciliation() {
  assert_grep 'fm-certification.sh" reconcile --notify' "$ROOT/bin/fm-session-start.sh" \
    "session restart does not reconcile durable certification state"
  assert_grep 'fm-certification.sh" reconcile --notify' "$ROOT/bin/fm-watch.sh" \
    "ordinary monitoring does not advance terminal certification results"
  pass "session restart and ordinary monitoring both invoke the state-machine owner"
}

test_notification_and_state_read_failures_stop_safely() {
  new_fixture
  local wt h out marker="$FIX/send-fail"
  wt=$(add_task failures failures); h=$(head_of "$wt")
  touch "$marker"
  export FM_CERT_TEST_SEND_FAIL="$marker"
  if out=$(run_cert enqueue failures "$h" --intent-file "$HOME_DIR/data/failures/intent" 2>&1); then fail "send failure should be actionable"; fi
  assert_state failures admitted
  [ "$(field "$(record_for failures)" notification)" = failed ] || fail "send failure was not durably recorded"
  rm -f "$marker"
  run_cert reconcile --notify >/dev/null
  [ "$(wc -l < "$SEND_LOG")" -eq 1 ] || fail "ambiguous send failure was automatically duplicated"
  run_cert retry failures >/dev/null
  [ "$(wc -l < "$SEND_LOG")" -eq 2 ] || fail "explicit retry did not redeliver once"

  new_fixture
  wt=$(add_task unreadable unreadable); h=$(head_of "$wt")
  touch "$wt/.nm-home-fail"
  git -C "$wt" add .nm-home-fail && git -C "$wt" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  h=$(head_of "$wt")
  if out=$(run_cert enqueue unreadable "$h" --intent-file "$HOME_DIR/data/unreadable/intent" 2>&1); then fail "no-mistakes read failure should block"; fi
  assert_state unreadable blocked
  assert_contains "$out" "could not be read" "state-read failure was not actionable"
  pass "notification ambiguity and no-mistakes read failures stop safely"
}

test_concurrent_admission_and_duplicate_notification
test_duplicate_start_claim_is_refused
test_restart_terminal_advances_queue
test_detached_wrong_branch_and_changed_head_stop
test_stale_custody_skips_to_next
test_unpublished_dirty_work_is_preserved
test_active_uncoordinated_run_blocks
test_restart_hooks_own_automatic_reconciliation
test_notification_and_state_read_failures_stop_safely
