#!/usr/bin/env bash
# Send one captain-ready notification to the captain's fixed Slack milestone
# endpoint.
# The event key is a stable, non-secret dedupe key.
# Text is accepted literally from --text or --text-file and is JSON encoded
# without shell evaluation, so multiline fenced approval phrases and full URLs
# remain data.
# Only slack-hook-2 is used in normal operation:
#   https://slack-hook-2.int.exe.xyz/
# Isolated tests may override that endpoint with
# FM_SLACK_HOOK_2_URL_FOR_TESTS; this is not normal configuration and is not
# inherited material.
# Delivered means HTTP 2xx with a response body exactly equal to "ok".
# Usage:
#   fm-captain-notify.sh <event-key> --text-file <path|->
#   fm-captain-notify.sh <event-key> --text <captain-ready text>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CHANNEL="#alexa"
ENDPOINT="${FM_SLACK_HOOK_2_URL_FOR_TESTS:-https://slack-hook-2.int.exe.xyz/}"
CONNECT_TIMEOUT="${FM_SLACK_HOOK_2_CONNECT_TIMEOUT_SECS:-2}"
TOTAL_TIMEOUT="${FM_SLACK_HOOK_2_TOTAL_TIMEOUT_SECS:-8}"
LOCK_WAIT_SECS="${FM_SLACK_HOOK_2_LOCK_WAIT_SECS:-10}"
AUDIT_MAX_LINES="${FM_SLACK_HOOK_2_AUDIT_MAX_LINES:-200}"
DELIVERED_DIR="$STATE/slack-hook-2-delivered"
AUDIT="$STATE/slack-hook-2-audit.jsonl"
LOCK="$STATE/.slack-hook-2.lock"

TEXT_FILE=
TEXT_INLINE=
EVENT_KEY=
LOCK_HELD=0
PAYLOAD=
BODY=
ERR=
AUDIT_TMP=

usage() {
  echo "usage: fm-captain-notify.sh <event-key> --text-file <path|-> | --text <text>" >&2
}

cleanup() {
  [ -z "$PAYLOAD" ] || rm -f -- "$PAYLOAD"
  [ -z "$BODY" ] || rm -f -- "$BODY"
  [ -z "$ERR" ] || rm -f -- "$ERR"
  [ -z "$AUDIT_TMP" ] || rm -f -- "$AUDIT_TMP"
  if [ "$LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$LOCK"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

die() {
  echo "error: $*" >&2
  exit 1
}

hash_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read(), separators=(",",":")))' || return 1
}

append_audit() {
  local event_key=$1 attempts=$2 result=$3 now event_json result_json tmp
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  event_json=$(printf '%s' "$event_key" | json_string) || return 1
  result_json=$(printf '%s' "$result" | json_string) || return 1
  printf '{"time":"%s","event_key":%s,"channel":"%s","attempt_count":%s,"result":%s}\n' \
    "$now" "$event_json" "$CHANNEL" "$attempts" "$result_json" >> "$AUDIT" || return 1
  chmod 0600 "$AUDIT" 2>/dev/null || true
  case "$AUDIT_MAX_LINES" in
    ''|*[!0-9]*) AUDIT_MAX_LINES=200 ;;
  esac
  if [ "$AUDIT_MAX_LINES" -gt 0 ] 2>/dev/null; then
    tmp=$(mktemp "$STATE/.slack-hook-2-audit.XXXXXX") || return 1
    AUDIT_TMP=$tmp
    tail -n "$AUDIT_MAX_LINES" "$AUDIT" > "$tmp" || return 1
    chmod 0600 "$tmp" || return 1
    mv -f -- "$tmp" "$AUDIT" || return 1
    AUDIT_TMP=
  fi
}

acquire_lock() {
  local start now
  start=$(date +%s)
  while ! fm_lock_try_acquire "$LOCK"; do
    now=$(date +%s)
    if [ $((now - start)) -ge "$LOCK_WAIT_SECS" ]; then
      return 1
    fi
    sleep 0.1
  done
  LOCK_HELD=1
}

read_text_to_payload() {
  PAYLOAD=$(mktemp "$STATE/.slack-hook-2-payload.XXXXXX") || return 1
  chmod 0600 "$PAYLOAD" || return 1
  if [ -n "$TEXT_FILE" ]; then
    if [ "$TEXT_FILE" = - ]; then
      python3 -c 'import json,sys; json.dump({"text": sys.stdin.read()}, sys.stdout, separators=(",",":"))' > "$PAYLOAD"
    else
      [ -f "$TEXT_FILE" ] || die "text file is unavailable"
      python3 -c 'import json,sys; json.dump({"text": open(sys.argv[1], "r", encoding="utf-8").read()}, sys.stdout, separators=(",",":"))' "$TEXT_FILE" > "$PAYLOAD"
    fi
  else
    printf '%s' "$TEXT_INLINE" \
      | python3 -c 'import json,sys; json.dump({"text": sys.stdin.read()}, sys.stdout, separators=(",",":"))' > "$PAYLOAD"
  fi
}

post_once() {
  local code rc
  BODY=$(mktemp "$STATE/.slack-hook-2-body.XXXXXX") || return 1
  ERR=$(mktemp "$STATE/.slack-hook-2-curl.XXXXXX") || return 1
  chmod 0600 "$BODY" "$ERR" || return 1
  set +e
  code=$(curl -sS \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$TOTAL_TIMEOUT" \
    -H 'Content-Type: application/json' \
    --data-binary "@$PAYLOAD" \
    -o "$BODY" \
    -w '%{http_code}' \
    "$ENDPOINT" 2> "$ERR")
  rc=$?
  set -e
  FM_NOTIFY_HTTP_CODE=$code
  FM_NOTIFY_CURL_RC=$rc
  if [ "$rc" -ne 0 ]; then
    FM_NOTIFY_RESULT=transport-failure
    return 1
  fi
  case "$code" in
    2??)
      if [ "$(cat "$BODY")" = ok ]; then
        FM_NOTIFY_RESULT=delivered
        return 0
      fi
      FM_NOTIFY_RESULT=unexpected-response
      return 1
      ;;
    5??)
      FM_NOTIFY_RESULT=server-error
      return 1
      ;;
    4??)
      FM_NOTIFY_RESULT=client-refused
      return 1
      ;;
    *)
      FM_NOTIFY_RESULT=http-failure
      return 1
      ;;
  esac
}

if [ "$#" -lt 3 ]; then
  usage
  exit 2
fi
EVENT_KEY=$1
shift
case "$EVENT_KEY" in
  ''|*$'\n'*|*$'\r'*|*$'\t'*) die "event key must be one non-empty line" ;;
esac
[ "${#EVENT_KEY}" -le 240 ] || die "event key is too long"

case "${1:-}" in
  --text)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    TEXT_INLINE=$2
    ;;
  --text-file)
    [ "$#" -eq 2 ] || { usage; exit 2; }
    TEXT_FILE=$2
    ;;
  *)
    usage
    exit 2
    ;;
esac

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
EVENT_HASH=$(hash_key "$EVENT_KEY") || die "sha256 tool is required"

mkdir -p "$STATE" "$DELIVERED_DIR" || die "could not prepare notification state"
chmod 0700 "$DELIVERED_DIR" 2>/dev/null || true
read_text_to_payload || die "could not encode notification text"
acquire_lock || die "could not acquire notification lock"

MARKER="$DELIVERED_DIR/$EVENT_HASH"
if [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; then
  append_audit "$EVENT_KEY" 0 duplicate || die "could not append notification audit"
  printf 'duplicate: %s %s\n' "$CHANNEL" "$EVENT_KEY"
  exit 0
fi

attempts=1
FM_NOTIFY_RESULT=unknown
if post_once; then
  tmp=$(mktemp "$DELIVERED_DIR/.delivered.XXXXXX") || die "could not record delivery"
  printf '%s\n' "$EVENT_KEY" > "$tmp" || die "could not record delivery"
  chmod 0600 "$tmp" || die "could not record delivery"
  mv -f -- "$tmp" "$MARKER" || die "could not record delivery"
  append_audit "$EVENT_KEY" "$attempts" delivered || die "could not append notification audit"
  printf 'delivered: %s %s\n' "$CHANNEL" "$EVENT_KEY"
  exit 0
fi

case "$FM_NOTIFY_RESULT" in
  transport-failure|server-error)
    attempts=2
    rm -f -- "$BODY" "$ERR"
    BODY=
    ERR=
    if post_once; then
      tmp=$(mktemp "$DELIVERED_DIR/.delivered.XXXXXX") || die "could not record delivery"
      printf '%s\n' "$EVENT_KEY" > "$tmp" || die "could not record delivery"
      chmod 0600 "$tmp" || die "could not record delivery"
      mv -f -- "$tmp" "$MARKER" || die "could not record delivery"
      append_audit "$EVENT_KEY" "$attempts" delivered || die "could not append notification audit"
      printf 'delivered: %s %s\n' "$CHANNEL" "$EVENT_KEY"
      exit 0
    fi
    ;;
esac

append_audit "$EVENT_KEY" "$attempts" "failed:$FM_NOTIFY_RESULT" || die "could not append notification audit"
echo "error: notification not delivered ($FM_NOTIFY_RESULT after $attempts attempt(s))" >&2
exit 1
