---
name: dependency-search
description: "Experimental jbcontext org-wide dependency search across multiple repositories. Use when need to find APIs in other repositories, or dependency configuration are used across repos for upgrades, removals, CVEs, migrations, or ownership discovery."
argument-hint: dependency query
allowed-tools: [exec, mcp__jbcontext__code_search, read]
triggers: [user, model]
---

Use this skill to research dependency usage across all available repositories when the question is about dependency usage, dependency ownership, upgrade planning, migration scope, version drift, or remediation.

## Use cases for dependency search

- **Find where a dependency is used.** Locate repos importing a package, requiring a module, referencing a framework, or declaring a dependency in package manifests, lockfiles, build files, Dockerfiles, or infrastructure config.
- **Plan dependency upgrades.** Identify consumers, pinned versions, compatibility wrappers, tests, and release paths before upgrading a shared package, runtime, SDK, framework, or generated client.
- **Scope CVE and security remediation.** Find vulnerable package versions, transitive dependency clues, vendored copies, or repeated mitigation patterns across repos.
- **Discover dependency owners and migration examples.** Find the repos that maintain a shared package and the repos that have already migrated to a newer API or replacement dependency.
- **Compare version drift.** Search for multiple declared versions or config variants to decide whether the org has one canonical version, several legacy versions, or repo-specific exceptions.
- **Find imports that do not appear in manifests.** Search for runtime imports, generated imports, plugin names, package namespaces, or error strings when manifest searches are incomplete.
- **Trace shared client and SDK usage.** Locate services using a generated API client, database library, observability package, authentication SDK, feature flag SDK, or common internal library.
- **Prepare deprecations and removals.** Identify remaining consumers, compatibility layers, fallback code, and tests that would be affected by removing a dependency.
- **Audit dependency configuration.** Search build systems, CI workflows, package managers, container images, Terraform modules, Helm charts, and language-specific dependency files for risky or inconsistent configuration.

## Workflow

1. **Find candidate repositories first.** Run the experimental repo discovery command before searching code:

```bash
exec: jbcontext repos "<repo or dependency terms>" --limit 30
```

Use short, discriminative terms from the request: package names, module names, framework names, SDK names, team names, service names, or explicit repository names.

2. **Handle prefixed repository families carefully.** If the request mentions a prefix or wildcard such as `jcp-*`, treat it as a repository-family constraint.

- Query the prefix literally, for example `jcp` and `jcp-`.
- Keep all suitable repos whose names start with that prefix.
- Do not replace a prefixed repo family with a similar unprefixed repo unless the repo results clearly show it is the right target.
- Preserve the exact repository `id` returned by `jbcontext repos`; do not infer ids from names.

```bash
exec: jbcontext repos "jcp-" # show all repos started with jcp- prefix
```

You can omit query completely.

3. **Select suitable repos.** Prefer exact dependency-owner repos, exact service matches, prefix-family matches, and repos whose description/path/language/package ecosystem matches the task. If there are many candidates, search the most likely 5-10 first, then expand if results are weak.

4. **Search selected repos in parallel.** Invoke `jbcontext search` once per selected repository. From the `jbcontext repos --json-output` result, use the `repository` value as the `--git-remote-url` argument:

```bash
exec: jbcontext search --git-remote-url "<repository>" --json-output --limit 10 "<semantic dependency search query>"
```

If the installed `jbcontext` rejects `--git-remote-url`, run `jbcontext search --help` and use the repository/URL flag it documents, still passing the exact `repository` value from `jbcontext repos`. Run independent repo searches in parallel when the agent environment supports parallel tool calls; otherwise keep results grouped by repository.

5. **Resolve snippets and repo information.** When `jbcontext search` returns promising snippets, use the built-in `read` tool for local files or the GitHub CLI (via `exec`) to fetch full manifests, lockfiles, source files, surrounding code, default branch, repo metadata, owners, recent commits, or related dependency PRs/issues before relying on the match. Use the GitHub owner/name or URL from `jbcontext repos` when available.

```bash
exec: gh repo view "<owner>/<repo>" --json nameWithOwner,description,defaultBranchRef,url
exec: gh api "repos/<owner>/<repo>/contents/<path>?ref=<ref>" -H "Accept: application/vnd.github.raw"
```

6. **Synthesize dependency findings.** Report which repos were searched, which repos had useful matches, the dependency declarations/usages found, known versions or config variants, likely owners, and recommended follow-up checks. If no suitable repo is found, say which repo filters were tried before stopping.

## Search Guidance

- Use semantic, behavior-focused queries for `jbcontext search`; avoid one-word searches.
- Include ecosystem-specific terms when useful, such as manifest names, package manager names, import namespaces, generated client names, runtime names, or version strings.
- Search both declarations and runtime usage; dependency manifests alone can miss generated, vendored, plugin, or transitive usage.
- Re-run `jbcontext repos` with narrower or prefix-aware terms before broadening code search.
- Use path filters only after repo-level matches identify likely directories.
- Keep repository names and ids visible in notes so later searches can be reproduced.
- Use `gh` (via `exec`) to resolve snippets into full source context and to gather more information about matching repositories.
