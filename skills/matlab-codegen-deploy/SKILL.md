---
name: matlab-codegen-deploy
description: MATLAB R2026a code generation and deployment workflow for MATLAB Coder, Simulink Coder, Embedded Coder, GPU Coder, HDL Coder, fixed-point conversion, MEX validation, and embedded deployment readiness. Use whenever the user asks to generate C/C++/CUDA/HDL/code, deploy algorithms, or validate generated code.
---

# MATLAB Codegen Deploy

Use this skill when MATLAB or Simulink algorithms need to become generated code or deployable artifacts.

## Workflow

1. Identify target: MEX, C/C++, embedded C, CUDA, HDL, PLC, or packaged app.
2. Verify required products with `ver` and `license`.
3. Isolate the algorithm into a codegen-friendly function.
4. Define input types with `coder.typeof` or representative test vectors.
5. Generate the smallest artifact first, usually MEX.
6. Compare generated result against MATLAB golden output.
7. Save generated code, logs, reports, and validation metrics.

## Self-Compile and Verify Preference

The user expects generated MATLAB/Simulink work to compile and verify itself after writing. Do not stop at source generation when a build or smoke check is feasible:

1. For MATLAB Coder, run `codegen` and then compare generated/MEX output against MATLAB golden output when compiler support exists.
2. For Simulink Coder, update/compile the model first, run simulation, then call `slbuild` only after simulation passes.
3. For embedded targets such as STM32, first try the configured hardware target and toolchain; if it fails, capture the exact missing package/compiler message and generate the closest portable C fallback if possible.
4. Verify generated `.c`, `.h`, project, library, `elf/axf/hex/bin`, or fallback artifacts exist and are nonempty.
5. Report clearly which stage passed: model update, simulation, code generation, toolchain build, binary generation, or only portable fallback.

## MATLAB Coder Pattern

Use this pattern before larger deployment:

```matlab
cfg = coder.config("mex");
codegen -config cfg myFunction -args {coder.typeof(0,[100 1],[1 0])}
gold = myFunction(x);
actual = myFunction_mex(x);
assert(norm(gold-actual) < 1e-9)
```

## Embedded Readiness

Check:

- Fixed-size vs variable-size arrays.
- Dynamic allocation and recursion.
- Unsupported functions.
- Numeric overflow and fixed-point scaling.
- Stack and heap impact.
- Timing budget and hardware target assumptions.

## Simulink Codegen

For models:

- Update/compile the model after editing and before `slbuild`.
- Build only after simulation passes.
- Set solver and sample times explicitly.
- Run Model Advisor or relevant checks when available.
- Compare simulation outputs before and after code generation.

## Output

Report target, generated artifact path, report path, golden comparison result, and limitations.
