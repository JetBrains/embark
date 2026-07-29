# JetBrains Context

https://www.jetbrains.com/context/

Give agents the codebase knowledge they need.

**This repository is the public home of JetBrains Context — not its source code.** The `jbcontext` CLI is developed in a private JetBrains repository and distributed as a prebuilt binary. What you'll find here:

- **Agent integrations** — skills, subagents, hooks, MCP configuration, and `AGENTS.md` instructions that wire `jbcontext` into coding agents. These *are* fully open.
- **Releases and release notes** — every `jbcontext` release is published under [Releases](https://github.com/JetBrains/context/releases). Treat that page as the CLI changelog; the tags there track CLI versions, not the contents of this repo.

The CLI is a separate download — see [jetbrains.com/context](https://www.jetbrains.com/context/) for installation instructions. Binaries come from `download.jetbrains.com`, and `jbcontext upgrade` updates in place.

### Skills


| Skill | Description |
|---|---|
| `context-search` | `/context-search` — run a semantic code search |
| `context-research` | `/context-research` — deep codebase exploration using `jbcontext search` and `jbcontext history` |
| `context-install` | `/context-install` — install the jbcontext CLI |
| `org-search` | `/org-search` — experimental org-wide semantic search |
| `dependency-search` | `/dependency-search` — org-wide dependency usage and upgrade research |
| `blast-radius` | `/blast-radius` — org-wide impact and consumer analysis |

### Agents

Read-only exploration subagents that run several `jbcontext search` queries in their own context and return `file:line` references with code snippets — useful for more extensive exploration without cluttering the main thread.

| Agent | Description |
|---|---|
| `context-explorer` (Claude) | `agents/claude/context-explorer.md` — Claude subagent, invoked via `Task(subagent_type='context-explorer', ...)`. |
| `context_explorer` (Codex) | `agents/codex/context-explorer.toml` — Codex custom agent (install under `~/.codex/agents/` or `.codex/agents/`). Codex spawns subagents only when asked, so request it directly, e.g. "use `context_explorer` to map the auth flow". |
