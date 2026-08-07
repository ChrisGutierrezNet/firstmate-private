#!/usr/bin/env bash
# Continuous Operations v2 GitHub discovery, classification, and queue admission.
#
# This script is the single owner of the GitHub-to-backlog candidate ledger,
# scan cadence, source-freshness status, and idempotent queue-admission record.
# It is deliberately upstream of bin/fm-continuous-ops-lib.sh's v1 marker:
# this script may add proven Ready GitHub issues to the local tasks-axi backlog,
# but v1 remains the only owner of the ready-plus-idle-capacity marker and the
# deduplicated actionable wake. This script never spawns workers, selects the
# next task, routes to a secondmate, or mutates GitHub.
#
# Config, all optional and local under config/continuous-ops-github-projects:
#   # one whitespace-separated project per line
#   <project-name> [repo=<owner/name>] [roadmap=<owner>/<number>] [default_branch=<branch>]
#
# When that file is absent, every data/projects.md entry whose projects/<name>
# clone has a GitHub origin is scanned. A configured repo lets a project be
# scanned even when the clone is absent. A configured roadmap is required evidence:
# if it cannot be read, eligibility for that project is reported as unknown.
#
# State, all local under state/:
#   .continuous-ops-github.status       key=value freshness/cadence record
#   .continuous-ops-github.ledger.jsonl one JSON object per candidate verdict
#   .continuous-ops-github.admitted.tsv admitted issue -> backlog task map
#   .continuous-ops-github.lock         serializes scans and admission
#
# Candidate verdict schema is owned here. Each JSONL row carries:
#   version, scanned_at, source_fresh_until, project, repo, number, issue_url,
#   title, verdict, code, evidence[], source_freshness{}, rank{}, task_id.
#
# Verdicts are: ready, blocked, held, ambiguous, duplicate_active,
# already_shipped, investigation_first, and eligibility_unknown.
# Missing, partial, stale, or unauthenticated source data is never interpreted as
# zero Ready work; it produces eligibility_unknown and preserves the previous
# successful ledger unless a fresh issue list was available for per-issue unknown
# rows.
#
# Usage:
#   fm-continuous-ops-github.sh refresh [--force] [--reason <reason>] [--print]
#       Reconcile due configured GitHub projects, admit proven Ready issues with
#       tasks-axi add, and print a compact summary with --print.
#   fm-continuous-ops-github.sh status
#       Print the current freshness record and ledger path.
#   fm-continuous-ops-github.sh ledger
#       Print the current candidate ledger summary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}"
DATA="${FM_DATA_OVERRIDE:-${DATA:-$FM_HOME/data}}"
CONFIG="${FM_CONFIG_OVERRIDE:-${CONFIG:-$FM_HOME/config}}"
PROJECTS_DIR="${FM_PROJECTS_OVERRIDE:-${PROJECTS:-$FM_HOME/projects}}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

STATUS_FILE="${FM_CONTINUOUS_OPS_GITHUB_STATUS:-$STATE/.continuous-ops-github.status}"
LEDGER_FILE="${FM_CONTINUOUS_OPS_GITHUB_LEDGER:-$STATE/.continuous-ops-github.ledger.jsonl}"
ADMITTED_FILE="${FM_CONTINUOUS_OPS_GITHUB_ADMITTED:-$STATE/.continuous-ops-github.admitted.tsv}"
LOCK_FILE="${FM_CONTINUOUS_OPS_GITHUB_LOCK:-$STATE/.continuous-ops-github.lock}"
CONFIG_FILE="${FM_CONTINUOUS_OPS_GITHUB_CONFIG:-$CONFIG/continuous-ops-github-projects}"
BACKLOG_FILE="${FM_CONTINUOUS_OPS_BACKLOG:-$DATA/backlog.md}"

FM_CONTINUOUS_OPS_GITHUB_INTERVAL_SECONDS=${FM_CONTINUOUS_OPS_GITHUB_INTERVAL_SECONDS:-1800}
FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS=${FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS:-7200}
FM_CONTINUOUS_OPS_GITHUB_COMMAND_TIMEOUT=${FM_CONTINUOUS_OPS_GITHUB_COMMAND_TIMEOUT:-45}
FM_CONTINUOUS_OPS_GITHUB_PER_PAGE=${FM_CONTINUOUS_OPS_GITHUB_PER_PAGE:-100}
FM_CONTINUOUS_OPS_GITHUB_MAX_PAGES=${FM_CONTINUOUS_OPS_GITHUB_MAX_PAGES:-20}
FM_CONTINUOUS_OPS_GITHUB_COMMIT_LIMIT=${FM_CONTINUOUS_OPS_GITHUB_COMMIT_LIMIT:-250}
FM_CONTINUOUS_OPS_GITHUB_PROJECT_LIMIT=${FM_CONTINUOUS_OPS_GITHUB_PROJECT_LIMIT:-500}

case "$FM_CONTINUOUS_OPS_GITHUB_INTERVAL_SECONDS" in ''|*[!0-9]*) FM_CONTINUOUS_OPS_GITHUB_INTERVAL_SECONDS=1800 ;; esac
case "$FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS=7200 ;; esac
case "$FM_CONTINUOUS_OPS_GITHUB_COMMAND_TIMEOUT" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_GITHUB_COMMAND_TIMEOUT=45 ;; esac
case "$FM_CONTINUOUS_OPS_GITHUB_PER_PAGE" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_GITHUB_PER_PAGE=100 ;; esac
case "$FM_CONTINUOUS_OPS_GITHUB_MAX_PAGES" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_GITHUB_MAX_PAGES=20 ;; esac
case "$FM_CONTINUOUS_OPS_GITHUB_COMMIT_LIMIT" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_GITHUB_COMMIT_LIMIT=250 ;; esac
case "$FM_CONTINUOUS_OPS_GITHUB_PROJECT_LIMIT" in ''|*[!0-9]*|0) FM_CONTINUOUS_OPS_GITHUB_PROJECT_LIMIT=500 ;; esac

NOW_EPOCH=
SCAN_AT=
FRESH_UNTIL=
SUMMARY_STATE=skipped
SUMMARY_REASON=
SUMMARY_PROJECTS=0
SUMMARY_OPEN_ISSUES=0
SUMMARY_CANDIDATES=0
SUMMARY_READY=0
SUMMARY_ADMITTED=0
SUMMARY_UNKNOWN=0
SUMMARY_FINGERPRINT=
SUMMARY_ERROR=
SCAN_PRESERVE_LEDGER=0

usage() {
  sed -n '2,/^set -u$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

now_epoch() { date +%s; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

status_get() {  # <key>
  [ -f "$STATUS_FILE" ] && [ ! -L "$STATUS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATUS_FILE" 2>/dev/null | tail -1
}

write_atomic() {  # <dest>, stdin
  local dest=$1 tmp
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    chmod 600 "$dest" 2>/dev/null || true
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

status_write() {  # <state> <reason> <last-success-epoch> <fingerprint>
  local state=$1 reason=$2 last_success=${3:-} fingerprint=${4:-}
  local updated expires
  updated=$(now_epoch)
  expires=
  if [ -n "$last_success" ]; then
    expires=$((last_success + FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS))
  fi
  mkdir -p "$STATE" 2>/dev/null || return 1
  write_atomic "$STATUS_FILE" <<EOF
version=1
state=$state
reason=$reason
updated_at=$(now_iso)
updated_epoch=$updated
last_attempt_epoch=$updated
last_success_epoch=$last_success
source_fresh_until_epoch=$expires
interval_seconds=$FM_CONTINUOUS_OPS_GITHUB_INTERVAL_SECONDS
max_age_seconds=$FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS
projects=$SUMMARY_PROJECTS
open_issues=$SUMMARY_OPEN_ISSUES
candidates=$SUMMARY_CANDIDATES
ready=$SUMMARY_READY
admitted=$SUMMARY_ADMITTED
unknown=$SUMMARY_UNKNOWN
fingerprint=$fingerprint
ledger=$LEDGER_FILE
admitted_file=$ADMITTED_FILE
EOF
}

refresh_due() {
  local last age
  [ "${FORCE_REFRESH:-0}" -eq 1 ] && return 0
  [ "$FM_CONTINUOUS_OPS_GITHUB_INTERVAL_SECONDS" -eq 0 ] && return 0
  last=$(status_get last_attempt_epoch)
  case "$last" in ''|*[!0-9]*) return 0 ;; esac
  age=$(( $(now_epoch) - last ))
  [ "$age" -ge "$FM_CONTINUOUS_OPS_GITHUB_INTERVAL_SECONDS" ]
}

safe_component() {  # <text>
  printf '%s\n' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//; s/-$//'
}

task_id_for_issue() {  # <project> <number>
  local project=$1 number=$2 comp
  comp=$(safe_component "$project")
  [ -n "$comp" ] || comp=project
  printf 'gh-%s-%s\n' "$comp" "$number"
}

github_repo_from_url() {  # <remote-url>
  local url=$1 repo
  case "$url" in
    git@github.com:*.git) repo=${url#git@github.com:}; repo=${repo%.git} ;;
    git@github.com:*) repo=${url#git@github.com:} ;;
    https://github.com/*.git) repo=${url#https://github.com/}; repo=${repo%.git} ;;
    https://github.com/*) repo=${url#https://github.com/} ;;
    ssh://git@github.com/*.git) repo=${url#ssh://git@github.com/}; repo=${repo%.git} ;;
    ssh://git@github.com/*) repo=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  case "$repo" in */*) printf '%s\n' "$repo" ;; *) return 1 ;; esac
}

infer_repo_for_project() {  # <project>
  local project=$1 clone url
  clone="$PROJECTS_DIR/$project"
  [ -d "$clone/.git" ] || [ -f "$clone/.git" ] || return 1
  url=$(git -C "$clone" remote get-url origin 2>/dev/null) || return 1
  github_repo_from_url "$url"
}

configured_projects() {
  local line token project repo roadmap default_branch
  if [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=${line%%#*}
      # shellcheck disable=SC2086 # Intentional token parsing of the config line.
      set -- $line
      [ $# -gt 0 ] || continue
      project=
      repo=
      roadmap=
      default_branch=
      for token in "$@"; do
        case "$token" in
          project=*) project=${token#project=} ;;
          repo=*) repo=${token#repo=} ;;
          roadmap=*) roadmap=${token#roadmap=} ;;
          default_branch=*) default_branch=${token#default_branch=} ;;
          *=*) ;;
          *) [ -n "$project" ] || project=$token ;;
        esac
      done
      [ -n "$project" ] || continue
      case "$repo" in
        '') repo=$(infer_repo_for_project "$project" 2>/dev/null || true) ;;
        */*) ;;
        *) repo= ;;
      esac
      [ -n "$repo" ] || {
        printf '%s\t%s\t%s\t%s\n' "$project" "" "$roadmap" "$default_branch"
        continue
      }
      printf '%s\t%s\t%s\t%s\n' "$project" "$repo" "$roadmap" "$default_branch"
    done < "$CONFIG_FILE"
    return 0
  fi

  [ -f "$DATA/projects.md" ] && [ ! -L "$DATA/projects.md" ] || return 0
  awk '$1=="-" { print $2 }' "$DATA/projects.md" |
    while IFS= read -r project || [ -n "$project" ]; do
      [ -n "$project" ] || continue
      repo=$(infer_repo_for_project "$project" 2>/dev/null || true)
      [ -n "$repo" ] || continue
      printf '%s\t%s\t\t\n' "$project" "$repo"
    done
}

toon_module_path() {
  if [ -n "${FM_TOON_MODULE:-}" ]; then
    [ -f "$FM_TOON_MODULE" ] || return 1
    printf '%s\n' "$FM_TOON_MODULE"
    return 0
  fi
  command -v gh-axi >/dev/null 2>&1 || return 1
  node -e 'const fs=require("fs"); const {createRequire}=require("module"); const p=fs.realpathSync(process.argv[1]); const r=createRequire(p); console.log(r.resolve("@toon-format/toon"));' \
    "$(command -v gh-axi)" 2>/dev/null
}

decode_output_to_json() {  # <input> <output>
  local input=$1 output=$2 module
  if jq . "$input" > "$output" 2>/dev/null; then
    return 0
  fi
  module=$(toon_module_path) || return 1
  TOON_MODULE=$module node --input-type=module -e '
const fs = await import("node:fs");
const { decode } = await import(process.env.TOON_MODULE);
const input = fs.readFileSync(0, "utf8");
console.log(JSON.stringify(decode(input, { strict: false })));
' < "$input" > "$output"
}

run_gh_toon_json() {  # <json-output> <gh-axi args...>
  local out=$1 raw err rc
  shift
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-cogh-raw.XXXXXX") || return 1
  err="$raw.err"
  rc=0
  fm_run_timed "$FM_CONTINUOUS_OPS_GITHUB_COMMAND_TIMEOUT" gh-axi "$@" > "$raw" 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    SUMMARY_ERROR=$(head -3 "$raw" "$err" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')
    rm -f "$raw" "$err" 2>/dev/null || true
    return "$rc"
  fi
  if ! decode_output_to_json "$raw" "$out"; then
    SUMMARY_ERROR="could not decode gh-axi output for gh-axi $*"
    rm -f "$raw" "$err" 2>/dev/null || true
    return 1
  fi
  rm -f "$raw" "$err" 2>/dev/null || true
  return 0
}

gh_api_object() {  # <path> <out>
  local path=$1 out=$2
  run_gh_toon_json "$out" api "$path" || return $?
  jq -e 'type == "object"' "$out" >/dev/null 2>&1
}

gh_api_paged_array() {  # <path-without-page> <out> [limit]
  local path=$1 out=$2 limit=${3:-0}
  local page=1 per_page=$FM_CONTINUOUS_OPS_GITHUB_PER_PAGE max_pages=$FM_CONTINUOUS_OPS_GITHUB_MAX_PAGES
  local page_file combined next len fetched=0 sep
  combined=$(mktemp "${TMPDIR:-/tmp}/fm-cogh-combined.XXXXXX") || return 1
  printf '[]\n' > "$combined"
  while [ "$page" -le "$max_pages" ]; do
    page_file=$(mktemp "${TMPDIR:-/tmp}/fm-cogh-page.XXXXXX") || {
      rm -f "$combined" 2>/dev/null || true
      return 1
    }
    case "$path" in *'?'*) sep='&' ;; *) sep='?' ;; esac
    if ! run_gh_toon_json "$page_file" api "${path}${sep}per_page=${per_page}&page=${page}"; then
      rm -f "$combined" "$page_file" 2>/dev/null || true
      return 1
    fi
    if ! jq -e 'type == "array"' "$page_file" >/dev/null 2>&1; then
      SUMMARY_ERROR="gh-axi api ${path} returned a non-array page"
      rm -f "$combined" "$page_file" 2>/dev/null || true
      return 1
    fi
    len=$(jq 'length' "$page_file")
    fetched=$((fetched + len))
    next="$combined.next"
    jq -s '.[0] + .[1]' "$combined" "$page_file" > "$next" || {
      rm -f "$combined" "$page_file" "$next" 2>/dev/null || true
      return 1
    }
    mv -f "$next" "$combined"
    rm -f "$page_file" 2>/dev/null || true
    [ "$limit" -le 0 ] || [ "$fetched" -lt "$limit" ] || break
    [ "$len" -lt "$per_page" ] && break
    page=$((page + 1))
  done
  if [ "$page" -gt "$max_pages" ]; then
    SUMMARY_ERROR="gh-axi api ${path} reached the page cap (${max_pages}) before proving completeness"
    rm -f "$combined" 2>/dev/null || true
    return 2
  fi
  if [ "$limit" -gt 0 ]; then
    jq --argjson limit "$limit" '.[:$limit]' "$combined" > "$out" || {
      rm -f "$combined" 2>/dev/null || true
      return 1
    }
  else
    mv -f "$combined" "$out"
    combined=
  fi
  rm -f "$combined" 2>/dev/null || true
  return 0
}

roadmap_items() {  # <roadmap owner/number> <out>
  local roadmap=$1 out=$2 owner number
  owner=${roadmap%/*}
  number=${roadmap##*/}
  [ -n "$owner" ] && [ -n "$number" ] && [ "$owner" != "$number" ] || return 1
  run_gh_toon_json "$out.raw.json" project item-list "$number" --owner "$owner" --limit "$FM_CONTINUOUS_OPS_GITHUB_PROJECT_LIMIT" || return $?
  if ! jq -e 'type == "object" and (.items | type == "array")' "$out.raw.json" >/dev/null 2>&1; then
    SUMMARY_ERROR="roadmap $roadmap did not decode into an item list"
    rm -f "$out.raw.json" 2>/dev/null || true
    return 1
  fi
  if jq -e '
    (.count // "" | tostring) as $c
    | ($c | test("^[0-9]+ of [0-9]+ total$"))
    and (($c | split(" ")[0] | tonumber) < ($c | split(" ")[2] | tonumber))
  ' "$out.raw.json" >/dev/null 2>&1; then
    SUMMARY_ERROR="roadmap $roadmap was partial at limit $FM_CONTINUOUS_OPS_GITHUB_PROJECT_LIMIT"
    rm -f "$out.raw.json" 2>/dev/null || true
    return 2
  fi
  jq '.items' "$out.raw.json" > "$out" || {
    rm -f "$out.raw.json" 2>/dev/null || true
    return 1
  }
  rm -f "$out.raw.json" 2>/dev/null || true
}

collect_duplicate_inventory() {  # <project> <out>
  local project=$1 out=$2 line home remote projects meta backlog rc=0
  : > "$out" || return 1
  if [ -f "$BACKLOG_FILE" ] && [ ! -L "$BACKLOG_FILE" ]; then
    tasks-axi list --file "$BACKLOG_FILE" --limit 10000 --fields body,links,priority,blocked,blocked_by,created \
      >> "$out" 2>/dev/null || return 1
  fi
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    cat "$meta" >> "$out" 2>/dev/null || return 1
  done
  [ -f "$DATA/secondmates.md" ] && [ ! -L "$DATA/secondmates.md" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- "*) ;; *) continue ;; esac
    if ! secondmate_registry_parse_line "$line"; then
      SUMMARY_ERROR="malformed secondmate registry entry while checking duplicate work"
      return 1
    fi
    projects=$SECONDMATE_REGISTRY_PROJECTS
    case ",$(printf '%s' "$projects" | tr -d ' ')," in *",$project,"*) ;; *) continue ;; esac
    remote=$SECONDMATE_REGISTRY_REMOTE
    if [ "$remote" -eq 1 ]; then
      SUMMARY_ERROR="remote secondmate inventory for $project cannot be scanned locally"
      return 2
    fi
    home=$SECONDMATE_REGISTRY_HOME
    backlog="$home/data/backlog.md"
    [ -f "$backlog" ] && [ ! -L "$backlog" ] || {
      SUMMARY_ERROR="secondmate backlog for $project is unavailable: $backlog"
      return 1
    }
    tasks-axi list --file "$backlog" --limit 10000 --fields body,links,priority,blocked,blocked_by,created \
      >> "$out" 2>/dev/null || return 1
    for meta in "$home/state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      cat "$meta" >> "$out" 2>/dev/null || return 1
    done
  done < "$DATA/secondmates.md"
  return "$rc"
}

unknown_records_for_issues() {  # <project> <repo> <issues-json> <reason> <out>
  local project=$1 repo=$2 issues=$3 reason=$4 out=$5
  jq -c \
    --arg scanned_at "$SCAN_AT" \
    --arg fresh_until "$FRESH_UNTIL" \
    --arg project "$project" \
    --arg repo "$repo" \
    --arg reason "$reason" '
    def issue_url($repo; $n): "https://github.com/\($repo)/issues/\($n)";
    .[]
    | select(.pull_request? | not)
    | {
        version:1,
        scanned_at:$scanned_at,
        source_fresh_until:$fresh_until,
        project:$project,
        repo:$repo,
        number:.number,
        issue_url:issue_url($repo; .number),
        title:(.title // ""),
        verdict:"eligibility_unknown",
        code:"source_unavailable",
        evidence:[$reason],
        source_freshness:{state:"unknown", reason:$reason},
        rank:{roadmap:99, priority:99, milestone:99, created:(.created_at // "")},
        task_id:null
      }
  ' "$issues" >> "$out"
}

unknown_project_record() {  # <project> <repo> <reason> <out>
  local project=$1 repo=$2 reason=$3 out=$4
  jq -cn \
    --arg scanned_at "$SCAN_AT" \
    --arg fresh_until "$FRESH_UNTIL" \
    --arg project "$project" \
    --arg repo "$repo" \
    --arg reason "$reason" '
    {
      version:1,
      scanned_at:$scanned_at,
      source_fresh_until:$fresh_until,
      project:$project,
      repo:$repo,
      number:null,
      issue_url:null,
      title:"project eligibility unknown",
      verdict:"eligibility_unknown",
      code:"source_unavailable",
      evidence:[$reason],
      source_freshness:{state:"unknown", reason:$reason},
      rank:{roadmap:99, priority:99, milestone:99, created:""},
      task_id:null
    }' >> "$out"
}

classify_project() {  # <project> <repo> <issues> <prs> <branches> <milestones> <commits> <roadmap> <inventory> <out>
  local project=$1 repo=$2 issues=$3 prs=$4 branches=$5 milestones=$6 commits=$7 roadmap=$8 inventory=$9 out=${10}
  jq -c \
    --arg scanned_at "$SCAN_AT" \
    --arg fresh_until "$FRESH_UNTIL" \
    --arg project "$project" \
    --arg repo "$repo" \
    --rawfile inventory_text "$inventory" \
    --slurpfile prs_file "$prs" \
    --slurpfile branches_file "$branches" \
    --slurpfile milestones_file "$milestones" \
    --slurpfile commits_file "$commits" \
    --slurpfile roadmap_file "$roadmap" '
    def labels_text:
      if . == null then ""
      elif type == "array" then map(if type == "object" then (.name // "") else tostring end) | join(",")
      else tostring end;
    def milestone_title:
      if . == null then ""
      elif type == "object" then (.title // "")
      else tostring end;
    def milestone_number:
      if . == null then null
      elif type == "object" then (.number // null)
      else null end;
    def lc: ascii_downcase;
    def has_any($s; $arr): any($arr[]; . as $needle | ($s | contains($needle)));
    def issue_url($repo; $n): "https://github.com/\($repo)/issues/\($n)";
    def priority_rank($labels; $text):
      (($labels + " " + $text) | lc) as $all
      | if ($all | test("(^|[^a-z0-9])p0([^a-z0-9]|$)")) then 0
        elif ($all | test("(^|[^a-z0-9])p1([^a-z0-9]|$)")) then 1
        elif ($all | test("(^|[^a-z0-9])p2([^a-z0-9]|$)")) then 2
        elif ($all | test("(^|[^a-z0-9])p3([^a-z0-9]|$)")) then 3
        elif ($all | test("(^|[^a-z0-9])p4([^a-z0-9]|$)")) then 4
        else 5 end;
    def roadmap_rank($status):
      ($status | lc) as $s
      | if $s == "prepared/awaiting slot" then 0
        elif $s == "later" then 1
        elif $s == "backlog (untriaged)" then 2
        elif $s == "" then 3
        elif $s == "next (not prepared)" then 20
        elif $s == "decision-gated" then 21
        elif $s == "future-held" then 22
        elif $s == "certifying" then 23
        elif $s == "shipped" then 24
        else 10 end;
    def task_id($project; $n):
      "gh-" + (($project | lc | gsub("[^a-z0-9]+";"-") | gsub("^-|-$";"")) // "project") + "-" + ($n|tostring);
    def compact($s): ($s | tostring | gsub("[\t\r\n]+";" ") | gsub("  +";" "));

    ($prs_file[0] // []) as $prs
    | ($branches_file[0] // []) as $branches
    | ($milestones_file[0] // []) as $milestones
    | ($commits_file[0] // []) as $commits
    | ($roadmap_file[0] // []) as $roadmap
    | ($roadmap | map(select((.number // null) != null) | {key:(.number|tostring), value:.}) | from_entries) as $roadmap_by_issue
    | ($milestones
       | sort_by((.due_on // "9999-99-99"), (.number // 999999), (.title // ""))
       | to_entries
       | map(select(.value.number != null) | {key:(.value.number|tostring), value:.key})
       | from_entries) as $milestone_rank
    | ($prs | map(((.title // "") + " " + (.body // "") + " " + (.head.ref // "") + " " + (.number | tostring)) | lc)) as $pr_texts
    | ($branches | map((.name // "") | lc)) as $branch_texts
    | ($commits | map(((.commit.message // .message // "") | lc))) as $commit_texts
    | ($inventory_text | lc) as $inventory
    | .[]
    | select(.pull_request? | not)
    | (.number | tostring) as $num
    | (.number) as $number
    | (.title // "") as $title
    | (.body // "") as $body
    | (.labels | labels_text) as $labels
    | (.milestone | milestone_title) as $milestone
    | (.milestone | milestone_number) as $milestone_num
    | issue_url($repo; $number) as $url
    | task_id($project; $number) as $task_id
    | ($title + " " + $body + " " + $labels | lc) as $text
    | ($text
       | gsub("does not require production access"; "")
       | gsub("does not require credentials"; "")
       | gsub("without production access"; "")
       | gsub("without credentials"; "")
       | gsub("no production access"; "")
       | gsub("no credentials"; "")
       | gsub("no credential"; "")
       | gsub("no deployment"; "")
      ) as $gate_text
    | ($roadmap_by_issue[$num] // {}) as $road
    | (($road.status // "") | tostring) as $status
    | (($road.gate // $road.Gate // "") | tostring) as $gate
    | (($road.iteration // $road.Iteration // "") | tostring) as $iteration
    | (($road.priority // $road.Priority // "") | tostring) as $road_priority
    | (["#\($num)", "/issues/\($num)", "issue-\($num)", $task_id] | map(lc)) as $needles
    | (any($pr_texts[]; . as $p | any($needles[]; . as $needle | ($p | contains($needle))))) as $open_pr
    | (any($branch_texts[]; . as $b | ($b | contains("issue-\($num)")) or ($b | contains("/\($num)-")) or ($b | contains("-\($num)-")))) as $branch
    | (any($commit_texts[]; . as $c | ($c | contains("#\($num)")) or ($c | contains("(\("#\($num)")")))) as $landed
    | (($inventory | contains("/issues/\($num)")) or ($inventory | contains("issue #\($num)")) or ($inventory | contains("github #\($num)")) or ($inventory | contains($task_id))) as $backlog
    | ($gate != "" and ($gate | lc) != "none" and ($gate | lc) != "null") as $has_gate
    | (($status | lc) as $s | $s == "shipped") as $road_shipped
    | (($status | lc) as $s | ($s == "decision-gated" or $s == "future-held" or $s == "next (not prepared)" or $s == "certifying")) as $road_held
    | has_any($text; [
        "planning only",
        "implementation is not authorized",
        "for consideration only",
        "not scoped work",
        "proposal only",
        "nothing here is a decision",
        "not a commitment"
      ]) as $planning
    | has_any($text; [
        "captain decision",
        "decision first",
        "decision-first",
        "requires a decision",
        "needs decision",
        "document-ownership decision"
      ]) as $decision
    | has_any($gate_text; [
        "blocked by",
        "depends on",
        "dependency",
        "prerequisite",
        "wait for",
        "waiting for",
        "upstream",
        "not before",
        "date-gated",
        "future iteration",
        "credential",
        "production access",
        "deployment",
        "migration",
        "destructive",
        "security",
        "security-sensitive",
        "security sensitive",
        "production verification",
        "release verified",
        "external hold"
      ]) as $blocked
    | has_any($text; [
        "investigate",
        "investigation",
        "audit",
        "qa pass",
        "real-device",
        "live qa",
        "measure",
        "research",
        "spike",
        "reconcile"
      ]) as $investigate
    | (has_any($text; [
        "acceptance",
        "verification",
        "proving test",
        "test",
        "scope",
        "implementation",
        "docs-only",
        "documentation",
        "comment-only",
        "no behavior change",
        "bounded",
        "ready for implementation"
      ])
      and has_any($text; [
        "acceptance",
        "verification",
        "proving test",
        "test",
        "docs build",
        "no behavior change",
        "rg ",
        "assert"
      ])) as $ready_proof
    | (if $road_shipped or $landed then
        {verdict:"already_shipped", code:(if $road_shipped then "roadmap_shipped" else "landed_default_branch" end),
         evidence:[if $road_shipped then "Roadmap status is Shipped" else "Default-branch history mentions #\($num)" end]}
      elif $open_pr or $branch or $backlog then
        {verdict:"duplicate_active", code:(if $open_pr then "open_pr" elif $branch then "remote_branch" else "local_or_secondmate_inventory" end),
         evidence:[
           (if $open_pr then "An open PR references #\($num)" else empty end),
           (if $branch then "A remote branch references issue-\($num) or \($num)" else empty end),
           (if $backlog then "Local or secondmate inventory already references #\($num)" else empty end)
         ]}
      elif $has_gate or $road_held or $planning or $decision then
        {verdict:"held", code:(if $has_gate then "roadmap_gate" elif $road_held then "roadmap_status_hold" elif $planning then "planning_only" else "decision_gated" end),
         evidence:[
           (if $status != "" then "Roadmap status: \($status)" else empty end),
           (if $gate != "" then "Roadmap gate: \($gate)" else empty end),
           (if $planning then "Issue text says planning/consideration only or implementation is not authorized" else empty end),
           (if $decision then "Issue text names a decision requirement" else empty end)
         ]}
      elif $blocked then
        {verdict:"blocked", code:"dependency_or_access_gate",
         evidence:["Issue text names dependency, credential, deployment, migration, destructive, production, or date-gated work"]}
      elif $investigate then
        {verdict:"investigation_first", code:"investigation_or_live_validation_first",
         evidence:["Issue text points to investigation, audit, QA, live validation, measurement, research, or reconciliation before shipping"]}
      elif ($ready_proof | not) then
        {verdict:"ambiguous", code:"needs_semantic_classification",
         evidence:["No deterministic Ready proof found; requires firstmate classification before queue admission"]}
      else
        {verdict:"ready", code:"bounded_ready",
         evidence:[
           "Issue text contains bounded implementation scope and verification evidence",
           "No local, secondmate, PR, branch, landed-history, roadmap, gate, or dependency exclusion matched"
         ]}
      end) as $decision
    | {
        version:1,
        scanned_at:$scanned_at,
        source_fresh_until:$fresh_until,
        project:$project,
        repo:$repo,
        number:$number,
        issue_url:$url,
        title:$title,
        labels:$labels,
        milestone:$milestone,
        roadmap_status:$status,
        roadmap_gate:$gate,
        roadmap_iteration:$iteration,
        roadmap_priority:$road_priority,
        verdict:$decision.verdict,
        code:$decision.code,
        evidence:($decision.evidence | map(select(. != null and . != "")) | map(compact(.))),
        source_freshness:{
          state:"fresh",
          scanned_at:$scanned_at,
          fresh_until:$fresh_until,
          sources:(["issues","open_prs","remote_branches","milestones","default_branch_commits","local_inventory","secondmate_inventory"] + (if ($roadmap | length) > 0 then ["roadmap"] else [] end))
        },
        rank:{
          roadmap:roadmap_rank($status),
          priority:priority_rank(($road_priority + " " + $labels); $text),
          milestone:(if $milestone_num == null then 999999 else (($milestone_rank[$milestone_num|tostring] // 999998)) end),
          created:(.created_at // "")
        },
        task_id:(if $decision.verdict == "ready" then $task_id else null end)
      }
  ' "$issues" >> "$out"
}

scan_project() {  # <project> <repo> <roadmap> <default-branch> <ledger-out>
  local project=$1 repo=$2 roadmap=$3 configured_default=$4 ledger_out=$5
  local tmp repo_json issues prs branches milestones commits roadmap_json inventory default_branch issue_count commit_pages
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-cogh-project.XXXXXX") || return 1
  repo_json="$tmp/repo.json"
  issues="$tmp/issues.json"
  prs="$tmp/prs.json"
  branches="$tmp/branches.json"
  milestones="$tmp/milestones.json"
  commits="$tmp/commits.json"
  roadmap_json="$tmp/roadmap.json"
  inventory="$tmp/inventory.txt"
  printf '[]\n' > "$roadmap_json"

  SUMMARY_PROJECTS=$((SUMMARY_PROJECTS + 1))
  if [ -z "$repo" ]; then
    unknown_project_record "$project" "$repo" "project has no configured repo and no GitHub origin clone" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + 1))
    rm -rf "$tmp"
    return 0
  fi
  if ! gh_api_object "/repos/$repo" "$repo_json"; then
    SCAN_PRESERVE_LEDGER=1
    unknown_project_record "$project" "$repo" "repo metadata could not be scanned: ${SUMMARY_ERROR:-gh-axi failed}" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + 1))
    rm -rf "$tmp"
    return 0
  fi
  default_branch=$configured_default
  [ -n "$default_branch" ] || default_branch=$(jq -r '.default_branch // "main"' "$repo_json")

  if ! gh_api_paged_array "/repos/$repo/issues?state=open" "$issues"; then
    SCAN_PRESERVE_LEDGER=1
    unknown_project_record "$project" "$repo" "open issues could not be scanned completely: ${SUMMARY_ERROR:-gh-axi failed}" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + 1))
    rm -rf "$tmp"
    return 0
  fi
  issue_count=$(jq '[.[] | select(.pull_request? | not)] | length' "$issues")
  SUMMARY_OPEN_ISSUES=$((SUMMARY_OPEN_ISSUES + issue_count))
  if ! gh_api_paged_array "/repos/$repo/pulls?state=open" "$prs"; then
    unknown_records_for_issues "$project" "$repo" "$issues" "open PRs could not be scanned completely: ${SUMMARY_ERROR:-gh-axi failed}" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + issue_count))
    rm -rf "$tmp"
    return 0
  fi
  if ! gh_api_paged_array "/repos/$repo/branches" "$branches"; then
    unknown_records_for_issues "$project" "$repo" "$issues" "remote branches could not be scanned completely: ${SUMMARY_ERROR:-gh-axi failed}" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + issue_count))
    rm -rf "$tmp"
    return 0
  fi
  if ! gh_api_paged_array "/repos/$repo/milestones?state=open" "$milestones"; then
    unknown_records_for_issues "$project" "$repo" "$issues" "open milestones could not be scanned completely: ${SUMMARY_ERROR:-gh-axi failed}" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + issue_count))
    rm -rf "$tmp"
    return 0
  fi
  commit_pages=$(( (FM_CONTINUOUS_OPS_GITHUB_COMMIT_LIMIT + FM_CONTINUOUS_OPS_GITHUB_PER_PAGE - 1) / FM_CONTINUOUS_OPS_GITHUB_PER_PAGE ))
  [ "$commit_pages" -gt 0 ] || commit_pages=1
  if ! FM_CONTINUOUS_OPS_GITHUB_MAX_PAGES=$commit_pages gh_api_paged_array "/repos/$repo/commits?sha=$default_branch" "$commits" "$FM_CONTINUOUS_OPS_GITHUB_COMMIT_LIMIT"; then
    unknown_records_for_issues "$project" "$repo" "$issues" "default-branch history could not be scanned completely: ${SUMMARY_ERROR:-gh-axi failed}" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + issue_count))
    rm -rf "$tmp"
    return 0
  fi
  if [ -n "$roadmap" ]; then
    if ! roadmap_items "$roadmap" "$roadmap_json"; then
      unknown_records_for_issues "$project" "$repo" "$issues" "configured Roadmap could not be scanned completely: ${SUMMARY_ERROR:-gh-axi project item-list failed}" "$ledger_out"
      SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + issue_count))
      rm -rf "$tmp"
      return 0
    fi
  fi
  if ! collect_duplicate_inventory "$project" "$inventory"; then
    unknown_records_for_issues "$project" "$repo" "$issues" "local or secondmate duplicate-work inventory could not be scanned: ${SUMMARY_ERROR:-tasks-axi failed}" "$ledger_out"
    SUMMARY_UNKNOWN=$((SUMMARY_UNKNOWN + issue_count))
    rm -rf "$tmp"
    return 0
  fi

  classify_project "$project" "$repo" "$issues" "$prs" "$branches" "$milestones" "$commits" "$roadmap_json" "$inventory" "$ledger_out"
  rm -rf "$tmp"
}

task_exists() {  # <id>
  local id=$1
  tasks-axi show "$id" --file "$BACKLOG_FILE" >/dev/null 2>&1
}

append_admitted() {  # <record-json>
  local record=$1 key
  key=$(printf '%s\n' "$record" | jq -r '[.project,.repo,(.number|tostring),.task_id] | @tsv')
  mkdir -p "$(dirname "$ADMITTED_FILE")" 2>/dev/null || return 1
  if [ -f "$ADMITTED_FILE" ] && grep -F -- "$key" "$ADMITTED_FILE" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\t%s\n' "$key" "$SCAN_AT" >> "$ADMITTED_FILE"
  chmod 600 "$ADMITTED_FILE" 2>/dev/null || true
}

admit_record() {  # <record-json>
  local record=$1 task_id title body tmp priority out rc=0
  task_id=$(printf '%s\n' "$record" | jq -r '.task_id')
  title=$(printf '%s\n' "$record" | jq -r '"GitHub #\(.number): \(.title)"')
  priority=$(printf '%s\n' "$record" | jq -r '(.rank.priority // 5) | if . > 4 then 3 else . end')
  if task_exists "$task_id"; then
    append_admitted "$record" || true
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-cogh-body.XXXXXX") || return 1
  body=$(printf '%s\n' "$record" | jq -r '
    "GitHub candidate admitted by Continuous Operations v2.\n\n" +
    "Project: \(.project)\n" +
    "Repository: \(.repo)\n" +
    "Issue: \(.issue_url)\n" +
    "Verdict: \(.verdict) (\(.code))\n" +
    "Evidence freshness: \(.scanned_at) through \(.source_fresh_until)\n" +
    "Ledger: \($ledger)\n\n" +
    "Evidence:\n" +
    (.evidence | map("- " + .) | join("\n")) + "\n\n" +
    "Dispatch note: firstmate must still route, brief, isolate, and dispatch this item under the existing project, secondmate, delivery-mode, profile, approval, security, deployment, and decision boundaries."
  ' --arg ledger "$LEDGER_FILE")
  printf '%s\n' "$body" > "$tmp"
  out=$(tasks-axi add "$task_id" "$title" --file "$BACKLOG_FILE" --kind ship --repo "$(printf '%s\n' "$record" | jq -r '.project')" --body-file "$tmp" --queue --priority "$priority" --json 2>&1) || rc=$?
  rm -f "$tmp" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    if task_exists "$task_id"; then
      append_admitted "$record" || true
      return 0
    fi
    SUMMARY_ERROR="tasks-axi add failed for $task_id: $(printf '%s\n' "$out" | head -2 | tr '\n' ' ')"
    return "$rc"
  fi
  append_admitted "$record" || true
  SUMMARY_ADMITTED=$((SUMMARY_ADMITTED + 1))
}

admit_ready_records() {
  local record rc=0
  [ -s "$LEDGER_FILE.new" ] || return 0
  while IFS= read -r record || [ -n "$record" ]; do
    [ -n "$record" ] || continue
    if ! admit_record "$record"; then
      rc=1
      break
    fi
  done < <(jq -c -s '
    map(select(.verdict == "ready"))
    | sort_by(.rank.roadmap, .rank.priority, .rank.milestone, .rank.created, .project, .number)
    | .[]
  ' "$LEDGER_FILE.new")
  return "$rc"
}

summarize_new_ledger() {
  [ -s "$LEDGER_FILE.new" ] || {
    SUMMARY_CANDIDATES=0
    SUMMARY_READY=0
    SUMMARY_UNKNOWN=0
    SUMMARY_FINGERPRINT=$(printf 'empty\n' | cksum | awk '{ print $1 ":" $2 }')
    return 0
  }
  SUMMARY_CANDIDATES=$(jq -s 'length' "$LEDGER_FILE.new")
  SUMMARY_READY=$(jq -s '[.[] | select(.verdict == "ready")] | length' "$LEDGER_FILE.new")
  SUMMARY_UNKNOWN=$(jq -s '[.[] | select(.verdict == "eligibility_unknown")] | length' "$LEDGER_FILE.new")
  SUMMARY_FINGERPRINT=$(cksum "$LEDGER_FILE.new" | awk '{ print $1 ":" $2 }')
}

cmd_refresh() {  # <reason>
  local reason=$1 project repo roadmap default_branch projects tmp last_success state record_count
  mkdir -p "$STATE" "$DATA" 2>/dev/null || {
    printf 'error: could not create state/data directories\n'
    return 1
  }
  if ! refresh_due; then
    [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-cogh-scan.XXXXXX") || return 1
  projects="$tmp/projects.tsv"
  configured_projects > "$projects"
  if [ ! -s "$projects" ]; then
    SUMMARY_STATE=skipped
    SUMMARY_REASON="no configured GitHub-backed projects found"
    SUMMARY_FINGERPRINT=$(printf 'no-projects\n' | cksum | awk '{ print $1 ":" $2 }')
    status_write "$SUMMARY_STATE" "$SUMMARY_REASON" "" "$SUMMARY_FINGERPRINT" || true
    rm -rf "$tmp"
    [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    SUMMARY_STATE=unknown
    SUMMARY_REASON="jq is unavailable; cannot classify GitHub candidates"
    status_write "$SUMMARY_STATE" "$SUMMARY_REASON" "$(status_get last_success_epoch)" "$(status_get fingerprint)" || true
    rm -rf "$tmp"
    [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
    return 0
  fi
  if ! command -v gh-axi >/dev/null 2>&1; then
    SUMMARY_STATE=unknown
    SUMMARY_REASON="gh-axi is unavailable; cannot scan GitHub"
    status_write "$SUMMARY_STATE" "$SUMMARY_REASON" "$(status_get last_success_epoch)" "$(status_get fingerprint)" || true
    rm -rf "$tmp"
    [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
    return 0
  fi
  if ! fm_tasks_axi_backend_available "$CONFIG"; then
    SUMMARY_STATE=unknown
    SUMMARY_REASON="compatible tasks-axi backend is unavailable; queue admission and duplicate checks are unsafe"
    status_write "$SUMMARY_STATE" "$SUMMARY_REASON" "$(status_get last_success_epoch)" "$(status_get fingerprint)" || true
    rm -rf "$tmp"
    [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
    return 0
  fi

  SCAN_AT=$(now_iso)
  NOW_EPOCH=$(now_epoch)
  FRESH_UNTIL=$(date -u -d "@$((NOW_EPOCH + FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$((NOW_EPOCH + FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u +%Y-%m-%dT%H:%M:%SZ)
  LEDGER_FILE_NEW="$LEDGER_FILE.new"
  : > "$LEDGER_FILE_NEW" || {
    rm -rf "$tmp"
    return 1
  }

  while IFS=$(printf '\t') read -r project repo roadmap default_branch || [ -n "$project$repo$roadmap$default_branch" ]; do
    [ -n "$project" ] || continue
    scan_project "$project" "$repo" "$roadmap" "$default_branch" "$LEDGER_FILE_NEW"
  done < "$projects"

  summarize_new_ledger
  if [ "$SCAN_PRESERVE_LEDGER" -eq 1 ]; then
    SUMMARY_STATE=unknown
    SUMMARY_REASON="a required GitHub source was unavailable before candidates could be refreshed; preserving the previous ledger"
    rm -f "$LEDGER_FILE_NEW" 2>/dev/null || true
    last_success=$(status_get last_success_epoch)
    status_write "$SUMMARY_STATE" "$SUMMARY_REASON" "$last_success" "$(status_get fingerprint)" || true
    rm -rf "$tmp"
    [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
    return 0
  fi

  if ! admit_ready_records; then
    SUMMARY_STATE=unknown
    SUMMARY_REASON="queue admission failed after scan: ${SUMMARY_ERROR:-tasks-axi add failed}"
    rm -f "$LEDGER_FILE_NEW" 2>/dev/null || true
    last_success=$(status_get last_success_epoch)
    status_write "$SUMMARY_STATE" "$SUMMARY_REASON" "$last_success" "$(status_get fingerprint)" || true
    rm -rf "$tmp"
    [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
    return 1
  fi

  mv -f "$LEDGER_FILE_NEW" "$LEDGER_FILE"
  chmod 600 "$LEDGER_FILE" 2>/dev/null || true
  record_count=$SUMMARY_CANDIDATES
  if [ "$SUMMARY_UNKNOWN" -gt 0 ]; then
    state=unknown
    SUMMARY_REASON="one or more candidate sources were unavailable or incomplete"
  else
    state=fresh
    SUMMARY_REASON=$reason
  fi
  SUMMARY_STATE=$state
  status_write "$SUMMARY_STATE" "$SUMMARY_REASON" "$NOW_EPOCH" "$SUMMARY_FINGERPRINT" || true
  rm -rf "$tmp"
  [ "$record_count" -ge 0 ] || true
  [ "${PRINT_SUMMARY:-0}" -eq 0 ] || print_status
  return 0
}

print_ready_rows() {
  [ -s "$LEDGER_FILE" ] || return 0
  jq -r -s '
    [ .[] | select(.verdict == "ready") ]
    | sort_by(.rank.roadmap, .rank.priority, .rank.milestone, .rank.created, .project, .number)
    | "ready[" + (length|tostring) + "]{project,repo,number,task_id,title}:",
      (.[] | "  " + ([.project,.repo,(.number|tostring),.task_id,((.title // "") | gsub("[\t\r\n]+";" "))] | @tsv))
  ' "$LEDGER_FILE"
}

print_exclusion_rows() {
  [ -s "$LEDGER_FILE" ] || return 0
  jq -r -s '
    [ .[] | select(.verdict != "ready") ][0:20]
    | "excluded[" + (length|tostring) + "]{project,number,verdict,code,evidence}:",
      (.[] | "  " + ([.project,((.number // "-")|tostring),.verdict,.code,((.evidence[0] // "") | gsub("[\t\r\n]+";" "))] | @tsv))
  ' "$LEDGER_FILE"
}

effective_state() {
  local state last_success
  state=$(status_get state)
  last_success=$(status_get last_success_epoch)
  if [ "$state" = fresh ]; then
    case "$last_success" in
      ''|*[!0-9]*) state=unknown ;;
      *) [ $(( $(now_epoch) - last_success )) -le "$FM_CONTINUOUS_OPS_GITHUB_MAX_AGE_SECONDS" ] || state=unknown ;;
    esac
  fi
  printf '%s\n' "${state:-absent}"
}

print_status() {
  local state reason
  state=$(effective_state)
  reason=$(status_get reason)
  printf 'continuous_ops_github:\n'
  printf '  state: %s\n' "$state"
  printf '  reason: %s\n' "${reason:-none}"
  printf '  projects: %s\n' "$(status_get projects)"
  printf '  open_issues: %s\n' "$(status_get open_issues)"
  printf '  candidates: %s\n' "$(status_get candidates)"
  printf '  ready: %s\n' "$(status_get ready)"
  printf '  admitted: %s\n' "$(status_get admitted)"
  printf '  unknown: %s\n' "$(status_get unknown)"
  printf '  ledger: %s\n' "$LEDGER_FILE"
  if [ -s "$LEDGER_FILE" ]; then
    print_ready_rows
    print_exclusion_rows
  else
    printf 'ledger: absent\n'
  fi
}

cmd_ledger() {
  if [ ! -s "$LEDGER_FILE" ]; then
    printf 'ledger: absent\n'
    return 0
  fi
  print_ready_rows
  print_exclusion_rows
  printf 'help[1]:\n'
  printf '  Run jq -s . %s for the full inspectable candidate ledger\n' "$LEDGER_FILE"
}

MODE=${1:-status}
[ $# -eq 0 ] || shift
FORCE_REFRESH=0
PRINT_SUMMARY=0
REASON=manual
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE_REFRESH=1; shift ;;
    --print) PRINT_SUMMARY=1; shift ;;
    --reason)
      if [ $# -lt 2 ]; then
        printf 'error: --reason requires a value\n'
        printf 'help: fm-continuous-ops-github.sh refresh --reason <reason>\n'
        exit 2
      fi
      REASON=$2
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'error: unknown argument %s\n' "$1"
      printf 'help: fm-continuous-ops-github.sh refresh [--force] [--reason <reason>] [--print]\n'
      exit 2
      ;;
  esac
done

case "$MODE" in
  refresh)
    fm_lock_acquire_wait "$LOCK_FILE"
    cmd_refresh "$REASON"
    rc=$?
    fm_lock_release "$LOCK_FILE"
    exit "$rc"
    ;;
  status) print_status ;;
  ledger) cmd_ledger ;;
  -h|--help) usage ;;
  *)
    printf 'error: unknown mode %s\n' "$MODE"
    printf 'help: fm-continuous-ops-github.sh refresh|status|ledger\n'
    exit 2
    ;;
esac
