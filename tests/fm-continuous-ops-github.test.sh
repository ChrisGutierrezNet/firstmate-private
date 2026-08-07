#!/usr/bin/env bash
# Behavior tests for Continuous Operations v2 GitHub discovery.
#
# The tests drive the public executable and the sourced continuous-ops refresh
# path with fake gh-axi, tasks-axi, and clock-independent fixtures. No live
# network call is made. The fixture pins the historical failure class: the local
# Ready queue starts empty while GitHub has 144 open issues, including two
# bounded, unclaimed Ready issues.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-continuous-ops-github)
HELPER="$ROOT/bin/fm-continuous-ops-lib.sh"
GITHUB="$ROOT/bin/fm-continuous-ops-github.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

make_case() {  # <name>
  local name=$1 dir home fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf 'social repo=Fixture/social roadmap=Fixture/7 default_branch=main\n' \
    > "$home/config/continuous-ops-github-projects"
  printf 'existing-901|in_flight|Existing duplicate|social|https://github.com/Fixture/social/issues/901\n' \
    > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$dir")
  write_fake_tasks_axi "$fakebin/tasks-axi"
  write_fake_gh_axi "$fakebin/gh-axi"
  printf '%s\n' "$dir"
}

home_of() { printf '%s/home\n' "$1"; }
state_of() { printf '%s/home/state\n' "$1"; }
fakebin_of() { printf '%s/fakebin\n' "$1"; }
backlog_of() { printf '%s/home/data/backlog.md\n' "$1"; }

write_fake_tasks_axi() {  # <path>
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u

cmd=${1:-}
[ $# -eq 0 ] || shift

file=${FM_FAKE_TASKS_FILE:-}
extract_file() {
  local arg
  while [ $# -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
      --file)
        file=${1:-}
        [ $# -eq 0 ] || shift
        ;;
      --file=*) file=${arg#--file=} ;;
    esac
  done
  [ -n "$file" ] || file=${FM_FAKE_TASKS_FILE:?missing fake tasks file}
}

case "$cmd" in
  --version|-v|-V)
    printf '0.2.4\n'
    exit 0
    ;;
  update)
    if [ "${1:-}" = --help ]; then
      printf 'usage: tasks-axi update <id> [--archive-body]\n'
      exit 0
    fi
    ;;
  mv)
    if [ "${1:-}" = --help ]; then
      printf 'usage: tasks-axi mv <dest> [<id>...]\n'
      exit 0
    fi
    ;;
  show)
    id=${1:-}
    [ $# -eq 0 ] || shift
    extract_file "$@"
    grep -F -- "$id|" "$file" >/dev/null 2>&1
    exit $?
    ;;
  list)
    extract_file "$@"
    if [ -f "$file" ]; then
      cat "$file"
    fi
    exit 0
    ;;
  ready)
    extract_file "$@"
    count=0
    if [ -f "$file" ]; then
      while IFS='|' read -r id state _rest || [ -n "$id$state" ]; do
        [ "$state" = queued ] || continue
        count=$((count + 1))
      done < "$file"
    fi
    printf 'count: %s\n' "$count"
    printf 'ready[%s]{id,state,kind,repo,title}:\n' "$count"
    if [ -f "$file" ]; then
      while IFS='|' read -r id state title repo _body || [ -n "$id$state$title$repo" ]; do
        [ "$state" = queued ] || continue
        printf '  %s,queued,ship,%s,%s\n' "$id" "$repo" "$title"
      done < "$file"
    fi
    printf 'ready_public_followups: 0 delivery-ready obligations\n'
    printf 'help[1]:\n'
    printf '  Run tasks-axi start <id> to dispatch one of these\n'
    exit 0
    ;;
  add)
    id=${1:-}
    title=${2:-}
    [ $# -lt 2 ] || shift 2
    repo=
    body_file=
    state=queued
    while [ $# -gt 0 ]; do
      case "$1" in
        --file) file=${2:-}; shift 2 ;;
        --kind) shift 2 ;;
        --repo) repo=${2:-}; shift 2 ;;
        --body-file) body_file=${2:-}; shift 2 ;;
        --queue) state=queued; shift ;;
        --start) state=in_flight; shift ;;
        --priority) shift 2 ;;
        --json) shift ;;
        *) shift ;;
      esac
    done
    [ -n "$file" ] || file=${FM_FAKE_TASKS_FILE:?missing fake tasks file}
    mkdir -p "$(dirname "$file")"
    if grep -F -- "$id|" "$file" >/dev/null 2>&1; then
      printf 'error: task exists\n'
      exit 1
    fi
    body=
    [ -z "$body_file" ] || body=$(tr '\n' ' ' < "$body_file")
    printf '%s|%s|%s|%s|%s\n' "$id" "$state" "$title" "$repo" "$body" >> "$file"
    [ -z "${FM_FAKE_TASKS_ADD_LOG:-}" ] || printf '%s\n' "$id" >> "$FM_FAKE_TASKS_ADD_LOG"
    printf '{"id":"%s"}\n' "$id"
    exit 0
    ;;
esac

exit 0
SH
  chmod +x "$path"
}

write_fake_gh_axi() {  # <path>
  local path=$1
  cat > "$path" <<'SH'
#!/usr/bin/env bash
set -u

[ -z "${FM_FAKE_GH_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_GH_LOG"

page_of() {
  case "$1" in
    *page=2*) printf '2\n' ;;
    *page=3*) printf '3\n' ;;
    *) printf '1\n' ;;
  esac
}

emit_issues() {
  local page=$1
  jq -n --argjson page "$page" '
    def issue($n; $title; $body; $created; $msnum; $mstitle; $labels):
      {
        number:$n,
        title:$title,
        state:"open",
        body:$body,
        created_at:$created,
        updated_at:$created,
        labels:$labels,
        milestone:(if $msnum == 0 then null else {number:$msnum, title:$mstitle} end)
      };
    ([
      issue(900; "Correct stale deploy workflow comment"; "## Scope\nComment-only implementation: correct the stale current-version.txt workflow comment. No behavior change. No production access, no deployment, and no credentials are required.\n\n## Acceptance\nrg current-version.txt proves the stale over-claim is gone."; "2026-01-01T00:00:00Z"; 38; "Production Server Migration"; ["P2"]),
      issue(895; "Document conversation takeover release behavior"; "## Scope\nDocs-only implementation for conversation takeover release behavior, including pending 202 and manual Release recovery.\n\n## Acceptance\nDocs build and rg takeover show the new behavior."; "2026-01-02T00:00:00Z"; 31; "Documentation Refresh"; ["P2"]),
      issue(946; "Credentials suspension prerequisite"; "## Scope\nImplement suspension checks.\n\n## Acceptance\nTests pass.\n\nDepends on prerequisite release verified first."; "2026-01-03T00:00:00Z"; 38; "Production Server Migration"; ["P1"]),
      issue(1019; "AI structured-output hardening plan"; "Issue planning only. Implementation is not authorized by this item."; "2026-01-04T00:00:00Z"; 31; "Documentation Refresh"; ["P1"]),
      issue(853; "Research companion consideration"; "For consideration only. Nothing here is a decision, a commitment, or scoped work."; "2026-01-05T00:00:00Z"; 31; "Documentation Refresh"; ["P3"]),
      issue(978; "Dashboard selectors from registry"; "## Scope\nBounded implementation.\n\n## Acceptance\nTests pass."; "2026-01-06T00:00:00Z"; 31; "Documentation Refresh"; ["P1"]),
      issue(545; "Entitlement registry"; "## Scope\nBounded implementation.\n\n## Acceptance\nTests pass."; "2026-01-07T00:00:00Z"; 38; "Production Server Migration"; ["P0"]),
      issue(998; "MCP accounting calls"; "## Scope\nBounded implementation.\n\n## Acceptance\nTests pass."; "2026-01-08T00:00:00Z"; 38; "Production Server Migration"; ["P0"]),
      issue(901; "Ready but already in local inventory"; "## Scope\nBounded implementation.\n\n## Acceptance\nTests pass."; "2026-01-09T00:00:00Z"; 38; "Production Server Migration"; ["P2"])
    ] + [range(2000; 2135) | issue(.; "Ambiguous backlog issue \(.)"; "Open issue without deterministic Ready proof."; "2026-02-01T00:00:00Z"; 31; "Documentation Refresh"; [])]) as $base
    | (if env.FM_FAKE_ALL_INELIGIBLE == "1"
       then $base | map(if (.number == 900 or .number == 895)
                        then .body = "Issue planning only. Implementation is not authorized by this item."
                        else . end)
       else $base end)
    | .[(($page - 1) * 100):($page * 100)]
  '
}

emit_project_items() {
  jq -n '
    def row($n; $status; $gate; $priority): {number:$n, repository:"Fixture/social", status:$status, gate:$gate, priority:$priority};
    ([row(900; "Later"; "None"; "P2"),
      row(895; "Backlog (untriaged)"; "None"; "P0"),
      row(946; "Later"; "None"; "P1"),
      row(1019; "Backlog (untriaged)"; "None"; "P1"),
      row(853; "Decision-gated"; "Captain decision"; "P3"),
      row(978; "Certifying"; "None"; "P1"),
      row(545; "Prepared/awaiting slot"; "Billing review"; "P0"),
      row(998; "Later"; "None"; "P0"),
      row(901; "Later"; "None"; "P2")]
     + [range(2000; 2135) | row(.; "Backlog (untriaged)"; "None"; "")]) as $items
    | if env.FM_FAKE_ALL_INELIGIBLE == "1"
      then {count:"144", items:($items | map(if (.number == 900 or .number == 895) then .status = "Decision-gated" | .gate = "Captain decision" else . end))}
      else {count:"144", items:$items}
      end
  '
}

cmd=${1:-}
[ $# -eq 0 ] || shift
case "$cmd" in
  api)
    path=${1:-}
    [ "${FM_FAKE_GH_FAIL:-}" != issues ] || case "$path" in *'/issues?'*) printf 'error: unavailable\n'; exit 1 ;; esac
    case "$path" in
      /repos/Fixture/social)
        jq -n '{full_name:"Fixture/social", default_branch:"main"}'
        ;;
      /repos/Fixture/social/issues\?state=open*)
        emit_issues "$(page_of "$path")"
        ;;
      /repos/Fixture/social/pulls\?state=open*)
        jq -n '[{number:1005, title:"Fix MCP accounting (#998)", body:"Closes #998", head:{ref:"fm/issue-998-accounting"}}]'
        ;;
      /repos/Fixture/social/branches*)
        jq -n '[{name:"fm/issue-978-dashboard-selectors"}]'
        ;;
      /repos/Fixture/social/milestones\?state=open*)
        jq -n '[{number:38, title:"Production Server Migration", due_on:null}, {number:31, title:"Documentation Refresh", due_on:null}]'
        ;;
      /repos/Fixture/social/commits\?sha=main*)
        jq -n '[{sha:"abc123", commit:{message:"fix(ui): dashboard selectors from registry (#978)"}}]'
        ;;
      *)
        printf 'error: unexpected api path %s\n' "$path"
        exit 1
        ;;
    esac
    ;;
  project)
    sub=${1:-}
    number=${2:-}
    if [ "$sub" = item-list ] && [ "$number" = 7 ]; then
      [ "${FM_FAKE_GH_FAIL:-}" != roadmap ] || { printf 'error: roadmap unavailable\n'; exit 1; }
      emit_project_items
      exit 0
    fi
    printf 'error: unexpected project command\n'
    exit 1
    ;;
  *)
    printf 'error: unexpected gh-axi command %s\n' "$cmd"
    exit 1
    ;;
esac
SH
  chmod +x "$path"
}

run_github_refresh() {  # <case-dir> [extra env assignments...]
  local dir=$1 home state fakebin
  shift
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  fakebin=$(fakebin_of "$dir")
  env "$@" \
    PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TASKS_FILE="$home/data/backlog.md" \
    "$GITHUB" refresh --force --print
}

run_helper_refresh() {  # <case-dir> [extra env assignments...]
  local dir=$1 home state fakebin
  shift
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  fakebin=$(fakebin_of "$dir")
  env "$@" \
    PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TASKS_FILE="$home/data/backlog.md" \
    FM_CONTINUOUS_OPS_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    bash -c ". \"\$1\"; fm_continuous_ops_refresh \"\$2\"" _ "$HELPER" test
}

run_drain() {  # <case-dir> [extra env assignments...]
  local dir=$1 home state fakebin
  shift
  home=$(home_of "$dir")
  state=$(state_of "$dir")
  fakebin=$(fakebin_of "$dir")
  env "$@" \
    PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" \
    FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TASKS_FILE="$home/data/backlog.md" \
    FM_CONTINUOUS_OPS_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_SUPERVISION_MODEL=autoarm \
    "$DRAIN" 2>&1
}

append_wake() {  # <case-dir> <kind> <key> <payload>
  local dir=$1 kind=$2 key=$3 payload=$4 state
  state=$(state_of "$dir")
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$kind" "$key" "$payload"
}

jq_ledger() {  # <case-dir> <jq-filter>
  local dir=$1 filter=$2
  jq -r -s "$filter" "$(state_of "$dir")/.continuous-ops-github.ledger.jsonl"
}

test_v1_local_ready_zero_cannot_see_github_candidates() {
  local dir state out
  dir=$(make_case v1-blind)
  state=$(state_of "$dir")
  out=$(run_helper_refresh "$dir" FM_CONTINUOUS_OPS_GITHUB_DISABLE=1)
  [ -z "$out" ] || fail "disabled v1 refresh produced output: $out"
  assert_absent "$state/.continuous-ops-ready" "v1 local-ready-only path wrote a marker despite zero local ready rows"
  assert_absent "$state/.continuous-ops-github.ledger.jsonl" "disabled v1 path unexpectedly scanned GitHub"
  pass "continuous ops v1 reproducer stays blind when local Ready rows are zero"
}

test_github_refresh_surfaces_and_admits_two_ready_issues_from_144_open() {
  local dir out ledger ready added
  dir=$(make_case positive)
  out=$(run_github_refresh "$dir")
  ledger="$(state_of "$dir")/.continuous-ops-github.ledger.jsonl"
  assert_contains "$out" "ready: 2" "GitHub refresh did not surface two Ready issues"
  assert_contains "$out" "gh-social-900" "Ready issue #900 was not surfaced"
  assert_contains "$out" "gh-social-895" "Ready issue #895 was not surfaced"
  assert_grep "gh-social-900|queued" "$(backlog_of "$dir")" "Ready issue #900 was not admitted to the local queue"
  assert_grep "gh-social-895|queued" "$(backlog_of "$dir")" "Ready issue #895 was not admitted to the local queue"
  assert_no_grep "gh-social-946|queued" "$(backlog_of "$dir")" "blocked issue #946 was admitted"
  assert_no_grep "gh-social-1019|queued" "$(backlog_of "$dir")" "planning-only issue #1019 was admitted"
  [ "$(jq_ledger "$dir" 'length')" = 144 ] || fail "expected 144 GitHub candidate rows"
  ready=$(jq_ledger "$dir" '[.[] | select(.verdict == "ready")] | sort_by(.rank.roadmap, .rank.milestone, .number) | map(.number) | join(",")')
  [ "$ready" = "900,895" ] || fail "Ready set was not exactly #900,#895: $ready"
  [ "$(jq -r -s '.[] | select(.number == 946) | .verdict + ":" + .code' "$ledger")" = "blocked:dependency_or_access_gate" ] \
    || fail "#946 did not carry the dependency-blocked verdict"
  [ "$(jq -r -s '.[] | select(.number == 1019) | .verdict + ":" + .code' "$ledger")" = "held:planning_only" ] \
    || fail "#1019 did not carry the planning-only verdict"
  [ "$(jq -r -s '.[] | select(.number == 853) | .verdict + ":" + .code' "$ledger")" = "held:roadmap_gate" ] \
    || fail "#853 did not carry the decision/gate verdict"
  [ "$(jq -r -s '.[] | select(.number == 998) | .verdict + ":" + .code' "$ledger")" = "duplicate_active:open_pr" ] \
    || fail "#998 did not carry the active-PR verdict"
  [ "$(jq -r -s '.[] | select(.number == 978) | .verdict + ":" + .code' "$ledger")" = "already_shipped:landed_default_branch" ] \
    || fail "#978 did not carry the landed verdict"
  [ "$(jq -r -s '.[] | select(.number == 545) | .verdict + ":" + .code' "$ledger")" = "held:roadmap_gate" ] \
    || fail "#545 did not carry the production-held gate verdict"
  [ "$(jq -r -s '.[] | select(.number == 901) | .verdict + ":" + .code' "$ledger")" = "duplicate_active:local_or_secondmate_inventory" ] \
    || fail "#901 did not carry the local-inventory duplicate verdict"
  added=$(grep -c '|queued|' "$(backlog_of "$dir")" || true)
  [ "$added" -eq 2 ] || fail "expected exactly two queued admissions, got $added"
  pass "Continuous Ops v2 surfaces and admits bounded Ready GitHub issues from a zero-local-ready fixture"
}

test_true_zero_keeps_an_inspectable_exclusion_ledger() {
  local dir out ready excluded
  dir=$(make_case true-zero)
  out=$(run_github_refresh "$dir" FM_FAKE_ALL_INELIGIBLE=1)
  assert_contains "$out" "ready: 0" "all-ineligible fixture did not report true zero Ready"
  assert_contains "$out" "excluded[" "true zero did not print an exclusion ledger summary"
  assert_absent "$(state_of "$dir")/.continuous-ops-ready" "GitHub scanner should not write the v1 marker directly"
  ready=$(jq_ledger "$dir" '[.[] | select(.verdict == "ready")] | length')
  [ "$ready" -eq 0 ] || fail "all-ineligible ledger still had Ready candidates"
  excluded=$(jq_ledger "$dir" 'length')
  [ "$excluded" -eq 144 ] || fail "true zero ledger did not retain every candidate verdict: $excluded"
  assert_no_grep "|queued|" "$(backlog_of "$dir")" "all-ineligible fixture admitted queued work"
  pass "Continuous Ops v2 true zero is backed by an inspectable exclusion ledger"
}

test_failed_source_marks_unknown_and_preserves_previous_ledger() {
  local dir ledger before after status
  dir=$(make_case freshness)
  run_github_refresh "$dir" >/dev/null
  ledger="$(state_of "$dir")/.continuous-ops-github.ledger.jsonl"
  before=$(sha256sum "$ledger" | awk '{ print $1 }')
  run_github_refresh "$dir" FM_FAKE_GH_FAIL=issues >/dev/null
  after=$(sha256sum "$ledger" | awk '{ print $1 }')
  [ "$before" = "$after" ] || fail "failed issue scan replaced the previous candidate ledger"
  status="$(state_of "$dir")/.continuous-ops-github.status"
  assert_grep "state=unknown" "$status" "failed source did not mark eligibility unknown"
  assert_grep "preserving the previous ledger" "$status" "unknown status did not explain preserved evidence"
  pass "Continuous Ops v2 preserves prior evidence when a required GitHub source is unavailable"
}

test_helper_materializes_then_uses_v1_marker_and_deduped_wake() {
  local dir state
  dir=$(make_case integration)
  state=$(state_of "$dir")
  run_helper_refresh "$dir" >/dev/null
  assert_present "$state/.continuous-ops-ready" "helper did not write the v1 ready-plus-idle marker"
  assert_grep "ready_count=2" "$state/.continuous-ops-ready" "v1 marker did not see the GitHub-admitted ready rows"
  assert_grep "gh-social-900" "$state/.continuous-ops-ready" "v1 marker did not name the ranked GitHub admission"
  [ "$(grep -c "$(printf '\tcheck\tcontinuous-ops-ready\t')" "$state/.wake-queue" || true)" -eq 1 ] \
    || fail "helper did not emit exactly one deduped continuous-ops wake"
  pass "GitHub admission feeds the existing v1 marker and durable wake instead of dispatching directly"
}

test_cadence_skips_repeated_cheap_refreshes() {
  local dir log first second
  dir=$(make_case cadence)
  log="$dir/gh.log"
  run_helper_refresh "$dir" FM_FAKE_GH_LOG="$log" >/dev/null
  first=$(wc -l < "$log" | tr -d ' ')
  run_helper_refresh "$dir" FM_FAKE_GH_LOG="$log" >/dev/null
  second=$(wc -l < "$log" | tr -d ' ')
  [ "$first" -gt 0 ] || fail "first refresh did not scan GitHub"
  [ "$first" -eq "$second" ] || fail "second cheap refresh made more GitHub calls ($first -> $second)"
  pass "Continuous Ops v2 cadence avoids a GitHub scan on every cheap refresh"
}

test_event_wake_forces_fresh_scan_inside_cadence() {
  local dir log first second state
  dir=$(make_case event-force)
  state=$(state_of "$dir")
  log="$dir/gh.log"
  run_helper_refresh "$dir" FM_FAKE_GH_LOG="$log" >/dev/null
  first=$(wc -l < "$log" | tr -d ' ')
  append_wake "$dir" check "$state/task-a.check.sh" "check: $state/task-a.check.sh: merged"
  run_drain "$dir" FM_FAKE_GH_LOG="$log" >/dev/null
  second=$(wc -l < "$log" | tr -d ' ')
  [ "$second" -gt "$first" ] || fail "merged wake did not force a GitHub refresh inside cadence ($first -> $second)"
  pass "Continuous Ops v2 forces a fresh GitHub scan for merge wake events"
}

test_large_duplicate_inventory_is_file_backed() {
  local dir out
  dir=$(make_case large-inventory)
  {
    printf 'large-done|done|Large historical row|social|'
    head -c 2500000 /dev/zero | tr '\0' 'x'
    printf '\n'
  } >> "$(backlog_of "$dir")"
  out=$(run_github_refresh "$dir")
  assert_contains "$out" "ready: 2" "large duplicate inventory prevented Ready candidate classification"
  assert_grep "gh-social-900|queued" "$(backlog_of "$dir")" "large duplicate inventory prevented queue admission"
  pass "Continuous Ops v2 keeps duplicate inventory out of shell argument limits"
}

test_v1_local_ready_zero_cannot_see_github_candidates
test_github_refresh_surfaces_and_admits_two_ready_issues_from_144_open
test_true_zero_keeps_an_inspectable_exclusion_ledger
test_failed_source_marks_unknown_and_preserves_previous_ledger
test_helper_materializes_then_uses_v1_marker_and_deduped_wake
test_cadence_skips_repeated_cheap_refreshes
test_event_wake_forces_fresh_scan_inside_cadence
test_large_duplicate_inventory_is_file_backed
