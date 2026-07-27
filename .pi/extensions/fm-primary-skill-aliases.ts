// Firstmate's Pi-only bare command aliases for user-invocable Firstmate skills.
//
// Pi's native skill command form remains /skill:<name>. This extension registers
// the historical Firstmate bare names as Pi extension commands. Pi's extension
// command API does not re-enter prompt expansion from sendUserMessage(), so the
// handler first verifies that Pi registered the native skill command, then sends
// the same skill block shape built from Pi's loaded skill metadata exactly once.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { stripFrontmatter } from "@earendil-works/pi-coding-agent";
import type {
  ExtensionAPI,
  ExtensionCommandContext,
  ExtensionContext,
  InputEvent,
  SlashCommandInfo,
} from "@earendil-works/pi-coding-agent";

type Alias = {
  alias: string;
  skill: string;
  description: string;
};

type LockOwnership = "owned" | "missing" | "other";

type LoadedSkill = {
  name: string;
  filePath: string;
  baseDir: string;
};

const aliases: Alias[] = [
  {
    alias: "ahoy",
    skill: "ahoy",
    description: "Invoke Firstmate Ahoy through Pi's native /skill:ahoy path.",
  },
  {
    alias: "bearings",
    skill: "bearings",
    description: "Invoke Firstmate Bearings through Pi's native /skill:bearings path.",
  },
  {
    alias: "afk",
    skill: "afk",
    description: "Invoke Firstmate away mode through Pi's native /skill:afk path.",
  },
  {
    alias: "stow",
    skill: "stow",
    description: "Invoke Firstmate Stow through Pi's native /skill:stow path.",
  },
  {
    alias: "updatefirstmate",
    skill: "updatefirstmate",
    description: "Invoke Firstmate self-update through Pi's native /skill:updatefirstmate path.",
  },
];

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.pi-skill-aliases-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

function commandBase(name: string): string {
  return name.replace(/:[0-9]+$/, "");
}

function samePath(a: string | undefined, b: string): boolean {
  if (!a) return false;
  return resolve(a) === resolve(b);
}

function formatCommand(command: SlashCommandInfo): string {
  return `${command.source}:${command.name} (${command.sourceInfo.path})`;
}

function parseAliasInvocation(text: string): Alias | undefined {
  if (!text.startsWith("/")) return undefined;
  const spaceIndex = text.indexOf(" ");
  const commandName = spaceIndex === -1 ? text.slice(1) : text.slice(1, spaceIndex);
  return aliases.find((alias) => alias.alias === commandName);
}

export default function (pi: ExtensionAPI) {
  const isThisExtensionCommand = (command: SlashCommandInfo, alias: string): boolean => (
    command.source === "extension" &&
    commandBase(command.name) === alias &&
    samePath(command.sourceInfo.path, extensionFile)
  );

  const commandCollisions = (alias: string): SlashCommandInfo[] => (
    pi.getCommands()
      .filter((command) => commandBase(command.name) === alias)
      .filter((command) => !isThisExtensionCommand(command, alias))
      .sort((a, b) => formatCommand(a).localeCompare(formatCommand(b)))
  );

  const hasNativeSkillCommand = (skill: string): boolean => (
    pi.getCommands().some((command) => command.name === `skill:${skill}` && command.source === "skill")
  );

  const loadedSkill = (ctx: ExtensionCommandContext, skillName: string): LoadedSkill | undefined => (
    ctx.getSystemPromptOptions().skills?.find((skill) => skill.name === skillName)
  );

  const expandedSkillMessage = (
    skill: LoadedSkill,
    args: string,
  ): string => {
    const content = readFileSync(skill.filePath, "utf-8");
    const body = stripFrontmatter(content).trim();
    const skillBlock = `<skill name="${skill.name}" location="${skill.filePath}">\nReferences are relative to ${skill.baseDir}.\n\n${body}\n</skill>`;
    return args.length > 0 ? `${skillBlock}\n\n${args}` : skillBlock;
  };

  const refuseCollisions = (alias: Alias, ctx: ExtensionContext): boolean => {
    const collisions = commandCollisions(alias.alias);
    if (collisions.length === 0) return false;
    ctx.ui.notify(
      `Firstmate /${alias.alias} refused because another Pi command already owns that name: ${collisions.map(formatCommand).join("; ")}. Use /skill:${alias.skill} for the Firstmate skill.`,
      "error",
    );
    return true;
  };

  for (const alias of aliases) {
    pi.registerCommand(alias.alias, {
      description: alias.description,
      handler: async (args, ctx) => {
        if (refuseCollisions(alias, ctx)) return;

        const skill = loadedSkill(ctx, alias.skill);
        if (!hasNativeSkillCommand(alias.skill) || !skill) {
          ctx.ui.notify(
            `Firstmate /${alias.alias} refused because Pi has not registered /skill:${alias.skill}. Ensure project skills are trusted and enableSkillCommands is true, or invoke the skill after Pi reports it in command discovery.`,
            "error",
          );
          return;
        }

        let message = "";
        try {
          message = expandedSkillMessage(skill, args);
        } catch (error) {
          const detail = error instanceof Error ? error.message : String(error);
          ctx.ui.notify(
            `Firstmate /${alias.alias} could not load /skill:${alias.skill}: ${detail}`,
            "error",
          );
          return;
        }

        if (ctx.isIdle()) {
          pi.sendUserMessage(message);
        } else {
          pi.sendUserMessage(message, { deliverAs: "steer" });
        }
      },
    });
  }

  pi.on("input", (event: InputEvent, ctx: ExtensionContext) => {
    const alias = parseAliasInvocation(event.text);
    if (alias && refuseCollisions(alias, ctx)) {
      return { action: "handled" };
    }
    return { action: "continue" };
  });

  pi.on("session_start", () => {
    markLoaded();
  });
}
