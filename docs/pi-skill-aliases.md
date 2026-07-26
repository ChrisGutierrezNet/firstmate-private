# Pi skill aliases

This page owns the maintainer contract for Firstmate's Pi-only bare aliases for user-invocable Firstmate skills.
Public current behavior is summarized in the README, and active evidence is recorded in [`docs/verification/supervision.md`](verification/supervision.md#pi-skill-aliases).

## Scope

The tracked extension is [`.pi/extensions/fm-primary-skill-aliases.ts`](../.pi/extensions/fm-primary-skill-aliases.ts).
It registers exactly these Pi extension commands:

- `/ahoy` for `/skill:ahoy`.
- `/bearings` for `/skill:bearings`.
- `/afk` for `/skill:afk`.
- `/stow` for `/skill:stow`.
- `/updatefirstmate` for `/skill:updatefirstmate`.

Pi's native `/skill:<name>` commands remain enabled and discoverable.
The alias layer does not add prompt templates, does not duplicate skill bodies into tracked prose, does not edit installed Pi files, and does not change global Pi configuration.

## Dispatch

Pi checks extension commands before `input` handlers and before native `/skill:<name>` expansion.
Pi's public extension command API does not expose a supported recursive prompt-expansion call, and `pi.sendUserMessage()` deliberately sends extension-originated messages with command and template expansion disabled.
The alias handler therefore uses Pi's supported extension command path for discovery and dispatch, then mirrors the installed Pi skill expansion shape from Pi's loaded skill metadata.

For each invocation, the handler first requires `pi.getCommands()` to contain the matching `skill:<name>` command with source `skill`.
It also requires `ctx.getSystemPromptOptions().skills` to contain the loaded skill metadata for that name.
It reads the current loaded `SKILL.md`, strips frontmatter with Pi's exported `stripFrontmatter`, builds Pi's installed `<skill name="..." location="...">` block shape, and appends the handler argument string exactly as received.
When Pi is idle, the extension sends that expanded user message once with no delivery option.
When Pi is busy, it sends the same expanded user message once with `{ deliverAs: "steer" }`.

The sent message starts with a skill XML block, not a slash command.
That prevents recursive alias handling, duplicate command delivery, and slash-command injection from arguments that themselves begin with `/`.
Ahoy's Bearings fallback, AFK enter and return boundaries, Stow's knowledge routing, and Updatefirstmate's authority limits remain owned by the corresponding `.agents/skills/*/SKILL.md` bodies because the extension reads those bodies at dispatch time.

## Collisions

Firstmate treats the unsuffixed base command name as the collision key, so `ahoy` and `ahoy:1` collide.
At dispatch time the alias refuses if `pi.getCommands()` reports any same-base command not owned by this exact extension file.
The refusal sends a Pi UI error and points the operator at the native `/skill:<name>` command.

If Pi detects duplicate extension command names, it assigns numeric invocation suffixes in load order.
Any suffixed same-base command still counts as a collision, so Firstmate refuses instead of treating `/ahoy:1` or `/ahoy:2` as a safe alias.
If a same-base prompt or skill command exists, Firstmate refuses the bare alias rather than silently overriding that command.

## Other Harnesses

This implementation is Pi-only because the missing behavior is specific to Pi's command registry.
Claude already exposes the shared Firstmate skills through `.claude/skills -> .agents/skills` and uses slash skill invocation.
Grok uses the same slash form for user-level skills, while its tracked project hooks are supervision hooks rather than skill aliases.
Codex uses `$<skill>` for skill invocation, and slash skill syntax is intentionally not accepted there.
OpenCode has no separate verified Firstmate bare-alias gap beyond its normal prompt and command behavior.
Kimi uses slash skill invocation for crew instructions and has only the separate guarded global turn-end hook path.
Runtime backends such as tmux, Herdr, Zellij, Orca, and cmux transport harness input and do not own skill command syntax.

## Verification

`tests/fm-pi-skill-aliases.test.sh` is the focused regression suite for this mechanism.
It covers static extension scope, deterministic handler dispatch and argument preservation, collision refusal, missing native command refusal, Pi RPC command discovery for aliases and native skill commands, and a real Pi RPC provider-context proof that bare `/ahoy` reaches skill-expanded context once.
`tests/fm-pi-primary-types.test.sh` includes the alias extension in the tracked Pi extension typecheck when a local TypeScript compiler is available.
