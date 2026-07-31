## Multi-Repo Search (jbcontext)

Your indexed context is not limited to the current 
checkout: `jbcontext` searches every repository you have access to, not just the current checkout. Prefer the
`/org-search`, `/dependency-search`, and `/blast-radius` skills; the commands below are the fallback.

Go org-wide once the local answer is missing or insufficient — typically when the symbol, service, or
table is defined elsewhere, when you need prior art, or when a shared contract or dependency change
needs its producers and consumers.

Discover candidate repos first, then search them one query at a time (in parallel when possible):

```bash
jbcontext repos "<repo, service, team, or package terms>" --limit 30
jbcontext search --git-remote-url "<repo url from jbcontext repos>" --limit 10 "<semantic query>"
```

- A prefix such as `jcp-*` is a repo-family constraint: query it literally and keep every match.
- Report which repos you searched and what matched; if nothing matched, say which filters you tried.
- Open the full file (e.g. via `gh`) before stating a cross-repo snippet as fact — the index may lag.
