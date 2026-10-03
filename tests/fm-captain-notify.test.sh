#!/usr/bin/env bash
# Tests for bin/fm-captain-notify.sh and the lifecycle call sites that use it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

NOTIFY="$ROOT/bin/fm-captain-notify.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
LOCAL_MERGE="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-notify-tests)
SERVER_PIDS=
SERVER_URL=

cleanup_servers() {
  local pid
  for pid in $SERVER_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_servers EXIT
trap 'cleanup_servers; exit 130' INT
trap 'cleanup_servers; exit 143' TERM

write_server() {
  local dir=$1
  cat > "$dir/server.py" <<'PY'
import http.server
import json
import socketserver
import sys
import threading
import time

port_file, behavior_file, log_file = sys.argv[1:4]
with open(behavior_file, encoding="utf-8") as f:
    behaviors = [json.loads(line) for line in f if line.strip()]
if not behaviors:
    behaviors = [{"status": 200, "body": "ok", "delay": 0}]

lock = threading.Lock()
index = 0

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global index
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            parsed = {"json_error": str(exc)}
        with lock:
            seq = index + 1
            behavior = behaviors[index] if index < len(behaviors) else behaviors[-1]
            index += 1
            with open(log_file, "a", encoding="utf-8") as log:
                log.write(json.dumps({
                    "seq": seq,
                    "path": self.path,
                    "headers": {k.lower(): v for k, v in self.headers.items()},
                    "body": raw.decode("utf-8", "replace"),
                    "json": parsed,
                }, sort_keys=True) + "\n")
        delay = behavior.get("delay", 0)
        if delay:
            time.sleep(delay / 1000.0)
        body = behavior.get("body", "ok").encode("utf-8")
        self.send_response(int(behavior.get("status", 200)))
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def log_message(self, fmt, *args):
        return

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

server = Server(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
}

start_server() {
  local dir=$1 port_file behavior_file pid i
  port_file="$dir/port"
  behavior_file="$dir/behavior.jsonl"
  write_server "$dir"
  : > "$dir/requests.jsonl"
  python3 "$dir/server.py" "$port_file" "$behavior_file" "$dir/requests.jsonl" &
  pid=$!
  SERVER_PIDS="$SERVER_PIDS $pid"
  i=0
  while [ ! -s "$port_file" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$port_file" ] || fail "fixture server did not publish its port"
  SERVER_URL="http://127.0.0.1:$(cat "$port_file")/"
}

write_behavior() {
  local dir=$1
  shift
  : > "$dir/behavior.jsonl"
  while [ "$#" -gt 0 ]; do
    printf '%s\n' "$1" >> "$dir/behavior.jsonl"
    shift
  done
}

request_count() {
  local file=$1
  [ -f "$file" ] || { echo 0; return; }
  wc -l < "$file" | tr -d '[:space:]'
}

run_notify_case() {
  local dir=$1 key=$2 text=$3 rc
  mkdir -p "$dir/state"
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_SLACK_HOOK_2_URL_FOR_TESTS="$SERVER_URL" \
    "$NOTIFY" "$key" --text "$text" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  return "$rc"
}

test_success_delivers_once_and_records_audit() {
  local dir rc
  dir="$TMP_ROOT/success"
  mkdir -p "$dir"
  write_behavior "$dir" '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  run_notify_case "$dir" "success:key" "Captain, PR ready: https://github.com/example/repo/pull/1"
  rc=$?

  expect_code 0 "$rc" "success: notification should deliver"
  [ "$(request_count "$dir/requests.jsonl")" = 1 ] || fail "success: expected one request"
  assert_grep '"result":"delivered"' "$dir/state/slack-hook-2-audit.jsonl" \
    "success: audit did not record delivery"
  pass "fm-captain-notify delivers one exact-ok request and audits the result"
}

test_exact_ok_is_required() {
  local dir rc
  dir="$TMP_ROOT/exact-ok"
  mkdir -p "$dir"
  write_behavior "$dir" '{"status":200,"body":"not ok","delay":0}'
  start_server "$dir"

  run_notify_case "$dir" "exact-ok:key" "Captain, this must not deliver"
  rc=$?

  expect_code 1 "$rc" "exact-ok: non-ok body should fail"
  [ "$(request_count "$dir/requests.jsonl")" = 1 ] || fail "exact-ok: should not retry unexpected 2xx body"
  [ ! -d "$dir/state/slack-hook-2-delivered" ] || [ -z "$(find "$dir/state/slack-hook-2-delivered" -type f -print -quit)" ] \
    || fail "exact-ok: failed delivery was deduped"
  pass "fm-captain-notify requires a response body exactly equal to ok"
}

test_ordinary_4xx_refuses_without_retry() {
  local dir rc
  dir="$TMP_ROOT/client-refused"
  mkdir -p "$dir"
  write_behavior "$dir" '{"status":403,"body":"forbidden","delay":0}' '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  run_notify_case "$dir" "client-refused:key" "Captain, this should fail"
  rc=$?

  expect_code 1 "$rc" "client-refused: 4xx should fail"
  [ "$(request_count "$dir/requests.jsonl")" = 1 ] || fail "client-refused: ordinary 4xx was retried"
  pass "fm-captain-notify refuses ordinary 4xx without retrying"
}

test_5xx_retries_once() {
  local dir rc
  dir="$TMP_ROOT/server-retry"
  mkdir -p "$dir"
  write_behavior "$dir" '{"status":500,"body":"bad","delay":0}' '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  run_notify_case "$dir" "server-retry:key" "Captain, retry this milestone"
  rc=$?

  expect_code 0 "$rc" "server-retry: retry should deliver"
  [ "$(request_count "$dir/requests.jsonl")" = 2 ] || fail "server-retry: expected exactly two attempts"
  pass "fm-captain-notify retries one 5xx once and then records delivery"
}

test_timeout_retries_once() {
  local dir rc
  dir="$TMP_ROOT/timeout-retry"
  mkdir -p "$dir/state"
  write_behavior "$dir" '{"status":200,"body":"ok","delay":1500}' '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_SLACK_HOOK_2_URL_FOR_TESTS="$SERVER_URL" \
  FM_SLACK_HOOK_2_TOTAL_TIMEOUT_SECS=1 \
    "$NOTIFY" "timeout-retry:key" --text "Captain, retry timeout" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?

  expect_code 0 "$rc" "timeout-retry: timeout retry should deliver"
  [ "$(request_count "$dir/requests.jsonl")" = 2 ] || fail "timeout-retry: expected exactly two attempts"
  pass "fm-captain-notify retries one timeout once and then records delivery"
}

test_successful_dedup_sends_no_second_request() {
  local dir rc
  dir="$TMP_ROOT/dedup"
  mkdir -p "$dir"
  write_behavior "$dir" '{"status":200,"body":"ok","delay":0}' '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  run_notify_case "$dir" "dedup:key" "Captain, first"
  rc=$?
  expect_code 0 "$rc" "dedup: first delivery should succeed"
  run_notify_case "$dir" "dedup:key" "Captain, second"
  rc=$?
  expect_code 0 "$rc" "dedup: duplicate should succeed"
  [ "$(request_count "$dir/requests.jsonl")" = 1 ] || fail "dedup: duplicate sent another request"
  assert_grep '"result":"duplicate"' "$dir/state/slack-hook-2-audit.jsonl" \
    "dedup: duplicate audit result missing"
  pass "fm-captain-notify deduplicates successful event keys"
}

test_failed_attempt_is_not_deduped() {
  local dir rc
  dir="$TMP_ROOT/failure-not-deduped"
  mkdir -p "$dir"
  write_behavior "$dir" \
    '{"status":500,"body":"bad","delay":0}' \
    '{"status":500,"body":"bad","delay":0}' \
    '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  run_notify_case "$dir" "failure-not-deduped:key" "Captain, first"
  rc=$?
  expect_code 1 "$rc" "failure-not-deduped: first call should fail"
  run_notify_case "$dir" "failure-not-deduped:key" "Captain, second"
  rc=$?
  expect_code 0 "$rc" "failure-not-deduped: second call should deliver"
  [ "$(request_count "$dir/requests.jsonl")" = 3 ] || fail "failure-not-deduped: failed attempt was deduped or retried incorrectly"
  pass "fm-captain-notify does not dedupe failed attempts"
}

test_concurrent_same_key_delivers_once() {
  local dir i rc notify_pids pid
  dir="$TMP_ROOT/concurrent"
  mkdir -p "$dir/state"
  write_behavior "$dir" '{"status":200,"body":"ok","delay":500}' '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  notify_pids=
  for i in 1 2 3 4 5; do
    (
      FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$dir/state" \
      FM_SLACK_HOOK_2_URL_FOR_TESTS="$SERVER_URL" \
        "$NOTIFY" "concurrent:key" --text "Captain, concurrent milestone" > "$dir/stdout.$i" 2> "$dir/stderr.$i"
      echo "$?" > "$dir/rc.$i"
    ) &
    notify_pids="$notify_pids $!"
  done
  for pid in $notify_pids; do
    wait "$pid" || true
  done
  for i in 1 2 3 4 5; do
    rc=$(cat "$dir/rc.$i")
    expect_code 0 "$rc" "concurrent: caller $i should succeed"
  done
  [ "$(request_count "$dir/requests.jsonl")" = 1 ] || fail "concurrent: expected exactly one HTTP delivery"
  pass "fm-captain-notify serializes concurrent calls and delivers one request per successful key"
}

test_multiline_text_is_json_data() {
  local dir msg rc
  dir="$TMP_ROOT/multiline"
  mkdir -p "$dir"
  write_behavior "$dir" '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"
  msg=$(cat <<'EOF'
Captain, this decision needs approval.

Approve with:
```
APPROVE firstmate-slack-milestone-delivery
```

Full URL: https://github.com/example/repo/pull/42?check_suite_focus=true
EOF
)

  run_notify_case "$dir" "multiline:key" "$msg"
  rc=$?

  expect_code 0 "$rc" "multiline: notification should deliver"
  EXPECTED_TEXT=$msg python3 - "$dir/requests.jsonl" <<'PY' || fail "multiline: posted JSON text did not match exactly"
import json
import os
import sys
with open(sys.argv[1], encoding="utf-8") as f:
    record = json.loads(f.readline())
actual = record["json"].get("text")
if actual != os.environ["EXPECTED_TEXT"]:
    raise SystemExit(f"mismatch: {actual!r}")
PY
  pass "fm-captain-notify keeps multiline fenced approval phrases and URLs as JSON data"
}

test_audit_is_redacted() {
  local dir rc
  dir="$TMP_ROOT/audit-redaction"
  mkdir -p "$dir"
  write_behavior "$dir" '{"status":200,"body":"ok","delay":0}'
  start_server "$dir"

  run_notify_case "$dir" "audit:key" "Captain, SECRET_TOKEN must stay out of the audit. https://private.example/path"
  rc=$?

  expect_code 0 "$rc" "audit-redaction: notification should deliver"
  assert_no_grep 'SECRET_TOKEN' "$dir/state/slack-hook-2-audit.jsonl" \
    "audit-redaction: audit leaked message body"
  assert_no_grep 'private.example' "$dir/state/slack-hook-2-audit.jsonl" \
    "audit-redaction: audit leaked message URL"
  assert_no_grep '127.0.0.1' "$dir/state/slack-hook-2-audit.jsonl" \
    "audit-redaction: audit leaked endpoint details"
  pass "fm-captain-notify audit records omit message bodies and endpoint details"
}

make_pr_state() {
  local dir=$1
  mkdir -p "$dir/state"
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$dir/missing-worktree" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

add_gh_axi_success() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$dir/fakebin/gh-axi"
}

test_pr_check_notification_failure_is_nonblocking() {
  local dir rc
  dir="$TMP_ROOT/pr-check-nonblocking"
  mkdir -p "$dir"
  make_pr_state "$dir"
  write_behavior "$dir" '{"status":500,"body":"bad","delay":0}' '{"status":500,"body":"bad","delay":0}'
  start_server "$dir"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_SLACK_HOOK_2_URL_FOR_TESTS="$SERVER_URL" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/50 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?

  expect_code 0 "$rc" "pr-check-nonblocking: PR registration should still succeed"
  assert_grep 'armed: state/task-x1.check.sh' "$dir/stdout" \
    "pr-check-nonblocking: PR poll was not armed"
  assert_grep 'warning: captain Slack notification failed' "$dir/stderr" \
    "pr-check-nonblocking: notification failure was not visible"
  [ "$(request_count "$dir/requests.jsonl")" = 2 ] || fail "pr-check-nonblocking: expected one retry"
  pass "fm-pr-check reports Slack failure without blocking review-ready registration"
}

test_pr_merge_notification_failure_is_nonblocking() {
  local dir rc
  dir="$TMP_ROOT/pr-merge-nonblocking"
  mkdir -p "$dir"
  make_pr_state "$dir"
  add_gh_axi_success "$dir"
  : > "$dir/gh-axi.log"
  write_behavior "$dir" '{"status":500,"body":"bad","delay":0}' '{"status":500,"body":"bad","delay":0}'
  start_server "$dir"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  FM_SLACK_HOOK_2_URL_FOR_TESTS="$SERVER_URL" \
  PATH="$dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/51 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?

  expect_code 0 "$rc" "pr-merge-nonblocking: merge should still succeed"
  grep -qxF 'pr merge 51 --repo example/repo --squash' "$dir/gh-axi.log" \
    || fail "pr-merge-nonblocking: gh-axi merge was not called"
  assert_grep 'warning: captain Slack notification failed' "$dir/stderr" \
    "pr-merge-nonblocking: notification failure was not visible"
  [ "$(request_count "$dir/requests.jsonl")" = 2 ] || fail "pr-merge-nonblocking: expected only the merge notification retry"
  pass "fm-pr-merge reports Slack failure without blocking a verified merge"
}

test_local_merge_notification_failure_is_nonblocking() {
  local dir project rc
  dir="$TMP_ROOT/local-merge-nonblocking"
  project="$dir/project"
  mkdir -p "$dir/state" "$project"
  git -C "$project" init -q -b main
  printf 'one\n' > "$project/file.txt"
  git -C "$project" add file.txt
  git -C "$project" commit -qm initial
  git -C "$project" checkout -q -b fm/local-x1
  printf 'two\n' > "$project/file.txt"
  git -C "$project" commit -am update -q
  git -C "$project" checkout -q main
  fm_write_meta "$dir/state/local-x1.meta" \
    "project=$project" \
    "mode=local-only" \
    "kind=ship"
  write_behavior "$dir" '{"status":500,"body":"bad","delay":0}' '{"status":500,"body":"bad","delay":0}'
  start_server "$dir"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_SLACK_HOOK_2_URL_FOR_TESTS="$SERVER_URL" \
    "$LOCAL_MERGE" local-x1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?

  expect_code 0 "$rc" "local-merge-nonblocking: local merge should still succeed"
  assert_grep 'merged fm/local-x1 into local main' "$dir/stdout" \
    "local-merge-nonblocking: local merge output missing"
  assert_grep 'warning: captain Slack notification failed' "$dir/stderr" \
    "local-merge-nonblocking: notification failure was not visible"
  [ "$(git -C "$project" rev-parse main)" = "$(git -C "$project" rev-parse fm/local-x1)" ] \
    || fail "local-merge-nonblocking: main did not fast-forward"
  pass "fm-merge-local reports Slack failure without blocking approved local landing"
}

test_success_delivers_once_and_records_audit
test_exact_ok_is_required
test_ordinary_4xx_refuses_without_retry
test_5xx_retries_once
test_timeout_retries_once
test_successful_dedup_sends_no_second_request
test_failed_attempt_is_not_deduped
test_concurrent_same_key_delivers_once
test_multiline_text_is_json_data
test_audit_is_redacted
test_pr_check_notification_failure_is_nonblocking
test_pr_merge_notification_failure_is_nonblocking
test_local_merge_notification_failure_is_nonblocking

echo "# fm-captain-notify.test.sh: all assertions passed"
