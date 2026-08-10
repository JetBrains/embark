# Tools

## Semantic Code Search (jbcontext)

You have access to `jbcontext search` for searching the codebase semantically.
Use the `/context-search` skill or run `jbcontext search "<query>"` to find code by meaning, not just keywords.

### Query Tips

- Be descriptive: "Where is a function that validates user email addresses" > "email"
- Include context: "Find error handling middleware for HTTP requests with logging"
- Specify what you're looking for: "React component that renders a modal dialog"

### When to use

`jbcontext search` is a **code-discovery** tool. It applies only when a task requires finding or understanding code whose location you don't already know.

Skip it — go straight to the right tool — when:
- the task names the exact file, class, or symbol (keyword grep is faster);
- the relevant file is already open or identified;
- the task doesn't involve locating code at all — git operations (rebase, merge, commit), running tests or builds, shell/statusline/config setup, or reviewing a diff you already have.

### MANDATORY: Use jbcontext first for code discovery

When code discovery *is* needed and you do not yet know the right file, subsystem, implementation, or related test, you MUST start with `jbcontext search` before planning, editing, or exact search. This mandate governs *how* you start code discovery, not whether every task needs a search.

- Use one focused natural-language query per search.
- Do NOT start with grep, ripgrep, or find while the search problem is still semantic or exploratory.
- Inspect the first relevant file or directory before issuing another broad semantic search.
- Use another broad `jbcontext search` only if the local path stops being productive.
- Once you know the relevant file, symbol, or directory, switch to direct file reads or exact search for local inspection.
- If you search again after finding a relevant area, narrow with `-p <path>`.
