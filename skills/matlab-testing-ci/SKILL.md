---
name: matlab-testing-ci
description: MATLAB testing, validation, and CI workflow for matlab.unittest, MATLAB Test, Simulink Test, coverage, artifact generation, GitHub Actions, and open-source reproducibility. Use whenever MATLAB work needs verification, regression tests, CI, GitHub publication, or acceptance criteria.
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

## Three Questions, Three Answers

"It ran", "the number is right" and "the requirement is met" are different claims,
and Phase 3A/3B produced every combination of them. `mas_grade` keeps them apart:

```matlab
r = mas_grade(checks);   % each check: executed / kind / value / reference / limit
r.ran      % did everything execute?
r.correct  % true | false | 'UNDETERMINED'  (a numeric check with no independent
           %                                  reference is UNDETERMINED, not true)
r.meets    % true | false | 'UNDETERMINED'
r.overall  % FAIL | CORRECT_NOT_ACCEPTED | UNDETERMINED | PASS
```

The `CORRECT_NOT_ACCEPTED` verdict exists for the Boost case where the output sat at
47.88 V (correct) while recovery took 2.25 ms against a 2 ms requirement. Reporting
that as PASS is exactly the failure this skill is supposed to prevent.

Domain-specific thresholds (Buck S1-S9, Boost B1-B12, BER curves, THD limits) belong
to the domain skill; `mas_grade` only consumes them. Never copy one domain's numbers
into another. `tests/test_grade.m` covers six combinations.

## References Are Frozen, Not Recomputed

A task that grades itself is not being tested. `mas_verify_task(id, values)` grades a
task's NUMBERS against `evals/references/reference_manifest.json`, which is committed
with a SHA-256 per entry:

```matlab
v = mas_verify_task('D3', out.values);
v.status       % PASS | FAIL | UNDETERMINED
v.perCheck     % field, got, ref, op, tol, pass
```

Three guards, all of which must hold before a number is called a reference:

1. Two or more INDEPENDENT derivation methods agree far tighter than the grading
   tolerance (`mas_ref_derive.m`). The Phase 4 D3 error -- the analog Butterworth
   formula used to grade a DIGITAL filter -- cannot survive this, because the second
   method is a hand-written difference-equation recursion, not a restatement.
2. The hand-declared value in `mas_ref_spec.m` agrees with the derived value at
   freeze time. A transposed centroid or a wrong constant fails before freezing.
3. `mas_refcheck('verify')` re-derives everything and compares hashes. Editing the
   manifest -- even consistently -- is detected.

`mas_refcheck('freeze')` rewrites the committed file and is deliberately NOT part of
the normal test run: changing a reference must show up as a diff.
`tests/test_refcheck.m` feeds the verifier wrong values and two kinds of tampered
manifest and requires the right rejection in each case.
