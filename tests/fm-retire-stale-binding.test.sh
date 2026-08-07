#!/usr/bin/env bash
# Regression tests for guarded stale binding retirement.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

RETIRE="$ROOT/bin/fm-retire-stale-binding.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-retire-stale-binding)

make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  : > "$case_dir/runtime.log"
  touch "$case_dir/home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

make_git_case() {
  local name=$1 case_dir
  case_dir=$(make_case "$name")
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "fm/survivor"
  git -C "$case_dir/project" branch "fm/stale" main
  printf '%s\n' "$case_dir"
}

sha() {
  fm_pr_sha256 "$1"
}

head_of() {
  git -C "$1" rev-parse --verify HEAD
}

ref_head() {
  git -C "$1" rev-parse --verify "$2^{commit}"
}

write_stale_meta() {
  local case_dir=$1 id=${2:-stale}
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  printf 'done: historical work preserved\n' > "$case_dir/home/state/$id.status"
}

write_survivor_meta() {
  local case_dir=$1
  fm_write_meta "$case_dir/home/state/survivor.meta" \
    "window=firstmate:fm-survivor" \
    "endpoint_task_id=survivor" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
}

run_retire() {
  local case_dir=$1 id=$2
  shift 2
  FM_HOME="$case_dir/home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  PATH="$case_dir/fakebin:$PATH" \
    "$RETIRE" "$id" "$@"
}

run_teardown_for() {
  local case_dir=$1 id=$2
  shift 2
  FM_HOME="$case_dir/home" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_RUNTIME_LOG="$case_dir/runtime.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

set_common_evidence() {
  local case_dir=$1 id=${2:-stale}
  COMMON_META_SHA=$(sha "$case_dir/home/state/$id.meta")
  COMMON_STATUS_SHA=$(sha "$case_dir/home/state/$id.status")
  COMMON_BRANCH=$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)
  COMMON_HEAD=$(head_of "$case_dir/wt")
  COMMON_SURVIVOR_SHA=$(sha "$case_dir/home/state/survivor.meta")
  COMMON_STALE_HEAD=$(ref_head "$case_dir/project" "fm/$id")
}

run_retire_common() {
  local case_dir=$1 id=${2:-stale}
  set_common_evidence "$case_dir" "$id"
  run_retire "$case_dir" "$id" \
    --expect-meta-sha256 "$COMMON_META_SHA" \
    --expect-worktree "$case_dir/wt" \
    --expect-worktree-branch "$COMMON_BRANCH" \
    --expect-worktree-head "$COMMON_HEAD" \
    --expect-worktree-claim survivor "$COMMON_SURVIVOR_SHA" \
    --expect-terminal-status \
    --expect-status-sha256 "$COMMON_STATUS_SHA" \
    --preserve-branch "$case_dir/wt" "$COMMON_BRANCH" "$COMMON_HEAD" \
    --preserve-branch "$case_dir/project" "fm/$id" "$COMMON_STALE_HEAD" \
    --preserve-backlog-match "$id"
}

assert_refused() {
  local case_dir=$1 id=$2 expected=$3
  shift 3
  local rc=0
  set +e
  run_retire "$case_dir" "$id" "$@" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$expected: retirement unexpectedly succeeded"
  assert_grep "$expected" "$case_dir/err" "$expected: refusal did not name expected evidence"
  assert_present "$case_dir/home/state/$id.meta" "$expected: refusal removed metadata"
}

test_reused_copy_stale_binding_retires_and_preserves_survivor() {
  local case_dir rc
  case_dir=$(make_git_case reused-copy)
  write_stale_meta "$case_dir"
  write_survivor_meta "$case_dir"
  printf -- '- stale: hold preserved branch\n' > "$case_dir/home/data/backlog.md"

  rc=0
  run_teardown_for "$case_dir" stale --force > "$case_dir/td-stale.out" 2> "$case_dir/td-stale.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ordinary teardown through stale record unexpectedly succeeded"
  assert_grep "also claimed by task" "$case_dir/td-stale.err" \
    "ordinary teardown did not refuse the stale reused-copy binding"
  assert_grep "survivor" "$case_dir/td-stale.err" \
    "ordinary teardown refusal did not name the survivor claim"
  [ ! -s "$case_dir/runtime.log" ] || fail "ordinary stale teardown reached runtime commands"

  rc=0
  run_teardown_for "$case_dir" survivor --force > "$case_dir/td-survivor.out" 2> "$case_dir/td-survivor.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "ordinary teardown for survivor should wait until stale binding retires"
  assert_grep "also claimed by task" "$case_dir/td-survivor.err" \
    "ordinary teardown did not reproduce the current duplicate-binding defect"
  assert_grep "stale" "$case_dir/td-survivor.err" \
    "ordinary teardown refusal did not name the stale claim"

  run_retire_common "$case_dir" stale > "$case_dir/out" 2> "$case_dir/err" \
    || fail "stale binding retirement failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/home/state/stale.meta" "stale meta was not retired"
  assert_absent "$case_dir/home/state/stale.status" "stale status was not retired"
  assert_present "$case_dir/home/state/survivor.meta" "survivor meta was touched"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = "fm/survivor" ] \
    || fail "survivor branch changed"
  git -C "$case_dir/project" rev-parse --verify "fm/stale^{commit}" >/dev/null \
    || fail "preserved stale branch was removed"
  assert_present "$case_dir/home/data/stale/binding-retirements" \
    "retirement archive was not written"
  pass "reused-copy stale binding retires only state artifacts and preserves survivor copy"
}

test_missing_local_copy_retires_with_commit_evidence() {
  local case_dir id=missing-copy meta_sha status_sha commit
  case_dir=$(make_case missing-copy)
  fm_git_init_commit "$case_dir/project"
  commit=$(head_of "$case_dir/project")
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/no-such-wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'done: PR merged and deployed\n' > "$case_dir/home/state/$id.status"
  meta_sha=$(sha "$case_dir/home/state/$id.meta")
  status_sha=$(sha "$case_dir/home/state/$id.status")

  run_retire "$case_dir" "$id" \
    --expect-meta-sha256 "$meta_sha" \
    --expect-worktree "$case_dir/no-such-wt" \
    --expect-worktree-missing \
    --expect-terminal-status \
    --expect-status-sha256 "$status_sha" \
    --preserve-commit "$case_dir/project" "$commit" \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "missing-copy retirement failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/home/state/$id.meta" "missing-copy meta was not retired"
  assert_present "$case_dir/home/data/$id/binding-retirements" "missing-copy archive missing"
  pass "missing local copy retires only after commit preservation evidence verifies"
}

test_report_only_history_retires_with_report_evidence() {
  local case_dir id=report-only meta_sha status_sha report_sha
  case_dir=$(make_case report-only)
  mkdir -p "$case_dir/home/data/$id"
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "kind=scout" \
    "mode=local-only"
  printf 'done: report complete\n' > "$case_dir/home/state/$id.status"
  printf '# Report\n\nNo unresolved decisions.\n' > "$case_dir/home/data/$id/report.md"
  meta_sha=$(sha "$case_dir/home/state/$id.meta")
  status_sha=$(sha "$case_dir/home/state/$id.status")
  report_sha=$(sha "$case_dir/home/data/$id/report.md")

  run_retire "$case_dir" "$id" \
    --expect-meta-sha256 "$meta_sha" \
    --expect-no-worktree \
    --expect-status-sha256 "$status_sha" \
    --preserve-report "$case_dir/home/data/$id/report.md" "$report_sha" \
    > "$case_dir/out" 2> "$case_dir/err" \
    || fail "report-only retirement failed: $(cat "$case_dir/err")"
  assert_absent "$case_dir/home/state/$id.meta" "report-only meta was not retired"
  assert_present "$case_dir/home/data/$id/report.md" "report was removed"
  pass "report-only stale binding retires with report preservation evidence"
}

test_malformed_and_symlinked_records_refuse() {
  local case_dir bad_sha rc=0
  case_dir=$(make_case malformed)
  set +e
  run_retire "$case_dir" "../bad" \
    --expect-meta-sha256 "$(printf '0%.0s' {1..64})" \
    --expect-no-worktree \
    --preserve-backlog-match bad > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "invalid task id unexpectedly succeeded"
  assert_grep "invalid task id" "$case_dir/err" "invalid id refusal did not name the bad id"

  case_dir=$(make_case symlinked)
  printf 'kind=ship\n' > "$case_dir/target.meta"
  ln -s "$case_dir/target.meta" "$case_dir/home/state/stale.meta"
  bad_sha=$(printf '0%.0s' {1..64})
  assert_refused "$case_dir" stale "meta is not a regular non-symlink file" \
    --expect-meta-sha256 "$bad_sha" \
    --expect-no-worktree \
    --preserve-backlog-match stale
  pass "malformed ids and symlinked records refuse before mutation"
}

test_byte_drift_refuses() {
  local case_dir wrong
  case_dir=$(make_git_case byte-drift)
  write_stale_meta "$case_dir"
  write_survivor_meta "$case_dir"
  printf -- '- stale: hold preserved branch\n' > "$case_dir/home/data/backlog.md"
  wrong=$(printf '1%.0s' {1..64})
  assert_refused "$case_dir" stale "meta changed" \
    --expect-meta-sha256 "$wrong" \
    --expect-worktree "$case_dir/wt" \
    --expect-worktree-branch "fm/survivor" \
    --expect-worktree-head "$(head_of "$case_dir/wt")" \
    --expect-worktree-claim survivor "$(sha "$case_dir/home/state/survivor.meta")" \
    --expect-terminal-status \
    --expect-status-sha256 "$(sha "$case_dir/home/state/stale.status")" \
    --preserve-branch "$case_dir/wt" "fm/survivor" "$(head_of "$case_dir/wt")" \
    --preserve-branch "$case_dir/project" "fm/stale" "$(ref_head "$case_dir/project" "fm/stale")" \
    --preserve-backlog-match stale
  pass "byte drift refuses before archive or removal"
}

test_current_matching_ownership_refuses() {
  local case_dir
  case_dir=$(make_git_case current-match)
  git -C "$case_dir/wt" checkout -q "fm/stale"
  write_stale_meta "$case_dir"
  printf -- '- stale: hold preserved branch\n' > "$case_dir/home/data/backlog.md"
  assert_refused "$case_dir" stale "still matches task stale" \
    --expect-meta-sha256 "$(sha "$case_dir/home/state/stale.meta")" \
    --expect-worktree "$case_dir/wt" \
    --expect-worktree-branch "fm/stale" \
    --expect-worktree-head "$(head_of "$case_dir/wt")" \
    --expect-terminal-status \
    --expect-status-sha256 "$(sha "$case_dir/home/state/stale.status")" \
    --preserve-branch "$case_dir/project" "fm/stale" "$(ref_head "$case_dir/project" "fm/stale")" \
    --preserve-backlog-match stale
  pass "current matching task branch refuses"
}

test_dirty_and_unique_work_refuse() {
  local case_dir
  case_dir=$(make_git_case dirty-work)
  write_stale_meta "$case_dir"
  printf -- '- stale: hold preserved branch\n' > "$case_dir/home/data/backlog.md"
  printf 'dirty\n' > "$case_dir/wt/dirty.txt"
  assert_refused "$case_dir" stale "worktree has uncommitted changes" \
    --expect-meta-sha256 "$(sha "$case_dir/home/state/stale.meta")" \
    --expect-worktree "$case_dir/wt" \
    --expect-worktree-branch "fm/survivor" \
    --expect-worktree-head "$(head_of "$case_dir/wt")" \
    --expect-terminal-status \
    --expect-status-sha256 "$(sha "$case_dir/home/state/stale.status")" \
    --preserve-branch "$case_dir/project" "fm/stale" "$(ref_head "$case_dir/project" "fm/stale")" \
    --preserve-backlog-match stale

  case_dir=$(make_git_case unique-work)
  write_stale_meta "$case_dir"
  printf -- '- stale: hold preserved branch\n' > "$case_dir/home/data/backlog.md"
  git -C "$case_dir/wt" commit --allow-empty -qm "local survivor work"
  assert_refused "$case_dir" stale "local-only commits without matching preservation evidence" \
    --expect-meta-sha256 "$(sha "$case_dir/home/state/stale.meta")" \
    --expect-worktree "$case_dir/wt" \
    --expect-worktree-branch "fm/survivor" \
    --expect-worktree-head "$(head_of "$case_dir/wt")" \
    --expect-terminal-status \
    --expect-status-sha256 "$(sha "$case_dir/home/state/stale.status")" \
    --preserve-branch "$case_dir/project" "fm/stale" "$(ref_head "$case_dir/project" "fm/stale")" \
    --preserve-backlog-match stale
  pass "dirty and unique current work refuse without preservation evidence"
}

test_open_decisions_refuse() {
  local case_dir
  case_dir=$(make_git_case open-decisions)
  write_stale_meta "$case_dir"
  write_survivor_meta "$case_dir"
  printf 'needs-decision [key=scope]: choose cleanup scope\n' > "$case_dir/home/state/stale.status"
  printf -- '- stale: hold preserved branch\n' > "$case_dir/home/data/backlog.md"
  assert_refused "$case_dir" stale "still has open decisions" \
    --expect-meta-sha256 "$(sha "$case_dir/home/state/stale.meta")" \
    --expect-worktree "$case_dir/wt" \
    --expect-worktree-branch "fm/survivor" \
    --expect-worktree-head "$(head_of "$case_dir/wt")" \
    --expect-worktree-claim survivor "$(sha "$case_dir/home/state/survivor.meta")" \
    --expect-status-sha256 "$(sha "$case_dir/home/state/stale.status")" \
    --preserve-branch "$case_dir/wt" "fm/survivor" "$(head_of "$case_dir/wt")" \
    --preserve-branch "$case_dir/project" "fm/stale" "$(ref_head "$case_dir/project" "fm/stale")" \
    --preserve-backlog-match stale
  pass "open decisions refuse before stale binding retirement"
}

test_duplicate_ambiguity_refuses() {
  local case_dir
  case_dir=$(make_git_case duplicate-ambiguity)
  write_stale_meta "$case_dir"
  write_survivor_meta "$case_dir"
  printf -- '- stale: hold preserved branch\n' > "$case_dir/home/data/backlog.md"
  assert_refused "$case_dir" stale "also claimed by survivor" \
    --expect-meta-sha256 "$(sha "$case_dir/home/state/stale.meta")" \
    --expect-worktree "$case_dir/wt" \
    --expect-worktree-branch "fm/survivor" \
    --expect-worktree-head "$(head_of "$case_dir/wt")" \
    --expect-terminal-status \
    --expect-status-sha256 "$(sha "$case_dir/home/state/stale.status")" \
    --preserve-branch "$case_dir/wt" "fm/survivor" "$(head_of "$case_dir/wt")" \
    --preserve-branch "$case_dir/project" "fm/stale" "$(ref_head "$case_dir/project" "fm/stale")" \
    --preserve-backlog-match stale
  pass "duplicate worktree claims refuse unless every expected survivor claim is supplied"
}

test_reused_copy_stale_binding_retires_and_preserves_survivor
test_missing_local_copy_retires_with_commit_evidence
test_report_only_history_retires_with_report_evidence
test_malformed_and_symlinked_records_refuse
test_byte_drift_refuses
test_current_matching_ownership_refuses
test_dirty_and_unique_work_refuse
test_open_decisions_refuse
test_duplicate_ambiguity_refuses
