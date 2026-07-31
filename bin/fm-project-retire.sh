#!/usr/bin/env bash
# fm-project-retire.sh - the single guarded owner of retiring a captain-approved
# out-of-registry project tree: a legacy clone (or a small tree of clones) left
# behind by an earlier layout, plus, optionally, the linked Treehouse pool whose
# slots are worktrees of that tree.
#
# It exists because AGENTS.md hard rule 1 forbids a raw removal command under a
# project tree, and the project-management skill's retirement procedure needs one
# owner that PROVES, before any mutation, that nothing unlanded, still
# referenced, or still in use would be destroyed. Every check below is a refusal
# condition: an inability to prove a condition is a blocker, never a reason to
# proceed.
#
# Scope: out-of-registry trees only. A registered project under this home's
# `projects/` is deliberately out of scope and always refuses here; removing one
# follows the project-management skill's registered-project path under hard
# rule 1's captain-approved project operation exception instead.
#
# Usage:
#   fm-project-retire.sh --root <abs> --boundary <abs> [--boundary <abs>]...
#                        [--pool <abs>] --preflight
#   fm-project-retire.sh --root <abs> --boundary <abs> [--boundary <abs>]...
#                        [--pool <abs>] --execute
#                        --confirm-root <abs> --confirm-plan <plan-id>
#   fm-project-retire.sh --help
#
# Flags:
#   --root <abs>     the retirement root. Must be absolute, normalized (no ".",
#                    "..", "//", or trailing "/"), already canonical, an ordinary
#                    non-symlink directory, and at least three path components
#                    deep. It is NEVER inferred from the current directory, from
#                    data/projects.md, or from any other default.
#   --pool <abs>     the linked legacy Treehouse pool root, when the tree's
#                    worktrees live outside the root. Same path rules as --root,
#                    must be outside --root, and every checkout found under it
#                    must prove it is a worktree of a repository inside --root.
#                    Without --pool, any worktree outside --root is a refusal.
#   --boundary <abs> an operator-approved retirement boundary. Required and
#                    repeatable. Every removal target must be inside (or equal
#                    to) at least one boundary, and no boundary may contain, be,
#                    or sit inside a protected fleet path. Naming the envelope
#                    separately is what turns a typo in --root into a refusal
#                    instead of a deletion.
#   --preflight      run every check, print the bounded removal plan and its plan
#                    id, and remove nothing.
#   --execute        run every check again from scratch and remove exactly the
#                    planned paths.
#   --confirm-root <abs>
#                    must repeat --root byte for byte. Execute only.
#   --confirm-plan <plan-id>
#                    must repeat the plan id printed by --preflight. Execute
#                    only. The plan id is a digest of the inspected evidence, so
#                    any change to that evidence between approval and removal
#                    refuses instead of removing a tree nobody approved.
#
# Refusal conditions (all of them, in this order):
#   - a non-absolute, non-normalized, non-canonical, missing, symlinked,
#     non-directory, or too-shallow root, pool, or boundary;
#   - a root or pool that is, contains, or sits inside the primary firstmate
#     home, the firstmate repository, a registered project, or a registered
#     secondmate home;
#   - a root or pool still named by a path reference in data/projects.md or
#     data/secondmates.md;
#   - a boundary that conflicts with any of those protected paths, or a removal
#     target outside every boundary;
#   - a root or pool still named by any recorded task (worktree=, project=, or
#     home= in this home's or a registered secondmate home's state/<id>.meta);
#   - a live process whose current directory is inside a removal target;
#   - no git checkout under the root at all (this owner retires project trees,
#     not arbitrary directories);
#   - a checkout whose git toplevel does not canonically match its own path, or
#     whose repository lives outside the retirement tree;
#   - any dirty or untracked file in any checkout;
#   - a linked worktree outside the root and the proven pool, any locked
#     worktree, or any stale worktree registration whose path is gone;
#   - a repository with no remote, a remote fetch failure, or no remote-tracking
#     ref after the fetch (incomplete landing evidence);
#   - a remote whose URL resolves to a path inside a removal target, so the
#     landing evidence would not survive the removal that cites it;
#   - an object-store check (`git fsck`) that fails or cannot complete, so the
#     repository's unreachable commits cannot be enumerated;
#   - a local branch, or an unreachable commit, whose work is not proven landed;
#   - any ambiguous git result anywhere above.
#
# Landing proof (a matching commit subject is NEVER proof). In order:
#   1. exact ancestry - the commit is an ancestor of a remote-tracking ref;
#   2. content containment - a three-way merge of a remote-tracking ref with the
#      commit yields that ref's exact tree, so the commit introduces nothing the
#      authoritative merged upstream does not already have (this is how a squash
#      merge or a rewritten history proves out);
#   3. patch equivalence - every commit the work adds over the remote-tracking
#      refs has a patch id that also appears upstream.
# Step 3 scans upstream commits, so it is bounded by FM_RETIRE_PATCH_SCAN_LIMIT
# (default 2000). Exceeding the bound is a refusal with an explicit message, not
# a silent skip; raise the bound deliberately when the evidence needs it.
#
# Repository discovery finds both working checkouts (a `.git` file or directory)
# and standalone repositories with no worktree, so objects that no checkout
# points at are still proven landed before anything is removed. A standalone
# repository is recognised by being its own git common directory, whether it is
# bare or a detached non-bare git directory (a `--separate-git-dir` target, or a
# `.git` directory whose worktree is gone); `core.bare` is never the test.
#
# Evidence freshness: preflight and execute each run one non-pruning
# `git fetch <remote>` per repository so landing evidence is current, and a fetch
# failure refuses. That fetch, plus the throwaway trees `git merge-tree` writes
# while proving containment, are the ONLY writes this owner makes before the
# confirmed removal: both are purely additive, and nothing here ever prunes,
# resets, stashes, forces, checks out, or discards anything.
# Because the fetched remote-tracking refs are part of the plan id, an upstream
# that moves between approval and removal also changes the plan id and refuses;
# re-run --preflight and approve the new plan deliberately.
#
# Live-process coverage: the current-directory check reads FM_RETIRE_PROC_ROOT
# (default /proc) exactly once, testing each process against every removal
# target in that single pass so each process is counted once. Entries this user
# cannot read - other users' processes - are not inspectable; the plan reports
# how many were inspected and how many were not, so the gap is visible rather
# than assumed away.
#
# The mutation is exactly two `rm -rf --` calls on the two canonical paths named
# in the plan, pool first so the authoritative repository survives longest. No
# glob, no recursion into symlinks (`rm -rf` unlinks a symlink, never follows
# it), and no cleanup beyond those two paths. Any removal error stops the run
# immediately and reports precisely what was and was not removed.
#
# Exit codes: 0 success, 1 refusal or removal failure, 2 usage error,
# 3 no-mistakes gate refusal (bin/fm-gate-refuse-lib.sh).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROC_ROOT="${FM_RETIRE_PROC_ROOT:-/proc}"
PATCH_SCAN_LIMIT="${FM_RETIRE_PATCH_SCAN_LIMIT:-2000}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'REFUSED: %s\n' "$1" >&2
  exit 1
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf 'run %s --help for the full contract\n' "$(basename "$0")" >&2
  exit 2
}

# --- argument parsing --------------------------------------------------------

ROOT_ARG=
POOL_ARG=
MODE=
CONFIRM_ROOT=
CONFIRM_PLAN=
BOUNDARY_ARGS=()

require_value() {
  [ "$2" -gt 0 ] || usage_error "$1 needs a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) require_value --root "$(( $# - 1 ))"; [ -z "$ROOT_ARG" ] || usage_error "--root given twice"; ROOT_ARG=$2; shift 2 ;;
    --pool) require_value --pool "$(( $# - 1 ))"; [ -z "$POOL_ARG" ] || usage_error "--pool given twice"; POOL_ARG=$2; shift 2 ;;
    --boundary) require_value --boundary "$(( $# - 1 ))"; BOUNDARY_ARGS+=("$2"); shift 2 ;;
    --confirm-root) require_value --confirm-root "$(( $# - 1 ))"; CONFIRM_ROOT=$2; shift 2 ;;
    --confirm-plan) require_value --confirm-plan "$(( $# - 1 ))"; CONFIRM_PLAN=$2; shift 2 ;;
    --preflight) [ -z "$MODE" ] || usage_error "choose exactly one of --preflight or --execute"; MODE=preflight; shift ;;
    --execute) [ -z "$MODE" ] || usage_error "choose exactly one of --preflight or --execute"; MODE=execute; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument '$1'" ;;
  esac
done

[ -n "$MODE" ] || usage_error "choose exactly one of --preflight or --execute"
[ -n "$ROOT_ARG" ] || usage_error "--root <absolute path> is required and is never inferred"
[ "${#BOUNDARY_ARGS[@]}" -gt 0 ] || usage_error "at least one --boundary <absolute path> is required"

if [ "$MODE" = execute ]; then
  [ -n "$CONFIRM_ROOT" ] || usage_error "--execute requires --confirm-root repeating --root exactly"
  [ -n "$CONFIRM_PLAN" ] || usage_error "--execute requires --confirm-plan repeating the plan id from --preflight"
  [ "$CONFIRM_ROOT" = "$ROOT_ARG" ] || usage_error "--confirm-root '$CONFIRM_ROOT' does not repeat --root '$ROOT_ARG'"
else
  [ -z "$CONFIRM_ROOT" ] || usage_error "--confirm-root is only valid with --execute"
  [ -z "$CONFIRM_PLAN" ] || usage_error "--confirm-plan is only valid with --execute"
fi

case "$PATCH_SCAN_LIMIT" in
  ''|*[!0-9]*) usage_error "FM_RETIRE_PATCH_SCAN_LIMIT must be a non-negative integer" ;;
esac

# Fail closed before any inspection or mutation: a no-mistakes gate agent must
# never drive a fleet removal.
fm_refuse_if_gate_agent

# --- path primitives ---------------------------------------------------------

canonical_dir() {
  local p=$1
  [ -n "$p" ] || return 1
  [ -d "$p" ] || return 1
  ( cd "$p" 2>/dev/null && pwd -P ) || return 1
}

path_equal_or_inside() {
  local inner=$1 outer=$2
  [ -n "$inner" ] && [ -n "$outer" ] || return 1
  [ "$inner" = "$outer" ] && return 0
  case "$inner" in "$outer"/*) return 0 ;; esac
  return 1
}

paths_conflict() {
  path_equal_or_inside "$1" "$2" && return 0
  path_equal_or_inside "$2" "$1"
}

VALIDATED_PATH=
validate_path_shape() {
  local raw=$1 label=$2 canon
  case "$raw" in
    /*) ;;
    *) usage_error "$label must be an absolute path (got '$raw')" ;;
  esac
  case "$raw" in
    */) usage_error "$label must not end with '/' (got '$raw')" ;;
    *//*|*/./*|*/../*|*/.|*/..) usage_error "$label must be normalized, without '.', '..', or empty components (got '$raw')" ;;
  esac
  case "$raw" in
    /*/*/*) ;;
    *) refuse "$label $raw is too close to the filesystem root to be an ordinary retirement path" ;;
  esac
  [ -e "$raw" ] || [ -L "$raw" ] || refuse "$label $raw does not exist"
  [ ! -L "$raw" ] || refuse "$label $raw is a symlink; name the real directory instead"
  [ -d "$raw" ] || refuse "$label $raw is not an ordinary directory"
  canon=$(canonical_dir "$raw") || refuse "$label $raw cannot be resolved to a canonical directory"
  [ "$canon" = "$raw" ] || refuse "$label $raw is not canonical; it resolves to $canon"
  VALIDATED_PATH=$canon
}

# --- protected fleet paths ---------------------------------------------------

PROTECTED_PATHS=()
PROTECTED_LABELS=()
SECONDMATE_STATE_DIRS=()

add_protected() {
  [ -n "$1" ] || return 0
  PROTECTED_PATHS+=("${1%/}")
  PROTECTED_LABELS+=("$2")
}

# Match the (home: ...) field itself rather than requiring it to be the first
# parenthesised group: summary and scope prose routinely carries its own
# parentheticals, and a "^[^(]*" prefix would leave those entries looking like
# they have no home - silently dropping that secondmate's state directory from
# the recorded-task scan. Greedy prefix, so the last (home: ...) wins.
registry_home_for_line() {
  sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p' | sed 's/[[:space:]]*$//'
}

registry_id_for_line() {
  local id=${1#- }
  printf '%s\n' "${id%% *}"
}

collect_protected() {
  local home_canon root_canon line id home canon

  if home_canon=$(canonical_dir "$FM_HOME"); then :; else home_canon=${FM_HOME%/}; fi
  add_protected "$home_canon" "the primary firstmate home"
  add_protected "$home_canon/projects" "the primary firstmate project directory"
  if root_canon=$(canonical_dir "$FM_ROOT"); then :; else root_canon=${FM_ROOT%/}; fi
  add_protected "$root_canon" "the firstmate repository"

  if [ -f "$DATA/projects.md" ]; then
    while IFS= read -r line; do
      case "$line" in "- "*) ;; *) continue ;; esac
      id=$(registry_id_for_line "$line")
      [ -n "$id" ] || continue
      add_protected "$home_canon/projects/$id" "registered project $id"
    done < "$DATA/projects.md"
  fi

  if [ -f "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      case "$line" in "- "*) ;; *) continue ;; esac
      id=$(registry_id_for_line "$line")
      home=$(printf '%s\n' "$line" | registry_home_for_line)
      [ -n "$home" ] || continue
      if canon=$(canonical_dir "$home"); then home=$canon; else home=${home%/}; fi
      add_protected "$home" "registered secondmate home for ${id:-an unnamed secondmate}"
      SECONDMATE_STATE_DIRS+=("$home/state")
    done < "$DATA/secondmates.md"
  fi
}

assert_not_protected() {
  local path=$1 label=$2 i
  [ "${#PROTECTED_PATHS[@]}" -gt 0 ] || return 0
  for i in "${!PROTECTED_PATHS[@]}"; do
    if paths_conflict "$path" "${PROTECTED_PATHS[$i]}"; then
      refuse "$label $path is, contains, or sits inside ${PROTECTED_LABELS[$i]} (${PROTECTED_PATHS[$i]})"
    fi
  done
}

assert_no_registry_reference() {
  local path=$1 label=$2 file tokens token
  for file in "$DATA/projects.md" "$DATA/secondmates.md"; do
    [ -f "$file" ] || continue
    tokens=$(grep -oE '/[^[:space:];)"'"'"']+' "$file" 2>/dev/null | sed 's:/*$::' | LC_ALL=C sort -u || true)
    [ -n "$tokens" ] || continue
    while IFS= read -r token; do
      [ -n "$token" ] || continue
      case "$token" in /*/*) ;; *) continue ;; esac
      if paths_conflict "$path" "$token"; then
        refuse "$label $path is still referenced by $file ($token); retire the registry entry first"
      fi
    done <<EOF
$tokens
EOF
  done
}

assert_no_task_reference() {
  local path=$1 label=$2 dirs dir meta id line value
  dirs=("$STATE")
  [ "${#SECONDMATE_STATE_DIRS[@]}" -eq 0 ] || dirs+=("${SECONDMATE_STATE_DIRS[@]}")
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    for meta in "$dir"/*.meta; do
      [ -f "$meta" ] || continue
      id=$(basename "$meta" .meta)
      while IFS= read -r line; do
        case "$line" in
          worktree=*|project=*|home=*) value=${line#*=} ;;
          *) continue ;;
        esac
        case "$value" in /*) ;; *) continue ;; esac
        if paths_conflict "$path" "${value%/}"; then
          refuse "$label $path is still referenced by recorded task $id ($meta: $line)"
        fi
      done < "$meta"
    done
  done
}

PROC_INSPECTED=0
PROC_UNREADABLE=0
# One pass over the process table for every removal target at once: walking it
# per target would count each process once per target and report an inspected /
# not-inspectable coverage gap that is a multiple of the real one.
assert_no_live_process_cwd() {
  local entry pid cwd i
  [ "${#REMOVAL_TARGETS[@]}" -gt 0 ] || return 0
  [ -d "$PROC_ROOT" ] \
    || refuse "cannot prove no live process is working inside ${REMOVAL_TARGETS[*]}: $PROC_ROOT is unavailable"
  for entry in "$PROC_ROOT"/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=$(basename "$entry")
    if ! cwd=$(readlink "$entry/cwd" 2>/dev/null); then
      PROC_UNREADABLE=$(( PROC_UNREADABLE + 1 ))
      continue
    fi
    PROC_INSPECTED=$(( PROC_INSPECTED + 1 ))
    cwd=${cwd% (deleted)}
    case "$cwd" in /*) ;; *) continue ;; esac
    for i in "${!REMOVAL_TARGETS[@]}"; do
      if path_equal_or_inside "${cwd%/}" "${REMOVAL_TARGETS[$i]}"; then
        refuse "${REMOVAL_LABELS[$i]} ${REMOVAL_TARGETS[$i]} is the current directory of live process $pid ($cwd)"
      fi
    done
  done
}

# --- git inventory and landing proof ----------------------------------------

CHECKOUTS=()

collect_checkouts() {
  local dir=$1 found marker workdir canon
  found=$(find -P "$dir" -name .git -prune -print 2>/dev/null) || refuse "cannot inventory git checkouts under $dir"
  [ -n "$found" ] || return 0
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    workdir=$(dirname "$marker")
    canon=$(canonical_dir "$workdir") || refuse "cannot resolve checkout $workdir to a canonical directory"
    CHECKOUTS+=("$canon")
  done <<EOF
$found
EOF
}

STANDALONE_REPOS=()

# A directory holding HEAD, objects/ and refs/ is git's own shape for a
# repository directory. A worktree administrative directory or a stray HEAD file
# elsewhere in the tree does not have all three, so this is what separates a
# candidate repository from an ordinary directory that happens to contain a file
# named HEAD.
looks_like_git_dir() {
  local dir=$1
  [ -f "$dir/HEAD" ] && [ -d "$dir/objects" ] && [ -d "$dir/refs" ]
}

# Standalone repositories have no `.git` marker for collect_checkouts to find: a
# repository directory is recognised by being its own git common directory,
# whether it is bare or a detached non-bare git directory whose worktree is gone
# or lives elsewhere. `core.bare` is deliberately not the test - a
# `--separate-git-dir` target reports false and still holds objects nothing else
# proves landed. Nested git directories (a worktree administrative dir) resolve
# to an enclosing common directory instead and are left to the checkout that
# owns them; a repository-shaped directory git cannot resolve is a refusal, not
# a skip.
collect_standalone_repos() {
  local dir=$1 found head candidate canon common
  found=$(find -P "$dir" -type f -name HEAD -print 2>/dev/null) \
    || refuse "cannot inventory git repositories under $dir"
  [ -n "$found" ] || return 0
  while IFS= read -r head; do
    [ -n "$head" ] || continue
    candidate=$(dirname "$head")
    looks_like_git_dir "$candidate" || continue
    canon=$(canonical_dir "$candidate") \
      || refuse "git repository directory $candidate cannot be resolved to a canonical directory; refusing on an ambiguous git result"
    common=$(common_dir_of "$canon") \
      || refuse "git repository directory $canon does not report a resolvable git directory; refusing on an ambiguous git result"
    [ "$common" = "$canon" ] || continue
    STANDALONE_REPOS+=("$canon")
  done <<EOF
$found
EOF
}

common_dir_of() {
  local workdir=$1 common
  common=$(git -C "$workdir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case "$common" in /*) ;; *) common="$workdir/$common" ;; esac
  ( cd "$common" 2>/dev/null && pwd -P ) || return 1
}

# Echo the local filesystem path a remote URL names, or fail when the URL names
# a network transport. Only local URLs can sit inside a removal target.
remote_local_path() {
  local workdir=$1 url=$2 path canon dir base
  case "$url" in
    file://localhost/*) path=${url#file://localhost} ;;
    file:///*) path=${url#file://} ;;
    *://*) return 1 ;;
    /*) path=$url ;;
    *)
      # scp-like [user@]host:path carries its colon before any slash.
      case "$url" in
        */*) case "${url%%/*}" in *:*) return 1 ;; esac ;;
        *:*) return 1 ;;
      esac
      path="$workdir/$url"
      ;;
  esac
  [ -n "$path" ] || return 1
  if canon=$(canonical_dir "$path"); then
    printf '%s\n' "$canon"
    return 0
  fi
  # A path that is not a directory right now still has to be placed: canonicalize
  # the parent so a bare repository named but not yet resolvable still lands in
  # the tree it belongs to.
  dir=$(dirname "$path")
  base=$(basename "$path")
  if canon=$(canonical_dir "$dir"); then
    printf '%s\n' "${canon%/}/$base"
    return 0
  fi
  printf '%s\n' "${path%/}"
}

# Landing evidence has to outlive the removal that cites it. A remote pointing
# at a mirror inside the retirement tree - or at the repository's own path -
# fetches happily and makes every branch look like an exact ancestor of a ref
# this same run destroys, so the proof proves nothing.
assert_remote_evidence_survives() {
  local common=$1 workdir=$2 remote=$3 urls url resolved i
  urls=$(git -C "$workdir" remote get-url --all "$remote" 2>/dev/null) \
    || refuse "cannot read the URL of remote $remote in repository $common; refusing on an ambiguous git result"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    resolved=$(remote_local_path "$workdir" "$url") || continue
    for i in "${!REMOVAL_TARGETS[@]}"; do
      if path_equal_or_inside "$resolved" "${REMOVAL_TARGETS[$i]}"; then
        refuse "repository $common takes its landing evidence from remote $remote ($url), which resolves to $resolved inside ${REMOVAL_LABELS[$i]} ${REMOVAL_TARGETS[$i]}; that evidence would be destroyed by this retirement, so it proves nothing"
      fi
    done
  done <<EOF
$urls
EOF
}

patch_id_of() {
  local workdir=$1 commit=$2
  git -C "$workdir" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

REPO_REMOTE_REFS=
REPO_UPSTREAM_IDS=
REPO_UPSTREAM_IDS_READY=0

load_upstream_patch_ids() {
  local workdir=$1 total commit
  [ "$REPO_UPSTREAM_IDS_READY" -eq 0 ] || return 0
  total=$(git -C "$workdir" rev-list --count --remotes 2>/dev/null) || return 1
  case "$total" in ''|*[!0-9]*) return 1 ;; esac
  [ "$total" -le "$PATCH_SCAN_LIMIT" ] || return 2
  REPO_UPSTREAM_IDS=$(
    git -C "$workdir" rev-list --remotes 2>/dev/null | while IFS= read -r commit; do
      patch_id_of "$workdir" "$commit"
    done | sed '/^$/d' | LC_ALL=C sort -u
  )
  REPO_UPSTREAM_IDS_READY=1
}

LANDED_REASON=
# Prove that everything reachable from <commit> and not already on a
# remote-tracking ref has landed upstream. A matching commit subject is never
# consulted; see the header's landing-proof ladder.
work_is_landed() {
  local workdir=$1 commit=$2 ref tree merged unique count entry pid rc

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if git -C "$workdir" merge-base --is-ancestor "$commit" "$ref" 2>/dev/null; then
      LANDED_REASON="exact ancestry of $ref"
      return 0
    fi
  done <<EOF
$REPO_REMOTE_REFS
EOF

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    tree=$(git -C "$workdir" rev-parse -q --verify "$ref^{tree}" 2>/dev/null) || continue
    [ -n "$tree" ] || continue
    merged=$(git -C "$workdir" merge-tree --write-tree "$ref" "$commit" 2>/dev/null | head -1) || continue
    if [ -n "$merged" ] && [ "$merged" = "$tree" ]; then
      LANDED_REASON="content already contained in $ref"
      return 0
    fi
  done <<EOF
$REPO_REMOTE_REFS
EOF

  unique=$(git -C "$workdir" log --format=%H "$commit" --not --remotes -- 2>/dev/null) || {
    LANDED_REASON="git could not list the commits it adds over the remote-tracking refs"
    return 1
  }
  unique=$(printf '%s\n' "$unique" | sed '/^$/d')
  if [ -z "$unique" ]; then
    LANDED_REASON="adds nothing over the remote-tracking refs"
    return 0
  fi
  count=$(printf '%s\n' "$unique" | wc -l | tr -d ' ')
  if [ "$count" -gt "$PATCH_SCAN_LIMIT" ]; then
    LANDED_REASON="adds $count commits, above the FM_RETIRE_PATCH_SCAN_LIMIT bound of $PATCH_SCAN_LIMIT"
    return 1
  fi

  rc=0
  load_upstream_patch_ids "$workdir" || rc=$?
  if [ "$rc" -eq 2 ]; then
    LANDED_REASON="upstream history is larger than the FM_RETIRE_PATCH_SCAN_LIMIT bound of $PATCH_SCAN_LIMIT, so patch equivalence cannot be proven"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    LANDED_REASON="git could not enumerate the upstream commits needed for patch equivalence"
    return 1
  fi

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    pid=$(patch_id_of "$workdir" "$entry")
    if [ -z "$pid" ]; then
      LANDED_REASON="commit $entry has no computable patch id, so patch equivalence cannot be proven"
      return 1
    fi
    if ! printf '%s\n' "$REPO_UPSTREAM_IDS" | grep -qxF "$pid"; then
      LANDED_REASON="commit $entry is not patch-equivalent to any upstream commit"
      return 1
    fi
  done <<EOF
$unique
EOF
  LANDED_REASON="patch-equivalent to upstream for all $count added commits"
  return 0
}

EVIDENCE=
REPORT=
add_evidence() {
  EVIDENCE="$EVIDENCE$1"$'\n'
}
add_report() {
  REPORT="$REPORT$1"$'\n'
}

# --- validation -------------------------------------------------------------

validate_path_shape "$ROOT_ARG" "retirement root"
ROOT=$VALIDATED_PATH
POOL=
if [ -n "$POOL_ARG" ]; then
  validate_path_shape "$POOL_ARG" "legacy pool root"
  POOL=$VALIDATED_PATH
  [ "$POOL" != "$ROOT" ] || usage_error "--pool must not repeat --root"
  ! path_equal_or_inside "$POOL" "$ROOT" || usage_error "--pool $POOL is inside --root $ROOT; the root removal already covers it"
  ! path_equal_or_inside "$ROOT" "$POOL" || usage_error "--root $ROOT is inside --pool $POOL; name the outermost tree as --root"
fi

collect_protected
assert_not_protected "$ROOT" "retirement root"
assert_no_registry_reference "$ROOT" "retirement root"
if [ -n "$POOL" ]; then
  assert_not_protected "$POOL" "legacy pool root"
  assert_no_registry_reference "$POOL" "legacy pool root"
fi

BOUNDARIES=()
for boundary in "${BOUNDARY_ARGS[@]}"; do
  validate_path_shape "$boundary" "retirement boundary"
  assert_not_protected "$VALIDATED_PATH" "retirement boundary"
  BOUNDARIES+=("$VALIDATED_PATH")
done

assert_inside_a_boundary() {
  local path=$1 label=$2 boundary
  for boundary in "${BOUNDARIES[@]}"; do
    path_equal_or_inside "$path" "$boundary" && return 0
  done
  refuse "$label $path is outside every approved retirement boundary (${BOUNDARIES[*]})"
}

assert_inside_a_boundary "$ROOT" "retirement root"
[ -z "$POOL" ] || assert_inside_a_boundary "$POOL" "legacy pool root"

# The removal targets are known as soon as the paths are validated, and every
# later check - recorded tasks, live processes, and the remote URLs the landing
# proof cites - is asked about all of them at once. Pool first, so the
# authoritative repository is removed last.
REMOVAL_TARGETS=()
REMOVAL_LABELS=()
if [ -n "$POOL" ]; then
  REMOVAL_TARGETS+=("$POOL")
  REMOVAL_LABELS+=("legacy pool root")
fi
REMOVAL_TARGETS+=("$ROOT")
REMOVAL_LABELS+=("retirement root")

for index in "${!REMOVAL_TARGETS[@]}"; do
  assert_no_task_reference "${REMOVAL_TARGETS[$index]}" "${REMOVAL_LABELS[$index]}"
done

assert_no_live_process_cwd

# --- inventory --------------------------------------------------------------

collect_checkouts "$ROOT"
ROOT_CHECKOUT_COUNT=${#CHECKOUTS[@]}
[ -z "$POOL" ] || collect_checkouts "$POOL"
[ "$ROOT_CHECKOUT_COUNT" -gt 0 ] \
  || refuse "no git checkout found under retirement root $ROOT; this owner retires project trees, not arbitrary directories"
if [ -n "$POOL" ] && [ "${#CHECKOUTS[@]}" -eq "$ROOT_CHECKOUT_COUNT" ]; then
  refuse "legacy pool root $POOL holds no git checkout, so it cannot be proven linked to $ROOT"
fi

SORTED_CHECKOUTS=$(printf '%s\n' "${CHECKOUTS[@]}" | LC_ALL=C sort -u)

REPO_COMMONS=()
REPO_WORKDIRS=()

remember_repo() {
  local common=$1 workdir=$2 existing
  for existing in ${REPO_COMMONS[@]+"${REPO_COMMONS[@]}"}; do
    [ "$existing" = "$common" ] && return 0
  done
  REPO_COMMONS+=("$common")
  REPO_WORKDIRS+=("$workdir")
}

while IFS= read -r checkout; do
  [ -n "$checkout" ] || continue
  toplevel=$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) \
    || refuse "checkout $checkout does not report a git toplevel; refusing on an ambiguous git result"
  toplevel=$(canonical_dir "$toplevel") \
    || refuse "checkout $checkout reports a git toplevel that cannot be resolved"
  [ "$toplevel" = "$checkout" ] \
    || refuse "checkout $checkout reports a different git toplevel $toplevel; refusing on an ambiguous git result"
  common=$(common_dir_of "$checkout") \
    || refuse "checkout $checkout does not report a resolvable git directory; refusing on an ambiguous git result"
  path_equal_or_inside "$common" "$ROOT" \
    || refuse "checkout $checkout belongs to repository $common outside the retirement root $ROOT"
  status=$(git -C "$checkout" status --porcelain --untracked-files=all 2>/dev/null) \
    || refuse "cannot inspect checkout $checkout for uncommitted work; refusing on an ambiguous git result"
  [ -z "$status" ] \
    || refuse "checkout $checkout has dirty or untracked files:"$'\n'"$(printf '%s\n' "$status" | head -10)"
  head=$(git -C "$checkout" rev-parse --verify HEAD 2>/dev/null) \
    || refuse "checkout $checkout has no resolvable HEAD; refusing on an ambiguous git result"
  add_evidence "checkout $checkout head $head"
  add_report "checkout $checkout at $head, clean"
  remember_repo "$common" "$checkout"
done <<EOF
$SORTED_CHECKOUTS
EOF

collect_standalone_repos "$ROOT"
[ -z "$POOL" ] || collect_standalone_repos "$POOL"
for standalone_repo in ${STANDALONE_REPOS[@]+"${STANDALONE_REPOS[@]}"}; do
  path_equal_or_inside "$standalone_repo" "$ROOT" \
    || refuse "git repository $standalone_repo has no worktree and lives outside the retirement root $ROOT"
  remember_repo "$standalone_repo" "$standalone_repo"
done

for index in "${!REPO_COMMONS[@]}"; do
  common=${REPO_COMMONS[$index]}
  workdir=${REPO_WORKDIRS[$index]}
  add_report "repository $common inspected from $workdir"

  worktrees=$(git -C "$workdir" -c core.quotePath=false worktree list --porcelain 2>/dev/null) \
    || refuse "cannot list the worktrees of repository $common; refusing on an ambiguous git result"
  current_worktree=
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        current_worktree=${line#worktree }
        current_worktree=$(canonical_dir "$current_worktree") \
          || refuse "repository $common has a stale worktree registration for ${line#worktree }, whose path is gone; resolve that registration deliberately before retiring the tree"
        if ! path_equal_or_inside "$current_worktree" "$ROOT" \
          && { [ -z "$POOL" ] || ! path_equal_or_inside "$current_worktree" "$POOL"; }; then
          refuse "repository $common has linked worktree $current_worktree outside the retirement tree"
        fi
        add_evidence "repo $common worktree $current_worktree"
        add_report "  worktree $current_worktree"
        ;;
      "locked"|"locked "*)
        refuse "repository $common has locked (in use) worktree ${current_worktree:-unknown}; ${line#locked}"
        ;;
    esac
  done <<EOF
$worktrees
EOF

  remotes=$(git -C "$workdir" remote 2>/dev/null) \
    || refuse "cannot list the remotes of repository $common; refusing on an ambiguous git result"
  remotes=$(printf '%s\n' "$remotes" | sed '/^$/d')
  [ -n "$remotes" ] \
    || refuse "repository $common has no remote, so no landing evidence exists for its branches"
  while IFS= read -r remote; do
    [ -n "$remote" ] || continue
    assert_remote_evidence_survives "$common" "$workdir" "$remote"
    git -C "$workdir" fetch --quiet --no-prune "$remote" 2>/dev/null \
      || refuse "cannot refresh landing evidence for repository $common: git fetch $remote failed"
  done <<EOF
$remotes
EOF

  REPO_REMOTE_REFS=$(git -C "$workdir" for-each-ref --format='%(refname)' refs/remotes/ 2>/dev/null) \
    || refuse "cannot list the remote-tracking refs of repository $common; refusing on an ambiguous git result"
  REPO_REMOTE_REFS=$(printf '%s\n' "$REPO_REMOTE_REFS" | grep -v '/HEAD$' | sed '/^$/d' || true)
  [ -n "$REPO_REMOTE_REFS" ] \
    || refuse "repository $common has no remote-tracking ref after fetching, so its landing evidence is incomplete"
  REPO_UPSTREAM_IDS=
  REPO_UPSTREAM_IDS_READY=0

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    sha=$(git -C "$workdir" rev-parse --verify "$ref" 2>/dev/null) \
      || refuse "repository $common has unreadable ref $ref; refusing on an ambiguous git result"
    add_evidence "repo $common ref $ref $sha"
  done <<EOF
$REPO_REMOTE_REFS
EOF

  branches=$(git -C "$workdir" for-each-ref --format='%(refname:short) %(objectname)' refs/heads/ 2>/dev/null) \
    || refuse "cannot list the branches of repository $common; refusing on an ambiguous git result"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    branch=${line%% *}
    sha=${line##* }
    add_evidence "repo $common branch $branch $sha"
    if work_is_landed "$workdir" "$sha"; then
      add_report "  branch $branch landed ($LANDED_REASON)"
    else
      refuse "repository $common has unlanded branch $branch at $sha: $LANDED_REASON"
    fi
  done <<EOF
$branches
EOF

  # fsck's own exit status, not the pipeline's: piping it into sed would report
  # a corrupt or unreadable object store as "no unreachable commits" and let the
  # tree be deleted without its dangling objects ever being proven landed.
  fsck_rc=0
  fsck_output=$(git -C "$workdir" fsck --unreachable --no-reflogs --no-progress --connectivity-only 2>&1) \
    || fsck_rc=$?
  [ "$fsck_rc" -eq 0 ] \
    || refuse "cannot check the object store of repository $common: git fsck exited $fsck_rc, so its unreachable commits cannot be enumerated:"$'\n'"$(printf '%s\n' "$fsck_output" | head -10)"
  unreachable=$(printf '%s\n' "$fsck_output" | sed -n 's/^unreachable commit //p' | LC_ALL=C sort -u)
  unreachable_count=0
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    unreachable_count=$(( unreachable_count + 1 ))
    add_evidence "repo $common unreachable $sha"
    if ! work_is_landed "$workdir" "$sha"; then
      refuse "repository $common holds unreachable commit $sha whose work is not landed: $LANDED_REASON"
    fi
  done <<EOF
$unreachable
EOF
  add_report "  $unreachable_count unreachable commits, all landed"
done

# Top-level entries are part of the plan so the operator sees every non-checkout
# file and directory the bounded removal would take with it.
list_top_level() {
  local dir=$1 label=$2 entry name
  for entry in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name=$(basename "$entry")
    add_evidence "entry $label $name"
    add_report "  contains $name"
  done
}

add_report "retirement root $ROOT"
list_top_level "$ROOT" "$ROOT"
if [ -n "$POOL" ]; then
  add_report "legacy pool root $POOL"
  list_top_level "$POOL" "$POOL"
fi

# --- plan identity ----------------------------------------------------------

digest_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{ print $1 }'
  else
    return 1
  fi
}

PLAN_ID=$(
  {
    printf 'root %s\n' "$ROOT"
    printf 'pool %s\n' "${POOL:--}"
    printf '%s' "$EVIDENCE" | LC_ALL=C sort
  } | digest_of_stdin
) || refuse "cannot compute a plan id: neither sha256sum nor shasum is available"
[ -n "$PLAN_ID" ] || refuse "cannot compute a plan id from the inspected evidence"

print_plan() {
  printf 'PLAN: guarded retirement of %s\n' "$ROOT"
  printf '%s' "$REPORT" | sed 's/^/PLAN:   /'
  printf 'PLAN: inspected %s live process working directories (%s not inspectable by this user)\n' \
    "$PROC_INSPECTED" "$PROC_UNREADABLE"
  local step=0 target
  for target in "${REMOVAL_TARGETS[@]}"; do
    step=$(( step + 1 ))
    printf 'PLAN: removal step %s: rm -rf -- %s\n' "$step" "$target"
  done
  printf 'PLAN-ID: %s\n' "$PLAN_ID"
}

if [ "$MODE" = preflight ]; then
  print_plan
  printf 'PREFLIGHT OK: every check passed and nothing was removed.\n'
  printf 'To remove exactly this plan, re-run with:\n'
  printf '  %s --root %s' "$0" "$ROOT"
  [ -z "$POOL" ] || printf ' --pool %s' "$POOL"
  for boundary in "${BOUNDARIES[@]}"; do
    printf ' --boundary %s' "$boundary"
  done
  printf ' --execute --confirm-root %s --confirm-plan %s\n' "$ROOT" "$PLAN_ID"
  exit 0
fi

# --- execute ----------------------------------------------------------------

if [ "$CONFIRM_PLAN" != "$PLAN_ID" ]; then
  printf 'REFUSED: the approved plan no longer matches the current evidence.\n' >&2
  printf '  approved plan id: %s\n' "$CONFIRM_PLAN" >&2
  printf '  current plan id:  %s\n' "$PLAN_ID" >&2
  printf 'Nothing was removed. Re-run --preflight, review the new plan, and approve it deliberately.\n' >&2
  exit 1
fi

print_plan

for target in "${REMOVAL_TARGETS[@]}"; do
  validate_path_shape "$target" "removal target"
  [ "$VALIDATED_PATH" = "$target" ] || refuse "removal target $target changed identity after the plan was approved"
  assert_not_protected "$target" "removal target"
  assert_inside_a_boundary "$target" "removal target"
done

for target in "${REMOVAL_TARGETS[@]}"; do
  if ! rm -rf -- "$target"; then
    printf 'error: removing %s failed; stopping without any further removal\n' "$target" >&2
    exit 1
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    printf 'error: %s still exists after removal; stopping without any further removal\n' "$target" >&2
    exit 1
  fi
  printf 'RETIRED: removed %s\n' "$target"
done

printf 'RETIRED: plan %s completed; %s removal target(s) gone, nothing else was touched.\n' \
  "$PLAN_ID" "${#REMOVAL_TARGETS[@]}"
