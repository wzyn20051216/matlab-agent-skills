# Isolated Benchmark (Phase 5.3)

This harness measures one question: when a task is handed over, can the MATLAB
tooling produce a verdict that an independent, frozen reference agrees with? It
does **not** measure an LLM agent unless a real agent episode is run — and the
grade file says so in `baseline`, `agentRuns`, and `agentLevel`.

## Isolation contract

1. **The agent-visible repository never contains the held-out answers.**
   `benchmark/dev/` is public: its tasks and answers exist so the harness can be
   developed. The formal holdout lives outside the repository, at
   `MAS_BENCH_HOLDOUT_ROOT` (default `E:\desktop\MATLAB-bench-holdout-phase53`).
2. **Reference answers and the grader are on the evaluation side.**
   `benchmark_run.m` receives only `tasks.json`; `benchmark_grade.m` reads
   `answers.json` afterwards and compares.
3. **Freeze before evaluation.** `benchmark_freeze.m` hashes `tasks.json` and
   `answers.json` into `manifest.json`. The grader refuses to run if either hash
   changed. `run_holdout.m` never freezes.
4. **Dev and held-out are disjoint.** `benchmark_audit.m` checks path
   containment, the frozen hashes, byte-identical answer copies, and id overlap
   between the dev and holdout sets.
5. **Complete evidence.** Each task writes `input_<id>.mat` (exact inputs),
   `trajectory_<id>.jsonl` (environment → input → route → capability → fixture →
   tool call → delivery), `output_<id>.mat` (full result), and `result_<id>.json`
   (the declared fields + hashes). For a holdout run these live under
   `<holdout root>/runs/`, not in the repository: the graded output names the
   expected verdicts and must not enter the agent-visible workspace.
6. **Tool-level only unless a real agent ran.** `benchmark_grade.m` reports
   `baseline = 'tool-level scripted policy (NOT an Agent benchmark)'`,
   `agentRuns = 0`, `agentLevel = 'NOT TESTED'`. A MATLAB regression pass is not
   an Agent benchmark and must not be reported as one.

This is procedural isolation, not an OS sandbox: a process that knows the
absolute holdout path can read it. The claim is that the workspace handed to the
agent does not contain the answers and that the grader verifies the freeze.

## Set layout

```
<holdout root>/
  tasks.json      prompt, skill, tool, fixture id, reported fields  (public to the runner)
  answers.json    expected skill/tool/verdict + numeric fields      (sealed)
  manifest.json   SHA-256 of both files + frozen timestamp
```

The Phase 5.3 set has 9 tasks: three domains (signal, data analysis, robotics) ×
three kinds (normal, boundary, fault). The formal set's ids, fixtures, prompts
and reference values are evaluation-side only; the shape each cell exercises is:

| id | domain | kind | property exercised |
|---|---|---|---|
| EX-001 | signal | normal | a measured quantity agrees with an independent reference |
| EX-002 | signal | boundary | degenerate evidence yields UNDETERMINED, not PASS |
| EX-003 | signal | fault | a claim contradicted by the record is reported as FAIL |
| EX-004 | data | normal | two independent routes agree inside a stated tolerance |
| EX-005 | data | boundary | an ill-conditioned system cannot certify a solution |
| EX-006 | data | fault | a perturbed solution fails residual/cross-route checks |
| EX-007 | robotics | normal | a transform convention agrees with independent composition |
| EX-008 | robotics | boundary | a quantity is undefined in the degenerate case |
| EX-009 | robotics | fault | a sign error is caught by identities, not by inspection |

The `EX-` ids above are illustrative; the sealed set uses its own ids outside
the repository and `benchmark_audit.m` checks that they do not overlap dev.

## Task and answer schema

Task:

```json
{"id":"EX-001","domain":"signal","kind":"normal","prompt":"...",
 "skill":"matlab-signal-vision-ai","tool":"mas_measure_contract",
 "fixture":"example_fixture","seed":53,
 "report":["verdict","measured.fPeak","powerLinear"]}
```

Answer:

```json
{"id":"EX-001","skill":"matlab-signal-vision-ai","tool":"mas_measure_contract",
 "verdict":"PASS",
 "fields":[{"name":"measured.fPeak","op":"abs","ref":123.4,"tol":0.5},
           {"name":"powerLinear","op":"rel","ref":0.5,"tol":0.05}]}
```

`op` is `abs`, `rel`, `maxabsdiff`, `min`, `max`, or `exact`. Dotted field names
are flattened to `_` in `result_<id>.json` (`measured.fPeak` → `measured_fPeak`).

## Running

Evaluation side (authoring and freezing):

```matlab
addpath('benchmark');
benchmark_freeze('<root>/tasks.json', '<root>/answers.json', '<root>/manifest.json');
```

Run and grade (the runner sees tasks only; the grader sees answers):

```matlab
setenv('MAS_BENCH_HOLDOUT_ROOT', '<root>');
run_holdout
```

`run_holdout` writes results and `grade.json` to `<root>/runs/latest` by default;
set `MAS_BENCH_OUT` only to another location outside the repository.

Development self-test (public answers in `benchmark/dev/`):

```matlab
benchmark_run('benchmark/dev/tasks.json', 'artifacts/phase53/benchmark/results_dev');
benchmark_grade('artifacts/phase53/benchmark/results_dev', ...
    'benchmark/dev/tasks.json', 'benchmark/dev/answers.json', ...
    'benchmark/dev/manifest.json');
```

Harness self-test (11/11): `tests/test_benchmark_harness.m` builds a throwaway
workspace and holdout, then checks that a frozen hash mismatch is refused, an
answers copy inside the workspace is caught (including one hidden under
`artifacts/phase53`), missing results are counted as failures, and altered
verdicts/fields cannot pass. It is registered in
`matlab/validation/phase4/run_all.m` as `benchmarkHarness`.

To run a real agent episode later, hand the agent only the nine prompts (not
`tasks.json`'s report list, not the answers) and require `result_<id>.json` in
the same schema. Then grade with the same sealed file. Only that run may be
reported as an Agent benchmark.

## Phase 5.3 pilot disclosure

A v1 pilot (2026-10-22) was run before the formal freeze. It found two
**benchmark-spec** errors, not tool errors:

1. A frequency field echoed the *claimed* value instead of the measured one, so
   the v1 answer compared the claim to itself.
2. A boundary-task tolerance was tighter than the difference between the hand
   reference and the measured value.

No tool was changed in response. v1 tasks, answers, manifest, and result folder
are retained (`*_v1.json` and `<root>/runs/v1_pilot/`) as evidence; the formal
v2 set was frozen afterwards and is the only set reported. The repository keeps
only the aggregate `artifacts/phase53/benchmark/task5_summary.json` and the
isolation audit; per-task holdout results stay on the evaluation side.
