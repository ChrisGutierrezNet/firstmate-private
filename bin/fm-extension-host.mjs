#!/usr/bin/env node
// Firstmate-owned local extension host for Stage 0.
//
// This file owns the structured JSON parsing and fail-closed validation for
// firstmate.extension/v1 manifests. The shell wrapper owns user-facing help and
// keeps shell lint coverage on the operator entrypoint.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const CONFIG_API = "firstmate.extension.config/v1";
const MANIFEST_API = "firstmate.extension/v1";
const GENERATED_API = "firstmate.extension.generated/v1";
const HOST_FIRSTMATE_VERSION = "0.0.0";
const ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,62}$/;
const VERSION_PATTERN = /^[0-9]+[.][0-9]+[.][0-9]+(?:[-+][0-9A-Za-z.-]+)?$/;
const HASH_PATTERN = /^[0-9a-f]{64}$/;
const KNOWN_CAPABILITIES = new Set([
  "no_mistakes.repo_command",
  "no_mistakes.wrapper",
  "no_mistakes.axi_observe",
]);
const KNOWN_REPO_COMMANDS = new Set(["lint", "test", "format"]);
const READ_ONLY_AXI = new Set(["status", "logs"]);
const GENERATED_MARKER = "# firstmate-extension-generated firstmate.extension.generated/v1";

function usage() {
  process.stdout.write(`fm-extension.sh usage is documented in bin/fm-extension.sh.
Run:
  bin/fm-extension.sh --help
`);
}

function fail(message, code = 1) {
  const error = new Error(message);
  error.exitCode = code;
  throw error;
}

function parseGlobal(argv) {
  const opts = {
    fmRoot: "",
    home: process.env.FM_HOME || "",
    config: "",
    noMistakesBin: process.env.NO_MISTAKES_BIN || "no-mistakes",
  };
  const rest = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--fm-root" || arg === "--home" || arg === "--config" || arg === "--no-mistakes-bin") {
      if (i + 1 >= argv.length) fail(`${arg} requires a value`, 2);
      const value = argv[i + 1];
      if (arg === "--fm-root") opts.fmRoot = value;
      if (arg === "--home") opts.home = value;
      if (arg === "--config") opts.config = value;
      if (arg === "--no-mistakes-bin") opts.noMistakesBin = value;
      i += 1;
      continue;
    }
    if (arg === "-h" || arg === "--help") {
      opts.help = true;
      continue;
    }
    rest.push(...argv.slice(i));
    break;
  }
  if (!opts.fmRoot) {
    opts.fmRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
  }
  opts.fmRoot = path.resolve(opts.fmRoot);
  if (opts.home) opts.home = path.resolve(opts.home);
  if (opts.config) opts.config = path.resolve(opts.config);
  return { opts, rest };
}

function readJson(file, label) {
  let raw;
  try {
    raw = fs.readFileSync(file, "utf8");
  } catch (error) {
    fail(`${label} is not readable: ${file}: ${error.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    fail(`${label} is malformed JSON: ${file}: ${error.message}`);
  }
}

function sha256File(file) {
  const hash = crypto.createHash("sha256");
  hash.update(fs.readFileSync(file));
  return hash.digest("hex");
}

function lstatSafe(file, label) {
  try {
    return fs.lstatSync(file);
  } catch (error) {
    fail(`${label} does not exist: ${file}`);
  }
}

function assertNoSymlinkPathAncestry(target, label) {
  const resolved = path.resolve(target);
  const root = path.parse(resolved).root;
  const parts = path.relative(root, resolved).split(path.sep).filter(Boolean);
  let current = root;
  for (const part of parts) {
    current = path.join(current, part);
    let st;
    try {
      st = fs.lstatSync(current);
    } catch (error) {
      if (error && error.code === "ENOENT") return false;
      throw error;
    }
    if (st.isSymbolicLink()) fail(`${label} path must not contain a symlink: ${current}`);
  }
  return true;
}

function assertSafeRegularFile(file, label, options = {}) {
  const st = lstatSafe(file, label);
  if (st.isSymbolicLink()) fail(`${label} must not be a symlink: ${file}`);
  if (!st.isFile()) fail(`${label} must be a regular file: ${file}`);
  if ((st.mode & 0o022) !== 0) fail(`${label} must not be group- or world-writable: ${file}`);
  if (options.executable && (st.mode & 0o100) === 0) {
    fail(`${label} must be owner-executable: ${file}`);
  }
  return st;
}

function assertSafeDirectory(dir, label) {
  const st = lstatSafe(dir, label);
  if (st.isSymbolicLink()) fail(`${label} must not be a symlink: ${dir}`);
  if (!st.isDirectory()) fail(`${label} must be a directory: ${dir}`);
  if ((st.mode & 0o022) !== 0) fail(`${label} must not be group- or world-writable: ${dir}`);
  return st;
}

function hasScheme(value) {
  return /^[A-Za-z][A-Za-z0-9+.-]*:/.test(value);
}

function isInside(parent, child) {
  const relative = path.relative(parent, child);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function resolveStrictChild(base, rel, label) {
  if (typeof rel !== "string" || rel.length === 0) fail(`${label} path must be a non-empty string`);
  if (rel.includes("\0")) fail(`${label} path contains a NUL byte`);
  if (hasScheme(rel)) fail(`${label} path must be local, not a URL or scheme path: ${rel}`);
  if (path.isAbsolute(rel)) fail(`${label} path must be relative to the extension source root: ${rel}`);
  const resolved = path.resolve(base, rel);
  if (!isInside(base, resolved)) fail(`${label} path escapes the extension source root: ${rel}`);
  return resolved;
}

function validateId(value, label) {
  if (typeof value !== "string" || !ID_PATTERN.test(value)) {
    fail(`${label} must match ${ID_PATTERN}`);
  }
}

function validateVersion(value, label) {
  if (typeof value !== "string" || !VERSION_PATTERN.test(value)) {
    fail(`${label} must be a semver-like version`);
  }
}

function validateHash(value, label) {
  if (typeof value !== "string" || !HASH_PATTERN.test(value)) {
    fail(`${label} must be a lowercase 64-hex SHA-256`);
  }
}

function ensureObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${label} must be an object`);
  return value;
}

function ensureStringArray(value, label) {
  if (!Array.isArray(value)) fail(`${label} must be an array`);
  for (const item of value) {
    if (typeof item !== "string" || item.length === 0) fail(`${label} must contain non-empty strings`);
  }
  return value;
}

function normalizeCapabilities(value, label) {
  if (typeof value === "string") return [value];
  return ensureStringArray(value, label);
}

function parseVersion(value) {
  const match = String(value).match(/v?([0-9]+)[.]([0-9]+)[.]([0-9]+)/);
  if (!match) return null;
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

function parseFloorRequirement(value, label) {
  if (typeof value !== "string") fail(`${label} must be a string`);
  const match = value.match(/^>=\s*v?([0-9]+)[.]([0-9]+)[.]([0-9]+)(?:[-+][0-9A-Za-z.-]+)?$/);
  if (!match) fail(`${label} supports only >= semver floors`);
  return [Number(match[1]), Number(match[2]), Number(match[3])];
}

function versionAtLeast(actual, floor) {
  for (let i = 0; i < 3; i += 1) {
    if (actual[i] > floor[i]) return true;
    if (actual[i] < floor[i]) return false;
  }
  return true;
}

function currentNoMistakesVersion(noMistakesBin, env) {
  const result = spawnSync(noMistakesBin, ["--version"], {
    encoding: "utf8",
    env: {
      ...process.env,
      ...env,
      NO_MISTAKES_NO_UPDATE_CHECK: "1",
    },
  });
  if (result.error) fail(`no-mistakes version check failed: ${result.error.message}`);
  if (result.status !== 0) {
    fail(`no-mistakes --version exited ${result.status}: ${(result.stderr || result.stdout || "").trim()}`);
  }
  const parsed = parseVersion(result.stdout) || parseVersion(`${result.stdout}\n${result.stderr}`);
  if (!parsed) fail(`no-mistakes --version did not contain a parseable semver: ${result.stdout.trim()}`);
  return { raw: result.stdout.trim(), parsed };
}

function discoverConfig(opts, id) {
  if (opts.config) return opts.config;
  if (!opts.home) fail("FM_HOME is required; pass --home or set FM_HOME", 2);
  const dir = path.join(opts.home, "config", "extensions.d");
  if (id) return path.join(dir, `${id}.json`);
  let entries = [];
  try {
    entries = fs.readdirSync(dir).filter((name) => name.endsWith(".json")).sort();
  } catch {
    fail(`no extension config directory found: ${dir}`);
  }
  if (entries.length !== 1) {
    fail(`expected exactly one extension config in ${dir}, found ${entries.length}`, 2);
  }
  return path.join(dir, entries[0]);
}

function validateConfig(configPath, requestedId) {
  assertSafeRegularFile(configPath, "extension config");
  const config = ensureObject(readJson(configPath, "extension config"), "extension config");
  if (config.api_version !== CONFIG_API) fail(`extension config api_version must be ${CONFIG_API}`);
  validateId(config.id, "extension config id");
  if (requestedId && config.id !== requestedId) fail(`requested extension id ${requestedId} does not match config id ${config.id}`);
  if (typeof config.manifest_path !== "string" || !path.isAbsolute(config.manifest_path)) {
    fail("extension config manifest_path must be an absolute local path");
  }
  if (hasScheme(config.manifest_path)) fail("extension config manifest_path must not use a URL or scheme");
  validateHash(config.manifest_sha256, "extension config manifest_sha256");
  return {
    id: config.id,
    configPath,
    manifestPath: path.resolve(config.manifest_path),
    manifestSha256: config.manifest_sha256,
  };
}

function validatePermissions(permissions) {
  if (permissions === undefined) return;
  const value = ensureObject(permissions, "manifest permissions");
  const allowed = new Set(["network", "read", "write"]);
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) fail(`manifest permissions contains unknown key: ${key}`);
  }
  if (value.network !== undefined && value.network !== false) {
    fail("manifest permissions.network must be false in Stage 0");
  }
  for (const key of ["read", "write"]) {
    if (value[key] === undefined) continue;
    const grants = ensureStringArray(value[key], `manifest permissions.${key}`);
    if (grants.length > 0) fail(`manifest permissions.${key} must be empty in Stage 0`);
  }
}

function validateSource(manifestPath, manifest) {
  const source = ensureObject(manifest.source, "manifest source");
  if (source.type !== "local_path") fail("manifest source.type must be local_path");
  if (typeof source.path !== "string" || source.path.length === 0) fail("manifest source.path must be a non-empty string");
  if (source.path.includes("\0")) fail("manifest source.path contains a NUL byte");
  if (hasScheme(source.path)) fail("manifest source.path must be a local path");

  const manifestDir = path.dirname(manifestPath);
  const resolved = path.resolve(manifestDir, source.path);
  const manifestDirReal = fs.realpathSync(manifestDir);
  const sourceReal = fs.realpathSync(resolved);
  if (!isInside(manifestDirReal, sourceReal)) {
    fail(`manifest source.path escapes the manifest directory: ${source.path}`);
  }
  assertSafeDirectory(resolved, "extension source root");
  return { sourceRoot: resolved, sourceRootReal: sourceReal };
}

function validateRequires(manifest, noMistakesBin, env) {
  const requires = manifest.requires === undefined ? {} : ensureObject(manifest.requires, "manifest requires");
  const known = new Set(["firstmate", "no_mistakes"]);
  for (const key of Object.keys(requires)) {
    if (!known.has(key)) fail(`manifest requires contains unknown key: ${key}`);
  }
  if (requires.firstmate !== undefined) {
    const floor = parseFloorRequirement(requires.firstmate, "manifest requires.firstmate");
    const actual = parseVersion(HOST_FIRSTMATE_VERSION);
    if (!versionAtLeast(actual, floor)) {
      fail(`firstmate ${HOST_FIRSTMATE_VERSION} does not satisfy ${requires.firstmate}`);
    }
  }
  let noMistakes = null;
  if (requires.no_mistakes !== undefined) {
    const floor = parseFloorRequirement(requires.no_mistakes, "manifest requires.no_mistakes");
    noMistakes = currentNoMistakesVersion(noMistakesBin, env);
    if (!versionAtLeast(noMistakes.parsed, floor)) {
      fail(`no-mistakes ${noMistakes.raw} does not satisfy ${requires.no_mistakes}`);
    }
  }
  return { requires, noMistakes };
}

function validateExtension(opts, requestedId = "") {
  if (!opts.home) fail("FM_HOME is required; pass --home or set FM_HOME", 2);
  const configPath = discoverConfig(opts, requestedId);
  const config = validateConfig(configPath, requestedId);

  assertSafeRegularFile(config.manifestPath, "extension manifest");
  const actualManifestHash = sha256File(config.manifestPath);
  if (actualManifestHash !== config.manifestSha256) {
    fail(`extension manifest hash mismatch: expected ${config.manifestSha256}, got ${actualManifestHash}`);
  }

  const manifest = ensureObject(readJson(config.manifestPath, "extension manifest"), "extension manifest");
  if (manifest.api_version !== MANIFEST_API) fail(`extension manifest api_version must be ${MANIFEST_API}`);
  validateId(manifest.id, "manifest id");
  if (manifest.id !== config.id) fail(`manifest id ${manifest.id} does not match config id ${config.id}`);
  validateVersion(manifest.version, "manifest version");
  validatePermissions(manifest.permissions);

  const { sourceRoot, sourceRootReal } = validateSource(config.manifestPath, manifest);
  const manifestCapabilities = new Set(normalizeCapabilities(manifest.capabilities, "manifest capabilities"));
  if (manifestCapabilities.size === 0) fail("manifest capabilities must not be empty");
  for (const capability of manifestCapabilities) {
    if (!KNOWN_CAPABILITIES.has(capability)) fail(`manifest capability is unknown: ${capability}`);
  }

  const versionEnv = {};
  if (process.env.NM_HOME) versionEnv.NM_HOME = process.env.NM_HOME;
  const needsNoMistakes = Array.from(manifestCapabilities).some((capability) => capability.startsWith("no_mistakes."));
  const { noMistakes } = validateRequires(
    {
      ...manifest,
      requires: needsNoMistakes
        ? { no_mistakes: ">=0.0.0", ...(manifest.requires || {}) }
        : manifest.requires,
    },
    opts.noMistakesBin,
    versionEnv,
  );

  const rawEntrypoints = ensureObject(manifest.entrypoints, "manifest entrypoints");
  const entrypoints = {};
  for (const [name, entrypoint] of Object.entries(rawEntrypoints)) {
    validateId(name, `entrypoint name ${name}`);
    const value = ensureObject(entrypoint, `entrypoint ${name}`);
    const entryPath = resolveStrictChild(sourceRoot, value.path, `entrypoint ${name}`);
    assertSafeRegularFile(entryPath, `entrypoint ${name}`, { executable: true });
    const entryReal = fs.realpathSync(entryPath);
    if (!isInside(sourceRootReal, entryReal)) {
      fail(`entrypoint ${name} resolves outside the extension source root`);
    }
    validateHash(value.sha256, `entrypoint ${name} sha256`);
    const actualEntryHash = sha256File(entryPath);
    if (actualEntryHash !== value.sha256) {
      fail(`entrypoint ${name} hash mismatch: expected ${value.sha256}, got ${actualEntryHash}`);
    }
    const entryCapabilities = new Set(normalizeCapabilities(value.capabilities ?? value.capability, `entrypoint ${name} capabilities`));
    if (entryCapabilities.size === 0) fail(`entrypoint ${name} capabilities must not be empty`);
    for (const capability of entryCapabilities) {
      if (!KNOWN_CAPABILITIES.has(capability)) fail(`entrypoint ${name} capability is unknown: ${capability}`);
      if (!manifestCapabilities.has(capability)) fail(`entrypoint ${name} capability is not granted by manifest: ${capability}`);
    }
    let repoCommand = "";
    if (entryCapabilities.has("no_mistakes.repo_command")) {
      if (typeof value.no_mistakes_command !== "string" || !KNOWN_REPO_COMMANDS.has(value.no_mistakes_command)) {
        fail(`entrypoint ${name} no_mistakes_command must be lint, test, or format`);
      }
      repoCommand = value.no_mistakes_command;
    }
    entrypoints[name] = {
      name,
      path: entryPath,
      sha256: value.sha256,
      capabilities: Array.from(entryCapabilities).sort(),
      noMistakesCommand: repoCommand,
    };
  }
  if (Object.keys(entrypoints).length === 0) fail("manifest entrypoints must not be empty");

  return {
    id: manifest.id,
    version: manifest.version,
    fmRoot: opts.fmRoot,
    home: opts.home,
    configPath,
    manifestPath: config.manifestPath,
    manifestSha256: config.manifestSha256,
    sourceRoot,
    capabilities: Array.from(manifestCapabilities).sort(),
    entrypoints,
    noMistakesBin: opts.noMistakesBin,
    noMistakesVersion: noMistakes ? noMistakes.raw : "",
  };
}

function stateDirFor(validated) {
  return path.join(validated.home, "state", "extensions", validated.id);
}

function generatedDirFor(validated) {
  return path.join(stateDirFor(validated), "generated");
}

function generatedWrapperPath(validated, entrypointName) {
  return path.join(generatedDirFor(validated), "wrappers", entrypointName);
}

function ensureCreatedDirectory(dir, mode = 0o700) {
  assertNoSymlinkPathAncestry(dir, "generated directory");
  const existed = fs.existsSync(dir);
  fs.mkdirSync(dir, { recursive: true, mode });
  const st = lstatSafe(dir, "generated directory");
  if (st.isSymbolicLink()) fail(`generated directory must not be a symlink: ${dir}`);
  if (!st.isDirectory()) fail(`generated directory must be a directory: ${dir}`);
  if ((st.mode & 0o022) !== 0) fail(`generated directory must not be group- or world-writable: ${dir}`);
  if (!existed) fs.chmodSync(dir, mode);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

function writeGeneratedFile(file, content, validated) {
  if (fs.existsSync(file)) {
    const st = fs.lstatSync(file);
    if (st.isSymbolicLink() || !st.isFile()) {
      fail(`refusing to overwrite unsafe generated path: ${file}`);
    }
    const current = fs.readFileSync(file, "utf8");
    if (!current.includes(GENERATED_MARKER)) {
      fail(`refusing to overwrite unowned generated path: ${file}`);
    }
  }
  const dir = path.dirname(file);
  ensureOwnedGeneratedDirectory(dir, validated);
  const tmp = path.join(dir, `.tmp.${process.pid}.${Date.now()}`);
  fs.writeFileSync(tmp, content, { mode: 0o700 });
  fs.renameSync(tmp, file);
  fs.chmodSync(file, 0o700);
}

function ownerJson(validated) {
  return `${JSON.stringify(
    {
      api_version: GENERATED_API,
      id: validated.id,
      version: validated.version,
      manifest_path: validated.manifestPath,
      manifest_sha256: validated.manifestSha256,
      generated_by: "bin/fm-extension.sh",
    },
    null,
    2,
  )}\n`;
}

function writeOwnerMarker(file, validated) {
  if (fs.existsSync(file)) {
    const st = fs.lstatSync(file);
    if (st.isSymbolicLink() || !st.isFile()) {
      fail(`refusing to overwrite unsafe generated owner marker: ${file}`);
    }
    if (!isOwnedGeneratedFile(file, validated.id)) {
      fail(`refusing to overwrite unowned generated owner marker: ${file}`);
    }
  }
  const dir = path.dirname(file);
  ensureCreatedDirectory(dir);
  const tmp = path.join(dir, `.tmp-owner.${process.pid}.${Date.now()}`);
  fs.writeFileSync(tmp, ownerJson(validated), { mode: 0o600 });
  fs.renameSync(tmp, file);
  fs.chmodSync(file, 0o600);
}

function ensureOwnedGeneratedDirectory(dir, validated) {
  ensureCreatedDirectory(dir);
  writeOwnerMarker(path.join(dir, ".owner.json"), validated);
}

function commandActivate(opts, id) {
  const validated = validateExtension(opts, id);
  const generatedDir = generatedDirFor(validated);
  const wrappersDir = path.join(generatedDir, "wrappers");
  ensureOwnedGeneratedDirectory(generatedDir, validated);
  ensureOwnedGeneratedDirectory(wrappersDir, validated);
  for (const entrypoint of Object.values(validated.entrypoints)) {
    const wrapper = `#!/usr/bin/env bash
${GENERATED_MARKER} id=${validated.id} entrypoint=${entrypoint.name}
set -u
exec ${shellQuote(path.join(validated.fmRoot, "bin", "fm-extension.sh"))} --home ${shellQuote(validated.home)} --config ${shellQuote(validated.configPath)} --no-mistakes-bin ${shellQuote(validated.noMistakesBin)} run ${shellQuote(validated.id)} ${shellQuote(entrypoint.name)} -- "$@"
`;
    writeGeneratedFile(generatedWrapperPath(validated, entrypoint.name), wrapper, validated);
  }
  process.stdout.write(`fm-extension: activated ${validated.id} generated=${generatedDir}\n`);
}

function isOwnedGeneratedFile(file, id) {
  const name = path.basename(file);
  if (name === ".owner.json") {
    try {
      const value = readJson(file, "generated owner marker");
      return value.api_version === GENERATED_API && value.id === id;
    } catch {
      return false;
    }
  }
  try {
    const st = fs.lstatSync(file);
    if (!st.isFile() || st.isSymbolicLink()) return false;
    const fd = fs.openSync(file, "r");
    const buffer = Buffer.alloc(512);
    const bytes = fs.readSync(fd, buffer, 0, buffer.length, 0);
    fs.closeSync(fd);
    const head = buffer.subarray(0, bytes).toString("utf8");
    return head.includes(`${GENERATED_MARKER} id=${id} `);
  } catch {
    return false;
  }
}

function isOwnedGeneratedDirectory(dir, id) {
  try {
    const st = fs.lstatSync(dir);
    if (!st.isDirectory() || st.isSymbolicLink()) return false;
    return isOwnedGeneratedFile(path.join(dir, ".owner.json"), id);
  } catch {
    return false;
  }
}

function walkFiles(root) {
  const files = [];
  const dirs = [];
  if (!fs.existsSync(root)) return { files, dirs };
  const visit = (dir) => {
    dirs.push(dir);
    for (const name of fs.readdirSync(dir)) {
      const file = path.join(dir, name);
      const st = fs.lstatSync(file);
      if (st.isDirectory() && !st.isSymbolicLink()) {
        visit(file);
      } else {
        files.push(file);
      }
    }
  };
  visit(root);
  return { files, dirs };
}

function commandDeactivate(opts, id) {
  if (!id) fail("deactivate requires an extension id", 2);
  if (!opts.home) fail("FM_HOME is required; pass --home or set FM_HOME", 2);
  validateId(id, "extension id");
  const generatedDir = path.join(opts.home, "state", "extensions", id, "generated");
  if (!assertNoSymlinkPathAncestry(generatedDir, "generated directory")) {
    process.stdout.write(`fm-extension: no generated material for ${id}\n`);
    return;
  }
  const rootStat = lstatSafe(generatedDir, "generated directory");
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) fail(`generated path is not a safe directory: ${generatedDir}`);
  const { files, dirs } = walkFiles(generatedDir);
  const ownedDirs = dirs.filter((dir) => isInside(generatedDir, dir) && isOwnedGeneratedDirectory(dir, id));
  const ownedDirSet = new Set(ownedDirs);
  let removed = 0;
  let left = 0;
  for (const file of files) {
    if (path.basename(file) === ".owner.json" && ownedDirSet.has(path.dirname(file))) {
      continue;
    }
    if (isOwnedGeneratedFile(file, id)) {
      fs.unlinkSync(file);
      removed += 1;
    } else {
      left += 1;
    }
  }
  for (const dir of dirs) {
    if (!ownedDirs.includes(dir)) left += 1;
  }
  ownedDirs.sort((a, b) => b.length - a.length);
  for (const dir of ownedDirs) {
    try {
      const marker = path.join(dir, ".owner.json");
      const entries = fs.readdirSync(dir).filter((name) => name !== ".owner.json");
      if (entries.length > 0 || !isOwnedGeneratedFile(marker, id)) continue;
      fs.unlinkSync(marker);
      removed += 1;
      fs.rmdirSync(dir);
    } catch {
    }
  }
  process.stdout.write(`fm-extension: deactivated ${id} removed=${removed} left_unowned=${left}\n`);
}

function runSpawn(command, args, env) {
  const result = spawnSync(command, args, {
    stdio: "inherit",
    env,
  });
  if (result.error) {
    process.stderr.write(`fm-extension: failed to execute ${command}: ${result.error.message}\n`);
    return 127;
  }
  if (result.signal) {
    process.stderr.write(`fm-extension: ${command} terminated by ${result.signal}\n`);
    return 128;
  }
  return result.status ?? 1;
}

function commandRun(opts, rest) {
  const id = rest[0];
  const entrypointName = rest[1];
  if (!id || !entrypointName) fail("run requires <id> <entrypoint>", 2);
  validateId(id, "extension id");
  validateId(entrypointName, "entrypoint name");
  let args = rest.slice(2);
  if (args[0] === "--") args = args.slice(1);
  const validated = validateExtension(opts, id);
  const entrypoint = validated.entrypoints[entrypointName];
  if (!entrypoint) fail(`unknown entrypoint for ${id}: ${entrypointName}`, 2);
  const env = {
    ...process.env,
    FM_EXTENSION_ID: validated.id,
    FM_EXTENSION_VERSION: validated.version,
    FM_EXTENSION_ENTRYPOINT: entrypoint.name,
    FM_EXTENSION_ROOT: validated.sourceRoot,
    FM_EXTENSION_MANIFEST: validated.manifestPath,
    FM_EXTENSION_MANIFEST_SHA256: validated.manifestSha256,
    FM_EXTENSION_GENERATED_DIR: generatedDirFor(validated),
    FM_EXTENSION_NETWORK: "0",
    FM_EXTENSION_READ_ROOTS: "",
    FM_EXTENSION_WRITE_ROOTS: "",
    FM_HOME: validated.home,
    FM_ROOT: validated.fmRoot,
    NO_MISTAKES_BIN: validated.noMistakesBin,
    NO_MISTAKES_VERSION: validated.noMistakesVersion,
    NO_MISTAKES_NO_UPDATE_CHECK: "1",
  };
  process.exitCode = runSpawn(entrypoint.path, args, env);
}

function commandDoctor(opts, id) {
  const validated = validateExtension(opts, id);
  process.stdout.write(
    `fm-extension: ok ${validated.id} ${validated.version} manifest=${validated.manifestPath} capabilities=${validated.capabilities.join(",")}\n`,
  );
}

function yamlSingleQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function commandRenderNoMistakes(opts, id) {
  const validated = validateExtension(opts, id);
  const commands = [];
  for (const entrypoint of Object.values(validated.entrypoints)) {
    if (!entrypoint.capabilities.includes("no_mistakes.repo_command")) continue;
    commands.push([entrypoint.noMistakesCommand, generatedWrapperPath(validated, entrypoint.name)]);
  }
  if (commands.length === 0) fail(`extension ${validated.id} has no no_mistakes.repo_command entrypoints`);
  process.stdout.write("commands:\n");
  for (const [name, wrapper] of commands) {
    process.stdout.write(`  ${name}: ${yamlSingleQuote(wrapper)}\n`);
  }
}

function commandObserveNoMistakes(opts, rest) {
  const id = rest[0];
  const action = rest[1];
  if (!id || !action) fail("observe-no-mistakes requires <id> <status|logs>", 2);
  validateId(id, "extension id");
  if (!READ_ONLY_AXI.has(action)) {
    fail(`observe-no-mistakes only permits read-only AXI actions: ${Array.from(READ_ONLY_AXI).join(", ")}`, 2);
  }
  let args = rest.slice(2);
  if (args[0] === "--") args = args.slice(1);
  const validated = validateExtension(opts, id);
  if (!validated.capabilities.includes("no_mistakes.axi_observe")) {
    fail(`extension ${validated.id} is not granted no_mistakes.axi_observe`);
  }
  const env = {
    ...process.env,
    FM_EXTENSION_ID: validated.id,
    FM_EXTENSION_VERSION: validated.version,
    FM_HOME: validated.home,
    FM_ROOT: validated.fmRoot,
    NO_MISTAKES_NO_UPDATE_CHECK: "1",
  };
  process.exitCode = runSpawn(validated.noMistakesBin, ["axi", action, ...args], env);
}

function main() {
  const { opts, rest } = parseGlobal(process.argv.slice(2));
  if (opts.help || rest.length === 0) {
    usage();
    return;
  }
  const command = rest[0];
  const args = rest.slice(1);
  if (command === "doctor") commandDoctor(opts, args[0] || "");
  else if (command === "activate") commandActivate(opts, args[0] || "");
  else if (command === "deactivate") commandDeactivate(opts, args[0] || "");
  else if (command === "run") commandRun(opts, args);
  else if (command === "render-no-mistakes") commandRenderNoMistakes(opts, args[0] || "");
  else if (command === "observe-no-mistakes") commandObserveNoMistakes(opts, args);
  else fail(`unknown command: ${command}`, 2);
}

try {
  main();
} catch (error) {
  process.stderr.write(`fm-extension: ${error.message}\n`);
  process.exitCode = error.exitCode || 1;
}
