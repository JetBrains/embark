# jbcontext Instructions

A collection of skills, agents, and instructions that integrate [JetBrains Context](https://www.jetbrains.com/) (`jbcontext`) into agents through hooks, MCP, and agent instructions.

This repository provides **tighter Devin CLI integration** than the reference installers for Junie, Claude, or Codex, including fail-open backend health checks, `ENFORCE_SOFT` no-op rewriting, RTK unwrapping, and automatic `pathFilter` injection for the `mcp__jbcontext__code_search` tool.

## Skills

| Skill | Description |
|---|---|
| `context-search` | `/context-search` — focused semantic code search |
| `context-research` | `/context-research` — deep codebase exploration using `jbcontext search` and `jbcontext history` |
| `context-install` | `/context-install` — install the jbcontext CLI |
| `context-review` | `/context-review` — review code changes using semantic search to understand context and impact |
| `org-search` | `/org-search` — experimental org-wide semantic search |
| `dependency-search` | `/dependency-search` — org-wide dependency usage and upgrade research |
| `blast-radius` | `/blast-radius` — org-wide impact and consumer analysis |
| `context-explorer` | `/context-explorer` — read-only exploration subagent (runs as a Devin subagent) |

_Devin uses the `.devin/skills/` versions. After running the installer these skills are also available globally in `~/.config/devin/skills/` (user scope) or copied into `./.devin/skills/` (project scope)._

## Agents

Read-only exploration subagents that run several `jbcontext search` queries in their own context and return `file:line` references with code snippets — useful for extensive exploration without cluttering the main thread.

| Agent | Description |
|---|---|
| `context-explorer` (Claude) | `agents/claude/context-explorer.md` — Claude subagent, invoked via `Task(subagent_type='context-explorer', ...)`. |
| `context_explorer` (Codex) | `agents/codex/context-explorer.toml` — Codex custom agent (install under `~/.codex/agents/` or `.codex/agents/`). |
| `context-explorer` (Devin) | `.devin/skills/context-explorer/SKILL.md` — Devin read-only exploration subagent (`subagent: true`). |

## Devin CLI integration

Devin CLI integration is configured in `.devin/` and uses the same jbcontext primitives through the `jbcontext` MCP server.

### One-command install

```bash
# Project scope (recommended for the current repo)
./scripts/setup-agent-devin.sh --agent=DEVIN --scope=PROJECT --non-interactive

# User scope (global Devin CLI config)
./scripts/setup-agent-devin.sh --agent=DEVIN --scope=USER --non-interactive
```

The installer:

1. Registers the `jbcontext` MCP server (`stdio: jbcontext mcp`) and auto-allows `mcp__jbcontext__*` and `Exec(jbcontext)`.
2. Installs the Node-based hook adapter to `hooks/jbcontext/` (project) or `~/.config/devin/hooks/jbcontext/` (user).
3. Installs all `.devin/skills/` globally or into the project.
4. Injects the full workflow instructions via `SessionStart`, `PostCompaction`, and `UserPromptSubmit` hooks — no `AGENTS.md` is written unless you explicitly pass `--instructions`.
5. Copies MCP tool description files to the hooks directory for documentation and future use.

### What the Devin adapter does

`hooks/jbcontext/jbcontext-devin.js` is a Node adapter that translates Devin tool names and events into the schema expected by the `jbcontext hook` binary, then translates the response back for Devin.

Key behaviors:

- **Bootstrap-first workflow**: `exec rg/grep/find` and `git log/show/blame` are blocked or no-opped before the first successful `jbcontext` semantic search.
- **`ENFORCE_SOFT`**: blocked tools are rewritten to no-ops instead of cancelling the whole Devin cycle, while still nudging the model toward `jbcontext search`.
- **Fail-open backend health**: before suppressing local discovery, the adapter probes whether `jbcontext search` can actually serve the current project. If not, enforcement is relaxed to a tip so the agent is never left without a search path.
- **RTK unwrapping**: commands like `rtk rg ...` are unwrapped to `rg ...` before being judged by jbcontext, so RTK and jbcontext compose cleanly.
- **MCP `pathFilter` injection**: the `mcp__jbcontext__code_search` MCP tool currently returns no results when `pathFilter` is omitted. The adapter injects `pathFilter: "."` for the first broad search and returns `updatedInput` so the call succeeds.
- **`/context-explorer` first**: the `SessionStart` and `/context-search` instructions explicitly recommend delegating broader or multi-step exploration to the `/context-explorer` subagent.
- **Self-test**: run `node hooks/jbcontext/jbcontext-devin.js --self-test` to verify the adapter locally.

### Files

- `.devin/config.json` — MCP server + permissions.
- `.devin/hooks.v1.json` — hook manifest using `hooks/jbcontext/jbcontext-devin.js`.
- `.devin/skills/` — all Devin skills, including `context-explorer` as a subagent.
- `hooks/jbcontext/jbcontext-devin.js` — Node adapter for Devin hooks.
- `hooks/jbcontext/session-start.txt` — workflow instructions injected at `SessionStart` and `PostCompaction`.
- `AGENTS.md` — optional project-level instructions (installed only with `--instructions`).
- `config-examples/devin-config.json` and `config-examples/devin-hooks.v1.json` — standalone reference copies.

## Status and upstream

The native `jbcontext setup-agent` binary does not yet support `--agent=DEVIN`. This repository provides a complete adapter and installer. Upstream contribution tracking and PR text are in `docs/devin-upstream-pr.md` (or the corresponding GitHub issue).
