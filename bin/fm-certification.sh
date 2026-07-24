#!/usr/bin/env bash
# Durable admission coordinator for final heavy no-mistakes certifications.
#
# This script is the single executable owner of the certification state machine.
# It serializes every mutation through one machine-global coordinator lock, stores
# its FIFO ledger outside individual Firstmate homes, and never runs a gate
# response, custody recovery, cancellation, branch rewrite, or daemon lifecycle
# command.
#
# Commands:
#   fm-certification.sh enqueue <task-id> <expected-head> --intent-file <path>
#     Records one final certification request for the task in the active FM_HOME.
#     The task must already have state/<id>.meta. The expected head must be a full
#     commit id. A successful call reconciles the queue and admits/notifies the
#     next eligible request when capacity is available.
#   fm-certification.sh reconcile [--notify]
#     Reconciles admitted work against read-only no-mistakes state, releases slots
#     only for an authoritative terminal result, and admits queued eligible work.
#     --notify submits one idempotently recorded start instruction to each newly
#     admitted worker through fm-send. This command never drives no-mistakes.
#   fm-certification.sh start <task-id> <admission-token>
#     Worker-side entry point. Repeats the full preflight under the coordinator
#     lock, records launch custody, then execs `no-mistakes axi run` in that
#     worker's own process with the stored intent. Repeating it reattaches to a
#     matching active run; it never starts a second mismatched run.
#   fm-certification.sh retry <task-id>
#     Requeues a blocked request without changing its expected branch or head,
#     or explicitly retries a failed/ambiguous notification or unbound launch
#     after inspection proves no matching active run exists.
#   fm-certification.sh withdraw <task-id>
#     Abandons a request and frees its slot so a corrected head can be
#     re-enqueued. Refuses to cancel a matching active or terminal run; the
#     record and its intent are archived under the shared root for evidence.
#   fm-certification.sh status
#     Prints the durable queue in sequence order without mutation.
#
# Configuration and test overrides:
#   FM_CERTIFICATION_ROOT   shared durable root (default ~/.no-mistakes/firstmate-certification)
#   FM_CERTIFICATION_CAPACITY positive configured capacity (default 1). The first
#                           mutation records it durably; later mismatches refuse.
#   FM_CERTIFICATION_RETAIN positive count of newest terminal records to retain
#                           (default 100). Also bounds the quarantine and withdrawn
#                           archives. Older records and their intent are pruned.
#   FM_CERTIFICATION_LAUNCH_GRACE positive seconds a launching record may show no
#                           matching run before reconcile surfaces a stall (default 120).
#   FM_CERT_NM_BIN          no-mistakes executable (default no-mistakes)
#   FM_CERT_SEND_BIN        fm-send executable (default tracked fm-send.sh)
#   FM_CERT_TIMEOUT         read-only CLI timeout seconds (default 15)
#   FM_CERT_NO_EXEC=1       test-only: print the worker command instead of exec
#
# Exit 0 means the requested operation converged. Exit 1 is an actionable safety
# refusal or failed notification. Exit 2 is bad usage. Exact state, transition,
# recovery, and authority rationale lives in docs/certification-coordinator.md.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CERT_ROOT="${FM_CERTIFICATION_ROOT:-${NO_MISTAKES_HOME:-$HOME/.no-mistakes}/firstmate-certification}"
QUEUE="$CERT_ROOT/queue"
LOCK="$CERT_ROOT/.lock"
QUARANTINE="$CERT_ROOT/quarantine"
WITHDRAWN="$CERT_ROOT/withdrawn"
CAPACITY_REQUESTED="${FM_CERTIFICATION_CAPACITY:-1}"
RETAIN_REQUESTED="${FM_CERTIFICATION_RETAIN:-100}"
LAUNCH_GRACE="${FM_CERTIFICATION_LAUNCH_GRACE:-120}"
NM_BIN="${FM_CERT_NM_BIN:-no-mistakes}"
SEND_BIN="${FM_CERT_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
NM_TIMEOUT="${FM_CERT_TIMEOUT:-15}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() { sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 1; }
usage_die() { echo "error: $*" >&2; usage >&2; exit 2; }

case "$CAPACITY_REQUESTED" in ''|*[!0-9]*|0) die "FM_CERTIFICATION_CAPACITY must be a positive integer" ;; esac
case "$RETAIN_REQUESTED" in ''|*[!0-9]*|0) die "FM_CERTIFICATION_RETAIN must be a positive integer" ;; esac
case "$LAUNCH_GRACE" in ''|*[!0-9]*|0) die "FM_CERTIFICATION_LAUNCH_GRACE must be a positive integer" ;; esac
case "$NM_TIMEOUT" in ''|*[!0-9]*|0) die "FM_CERT_TIMEOUT must be a positive integer" ;; esac

mkdir_private() {
  umask 077
  mkdir -p "$CERT_ROOT" "$QUEUE" "$QUARANTINE" "$WITHDRAWN"
  [ ! -L "$CERT_ROOT" ] && [ ! -L "$QUEUE" ] || die "certification state paths must not be symlinks: $CERT_ROOT"
  [ ! -L "$QUARANTINE" ] && [ ! -L "$WITHDRAWN" ] || die "certification state paths must not be symlinks: $CERT_ROOT"
  chmod 0700 "$CERT_ROOT" "$QUEUE" "$QUARANTINE" "$WITHDRAWN" 2>/dev/null || true
}

lock_acquire() {
  mkdir_private
  fm_lock_acquire_wait "$LOCK"
  trap 'fm_lock_release "$LOCK" 2>/dev/null || true' EXIT HUP INT TERM
}
lock_release() {
  fm_lock_release "$LOCK"
  trap - EXIT HUP INT TERM
}

capacity_ensure() {
  local file="$CERT_ROOT/capacity" tmp current
  if [ -e "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || die "coordinator capacity is not a regular file: $file"
    current=$(cat "$file" 2>/dev/null || true)
    [ "$current" = "$CAPACITY_REQUESTED" ] || die "configured capacity $CAPACITY_REQUESTED conflicts with durable shared capacity ${current:-unknown} at $file"
    return
  fi
  tmp=$(mktemp "$CERT_ROOT/.capacity.XXXXXX") || die "cannot create coordinator capacity"
  printf '%s\n' "$CAPACITY_REQUESTED" > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
}

valid_task_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }
valid_head() { printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}$'; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
now_epoch() { printf '%s\n' "${FM_CERT_NOW:-$(date +%s)}"; }
within_launch_grace() { # <launched-at>
  local launched=$1 now
  now=$(now_epoch)
  is_uint "$launched" && is_uint "$now" || return 1
  [ "$now" -ge "$launched" ] && [ "$((now - launched))" -lt "$LAUNCH_GRACE" ]
}
single_line_value() { case "$1" in *$'\n'*|*$'\r'*) return 1 ;; *) return 0 ;; esac; }
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
record_field() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
record_for_task() {
  local task=$1 home=$2 rec
  for rec in "$QUEUE"/*.record; do
    [ -f "$rec" ] || continue
    [ "$(record_field "$rec" task)" = "$task" ] || continue
    [ "$(record_field "$rec" home)" = "$home" ] || continue
    printf '%s\n' "$rec"
    return 0
  done
  return 1
}

RECORD_STATES="queued admitted launching running blocked terminal"
record_schema_ok() { # <record>
  local rec=$1 field state seq
  [ "$(record_field "$rec" version)" = 1 ] || return 1
  for field in sequence task home project worktree branch expected_head token state; do
    [ -n "$(record_field "$rec" "$field")" ] || return 1
  done
  seq=$(record_field "$rec" sequence)
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  valid_task_id "$(record_field "$rec" task)" || return 1
  valid_head "$(record_field "$rec" expected_head)" || return 1
  state=$(record_field "$rec" state)
  case " $RECORD_STATES " in *" $state "*) return 0 ;; *) return 1 ;; esac
}

quarantine_sweep() { # sets QUARANTINED=1 and returns 1 if any record was quarantined
  local rec base rc=0
  for rec in "$QUEUE"/*.record; do
    [ -f "$rec" ] || continue
    record_schema_ok "$rec" && continue
    base=$(basename "$rec" .record)
    mv "$rec" "$QUARANTINE/$base.record" 2>/dev/null || true
    [ ! -f "$QUEUE/$base.intent" ] || mv "$QUEUE/$base.intent" "$QUARANTINE/$base.intent" 2>/dev/null || true
    echo "certification record quarantined (unsupported version or malformed schema): $base" >&2
    rc=1
  done
  return "$rc"
}

prune_dir_records() { # <dir> <keep> [state-filter]
  local dir=$1 keep=$2 filter=${3:-} rec base n=0 sorted
  sorted=$(for rec in "$dir"/*.record; do
    [ -f "$rec" ] || continue
    [ -z "$filter" ] || [ "$(record_field "$rec" state)" = "$filter" ] || continue
    printf '%s\n' "$rec"
  done | sort -r)
  [ -n "$sorted" ] || return 0
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    n=$((n + 1))
    [ "$n" -gt "$keep" ] || continue
    base=$(basename "$rec" .record)
    rm -f "$rec" "$(dirname "$rec")/$base.intent" 2>/dev/null || true
  done <<EOF
$sorted
EOF
}

retention_sweep() {
  # Keep the newest RETAIN_REQUESTED terminal records in the live queue and the
  # newest RETAIN_REQUESTED entries of each archive so compact recent audit
  # evidence is preserved while steady-state storage stays flat.
  prune_dir_records "$QUEUE" "$RETAIN_REQUESTED" terminal
  prune_dir_records "$QUARANTINE" "$RETAIN_REQUESTED"
  prune_dir_records "$WITHDRAWN" "$RETAIN_REQUESTED"
}

record_write() { # <record> <state> <notification> <run-id> <outcome> <reason> [launched-at]
  local rec=$1 new_state=$2 notification=$3 run_id=$4 outcome=$5 reason=$6 tmp launched
  if [ "$#" -ge 7 ]; then launched=$7; else launched=$(record_field "$rec" launched_at); fi
  tmp=$(mktemp "$QUEUE/.record.XXXXXX") || die "cannot create certification record"
  {
    printf 'version=1\n'
    printf 'sequence=%s\n' "$(record_field "$rec" sequence)"
    printf 'task=%s\n' "$(record_field "$rec" task)"
    printf 'home=%s\n' "$(record_field "$rec" home)"
    printf 'project=%s\n' "$(record_field "$rec" project)"
    printf 'worktree=%s\n' "$(record_field "$rec" worktree)"
    printf 'branch=%s\n' "$(record_field "$rec" branch)"
    printf 'expected_head=%s\n' "$(record_field "$rec" expected_head)"
    printf 'token=%s\n' "$(record_field "$rec" token)"
    printf 'state=%s\n' "$new_state"
    printf 'notification=%s\n' "$notification"
    printf 'run_id=%s\n' "$run_id"
    printf 'outcome=%s\n' "$outcome"
    printf 'reason=%s\n' "$reason"
    printf 'launched_at=%s\n' "$launched"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$rec"
}

next_sequence() {
  local file="$CERT_ROOT/next-sequence" n tmp
  n=$(cat "$file" 2>/dev/null || printf '1')
  case "$n" in ''|*[!0-9]*) die "invalid coordinator sequence in $file" ;; esac
  tmp=$(mktemp "$CERT_ROOT/.sequence.XXXXXX") || die "cannot create coordinator sequence"
  printf '%s\n' "$((n + 1))" > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$file"
  printf '%012d' "$n"
}

physical_dir() { (cd "$1" 2>/dev/null && pwd -P); }
meta_value() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }

run_bounded() { # <worktree> <args...>
  local wt=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    (cd "$wt" && timeout "$NM_TIMEOUT" "$NM_BIN" "$@") 2>/dev/null
  elif command -v gtimeout >/dev/null 2>&1; then
    (cd "$wt" && gtimeout "$NM_TIMEOUT" "$NM_BIN" "$@") 2>/dev/null
  else
    (cd "$wt" && "$NM_BIN" "$@") 2>/dev/null
  fi
}

toon_field() { printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\"\{0,1\}\([^\"]*\)\"\{0,1\}[[:space:]]*$/\1/p" | head -1; }
active_run_rows() { printf '%s\n' "$1" | awk '$1 == "running" { print $2 "\t" $3 }'; }

record_is_live() {
  case "$(record_field "$1" state)" in admitted|launching|running) return 0 ;; *) return 1 ;; esac
}

coordinated_active_run() { # <project> <branch> <head-prefix>
  local project=$1 branch=$2 head=$3 rec expected
  for rec in "$QUEUE"/*.record; do
    if [ ! -f "$rec" ] || ! record_is_live "$rec"; then
      continue
    fi
    [ "$(record_field "$rec" project)" = "$project" ] || continue
    [ "$(record_field "$rec" branch)" = "$branch" ] || continue
    expected=$(record_field "$rec" expected_head)
    case "$expected" in "$head"*|"$head") return 0 ;; esac
  done
  return 1
}

PREFLIGHT_REASON=
preflight() { # <record> [allow-self-active]
  local rec=$1 allow_self=${2:-0} task home project wt branch expected meta top wt_real project_real actual_branch actual_head porcelain home_out runs_out rbranch rhead
  PREFLIGHT_REASON=
  task=$(record_field "$rec" task)
  home=$(record_field "$rec" home)
  project=$(record_field "$rec" project)
  wt=$(record_field "$rec" worktree)
  branch=$(record_field "$rec" branch)
  expected=$(record_field "$rec" expected_head)
  meta="$home/state/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { PREFLIGHT_REASON="task metadata is missing or ambiguous at $meta"; return 1; }
  [ "$(meta_value "$meta" kind)" = ship ] || { PREFLIGHT_REASON="task $task is not a ship task"; return 1; }
  [ "$(meta_value "$meta" mode)" = no-mistakes ] || { PREFLIGHT_REASON="task $task delivery mode is $(meta_value "$meta" mode); final certification admits only no-mistakes delivery, never direct-PR or local-only"; return 1; }
  [ "$(meta_value "$meta" worktree)" = "$wt" ] || { PREFLIGHT_REASON="task $task metadata no longer names intended isolated copy $wt"; return 1; }
  [ "$(meta_value "$meta" project)" = "$project" ] || { PREFLIGHT_REASON="task $task metadata no longer names intended project $project"; return 1; }
  wt_real=$(physical_dir "$wt" 2>/dev/null) || { PREFLIGHT_REASON="isolated copy is unavailable: $wt"; return 1; }
  project_real=$(physical_dir "$project" 2>/dev/null) || { PREFLIGHT_REASON="project local copy is unavailable: $project"; return 1; }
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null || true)
  top=$(physical_dir "$top" 2>/dev/null || true)
  [ -n "$top" ] && [ "$top" = "$wt_real" ] && [ "$wt_real" != "$project_real" ] || { PREFLIGHT_REASON="task $task is not in a clean isolated git copy distinct from $project"; return 1; }
  actual_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$actual_branch" ] || { PREFLIGHT_REASON="detached HEAD in $wt; attach the intended task branch before certification"; return 1; }
  [ "$actual_branch" = "$branch" ] || { PREFLIGHT_REASON="wrong branch in $wt: expected $branch, found $actual_branch"; return 1; }
  actual_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  [ "$actual_head" = "$expected" ] || { PREFLIGHT_REASON="changed head for $task: expected $expected, found ${actual_head:-unknown}; request a new explicit expected head"; return 1; }
  porcelain=$(git -C "$wt" status --porcelain=v1 --untracked-files=all 2>/dev/null || printf '__git_status_failed__')
  [ -z "$porcelain" ] || { PREFLIGHT_REASON="isolated copy $wt is not clean; preserve and resolve every unpublished change before certification"; return 1; }
  if ! home_out=$(run_bounded "$wt" axi); then
    PREFLIGHT_REASON="no-mistakes state could not be read for $task; leave daemon and custody untouched and inspect the reported tool failure"
    return 1
  fi
  case "$home_out" in
    *recover_custody*|*"recover custody"*|*"sync --recover"*)
      PREFLIGHT_REASON="obsolete no-mistakes custody blocks $task; use only the separately authorized custody recovery choice"
      return 1
      ;;
    *"error:"*) PREFLIGHT_REASON="no-mistakes preflight reported an error for $task"; return 1 ;;
  esac
  if ! runs_out=$(run_bounded "$wt" runs --limit 200); then
    PREFLIGHT_REASON="active no-mistakes runs could not be inspected for $task"
    return 1
  fi
  while IFS=$(printf '\t') read -r rbranch rhead; do
    [ -n "$rbranch" ] || continue
    if [ "$allow_self" = 1 ] && [ "$rbranch" = "$branch" ]; then
      case "$expected" in "$rhead"*|"$rhead") continue ;; esac
    fi
    if coordinated_active_run "$project" "$rbranch" "$rhead"; then
      continue
    fi
    PREFLIGHT_REASON="uncoordinated active validation on branch $rbranch blocks safe admission for project $project"
    return 1
  done < <(active_run_rows "$runs_out")
  return 0
}

live_count() {
  local rec n=0
  for rec in "$QUEUE"/*.record; do
    [ -f "$rec" ] && record_is_live "$rec" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

RUN_KIND=none
RUN_ID=""
RUN_OUTCOME=""
RUN_REASON=""
inspect_record_run() {
  local rec=$1 wt branch expected out run_branch run_head status outcome run_full expected_full
  RUN_KIND=none
  RUN_ID=""
  RUN_OUTCOME=""
  RUN_REASON=""
  wt=$(record_field "$rec" worktree)
  branch=$(record_field "$rec" branch)
  expected=$(record_field "$rec" expected_head)
  if ! out=$(run_bounded "$wt" axi status); then
    RUN_KIND=ambiguous; RUN_REASON="no-mistakes status read failed"; return
  fi
  case "$out" in *"error:"*) RUN_KIND=none; return ;; esac
  run_branch=$(toon_field "$out" branch)
  [ -n "$run_branch" ] || { RUN_KIND=none; return; }
  [ "$run_branch" = "$branch" ] || { RUN_KIND=none; return; }
  run_head=$(toon_field "$out" head)
  [ -n "$run_head" ] || { RUN_KIND=ambiguous; RUN_REASON="matching run has no head identity"; return; }
  outcome=$(toon_field "$out" outcome)
  status=$(toon_field "$out" status)
  expected_full=$(git -C "$wt" rev-parse --verify "${expected}^{commit}" 2>/dev/null || true)
  run_full=$(git -C "$wt" rev-parse --verify "${run_head}^{commit}" 2>/dev/null || true)
  if [ -z "$expected_full" ] || [ -z "$run_full" ] || ! git -C "$wt" merge-base --is-ancestor "$expected_full" "$run_full" 2>/dev/null; then
    case "$outcome:$status" in
      checks-passed:*|passed:*|failed:*|cancelled:*|*:completed|*:failed|*:cancelled)
        # A historical terminal result on an older tip of the reused branch is
        # not this request's run and does not own current certification custody.
        RUN_KIND=none
        ;;
      *)
        RUN_KIND=ambiguous
        RUN_REASON="matching active branch run does not descend from expected head $expected"
        ;;
    esac
    return
  fi
  RUN_ID=$(toon_field "$out" id)
  case "$outcome" in checks-passed|passed|failed|cancelled)
    RUN_KIND=terminal; RUN_OUTCOME=$outcome; return ;;
  esac
  case "$status" in completed) RUN_KIND=terminal; RUN_OUTCOME=passed; return ;; failed|cancelled) RUN_KIND=terminal; RUN_OUTCOME=$status; return ;; esac
  RUN_KIND=active
}

notify_record() {
  local rec=$1 home task token fm_root message qhome qroot qtask qtoken
  [ "$(record_field "$rec" notification)" = pending ] || return 0
  home=$(record_field "$rec" home)
  task=$(record_field "$rec" task)
  token=$(record_field "$rec" token)
  # Mark before delivery. A crash can lose a notification, but can never submit a
  # duplicate start instruction. retry is an explicit recovery for failed/unknown delivery.
  record_write "$rec" "$(record_field "$rec" state)" sending "$(record_field "$rec" run_id)" "$(record_field "$rec" outcome)" "notification delivery in progress"
  fm_root="$home"
  [ -x "$fm_root/bin/fm-certification.sh" ] || fm_root="$FM_ROOT"
  qhome=$(shell_quote "$home")
  qroot=$(shell_quote "$fm_root/bin/fm-certification.sh")
  qtask=$(shell_quote "$task")
  qtoken=$(shell_quote "$token")
  message="Certification slot admitted for $task. Run exactly: FM_HOME=$qhome $qroot start $qtask $qtoken"
  if FM_HOME="$home" "$SEND_BIN" "$task" "$message"; then
    record_write "$rec" "$(record_field "$rec" state)" sent "$(record_field "$rec" run_id)" "$(record_field "$rec" outcome)" ""
    echo "certification admitted: $task at $(record_field "$rec" expected_head)"
    return 0
  fi
  record_write "$rec" "$(record_field "$rec" state)" failed "$(record_field "$rec" run_id)" "$(record_field "$rec" outcome)" "worker notification failed; inspect delivery before retrying"
  echo "certification notification failed: $task; inspect delivery before 'fm-certification.sh retry $task'" >&2
  return 1
}

reconcile_locked() { # <notify 0|1>
  local do_notify=$1 rec st notification live rc=0
  # Records with an unsupported version or malformed schema never establish
  # capacity or ownership: quarantine them before any accounting loop runs.
  quarantine_sweep || rc=1
  # Terminal reconciliation is authoritative only for records that reached the
  # worker-side start command. Merely admitted work holds its slot until then.
  for rec in "$QUEUE"/*.record; do
    [ -f "$rec" ] || continue
    st=$(record_field "$rec" state)
    case "$st" in launching|running)
      inspect_record_run "$rec"
      case "$RUN_KIND" in
        terminal)
          record_write "$rec" terminal "$(record_field "$rec" notification)" "$RUN_ID" "$RUN_OUTCOME" ""
          rm -f "${rec%.record}.intent" 2>/dev/null || true
          echo "certification terminal: $(record_field "$rec" task) outcome=$RUN_OUTCOME"
          ;;
        active)
          record_write "$rec" running "$(record_field "$rec" notification)" "$RUN_ID" "" ""
          ;;
        ambiguous)
          record_write "$rec" "$st" "$(record_field "$rec" notification)" "$(record_field "$rec" run_id)" "" "$RUN_REASON"
          echo "certification ownership ambiguous: $(record_field "$rec" task): $RUN_REASON" >&2
          rc=1
          ;;
        none)
          # Launch custody was recorded but no matching run is visible. Within the
          # bounded launch grace this is an ordinary run still registering, so the
          # slot is retained silently. Past the grace a worker likely crashed
          # between claiming the slot and no-mistakes starting: retain the slot
          # (never auto-relaunch) but surface the stall so session-start/watch
          # reconciliation prompts an explicit retry or withdraw.
          if within_launch_grace "$(record_field "$rec" launched_at)"; then
            :
          else
            record_write "$rec" "$st" "$(record_field "$rec" notification)" "$(record_field "$rec" run_id)" "" "launch custody holds a slot but no matching no-mistakes run is visible after the launch grace; inspect then retry or withdraw"
            echo "certification launch stalled: $(record_field "$rec" task): no matching run visible after ${LAUNCH_GRACE}s grace; inspect then retry or withdraw" >&2
            rc=1
          fi
          ;;
      esac
      ;;
  esac
  done

  live=$(live_count)
  for rec in "$QUEUE"/*.record; do
    [ -f "$rec" ] || continue
    [ "$live" -lt "$CAPACITY_REQUESTED" ] || break
    [ "$(record_field "$rec" state)" = queued ] || continue
    if preflight "$rec" 0; then
      record_write "$rec" admitted pending "" "" ""
      live=$((live + 1))
    else
      record_write "$rec" blocked none "" "" "$PREFLIGHT_REASON"
      echo "certification blocked: $(record_field "$rec" task): $PREFLIGHT_REASON" >&2
      rc=1
    fi
  done

  if [ "$do_notify" = 1 ]; then
    for rec in "$QUEUE"/*.record; do
      [ -f "$rec" ] || continue
      [ "$(record_field "$rec" state)" = admitted ] || continue
      notification=$(record_field "$rec" notification)
      [ "$notification" = pending ] || continue
      notify_record "$rec" || rc=1
    done
  fi

  retention_sweep
  return "$rc"
}

command_enqueue() {
  local task=${1:-} expected=${2:-} intent_file="" meta project wt branch actual seq token rec tmp intent_dst existing
  shift 2 || true
  [ "${1:-}" = --intent-file ] && [ -n "${2:-}" ] && [ $# -eq 2 ] || usage_die "enqueue requires --intent-file <path>"
  intent_file=$2
  valid_task_id "$task" || usage_die "invalid task id '$task'"
  valid_head "$expected" || usage_die "expected head must be a full 40-character commit id"
  [ -f "$intent_file" ] && [ ! -L "$intent_file" ] && [ -s "$intent_file" ] || die "intent file must be a non-empty regular file: $intent_file"
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "task metadata missing or ambiguous: $meta"
  project=$(meta_value "$meta" project)
  wt=$(meta_value "$meta" worktree)
  [ -n "$project" ] && [ -n "$wt" ] || die "task metadata lacks project/worktree for $task"
  [ "$(meta_value "$meta" kind)" = ship ] || die "task $task is not a ship task; final certification admits only ship tasks"
  [ "$(meta_value "$meta" mode)" = no-mistakes ] || die "task $task delivery mode is $(meta_value "$meta" mode); final certification admits only no-mistakes delivery, never direct-PR or local-only"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || die "detached HEAD in $wt; attach the intended task branch before enqueueing certification"
  if ! { single_line_value "$FM_HOME" && single_line_value "$project" \
    && single_line_value "$wt" && single_line_value "$branch"; }; then
    die "certification identity paths and branch must be single-line values"
  fi
  actual=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  [ "$actual" = "$expected" ] || die "expected head $expected does not match task head ${actual:-unknown}"
  lock_acquire
  capacity_ensure
  quarantine_sweep || true
  existing=$(record_for_task "$task" "$FM_HOME" || true)
  if [ -n "$existing" ]; then
    [ "$(record_field "$existing" expected_head)" = "$expected" ] || die "task $task already has a certification request for a different expected head"
    echo "certification already recorded: $task state=$(record_field "$existing" state)"
    reconcile_locked 1
    lock_release
    return
  fi
  seq=$(next_sequence)
  token=$( (command -v sha256sum >/dev/null 2>&1 && printf '%s:%s:%s:%s' "$FM_HOME" "$task" "$expected" "$(date +%s%N)" | sha256sum | cut -c1-24) || (printf '%s%s' "$(date +%s)" "$$") )
  rec="$QUEUE/$seq-$task.record"
  intent_dst="$QUEUE/$seq-$task.intent"
  tmp=$(mktemp "$QUEUE/.intent.XXXXXX") || die "cannot create certification intent"
  cp "$intent_file" "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$intent_dst"
  tmp=$(mktemp "$QUEUE/.record.XXXXXX") || die "cannot create certification record"
  {
    printf 'version=1\nsequence=%s\ntask=%s\nhome=%s\nproject=%s\nworktree=%s\nbranch=%s\nexpected_head=%s\ntoken=%s\nstate=queued\nnotification=none\nrun_id=\noutcome=\nreason=\nlaunched_at=\n' \
      "$seq" "$task" "$FM_HOME" "$project" "$wt" "$branch" "$expected" "$token"
  } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$rec"
  reconcile_locked 1
  lock_release
}

command_reconcile() {
  local notify=0
  case "${1:-}" in '') ;; --notify) notify=1 ;; *) usage_die "reconcile accepts only --notify" ;; esac
  [ $# -le 1 ] || usage_die "reconcile accepts only --notify"
  # A home with no certification ledger stays byte-for-byte inert. This keeps
  # ordinary watcher and session-start reconciliation from creating feature state.
  [ -d "$QUEUE" ] || return 0
  lock_acquire
  capacity_ensure
  reconcile_locked "$notify"
  lock_release
}

command_start() {
  local task=${1:-} token=${2:-} rec state wt expected intent_file expected_branch actual_branch active=0
  [ $# -eq 2 ] || usage_die "start requires <task-id> <admission-token>"
  valid_task_id "$task" || usage_die "invalid task id '$task'"
  lock_acquire
  capacity_ensure
  quarantine_sweep || true
  rec=$(record_for_task "$task" "$FM_HOME" || true)
  [ -n "$rec" ] || die "no certification request for task $task in FM_HOME $FM_HOME"
  [ "$(record_field "$rec" token)" = "$token" ] || die "admission token does not match task $task"
  state=$(record_field "$rec" state)
  case "$state" in admitted|launching|running) ;; *) die "task $task is not admitted (state=$state)" ;; esac
  if [ "$state" = admitted ]; then
    if ! preflight "$rec" 1; then
      record_write "$rec" blocked "$(record_field "$rec" notification)" "$(record_field "$rec" run_id)" "" "$PREFLIGHT_REASON"
      die "$PREFLIGHT_REASON"
    fi
  else
    # Reattachment may follow pipeline fix commits, so exact-head and clean-copy
    # checks no longer apply. The attached admitted branch still does.
    wt=$(record_field "$rec" worktree)
    expected_branch=$(record_field "$rec" branch)
    actual_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ -n "$actual_branch" ] || die "detached HEAD in $wt; refusing certification reattachment"
    [ "$actual_branch" = "$expected_branch" ] || die "wrong branch in $wt: expected $expected_branch, found $actual_branch"
  fi
  inspect_record_run "$rec"
  case "$RUN_KIND" in
    terminal) die "task $task already has authoritative terminal outcome $RUN_OUTCOME" ;;
    ambiguous) die "$RUN_REASON" ;;
    active) active=1 ;;
    none)
      if [ "$state" != admitted ]; then
        die "task $task launch was already claimed but no matching run is visible; inspect before an explicit retry"
      fi
      ;;
  esac
  record_write "$rec" launching sent "$RUN_ID" "" "" "$(now_epoch)"
  wt=$(record_field "$rec" worktree)
  expected=$(record_field "$rec" expected_head)
  intent_file="${rec%.record}.intent"
  [ -s "$intent_file" ] || die "stored certification intent is missing for $task"
  lock_release
  if [ "${FM_CERT_NO_EXEC:-0}" = 1 ]; then
    printf 'would exec in %s at %s: %s axi run --intent <stored-intent> (reattach=%s)\n' "$wt" "$expected" "$NM_BIN" "$active"
    return
  fi
  cd "$wt"
  exec "$NM_BIN" axi run --intent "$(cat "$intent_file")"
}

command_retry() {
  local task=${1:-} rec state
  [ $# -eq 1 ] || usage_die "retry requires <task-id>"
  lock_acquire
  capacity_ensure
  quarantine_sweep || true
  rec=$(record_for_task "$task" "$FM_HOME" || true)
  [ -n "$rec" ] || die "no certification request for task $task"
  state=$(record_field "$rec" state)
  case "$state" in blocked)
    record_write "$rec" queued none "" "" ""
    ;;
  admitted)
    case "$(record_field "$rec" notification)" in failed|sending)
      record_write "$rec" admitted pending "$(record_field "$rec" run_id)" "" ""
      ;;
    *) die "task $task has no retryable notification" ;;
    esac
    ;;
  launching|running)
    inspect_record_run "$rec"
    case "$RUN_KIND" in
      none) record_write "$rec" admitted pending "" "" "" ;;
      active) die "task $task already has a matching active run; use its token-bound start command only to reattach" ;;
      terminal) die "task $task already has authoritative terminal outcome $RUN_OUTCOME; reconcile instead" ;;
      ambiguous) die "$RUN_REASON" ;;
    esac
    ;;
  *) die "task $task is not retryable (state=$state)" ;;
  esac
  reconcile_locked 1
  lock_release
}

command_withdraw() {
  local task=${1:-} rec state base
  [ $# -eq 1 ] || usage_die "withdraw requires <task-id>"
  valid_task_id "$task" || usage_die "invalid task id '$task'"
  lock_acquire
  capacity_ensure
  quarantine_sweep || true
  rec=$(record_for_task "$task" "$FM_HOME" || true)
  [ -n "$rec" ] || die "no certification request for task $task"
  state=$(record_field "$rec" state)
  # Withdrawal abandons a request and frees its slot. It never cancels an
  # in-flight No Mistakes run: a matching active or terminal run stays under the
  # worker's gate authority, so those are refused. A launch inside its grace
  # window may still be registering its run, so withdrawal waits rather than
  # freeing the slot into an uncoordinated double run.
  case "$state" in launching|running)
    inspect_record_run "$rec"
    case "$RUN_KIND" in
      active) die "task $task has a matching active no-mistakes run; withdrawal cannot cancel it — the worker owns that gate" ;;
      terminal) die "task $task already has authoritative terminal outcome $RUN_OUTCOME; reconcile instead of withdrawing" ;;
      ambiguous) die "$RUN_REASON" ;;
      none)
        if within_launch_grace "$(record_field "$rec" launched_at)"; then
          die "task $task launched within the last ${LAUNCH_GRACE}s and its run may still be registering; wait for the launch grace to elapse before withdrawing to avoid an uncoordinated double run"
        fi
        ;;
    esac
    ;;
  esac
  base=$(basename "$rec" .record)
  mv "$rec" "$WITHDRAWN/$base.record" 2>/dev/null || die "cannot archive withdrawn record for $task"
  [ ! -f "$QUEUE/$base.intent" ] || mv "$QUEUE/$base.intent" "$WITHDRAWN/$base.intent" 2>/dev/null || true
  echo "certification withdrawn: $task (was $state); re-enqueue with a fresh expected head to resubmit"
  reconcile_locked 1
  lock_release
}

command_status() {
  local rec
  if [ ! -d "$QUEUE" ]; then
    printf 'capacity=uninitialized\n(no certification requests)\n'
    return
  fi
  printf 'capacity=%s\n' "$(cat "$CERT_ROOT/capacity" 2>/dev/null || printf 'uninitialized')"
  for rec in "$QUEUE"/*.record; do
    [ -f "$rec" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(record_field "$rec" sequence)" "$(record_field "$rec" state)" \
      "$(record_field "$rec" task)" "$(record_field "$rec" branch)" \
      "$(record_field "$rec" expected_head)" "$(record_field "$rec" reason)"
  done
}

cmd=${1:-}
[ -n "$cmd" ] || usage_die "missing command"
shift
case "$cmd" in
  -h|--help|help) usage ;;
  enqueue) command_enqueue "$@" ;;
  reconcile) command_reconcile "$@" ;;
  start) command_start "$@" ;;
  retry) command_retry "$@" ;;
  withdraw) command_withdraw "$@" ;;
  status) command_status "$@" ;;
  *) usage_die "unknown command '$cmd'" ;;
esac
