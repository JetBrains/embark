---
name: context-search
description: "Explore and understand unfamiliar codebases using semantic code search"
argument-hint: query
allowed-tools: [read, grep, glob, exec, mcp__jbcontext__code_search]
triggers: [user, model]
---

# Semantic Code Search

Use `mcp__jbcontext__code_search` (or `jbcontext search` via exec) to find code snippets by meaning, not just keywords.

Use it as a single semantic bootstrap when the relevant file or subsystem is unknown. Do one broad search, open and inspect at least one returned file locally, and inspect nearby code in that same directory or subsystem before any retry. If that still does not identify the needed adjacent area, do a narrowed retry with `pathFilter` set to the directory of the best first hit, or use `jbcontext search -p <path> ...` via exec.

For broader or multi-step exploration (mapping a subsystem, tracing a flow, or when the task describes behavior or intent without naming an exact file or symbol), use `/context-explorer` first instead of repeated inline searches.

## Usage

```bash
jbcontext search "<detailed and descriptive query>"
jbcontext search "<code snippet>" # find similar snippets
jbcontext search -p <path> "<query>"  # <path> must be relative to the project root
```

Alternatively, call the MCP tool:

```text
mcp__jbcontext__code_search
  text: "<detailed and descriptive query>"
  pathFilter: "<relative/path>"  # optional, narrows to a directory
```

## Query Tips

- Be descriptive: "function that validates user email addresses" > "email"
- Include context: "error handling middleware for HTTP requests with logging"
- Specify what you're looking for: "React component that renders a modal dialog"
- Make the first query specific to the issue's named feature, class, method, or behavior when available

## Examples

```text
# Broad search for authentication-related code
mcp__jbcontext__code_search
  text: "user authentication login flow"

# After finding a hit under src/auth, narrow there
mcp__jbcontext__code_search
  text: "JWT token validation"
  pathFilter: "src/auth"
```

```bash
# Fallback using the CLI
jbcontext search "user authentication login flow"
jbcontext search -p src/auth "JWT token validation"
```
