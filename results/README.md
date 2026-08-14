# Published eval results


```
results/
  index.json                                 every dataset and arm below, for enumeration
  <dataset>/
    dataset.json                             properties of the task set: size, files, LOC, taskCount
    <harness>+<model>+<effort>/              one directory per measured cell
      baseline.json                          the arm run WITHOUT jbcontext
      jbcontext.json                         the arm run WITH it
```

`index.json` is required.

## Aggregates versus per-task

`tasks[]` is optional and changes how the cell is labelled, never how much it is trusted:

| Published            | Row label         | Sample                          |
| -------------------- | ----------------- | ------------------------------- |
| `tasks[]` both arms  | `measured`        | tasks paired by `taskId`        |
| aggregates only      | `dataset-average` | the dataset's task count        |

With per-task metrics one dataset can also split into several rows by each task's own `sizeLabel`.

## Adding a dataset

1. Write `<dataset>/dataset.json` and both arms of each cell.
2. Add the dataset and its arm directory names to `index.json`.
3. Validate — see below. Do this before opening the PR; it is the only step that checks the numbers
   rather than the files.

## Validate

```
jbcontext analyze --check-results .                                       # this checkout
jbcontext analyze --check-results . --json-output                         # same findings, for CI to parse
jbcontext analyze --check-results https://github.com/jetbrains/context    # what main publishes right now
jbcontext analyze --check-results https://github.com/jetbrains/context/tree/my-branch
```

A healthy tree looks like this:

```
  Published eval results · /path/to/context
  Datasets      3 · monorepo-swebench, oss-swe-bench, swe-bench-pro
  Cells         3 with both arms parsed
  Rows          3 · 3 dataset-average

    claude opus high XL          cost +0.34 · turns +0.41 · explorationTime +0.15 · resolution +0.00 · dataset-average n=175
    claude opus high XS          cost +0.06 · toolCalls +0.06 · turns +0.14 · explorationTime +0.04 · dataset-average n=205
    codex gpt-5.3-codex high XL  cost -0.07 · explorationTime -0.01 · resolution -0.05 · dataset-average n=731

  Default       cost +0.06 · toolCalls +0.06 · turns +0.14 · explorationTime +0.04 · extrapolated
  Unmeasured    tokens — reported as n/a, never as 0

  Problems      none

  OK — 3 rows from 3 datasets.
```

Read the **Rows** block against what you meant to publish. Every failure mode below produces a tree
that parses and validates and is still wrong, which is why file-level checks cannot catch them:

| What went wrong                             | What you would otherwise ship                       |
| ------------------------------------------- | --------------------------------------------------- |
| both arms are the same file                 | every effect `0.00`, labelled as a real measurement |
| the arms are swapped                        | every effect with its sign inverted                 |
| a metric in one arm only                    | that metric silently absent                         |
| a metric paired on too few tasks            | a quotient of reporting coverage, not of the effect |
| a zero baseline, or a zero jbcontext arm    | a division by zero, or a "100% saving"              |
| two datasets publishing the same cell       | one of them measured to no effect                   |
| a row no query can reach                    | numbers published that no session ever reads        |

The last two are the ones worth re-reading the output for: nothing about the files is wrong, and the
measurement simply never surfaces. `--check-results` reports them as `unreachable`.

Also useful:

- `jbcontext analyze --json-output` on real sessions exposes the resolved table under `projection`,
  including which cell each number came from.