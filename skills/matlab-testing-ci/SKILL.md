---
name: matlab-testing-ci
description: MATLAB R2026a testing, validation, and CI workflow for matlab.unittest, MATLAB Test, Simulink Test, coverage, artifact generation, GitHub Actions, and open-source reproducibility. Use whenever MATLAB work needs verification, regression tests, CI, GitHub publication, or acceptance criteria.
---

# MATLAB Testing CI

Use this skill to close the loop on MATLAB work.

## Test Ladder

Start as small as possible, then broaden:

1. Smoke script runs without error.
2. One unit test checks a core numeric result.
3. Project or folder tests pass with `runtests`.
4. Simulink model simulates and logged signals are checked.
5. CI workflow runs the same command.

## MATLAB/Simulink Completion Rule

For MATLAB or Simulink engineering tasks, completion means the work has been self-checked after writing:

1. Scripts/functions run without error.
2. Simulink models load and update/compile without diagram errors.
3. Simulations reach the requested stop time.
4. Key logged signals are nonempty and finite.
5. Generated figures/data/reports exist and are nonempty.
6. If code generation or deployment is requested, generated code/project/binary artifacts are checked for existence and nonzero size.
7. If any step cannot be completed, record the exact blocker, the command that failed, and the highest-value next action.

## MATLAB Unit Test Pattern

Use:

```matlab
results = runtests;
assertSuccess(results);
```

For scripts, add explicit assertions instead of only checking that MATLAB exits.

## CI Pattern

For GitHub Actions, use MathWorks maintained actions:

- `matlab-actions/setup-matlab@v3`
- `matlab-actions/run-tests@v3`
- `matlab-actions/run-command@v3`

Use self-hosted runners for private licenses, specialized toolboxes, hardware, or long simulations.

## Artifact Requirements

Save:

- MATLAB command log.
- Test results or summary JSON.
- Figures, models, generated code, and reports.
- MATLAB release and toolbox inventory.
- Dataset or paper reproduction manifest.

## Acceptance Report

End every task with:

- Command executed.
- Passed checks.
- Skipped checks and reason.
- Artifact folder.
- Next highest-value regression test.
