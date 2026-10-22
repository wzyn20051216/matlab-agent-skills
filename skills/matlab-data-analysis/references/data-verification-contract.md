# Data Verification Contract

This reference explains what each `mas_*_check` tool actually verifies, the formula it
uses, and the situation in which it must refuse to answer. The tools exist because the
dangerous failure in numerical data analysis is not a crash — it is a number that looks
plausible, is printed with ten significant digits, and is wrong. A plot, a converged
solver, or an agent's own arithmetic cannot grade that number. Only an independent route
can.

## The four-state check model

Every tool returns `r.verdict` (`PASS` | `FAIL` | `UNDETERMINED`) and `r.checks`:

| status | meaning | effect on verdict |
|---|---|---|
| `pass` | the check ran and the claim/number met the criterion | none |
| `fail` | the check ran and the claim/number is wrong | forces FAIL |
| `na` | the contract does not apply (e.g. no derivative claim was made) | does not drag |
| `undetermined` | the evidence or the criterion is missing (no tolerance, reference not trustworthy, condition too high) | forces UNDETERMINED |

The precedence is: any `fail` -> FAIL; else any `undetermined` -> UNDETERMINED; else
PASS. `undetermined` is not a soft failure and is never rewritten to PASS. "No
acceptance criterion, no PASS" is the rule that makes the verdict meaningful: a value
with no stated tolerance has nothing to be tested against, so the tool says so instead
of inventing a tolerance.

## 1. Numerical integration and differentiation — `mas_quad_check`

```matlab
r = mas_quad_check(f, a, b, struct('value', pi, 'tolRel', 1e-8, ...
    'method', 'simpson', 'n', 32, 'derivAt', 0.5, 'derivValue', -2.56));
```

What it does:

- **Reference by two independent routes.** The claimed integral is compared against
  `integral` (adaptive Gauss-Kronrod) and against `quadgk` where available. `refAgreement`
  requires the two routes to agree to within `refQuality = max(refGap, 10*eps*refScale)`.
  If they disagree by more than the claimed tolerance, the reference is not good enough
  and `valueVsRef` is `undetermined` — a correct claim can fail against a bad reference.
- **Tolerance achievability.** The roundoff floor of the integral is
  `floorI = 100*eps*max(|a|,|b|)*max(1,|I|)` (roughly). A claimed tolerance below that
  floor is `undetermined` with an explicit message: no quadrature can certify digits
  that are below double precision. Example: trapezoid on a smooth function cannot support
  `1e-12` — the tool reports the floor rather than a lucky pass.
- **Measured order, not assumed order.** With `n` and `2n` (and `4n`) evaluations, the
  error ratio estimates the observed convergence order `p = log2(e_n / e_2n)`. This is
  the check that catches "Simpson" code that is actually a rectangle rule. The test is
  one-sided (`p >= expP - 0.25`) because a higher observed order is not a defect — the
  leading error term can cancel for a particular integrand (for `4/(1+x^2)` Simpson
  measured 6.0 instead of 4.0, exactly because the h^4 term vanishes). A *lower* order
  (kink, wrong weights) still fails. Simpson on `|x-1/3|` measures 0.0000 and fails.
- **Derivative verification.** A central-difference estimate at `derivAt` is compared to
  the claimed `derivValue` with `derivTolRel`; the observed difference order is reported.
  A complex-step or analytic derivative can be supplied; the point is that the claim is
  checked against a second numerical route, not against itself.

Refuses to answer when: no `value` and no `derivValue` claim (nothing to grade); the
reference routes disagree beyond the claimed tolerance; the claimed tolerance is below
the roundoff floor.

## 2. Linear systems — `mas_linsolve_check`

```matlab
r = mas_linsolve_check(A, x, b, struct('tolRel', 1e-10, 'xTrue', xt));
```

The distinction that matters is **backward error vs forward error**:

- `eta = ||b - A*x|| / (||A||*||x|| + ||b||)` (with the exact-zero branch `eta = 0`,
  otherwise denominator zero gives `Inf`). This is the normwise backward error; it is
  the quantity a stable solver controls, and it is graded against `10*n*eps`.
- `kappa = cond(A)` from `svd`. The forward error bound is `kappa * eta`. A solver can
  be backward stable and still deliver a solution with no correct digits when `kappa` is
  `1e16`; reporting `eta` alone hides that.
- **Certification** is `kappa*eta <= tolRel`. When `tolRel` is absent the check is `na`
  (the solution is still graded by the residual), not PASS.
- **Independent route.** `xQr = R\(Q'*b)` from a QR factorization is computed and
  compared with the submitted `x`; the threshold is
  `max(1e-9, 1000*eps*kappa)`. Two factorizations that disagree by more than the
  conditioning allows means the solution is not determined to the claimed accuracy.
- `xTrue`, when supplied, gives a relative forward error, but only after the conditioning
  gate: a large error at `kappa = 1e16` is expected, not a code defect.

Observed grounding: `hilb(12)` gives `kappa = 1.634e16` and an error bound around 1.0 —
the tool returns UNDETERMINED because no tolerance can be certified there, even though
the residual is at the roundoff floor.

Shape errors (row `b`, row `x`, dimension mismatch) throw rather than silently
transposing: a column/row mix-up changes the problem and must not be reinterpreted.

## 3. Iterative convergence — `mas_converge_check`

```matlab
r = mas_converge_check(hist, struct('tolFinal', 1e-10, 'order', 2, 'rate', 0.5));
```

`hist` is the sequence of errors (or residuals, if `claims.isError` says so). At least
one of `tolFinal`, `order`, `rate` is required; with none there is no claim and the call
is an error, not a PASS.

- Non-finite values in the history mean divergence -> FAIL. A negative value when errors
  were expected is an input error -> throw.
- `floorE = 100*eps*max(1, e1)`. Once the sequence reaches the floor, further error
  ratios are meaningless — estimating order from roundoff noise is how a converged
  method gets accused of stalling. Estimates are only formed from triples above the
  floor.
- **Order**: `p = log(c/b)/log(b/a)` for consecutive errors; the median over all valid
  triples plus the last three estimates and their spread are reported. A claim is graded
  only when there are at least 3 estimates and the spread (MAD) is at most 0.5;
  otherwise `undetermined` (the measurement is too noisy to support or refute).
  Tolerance is `max(0.30, 0.15*|claimed|)`.
- **Rate**: linear convergence is graded by `observed <= claimed*1.1`. A method claiming
  rate 0.5 that measures 0.9 fails; bisection should measure ~0.5.
- `tolFinal`: the last error must be at or below the claimed final tolerance. If the
  floor prevented reaching it, the check is still graded against the floor — a converged
  method that hit the floor is `pass` for a tolerance above the floor, and `fail` if it
  stalled above the requested tolerance.

Observed grounding: Newton on `sqrt(2)` measures order 1.9998 with tail
`[2.258 1.984 2.000]` (PASS); a stagnating sequence and a divergent sequence both FAIL;
a history that reaches the floor before three clean estimates is UNDETERMINED.

## 4. Data cleaning — `mas_table_audit`

This tool is the row ledger. The contract is the balance identity

```
nRowsIn == nRowsOut + nDropped
```

and every removed row carries exactly one reason, claimed by the first rule that matches
in the fixed order **missing -> duplicates -> outliers**. A row that is both a duplicate
and an outlier is counted once, as a duplicate. Without that rule the audit *looks*
consistent — `40 in, 30 out, dropped 3+2+2` adds up — while one row was judged twice and
another was never judged at all.

- `missing`: `drop` removes rows with any missing value; `fill` replaces them and drops
  nothing (`nFilled` is reported). A fill rule that silently drops rows breaks the
  balance and is caught.
- `duplicates`: keyed by `dupKeys`; `keep`/`drop`/`flag` decide the action.
- `outliers`: `iqr` with a `factor` (default 1.5), or `zscore`; `remove` or `flag`.
  The outlier test runs only on rows that survived the previous rules.
- Non-numeric columns are preserved and listed in `typeWarnings`; they are never
  silently converted (a categorical column that becomes `NaN` is a data loss).
- Empty tables and non-table inputs are handled deliberately: empty is balanced with
  zero rows; a non-table is an error, not an empty audit.

Tests: `tests/test_table_audit.m` (11/11), including the double-qualified row.

## 5. Regression and fitting — `mas_fit_check`

```matlab
r = mas_fit_check(X, y, beta, struct('tolRel', 1e-8, 'r2', 0.98, ...
    'se', se, 'ciLo', lo, 'ciHi', hi, 'holdout', struct('X', Xh, 'y', yh)));
```

The fit is recomputed, never trusted:

- `betaRef = X\y` (QR). `coeffAgree` compares the submitted `beta` to it. The threshold
  is `max(tolBeta, 10*kappa^2*eps)`, but only when `kappa^2*eps < 1`. At worse
  conditioning the two routes can differ by more than 100 %, so agreement proves nothing
  and the check is `undetermined` — the honest answer instead of a clamped threshold that
  would always pass.
- `rank`: a rank-deficient design means the parameters are not identifiable; coefficients
  are then `undetermined` regardless of how small the residual is.
- `orthogonality`: `||X'r|| / (||X||*||r||)` against `max(1e-8, 10*kappa*eps)`.
- `residualMean`: only meaningful with an intercept; the tool checks for a column of ones.
- `dof`: requires `n > p`; an interpolating fit has zero residual degrees of freedom,
  so `sigma`, `se` and CIs are `undetermined` — they are not zero, they do not exist.
- `metrics`: `r2`, `adjR2`, `rmse`, `sse`, `sigma` are recomputed and compared with
  claimed values at relative tolerance `1e-6`.
- `paramSeVsClaim`: `Cov = sigma^2 * (Ri*Ri')` from the QR factor, gated at `kappa <= 1e8`.
  The hand route and the toolbox route must agree; a mismatch means one of them is wrong.
- Confidence intervals use the t quantile computed from the incomplete beta function
  (no Statistics Toolbox needed):
  `t = sqrt(nu*(1-x)/x)` where `x = betaincinv(2*(1-p), nu/2, 0.5)`.
  Checked against `t_{0.975,8} = 2.30600413520417`.
- `holdout`: when supplied, the RMSE on held-out data is recomputed from `beta` and
  compared with `holdoutRmse`. A model that fits the training data and is wrong on
  holdout fails here, not in prose.

Refuses to answer when: `n <= p` (dof), rank deficiency, conditioning above the gate,
no residual variance. In each case the reason is printed.

## 6. Significance and confidence intervals — `mas_stat_check`

```matlab
r = mas_stat_check(x, struct('mu0', 5, 'alpha', 0.05, 'tail', 'two-sided'));
r = mas_stat_check(x1, x2, struct('claimDiff', 0, 'alpha', 0.05));  % Welch
```

- One-sample: t statistic, two-sided p from
  `p = betainc(nu/(nu+t^2), nu/2, 0.5)` (base MATLAB, no toolbox), CI from the t
  quantile above.
- Two-sample: **Welch** by default (unequal variances), with the Welch-Satterthwaite
  degrees of freedom `nu = (s1²/n1 + s2²/n2)² / (...)`; a pooled-variance claim is
  accepted only if it agrees with the Welch result at the stated tolerance.
- **Independent p-value route.** The parametric p is compared with a resampling p:
  - one-sample, `n <= 14`: exact sign-flip enumeration over all `2^n` sign patterns
    (deterministic, no RNG);
  - one-sample, larger `n`: 5000 seeded sign-flip draws (seed 20261021, RNG restored);
  - two-sample: 5000 seeded label permutations.
  If the parametric and resampling decisions disagree, `methodAgreement` is
  `undetermined` and the message says "do not claim significance". This is exactly the
  check that stops a t-test from being reported as significant on a skewed sample where
  the sign-flip test retains the null.
- `claimP` compares the claimed p with the computed p at `pAbsTol` (default 1e-3);
  `claimCI` compares both endpoints; `claimMean`/`claimDiff` compare the statistic.
  At least one claim is required; unknown `tail` or `decision` values are errors, not
  silent defaults.
- A zero-variance sample gives `undetermined` (the t statistic is 0/0); an incomplete
  sample (NaN) FAILS — dropping the NaN silently changes the mean, and the tool prints
  both the filtered mean and the claimed one.
- `decision` is graded against the computed p at `alpha`; a claim of significance when
  p > alpha fails.

Observed grounding: the skewed-sample fixture has t-test p = 0.00246 (rejects) but
sign-flip p = 0.0186 with n=9 — the decisions can disagree, and the tool refuses to let
either be called significant without qualification. For the fixture used in the tests,
t retains and the exact sign-flip rejects (p = 0.03125); `methodAgreement` returns
`undetermined` by design, and the test asserts that status rather than a verdict.

## 7. Error propagation — `mas_uncert_check`

```matlab
r = mas_uncert_check(@(p) p(1).*p(2).^2, [2; 3], [0.02; 0.03], ...
    struct('value', 18, 'sigma', 0.36, 'sigmaTolRel', 0.05));
```

- **Jacobian**: complex-step differentiation `Im(f(x+i*h))/h` with `h = 1e-20`, verified
  against central differences. For non-analytic functions (e.g. `abs`), complex step is
  invalid and the tool falls back to central differences — and reports which route was
  used (`r.jacobianMethod`). This is the check that prevents an `abs` function from
  producing a silently wrong derivative.
- **Linear propagation**: `sigmaLin = sqrt(sum((J.*sigma).^2))`; this is the first-order
  answer and is valid only for small relative uncertainties.
- **Monte Carlo**: `nMC` draws (default 10000) with the seed recorded and the RNG
  restored afterwards. `sigmaMC`, its standard error `seS = sigmaMC/sqrt(2*(N-1))`, a
  95 % interval, and the bias `mean(f(x+dx)) - f(x0)` are reported.
- **Nonlinearity gap**: when `sigmaMC` differs from `sigmaLin` by more than
  `sigmaTolRel`, the linearized claim fails; the tool states that the linearization is
  the problem, not the arithmetic.
- `mcPrecision`: if `3*seS > tol*sigmaMC`, the Monte Carlo itself is too noisy to
  certify the claim — `undetermined`, not PASS. (A fixed seed makes the run reproducible
  but does not make it precise.)
- The sensitivity table (`r.sensitivity`, one row per input) shows which input dominates;
  this is the actionable part of an uncertainty budget.
- Input length mismatches and negative sigmas are errors. Correlated inputs are a stated
  limitation, not a silent assumption: the tool says the propagation assumes independence.

## 8. Reproducibility — `mas_repro_check`

```matlab
r = mas_repro_check(@() myExperiment(), struct('seed', 20261021, 'tol', 0));
```

- Runs the function three times: seed `s`, seed `s` again, seed `s+1`, restoring the
  caller's RNG stream on exit (`onCleanup`).
- `sameSeed`: the two runs at seed `s` must agree bitwise when `tol = 0`, or within `tol`.
  This catches hidden global state, unseeded `rand`, hash-order dependence, and
  time-dependent behavior.
- `seedEffect`: when `expectSeedDependence` is asserted, the run at `s+1` must differ.
  A stochastic experiment whose result does not change with the seed is suspicious —
  either the randomness is unused or the seed is not wired in. When not asserted, the
  check is `na` and only the measured difference is reported.
- `digest`: SHA-256 of the numeric result (via Java `MessageDigest`), so two runs can be
  compared without storing the payload.
- Non-numeric return values are rejected; structs, cells and objects need an explicit
  numeric projection, because "equal structs" hides which field actually changed.

The RNG restoration is itself tested: after the tool returns, a stream initialized with
`rng(5)` must produce the same values as before the call.

## Cross-tool rules

- Every tool accepts a struct of claims; an empty/absent claim is `na` or an error, never
  an automatic PASS.
- Every tool reports `nChecks`, `nPass`, `nFail`, `nUndetermined`, `nNa` and a one-line
  `detail`; the counts are tested to add up to `nChecks`.
- Reference values in the tests come from hand algebra, closed forms, a second numerical
  route, or MATLAB's own independent implementation — never from the tool under test.
- A missing tolerance, a bad reference, or an unidentifiable model produces
  UNDETERMINED. This is deliberate: the failure mode being prevented is false
  confidence, not a missing answer.

Tests: `tests/test_data_contract.m` (118/118) and `tests/test_table_audit.m` (11/11).
