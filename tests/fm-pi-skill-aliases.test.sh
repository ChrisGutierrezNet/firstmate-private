#!/usr/bin/env bash
# Tests for Firstmate's Pi-only bare aliases for user-invocable skills.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-skill-aliases)
ALIAS_EXT="$ROOT/.pi/extensions/fm-primary-skill-aliases.ts"
ALIAS_NAMES="ahoy bearings afk stow updatefirstmate"
export NODE_NO_WARNINGS=1

test_static_extension_contract() {
  local text
  assert_present "$ALIAS_EXT" "tracked Pi skill alias extension is missing"
  text=$(cat "$ALIAS_EXT")
  for name in $ALIAS_NAMES; do
    assert_contains "$text" "alias: \"$name\"" "Pi alias extension does not define /$name"
    assert_contains "$text" "skill: \"$name\"" "Pi alias extension does not map /$name to /skill:$name"
    assert_contains "$text" "pi.registerCommand(alias.alias" "Pi alias extension does not use Pi's command registration path"
  done
  assert_contains "$text" "pi.sendUserMessage(message" "Pi alias extension does not redispatch through Pi user-message processing"
  assert_contains "$text" "stripFrontmatter" "Pi alias extension does not build Pi-equivalent skill expansion from the loaded SKILL.md"
  assert_contains "$text" "hasNativeSkillCommand" "Pi alias extension does not require the native skill command before dispatch"
  assert_contains "$text" "getSystemPromptOptions().skills" "Pi alias extension does not use Pi's loaded skill metadata"
  assert_contains "$text" "commandCollisions" "Pi alias extension does not check command collisions"
  assert_contains "$text" "deliverAs: \"steer\"" "Pi alias extension does not handle busy Pi sessions deterministically"
  assert_contains "$text" ".pi-skill-aliases-extension-loaded" "Pi alias extension does not write a loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "Pi alias extension does not self-hash its own content"
  assert_not_contains "$text" ".agents/skills/ahoy/SKILL.md" "Pi alias extension duplicates a skill body path"
  pass "Pi skill alias extension is tracked, narrow, and dispatches expanded skill content once"
}

test_handler_dispatch_and_collision_contract() {
  local fixture plugin out status=0
  fixture="$TMP_ROOT/handler-plugin"
  plugin="$fixture/.pi/extensions/fm-primary-skill-aliases.ts"
  mkdir -p "$fixture/.pi/extensions" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  cp "$ALIAS_EXT" "$plugin"
  cat > "$fixture/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$fixture/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function stripFrontmatter(content) {
  return content.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, "");
}
JS

  out=$(PLUGIN="$plugin" TEST_TMP="$TMP_ROOT" node --input-type=module <<'JS'
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const pluginPath = process.env.PLUGIN;
const mod = await import(pathToFileURL(pluginPath).href);
const aliases = ["ahoy", "bearings", "afk", "stow", "updatefirstmate"];
let extraCommands = [];
let availableSkills = new Set(aliases);
const registeredCommands = [];
const handlers = new Map();
const inputHandlers = [];
const sent = [];
const notices = [];
const skillRoot = `${process.env.TEST_TMP}/handler-skills`;
const loadedSkills = aliases.map((name) => {
  const baseDir = `${skillRoot}/${name}`;
  const filePath = `${baseDir}/SKILL.md`;
  mkdirSync(baseDir, { recursive: true });
  writeFileSync(filePath, `---\nname: ${name}\ndescription: ${name} test skill\n---\n\n# ${name}\n\n${name.toUpperCase()}_BODY_SENTINEL\n`);
  return { name, filePath, baseDir };
});

const sourceInfo = (path, source = "test") => ({
  path,
  source,
  scope: "temporary",
  origin: "top-level",
});

const pi = {
  on(event, handler) {
    if (event === "input") inputHandlers.push(handler);
  },
  registerCommand(name, options) {
    handlers.set(name, options.handler);
    registeredCommands.push({
      name,
      description: options.description,
      source: "extension",
      sourceInfo: sourceInfo(pluginPath, "cli"),
    });
  },
  getCommands() {
    const skillCommands = [...availableSkills].map((name) => ({
      name: `skill:${name}`,
      source: "skill",
      sourceInfo: sourceInfo(`/skills/${name}/SKILL.md`, "path"),
    }));
    return [...registeredCommands, ...extraCommands, ...skillCommands];
  },
  sendUserMessage(message, options) {
    sent.push({ message, options: options ?? null });
  },
};

await mod.default(pi);

if (registeredCommands.map((c) => c.name).join(" ") !== aliases.join(" ")) {
  throw new Error(`registered aliases mismatch: ${registeredCommands.map((c) => c.name).join(" ")}`);
}

const ctx = (idle) => ({
  isIdle: () => idle,
  getSystemPromptOptions: () => ({ skills: loadedSkills }),
  ui: { notify: (message, type) => notices.push({ message, type }) },
});
const idleCtx = ctx(true);
const busyCtx = ctx(false);

for (const name of aliases) {
  const args = `ARG_${name}  /literal-${name}`;
  await handlers.get(name)(args, idleCtx);
  const last = sent.at(-1);
  if (!last.message.includes(`<skill name="${name}"`)) {
    throw new Error(`${name} did not expand its matching skill block: ${JSON.stringify(last)}`);
  }
  if (!last.message.includes(`${name.toUpperCase()}_BODY_SENTINEL`)) {
    throw new Error(`${name} skill body was not loaded: ${JSON.stringify(last)}`);
  }
  if (!last.message.endsWith(`\n\n${args}`)) {
    throw new Error(`${name} args were not preserved exactly: ${JSON.stringify(last)}`);
  }
  if (last.message.includes(`/skill:${name}`)) {
    throw new Error(`${name} leaked a literal native command instead of expanded content: ${JSON.stringify(last)}`);
  }
  if (last.options !== null) {
    throw new Error(`${name} idle dispatch unexpectedly used delivery options`);
  }
}

await handlers.get("ahoy")("alpha  beta\n/stow --not-a-command", idleCtx);
if (!sent.at(-1).message.includes('<skill name="ahoy"')) {
  throw new Error(`ahoy did not expand a skill block: ${JSON.stringify(sent.at(-1))}`);
}
if (!sent.at(-1).message.includes("AHOY_BODY_SENTINEL")) {
  throw new Error(`ahoy skill body was not loaded: ${JSON.stringify(sent.at(-1))}`);
}
if (!sent.at(-1).message.endsWith("\n\nalpha  beta\n/stow --not-a-command")) {
  throw new Error(`ahoy args were not preserved exactly: ${JSON.stringify(sent.at(-1))}`);
}
if (sent.at(-1).message.includes("/skill:ahoy")) {
  throw new Error(`ahoy leaked a literal native command instead of expanded content: ${JSON.stringify(sent.at(-1))}`);
}
if (sent.at(-1).options !== null) {
  throw new Error("idle dispatch unexpectedly used delivery options");
}

await handlers.get("bearings")("fleet please", busyCtx);
if (!sent.at(-1).message.includes('<skill name="bearings"') || !sent.at(-1).message.endsWith("\n\nfleet please")) {
  throw new Error(`bearings args were not forwarded: ${JSON.stringify(sent.at(-1))}`);
}
if (sent.at(-1).options?.deliverAs !== "steer") {
  throw new Error(`busy dispatch did not use steer delivery: ${JSON.stringify(sent.at(-1))}`);
}

await handlers.get("stow")("", idleCtx);
if (!sent.at(-1).message.includes('<skill name="stow"') || !sent.at(-1).message.endsWith("</skill>")) {
  throw new Error(`empty args should not add trailing argument text: ${JSON.stringify(sent.at(-1))}`);
}

const beforeCollisionSends = sent.length;
extraCommands = [{
  name: "afk",
  source: "prompt",
  sourceInfo: sourceInfo("/tmp/afk.md", "project"),
}];
await handlers.get("afk")("now", idleCtx);
if (sent.length !== beforeCollisionSends) throw new Error("collision did not refuse dispatch");
if (!notices.at(-1)?.message.includes("Use /skill:afk")) {
  throw new Error(`collision notice did not point at the native skill: ${JSON.stringify(notices.at(-1))}`);
}

extraCommands = [{
  name: "stow:1",
  source: "extension",
  sourceInfo: sourceInfo("/tmp/other.ts", "cli"),
}];
await handlers.get("stow")("again", idleCtx);
if (sent.length !== beforeCollisionSends) throw new Error("suffixed collision did not refuse dispatch");

const inputResult = await inputHandlers.at(-1)(
  { type: "input", text: "/stow EXACT  args\n/afk --literal", source: "rpc" },
  idleCtx,
);
if (inputResult?.action !== "handled") {
  throw new Error(`suffixed collision input was not handled: ${JSON.stringify(inputResult)}`);
}
if (sent.length !== beforeCollisionSends) throw new Error("suffixed collision input fell through to dispatch");
if (!notices.at(-1)?.message.includes("Use /skill:stow")) {
  throw new Error(`suffixed collision input notice did not point at the native skill: ${JSON.stringify(notices.at(-1))}`);
}

const nonAliasInputResult = await inputHandlers.at(-1)(
  { type: "input", text: "/not-firstmate hello", source: "rpc" },
  idleCtx,
);
if (nonAliasInputResult?.action !== "continue") {
  throw new Error(`non-alias input should continue: ${JSON.stringify(nonAliasInputResult)}`);
}

extraCommands = [];
availableSkills = new Set(aliases.filter((name) => name !== "updatefirstmate"));
await handlers.get("updatefirstmate")("", idleCtx);
if (sent.length !== beforeCollisionSends) throw new Error("missing native skill command fell through to chat");
if (!notices.at(-1)?.message.includes("has not registered /skill:updatefirstmate")) {
  throw new Error(`missing skill notice was not explicit: ${JSON.stringify(notices.at(-1))}`);
}

console.log("ok");
JS
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi alias handler contract failed: $out"
  assert_contains "$out" "ok" "Pi alias handler contract did not complete"
  pass "Pi alias handlers preserve args, refuse collisions, and avoid ordinary-chat fallthrough"
}

test_rpc_command_discovery_lists_aliases_and_native_skills() {
  local out status=0 name
  if ! command -v pi >/dev/null 2>&1; then
    echo "skip: pi not found for RPC command discovery"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "skip: jq not found for RPC command discovery"
    return 0
  fi

  out=$(
    cd "$ROOT" &&
      printf '{"type":"get_commands"}\n' |
        timeout 15s env PI_OFFLINE=1 pi --mode rpc --no-session --approve \
          --no-context-files --no-prompt-templates --no-extensions \
          -e .pi/extensions/fm-primary-skill-aliases.ts \
          --no-skills --skill .agents/skills --offline
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi RPC get_commands failed: $out"

  for name in $ALIAS_NAMES; do
    printf '%s\n' "$out" | jq -e --arg name "$name" --arg path "$ALIAS_EXT" '
      select(.type == "response" and .command == "get_commands")
      | .data.commands[]
      | select(.name == $name and .source == "extension" and (.sourceInfo.path | endswith($path)))
    ' >/dev/null || fail "Pi RPC command discovery did not list /$name as a Firstmate extension alias"

    printf '%s\n' "$out" | jq -e --arg name "skill:$name" '
      select(.type == "response" and .command == "get_commands")
      | .data.commands[]
      | select(.name == $name and .source == "skill")
    ' >/dev/null || fail "Pi RPC command discovery did not keep /skill:$name discoverable"
  done

  pass "Pi RPC command discovery lists bare aliases and native skill commands"
}

test_rpc_bare_ahoy_enters_skill_expanded_context_once() {
  local project proof provider out prompt status=0 line_count
  if ! command -v pi >/dev/null 2>&1; then
    echo "skip: pi not found for RPC alias dispatch E2E"
    return 0
  fi

  project="$TMP_ROOT/rpc-ahoy-project"
  proof="$TMP_ROOT/rpc-ahoy-prompts.jsonl"
  provider="$project/alias-proof-provider.ts"
  mkdir -p "$project/.agents/skills/ahoy"
  fm_git_init_commit "$project"

  cat > "$project/.agents/skills/ahoy/SKILL.md" <<'MD'
---
name: ahoy
description: Test-only Ahoy alias dispatch sentinel.
---

# Ahoy Alias Dispatch Sentinel

The native skill expansion must include `ALIAS_AHOY_SKILL_SENTINEL`.
MD

  cat > "$provider" <<'TS'
import { appendFileSync } from "node:fs";
import {
  createFauxCore,
  fauxAssistantMessage,
  fauxText,
} from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI): void {
  const faux = createFauxCore({
    api: "firstmate-alias-e2e-api",
    provider: "firstmate-alias-e2e",
    models: [{
      id: "deterministic",
      name: "Firstmate alias E2E",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  faux.setResponses([
    fauxAssistantMessage([fauxText("ALIAS_E2E_FINAL")]),
  ]);
  pi.registerProvider("firstmate-alias-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  pi.on("session_start", async (_event, ctx) => {
    const model = ctx.modelRegistry.find("firstmate-alias-e2e", "deterministic");
    if (!model || !(await pi.setModel(model))) {
      throw new Error("Firstmate alias E2E model unavailable");
    }
  });
  pi.on("context", (event) => {
    appendFileSync(process.env.FM_PI_ALIAS_PROOF!, `${JSON.stringify({ messages: event.messages })}\n`);
  });
}
TS

  out=$(
    cd "$project" &&
      printf '{"type":"prompt","message":"/ahoy ARG_EXACT /stow --literal"}\n' |
        timeout 25s env FM_PI_ALIAS_PROOF="$proof" PI_OFFLINE=1 pi --mode rpc --no-session --approve \
          --no-context-files --no-prompt-templates --no-extensions \
          -e "$ALIAS_EXT" -e "$provider" \
          --no-skills --skill .agents/skills --offline
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi RPC bare /ahoy dispatch E2E failed: $out"
  assert_contains "$out" "ALIAS_E2E_FINAL" "deterministic Pi provider did not complete the alias-dispatched turn"
  assert_present "$proof" "Pi alias E2E did not record provider context"

  line_count=$(wc -l < "$proof" | tr -d ' ')
  [ "$line_count" = 1 ] || fail "bare /ahoy produced $line_count provider contexts instead of one"
  prompt=$(cat "$proof")
  assert_contains "$prompt" "ALIAS_AHOY_SKILL_SENTINEL" "bare /ahoy did not enter skill-expanded provider context"
  assert_contains "$prompt" "ARG_EXACT /stow --literal" "bare /ahoy did not preserve command arguments"
  assert_not_contains "$prompt" "/skill:ahoy" "bare /ahoy leaked a literal native skill command into provider context"
  assert_not_contains "$prompt" "/ahoy ARG_EXACT" "bare /ahoy fell through as ordinary chat"

  pass "Pi RPC bare /ahoy dispatch enters skill-expanded context once"
}

test_static_extension_contract
test_handler_dispatch_and_collision_contract
test_rpc_command_discovery_lists_aliases_and_native_skills
test_rpc_bare_ahoy_enters_skill_expanded_context_once
