---
name: context-review
description: "Use this skill to review code changes using semantic search to understand context and impact"
argument-hint: query
allowed-tools: [read, exec, mcp__jbcontext__code_search]
triggers: [user, model]
---

## When to Use

- Before committing changes to understand what you're about to commit
- Reviewing pull requests or branches
- Understanding the impact of changes on the rest of the codebase

## Review Workflow

### 1. Check Current Changes

First, see what's changed:

```bash
exec: git status
exec: git diff                    # Unstaged changes
exec: git diff --staged           # Staged changes
exec: git diff main...HEAD        # All changes on current branch
```

### 2. Understand Changed Code Context

For each significantly changed file, use semantic search to understand:

- **Similar patterns**: Find similar code elsewhere that might need the same change
- **Callers**: Find code that calls the modified functions
- **Dependencies**: Find code that the modified code depends on

```text
# Find similar patterns
mcp__jbcontext__code_search
  text: "<code chunk that was changed>"

# Find callers of a modified function
mcp__jbcontext__code_search
  text: "calls to <function name> to understand impact"

# Find related test files in the "test/" directory
mcp__jbcontext__code_search
  text: "tests for <feature being modified>"
  pathFilter: "test"
```

```bash
# Fallback using the CLI
jbcontext search "<code chunk that was changed>"
jbcontext search "calls to <function name> to understand impact"
jbcontext search -p test "tests for <feature being modified>"
```

### 3. Review Checklist

For each change, verify:

- [ ] The change is consistent with similar patterns in the codebase
- [ ] All callers of modified functions will still work correctly
- [ ] Related tests exist and cover the changes
- [ ] The change doesn't reintroduce previously fixed bugs

## Example Session

```bash
exec: git diff --staged
```

```text
# For a change to auth middleware, find similar patterns
mcp__jbcontext__code_search
  text: "authentication middleware pattern"

# Find what calls this middleware
mcp__jbcontext__code_search
  text: "uses auth middleware to protect routes"

# Find related tests
mcp__jbcontext__code_search
  text: "auth middleware test"
  pathFilter: "test"
```
