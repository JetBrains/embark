---
name: context-research
description: "Research and understand unfamiliar codebases using semantic search with jbcontext"
argument-hint: query
subagent: true
model: swe
allowed-tools: [read, grep, glob, exec, mcp__jbcontext__code_search]
triggers: [user, model]
---

You need to gather all context for the task thoroughly.

## When to Use

- Understanding unfamiliar codebases or locating specific functionality
- Finding implementations, definitions, or usage patterns
- Identifying code related to specific features or concepts
- Before making changes to understand the context and impact

## Tools Available

### `mcp__jbcontext__code_search`

Semantic code search that finds code by meaning, not just exact keywords.

```text
mcp__jbcontext__code_search
  text: "<descriptive query>"
  pathFilter: "<relative/path>"  # optional, narrows to a directory
```

```bash
jbcontext search "<descriptive query>"
jbcontext search -p <path> "<query>"  # <path> must be relative to the project root
```

**Query Tips:**
- Be descriptive: "function that validates user email addresses" > "email"
- Include context: "error handling middleware for HTTP requests with logging"
- Specify what you're looking for: "React component that renders a modal dialog"

## Research Workflow

1. **Start broad**: Use `mcp__jbcontext__code_search` with general terms to understand the landscape
2. **Narrow down**: Add `pathFilter` (or `jbcontext search -p`) once you identify relevant directories
3. **Read the code**: Once you find relevant files, read them to understand the details

## Example Session

```text
# Find authentication-related code
mcp__jbcontext__code_search
  text: "user authentication login"

# Narrow to specific directory
mcp__jbcontext__code_search
  text: "JWT token validation"
  pathFilter: "src/auth"
```

```bash
# Fallback using the CLI
jbcontext search "user authentication login"
jbcontext search -p src/auth "JWT token validation"
```
