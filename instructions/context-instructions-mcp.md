# Tools

## Semantic Code Search (jbcontext)

You have access to the jbcontext MCP `code_search` tool for searching the codebase semantically.
This tool can search for code snippets related in meaning to the search query and search objective.

### Query Tips

- Be descriptive: "Where is a function that validates user email addresses" > "email"
- Include context: "Find error handling middleware for HTTP requests with logging"
- Specify what you're looking for: "React component that renders a modal dialog"

### When to use

`code_search` is a **code-discovery** tool. Reach for it only when a task requires finding or understanding code whose location you don't already know.

Skip it — go straight to the right tool — when:
- the task names the exact file, class, or symbol (keyword grep is faster);
- the relevant file is already open or identified;
- the task doesn't involve locating code at all — git operations (rebase, merge, commit), running tests or builds, shell/statusline/config setup, or reviewing a diff you already have.

### How to use it
- Start with `code_search` before planning, editing, or exact search in unfamiliar code when you do not yet know the right file, subsystem, implementation, or related test.
- Use one focused natural-language query per search.
- Do not start with grep, ripgrep, or find when the search problem is still semantic or exploratory.
- Inspect the first relevant file or directory before issuing another broad semantic search.
- Use another broad `code_search` only if the local path stops being productive.
- Once you know the relevant file, symbol, or directory, switch to direct file reads or exact search for local inspection.
- If you search again after finding a relevant area, narrow with `pathFilter`.
