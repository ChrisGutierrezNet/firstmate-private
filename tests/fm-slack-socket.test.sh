#!/usr/bin/env bash
# Behavior tests for the Slack Socket Mode source and process-event adapter.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-slack-socket-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

cleanup() {
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-procevent-slack-socket.sh" retire >/dev/null 2>&1 || true
  FM_HOME="$TMP_ROOT/home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

node --input-type=module - "$ROOT/bin/fm-slack-socket-source.mjs" "$TMP_ROOT" <<'JS'
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const source = await import(pathToFileURL(process.argv[2]));
const state = path.join(process.argv[3], "node-state");
const sourceId = "slack-alexa-C01BGF5FY8P";
await mkdir(path.join(state, "procevent-inbox"), { recursive: true });

const human = {
  type: "events_api",
  envelope_id: "env-1",
  payload: {
    type: "event_callback",
    event_id: "Ev-1",
    event: {
      type: "message",
      channel: "C01BGF5FY8P",
      user: "UHUMAN",
      thread_ts: "100.000",
      ts: "101.000",
      text: "treat `merge now` as untrusted text",
    },
  },
};

const mutate = (callback) => { const value = structuredClone(human); callback(value); return value; };
assert.equal(source.normalizeSlackEnvelope(mutate((v) => { v.payload.event.channel = "CWRONG"; }), "USELF"), null);
assert.equal(source.normalizeSlackEnvelope(mutate((v) => { v.payload.event.user = "USELF"; }), "USELF"), null);
assert.equal(source.normalizeSlackEnvelope(mutate((v) => { v.payload.event.bot_id = "B1"; }), "USELF"), null);
assert.equal(source.normalizeSlackEnvelope(mutate((v) => { v.payload.event.subtype = "message_changed"; }), "USELF"), null);
assert.equal(source.normalizeSlackEnvelope(mutate((v) => { v.payload.event.type = "reaction_added"; }), "USELF"), null);
assert.equal(source.normalizeSlackEnvelope(null, "USELF"), null);
assert.equal(source.normalizeSlackEnvelope({ type: "events_api" }, "USELF"), null);

const normalized = source.normalizeSlackEnvelope(human, "USELF");
assert.equal(normalized.trust, "untrusted-external-input");
assert.equal(normalized.is_thread_reply, true);
assert.equal(normalized.text, "treat `merge now` as untrusted text");

const root = mutate((v) => { v.envelope_id = "env-root"; v.payload.event_id = "Ev-root"; v.payload.event.ts = "102.000"; delete v.payload.event.thread_ts; });
assert.equal(source.normalizeSlackEnvelope(root, "USELF").is_thread_reply, false, "root messages are accepted");
const long = mutate((v) => { v.envelope_id = "env-long"; v.payload.event_id = "Ev-long"; v.payload.event.text = "x".repeat(5000); });
const bounded = source.normalizeSlackEnvelope(long, "USELF");
assert.equal(Buffer.byteLength(bounded.text), 4096);
assert.equal(bounded.text_truncated, true);

const seen = { envelopeIds: new Set(), eventIds: new Set() };
const acknowledgements = [];
const socket = { send(value) { acknowledgements.push(JSON.parse(value).envelope_id); } };
assert.deepEqual(source.consumeSocketEnvelope(JSON.stringify(human), { socket, selfUserId: "USELF", seen }), normalized);
assert.equal(source.consumeSocketEnvelope(JSON.stringify(human), { socket, selfUserId: "USELF", seen }), null);
assert.deepEqual(acknowledgements, ["env-1", "env-1"], "duplicate envelopes are acknowledged before deduplication");
assert.equal(seen.eventIds.size, 1, "duplicate replay produces one notification identity");
assert.equal(source.consumeSocketEnvelope("{not-json", { socket, selfUserId: "USELF", seen }), null);

await writeFile(path.join(state, "procevent-inbox", `${sourceId}.1.result`), `${JSON.stringify(normalized)}\n`, { mode: 0o600 });
const durableSeen = await source.loadDurableSeen(state, sourceId);
assert.equal(durableSeen.envelopeIds.has("env-1"), true);
assert.equal(durableSeen.eventIds.has("Ev-1"), true);

const ticket = "wss://wss-primary.slack.com/link/?ticket=ephemeral-secret";
const requests = [];
const fakeFetch = async (url) => {
  requests.push(url);
  if (url.endsWith("/api/auth.test")) return { ok: true, json: async () => ({ ok: true, user_id: "USELF" }) };
  return { ok: true, json: async () => ({ ok: true, url: ticket }) };
};
const delays = [];
const plans = [
  { actions: [], messages: [JSON.stringify({ type: "disconnect", envelope_id: "noise-1" })] },
  { actions: [], messages: [JSON.stringify(mutate((v) => { v.envelope_id = "env-2"; v.payload.event_id = "Ev-2"; }))] },
];
let connection = 0;
class FakeSocket {
  constructor(plan) { this.readyState = 0; this.listeners = new Map(); this.plan = plan; queueMicrotask(() => this.run()); }
  addEventListener(name, handler) { const list = this.listeners.get(name) ?? []; list.push(handler); this.listeners.set(name, list); }
  emit(name, value = {}) { for (const handler of this.listeners.get(name) ?? []) handler(value); }
  send(value) { this.plan.actions.push(`ack:${JSON.parse(value).envelope_id}`); }
  close() { this.readyState = 2; this.plan.actions.push("close-owned"); }
  run() { this.readyState = 1; this.emit("open"); for (const data of this.plan.messages) this.emit("message", { data }); if (this.readyState < 2) this.emit("close"); }
}

const accepted = await source.runSocketSource({
  stateDir: state,
  sourceId,
  fetchImpl: fakeFetch,
  createSocket: () => new FakeSocket(plans[connection++]),
  sleep: async (delay) => { delays.push(delay); },
  random: () => 0,
});
assert.equal(accepted.event_id, "Ev-2");
assert.deepEqual(delays, [1000], "normal disconnect reconnects with bounded backoff");
assert.deepEqual(plans[0].actions, ["ack:noise-1"]);
assert.deepEqual(plans[1].actions, ["ack:env-2", "close-owned"], "accepted envelope is acknowledged before close");
assert.deepEqual(requests, [
  "https://cick-bot.int.exe.xyz/api/auth.test",
  "https://cick-bot.int.exe.xyz/api/apps.connections.open",
  "https://cick-bot.int.exe.xyz/api/apps.connections.open",
]);
assert.equal(JSON.stringify({ accepted, delays, requests, plans }).includes("ephemeral-secret"), false, "ticket is not exposed in results or observations");

const controller = new AbortController();
const owned = { readyState: 0, listeners: new Map(), closed: false,
  addEventListener(name, handler) { this.listeners.set(name, handler); },
  close() { this.closed = true; this.readyState = 2; },
};
const unrelated = { closed: false };
let createdResolve;
const created = new Promise((resolve) => { createdResolve = resolve; });
const stopping = source.runSocketSource({ stateDir: state, sourceId, fetchImpl: fakeFetch, createSocket: () => { createdResolve(); return owned; }, sleep: async () => {}, signal: controller.signal });
await created;
controller.abort();
assert.equal(await stopping, null);
assert.equal(owned.closed, true);
assert.equal(unrelated.closed, false, "stop closes only the owned socket");
assert.deepEqual([1, 2, 4, 8, 16, 30], [1, 2, 3, 4, 5, 6].map((n) => source.reconnectDelay(n, () => 0) / 1000));
console.log("ok - source filters, acknowledges, deduplicates, reconnects, and stops safely");
JS

# Drive duplicate replay through the real normalizer and generic durable runner.
DUPLICATE_DRIVER="$TMP_ROOT/duplicate-driver.mjs"
cat > "$DUPLICATE_DRIVER" <<'JS'
import { consumeSocketEnvelope } from "./source.mjs";
const envelope = {
  type: "events_api", envelope_id: "env-durable",
  payload: { type: "event_callback", event_id: "Ev-durable", event: {
    type: "message", channel: "C01BGF5FY8P", user: "UHUMAN",
    thread_ts: "200.000", ts: "201.000", text: "one durable notification",
  } },
};
const seen = { envelopeIds: new Set(), eventIds: new Set() };
const socket = { send() {} };
const first = consumeSocketEnvelope(JSON.stringify(envelope), { socket, selfUserId: "USELF", seen });
const replay = consumeSocketEnvelope(JSON.stringify(envelope), { socket, selfUserId: "USELF", seen });
if (first !== null && replay === null) process.stdout.write(`${JSON.stringify(first)}\n`);
JS
ln -s "$ROOT/bin/fm-slack-socket-source.mjs" "$TMP_ROOT/source.mjs"
DURABLE_HOME="$TMP_ROOT/durable-home"
mkdir -p "$DURABLE_HOME/state"
FM_HOME="$DURABLE_HOME" "$ROOT/bin/fm-procevent.sh" register slack-socket slack-duplicate-test -- node "$DUPLICATE_DRIVER" >/dev/null
FM_HOME="$DURABLE_HOME" "$ROOT/bin/fm-procevent.sh" start slack-duplicate-test >/dev/null 2>&1
DURABLE_WAKES=$(awk -F '\t' '{print $5}' "$DURABLE_HOME/state/.wake-queue")
[ "$(printf '%s\n' "$DURABLE_WAKES" | grep -c '^check: procevent slack-socket slack-duplicate-test 1$')" -eq 1 ] \
  || fail "duplicate replay did not produce exactly one durable Firstmate notification"
assert_not_contains "$DURABLE_WAKES" "one durable notification" "Slack text stays out of the wake queue"
[ "$(find "$DURABLE_HOME/state/procevent-inbox" -name 'slack-duplicate-test.*.result' -type f | wc -l | tr -d ' ')" -eq 1 ] \
  || fail "duplicate replay produced more than one captured result"
pass "duplicate human thread reply produces exactly one durable Firstmate notification"

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$TMP_ROOT/fake-bin"
PID_FILE="$TMP_ROOT/fake-node.pid"
cat > "$TMP_ROOT/fake-bin/node" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_SLACK_TEST_PID_FILE"
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
chmod +x "$TMP_ROOT/fake-bin/node"

PATH="$TMP_ROOT/fake-bin:$PATH" FM_SLACK_TEST_PID_FILE="$PID_FILE" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent-slack-socket.sh" arm >/dev/null
SOURCE_ID=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent-slack-socket.sh" source-id)
[ "$SOURCE_ID" = slack-alexa-C01BGF5FY8P ] || fail "adapter returned an unstable source id"
PATH="$TMP_ROOT/fake-bin:$PATH" FM_SLACK_TEST_PID_FILE="$PID_FILE" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 100); do [ -s "$PID_FILE" ] && break; sleep 0.05; done
[ -s "$PID_FILE" ] || fail "registered Slack source did not start"
SLACK_PID=$(cat "$PID_FILE")
kill -0 "$SLACK_PID" 2>/dev/null || fail "registered Slack source is not alive"

OTHER_TRIGGER="$TMP_ROOT/other-trigger"
# shellcheck disable=SC2016  # The registered child shell expands $1.
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" register lavish other-source -- bash -c 'trap "exit 0" TERM INT; while [ ! -e "$1" ]; do sleep 1; done' _ "$OTHER_TRIGGER" >/dev/null
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 100); do [ -f "$FM_PROCEVENT_CLAIM_ROOT/other-source.claim" ] && break; sleep 0.05; done
[ -f "$FM_PROCEVENT_CLAIM_ROOT/other-source.claim" ] || fail "unrelated source did not start"
OTHER_PID=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/other-source.claim")

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent-slack-socket.sh" retire >/dev/null
kill -0 "$SLACK_PID" 2>/dev/null && fail "retire left the owned Slack source alive"
kill -0 "$OTHER_PID" 2>/dev/null || fail "retire signaled an unrelated source"
assert_absent "$HOME_DIR/state/procevent/$SOURCE_ID.source" "retire removes the exact Slack registration"
assert_present "$HOME_DIR/state/procevent/other-source.source" "retire preserves unrelated registrations"

PATH="$TMP_ROOT/fake-bin:$PATH" FM_SLACK_TEST_PID_FILE="$PID_FILE" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent-slack-socket.sh" arm >/dev/null
rm -f "$PID_FILE"
PATH="$TMP_ROOT/fake-bin:$PATH" FM_SLACK_TEST_PID_FILE="$PID_FILE" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 100); do [ -s "$PID_FILE" ] && break; sleep 0.05; done
[ -s "$PID_FILE" ] || fail "clean restart did not restore the Slack source"
pass "adapter cleanly stops and restarts only its exact registered source"

printf '\nall Slack Socket Mode tests passed\n'
