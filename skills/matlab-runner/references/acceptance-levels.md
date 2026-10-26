# Acceptance levels L1–L5, and how they get upgraded

Loaded on demand by `matlab-runner`. Read this before writing "it works".

## The levels are cumulative and never automatic

| Level | Meaning | Example evidence | What it does NOT prove |
|---|---|---|---|
| L1 | artifact produced | `.slx` created and non-empty; `.c`/`.h` generated | that anything was compiled |
| L2 | build/compile succeeded | MEX built; `slbuild` produced a library; model `update` passed | that the numbers are right |
| L3 | numeric result matches | `rmse` / `maxAbsDiff` within tolerance against a golden value | that other scenarios work |
| L4 | multi-scenario and failure modes | parameter sweep, NaN/Inf propagation, illegal size rejected | that it runs on hardware |
| L5 | real hardware run | board download plus read-back | — |

A run that produced a file has an **L1** claim. Calling that "deployed" is the single
most common overstatement in this repository, and it is wrong in a way that survives
review because the file really is there.

## Hard rules

- **File existence is an L1 claim only.** It never substitutes for L2 compile success.
- **Generic C codegen is not STM32 deployment.** STM32 additionally needs CubeMX
  registration, visible target hardware, a bound `.ioc`, and a matching Cube firmware
  package. Verify each separately; the STM32 checklist in `matlab-codegen-deploy`
  names the products, registration calls, `.ioc` binding, and target data fields.
- **Every run must edit the acceptance report** (`artifacts/validation/acceptance_report.json`),
  which carries `status`, `command`, `exitCode`, `metrics`, `reason`, `errorClass`
  per check.
- **`SKIP` means "not executed", and it is not a pass.** A report containing any SKIP
  has `overallStatus = SKIP` and exit code `3`.
- **`FAIL` or `SKIP` without a `reason` is rejected by the validator at construction
  time.** A missing reason is not a formatting nit: it is the difference between a
  report that can be acted on and one that cannot.

## Useful single checks

- Unit test passes with `runtests` and `assertSuccess`.
- Numerical tolerance check passes with **both** absolute and relative tolerance
  recorded. One of them alone is not reproducible across scales.
- Simulink model loads, updates, simulates to stop time, and logged signals are
  nonempty.
- Figure, data file, report, or generated code exists and has nonzero size (L1 only).
- Static checks such as `checkcode` return no critical issues for touched files.

## Which single checks are worth running

Not all of the above are relevant to every task. The cheap ones that catch the most:

| Situation | Minimum that means anything |
|---|---|
| pure MATLAB code | `runtests` + a numeric tolerance check with both bounds recorded |
| Simulink model | load, `update`, simulate, and assert the logged signal is nonempty |
| code generation | L2 build **and** L3 numeric comparison — L2 alone says only that it compiled |
| hardware | L5, read back from the board; a host-side loopback is L3 at best |