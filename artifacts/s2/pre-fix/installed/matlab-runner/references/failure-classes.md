# Failure classes and what may be retried

Loaded on demand by `matlab-runner`. Consult before retrying a failed run.

## The table

| Class | Auto-retry | Typical cause |
|---|---|---|
| `TIMEOUT` | yes | process exceeded its budget and was killed |
| `MCP_CONNECTION_ERROR` | yes | port closed, handshake rejected, bad API key |
| `ENVIRONMENT_ERROR` | no | compiler or executable missing |
| `LICENSE_ERROR` | no | product not licensed |
| `VALIDATION_ERROR` | no | numeric or content mismatch |
| `SIMULATION_ERROR` | no | solver error |
| `CODEGEN_ERROR` | no | build error |
| `MATLAB_RUNTIME_ERROR` | no | other runtime error |

## Why classifying first is worth the effort

- Retrying `LICENSE_ERROR` or `ENVIRONMENT_ERROR` cannot succeed. The second and
  third attempts produce identical failures and burn the budget that a real fix
  would have needed.
- Retrying `VALIDATION_ERROR` is **worse than useless**: it converts a crisp
  "maxAbs 3.9e-01 exceeds tol 1e-06" into a vague "flaky", and the number that
  would have identified the bug is gone.
- `TIMEOUT` and `MCP_CONNECTION_ERROR` are genuinely transient, so a bounded retry
  is the right response — provided the operation is idempotent.

## Caps and the destructive-operation rule

Retries are capped at **5 attempts**. Beyond that, stop and report: a fifth identical
failure is not a flake, and continuing hides it.

**Non-idempotent or destructive operations — downloads, installs, writes, deployments —
must not be retried without explicit user approval.** The retry, not the first attempt,
is what causes damage: a half-written file, a duplicated dataset, a partially applied
install. When a retry would repeat a write, report and ask instead.

## Distinguishing the three "it ran but the answer is wrong" cases

These are separate problems with separate fixes, and collapsing them into "failed"
is how a real defect survives:

| Symptom | Class | First thing to check |
|---|---|---|
| numbers differ from a golden value | `VALIDATION_ERROR` | the reference itself — is it derived from the code under test? |
| model/simulation aborts | `SIMULATION_ERROR` | solver settings, sample time, algebraic loops |
| build fails after generation | `CODEGEN_ERROR` | unsupported construct; run `mas_codegen_ready` first |

The first row is the one worth internalising: a validation failure whose reference was
computed by the code being validated is not a validation failure. That is how Phase 4's
Butterworth task reported PASS on a number that was 3.9 dB off.