#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_NM_SLEEP:-0}" = 1 ] && sleep 1
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  list-windows)
    sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

record_claude_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  # A working ship task proves it through its own semantic busy-state record
  # (bin/fm-busy-lib.sh), which is what the snapshot's current-state read
  # consults; rendered pane text is no longer a state source.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source claude-hook --event user-prompt-submit
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    "window=firstmate:fm-worker" "worktree=$home/projects/worker" "project=alpha" \
    "harness=codex" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .captain_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out hint_gen
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-decision
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  record_claude_idle "$home/state" active-blocked
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-decision)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-decision busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-blocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-blocked busy --gen "$hint_gen" \
    --source claude-hook --event user-prompt-submit
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" bold-task
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | scout | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log | secondmate | $home/secondmate-home | tmux | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    "window=firstmate:fm-masked-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    "window=firstmate:fm-active-secondmate" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_captain_hold() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    "window=firstmate:fm-transferred-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "captain-held transfer must close only the duplicate status copy: $out"
  pass "durable captain-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    "window=firstmate:fm-resolved-decision" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" lavish-103
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    "window=firstmate:fm-parked-scout" \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_idle "$home/state" parked-scout
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

# --- large-inventory argv transport ----------------------------------------
#
# A real fleet backlog serializes to more JSON than Linux permits in a SINGLE
# exec argument (MAX_ARG_STRLEN, 128 KiB) while the whole argument list stays far
# below the much larger total ARG_MAX. Handing snapshot aggregates to jq with
# --argjson therefore failed with "Argument list too long" once the inventory
# grew, and both the snapshot and its Bearings renderer stopped producing any
# report. These tests pin both halves of the repair: an inventory larger than
# that per-argument ceiling must still snapshot completely, and no snapshot jq
# call may carry fleet data on the command line at all.
FM_SNAPSHOT_ARGV_LIMIT_BYTES=131072

# A parent home whose backlog alone exceeds the per-argument exec limit, with a
# registered secondmate so the cross-home aggregation path is exercised too.
# Echoes "<queued-rows> <done-rows>".
write_large_inventory_fixture() {  # <home> <mate-home>
  local home=$1 mate=$2 queued=180 done_rows=120 i pad
  pad="carrying a deliberately long descriptive title so the parsed backlog serializes past the per-argument exec limit"
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/beta-worktree"
  {
    printf '## In flight\n'
    printf -- '- [ ] alpha-ship - Alpha ship %s (repo: alpha) (kind: ship) (since 2026-07-11)\n' "$pad"
    printf -- '- [ ] beta-ship - Beta ship %s (repo: beta) (kind: ship) (since 2026-07-11)\n' "$pad"
    printf '\n## Queued\n'
    i=1
    while [ "$i" -le "$queued" ]; do
      printf -- '- [ ] queued-%03d - Queued item %03d %s (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-11)\n' \
        "$i" "$i" "$pad"
      i=$((i + 1))
    done
    printf '\n## Done\n'
    i=1
    while [ "$i" -le "$done_rows" ]; do
      printf -- '- [x] done-%03d - Done item %03d %s https://github.com/kunchenguid/firstmate/pull/%d (repo: alpha) (kind: ship) (merged 2026-07-10)\n' \
        "$i" "$i" "$pad" "$i"
      i=$((i + 1))
    done
  } > "$home/data/backlog.md"

  fm_write_meta "$home/state/alpha-ship.meta" \
    "window=firstmate:fm-alpha-ship" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" "harness=codex" "kind=ship" "mode=ship" "yolo=off"
  fm_write_meta "$home/state/beta-ship.meta" \
    "window=firstmate:fm-beta-ship" \
    "worktree=$home/projects/beta-worktree" \
    "project=beta" "harness=codex" "kind=ship" "mode=ship" "yolo=off"

  # Registered secondmate in a sibling home, so the union, per-record, and record
  # accumulator handoffs run rather than being skipped as an empty fleet.
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'delegate\n' > "$mate/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$mate/data/backlog.md"
  fm_write_meta "$home/state/delegate.meta" \
    "window=firstmate:fm-delegate" \
    "worktree=$mate" "project=$mate" "harness=codex" \
    "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$mate" "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/delegate.status"
  printf -- '- delegate - delegated scope (home: %s; scope: delegated scope; projects: alpha; added 2026-07-11)\n' \
    "$mate" > "$home/data/secondmates.md"

  printf '%s %s\n' "$queued" "$done_rows"
}

test_large_inventory_snapshot_survives_argv_limit() {
  local home mate fakebin out rows queued done_rows backlog_bytes records expected
  home=$(make_home large-inventory)
  mate=$(make_home large-inventory-mate)
  rows=$(write_large_inventory_fixture "$home" "$mate")
  queued=${rows% *}
  done_rows=${rows#* }
  fakebin=$(make_fakebin "$home")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json) \
    || fail "snapshot must succeed on an inventory larger than the per-argument exec limit"
  printf '%s' "$out" | jq -e . >/dev/null || fail "large-inventory snapshot must be valid JSON"

  # The fixture only pins the regression while it really is bigger than the
  # ceiling that used to break the command.
  backlog_bytes=$(printf '%s' "$out" | jq '.backlog | tojson | length')
  [ "$backlog_bytes" -gt "$FM_SNAPSHOT_ARGV_LIMIT_BYTES" ] \
    || fail "fixture backlog is only $backlog_bytes bytes; it must exceed $FM_SNAPSHOT_ARGV_LIMIT_BYTES to pin this regression"

  # Nothing may be dropped to make the command fit.
  expected=$((2 + queued + done_rows))
  records=$(printf '%s' "$out" | jq '.backlog.records | length')
  [ "$records" = "$expected" ] \
    || fail "large snapshot dropped backlog records: got $records, expected $expected"
  printf '%s' "$out" | jq -e --argjson queued "$queued" --argjson done_rows "$done_rows" '
    .schema == "fm-fleet-snapshot.v1"
      and ([.backlog.records[] | select(.state == "in_flight")] | length) == 2
      and ([.backlog.records[] | select(.state == "queued")] | length) == $queued
      and ([.backlog.records[] | select(.state == "done")] | length) == $done_rows
      and ([.backlog.records[] | select(.structured | not)] | length) == 0
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.tasks | map(.id)) == ["alpha-ship","beta-ship","delegate"]
  ' >/dev/null || fail "large snapshot lost inventory integrity or task rows"

  # The cross-home aggregation must still resolve, not degrade to unknown.
  printf '%s' "$out" | jq -e '
    .secondmate_current.total == 1
      and .secondmate_current.shown == 1
      and (.secondmate_current.records | length) == 1
      and .secondmate_current.records[0].id == "delegate"
      and .secondmate_current.records[0].registered == true
      and .secondmate_current.records[0].provenance.selected == "structured-home"
  ' >/dev/null || fail "large snapshot lost the registered secondmate record: $(printf '%s' "$out" | jq -c '.secondmate_current')"

  # The secondmate summary mode reads the same oversized backlog. This fixture
  # registers a secondmate with no in-flight backlog row, so the expected verdict
  # is that documented unowned-current disclosure - never a failed backlog read.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary) \
    || fail "secondmate home summary must succeed on an oversized inventory"
  printf '%s' "$out" | jq -e --argjson queued "$queued" --argjson done_rows "$done_rows" '
    .schema == "fm-secondmate-home-summary.v1"
      and .counts.queued == $queued
      and .counts.landed == $done_rows
      and .counts.endpoints == 3
      and .invalidity.kind == "unowned_current"
  ' >/dev/null || fail "oversized secondmate home summary lost bounded counts: $out"
  pass "snapshot and secondmate summary complete on an inventory past the per-argument exec limit"
}

# A finished or deliberately cancelled child whose delivery artifact is preserved
# unlanded is not an inventory contradiction. The in-flight row that carries the
# hold, and the queued row the work was moved to, both already state that no
# worker is running; only a row that still claims a live worker contradicts a
# terminal child, and only an unrecorded id contradicts the inventory. Without
# that boundary a whole readable home degraded to unknown, hiding its backlog and
# its preserved open PRs, and the only way to silence it would have been deleting
# task records that unlanded branches still depend on.
write_preserved_artifact_home() {  # <mate-home> [extra-in-flight-row] [extra-queued-row]
  local mate=$1 extra_in_flight=${2:-} extra_queued=${3:-}
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'delegate\n' > "$mate/.fm-secondmate-home"
  {
    printf '## In flight\n'
    printf -- '- [ ] preserved-pr - Preserved release https://github.com/kunchenguid/firstmate/pull/1001 (repo: alpha) (kind: ship) (since 2026-08-01) (hold: Complete and preserved; not landed.) (hold-kind: external)\n'
    [ -n "$extra_in_flight" ] && printf '%s\n' "$extra_in_flight"
    printf '\n## Queued\n'
    printf -- '- [ ] held-intake - Held intake behind an open PR (repo: alpha) (kind: ship) (since 2026-08-01) (hold: PR 1005 unapproved for merge.) (hold-kind: external)\n'
    [ -n "$extra_queued" ] && printf '%s\n' "$extra_queued"
    printf '\n## Done\n'
  } > "$mate/data/backlog.md"
  write_preserved_child "$mate" preserved-pr \
    'failed: run cancelled to stop merge-monitoring; PR 1001 open, unmerged, not deployed' \
    https://github.com/kunchenguid/firstmate/pull/1001
  write_preserved_child "$mate" held-intake \
    'failed: run cancelled deliberately; PR 1005 open, unmerged, awaiting the captain' \
    https://github.com/kunchenguid/firstmate/pull/1005
}

write_preserved_child() {  # <mate-home> <id> <status-line> [pr-url]
  local mate=$1 id=$2 line=$3 pr=${4:-}
  mkdir -p "$mate/projects/$id"
  fm_write_meta "$mate/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$mate/projects/$id" \
    "project=alpha" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  [ -n "$pr" ] && printf 'pr=%s\n' "$pr" >> "$mate/state/$id.meta"
  printf '%s\n' "$line" > "$mate/state/$id.status"
  # A crew whose monitor was cancelled is semantically IDLE, and only an exact
  # idle verdict lets fm-crew-state.sh consult the status log for the terminal
  # state this fixture is about (bin/fm-busy-lib.sh; unknown is never idle).
  record_claude_idle "$mate/state" "$id"
}

register_preserved_secondmate() {  # <parent-home> <mate-home>
  local home=$1 mate=$2
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf -- '- delegate - delegated scope (home: %s; scope: delegated scope; projects: alpha; added 2026-08-01)\n' \
    "$mate" > "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/delegate.meta" "$mate"
  printf 'working: watching delegated scope\n' > "$home/state/delegate.status"
}

test_preserved_terminal_artifact_stays_charted() {
  local home mate fakebin out
  home=$(make_home preserved-parent)
  mate=$(make_home preserved-mate)
  write_preserved_artifact_home "$mate"
  register_preserved_secondmate "$home" "$mate"
  fakebin=$(make_fakebin "$home")

  out=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$SNAPSHOT" --secondmate-home-summary) \
    || fail "the home summary must succeed on preserved terminal artifacts"
  printf '%s' "$out" | jq -e '
    .valid == true
      and .reason == null
      and .invalidity.kind == null
      and .state == "externally_held"
      and .active_children == []
      and .landed == []
      and ([.holds[].id] | sort) == ["held-intake","preserved-pr"]
      and ([.endpoints[] | select(.state == "failed") | .id] | sort) == ["held-intake","preserved-pr"]
  ' >/dev/null || fail "preserved terminal artifacts were not charted as held: $out"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json) \
    || fail "the parent snapshot must succeed over a home holding preserved terminal artifacts"
  printf '%s' "$out" | jq -e '
    .secondmate_current.records[] | select(.id == "delegate")
    | .provenance.selected == "structured-home"
      and .provenance.summary_valid == true
      and .current.state == "externally_held"
      and .current.reason == null
      and .active_children == []
      and ([.holds[].id] | sort) == ["held-intake","preserved-pr"]
  ' >/dev/null || fail "a readable home with preserved terminal artifacts degraded to unknown: $out"

  # A row that still claims a live worker is the real terminal contradiction.
  mate=$(make_home preserved-mate-stalled)
  write_preserved_artifact_home "$mate" \
    '- [ ] stalled-worker - Ship still claimed as under way (repo: alpha) (kind: ship) (since 2026-08-01)'
  write_preserved_child "$mate" stalled-worker 'failed: run failed'
  out=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$SNAPSHOT" --secondmate-home-summary) \
    || fail "the home summary must succeed on a stalled worker row"
  printf '%s' "$out" | jq -e '
    .valid == false
      and .state == "unknown"
      and .invalidity == {kind:"terminal_in_flight",ids:["stalled-worker"]}
  ' >/dev/null || fail "an in-flight worker row with a terminal child stopped being invalid: $out"

  # A live child under a row that claims no worker is still off the books.
  mate=$(make_home preserved-mate-runaway)
  write_preserved_artifact_home "$mate" "" \
    '- [ ] runaway - Queued while a worker runs (repo: alpha) (kind: ship) (since 2026-08-01)'
  write_preserved_child "$mate" runaway 'working: implementing the change'
  out=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$SNAPSHOT" --secondmate-home-summary) \
    || fail "the home summary must succeed on a runaway child"
  printf '%s' "$out" | jq -e '
    .valid == false
      and .state == "unknown"
      and .invalidity == {kind:"unowned_current",ids:["runaway"]}
  ' >/dev/null || fail "a live child with no in-flight row stopped being invalid: $out"

  # A terminal child the backlog never records at all is still off the books.
  mate=$(make_home preserved-mate-ghost)
  write_preserved_artifact_home "$mate"
  write_preserved_child "$mate" ghost 'failed: run cancelled'
  out=$(PATH="$fakebin:$PATH" FM_HOME="$mate" "$SNAPSHOT" --secondmate-home-summary) \
    || fail "the home summary must succeed on an unrecorded terminal child"
  printf '%s' "$out" | jq -e '
    .valid == false
      and .state == "unknown"
      and .invalidity == {kind:"unowned_current",ids:["ghost"]}
  ' >/dev/null || fail "a terminal child with no backlog record stopped being invalid: $out"
  pass "preserved terminal artifacts stay charted while real terminal contradictions stay invalid"
}

test_secondmate_summary_budget_excludes_repeated_child_probe_wallclock() {
  local home mate fakebin out i child
  home=$(make_home summary-budget-parent)
  mate=$(make_home summary-budget-mate)
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  printf 'delegate\n' > "$mate/.fm-secondmate-home"
  printf '## In flight\n' > "$mate/data/backlog.md"
  i=1
  while [ "$i" -le 6 ]; do
    child="child-$i"
    mkdir -p "$mate/projects/$child"
    printf -- '- [ ] %s - Child %s (repo: alpha) (kind: ship) (since 2026-07-11)\n' \
      "$child" "$i" >> "$mate/data/backlog.md"
    fm_write_meta "$mate/state/$child.meta" \
      "window=firstmate:fm-$child" \
      "worktree=$mate/projects/$child" \
      "project=alpha" "harness=claude" "kind=ship" "mode=ship" "yolo=off"
    printf 'working: child %s\n' "$i" > "$mate/state/$child.status"
    # Working children prove it through their own semantic busy-state record,
    # which is what the summary's current-state read consults.
    record_claude_busy "$mate/state" "$child"
    i=$((i + 1))
  done
  printf '\n## Queued\n\n## Done\n' >> "$mate/data/backlog.md"
  printf -- '- delegate - delegated scope (home: %s; scope: delegated scope; projects: alpha; added 2026-07-11)\n' \
    "$mate" > "$home/data/secondmates.md"
  fm_write_meta "$home/state/delegate.meta" \
    "window=firstmate:fm-delegate" \
    "worktree=$mate" "project=$mate" "harness=codex" \
    "kind=secondmate" "mode=secondmate" "yolo=off" \
    "home=$mate" "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/delegate.status"
  fakebin=$(make_fakebin "$home")

  out=$(PATH="$fakebin:$PATH" FAKE_NM_SLEEP=1 FM_HOME="$home" \
    FM_SNAPSHOT_SECONDMATE_TIMEOUT=3 "$SNAPSHOT" --json) \
    || fail "secondmate summary timed out when repeated child probes should run within the summary budget"
  printf '%s' "$out" | jq -e '
    .secondmate_current.records[] | select(.id == "delegate")
    | .provenance.selected == "structured-home"
      and .current.state == "active_child_work"
      and .counts.active_children == 6
      and (.active_children | length) == 6
  ' >/dev/null || fail "budgeted secondmate summary did not retain structured child activity: $out"
  pass "secondmate summary budget excludes repeated child-probe wall-clock"
}

# Deterministic proof independent of the host's own limit: a jq shim rejects any
# --arg/--argjson VALUE over the threshold. Filter programs are fixed source text
# and are deliberately not checked - only data transport is.
make_jq_argv_guard() {  # <dir>
  local fb
  fb="$1/jq-argv-guard"
  mkdir -p "$fb"
  cat > "$fb/jq" <<'SH'
#!/usr/bin/env bash
set -u
max=${FM_TEST_JQ_ARGV_MAX:?}
real=${FM_TEST_REAL_JQ:?}
expect=0
for a in "$@"; do
  case "$expect" in
    2) expect=1; continue ;;
    1) expect=0
       if [ "${#a}" -gt "$max" ]; then
         printf 'fm-test: jq got a %s-byte --arg/--argjson value (limit %s)\n' "${#a}" "$max" >&2
         exit 97
       fi
       continue ;;
  esac
  case "$a" in
    --arg|--argjson) expect=2 ;;
  esac
done
exec "$real" "$@"
SH
  chmod +x "$fb/jq"
  printf '%s\n' "$fb"
}

test_snapshot_keeps_large_json_off_the_command_line() {
  local home mate fakebin guard real_jq out rc big
  home=$(make_home argv-guard)
  mate=$(make_home argv-guard-mate)
  write_large_inventory_fixture "$home" "$mate" >/dev/null
  fakebin=$(make_fakebin "$home")
  guard=$(make_jq_argv_guard "$home")
  real_jq=$(command -v jq) || fail "jq not found"

  # Sanity: the guard really does fire on argv-transported data.
  big=$(head -c 9000 /dev/zero | tr '\0' 'x')
  out=$(PATH="$guard:$PATH" FM_TEST_JQ_ARGV_MAX=8192 FM_TEST_REAL_JQ="$real_jq" \
    jq -n --arg big "$big" '$big | length' 2>&1)
  rc=$?
  [ "$rc" -eq 97 ] || fail "argv guard failed to reject an oversized --arg value (rc=$rc): $out"

  out=$(PATH="$guard:$fakebin:$PATH" FM_TEST_JQ_ARGV_MAX=8192 FM_TEST_REAL_JQ="$real_jq" \
    FM_HOME="$home" "$SNAPSHOT" --json 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "snapshot passed fleet JSON on the command line (rc=$rc): $(printf '%s' "$out" | tail -3)"
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null \
    || fail "guarded snapshot did not produce the documented schema"

  out=$(PATH="$guard:$fakebin:$PATH" FM_TEST_JQ_ARGV_MAX=8192 FM_TEST_REAL_JQ="$real_jq" \
    FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] \
    || fail "secondmate home summary passed fleet JSON on the command line (rc=$rc): $(printf '%s' "$out" | tail -3)"
  printf '%s' "$out" | jq -e '.schema == "fm-secondmate-home-summary.v1"' >/dev/null \
    || fail "guarded secondmate home summary did not produce the documented schema"
  pass "no snapshot jq call carries fleet JSON as a command-line argument"
}

# A jq that answers the backlog parse (jq -Rn over data/backlog.md) with no
# output and a success status, standing in for an upstream JSON read that yields
# nothing.
make_jq_empty_read_stub() {  # <dir>
  local fb
  fb="$1/jq-empty-read"
  mkdir -p "$fb"
  cat > "$fb/jq" <<'SH'
#!/usr/bin/env bash
set -u
real=${FM_TEST_REAL_JQ:?}
for a in "$@"; do
  if [ "$a" = "-Rn" ]; then exit 0; fi
done
exec "$real" "$@"
SH
  chmod +x "$fb/jq"
  printf '%s\n' "$fb"
}

# --argjson rejected an empty value outright. --slurpfile would instead bind []
# and read back as null, which would quietly turn a failed backlog read into a
# real-looking empty inventory. The transport must stay fail-loud.
test_empty_upstream_read_stops_the_snapshot() {
  local home mate fakebin stub real_jq out rc
  home=$(make_home empty-read)
  mate=$(make_home empty-read-mate)
  write_large_inventory_fixture "$home" "$mate" >/dev/null
  fakebin=$(make_fakebin "$home")
  stub=$(make_jq_empty_read_stub "$home")
  real_jq=$(command -v jq) || fail "jq not found"

  out=$(PATH="$stub:$fakebin:$PATH" FM_TEST_REAL_JQ="$real_jq" FM_HOME="$home" \
    "$SNAPSHOT" --json 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an empty backlog read must stop the snapshot, not report an empty inventory as real: $out"
  assert_contains "$out" "main inventory summary failed" \
    "the empty backlog read should surface the main inventory diagnostic"
  pass "an empty upstream JSON read stops the snapshot instead of reading back as null"
}

test_empty_fleet_json
test_large_inventory_snapshot_survives_argv_limit
test_preserved_terminal_artifact_stays_charted
test_secondmate_summary_budget_excludes_repeated_child_probe_wallclock
test_snapshot_keeps_large_json_off_the_command_line
test_empty_upstream_read_stops_the_snapshot
test_fixture_snapshot_json
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_transfers_to_captain_hold
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
