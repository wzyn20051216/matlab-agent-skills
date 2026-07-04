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
