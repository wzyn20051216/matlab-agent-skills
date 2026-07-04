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

- Build only after simulation passes.
- Set solver and sample times explicitly.
- Run Model Advisor or relevant checks when available.
- Compare simulation outputs before and after code generation.

## Output

Report target, generated artifact path, report path, golden comparison result, and limitations.
