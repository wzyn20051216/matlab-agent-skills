---
name: matlab-runner
description: Run MATLAB R2026a tasks from Codex with reliable batch execution, logs, artifacts, toolbox inventory, smoke tests, and reproducible validation. Use whenever MATLAB code, .m/.mlx scripts, MATLAB tests, local toolbox probing, or command-line automation is needed.
---

# MATLAB Runner

Use this skill to execute MATLAB work safely and repeatably from the terminal. It is the foundation skill for all other MATLAB skills.

## Execution Rules

1. Prefer `matlab -batch` for noninteractive work.
2. Capture stdout, stderr, exit code, MATLAB version, working directory, and artifact paths.
3. Run from a project root, not from a random temporary folder, unless isolation is required.
4. Put generated files under `artifacts/` or a user-specified output folder.
5. Keep scripts deterministic: seed random generators and record data sources.

## Preferred Wrapper

If this repository exists, prefer:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Invoke-MatlabBatch.ps1 -Script .\path\to\script.m
```

For a full local smoke test:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1
```

If the wrapper is not available, call MATLAB directly:

```powershell
matlab -batch "disp(version); v=ver; disp({v.Name}')"
```

## MATLAB Discovery

Use this order to find MATLAB:

1. `$env:MATLAB_EXE`
2. `Get-Command matlab`
3. Known install path such as `E:\Program Files\MATLAB\R2026a\bin\matlab.exe`

Verify before running expensive work:

```matlab
disp(version)
v = ver;
{v.Name}'
```

## Error Handling

When MATLAB fails:

- Read the first error and the deepest stack frame.
- Check missing toolbox with `license('test', product)` and `ver`.
- Check path ambiguity with `which functionName -all`.
- Re-run a minimal reproduction before editing large code.
- Save the failing command and log path.

## Acceptance Checks

Choose at least one:

- Unit test passes with `runtests` and `assertSuccess`.
- Numerical tolerance check passes.
- Simulink model simulates to stop time and logged signals are nonempty.
- Figure, data file, report, or generated code exists and has nonzero size.
- Static checks such as `checkcode` return no critical issues for touched files.

## Paper Reproduction Mode

For open-source paper projects:

1. Record paper URL, commit hash, dataset URL, MATLAB release, toolbox list.
2. Run the smallest official example first.
3. Reproduce one figure or table before scaling to the whole paper.
4. Save `manifest.json`, raw logs, processed data, and generated figures.
5. Mark differences from the paper explicitly instead of smoothing them over.
