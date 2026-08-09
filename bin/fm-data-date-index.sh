#!/usr/bin/env bash
# Build and inspect the private generated date index for one Firstmate home.
# Usage:
#   fm-data-date-index.sh refresh
#   fm-data-date-index.sh check
#   fm-data-date-index.sh status
#   fm-data-date-index.sh current <html|json|archive>
#   fm-data-date-index.sh --help
#
# This file is the single owner of the generated data-by-date schema, source
# fingerprint, path confinement, classification, date selection, and atomic
# publication contract.
#
# Sources are regular files below $FM_HOME/data plus the names and filesystem
# metadata of state/*.meta task records.
# File bodies never enter the fingerprint or generated views.
# The only source content parsed is structured task metadata on backlog title
# lines, which supplies task-created/task-closed dates, task state, and exact
# data/... reference counts without reading indented task bodies.
#
# A fingerprint is SHA-256 over sorted stable source paths, file type, size,
# mtime, ctime, device, and inode, plus whether data/ exists.
# `check` and `refresh` both stop after this metadata-only comparison when the
# current complete generation matches.
#
# Complete views live in content-addressed generation directories.
# current.json is replaced last and atomically, so an error or interruption
# preserves the last complete view and cannot publish a partial generation.
# Generated directories are mode 0700 and generated files are mode 0600.
# Source or destination symlinks, special files, control characters in paths,
# unsafe current-manifest paths, and path escapes are rejected.
# Generation is optional and non-authoritative: callers must preserve their
# canonical lifecycle result when this command reports an error.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
RAW_HOME="${FM_HOME:-$FM_ROOT}"
SCHEMA_VERSION='firstmate.data-by-date.v1'
COMMAND=${1:-refresh}
CURRENT_KIND=${2:-}
WORK_TMP=
STAGE_DIR=
LOCK_DIR=
LOCK_HELD=0
SOURCE_LIST=
FINGERPRINT_INPUT=
TASK_DATES=
BACKLOG_TITLES=
SOURCE_PRESENT=false
SOURCE_FINGERPRINT=

usage() {
  sed -n '2,8{s/^# \{0,1\}//;p;}' "$0"
}

die() {
  local message=$1
  printf 'data-date-index: error - %s\n' "$message" >&2
  exit 1
}

cleanup() {
  local owner
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ] && [ ! -L "$STAGE_DIR" ]; then
    rm -rf -- "$STAGE_DIR"
  fi
  if [ "$LOCK_HELD" -eq 1 ] && [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ]; then
    owner=$(sed -n '1p' "$LOCK_DIR/owner" 2>/dev/null || true)
    if [ "$owner" = "$$" ]; then
      rm -f -- "$LOCK_DIR/owner"
      rmdir -- "$LOCK_DIR" 2>/dev/null || true
    fi
  fi
  if [ -n "$WORK_TMP" ] && [ -d "$WORK_TMP" ] && [ ! -L "$WORK_TMP" ]; then
    rm -rf -- "$WORK_TMP"
  fi
}

signal_exit() {
  exit 130
}

trap cleanup EXIT
trap signal_exit HUP INT TERM

case "$COMMAND" in
  -h | --help | help)
    usage
    exit 0
    ;;
  refresh | check | status) ;;
  current)
    case "$CURRENT_KIND" in html | json | archive) ;; *) die "current requires html, json, or archive" ;; esac
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

[ -d "$RAW_HOME" ] || die "FM_HOME is not an existing directory: $RAW_HOME"
[ ! -L "$RAW_HOME" ] || die "FM_HOME must not be a symlink: $RAW_HOME"
FM_HOME=$(cd "$RAW_HOME" && pwd -P) || die "cannot resolve FM_HOME: $RAW_HOME"
DATA="$FM_HOME/data"
STATE="$FM_HOME/state"
GENERATED="$STATE/generated"
OUTPUT="$GENERATED/data-by-date"
GENERATIONS="$OUTPUT/generations"
CURRENT="$OUTPUT/current.json"
LOCK_DIR="$OUTPUT/.refresh.lock"

if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state path is not a safe directory: $STATE"
fi
if [ -e "$DATA" ] || [ -L "$DATA" ]; then
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || die "data path is not a safe directory: $DATA"
  SOURCE_PRESENT=true
fi
for existing_dir in "$GENERATED" "$OUTPUT" "$GENERATIONS"; do
  if [ -e "$existing_dir" ] || [ -L "$existing_dir" ]; then
    [ -d "$existing_dir" ] && [ ! -L "$existing_dir" ] \
      || die "generated destination is not a safe directory: $existing_dir"
  fi
done

WORK_TMP=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-data-date-index.XXXXXX") \
  || die "cannot create private working directory"
chmod 700 "$WORK_TMP" || die "cannot secure private working directory"
SOURCE_LIST="$WORK_TMP/source-files"
FINGERPRINT_INPUT="$WORK_TMP/fingerprint-input"
TASK_DATES="$WORK_TMP/task-dates"
BACKLOG_TITLES="$WORK_TMP/backlog-titles"
: > "$SOURCE_LIST"
: > "$TASK_DATES"
: > "$BACKLOG_TITLES"

if [ "$(uname -s 2>/dev/null || true)" = Darwin ]; then
  stat_signatures() { stat -f '%z\t%m\t%c\t%d\t%i' "$@"; }
  stat_size() { stat -f '%z' "$1"; }
  stat_mtime() { stat -f '%m' "$1"; }
  stat_mode() { stat -f '%Lp' "$1"; }
  epoch_date_utc() { date -u -r "$1" '+%Y-%m-%d'; }
  date_week_utc() { date -u -j -f '%Y-%m-%d' "$1" '+%G-W%V' 2>/dev/null; }
  date_roundtrip_utc() { date -u -j -f '%Y-%m-%d' "$1" '+%Y-%m-%d' 2>/dev/null; }
else
  stat_signatures() { stat -c '%s\t%Y\t%Z\t%d\t%i' "$@"; }
  stat_size() { stat -c '%s' "$1"; }
  stat_mtime() { stat -c '%Y' "$1"; }
  stat_mode() { stat -c '%a' "$1"; }
  epoch_date_utc() { date -u -d "@$1" '+%Y-%m-%d'; }
  date_week_utc() { date -u -d "$1 00:00:00" '+%G-W%V' 2>/dev/null; }
  date_roundtrip_utc() { date -u -d "$1 00:00:00" '+%Y-%m-%d' 2>/dev/null; }
fi

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

valid_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ "$(date_roundtrip_utc "$1" || true)" = "$1" ]
}

private_mode() {
  local mode
  mode=$(stat_mode "$1" 2>/dev/null || true)
  while [ "${mode#0}" != "$mode" ]; do mode=${mode#0}; done
  [ "$mode" = "$2" ]
}

safe_relative_path() {
  local path=$1
  case "$path" in
    '' | /* | ../* | */../* | */.. | *$'\n'* | *$'\r'* | *$'\t'*) return 1 ;;
  esac
  return 0
}

collect_sources() {
  local unsorted="$WORK_TMP/source-files.unsorted"
  local found="$WORK_TMP/source-files.found"
  local path rel
  : > "$unsorted"
  if [ -e "$DATA" ] || [ -L "$DATA" ]; then
    [ -d "$DATA" ] && [ ! -L "$DATA" ] || die "data path is not a safe directory: $DATA"
    SOURCE_PRESENT=true
  else
    SOURCE_PRESENT=false
  fi
  if [ "$SOURCE_PRESENT" = true ]; then
    find "$DATA" -mindepth 1 -print0 > "$found" \
      || die "cannot enumerate data sources"
    while IFS= read -r -d '' path; do
      rel=${path#"$FM_HOME"/}
      safe_relative_path "$rel" || die "source path contains an escape or unsupported control character: $rel"
      if [ -L "$path" ]; then
        die "source symlink is not allowed: $rel"
      elif [ -d "$path" ]; then
        continue
      elif [ -f "$path" ]; then
        [ -r "$path" ] || die "source file is not readable: $rel"
        printf '%s\n' "$rel" >> "$unsorted"
      else
        die "source is not a regular file or directory: $rel"
      fi
    done < "$found"
  fi
  if [ -d "$STATE" ]; then
    for path in "$STATE"/*.meta; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      rel=${path#"$FM_HOME"/}
      safe_relative_path "$rel" || die "task metadata path contains an escape or unsupported control character: $rel"
      [ -f "$path" ] && [ ! -L "$path" ] || die "task metadata is not a safe regular file: $rel"
      [ -r "$path" ] || die "task metadata is not readable: $rel"
      printf '%s\n' "$rel" >> "$unsorted"
    done
  fi
  LC_ALL=C sort -u "$unsorted" > "$SOURCE_LIST"
}

compute_fingerprint() {
  local rel path hash signature_count source_count
  local signatures="$WORK_TMP/stat-signatures"
  local -a paths=()
  collect_sources
  : > "$signatures"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    path="$FM_HOME/$rel"
    [ -f "$path" ] && [ ! -L "$path" ] || die "source changed type during fingerprinting: $rel"
    paths+=("$path")
    if [ "${#paths[@]}" -eq 100 ]; then
      stat_signatures "${paths[@]}" >> "$signatures" 2>/dev/null \
        || die "cannot stat source files for fingerprinting"
      paths=()
    fi
  done < "$SOURCE_LIST"
  if [ "${#paths[@]}" -gt 0 ]; then
    stat_signatures "${paths[@]}" >> "$signatures" 2>/dev/null \
      || die "cannot stat source files for fingerprinting"
  fi
  source_count=$(wc -l < "$SOURCE_LIST" | tr -d ' ')
  signature_count=$(wc -l < "$signatures" | tr -d ' ')
  [ "$source_count" = "$signature_count" ] \
    || die "source metadata count changed during fingerprinting"
  {
    printf 'schema=%s\n' "$SCHEMA_VERSION"
    printf 'data_present=%s\n' "$SOURCE_PRESENT"
    paste "$SOURCE_LIST" "$signatures"
  } > "$FINGERPRINT_INPUT"
  hash=$(sha256_file "$FINGERPRINT_INPUT") || die "shasum or sha256sum is required"
  case "$hash" in '' | *[!0-9a-f]*) die "source fingerprint command returned an invalid digest" ;; esac
  [ "${#hash}" -eq 64 ] || die "source fingerprint command returned an invalid digest"
  SOURCE_FINGERPRINT="sha256:$hash"
}

extract_backlog_metadata() {
  local backlog="$DATA/backlog.md"
  [ -f "$backlog" ] || return 0
  [ ! -L "$backlog" ] && [ -r "$backlog" ] || die "backlog metadata source is not a safe readable regular file"
  awk -v dates="$TASK_DATES" -v titles="$BACKLOG_TITLES" '
    function extract_date(line, label,    pattern, value) {
      pattern = "\\(" label " [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\\)"
      if (!match(line, pattern)) return ""
      value = substr(line, RSTART, RLENGTH)
      sub("^\\(" label " ", "", value)
      sub("\\)$", "", value)
      return value
    }
    /^##[[:space:]]+/ {
      section=$0
      sub(/^##[[:space:]]+/, "", section)
      next
    }
    /^[-*][[:space:]]+\[[ xX]\][[:space:]]+/ {
      line=$0
      print line >> titles
      id=line
      sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", id)
      sub(/[[:space:]]+-[[:space:]].*$/, "", id)
      lifecycle=(section == "Done" ? "done" : (section == "Queued" ? "queued" : (section == "In flight" ? "in_flight" : "unknown")))
      date=""
      source=""
      if (lifecycle == "done") {
        date=extract_date(line, "closed")
        if (date == "") date=extract_date(line, "merged")
        if (date == "") date=extract_date(line, "reported")
        if (date == "") date=extract_date(line, "done")
        if (date != "") source="task.closed"
      } else {
        date=extract_date(line, "created")
        if (date == "") date=extract_date(line, "since")
        if (date != "") source="task.created"
      }
      print id "\t" lifecycle "\t" date "\t" source >> dates
    }
  ' "$backlog"
}

task_metadata() {
  local id=$1
  awk -F '\t' -v id="$id" '$1 == id {line=$0} END {if (line != "") print line}' "$TASK_DATES"
}

reference_count() {
  local path=$1
  awk -v path="$path" 'index($0, path) > 0 {count++} END {print count + 0}' "$BACKLOG_TITLES"
}

classify_record() {
  local rel=$1 sub first base meta lifecycle
  sub=${rel#data/}
  first=${sub%%/*}
  base=${sub##*/}
  OWNER=home
  CLASS=reusable_reference
  RECORD_STATE=reusable
  TASK_ID=
  case "$sub" in
    captain.md | captain-shared.md | learnings.md)
      OWNER=captain
      CLASS=curated_memory
      RECORD_STATE=curated
      return
      ;;
    backlog.md | done-archive.md | projects.md | secondmates.md | charter.md | handoff/*)
      CLASS=canonical_operational
      RECORD_STATE=canonical
      return
      ;;
    reference/* | references/* | docs/*)
      CLASS=reusable_reference
      RECORD_STATE=reusable
      return
      ;;
  esac
  meta=$(task_metadata "$first")
  if [ -n "$meta" ] || [ -f "$STATE/$first.meta" ] || [ "$base" = brief.md ] || [ "$base" = report.md ]; then
    TASK_ID=$first
    OWNER="task:$first"
    lifecycle=
    [ -z "$meta" ] || lifecycle=$(printf '%s\n' "$meta" | awk -F '\t' '{print $2}')
    if [ -f "$STATE/$first.meta" ]; then
      CLASS=active_task_material
      RECORD_STATE=active
    elif [ "$lifecycle" = "done" ]; then
      CLASS=historical_evidence
      RECORD_STATE=historical
    elif [ "$lifecycle" = queued ] || [ "$lifecycle" = in_flight ]; then
      CLASS=active_task_material
      RECORD_STATE=active
    else
      CLASS=preserved_task_material
      RECORD_STATE=preserved
    fi
    return
  fi
  case "$sub" in
    */report.md | */reports/* | */evidence/* | *.report.md)
      CLASS=historical_evidence
      RECORD_STATE=historical
      ;;
  esac
}

build_records() {
  local records_tsv=$1 rel path chosen_date date_source uncertainty ref_count meta
  local mtime week size link
  : > "$records_tsv"
  extract_backlog_metadata
  while IFS= read -r rel; do
    case "$rel" in data/*) ;; *) continue ;; esac
    path="$FM_HOME/$rel"
    classify_record "$rel"
    chosen_date=
    date_source=
    uncertainty=true
    ref_count=
    if [ -n "$TASK_ID" ]; then
      meta=$(task_metadata "$TASK_ID")
      if [ -n "$meta" ]; then
        chosen_date=$(printf '%s\n' "$meta" | awk -F '\t' '{print $3}')
        date_source=$(printf '%s\n' "$meta" | awk -F '\t' '{print $4}')
        if [ -n "$chosen_date" ] && valid_date "$chosen_date"; then
          uncertainty=false
        else
          chosen_date=
          date_source=
        fi
      fi
      ref_count=$(reference_count "$rel")
    fi
    if [ -z "$chosen_date" ]; then
      mtime=$(stat_mtime "$path" 2>/dev/null) || die "cannot read fallback mtime: $rel"
      chosen_date=$(epoch_date_utc "$mtime" 2>/dev/null) || die "cannot convert fallback mtime to UTC date: $rel"
      valid_date "$chosen_date" || die "fallback mtime produced an invalid UTC date: $rel"
      date_source=filesystem.mtime
      uncertainty=true
    fi
    week=$(date_week_utc "$chosen_date") || die "cannot calculate Monday-based week identity: $chosen_date"
    size=$(stat_size "$path" 2>/dev/null) || die "cannot read source size: $rel"
    link="../../../../../$rel"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$OWNER" "$CLASS" "$RECORD_STATE" "$chosen_date" "$date_source" \
      "$uncertainty" "$week" "$rel" "$size" "$ref_count" "$link" Monday >> "$records_tsv"
  done < "$SOURCE_LIST"
}

current_view_safe() {
  local rel file
  [ -f "$CURRENT" ] && [ ! -L "$CURRENT" ] && private_mode "$CURRENT" 600 || return 1
  jq -e --arg schema "$SCHEMA_VERSION" '
    .schema_version == $schema
    and (.source_fingerprint | type == "string")
    and (.stale | type == "boolean")
    and (.views | type == "array")
    and ([.views[].kind] | sort == ["archive","html","json"])
    and (all(.views[].path; test("^generations/[0-9a-f]{64}-[0-9]+-[0-9]+/(index\\.html|index\\.json|data-by-date\\.tar\\.gz)$")))
  ' "$CURRENT" >/dev/null 2>&1 || return 1
  while IFS= read -r rel; do
    safe_relative_path "$rel" || return 1
    file="$OUTPUT/$rel"
    [ -f "$file" ] && [ ! -L "$file" ] && private_mode "$file" 600 || return 1
  done < <(jq -r '.views[].path' "$CURRENT")
  return 0
}

current_fingerprint() {
  current_view_safe || return 1
  jq -r '.source_fingerprint' "$CURRENT"
}

print_status() {
  local current_fp stale
  current_fp=$(current_fingerprint 2>/dev/null || true)
  stale=true
  [ -n "$current_fp" ] && [ "$current_fp" = "$SOURCE_FINGERPRINT" ] && stale=false
  jq -n \
    --arg schema_version "$SCHEMA_VERSION" \
    --arg source_fingerprint "$current_fp" \
    --arg observed_source_fingerprint "$SOURCE_FINGERPRINT" \
    --argjson stale "$stale" \
    --arg current_manifest "state/generated/data-by-date/current.json" \
    '{schema_version:$schema_version,source_fingerprint:(if $source_fingerprint == "" then null else $source_fingerprint end),observed_source_fingerprint:$observed_source_fingerprint,stale:$stale,current_manifest:$current_manifest}'
}

ensure_private_directory() {
  local dir=$1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || die "generated destination is not a safe directory: $dir"
  else
    mkdir "$dir" || die "cannot create generated directory: $dir"
  fi
  chmod 700 "$dir" || die "cannot set generated directory mode 0700: $dir"
}

prepare_destination() {
  if [ ! -e "$STATE" ]; then
    mkdir "$STATE" || die "cannot create state directory: $STATE"
  fi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state path is not a safe directory: $STATE"
  ensure_private_directory "$GENERATED"
  ensure_private_directory "$OUTPUT"
  ensure_private_directory "$GENERATIONS"
  if [ -e "$CURRENT" ] || [ -L "$CURRENT" ]; then
    [ -f "$CURRENT" ] && [ ! -L "$CURRENT" ] || die "current manifest is not a safe regular file: $CURRENT"
  fi
}

acquire_lock() {
  local owner live
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
  else
    [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || die "refresh lock is not a safe directory"
    owner=$(sed -n '1p' "$LOCK_DIR/owner" 2>/dev/null || true)
    case "$owner" in
      '' | *[!0-9]*) live=0 ;;
      *) if kill -0 "$owner" 2>/dev/null; then live=1; else live=0; fi ;;
    esac
    [ "$live" -eq 0 ] || die "another data date-index refresh is active (pid $owner)"
    rm -f -- "$LOCK_DIR/owner"
    rmdir -- "$LOCK_DIR" 2>/dev/null || die "stale refresh lock could not be retired"
    mkdir "$LOCK_DIR" 2>/dev/null || die "refresh lock changed while retiring a stale owner"
    LOCK_HELD=1
  fi
  chmod 700 "$LOCK_DIR" || die "cannot secure refresh lock"
  printf '%s\n' "$$" > "$LOCK_DIR/owner" || die "cannot record refresh lock owner"
  chmod 600 "$LOCK_DIR/owner" || die "cannot secure refresh lock owner"
}

write_html() {
  local json=$1 html=$2
  jq -r '
    . as $root |
    def h: tostring | @html;
    def count($class): [$root.records[] | select(.class == $class)] | length;
    "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Firstmate private data by date</title><style>" +
    "body{margin:0;background:#f4f1e8;color:#17201d;font:15px/1.5 ui-sans-serif,system-ui,sans-serif}main{max-width:1120px;margin:auto;padding:48px 24px 72px}h1{font:700 clamp(2rem,5vw,4rem)/1.05 ui-serif,Georgia,serif;margin:.2em 0}.eyebrow,.meta{font:700 .72rem/1.2 ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;color:#5e6d66}.summary{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:1px;background:#b8c0ba;border:1px solid #b8c0ba;margin:28px 0}.card{background:#fffdf7;padding:18px}.card strong{display:block;font:700 1.8rem/1 ui-serif,Georgia,serif}.week{margin-top:42px;border-top:2px solid #17201d}.week h2{display:flex;justify-content:space-between;gap:16px;align-items:baseline;font:700 1.5rem/1.2 ui-serif,Georgia,serif}.row{display:grid;grid-template-columns:130px minmax(0,1fr) 150px 110px;gap:16px;padding:13px 0;border-top:1px solid #ccd2cd}.path{overflow-wrap:anywhere}.pill{display:inline-block;border:1px solid #7b8a82;border-radius:999px;padding:2px 8px;font-size:.75rem}a{color:#075e4b}footer{margin-top:48px;color:#5e6d66}@media(max-width:720px){.row{grid-template-columns:1fr}.row>*{min-width:0}}" +
    "</style></head><body><main><div class=\"eyebrow\">Private generated view · metadata and links only</div><h1>Firstmate data by date</h1><p>Grouped by ISO week in UTC. Weeks start Monday and use the ISO week-year, including year boundaries.</p>" +
    "<div class=\"summary\"><div class=\"card\"><span class=\"meta\">Records</span><strong>" + ($root.records|length|tostring) + "</strong></div>" +
    "<div class=\"card\"><span class=\"meta\">Operational</span><strong>" + (count("canonical_operational")|tostring) + "</strong></div>" +
    "<div class=\"card\"><span class=\"meta\">Curated memory</span><strong>" + (count("curated_memory")|tostring) + "</strong></div>" +
    "<div class=\"card\"><span class=\"meta\">Task and evidence</span><strong>" + ([$root.records[]|select(.class|test("task_material|historical_evidence"))]|length|tostring) + "</strong></div></div>" +
    "<p><a href=\"index.json\">Machine-readable JSON</a> · <a href=\"data-by-date.tar.gz\" download>Download these generated views</a></p>" +
    ([$root.records[] | .week_id] | unique | sort | reverse | map(. as $week |
      "<section class=\"week\"><h2><span>" + ($week|h) + "</span><span class=\"meta\">Monday-based</span></h2>" +
      ([$root.records[] | select(.week_id == $week)] | sort_by(.chosen_date,.source_path) | reverse | map(
        "<div class=\"row\"><time>" + (.chosen_date|h) + "</time><div class=\"path\"><a href=\"" + (.link|h) + "\">" + (.source_path|h) + "</a><br><span class=\"meta\">" + (.owner|h) + " · " + (.date_source|h) + (if .date_uncertain then " · uncertain" else "" end) + "</span></div><div><span class=\"pill\">" + (.class|h) + "</span></div><div>" + ((.size_bytes|tostring)|h) + " bytes</div></div>"
      ) | join("")) + "</section>"
    ) | join("")) +
    "<footer><div class=\"meta\">Schema " + ($root.schema_version|h) + " · Generated " + ($root.generated_at|h) + " · " + ($root.source_fingerprint|h) + "</div><p>No report or note body is included in this view or its archive.</p></footer></main></body></html>"
  ' "$json" > "$html"
}

publish_generation() {
  local hash generated_at generation_id records_tsv index_json index_html archive
  local before_publish generation html_size json_size archive_size current_tmp
  hash=${SOURCE_FINGERPRINT#sha256:}
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  generation_id="$hash-$(date -u '+%s')-$$"
  records_tsv="$WORK_TMP/records.tsv"
  build_records "$records_tsv"
  STAGE_DIR=$(umask 077; mktemp -d "$GENERATIONS/.tmp.XXXXXX") \
    || die "cannot create private generation stage"
  chmod 700 "$STAGE_DIR" || die "cannot secure generation stage"
  index_json="$STAGE_DIR/index.json"
  index_html="$STAGE_DIR/index.html"
  archive="$STAGE_DIR/data-by-date.tar.gz"
  jq -Rn \
    --arg schema_version "$SCHEMA_VERSION" \
    --arg generated_at "$generated_at" \
    --arg source_fingerprint "$SOURCE_FINGERPRINT" \
    --argjson source_present "$SOURCE_PRESENT" '
      [inputs | split("\t") | {
        owner:.[0],class:.[1],state:.[2],chosen_date:.[3],date_source:.[4],
        date_uncertain:(.[5] == "true"),timezone:"UTC",week_id:.[6],week_starts_on:.[11],
        source_path:.[7],size_bytes:(.[8]|tonumber),
        reference_count:(if .[9] == "" then null else (.[9]|tonumber) end),link:.[10]
      }]
      | sort_by(.chosen_date,.source_path) | reverse
      | {schema_version:$schema_version,generated_at:$generated_at,
         source_fingerprint:$source_fingerprint,observed_source_fingerprint:$source_fingerprint,
         stale:false,timezone:"UTC",week_identity:"ISO-8601 Monday-based week-year",
         source_root:"data",source_present:$source_present,records:.,
         summary:{record_count:length,uncertain_date_count:([.[]|select(.date_uncertain)]|length)}}
    ' < "$records_tsv" > "$index_json" || die "cannot render machine-readable index"
  write_html "$index_json" "$index_html" || die "cannot render static HTML index"
  chmod 600 "$index_json" "$index_html" || die "cannot set generated view mode 0600"
  tar -czf "$archive" -C "$STAGE_DIR" index.json index.html \
    || die "cannot create downloadable generated-view archive"
  chmod 600 "$archive" || die "cannot set generated archive mode 0600"

  before_publish=$SOURCE_FINGERPRINT
  compute_fingerprint
  [ "$SOURCE_FINGERPRINT" = "$before_publish" ] \
    || die "sources changed during generation; last complete view was preserved"

  generation="$GENERATIONS/$generation_id"
  [ ! -e "$generation" ] && [ ! -L "$generation" ] \
    || die "immutable generation path already exists: $generation"
  mv "$STAGE_DIR" "$generation" || die "cannot publish complete generation directory"
  STAGE_DIR=
  chmod 700 "$generation" || die "cannot secure complete generation directory"

  html_size=$(stat_size "$generation/index.html") || die "cannot stat published HTML view"
  json_size=$(stat_size "$generation/index.json") || die "cannot stat published JSON view"
  archive_size=$(stat_size "$generation/data-by-date.tar.gz") || die "cannot stat published archive"
  current_tmp=$(umask 077; mktemp "$OUTPUT/.current.XXXXXX") || die "cannot stage current manifest"
  jq -n \
    --arg schema_version "$SCHEMA_VERSION" \
    --arg generated_at "$generated_at" \
    --arg source_fingerprint "$SOURCE_FINGERPRINT" \
    --arg html_path "generations/$generation_id/index.html" \
    --arg json_path "generations/$generation_id/index.json" \
    --arg archive_path "generations/$generation_id/data-by-date.tar.gz" \
    --argjson html_size "$html_size" \
    --argjson json_size "$json_size" \
    --argjson archive_size "$archive_size" '
      {schema_version:$schema_version,generated_at:$generated_at,
       source_fingerprint:$source_fingerprint,observed_source_fingerprint:$source_fingerprint,
       stale:false,timezone:"UTC",views:[
         {kind:"html",owner:"generator",class:"generated_view",state:"complete",chosen_date:($generated_at[0:10]),date_source:"generated_at",date_uncertain:false,timezone:"UTC",source_path:$html_path,size_bytes:$html_size,reference_count:null,path:$html_path},
         {kind:"json",owner:"generator",class:"generated_view",state:"complete",chosen_date:($generated_at[0:10]),date_source:"generated_at",date_uncertain:false,timezone:"UTC",source_path:$json_path,size_bytes:$json_size,reference_count:null,path:$json_path},
         {kind:"archive",owner:"generator",class:"generated_view",state:"complete",chosen_date:($generated_at[0:10]),date_source:"generated_at",date_uncertain:false,timezone:"UTC",source_path:$archive_path,size_bytes:$archive_size,reference_count:null,path:$archive_path}
       ]}
    ' > "$current_tmp" || { rm -f -- "$current_tmp"; die "cannot render current manifest"; }
  chmod 600 "$current_tmp" || { rm -f -- "$current_tmp"; die "cannot secure current manifest stage"; }
  mv -f "$current_tmp" "$CURRENT" || { rm -f -- "$current_tmp"; die "cannot atomically publish current manifest"; }
  printf 'data-date-index: refreshed %s\n' "$CURRENT"
}

if [ "$COMMAND" = current ]; then
  current_view_safe || die "no complete current generated view is available"
  rel=$(jq -r --arg kind "$CURRENT_KIND" '.views[] | select(.kind == $kind) | .path' "$CURRENT")
  safe_relative_path "$rel" || die "current manifest contains an unsafe view path"
  printf '%s\n' "$OUTPUT/$rel"
  exit 0
fi

compute_fingerprint

if [ "$COMMAND" = status ]; then
  print_status
  exit 0
fi

prepare_destination
acquire_lock
current_fp=$(current_fingerprint 2>/dev/null || true)
if [ -n "$current_fp" ] && [ "$current_fp" = "$SOURCE_FINGERPRINT" ]; then
  printf 'data-date-index: unchanged %s\n' "$CURRENT"
  exit 0
fi
publish_generation
