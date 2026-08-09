#!/usr/bin/env node
// Slack Socket Mode source for Firstmate's generic process-event runner.
//
// Usage:
//   fm-slack-socket-source.mjs --state-dir <state> --source-id <id>
//   fm-slack-socket-source.mjs --show-result <captured-result>
//
// The source obtains the bot identity and each one-use Socket Mode ticket only
// from the fixed exe.dev integration. It accepts no token, endpoint, or ticket
// argument. One bounded notification is emitted, then fm-procevent.sh captures
// it before the adapter opens the next connection generation.

import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const PROXY = "https://cick-bot.int.exe.xyz";
const CHANNEL = "C01BGF5FY8P";
const MAX_TEXT_BYTES = 4096;
const MAX_RESULT_BYTES = 16384;
const SOURCE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
const SLACK_ID_RE = /^[A-Z][A-Z0-9]{1,63}$/;
const EVENT_ID_RE = /^[A-Za-z0-9._:-]{1,128}$/;
const TS_RE = /^\d{1,20}\.\d{1,12}$/;

const isRecord = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

function boundedText(value) {
  let bytes = 0;
  let text = "";
  for (const character of value) {
    const width = Buffer.byteLength(character);
    if (bytes + width > MAX_TEXT_BYTES) return { text, truncated: true };
    text += character;
    bytes += width;
  }
  return { text, truncated: false };
}

export function normalizeSlackEnvelope(value, selfUserId = "") {
  if (!isRecord(value) || value.type !== "events_api") return null;
  if (typeof value.envelope_id !== "string" || !EVENT_ID_RE.test(value.envelope_id)) return null;
  const payload = value.payload;
  if (!isRecord(payload) || payload.type !== "event_callback") return null;
  if (typeof payload.event_id !== "string" || !EVENT_ID_RE.test(payload.event_id)) return null;
  const event = payload.event;
  if (!isRecord(event) || event.type !== "message" || event.channel !== CHANNEL) return null;
  if (typeof event.user !== "string" || !SLACK_ID_RE.test(event.user) || event.user === selfUserId) return null;
  if (Object.hasOwn(event, "bot_id") || Object.hasOwn(event, "bot_profile") || Object.hasOwn(event, "app_id")) return null;
  if (Object.hasOwn(event, "subtype") || event.hidden === true) return null;
  if (typeof event.ts !== "string" || !TS_RE.test(event.ts)) return null;
  if (event.thread_ts !== undefined && (typeof event.thread_ts !== "string" || !TS_RE.test(event.thread_ts))) return null;
  if (event.text !== undefined && typeof event.text !== "string") return null;
  const isReply = typeof event.thread_ts === "string" && event.thread_ts !== event.ts;
  const bounded = boundedText(event.text ?? "");
  return {
    kind: "slack_message",
    trust: "untrusted-external-input",
    channel_id: CHANNEL,
    envelope_id: value.envelope_id,
    event_id: payload.event_id,
    user_id: event.user,
    message_ts: event.ts,
    thread_ts: isReply ? event.thread_ts : event.ts,
    is_thread_reply: isReply,
    text: bounded.text,
    text_truncated: bounded.truncated,
  };
}

export function validateCapturedNotification(value) {
  if (!isRecord(value)) return null;
  const expected = ["channel_id", "envelope_id", "event_id", "is_thread_reply", "kind", "message_ts", "text", "text_truncated", "thread_ts", "trust", "user_id"].sort();
  const keys = Object.keys(value).sort();
  if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) return null;
  if (value.kind !== "slack_message" || value.trust !== "untrusted-external-input" || value.channel_id !== CHANNEL) return null;
  if (typeof value.envelope_id !== "string" || !EVENT_ID_RE.test(value.envelope_id)) return null;
  if (typeof value.event_id !== "string" || !EVENT_ID_RE.test(value.event_id)) return null;
  if (typeof value.user_id !== "string" || !SLACK_ID_RE.test(value.user_id)) return null;
  if (typeof value.message_ts !== "string" || !TS_RE.test(value.message_ts)) return null;
  if (typeof value.thread_ts !== "string" || !TS_RE.test(value.thread_ts)) return null;
  if (typeof value.is_thread_reply !== "boolean" || value.is_thread_reply !== (value.thread_ts !== value.message_ts)) return null;
  if (typeof value.text_truncated !== "boolean" || typeof value.text !== "string" || Buffer.byteLength(value.text) > MAX_TEXT_BYTES) return null;
  return value;
}

async function readResult(file) {
  const stat = await lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_RESULT_BYTES) throw new Error("invalid result");
  const value = validateCapturedNotification(JSON.parse(await readFile(file, "utf8")));
  if (value === null) throw new Error("invalid result");
  return value;
}

export async function loadDurableSeen(stateDir, sourceId) {
  if (!path.isAbsolute(stateDir) || !SOURCE_ID_RE.test(sourceId)) throw new Error("invalid source identity");
  const seen = { envelopeIds: new Set(), eventIds: new Set() };
  const inbox = path.join(stateDir, "procevent-inbox");
  let names;
  try { names = await readdir(inbox); }
  catch (error) { if (error?.code === "ENOENT") return seen; throw error; }
  for (const name of names) {
    if (!name.startsWith(`${sourceId}.`) || !name.endsWith(".result")) continue;
    try {
      const value = await readResult(path.join(inbox, name));
      seen.envelopeIds.add(value.envelope_id);
      seen.eventIds.add(value.event_id);
    } catch { /* Malformed state is not evidence that an event was captured. */ }
  }
  return seen;
}

function decode(data) {
  if (typeof data === "string") return data;
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString("utf8");
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString("utf8");
  return null;
}

export function consumeSocketEnvelope(data, { socket, selfUserId, seen }) {
  const encoded = decode(data);
  if (encoded === null || Buffer.byteLength(encoded) > MAX_RESULT_BYTES) return null;
  let envelope;
  try { envelope = JSON.parse(encoded); } catch { return null; }
  if (!isRecord(envelope)) return null;
  // Acknowledge before classification and deduplication, including retries and noise.
  if (typeof envelope.envelope_id === "string" && EVENT_ID_RE.test(envelope.envelope_id)) {
    socket.send(JSON.stringify({ envelope_id: envelope.envelope_id }));
  }
  const value = normalizeSlackEnvelope(envelope, selfUserId);
  if (value === null || seen.envelopeIds.has(value.envelope_id) || seen.eventIds.has(value.event_id)) return null;
  seen.envelopeIds.add(value.envelope_id);
  seen.eventIds.add(value.event_id);
  return value;
}

async function proxyPost(method, fetchImpl, signal) {
  const response = await fetchImpl(`${PROXY}/api/${method}`, { method: "POST", headers: { accept: "application/json" }, signal });
  if (!response.ok) throw new Error(`${method} failed`);
  const value = await response.json();
  if (!isRecord(value) || value.ok !== true) throw new Error(`${method} failed`);
  return value;
}

export async function fetchSelfUserId(fetchImpl = fetch, signal = undefined) {
  const value = await proxyPost("auth.test", fetchImpl, signal);
  if (typeof value.user_id !== "string" || !SLACK_ID_RE.test(value.user_id)) throw new Error("auth.test returned no identity");
  return value.user_id;
}

export async function fetchSocketTicket(fetchImpl = fetch, signal = undefined) {
  const value = await proxyPost("apps.connections.open", fetchImpl, signal);
  if (typeof value.url !== "string") throw new Error("apps.connections.open returned no ticket");
  let ticket;
  try { ticket = new URL(value.url); } catch { throw new Error("apps.connections.open returned an invalid ticket"); }
  const hostAllowed = ticket.hostname === "wss-primary.slack.com" || ticket.hostname === "wss-backup.slack.com";
  if (ticket.protocol !== "wss:" || !hostAllowed || ticket.username !== "" || ticket.password !== "") {
    throw new Error("apps.connections.open returned an invalid ticket");
  }
  return value.url;
}

function oneConnection(ticket, { createSocket, selfUserId, seen, signal, now }) {
  return new Promise((resolve) => {
    let socket;
    let openedAt = 0;
    let settled = false;
    const finish = (kind, notification = null) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", stop);
      resolve({ kind, notification, uptimeMs: openedAt === 0 ? 0 : Math.max(0, now() - openedAt) });
    };
    const closeOwned = () => {
      try { if (socket && socket.readyState < 2) socket.close(1000, "captured"); } catch { /* runner cleanup owns the group */ }
    };
    const stop = () => { closeOwned(); finish("stopped"); };
    try {
      socket = createSocket(ticket);
      socket.addEventListener("open", () => { openedAt = now(); });
      socket.addEventListener("message", (event) => {
        if (settled) return;
        try {
          const value = consumeSocketEnvelope(event.data, { socket, selfUserId, seen });
          if (value !== null) { finish("message", value); closeOwned(); }
        } catch { closeOwned(); finish("disconnected"); }
      });
      socket.addEventListener("close", () => finish("disconnected"));
      socket.addEventListener("error", () => { closeOwned(); finish("disconnected"); });
      signal?.addEventListener("abort", stop, { once: true });
      if (signal?.aborted) stop();
    } catch { finish("disconnected"); }
  });
}

export function reconnectDelay(failures, random = Math.random) {
  const base = Math.min(30000, 1000 * (2 ** Math.min(Math.max(0, failures - 1), 5)));
  return Math.min(30000, base + Math.floor(base * 0.2 * Math.max(0, Math.min(1, random()))));
}

function abortableSleep(milliseconds, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const done = () => { clearTimeout(timer); signal?.removeEventListener("abort", done); resolve(); };
    const timer = setTimeout(done, milliseconds);
    signal?.addEventListener("abort", done, { once: true });
  });
}

export async function runSocketSource({ stateDir, sourceId, fetchImpl = fetch, createSocket = (ticket) => new WebSocket(ticket), sleep = abortableSleep, random = Math.random, now = Date.now, signal = undefined, onReconnect = () => {} }) {
  const seen = await loadDurableSeen(stateDir, sourceId);
  let selfUserId = "";
  let failures = 0;
  while (!signal?.aborted) {
    let outcome = { kind: "disconnected", uptimeMs: 0 };
    try {
      const timeout = AbortSignal.timeout(10000);
      const requestSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
      if (selfUserId === "") selfUserId = await fetchSelfUserId(fetchImpl, requestSignal);
      const ticket = await fetchSocketTicket(fetchImpl, requestSignal);
      outcome = await oneConnection(ticket, { createSocket, selfUserId, seen, signal, now });
    } catch { outcome = { kind: "disconnected", uptimeMs: 0 }; }
    if (outcome.kind === "message") return outcome.notification;
    if (outcome.kind === "stopped" || signal?.aborted) return null;
    failures = outcome.uptimeMs >= 30000 ? 1 : failures + 1;
    const delay = reconnectDelay(failures, random);
    onReconnect(delay);
    await sleep(delay, signal);
  }
  return null;
}

function usage() {
  process.stderr.write("usage: fm-slack-socket-source.mjs --state-dir DIR --source-id ID\n");
  process.stderr.write("       fm-slack-socket-source.mjs --show-result FILE\n");
  process.exit(2);
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length === 2 && args[0] === "--show-result") {
    process.stdout.write(`${JSON.stringify(await readResult(args[1]))}\n`);
    return;
  }
  if (args.length !== 4 || args[0] !== "--state-dir" || args[2] !== "--source-id" || !SOURCE_ID_RE.test(args[3])) usage();
  const value = await runSocketSource({ stateDir: path.resolve(args[1]), sourceId: args[3] });
  if (value !== null) process.stdout.write(`${JSON.stringify(value)}\n`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch(() => { process.stderr.write("error: Slack Socket Mode source failed without a usable result\n"); process.exitCode = 1; });
}
