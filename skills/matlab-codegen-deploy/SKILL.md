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

## STM32 Embedded Coder Readiness

For STM32 targets, do not treat "an executable exists on disk" as enough. Verify the full MATLAB-to-ST chain before blaming the model:

- MATLAB products: Simulink, Simulink Coder, Embedded Coder, STM32 support package.
- MATLAB registration: `stm32cube.hwsetup.stm32Tools.getInstalledSTM32CubeMX()` returns the CubeMX directory MATLAB will use.
- ST tools: GNU Tools for STM32, CMSIS, CMSIS-DSP, STM32CubeMX, and the matching STM32Cube firmware package such as `STM32Cube_FW_F1_*`.
- Model binding: the model has a real `.ioc` path in `STM32CubeMX.ProjectFile`.
- Target hardware: `codertarget.targethardware.getRegisteredTargetHardwareNames` includes the required STM32 family, for example `STM32F1xx Based`.

Prefer target data APIs over editing opaque structures:

```matlab
tools = stm32cube.hwsetup.stm32Tools();
tools.updateSTM32CubeMXPath("C:\Users\me\AppData\Local\Programs\STM32CubeMX");

codertarget.data.setParameterValue(model, "STM32CubeMX.ProjectFile", iocPath);
codertarget.data.setParameterValue(model, "STM32CubeMX.DeviceId", "STM32F103RBTx");
codertarget.data.setParameterValue(model, "STM32CubeMX.Family", "STM32F1");
```

If `slbuild` hangs around "Generating code from STM32CubeMX project" or "Starting compilation process":

- Check `STM32CubeMX.log`, generated `hardware` scripts, and background `java.exe` / `STM32CubeMX.exe` processes.
- Compare direct `STM32CubeMX.exe -q script` with MATLAB's `java -jar STM32CubeMX.exe -q script`; some CubeMX versions can behave differently.
- Prefer the MathWorks-recommended CubeMX version shown by `message("stm32:setup:CubeMXReqVersion").getString`.
- If non-ASCII paths are involved, copy the model and `.ioc` to an ASCII scratch path and retry once to isolate path encoding from model errors.
- Only use a local CubeMX wrapper as a documented workaround after recording the direct failure and the real CubeMX path.

## Output

Report target, generated artifact path, report path, golden comparison result, and limitations.
