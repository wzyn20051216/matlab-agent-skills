# Stability & Acceptance Contract (MATLAB control)

Purpose: stop reporting a number as an engineering conclusion. This reference is
loaded only when stability, margins, or controller acceptance are being judged.

## 1. Three independent answers

| Dimension | Values | Source |
|---|---|---|
| Mathematical stability | `STABLE` / `UNSTABLE` / `UNDETERMINED` | poles of `feedback(L,1)` + all-crossing frequency evidence |
| Engineering target | `PASS` / `FAIL` / `UNDETERMINED` | PM and GM versus explicit targets |
| Evidence quality | `VERIFIED` / `PARTIAL` / `NOT VERIFIED` | two independent sources agree, or not |

Never infer one from another:

- MATLAB ran successfully does **not** mean the loop is stable.
- A stable closed loop does **not** mean the PM target is met.
- A passing PM target does **not** mean the engineering system is safe.
- Missing evidence is `UNDETERMINED`, never `PASS` and never `FAIL` by default.

## 2. Units and return order (defects G1/G2/G3)

- `[Gm, Pm, Wcg, Wcp] = margin(L)`: `Gm` is an **absolute gain ratio**, not dB;
  `Pm` is degrees; `Wcg` is the frequency where the gain margin is measured
  (phase = -180 deg); `Wcp` is the 0 dB crossover where PM is measured.
  A report in dB must compute `20*log10(Gm)`.
- `allmargin(L).GainMargin` is also an absolute ratio, not dB. This is a common
  source of "20 dB" vs "26 dB" mismatches for sampled loops. Measured here:
  `c2d(10/(s+1),0.01)` has `GainMargin = 20.0002` (ratio) = **26.0207 dB**;
  direct evaluation at `z=-1` gives `|L| = 0.05`.
- Every frequency is exposed twice: `f` (Hz) and `wRadPerSec` (rad/s).
  `r.freqUnit` echoes the unit used for `opts.wmin`/`opts.wmax`.
- A discrete model (`Ts > 0`) must be evaluated at `z = exp(j*w*Ts)`; the
  function does this automatically. Never evaluate a sampled loop on `s`.
- Phase is unwrapped before interpolation and the phase margin is wrapped into
  `(-180, 180]`. Without the wrap, a negative-gain loop reports `+275.7 deg`
  instead of `-84.26 deg`.

## 3. Boundary cases that a single margin misses

| Case | Correct handling |
|---|---|
| Multiple 0 dB crossings | Report every crossing; the worst one is binding. A healthy first crossing does not cancel a negative later one. |
| No 0 dB crossing | PM is undefined (`NaN`); GM may still be finite. Math stability comes from closed-loop poles; target is `UNDETERMINED`. |
| `|L(0)| = 1` | The PM is evaluated at DC. `1/(s+1)` has PM 180 deg, not NaN. |
| Phase = -180 at DC with `|L| > 1` | Negative GM at `w=0` (Nyquist encirclement). `-10/(s+1)` is UNSTABLE even though its 0 dB crossing reads +84 deg by the naive formula. |
| Discrete -180 at `pi/Ts` | GM is evaluated at the Nyquist frequency. An interior search reports `Inf` and hides a finite margin. |
| Double integrator | Closed-loop poles on the imaginary axis. Report `MARGINAL`; the contract maps this to `UNSTABLE` because it is not asymptotically stable. |
| Static gain | No poles is stable; no crossing means target `UNDETERMINED`. |
| Delay | Rational closed-loop poles do not include the delay; closed-loop stability is `UNDETERMINED` and evidence is `PARTIAL`. Frequency margins still decide instability. |
| NaN / Inf coefficients | No usable evidence: `UNDETERMINED` / `NOT VERIFIED`, with a note. Never PASS. |
| Hz/rad-s mixing | Use `opts.freqUnit`; verify `w = 2*pi*f` in the output. |

## 4. Machine-readable contract

`mas_stability_verdict(L, opts)` returns schema `1.0`:

```matlab
r.schemaVersion
r.verdict                 % == r.math.stability
r.math.stability          % STABLE | UNSTABLE | UNDETERMINED
r.math.marginal           % true for a marginally stable loop
r.math.closedLoopStatus   % STABLE | UNSTABLE | MARGINAL | UNDETERMINED
r.target.status           % PASS | FAIL | UNDETERMINED
r.target.pm / gm
r.target.pmStatus / gmStatus
r.target.pmTarget / gmTarget
r.target.reasons          % cellstr
r.evidence.quality        % VERIFIED | PARTIAL | NOT VERIFIED
r.evidence.sources        % independent methods that produced evidence
r.evidence.independent    % true when at least two sources are present
r.evidence.warnings       % cellstr
r.notes                   % cellstr, includes reasons for NaN/Inf/missing data
```

`mas_ctrl_analyze` keeps its legacy fields (`stable`, `pmWorst`, `gmWorst`,
`verdict`, `crossings`) and adds `openLoopStatus`, `closedLoopStatus`,
`closedLoopPoles`, `closedLoopMaxPole`, `evidenceQuality`, `notes`, `freqUnit`,
`gmKnown`, `hasDelay`, and `wRadPerSec` on every crossing.

## 5. Independent cross-checks used in tests

- Closed-loop poles (`pole(feedback(L,1))`) versus frequency margins.
- `margin`/`allmargin` for single-crossing values, with the unit contract above.
- Analytic values: `10/(s+1)` PM = `180 - atan(sqrt(99)) = 95.739 deg`;
  `30/((s+1)(s+2)(s+3))` GM = 2 at `w = sqrt(11)`;
  `c2d(10/(s+1),0.01)` Nyquist GM = `-20*log10(0.05) = 26.0207 dB`.
- Never "run the same algorithm twice" and call it independent.
