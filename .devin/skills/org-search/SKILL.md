---
name: org-search
description: "Experimental jbcontext org-wide semantic search across multiple repositories"
argument-hint: query
allowed-tools: [exec, mcp__jbcontext__code_search, read]
triggers: [user, model]
---

Use this skill to research across all available repositories, especially when the answer may live outside the current repo.

## Use cases for cross repository search

- **Find reusable components, libraries, or utilities.** Before writing new code, check whether another repo already exposes a client, helper, or shared package that solves the problem.
- **Locate prior art and reference implementations.** Discover how other teams have already solved a similar design problem (e.g. retry logic, feature flag wiring, pagination, caching, auth middleware) so a new implementation can follow established patterns.
- **Trace cross-service API consumers and producers.** Given an endpoint, RPC, topic, or event name, find every repo that publishes or consumes it to understand blast radius before changing a contract.
- **Find usages of a shared library, type, or symbol across the org.** Useful for migrations, deprecations, and breaking-change planning — answer "who imports this?" when the symbol is defined in a shared package.
- **Investigate unfamiliar systems and code ownership.** When a request mentions a service, table, or feature you don't recognize, search the org to find the owning repo, its README, and entry points before asking a human.
- **Audit security, compliance, or anti-pattern occurrences.** Sweep all repos for risky patterns (hardcoded secrets shapes, deprecated crypto, banned dependencies, unsafe SQL) to scope remediation work.
- **Discover configuration and infrastructure examples.** Find how other services configure the same tool (CI workflows, Dockerfiles, Terraform modules, Helm charts, observability setup) to copy a known-good baseline.
- **Cross-reference schemas, protos, and shared data models.** Locate the canonical definition of a type or message and every repo that depends on it.
- **Reproduce or correlate bugs across services.** When a bug may stem from a shared dependency or duplicated logic, search the org for the same code path or error string.
- **Onboarding and documentation lookup.** Surface relevant docs, runbooks, and examples that live outside the current repo when the local codebase doesn't fully explain a workflow.

## Workflow

1. **Find candidate repositories first.** Run the experimental repo discovery command before searching code:

```bash
exec: jbcontext repos "<repo or domain terms>" --limit 30
```

Use short, discriminative repo terms from the request: product names, service names, team names, package names, or explicit repository names.

2. **Handle prefixed repository families carefully.** If the request mentions a prefix or wildcard such as `jcp-*`, treat it as a repository-family constraint.

- Query the prefix literally, for example `jcp` and `jcp-`.
- Keep all suitable repos whose names start with that prefix.
- Do not replace a prefixed repo family with a similar unprefixed repo unless the repo results clearly show it is the right target.
- Preserve the exact repository `id` returned by `jbcontext repos`; do not infer ids from names.

```bash
exec: jbcontext repos "jcp-" # show all repos started with jcp- prefix
```

You can omit query completely.

3. **Select suitable repos.** Prefer exact name matches, prefix-family matches, and repos whose description/path/language matches the task. If there are many candidates, search the most likely 5-10 first, then expand if results are weak.

4. **Search selected repos in parallel.** Invoke `jbcontext search` once per selected repository. From the `jbcontext repos --json-output` result, use the `repository` value as the `--git-remote-url` argument:

```bash
exec: jbcontext search --git-remote-url "<repository>" --json-output --limit 10 "<semantic search query>"
```

If the installed `jbcontext` rejects `--git-remote-url`, run `jbcontext search --help` and use the repository/URL flag it documents, still passing the exact `repository` value from `jbcontext repos`. Run independent repo searches in parallel when the agent environment supports parallel tool calls; otherwise keep results grouped by repository.

5. **Resolve snippets and repo information.** When `jbcontext search` returns promising snippets, use the built-in `read` tool for local files or the GitHub CLI (via `exec`) to fetch full file context, surrounding code, default branch, repo metadata, owners, recent commits, or related PRs/issues before relying on the match. Use the GitHub owner/name or URL from `jbcontext repos` when available.

```bash
exec: gh repo view "<owner>/<repo>" --json nameWithOwner,description,defaultBranchRef,url
exec: gh api "repos/<owner>/<repo>/contents/<path>?ref=<ref>" -H "Accept: application/vnd.github.raw"
```

6. **Synthesize across repositories.** Report which repos were searched, which repos had useful matches, and the strongest files/symbols found. If no suitable repo is found, say which repo filters were tried before stopping.

## Search Guidance

- Use semantic, behavior-focused queries for `jbcontext search`; avoid one-word searches.
- Re-run `jbcontext repos` with narrower or prefix-aware terms before broadening code search.
- Use path filters only after repo-level matches identify likely directories.
- Keep repository names and ids visible in notes so later searches can be reproduced.
- Use `gh` (via `exec`) to resolve snippets into full source context and to gather more information about matching repositories.
