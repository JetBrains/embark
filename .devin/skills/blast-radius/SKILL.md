---
name: blast-radius
description: "Experimental jbcontext org-wide blast-radius analysis across multiple repositories. Use when you need to estimate the impact of changing an API, endpoint, schema, event, shared library, config, feature flag, data model, behavior, or dependency by finding producers, consumers, owners, tests, and related repos."
argument-hint: change or contract query
allowed-tools: [exec, mcp__jbcontext__code_search, read]
triggers: [user, model]
---

Use this skill to research impact across all available repositories when the question is about impact analysis, consumers, producers, compatibility risk, migration scope, rollout planning, or cross-repo ownership.

## Use cases for blast-radius analysis

- **Find consumers before changing a contract.** Given an endpoint, RPC, topic, event, protobuf, schema, enum, table, config key, or shared type, locate repos that publish, consume, validate, transform, or test it.
- **Scope API and behavior changes.** Identify services, clients, SDKs, generated code, docs, tests, and compatibility layers that depend on the current behavior.
- **Plan migrations and deprecations.** Find remaining users of old flags, versions, endpoints, event names, schemas, or dependency APIs before removal.
- **Trace ownership across systems.** Locate the owning repo, adjacent services, deployment config, runbooks, and callers when a request mentions an unfamiliar system.
- **Estimate rollout risk.** Search for feature flag wiring, config defaults, environment overrides, CI workflows, dashboards, or alerts that may need coordinated changes.
- **Find copied logic and duplicate implementations.** Search for similar validation, parsing, retry, auth, serialization, pagination, or error-handling code that might need the same fix.
- **Audit tests and safety nets.** Locate unit, integration, contract, fixture, golden-file, and end-to-end tests that cover the changed behavior.
- **Correlate incidents or bugs across repos.** Find shared error strings, log messages, metrics, spans, alerts, or fallback paths that reveal affected services.
- **Prepare stakeholder notes.** Identify repos searched, concrete matches, owners, likely impacted surfaces, and unknowns that need human confirmation.

## Workflow

0. **Gather possible dependencies, make a discovery about the current project how it can be consumed**

1. **Read the project's curated repo list first.** Each project may pin a hand-maintained list of external repositories in its agent instruction file. Read it before anything else and treat it as the **primary** source of candidate repos. Look in the current project, in this order, and use the first one that contains the list section:

- `CLAUDE.md`
- `AGENTS.md`

   The list lives in a section delimited by these markers (anywhere in the file):

```markdown
<!-- blast-radius-repos-start -->
## Blast-radius external repositories
| Name | git-remote-url | owner/repo | When relevant |
|------|----------------|------------|---------------|
| payments-api | github.com/acme/payments-api | acme/payments-api | Owns `/payments` REST + payment events; pick for any payment contract/schema change |
<!-- blast-radius-repos-end -->
```

   When the section exists:

- Match rows by their `When relevant` trigger against the change being analyzed.
- Use the exact `git-remote-url` from the matching rows for `jbcontext search` (step 4) — do not look these values up again or infer them from names.

   **Fall back to `jbcontext repos` discovery only when the project has no such section, or it has no row relevant to the change** (and to sanity-check that the list is not missing an obvious candidate). The experimental repo discovery command:

```bash
exec: jbcontext repos "<repo or system terms>" --limit 30
```

Use short, discriminative terms from the request: service names, endpoint names, schema names, event/topic names, package names, team names, product names, or explicit repository names. The shorter the better.

You can omit query completely.

```bash
exec: jbcontext repos
```

Note: `jbcontext repos` matches **repository names by substring** and returns each repo's `repository` git-remote-url (e.g. `github.com/jetbrains/context`) — this is the exact value `jbcontext search --git-remote-url` expects. To populate the curated list, find a repo with `jbcontext repos "<terms>" --json-output` and copy its `repository` value into a new row.

2. **Handle prefixed repository families carefully.** If the request mentions a prefix or wildcard such as `jcp-*`, treat it as a repository-family constraint.

- Query the prefix literally, for example `jcp` and `jcp-`.
- Keep all suitable repos whose names start with that prefix.
- Do not replace a prefixed repo family with a similar unprefixed repo unless the repo results clearly show it is the right target.
- Preserve the exact `repository` git-remote-url returned by `jbcontext repos`; do not infer it from names.

```bash
exec: jbcontext repos "jcp-" # Example: show all repos started with jcp- prefix
```

3. **Select suitable repos.** Start from the rows whose `When relevant` triggers matched in the project's curated list, then add any exact owner/consumer/producer repos, prefix-family matches, and repos whose description/path/language/domain matches the changed surface (from the fallback `jbcontext repos` discovery). If there are many candidates, search the most likely 5-10 first, then expand if results are weak.

4. **Search selected repos in parallel.** Invoke `jbcontext search` once per selected repository, passing the repo's git-remote-url (the exact `git-remote-url` from the project's curated list, or the `repository` value from `jbcontext repos` for fallback candidates) via the `--git-remote-url` option:

```bash
exec: jbcontext search --git-remote-url "<repo-git-remote-url>" --json-output --limit 10 "<semantic blast-radius search query>"
```

Run `jbcontext search --help` to confirm the flag for the installed experimental CLI if `--git-remote-url` is rejected, but still pass the exact git-remote-url from the project's curated list or `jbcontext repos`. Run independent repo searches in parallel when the agent environment supports parallel tool calls; otherwise keep results grouped by repository.

5. **Resolve snippets and repo information.** When `jbcontext search` returns promising snippets, use the built-in `read` tool for local files or the GitHub CLI (via `exec`) to fetch full source files, surrounding code, default branch, repo metadata, owners, recent commits, or related PRs/issues before relying on the match. Use the GitHub owner/name or URL from `jbcontext repos` when available.

```bash
exec: gh repo view "<owner>/<repo>" --json nameWithOwner,description,defaultBranchRef,url
exec: gh api "repos/<owner>/<repo>/contents/<path>?ref=<ref>" -H "Accept: application/vnd.github.raw"
```

6. **Synthesize blast-radius findings.** Report which repos were searched, which repos had useful matches, the strongest producers/consumers/files/symbols found, likely impacted surfaces, and unresolved unknowns. Separate confirmed impacts from plausible leads. If no suitable repo is found, say whether the project's curated list (`CLAUDE.md`/`AGENTS.md`) had a relevant row and which `jbcontext repos` filters were tried before stopping. If a relevant repo seems to be missing from the curated list, note it (with its `repository` value if known) so the project's list can be updated.

## Search Guidance

- Use semantic, behavior-focused queries for `jbcontext search`; avoid one-word searches.
- Search for both names and behavior: endpoint paths, message names, schema fields, event topics, config keys, feature flags, error strings, metric names, and the behavior being changed.
- Search producers, consumers, tests, generated code, docs, and deployment/config paths when blast radius matters.
- Re-run `jbcontext repos` with narrower or prefix-aware terms before broadening code search.
- Use path filters only after repo-level matches identify likely directories.
- Keep repository names and ids visible in notes so later searches can be reproduced.
- Use `gh` (via `exec`) to resolve snippets into full source context and to gather more information about matching repositories.
