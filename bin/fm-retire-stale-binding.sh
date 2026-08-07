#!/usr/bin/env bash
# Retire one proven stale task binding from this Firstmate home.
#
# This command is the narrow owner for removing stale state ownership after a
# report proves that state/<task-id>.meta no longer owns the recorded local copy.
# It is binding-only: it never calls a backend, never calls Treehouse, never
# kills a pane or process, never edits a project, never deletes a branch, never
# returns a worktree to a pool, never changes backlog records, and never infers
# discard authority.
#
# The caller supplies one exact task id and immutable expected evidence for the
# current stale record. The command acquires state/.retire-stale-binding.lock,
# re-reads every supplied and discovered artifact while holding that home-scoped
# lock, copies each retired state artifact into
# data/<task-id>/binding-retirements/<timestamp>/, re-checks hashes immediately
# before deletion, then removes only the archived state artifacts.
#
# Refusal is a successful safety result. A refusal preserves every file and
# names the missing, changed, or ambiguous evidence.
#
# Usage:
#   fm-retire-stale-binding.sh <task-id> \
#     --expect-meta-sha256 <sha256> \
#     (--expect-worktree <absolute-path> | --expect-no-worktree) \
#     [--expect-worktree-missing] \
#     [--expect-worktree-branch <branch> --expect-worktree-head <commit>] \
#     [--expect-worktree-claim <task-id> <meta-sha256>]... \
#     [--expect-endpoint-claim <task-id> <meta-sha256>]... \
#     [--expect-terminal-status] \
#     [--expect-artifact-sha256 <artifact-name> <sha256>]... \
#     [--expect-status-sha256 <sha256>] \
#     [--preserve-branch <repo-path> <ref> <commit>]... \
#     [--preserve-commit <repo-path> <commit>]... \
#     [--preserve-report <path> <sha256>]... \
#     [--preserve-backlog-match <literal>]...
#
# Recognized artifact names are: status, turn-ended, check.sh, check-trust,
# pr-poll, pr-poll-registration, pr-poll-retirement, busy-gen, pi-ext.ts,
# grok-turnend-token, kimi-turnend-token, muse-session, muse-session-current,
# herdr-presentation, and open-decisions-cursor.
#
# If the stale record has a worktree path that still exists, the caller must
# name the exact current branch and head. A current branch of fm/<task-id> or
# <task-id> refuses because ordinary task cleanup or recovery still owns it. Any
# dirty worktree refuses. Local commits that are not reachable from any remote
# must be named by --preserve-branch or --preserve-commit before the stale state
# can be retired.
#
# If another metadata record claims the same worktree or endpoint, every such
# claim must be named with its current meta hash. If the endpoint is unique, the
# caller must additionally supply --expect-terminal-status and the status log's
# final event must be done:. Open decisions always refuse.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 1
}

die_usage() {
  usage >&2
  exit 2
}

sha256_valid() {
  local value=$1 LC_ALL=C
  case "$value" in
    *[!0-9A-Fa-f]*|'') return 1 ;;
  esac
  [ "${#value}" -eq 64 ]
}

commit_valid() {
  fm_pr_head_valid "$1"
}

task_id_valid_or_refuse() {
  fm_task_id_path_safe "$1" || refuse "invalid task id: $1"
}

artifact_path() {
  case "$1" in
    meta) printf '%s/%s.meta\n' "$STATE" "$ID" ;;
    status) printf '%s/%s.status\n' "$STATE" "$ID" ;;
    turn-ended) printf '%s/%s.turn-ended\n' "$STATE" "$ID" ;;
    check.sh) printf '%s/%s.check.sh\n' "$STATE" "$ID" ;;
    check-trust) printf '%s/%s.check-trust\n' "$STATE" "$ID" ;;
    pr-poll) printf '%s/%s.pr-poll\n' "$STATE" "$ID" ;;
    pr-poll-registration) printf '%s/%s.pr-poll-registration\n' "$STATE" "$ID" ;;
    pr-poll-retirement) printf '%s/%s.pr-poll-retirement\n' "$STATE" "$ID" ;;
    busy-gen) printf '%s/%s.busy-gen\n' "$STATE" "$ID" ;;
    pi-ext.ts) printf '%s/%s.pi-ext.ts\n' "$STATE" "$ID" ;;
    grok-turnend-token) printf '%s/%s.grok-turnend-token\n' "$STATE" "$ID" ;;
    kimi-turnend-token) printf '%s/%s.kimi-turnend-token\n' "$STATE" "$ID" ;;
    muse-session) printf '%s/%s.muse-session\n' "$STATE" "$ID" ;;
    muse-session-current) printf '%s/%s.muse-session-current\n' "$STATE" "$ID" ;;
    herdr-presentation) printf '%s/%s.herdr-presentation\n' "$STATE" "$ID" ;;
    open-decisions-cursor) printf '%s/.%s.open-decisions-cursor\n' "$STATE" "$ID" ;;
    *) return 1 ;;
  esac
}

artifact_name_valid() {
  artifact_path "$1" >/dev/null
}

expected_artifact_hash() {
  local name=$1 rec_name rec_hash
  if [ "$name" = meta ]; then
    printf '%s\n' "$EXPECT_META_SHA"
    return 0
  fi
  while IFS=$'\t' read -r rec_name rec_hash; do
    [ -n "${rec_name:-}" ] || continue
    [ "$rec_name" = "$name" ] || continue
    printf '%s\n' "$rec_hash"
    return 0
  done <<EOF
$EXPECT_ARTIFACTS
EOF
  return 1
}

append_unique_artifact() {
  local name=$1 existing
  existing=$(printf '%s\n' "$ARTIFACTS_TO_RETIRE" | grep -Fx "$name" || true)
  [ -z "$existing" ] || return 0
  ARTIFACTS_TO_RETIRE="${ARTIFACTS_TO_RETIRE}${ARTIFACTS_TO_RETIRE:+
}$name"
}

regular_single_file_on_state_device() {
  local path=$1 label=$2
  [ -f "$path" ] && [ ! -L "$path" ] \
    || refuse "$label is not a regular non-symlink file: $path"
  [ "$(fm_pr_file_device "$path")" = "$STATE_DEVICE" ] \
    || refuse "$label is not on the state device: $path"
  [ "$(fm_pr_file_link_count "$path")" = 1 ] \
    || refuse "$label has multiple links: $path"
}

verify_artifact_hash() {
  local name=$1 path expected actual
  path=$(artifact_path "$name") || refuse "unknown artifact name: $name"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  regular_single_file_on_state_device "$path" "$name"
  expected=$(expected_artifact_hash "$name") \
    || refuse "$name exists but no expected sha256 was supplied"
  actual=$(fm_pr_sha256 "$path") || refuse "cannot hash $name at $path"
  [ "$actual" = "$expected" ] \
    || refuse "$name changed: expected $expected, got $actual"
}

verify_expected_artifacts_present() {
  local name expected path
  while IFS=$'\t' read -r name expected; do
    [ -n "${name:-}" ] || continue
    path=$(artifact_path "$name") || refuse "unknown expected artifact name: $name"
    [ -e "$path" ] || [ -L "$path" ] \
      || refuse "$name was supplied as expected evidence but is absent"
  done <<EOF
$EXPECT_ARTIFACTS
EOF
}

meta_value_exact() {
  fm_backend_meta_exact_value "$1" "$2"
}

canonical_dir() {
  [ -d "$1" ] || return 1
  (CDPATH='' cd -- "$1" && pwd -P)
}

same_recorded_worktree() {
  local candidate=$1 expected=$2 expected_abs=$3 candidate_abs
  [ -n "$candidate" ] || return 1
  [ "$candidate" = "$expected" ] && return 0
  [ -d "$candidate" ] || return 1
  candidate_abs=$(canonical_dir "$candidate") || return 1
  [ "$candidate_abs" = "$expected_abs" ]
}

claim_hash_expected() {
  local claims=$1 id=$2 claim_id claim_hash
  while IFS=$'\t' read -r claim_id claim_hash; do
    [ -n "${claim_id:-}" ] || continue
    [ "$claim_id" = "$id" ] || continue
    printf '%s\n' "$claim_hash"
    return 0
  done <<EOF
$claims
EOF
  return 1
}

verify_meta_claim_hash() {
  local claim_id=$1 expected=$2 path actual
  path="$STATE/$claim_id.meta"
  [ "$claim_id" != "$ID" ] || refuse "a duplicate claim cannot name the retiring task itself"
  task_id_valid_or_refuse "$claim_id"
  [ -f "$path" ] && [ ! -L "$path" ] \
    || refuse "expected claim $claim_id has no regular metadata at $path"
  [ "$(fm_pr_file_link_count "$path")" = 1 ] \
    || refuse "expected claim $claim_id metadata has multiple links"
  actual=$(fm_pr_sha256 "$path") || refuse "cannot hash expected claim $claim_id"
  [ "$actual" = "$expected" ] \
    || refuse "expected claim $claim_id metadata changed: expected $expected, got $actual"
}

verify_claim_list_hashes() {
  local claims=$1 claim_id claim_hash
  while IFS=$'\t' read -r claim_id claim_hash; do
    [ -n "${claim_id:-}" ] || continue
    verify_meta_claim_hash "$claim_id" "$claim_hash"
  done <<EOF
$claims
EOF
}

scan_worktree_claims() {
  local meta claim_id claim_wt claim_hash expected_hash found=""
  [ -n "$EXPECT_WORKTREE" ] || return 0
  [ "$EXPECT_NO_WORKTREE" -eq 0 ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] \
      || refuse "unsafe metadata record while scanning worktree claims: $meta"
    claim_id=${meta##*/}
    claim_id=${claim_id%.meta}
    task_id_valid_or_refuse "$claim_id"
    claim_wt=$(fm_meta_get "$meta" worktree)
    same_recorded_worktree "$claim_wt" "$EXPECT_WORKTREE" "$EXPECT_WORKTREE_CANONICAL" || continue
    [ "$claim_id" != "$ID" ] || continue
    found="${found}${found:+ }$claim_id"
    expected_hash=$(claim_hash_expected "$EXPECT_WORKTREE_CLAIMS" "$claim_id") \
      || refuse "worktree $EXPECT_WORKTREE is also claimed by $claim_id, but that claim was not supplied as expected evidence"
    claim_hash=$(fm_pr_sha256 "$meta") || refuse "cannot hash worktree claim $claim_id"
    [ "$claim_hash" = "$expected_hash" ] \
      || refuse "worktree claim $claim_id changed: expected $expected_hash, got $claim_hash"
  done
  while IFS=$'\t' read -r claim_id claim_hash; do
    [ -n "${claim_id:-}" ] || continue
    printf '%s\n' "$found" | tr ' ' '\n' | grep -Fxq "$claim_id" \
      || refuse "expected worktree claim $claim_id was not found on $EXPECT_WORKTREE"
  done <<EOF
$EXPECT_WORKTREE_CLAIMS
EOF
}

meta_endpoint_identity() {
  local meta=$1 backend target
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || return 1
  printf '%s\t%s\n' "$backend" "$target"
}

scan_endpoint_claims() {
  local endpoint=$1 backend target meta claim_endpoint claim_backend claim_target claim_id
  local expected_hash claim_hash found=""
  [ -n "$endpoint" ] || return 0
  backend=${endpoint%%$'\t'*}
  target=${endpoint#*$'\t'}
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    [ -f "$meta" ] && [ ! -L "$meta" ] \
      || refuse "unsafe metadata record while scanning endpoint claims: $meta"
    claim_id=${meta##*/}
    claim_id=${claim_id%.meta}
    task_id_valid_or_refuse "$claim_id"
    [ "$claim_id" != "$ID" ] || continue
    claim_endpoint=$(meta_endpoint_identity "$meta" || true)
    [ -n "$claim_endpoint" ] || continue
    claim_backend=${claim_endpoint%%$'\t'*}
    claim_target=${claim_endpoint#*$'\t'}
    [ "$claim_backend" = "$backend" ] && [ "$claim_target" = "$target" ] || continue
    found="${found}${found:+ }$claim_id"
    expected_hash=$(claim_hash_expected "$EXPECT_ENDPOINT_CLAIMS" "$claim_id") \
      || refuse "endpoint $backend:$target is also claimed by $claim_id, but that claim was not supplied as expected evidence"
    claim_hash=$(fm_pr_sha256 "$meta") || refuse "cannot hash endpoint claim $claim_id"
    [ "$claim_hash" = "$expected_hash" ] \
      || refuse "endpoint claim $claim_id changed: expected $expected_hash, got $claim_hash"
  done
  while IFS=$'\t' read -r claim_id claim_hash; do
    [ -n "${claim_id:-}" ] || continue
    printf '%s\n' "$found" | tr ' ' '\n' | grep -Fxq "$claim_id" \
      || refuse "expected endpoint claim $claim_id was not found on $backend:$target"
  done <<EOF
$EXPECT_ENDPOINT_CLAIMS
EOF
  if [ -z "$found" ] && [ "$EXPECT_TERMINAL_STATUS" -ne 1 ]; then
    refuse "endpoint $backend:$target is uniquely owned by the stale record; supply terminal status evidence or preserve it"
  fi
}

status_last_verb() {
  local line
  line=$(last_status_line "$1")
  status_line_verb "$line"
}

verify_status_safety() {
  local status_path open verb
  status_path=$(artifact_path status)
  if [ -e "$status_path" ] || [ -L "$status_path" ]; then
    regular_single_file_on_state_device "$status_path" status
    append_unique_artifact status
    verify_artifact_hash status
    open=$(status_open_decisions "$status_path")
    [ -z "$open" ] || refuse "task $ID still has open decisions"
    if [ "$EXPECT_TERMINAL_STATUS" -eq 1 ]; then
      verb=$(status_last_verb "$status_path")
      [ "$verb" = "done" ] || refuse "task $ID status is not terminal done: (last verb: ${verb:-none})"
    fi
  elif [ "$EXPECT_TERMINAL_STATUS" -eq 1 ]; then
    refuse "--expect-terminal-status was supplied, but state/$ID.status is absent"
  fi
}

ref_is_preserved() {
  local repo=$1 ref=$2 sha=$3 rec_repo rec_ref rec_sha
  while IFS=$'\t' read -r rec_repo rec_ref rec_sha; do
    [ -n "${rec_repo:-}" ] || continue
    [ "$rec_repo" = "$repo" ] && [ "$rec_ref" = "$ref" ] && [ "$rec_sha" = "$sha" ] && return 0
  done <<EOF
$PRESERVE_BRANCHES
EOF
  return 1
}

commit_is_preserved() {
  local repo=$1 sha=$2 rec_repo rec_sha
  while IFS=$'\t' read -r rec_repo rec_sha; do
    [ -n "${rec_repo:-}" ] || continue
    [ "$rec_repo" = "$repo" ] && [ "$rec_sha" = "$sha" ] && return 0
  done <<EOF
$PRESERVE_COMMITS
EOF
  return 1
}

verify_preserve_branch() {
  local repo=$1 ref=$2 sha=$3 actual
  [ -d "$repo" ] && [ ! -L "$repo" ] || refuse "preserved branch repo is not a directory: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "preserved branch repo is not git-inspectable: $repo"
  actual=$(git -C "$repo" rev-parse --verify "$ref^{commit}" 2>/dev/null) \
    || refuse "preserved branch ref is missing: $repo $ref"
  [ "$actual" = "$sha" ] || refuse "preserved branch $ref changed: expected $sha, got $actual"
}

verify_preserve_commit() {
  local repo=$1 sha=$2 actual
  [ -d "$repo" ] && [ ! -L "$repo" ] || refuse "preserved commit repo is not a directory: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "preserved commit repo is not git-inspectable: $repo"
  actual=$(git -C "$repo" rev-parse --verify "$sha^{commit}" 2>/dev/null) \
    || refuse "preserved commit is missing: $repo $sha"
  [ "$actual" = "$sha" ] || refuse "preserved commit resolved differently: expected $sha, got $actual"
}

resolve_report_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    data/*) printf '%s/%s\n' "$FM_HOME" "$1" ;;
    *) printf '%s/%s\n' "$DATA" "$1" ;;
  esac
}

verify_preserve_report() {
  local raw=$1 expected=$2 path actual
  path=$(resolve_report_path "$raw")
  [ -f "$path" ] && [ ! -L "$path" ] || refuse "preserved report is missing or unsafe: $raw"
  actual=$(fm_pr_sha256 "$path") || refuse "cannot hash preserved report: $raw"
  [ "$actual" = "$expected" ] || refuse "preserved report changed: $raw"
}

report_path_matches_preserved() {
  local path=$1 raw expected resolved
  while IFS=$'\t' read -r raw expected; do
    [ -n "${raw:-}" ] || continue
    resolved=$(resolve_report_path "$raw")
    [ "$resolved" = "$path" ] && return 0
  done <<EOF
$PRESERVE_REPORTS
EOF
  return 1
}

verify_preservation_evidence() {
  local rec_repo rec_ref rec_sha rec_report rec_report_sha rec_literal report
  local has_evidence=0 backlog_has_id=0
  while IFS=$'\t' read -r rec_repo rec_ref rec_sha; do
    [ -n "${rec_repo:-}" ] || continue
    has_evidence=1
    verify_preserve_branch "$rec_repo" "$rec_ref" "$rec_sha"
  done <<EOF
$PRESERVE_BRANCHES
EOF
  while IFS=$'\t' read -r rec_repo rec_sha; do
    [ -n "${rec_repo:-}" ] || continue
    has_evidence=1
    verify_preserve_commit "$rec_repo" "$rec_sha"
  done <<EOF
$PRESERVE_COMMITS
EOF
  while IFS=$'\t' read -r rec_report rec_report_sha; do
    [ -n "${rec_report:-}" ] || continue
    has_evidence=1
    verify_preserve_report "$rec_report" "$rec_report_sha"
  done <<EOF
$PRESERVE_REPORTS
EOF
  if [ -e "$DATA/backlog.md" ] || [ -L "$DATA/backlog.md" ]; then
    [ -f "$DATA/backlog.md" ] && [ ! -L "$DATA/backlog.md" ] \
      || refuse "backlog history path is unsafe: $DATA/backlog.md"
    grep -Fq "$ID" "$DATA/backlog.md" && backlog_has_id=1
  fi
  while IFS= read -r rec_literal; do
    [ -n "${rec_literal:-}" ] || continue
    has_evidence=1
    [ -f "$DATA/backlog.md" ] || refuse "backlog preservation evidence was supplied, but data/backlog.md is absent"
    grep -Fq "$rec_literal" "$DATA/backlog.md" \
      || refuse "backlog preservation literal was not found: $rec_literal"
  done <<EOF
$PRESERVE_BACKLOG_MATCHES
EOF
  [ "$has_evidence" -eq 1 ] || refuse "no preservation evidence was supplied"
  if [ "$backlog_has_id" -eq 1 ]; then
    printf '%s\n' "$PRESERVE_BACKLOG_MATCHES" | grep -Fq "$ID" \
      || refuse "backlog mentions $ID but no matching backlog preservation evidence was supplied"
  fi
  report="$DATA/$ID/report.md"
  if [ -e "$report" ] || [ -L "$report" ]; then
    [ -f "$report" ] && [ ! -L "$report" ] || refuse "task report path is unsafe: $report"
    report_path_matches_preserved "$report" \
      || refuse "report exists at data/$ID/report.md but was not named as preserved evidence"
  fi
}

verify_worktree_state() {
  local meta_worktree actual_branch actual_head dirty unpushed repo ref sha found_preserve=0
  if [ "$EXPECT_NO_WORKTREE" -eq 1 ]; then
    if meta_worktree=$(meta_value_exact "$META" worktree 2>/dev/null); then
      refuse "--expect-no-worktree was supplied, but metadata records worktree=$meta_worktree"
    fi
    return 0
  fi
  meta_worktree=$(meta_value_exact "$META" worktree 2>/dev/null) \
    || refuse "metadata has missing, empty, or ambiguous worktree identity"
  [ "$meta_worktree" = "$EXPECT_WORKTREE" ] \
    || refuse "worktree evidence changed: expected $EXPECT_WORKTREE, got $meta_worktree"
  if [ "$EXPECT_WORKTREE_MISSING" -eq 1 ]; then
    [ ! -e "$EXPECT_WORKTREE" ] && [ ! -L "$EXPECT_WORKTREE" ] \
      || refuse "expected missing worktree exists: $EXPECT_WORKTREE"
    return 0
  fi
  [ -d "$EXPECT_WORKTREE" ] && [ ! -L "$EXPECT_WORKTREE" ] \
    || refuse "recorded worktree is missing or unsafe: $EXPECT_WORKTREE"
  git -C "$EXPECT_WORKTREE" rev-parse --git-dir >/dev/null 2>&1 \
    || refuse "recorded worktree is not git-inspectable: $EXPECT_WORKTREE"
  [ -n "$EXPECT_WORKTREE_BRANCH" ] && [ -n "$EXPECT_WORKTREE_HEAD" ] \
    || refuse "existing worktree requires --expect-worktree-branch and --expect-worktree-head"
  actual_branch=$(git -C "$EXPECT_WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null) \
    || refuse "cannot read current worktree branch"
  actual_head=$(git -C "$EXPECT_WORKTREE" rev-parse --verify HEAD 2>/dev/null) \
    || refuse "cannot read current worktree head"
  [ "$actual_branch" = "$EXPECT_WORKTREE_BRANCH" ] \
    || refuse "worktree branch changed: expected $EXPECT_WORKTREE_BRANCH, got $actual_branch"
  [ "$actual_head" = "$EXPECT_WORKTREE_HEAD" ] \
    || refuse "worktree head changed: expected $EXPECT_WORKTREE_HEAD, got $actual_head"
  case "$actual_branch" in
    "$ID"|"fm/$ID") refuse "worktree branch $actual_branch still matches task $ID" ;;
  esac
  dirty=$(git -C "$EXPECT_WORKTREE" status --porcelain --untracked-files=all 2>/dev/null) \
    || refuse "cannot inspect worktree status for $EXPECT_WORKTREE"
  [ -z "$dirty" ] || refuse "worktree has uncommitted changes: $EXPECT_WORKTREE"
  unpushed=$(git -C "$EXPECT_WORKTREE" log --format=%H HEAD --not --remotes -- 2>/dev/null) \
    || refuse "cannot inspect worktree commits for $EXPECT_WORKTREE"
  if [ -n "$unpushed" ]; then
    while IFS=$'\t' read -r repo ref sha; do
      [ -n "${repo:-}" ] || continue
      if [ "$repo" = "$EXPECT_WORKTREE" ] && [ "$ref" = "$actual_branch" ] && [ "$sha" = "$actual_head" ]; then
        found_preserve=1
      fi
    done <<EOF
$PRESERVE_BRANCHES
EOF
    commit_is_preserved "$EXPECT_WORKTREE" "$actual_head" && found_preserve=1
    [ "$found_preserve" -eq 1 ] \
      || refuse "worktree head contains local-only commits without matching preservation evidence"
  fi
}

verify_task_branch_preserved() {
  local project ref actual
  project=$(fm_meta_get "$META" project)
  [ -n "$project" ] || return 0
  [ -d "$project" ] && [ ! -L "$project" ] || return 0
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 0
  for ref in "fm/$ID" "$ID"; do
    actual=$(git -C "$project" rev-parse --verify "$ref^{commit}" 2>/dev/null || true)
    [ -n "$actual" ] || continue
    ref_is_preserved "$project" "$ref" "$actual" \
      || commit_is_preserved "$project" "$actual" \
      || refuse "local task branch $ref exists at $actual but was not named as preserved evidence"
  done
}

discover_artifacts() {
  local name path
  ARTIFACTS_TO_RETIRE=meta
  for name in status turn-ended check.sh check-trust pr-poll pr-poll-registration \
    pr-poll-retirement busy-gen pi-ext.ts grok-turnend-token kimi-turnend-token \
    muse-session muse-session-current herdr-presentation open-decisions-cursor; do
    path=$(artifact_path "$name")
    if [ -e "$path" ] || [ -L "$path" ]; then
      append_unique_artifact "$name"
      verify_artifact_hash "$name"
    fi
  done
}

archive_artifacts() {
  local base ts archive path name expected actual dst ledger tmp
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || refuse "data directory is missing or unsafe: $DATA"
  if [ -e "$DATA/$ID" ] || [ -L "$DATA/$ID" ]; then
    [ -d "$DATA/$ID" ] && [ ! -L "$DATA/$ID" ] \
      || refuse "task data directory is unsafe: $DATA/$ID"
  fi
  base="$DATA/$ID/binding-retirements"
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  archive="$base/$ts"
  if [ -e "$archive" ]; then
    archive="$base/$ts.$$"
  fi
  (umask 077; mkdir -p "$base"; mkdir "$archive") \
    || refuse "cannot create archive directory under data/$ID"
  ledger="$archive/retirement-record"
  tmp="$archive/.write-test"
  if ! printf '%s\n' test > "$tmp" || ! rm -f "$tmp"; then
    refuse "archive directory is not writable: $archive"
  fi
  {
    printf 'fm-stale-binding-retirement-v1\n'
    printf 'task_id=%s\n' "$ID"
    printf 'timestamp=%s\n' "$ts"
    printf 'fm_home=%s\n' "$FM_HOME"
    printf 'state=%s\n' "$STATE"
    printf 'data=%s\n' "$DATA"
    printf 'worktree=%s\n' "$EXPECT_WORKTREE"
    printf 'artifacts:\n'
  } > "$ledger"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path=$(artifact_path "$name")
    [ -e "$path" ] || [ -L "$path" ] || refuse "$name disappeared before archive"
    verify_artifact_hash "$name"
    expected=$(expected_artifact_hash "$name")
    dst="$archive/$name"
    cp -p -- "$path" "$dst" || refuse "cannot archive $name"
    actual=$(fm_pr_sha256 "$dst") || refuse "cannot hash archived $name"
    [ "$actual" = "$expected" ] || refuse "archived $name hash mismatch"
    printf '  %s %s\n' "$name" "$actual" >> "$ledger"
  done <<EOF
$ARTIFACTS_TO_RETIRE
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    verify_artifact_hash "$name"
  done <<EOF
$ARTIFACTS_TO_RETIRE
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path=$(artifact_path "$name")
    rm -f -- "$path" || refuse "cannot remove retired state artifact $name"
  done <<EOF
$ARTIFACTS_TO_RETIRE
EOF
  printf 'retired stale binding %s; archived %s\n' "$ID" "$archive"
}

ID=${1:-}
[ -n "$ID" ] || die_usage
shift
task_id_valid_or_refuse "$ID"

EXPECT_META_SHA=
EXPECT_ARTIFACTS=
EXPECT_WORKTREE=
EXPECT_WORKTREE_CANONICAL=
EXPECT_WORKTREE_MISSING=0
EXPECT_NO_WORKTREE=0
EXPECT_WORKTREE_BRANCH=
EXPECT_WORKTREE_HEAD=
EXPECT_WORKTREE_CLAIMS=
EXPECT_ENDPOINT_CLAIMS=
EXPECT_TERMINAL_STATUS=0
PRESERVE_BRANCHES=
PRESERVE_COMMITS=
PRESERVE_REPORTS=
PRESERVE_BACKLOG_MATCHES=
ARTIFACTS_TO_RETIRE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --expect-meta-sha256)
      shift; EXPECT_META_SHA=${1:-}; sha256_valid "$EXPECT_META_SHA" || die_usage ;;
    --expect-status-sha256)
      shift; status_sha=${1:-}; sha256_valid "$status_sha" || die_usage
      EXPECT_ARTIFACTS="${EXPECT_ARTIFACTS}${EXPECT_ARTIFACTS:+
}status	$status_sha" ;;
    --expect-artifact-sha256)
      shift; artifact=${1:-}; shift; artifact_sha=${1:-}
      artifact_name_valid "$artifact" || die_usage
      sha256_valid "$artifact_sha" || die_usage
      [ "$artifact" != meta ] || die_usage
      EXPECT_ARTIFACTS="${EXPECT_ARTIFACTS}${EXPECT_ARTIFACTS:+
}$artifact	$artifact_sha" ;;
    --expect-worktree)
      shift; EXPECT_WORKTREE=${1:-}
      case "$EXPECT_WORKTREE" in /*) ;; *) die_usage ;; esac ;;
    --expect-worktree-missing) EXPECT_WORKTREE_MISSING=1 ;;
    --expect-no-worktree) EXPECT_NO_WORKTREE=1 ;;
    --expect-worktree-branch)
      shift; EXPECT_WORKTREE_BRANCH=${1:-}; [ -n "$EXPECT_WORKTREE_BRANCH" ] || die_usage ;;
    --expect-worktree-head)
      shift; EXPECT_WORKTREE_HEAD=${1:-}; commit_valid "$EXPECT_WORKTREE_HEAD" || die_usage ;;
    --expect-worktree-claim)
      shift; claim_id=${1:-}; shift; claim_sha=${1:-}
      task_id_valid_or_refuse "$claim_id"; sha256_valid "$claim_sha" || die_usage
      EXPECT_WORKTREE_CLAIMS="${EXPECT_WORKTREE_CLAIMS}${EXPECT_WORKTREE_CLAIMS:+
}$claim_id	$claim_sha" ;;
    --expect-endpoint-claim)
      shift; claim_id=${1:-}; shift; claim_sha=${1:-}
      task_id_valid_or_refuse "$claim_id"; sha256_valid "$claim_sha" || die_usage
      EXPECT_ENDPOINT_CLAIMS="${EXPECT_ENDPOINT_CLAIMS}${EXPECT_ENDPOINT_CLAIMS:+
}$claim_id	$claim_sha" ;;
    --expect-terminal-status) EXPECT_TERMINAL_STATUS=1 ;;
    --preserve-branch)
      shift; preserve_repo=${1:-}; shift; preserve_ref=${1:-}; shift; preserve_sha=${1:-}
      if [ -z "$preserve_repo" ] || [ -z "$preserve_ref" ] || ! commit_valid "$preserve_sha"; then
        die_usage
      fi
      PRESERVE_BRANCHES="${PRESERVE_BRANCHES}${PRESERVE_BRANCHES:+
}$preserve_repo	$preserve_ref	$preserve_sha" ;;
    --preserve-commit)
      shift; preserve_repo=${1:-}; shift; preserve_sha=${1:-}
      if [ -z "$preserve_repo" ] || ! commit_valid "$preserve_sha"; then
        die_usage
      fi
      PRESERVE_COMMITS="${PRESERVE_COMMITS}${PRESERVE_COMMITS:+
}$preserve_repo	$preserve_sha" ;;
    --preserve-report)
      shift; preserve_report=${1:-}; shift; preserve_report_sha=${1:-}
      if [ -z "$preserve_report" ] || ! sha256_valid "$preserve_report_sha"; then
        die_usage
      fi
      PRESERVE_REPORTS="${PRESERVE_REPORTS}${PRESERVE_REPORTS:+
}$preserve_report	$preserve_report_sha" ;;
    --preserve-backlog-match)
      shift; preserve_literal=${1:-}; [ -n "$preserve_literal" ] || die_usage
      case "$preserve_literal" in *$'\n'*|*$'\r'*) die_usage ;; esac
      PRESERVE_BACKLOG_MATCHES="${PRESERVE_BACKLOG_MATCHES}${PRESERVE_BACKLOG_MATCHES:+
}$preserve_literal" ;;
    *) die_usage ;;
  esac
  shift
done

[ -n "$EXPECT_META_SHA" ] || die_usage
if [ "$EXPECT_NO_WORKTREE" -eq 1 ]; then
  [ -z "$EXPECT_WORKTREE" ] && [ "$EXPECT_WORKTREE_MISSING" -eq 0 ] || die_usage
else
  [ -n "$EXPECT_WORKTREE" ] || die_usage
fi
if [ -n "$EXPECT_WORKTREE_BRANCH" ] || [ -n "$EXPECT_WORKTREE_HEAD" ]; then
  [ -n "$EXPECT_WORKTREE_BRANCH" ] && [ -n "$EXPECT_WORKTREE_HEAD" ] || die_usage
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || refuse "state directory is missing or unsafe: $STATE"
STATE_DEVICE=$(fm_pr_file_device "$STATE") || refuse "cannot identify state device"
META="$STATE/$ID.meta"
LOCK="$STATE/.retire-stale-binding.lock"

fm_lock_acquire_wait "$LOCK" || refuse "cannot acquire stale-binding retirement lock"
trap 'fm_lock_release "$LOCK"' EXIT

regular_single_file_on_state_device "$META" meta
verify_artifact_hash meta
verify_expected_artifacts_present
if [ "$EXPECT_NO_WORKTREE" -eq 0 ] && [ "$EXPECT_WORKTREE_MISSING" -eq 0 ] \
  && [ -d "$EXPECT_WORKTREE" ]; then
  EXPECT_WORKTREE_CANONICAL=$(canonical_dir "$EXPECT_WORKTREE") \
    || refuse "cannot canonicalize worktree: $EXPECT_WORKTREE"
fi
verify_claim_list_hashes "$EXPECT_WORKTREE_CLAIMS"
verify_claim_list_hashes "$EXPECT_ENDPOINT_CLAIMS"
verify_status_safety
verify_preservation_evidence
verify_worktree_state
verify_task_branch_preserved
scan_worktree_claims
endpoint_identity=$(meta_endpoint_identity "$META" || true)
scan_endpoint_claims "$endpoint_identity"
if grep -Eq '^x_request=|^x_followups=' "$META"; then
  refuse "task $ID has Relay follow-up metadata; retire or waive the public follow-up first"
fi
discover_artifacts
archive_artifacts
