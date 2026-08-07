#!/usr/bin/env bash
# Continuous Operations helper.
#
# This file is the single owner of the durable "ready backlog work + idle
# capacity" marker. GitHub discovery and queue admission are owned by
# bin/fm-continuous-ops-github.sh, which may materialize proven Ready issues
# into the local tasks-axi backlog before this helper evaluates the configured
# backend's own `ready` answer. This helper deliberately does not select tasks,
# route work, spawn workers, or decide authority. It compares ready backlog work
# with the standing capacity limits, writes or clears one home-local marker, and
# queues one deduplicated actionable wake when a new ready transition needs
# supervisor action.
# It also owns the effective-metadata filter used by supervision counters:
# when multiple metadata rows point at one reused worktree, and that worktree's
# current branch matches exactly one sibling task id, older duplicate rows are
# stale runtime bindings for counting purposes only.
# Usage:
#   . bin/fm-continuous-ops-lib.sh
#   fm_continuous_ops_refresh <reason>
#   fm_continuous_ops_reconcile_existing
#   fm_continuous_ops_print_section

FM_CONTINUOUS_OPS_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_CONTINUOUS_OPS_DIR="$(cd "$(dirname "$FM_CONTINUOUS_OPS_SCRIPT")" && pwd)"
unset FM_CONTINUOUS_OPS_SCRIPT
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$FM_CONTINUOUS_OPS_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
DATA="${FM_DATA_OVERRIDE:-${DATA:-$FM_HOME/data}}"
CONFIG="${FM_CONFIG_OVERRIDE:-${CONFIG:-$FM_HOME/config}}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$FM_CONTINUOUS_OPS_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_CONTINUOUS_OPS_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_CONTINUOUS_OPS_DIR/fm-classify-lib.sh"

FM_CONTINUOUS_OPS_MARKER="${FM_CONTINUOUS_OPS_MARKER:-$STATE/.continuous-ops-ready}"
FM_CONTINUOUS_OPS_MARKER_LOCK="${FM_CONTINUOUS_OPS_MARKER_LOCK:-$STATE/.continuous-ops-ready.lock}"
FM_CONTINUOUS_OPS_WAKE_KIND=check
FM_CONTINUOUS_OPS_WAKE_KEY=continuous-ops-ready
FM_CONTINUOUS_OPS_WORKER_LIMIT=${FM_CONTINUOUS_OPS_WORKER_LIMIT:-6}
FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT=${FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT:-2}
FM_CONTINUOUS_OPS_CREW_STATE_BIN="${FM_CONTINUOUS_OPS_CREW_STATE_BIN:-$FM_CONTINUOUS_OPS_DIR/fm-crew-state.sh}"
FM_CONTINUOUS_OPS_GITHUB_BIN="${FM_CONTINUOUS_OPS_GITHUB_BIN:-$FM_CONTINUOUS_OPS_DIR/fm-continuous-ops-github.sh}"
FM_CONTINUOUS_OPS_GITHUB_STATUS="${FM_CONTINUOUS_OPS_GITHUB_STATUS:-$STATE/.continuous-ops-github.status}"

case "$FM_CONTINUOUS_OPS_WORKER_LIMIT" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_WORKER_LIMIT=6 ;; esac
case "$FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT=2 ;; esac

FM_CONTINUOUS_OPS_READY_COUNT=0
FM_CONTINUOUS_OPS_READY_IDS=
FM_CONTINUOUS_OPS_READY_SIGNATURE=
FM_CONTINUOUS_OPS_WORKERS=0
FM_CONTINUOUS_OPS_LOCAL_CERT_ACTIVE=0
FM_CONTINUOUS_OPS_WORKER_IDLE=false
FM_CONTINUOUS_OPS_PAYLOAD=

fm_continuous_ops_github_status_get() {  # <key> [state-dir]
  local key=$1 status
  status="${2:-$STATE}/.continuous-ops-github.status"
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  grep "^$key=" "$status" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_continuous_ops_github_refresh() {  # <reason>
  local reason=$1
  [ "${FM_CONTINUOUS_OPS_GITHUB_DISABLE:-0}" != 1 ] || return 0
  [ -x "$FM_CONTINUOUS_OPS_GITHUB_BIN" ] || return 0
  if [ "${FM_CONTINUOUS_OPS_GITHUB_FORCE:-0}" = 1 ]; then
    "$FM_CONTINUOUS_OPS_GITHUB_BIN" refresh --force --reason "$reason" >/dev/null 2>&1
  else
    "$FM_CONTINUOUS_OPS_GITHUB_BIN" refresh --reason "$reason" >/dev/null 2>&1
  fi
}

fm_continuous_ops_meta_get() {  # <meta> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  grep "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_continuous_ops_branch_matches_id() {  # <branch> <id>
  local branch=$1 id=$2
  [ -n "$branch" ] && [ -n "$id" ] || return 1
  [ "$branch" = "$id" ] || [ "$branch" = "fm/$id" ]
}

fm_continuous_ops_worktree_branch() {  # <worktree>
  command -v git >/dev/null 2>&1 || return 1
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null
}

fm_continuous_ops_meta_is_stale_reused_worktree() {  # <meta> [state-dir]
  local meta=$1 state=${2:-$STATE} worktree branch id peer peer_worktree peer_id has_peer=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  worktree=$(fm_continuous_ops_meta_get "$meta" worktree)
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  for peer in "$state"/*.meta; do
    [ -f "$peer" ] && [ ! -L "$peer" ] || continue
    [ "$peer" != "$meta" ] || continue
    peer_worktree=$(fm_continuous_ops_meta_get "$peer" worktree)
    if [ "$peer_worktree" = "$worktree" ]; then
      has_peer=1
      break
    fi
  done
  [ "$has_peer" -eq 1 ] || return 1
  branch=$(fm_continuous_ops_worktree_branch "$worktree" || true)
  [ -n "$branch" ] || return 1
  id=$(basename "$meta" .meta)
  if fm_continuous_ops_branch_matches_id "$branch" "$id"; then
    return 1
  fi
  for peer in "$state"/*.meta; do
    [ -f "$peer" ] && [ ! -L "$peer" ] || continue
    [ "$peer" != "$meta" ] || continue
    peer_worktree=$(fm_continuous_ops_meta_get "$peer" worktree)
    [ "$peer_worktree" = "$worktree" ] || continue
    peer_id=$(basename "$peer" .meta)
    if fm_continuous_ops_branch_matches_id "$branch" "$peer_id"; then
      return 0
    fi
  done
  return 1
}

fm_continuous_ops_reused_worktree_branch_owner_meta() {  # <meta> [state-dir]
  local meta=$1 state=${2:-$STATE} worktree branch peer peer_worktree peer_id
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  worktree=$(fm_continuous_ops_meta_get "$meta" worktree)
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  branch=$(fm_continuous_ops_worktree_branch "$worktree" || true)
  [ -n "$branch" ] || return 1
  for peer in "$state"/*.meta; do
    [ -f "$peer" ] && [ ! -L "$peer" ] || continue
    [ "$peer" != "$meta" ] || continue
    peer_worktree=$(fm_continuous_ops_meta_get "$peer" worktree)
    [ "$peer_worktree" = "$worktree" ] || continue
    peer_id=$(basename "$peer" .meta)
    if fm_continuous_ops_branch_matches_id "$branch" "$peer_id"; then
      printf '%s\n' "$peer"
      return 0
    fi
  done
  return 1
}

fm_continuous_ops_marker_path() {  # [state-dir]
  local state=${1:-$STATE}
  printf '%s/.continuous-ops-ready\n' "$state"
}

fm_continuous_ops_marker_exists() {  # [state-dir]
  local marker
  marker=$(fm_continuous_ops_marker_path "${1:-$STATE}")
  [ -f "$marker" ] && [ ! -L "$marker" ]
}

fm_continuous_ops_marker_get() {  # <key> [state-dir]
  local key=$1 marker
  marker=$(fm_continuous_ops_marker_path "${2:-$STATE}")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  grep "^$key=" "$marker" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_continuous_ops_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

fm_continuous_ops_join_ids() {  # <newline-separated-ids> [limit]
  local ids=$1 limit=${2:-5}
  awk -v limit="$limit" '
    NF {
      total++
      if (shown < limit) {
        if (out != "") out = out ","
        out = out $1
        shown++
      }
    }
    END {
      if (total > shown) out = out ",+" (total - shown) " more"
      print out
    }
  ' <<EOF
$ids
EOF
}

fm_continuous_ops_ready_signature() {  # <count> <newline-separated-ids>
  local count=$1 ids=$2
  {
    printf 'count=%s\n' "$count"
    printf '%s\n' "$ids"
  } | cksum | awk '{ print $1 ":" $2 }'
}

fm_continuous_ops_parse_ready_count() {  # <ready-output>
  local output=$1 count rows
  count=$(printf '%s\n' "$output" |
    awk -F ':' '/^count:[[:space:]]*[0-9]+[[:space:]]*$/ {
      gsub(/[[:space:]]/, "", $2)
      print $2
      exit
    }')
  case "$count" in ''|*[!0-9]*) count= ;; esac
  if [ -n "$count" ]; then
    printf '%s\n' "$count"
    return 0
  fi
  rows=$(fm_continuous_ops_parse_ready_ids "$output" | awk 'NF { count++ } END { print count + 0 }')
  printf '%s\n' "$rows"
}

fm_continuous_ops_parse_ready_ids() {  # <ready-output>
  local output=$1
  printf '%s\n' "$output" | awk '
    /^help\[/ { exit }
    /^ready\[[0-9]+\]/ { rows = 1; next }
    rows && /^[[:space:]]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      id = line
      sub(/,.*/, "", id)
      if (id != "") print id
      next
    }
    rows && NF && $0 !~ /^[[:space:]]/ { rows = 0 }
  '
}

fm_continuous_ops_read_ready() {
  local backlog="$DATA/backlog.md" ready count ids
  FM_CONTINUOUS_OPS_READY_COUNT=0
  FM_CONTINUOUS_OPS_READY_IDS=
  FM_CONTINUOUS_OPS_READY_SIGNATURE=

  [ -f "$backlog" ] || return 0
  fm_tasks_axi_backend_available "$CONFIG" || return 3
  ready=$(tasks-axi ready --file "$backlog" 2>&1) || {
    return 1
  }
  count=$(fm_continuous_ops_parse_ready_count "$ready")
  ids=$(fm_continuous_ops_parse_ready_ids "$ready")
  FM_CONTINUOUS_OPS_READY_COUNT=$count
  FM_CONTINUOUS_OPS_READY_IDS=$ids
  FM_CONTINUOUS_OPS_READY_SIGNATURE=$(fm_continuous_ops_ready_signature "$count" "$ids")
  return 0
}

fm_continuous_ops_state_counts_local_cert() {  # <fm-crew-state line>
  local line=$1
  case "$line" in
    state:\ working*"source: run-step"*) ;;
    *) return 1 ;;
  esac
  case "$line" in
    *"waiting for hosted CI checks"*|*"checks green"*|*"PR ready for review"*|*"ci running"*) return 1 ;;
  esac
  return 0
}

fm_continuous_ops_status_last_line() {  # <status-log>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

fm_continuous_ops_status_proves_inactive_worker() {  # <status-line>
  local line=$1 verb
  [ -n "$line" ] || return 1
  status_is_paused "$line" && return 0
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|failed|blocked|needs-decision|captain-held) return 0 ;;
  esac
  return 1
}

fm_continuous_ops_state_proves_missing_worker() {  # <fm-crew-state line>
  local line=$1
  case "$line" in
    *"worktree gone"*|*"backend target gone"*|*"no metadata for "*|*"no backend target recorded"*|*"unknown missing"*)
      return 0
      ;;
  esac
  return 1
}

fm_continuous_ops_state_counts_active_worker() {  # <fm-crew-state line> <status-log>
  local line=$1 status_log=$2 state status_line
  case "$line" in
    state:\ working*) return 0 ;;
    state:\ done*|state:\ blocked*|state:\ paused*|state:\ failed*|state:\ parked*) return 1 ;;
  esac

  # Unknown current-state evidence is conservative, except when the current read
  # or the latest event proves historical ownership rather than active work.
  if fm_continuous_ops_state_proves_missing_worker "$line"; then
    return 1
  fi
  status_line=$(fm_continuous_ops_status_last_line "$status_log" || true)
  if fm_continuous_ops_status_proves_inactive_worker "$status_line"; then
    return 1
  fi

  state=${line#state: }
  state=${state%% *}
  [ -z "$line" ] || [ "$state" = unknown ]
}

fm_continuous_ops_state_is_working_worker() {  # <fm-crew-state line>
  case "$1" in
    state:\ working*) return 0 ;;
  esac
  return 1
}

fm_continuous_ops_stale_reused_branch_owner_active() {  # <stale-meta> <state-dir>
  local meta=$1 state=${2:-$STATE} owner owner_id owner_kind owner_line owner_status
  owner=$(fm_continuous_ops_reused_worktree_branch_owner_meta "$meta" "$state") || return 1
  owner_id=$(basename "$owner" .meta)
  owner_kind=$(fm_continuous_ops_meta_get "$owner" kind)
  [ -n "$owner_kind" ] || owner_kind=ship
  [ "$owner_kind" = secondmate ] && return 1
  owner_status="$state/$owner_id.status"
  owner_line=$("$FM_CONTINUOUS_OPS_CREW_STATE_BIN" "$owner_id" 2>/dev/null || true)
  fm_continuous_ops_state_counts_active_worker "$owner_line" "$owner_status"
}

fm_continuous_ops_capacity_read() {
  local meta id kind mode line status_log
  FM_CONTINUOUS_OPS_WORKERS=0
  FM_CONTINUOUS_OPS_LOCAL_CERT_ACTIVE=0
  FM_CONTINUOUS_OPS_WORKER_IDLE=false

  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    kind=$(fm_continuous_ops_meta_get "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = secondmate ] && continue
    id=$(basename "$meta" .meta)
    status_log="$STATE/$id.status"
    line=$("$FM_CONTINUOUS_OPS_CREW_STATE_BIN" "$id" 2>/dev/null || true)
    if fm_continuous_ops_meta_is_stale_reused_worktree "$meta" "$STATE"; then
      fm_continuous_ops_state_is_working_worker "$line" || continue
      fm_continuous_ops_stale_reused_branch_owner_active "$meta" "$STATE" && continue
    fi
    fm_continuous_ops_state_counts_active_worker "$line" "$status_log" || continue
    FM_CONTINUOUS_OPS_WORKERS=$((FM_CONTINUOUS_OPS_WORKERS + 1))
    mode=$(fm_continuous_ops_meta_get "$meta" mode)
    if [ "$kind" = ship ] && [ "$mode" = no-mistakes ]; then
      if fm_continuous_ops_state_counts_local_cert "$line"; then
        FM_CONTINUOUS_OPS_LOCAL_CERT_ACTIVE=$((FM_CONTINUOUS_OPS_LOCAL_CERT_ACTIVE + 1))
      fi
    fi
  done

  [ "$FM_CONTINUOUS_OPS_WORKERS" -lt "$FM_CONTINUOUS_OPS_WORKER_LIMIT" ] \
    && FM_CONTINUOUS_OPS_WORKER_IDLE=true
}

fm_continuous_ops_capacity_idle() {
  [ "$FM_CONTINUOUS_OPS_WORKER_IDLE" = true ]
}

fm_continuous_ops_payload() {
  local ids
  ids=$(fm_continuous_ops_join_ids "$FM_CONTINUOUS_OPS_READY_IDS" 5)
  [ -n "$ids" ] || ids="ready set"
  printf 'continuous-ops: approved ready work exists (%s item(s): %s); active workers=%s/%s local certification=%s/%s; select and dispatch the next eligible work under existing project, secondmate, delivery-mode, profile, and authority contracts, or record the concrete blocker' \
    "$FM_CONTINUOUS_OPS_READY_COUNT" \
    "$ids" \
    "$FM_CONTINUOUS_OPS_WORKERS" \
    "$FM_CONTINUOUS_OPS_WORKER_LIMIT" \
    "$FM_CONTINUOUS_OPS_LOCAL_CERT_ACTIVE" \
    "$FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT"
}

fm_continuous_ops_clear_marker() {
  fm_lock_acquire_wait "$FM_CONTINUOUS_OPS_MARKER_LOCK"
  rm -f "$FM_CONTINUOUS_OPS_MARKER" 2>/dev/null || true
  fm_lock_release "$FM_CONTINUOUS_OPS_MARKER_LOCK"
}

fm_continuous_ops_write_marker() {  # <reason>
  local reason=${1:-refresh} tmp now ids
  now=$(fm_continuous_ops_now)
  ids=$(fm_continuous_ops_join_ids "$FM_CONTINUOUS_OPS_READY_IDS" 20)
  tmp="$STATE/.continuous-ops-ready.tmp.$(fm_current_pid)"
  fm_lock_acquire_wait "$FM_CONTINUOUS_OPS_MARKER_LOCK"
  {
    printf 'version=1\n'
    printf 'updated_at=%s\n' "$now"
    printf 'reason=%s\n' "$reason"
    printf 'ready_signature=%s\n' "$FM_CONTINUOUS_OPS_READY_SIGNATURE"
    printf 'ready_count=%s\n' "$FM_CONTINUOUS_OPS_READY_COUNT"
    printf 'ready_items=%s\n' "$ids"
    printf 'active_workers=%s\n' "$FM_CONTINUOUS_OPS_WORKERS"
    printf 'active_worker_limit=%s\n' "$FM_CONTINUOUS_OPS_WORKER_LIMIT"
    printf 'local_cert_active=%s\n' "$FM_CONTINUOUS_OPS_LOCAL_CERT_ACTIVE"
    printf 'local_cert_limit=%s\n' "$FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT"
    printf 'payload=%s\n' "$FM_CONTINUOUS_OPS_PAYLOAD"
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$FM_CONTINUOUS_OPS_MARKER"
  fm_lock_release "$FM_CONTINUOUS_OPS_MARKER_LOCK"
}

fm_continuous_ops_refresh() {  # [reason]
  local reason=${1:-refresh} existing_sig ready_status
  mkdir -p "$STATE"

  fm_continuous_ops_github_refresh "$reason" || {
    if [ "${FM_CONTINUOUS_OPS_QUIET:-0}" != 1 ]; then
      printf 'Continuous ops: GitHub candidate discovery is unknown; preserving local ready evaluation and inspect %s.\n' "$FM_CONTINUOUS_OPS_GITHUB_STATUS" >&2
    fi
  }

  fm_continuous_ops_read_ready
  ready_status=$?
  case "$ready_status" in
    0) ;;
    3)
      fm_continuous_ops_clear_marker
      return 0
      ;;
    *)
      if [ "${FM_CONTINUOUS_OPS_QUIET:-0}" != 1 ]; then
        printf 'Continuous ops: tasks-axi ready failed; preserving any existing marker until readiness can be evaluated.\n' >&2
      fi
      return 1
      ;;
  esac
  if [ "$FM_CONTINUOUS_OPS_READY_COUNT" -le 0 ]; then
    fm_continuous_ops_clear_marker
    return 0
  fi

  fm_continuous_ops_capacity_read
  if ! fm_continuous_ops_capacity_idle; then
    fm_continuous_ops_clear_marker
    return 0
  fi

  FM_CONTINUOUS_OPS_PAYLOAD=$(fm_continuous_ops_payload)
  existing_sig=$(fm_continuous_ops_marker_get ready_signature)
  fm_continuous_ops_write_marker "$reason"
  if [ "$existing_sig" != "$FM_CONTINUOUS_OPS_READY_SIGNATURE" ]; then
    fm_wake_append "$FM_CONTINUOUS_OPS_WAKE_KIND" "$FM_CONTINUOUS_OPS_WAKE_KEY" "$FM_CONTINUOUS_OPS_PAYLOAD"
    if [ "${FM_CONTINUOUS_OPS_QUIET:-0}" != 1 ]; then
      printf 'Continuous ops: queued one dispatch notification for %s ready item(s).\n' "$FM_CONTINUOUS_OPS_READY_COUNT"
    fi
  fi
  return 0
}

fm_continuous_ops_refresh_quiet() {  # [reason]
  FM_CONTINUOUS_OPS_QUIET=1 fm_continuous_ops_refresh "$@"
}

fm_continuous_ops_reconcile_existing() {
  fm_continuous_ops_marker_exists "$STATE" || return 0
  fm_continuous_ops_refresh_quiet "reconcile"
}

fm_continuous_ops_print_section() {
  local count items workers worker_limit cert cert_limit payload gh_state gh_reason gh_ready gh_unknown gh_ledger
  local worker_has_capacity=unknown
  if ! fm_continuous_ops_marker_exists "$STATE"; then
    gh_state=$(fm_continuous_ops_github_status_get state "$STATE")
    case "$gh_state" in
      unknown)
        gh_reason=$(fm_continuous_ops_github_status_get reason "$STATE")
        gh_ready=$(fm_continuous_ops_github_status_get ready "$STATE")
        gh_unknown=$(fm_continuous_ops_github_status_get unknown "$STATE")
        gh_ledger=$(fm_continuous_ops_github_status_get ledger "$STATE")
        printf 'CONTINUOUS OPS (GitHub candidate discovery):\n'
        printf 'eligibility: unknown'
        [ -n "$gh_reason" ] && printf ' (%s)' "$gh_reason"
        printf '\n'
        printf 'ready: %s item(s), unknown: %s candidate(s)\n' "${gh_ready:-0}" "${gh_unknown:-0}"
        [ -n "$gh_ledger" ] && printf 'ledger: %s\n' "$gh_ledger"
        return 0
        ;;
    esac
    return 1
  fi
  count=$(fm_continuous_ops_marker_get ready_count)
  items=$(fm_continuous_ops_marker_get ready_items)
  workers=$(fm_continuous_ops_marker_get active_workers)
  [ -n "$workers" ] || workers=$(fm_continuous_ops_marker_get ordinary_workers)
  worker_limit=$(fm_continuous_ops_marker_get active_worker_limit)
  [ -n "$worker_limit" ] || worker_limit=$(fm_continuous_ops_marker_get ordinary_worker_limit)
  cert=$(fm_continuous_ops_marker_get local_cert_active)
  cert_limit=$(fm_continuous_ops_marker_get local_cert_limit)
  payload=$(fm_continuous_ops_marker_get payload)
  case "$workers:$worker_limit" in
    *[!0-9]*:*) ;;
    *:*[!0-9]*) ;;
    *:|:*) ;;
    *)
      if [ "$workers" -lt "$worker_limit" ]; then
        worker_has_capacity=true
      else
        worker_has_capacity=false
      fi
      ;;
  esac
  case "$payload" in
    *"idle capacity workers="*)
      payload=$(printf 'continuous-ops: approved ready work exists (%s item(s): %s); active workers=%s/%s local certification=%s/%s; select and dispatch the next eligible work under existing project, secondmate, delivery-mode, profile, and authority contracts, or record the concrete blocker' \
        "${count:-unknown}" "${items:-ready set}" "${workers:-unknown}" "${worker_limit:-$FM_CONTINUOUS_OPS_WORKER_LIMIT}" \
        "${cert:-unknown}" "${cert_limit:-$FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT}")
      ;;
  esac
  printf 'CONTINUOUS OPS (ready backlog work + active-worker capacity):\n'
  printf 'ready: %s item(s)' "${count:-unknown}"
  [ -n "$items" ] && printf ' (%s)' "$items"
  printf '\n'
  printf 'capacity: active workers %s/%s, local certification %s/%s\n' \
    "${workers:-unknown}" "${worker_limit:-$FM_CONTINUOUS_OPS_WORKER_LIMIT}" \
    "${cert:-unknown}" "${cert_limit:-$FM_CONTINUOUS_OPS_LOCAL_CERT_LIMIT}"
  if [ "$worker_has_capacity" = false ]; then
    printf 'action: no dispatch request; active worker limit is full until a refresh proves a worker slot is open.\n'
  elif [ -n "$payload" ]; then
    printf 'action: %s\n' "$payload"
  else
    printf 'action: select and dispatch the next eligible ready work, or record the concrete blocker.\n'
  fi
}
