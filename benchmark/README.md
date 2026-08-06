# Single-query Claude Code benchmark

`singe-query-bench-claude.sh` (macOS/Linux) and `singe-query-bench-claude.ps1` (Windows)
measure the **cost and latency of one query in the interactive Claude Code TUI, with vs.
without JetBrains Context**, in the **warm** steady state a real ongoing session experiences.

## What it does

For each of the two legs — **with** JetBrains Context and **without** — the script:

1. Runs a throwaway **warm-up** TUI session (you type `hi`, `/exit`) that writes Claude Code's
   tools + system prompt prefix into the server-side prompt cache.
2. Runs the **measured** TUI session (you paste the query, do **one** turn, `/exit`), which
   reads that prefix **warm**.

Because the measured session is separate and single-turn, its official cost is the warm cost
of just that query. Both legs are warmed the same way, so the comparison is apples-to-apples.

Metrics are read straight from Claude Code's own records — **no manual pricing**:

- `Cost` / `Wall` / `API` — `lastCost` / `lastDuration` / `lastAPIDuration` from `~/.claude.json`.
- `WarmRead` — `cache_read` on the measured session's first call (from the session transcript).
  `>0` confirms the warm-up worked; `0` means the leg ran cold — re-run it.

Prompt caching is enabled for the run and the original environment is restored on exit.

## Prerequisites

- `claude` (Claude Code CLI) and `jbcontext` on `PATH`.
- **`.sh`**: `bash` + `python3` (reads `~/.claude.json`), and a clipboard tool
  (`pbcopy` / `wl-copy` / `xclip` / `xsel`).
- **`.ps1`**: Windows PowerShell 5.1 or PowerShell 7+.

## Repository & query recommendations

The benchmark is most meaningful when JetBrains Context has real work to do, so context
retrieval measurably changes the answer's cost and quality.

- **Repo size:** prefer a **medium or large codebase — at least ~50K LOC**. On tiny repos the model can
  hold everything in context and JetBrains Context adds little, so the with/without difference
  is noise.
- **Pre-index first:** index the repo before benchmarking so semantic search is warm and the
  results are stable:

  ```bash
  jbcontext index          # run in the repo root; check index availability with: jbcontext status
  ```

- **Query type:** use **semantic "how is X implemented?" questions** — where the answer lives
  in code you'd normally have to hunt for, not something answerable from a file name. For an
  e-commerce project, for example:

  > how is order total amount calculation implemented?

  These exercise semantic retrieval; keyword-trivial or purely conversational prompts won't
  show a representative difference.

## Usage

```bash
# macOS / Linux
./singe-query-bench-claude.sh [--model <id>] ["your query"]
```

```powershell
# Windows
./singe-query-bench-claude.ps1 [-Model <id>] [-Prompt "your query"]
```

- Default model is `claude-opus-4-8`. If the query is omitted, you're prompted for it.
- Follow the on-screen steps. Before each Claude launch the script pauses for a keypress so
  you can read the instructions; the TUI then takes over the terminal.
- **In the measured session, do exactly ONE turn** (paste query → wait → `/exit`), or the
  reported cost will include the extra turns.

## Example output

```
==== Summary (warm query turn, official cost) ====
Run                                    Cost USD      Wall       API   WarmRead
Run Claude with JetBrains Context        0.0421     00:34     00:22      24118
Run Claude without JetBrains Context     0.0298     00:25     00:15      24051
```

## Notes

- Two warm-ups (one per leg) are required: `jbcontext setup-agent` adds MCP tools and
  instructions, so the two legs have different cached prefixes and each must be warmed
  under its own configuration.
- The legs are isolated by a unique per-run marker (`--append-system-prompt`), so no waiting
  for cache TTL expiry is needed.
