# agentictools

Skills live in `skills/<name>/SKILL.md` (the
[Agent Skills](https://agentskills.io) format: YAML frontmatter `name` + `description`,
then markdown instructions) next to any scripts they call. Scripts must work standalone,
so humans can run them too.

| Skill | What it does |
|-------|--------------|
| [`localnet-integration`](skills/localnet-integration/SKILL.md) | Launch a local Sui network with the world deployed; run SDK integration tests |

## Wiring into agents

- **Claude Code** discovers skills from `.claude/skills/`. Each skill is symlinked there:
  `ln -s ../../agentictools/skills/<name> .claude/skills/<name>`, then add a
  `!.claude/skills/<name>` line to `.gitignore`.
- **Other agents** (Cursor, Codex, etc.): point them at `agentictools/skills/` from their
  rules / `AGENTS.md`, or read the `SKILL.md` directly.
