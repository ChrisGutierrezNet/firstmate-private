#!/usr/bin/env bash
# Behavior tests for the private generated Firstmate data date index.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INDEX="$ROOT/bin/fm-data-date-index.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-data-date-index)

mode_of() {
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

current_view() {
  FM_HOME="$1" "$INDEX" current "$2"
}

set_old_mtime() {
  if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
    touch -t 200001030000 "$1"
  else
    touch -d '2000-01-03 00:00:00 UTC' "$1"
  fi
}

test_help_and_empty_home() {
  local home out json archive listing
  home="$TMP_ROOT/empty-home"
  mkdir -p "$home"
  out=$($INDEX --help)
  assert_contains "$out" 'fm-data-date-index.sh current <html|json|archive>' "help must list the private delivery locator"

  FM_HOME="$home" "$INDEX" refresh >/dev/null || fail "empty home did not generate"
  json=$(current_view "$home" json) || fail "empty home has no current JSON"
  jq -e '
    .schema_version == "firstmate.data-by-date.v1"
    and .source_present == false
    and .stale == false
    and .timezone == "UTC"
    and .week_identity == "ISO-8601 Monday-based week-year"
    and (.records | length == 0)
  ' "$json" >/dev/null || fail "empty-home JSON contract is incomplete"
  archive=$(current_view "$home" archive) || fail "empty home has no current archive"
  listing=$(tar -tzf "$archive") || fail "empty-home archive is unreadable"
  [ "$listing" = $'index.json\nindex.html' ] || fail "archive contains files other than the generated JSON and HTML views: $listing"
  pass "help is current and an empty home yields complete private HTML, JSON, and archive views"
}

test_classification_dates_privacy_and_modes() {
  local home json html archive preserved current
  home="$TMP_ROOT/classified"
  mkdir -p "$home/data/active" "$home/data/done" "$home/data/preserved" \
    "$home/data/references" "$home/state"
  printf '%s\n' \
    '## In flight' \
    '- [ ] active - Active report data/active/report.md (repo: firstmate) (kind: scout) (since 2021-01-01)' \
    '' \
    '## Queued' \
    '' \
    '## Done' \
    '- [x] done - Finished report data/done/report.md (repo: firstmate) (kind: scout) (reported 2020-12-31)' \
    > "$home/data/backlog.md"
  printf 'SECRET-ACTIVE-BODY\n' > "$home/data/active/report.md"
  printf 'SECRET-DONE-BODY\n' > "$home/data/done/report.md"
  printf 'SECRET-PRESERVED-BODY\n' > "$home/data/preserved/brief.md"
  printf 'reference metadata fixture\n' > "$home/data/references/guide.md"
  printf 'curated memory fixture\n' > "$home/data/learnings.md"
  printf 'kind=scout\n' > "$home/state/active.meta"
  set_old_mtime "$home/data/preserved/brief.md"

  FM_HOME="$home" "$INDEX" refresh >/dev/null || fail "classified fixture did not generate"
  json=$(current_view "$home" json)
  html=$(current_view "$home" html)
  archive=$(current_view "$home" archive)
  current="$home/state/generated/data-by-date/current.json"

  jq -e '
    def record($path): .records[] | select(.source_path == $path);
    (record("data/backlog.md") | .owner == "home" and .class == "canonical_operational" and .state == "canonical")
    and (record("data/learnings.md") | .owner == "captain" and .class == "curated_memory" and .state == "curated")
    and (record("data/references/guide.md") | .class == "reusable_reference" and .state == "reusable")
    and (record("data/active/report.md") |
      .owner == "task:active" and .class == "active_task_material" and .state == "active"
      and .chosen_date == "2021-01-01" and .date_source == "task.created"
      and .date_uncertain == false and .timezone == "UTC" and .week_id == "2020-W53"
      and .week_starts_on == "Monday" and .reference_count == 1)
    and (record("data/done/report.md") |
      .owner == "task:done" and .class == "historical_evidence" and .state == "historical"
      and .chosen_date == "2020-12-31" and .date_source == "task.closed"
      and .date_uncertain == false and .week_id == "2020-W53" and .reference_count == 1)
    and (record("data/preserved/brief.md") |
      .class == "preserved_task_material" and .state == "preserved"
      and .chosen_date == "2000-01-03" and .date_source == "filesystem.mtime"
      and .date_uncertain == true and .week_id == "2000-W01")
  ' "$json" >/dev/null || fail "classification, structured dates, fallback uncertainty, or ISO week-year output is wrong"

  jq -e '
    .stale == false
    and ([.views[].kind] | sort == ["archive","html","json"])
    and all(.views[]; .owner == "generator" and .class == "generated_view" and .state == "complete")
  ' "$current" >/dev/null || fail "current manifest does not classify all generated views"

  for secret in SECRET-ACTIVE-BODY SECRET-DONE-BODY SECRET-PRESERVED-BODY; do
    ! grep -F "$secret" "$json" "$html" >/dev/null \
      || fail "a report or note body leaked into a generated view: $secret"
    ! tar -xOzf "$archive" index.json index.html | grep -F "$secret" >/dev/null \
      || fail "a report or note body leaked into the downloadable archive: $secret"
  done
  assert_contains "$(sed -n '1p' "$html")" '<!doctype html>' "static HTML view must be directly readable"

  [ "$(mode_of "$home/state/generated")" = 700 ] || fail "generated parent is not mode 0700"
  [ "$(mode_of "$home/state/generated/data-by-date")" = 700 ] || fail "generated index directory is not mode 0700"
  [ "$(mode_of "${json%/*}")" = 700 ] || fail "generation directory is not mode 0700"
  [ "$(mode_of "$current")" = 600 ] || fail "current manifest is not mode 0600"
  [ "$(mode_of "$json")" = 600 ] || fail "JSON view is not mode 0600"
  [ "$(mode_of "$html")" = 600 ] || fail "HTML view is not mode 0600"
  [ "$(mode_of "$archive")" = 600 ] || fail "archive is not mode 0600"

  preserved=$(jq -r '.records[] | select(.source_path == "data/preserved/brief.md") | .state' "$json")
  [ "$preserved" = preserved ] || fail "old unowned task material was inferred complete from age"
  pass "metadata-only views classify every audience, prefer structured dates, use year-safe Monday weeks, preserve unknown state, and stay private"
}

test_unchanged_stale_and_missing_source() {
  local home before_manifest before_json out status after_json missing_json
  home="$TMP_ROOT/convergence"
  mkdir -p "$home/data"
  printf 'first\n' > "$home/data/projects.md"
  FM_HOME="$home" "$INDEX" refresh >/dev/null
  before_manifest=$(hash_file "$home/state/generated/data-by-date/current.json")
  before_json=$(current_view "$home" json)

  out=$(FM_HOME="$home" "$INDEX" check) || fail "unchanged check failed"
  assert_contains "$out" 'data-date-index: unchanged' "unchanged check did not take the no-publish path"
  [ "$before_manifest" = "$(hash_file "$home/state/generated/data-by-date/current.json")" ] \
    || fail "unchanged execution rewrote the current manifest"
  [ "$before_json" = "$(current_view "$home" json)" ] || fail "unchanged execution published a new generation"

  printf 'second\n' >> "$home/data/projects.md"
  status=$(FM_HOME="$home" "$INDEX" status)
  jq -e '.stale == true and .source_fingerprint != .observed_source_fingerprint' <<< "$status" >/dev/null \
    || fail "changed metadata was not reported stale before refresh"
  FM_HOME="$home" "$INDEX" check >/dev/null || fail "stale check did not refresh"
  after_json=$(current_view "$home" json)
  [ "$after_json" != "$before_json" ] || fail "stale refresh did not publish a new generation"
  jq -e '.stale == false' <<< "$(FM_HOME="$home" "$INDEX" status)" >/dev/null \
    || fail "status remained stale after successful refresh"

  rm -rf -- "$home/data"
  FM_HOME="$home" "$INDEX" refresh >/dev/null || fail "missing data source did not converge to an empty view"
  missing_json=$(current_view "$home" json)
  jq -e '.source_present == false and (.records | length == 0)' "$missing_json" >/dev/null \
    || fail "missing data source did not publish an explicit empty-source generation"
  pass "repeated execution is unchanged, stale state is explicit, and a missing data source converges safely"
}

test_interruption_preserves_last_complete_view() {
  local home fakebin current before before_json rc
  home="$TMP_ROOT/interrupted"
  fakebin="$home/fakebin"
  mkdir -p "$home/data" "$fakebin"
  printf 'baseline\n' > "$home/data/projects.md"
  FM_HOME="$home" "$INDEX" refresh >/dev/null
  current="$home/state/generated/data-by-date/current.json"
  before=$(hash_file "$current")
  before_json=$(current_view "$home" json)
  printf 'changed\n' >> "$home/data/projects.md"
  cat > "$fakebin/tar" <<'SH'
#!/usr/bin/env bash
kill -TERM "$PPID"
exit 143
SH
  chmod +x "$fakebin/tar"
  PATH="$fakebin:$PATH" FM_HOME="$home" "$INDEX" refresh >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "interrupted generator reported success"
  [ "$before" = "$(hash_file "$current")" ] \
    || fail "interruption replaced the last complete current manifest"
  [ -f "$before_json" ] || fail "interruption removed a file from the last complete generation"
  if find "$home/state/generated/data-by-date/generations" -maxdepth 1 -name '.tmp.*' -print | grep . >/dev/null; then
    fail "interruption left a publishable temporary generation"
  fi
  FM_HOME="$home" "$INDEX" refresh >/dev/null || fail "retry after interruption did not converge"
  jq -e '.stale == false' <<< "$(FM_HOME="$home" "$INDEX" status)" >/dev/null \
    || fail "retry after interruption remained stale"
  pass "an interrupted refresh leaves the last complete generation current and a retry converges"
}

test_symlink_and_destination_escape_refusals() {
  local home outside current before rc escape_home escape_sink
  home="$TMP_ROOT/symlink-source"
  outside="$TMP_ROOT/outside-secret"
  mkdir -p "$home/data"
  printf 'outside secret body\n' > "$outside"
  printf 'safe\n' > "$home/data/projects.md"
  FM_HOME="$home" "$INDEX" refresh >/dev/null
  current="$home/state/generated/data-by-date/current.json"
  before=$(hash_file "$current")
  ln -s "$outside" "$home/data/escape.md"
  FM_HOME="$home" "$INDEX" refresh >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "source symlink was accepted"
  [ "$before" = "$(hash_file "$current")" ] \
    || fail "source-symlink refusal changed the current manifest"

  escape_home="$TMP_ROOT/symlink-destination"
  escape_sink="$TMP_ROOT/escape-sink"
  mkdir -p "$escape_home/data" "$escape_home/state" "$escape_sink"
  printf 'safe\n' > "$escape_home/data/projects.md"
  ln -s "$escape_sink" "$escape_home/state/generated"
  FM_HOME="$escape_home" "$INDEX" refresh >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "generated-destination symlink was accepted"
  [ -z "$(find "$escape_sink" -mindepth 1 -print -quit)" ] || fail "destination symlink escaped and wrote outside the home"
  pass "source and generated-destination symlinks are refused without path escape or current-view damage"
}

test_brief_lifecycle_refresh_is_best_effort() {
  local home json failing out rc
  home="$TMP_ROOT/brief-refresh"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$BRIEF" date-index-brief firstmate --scout >/dev/null \
    || fail "brief scaffold failed while refreshing the optional date index"
  json=$(current_view "$home" json)
  jq -e 'any(.records[]; .source_path == "data/date-index-brief/brief.md" and .class == "preserved_task_material")' "$json" >/dev/null \
    || fail "successful brief publication did not refresh its generated metadata"

  failing="$TMP_ROOT/brief-best-effort"
  mkdir -p "$failing/data" "$failing/state" "$failing/escape"
  ln -s "$failing/escape" "$failing/state/generated"
  out=$(FM_HOME="$failing" "$BRIEF" date-index-warning firstmate --scout 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "optional generator failure changed the successful brief exit status"
  [ -f "$failing/data/date-index-warning/brief.md" ] || fail "optional generator failure removed the authoritative brief"
  assert_contains "$out" 'optional private data date-index refresh failed after brief publication' \
    "best-effort lifecycle failure did not report its concrete integration point"
  pass "brief publication refreshes the view and an optional refresh failure preserves the canonical lifecycle result"
}

test_help_and_empty_home
test_classification_dates_privacy_and_modes
test_unchanged_stale_and_missing_source
test_interruption_preserves_last_complete_view
test_symlink_and_destination_escape_refusals
test_brief_lifecycle_refresh_is_best_effort
