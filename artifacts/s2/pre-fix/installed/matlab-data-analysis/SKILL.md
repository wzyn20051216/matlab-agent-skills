---
name: matlab-data-analysis
description: MATLAB data analysis workflow for tables, timetables, numerical verification, ODE solving, statistics, fitting, uncertainty, error propagation, and reproducible experiments. Use whenever the user asks MATLAB to analyze data, integrate or differentiate numerically, solve or verify ODE solutions, solve or check linear systems, assess convergence and conditioning, clean tables with missing/outlier accounting, fit models, test significance, propagate uncertainty, or reproduce figures and numbers.
---

# MATLAB Data Analysis

Use this skill when the deliverable is a validated number: an integral, a solution vector,
a fit, a p-value, an uncertainty, or a figure whose axis is backed by arithmetic. The
plot is never the evidence.

## Workflow

1. 任务识别 — State the quantity, its units, the tolerance that makes it acceptable, and
   what independent source could contradict it. A claim without a tolerance has no PASS.
2. 能力选择 — `r = mas_route(prompt)`; confirm this skill is primary, then read the
   matching tool contract below instead of the whole toolbox.
3. 环境检查 — `mas_precheck` before toolbox-only APIs (`fitlm`, Statistics Toolbox).
   Missing toolbox degrades the method explicitly; it never silently swaps the method.
4. MATLAB 执行 — build a small reproducible subset first; save intermediate arrays so a
   failing check can be inspected rather than guessed.
5. 独立验收 — grade with the tools below. Every accepted number needs a second route:
   closed form, hand algebra, a different factorization, resampling, or Monte Carlo.
6. 错误恢复 — a `fail`/`UNDETERMINED` is fixed for the named reason (add tolerance,
   improve the reference, raise precision, extend the record) and re-run; it is never
   skipped or relabelled.
7. 结果交付 — report value, tolerance, condition/uncertainty, and verdict. SKIP/BLOCKED
   stays SKIP/BLOCKED.

## Verification tools

```matlab
q = mas_quad_check(@(x) 4./(1+x.^2), 0, 1, struct('value',pi,'tolRel',1e-8, ...
        'method','simpson','n',32,'derivAt',0.5,'derivValue',-2.56));
q.verdict  q.valueErr  q.orders  q.refGap  q.floorI

L = mas_linsolve_check(A, x, b, struct('tolRel',1e-10));
L.verdict  L.backwardError  L.errorBound  L.cond  L.rank  L.routeDiff

c = mas_converge_check(hist, struct('tolFinal',1e-10,'order',2,'rate',0.5));
c.verdict  c.observed.order  c.observed.rate  c.observed.final

r = mas_fit_check(X, y, beta, struct('tolRel',1e-8,'r2',0.98, ...
        'se',se,'holdout',struct('X',Xh,'y',yh)));
r.verdict  r.r2  r.rmse  r.ci  r.betaRef  r.condX

s = mas_stat_check(x, struct('mu0',5,'alpha',0.05,'tail','two-sided'));
s = mas_stat_check(x1, x2, struct('claimDiff',0));          % Welch
s.verdict  s.p  s.ci  s.decision  s.pResample  s.methodAgreement

u = mas_uncert_check(@(p) p(1).*p(2).^2, [2;3], [0.02;0.03], ...
        struct('value',18,'sigma',0.36,'sigmaTolRel',0.05));
u.verdict  u.sigmaLin  u.sigmaMC  u.mcSE  u.sensitivity  u.jacobianMethod

p = mas_repro_check(@() myExperiment(), struct('seed',20261021,'tol',0));
p.verdict  p.sameSeed  p.seedEffect  p.digest  p.diffSameSeed

o = mas_ode_check(@(t,y) [y(2);-y(1)], [0 2*pi], [1;0], struct( ...
        'reference', @(t) [cos(t);-sin(t)], 'refTolRel', 1e-8, ...
        'invariant', @(t,y) y(1)^2+y(2)^2, 'invTolRel', 1e-8, ...
        'finalValue', [1;0], 'finalTolRel', 1e-8));
o.verdict  o.levels  o.error.maxScaled  o.invariant.maxRelDrift  o.stiffness.classified
```

### One error, three denominators: never quote a scaled error without its rule

`o.schema` is `mas-ode-report/2`. The report splits the difference to the reference
into three quantities that differ by orders of magnitude and are **not**
interchangeable:

| field | numerator / denominator | meaning |
|---|---|---|
| `error.maxAbs` | max abs(y_candidate - y_reference) | raw error in state units |
| `error.maxScaled` | maxAbs / max(1, max abs(y_reference)) | fraction of the solution magnitude; this is what `refTolRel` grades and what an answer key means by "scaled error" |
| `error.maxSolverScaled` | maxAbs / (AbsTol + RelTol*abs(y_reference)), elementwise | how many solver tolerances the error is; a *diagnosis* of the solver settings, never an accuracy verdict |
| `error.maxRel` | elementwise abs error / max(abs(y_reference), eps) | per-component relative error; blows up at a zero crossing of an otherwise perfect oscillator |

Each carries `numeratorRule`, `denominatorRule`, `unit` and the aggregation
(`error.at`, `error.component`, `error.rows`, `error.components`), so a number
cannot be separated from the definition that produced it. When no reference
exists the fields are emitted as `NaN` rather than omitted.

A graded claim must name its convention. Comparing a solver-tolerance-scaled
number against a magnitude-scaled key fails a correct answer: Phase 5.5's
H54-ODE-N episode reported 2.66 (solver convention) against a key of 3.3e-10
(magnitude convention) and was graded MISS although both numbers were computed
correctly.

Every tool returns `verdict` (PASS | FAIL | UNDETERMINED) and per-check status
(`pass | fail | na | undetermined`). `na` = the contract does not apply and does not drag
the verdict; `undetermined` = missing evidence or missing criterion and forces
UNDETERMINED. **No acceptance criterion, no PASS.**

## Boundary rules these tools encode

- A claimed integral tolerance below the double-precision floor of the quadrature is
  `undetermined`, not a lucky PASS; two reference routes must agree before the reference
  is used at all.
- Measured order comes from halving `n`, not from the method's name: Simpson on a kink
  measures order 0 and FAILS, while a smooth integrand may measure above nominal because
  the leading error term cancels — the check is one-sided on purpose.
- Backward error (`||b-Ax||/(||A|| ||x||+||b||)`) and forward error (`kappa*eta`) are
  different claims. `hilb(12)` has a residual at the roundoff floor and no certifiable
  digits; the tool says UNDETERMINED.
- Once an iteration reaches `100*eps*max(1,e1)`, order estimates are noise. Fewer than
  three clean estimates give UNDETERMINED, not a fabricated order.
- A row that qualifies for two cleaning rules is counted once, by the first rule; the
  ledger must satisfy `nRowsIn == nRowsOut + nDropped`, or the audit is wrong even when
  the totals look plausible.
- `n <= p` means no residual degrees of freedom: `sigma`, standard errors and CIs are
  `undetermined`, not zero. Rank deficiency means the parameters are not identifiable.
- At `kappa^2*eps >= 1` the QR and normal-equation coefficient routes can differ by more
  than 100 %, so their agreement proves nothing — UNDETERMINED, not a clamped PASS.
- A t-test and its resampling counterpart must agree on the decision before significance
  is claimed; a skewed sample where they disagree is UNDETERMINED by design.
- Complex-step differentiation is verified against central differences; analytical
  functions use complex step, `abs`-like functions fall back and say so. Linear
  propagation that disagrees with Monte Carlo beyond `sigmaTolRel` FAILS.
- Same-seed runs must agree bitwise; an asserted seed dependence that does not appear is
  a FAIL, and the caller's RNG stream must be restored.
- `ode45` exit flag 0 is one level (`solverExit`), never a PASS. A solution is graded on
  separate levels — convergence under refinement, error to an independent reference,
  conserved quantity, stated final state/event — and a run with no acceptance criterion
  is UNDETERMINED even when the solver is happy.
- Stiffness comes from the Jacobian eigenvalue ratio (step ratio only corroborates), not
  from the solver's name. A coarse explicit step over a fast decay exits successfully
  with finite, wrong numbers; errorTol catches it at 1e-4.
- An analytic reference is cross-checked against a tight `ode15s` solve before it is
  used; if the two disagree the tool refuses to grade instead of picking a number.
- Non-numeric table columns are preserved and reported, never silently converted.

Full formulas, worked numbers and negative controls:
`references/data-verification-contract.md`.

## Cleaning that accounts for every row — `mas_table_audit`

```matlab
r = mas_table_audit(T, struct('missing','drop','duplicates','drop', ...
    'outliers', struct('method','iqr','factor',1.5,'action','remove')));
r.balanced    % nRowsIn == nRowsOut + nDropped, each row judged exactly once
r.audit       % per rule: before, after, dropped, filled
r.dropped     % removed rows WITH the rule that removed each one
```

Rule order is part of the contract (missing -> duplicates -> outliers) and is printed,
because changing it changes the counts. Fill must drop nothing and report `nFilled`;
an empty table is balanced at zero and a non-table is an error. Tests:
`tests/test_table_audit.m` (11/11).

## Legacy toolbox APIs

- Tables: `readtable`, `readtimetable`, `groupsummary`, `rowfun`, `varfun`,
  `synchronize`, `retime`.
- Fits: `fitlm`, `fitnlm`, `fitrgp`, `fitcsvm` only after `mas_precheck`.
- Constrained fitting: `optimproblem` / solver APIs when regression is not enough.
- Export figures with explicit size, resolution and format.

## Reproducible experiments

Record the seed, the split policy, the data provenance (file hash or URL), the MATLAB
version, and the tolerance used for acceptance. `mas_repro_check` produces the digest and
the same-seed/other-seed differences; cite them in the delivery instead of saying
"results are reproducible".

## Validation outside the tools

```matlab
assert(height(T) > 0)
assert(all(isfinite(metrics.rmse)))
assert(abs(integralValue - pi) < 1e-8)
```

These are smoke checks. They complement the contract tools; they do not replace them.

Tests: `tests/test_data_contract.m` (118/118), `tests/test_ode_contract.m` (56/56) and
`tests/test_table_audit.m` (11/11).
Every expected value comes from hand algebra, a closed form, a second numerical route, or
MATLAB's independent implementation — never from the code under test.
