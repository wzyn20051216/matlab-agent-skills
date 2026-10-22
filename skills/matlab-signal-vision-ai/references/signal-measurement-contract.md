# Signal Measurement Contract (MATLAB DSP / comms)

Purpose: stop reporting a plotted or computed number as a verified measurement.
This reference is loaded only when a signal measurement is being judged:
spectra, filters, sampling chains, BER.

## 0. The one rule

数据能画图不等于测对了. An FFT that renders a pretty peak proves only that FFT
ran. A number is not a measurement until its **units, window, regime and
uncertainty** are stated -- and each is then checked against the record, not
against itself. A missing criterion is `UNDETERMINED`, never `PASS`.

## 1. Units and conventions

| Dimension | Correct form | The trap |
|---|---|---|
| Frequency | `w = 2*pi*f`; every frequency reported as both `f` (Hz) and `fRadPerSec` | `freqz(b,a,w)` without `fs` means rad/**sample**; `freqz(b,a,250,1000)` reads 250 as the point count n, not 250 Hz. A 628 rad/s claim where 628 Hz was meant is caught by the Nyquist check. |
| Power | dB conversion is `10*log10` for power | `20*log10` applied to a power value is a factor-2-in-dB error; -3.01 dB IS 0.5 linear (a correct claim is routinely negative). |
| Amplitude | RMS vs peak; `rms <= peak` holds for ANY signal | swapped labels -- nothing else violates the inequality. Ratio ~sqrt(2) is consistent with a sinusoid; ratio ~1 is not one signal. |
| Energy per bit | `Es/N0 = Eb/N0 + 10*log10(k)` | at k = 2 the gap is 3.01 dB; a BER table read against "SNR" labelled Es but computed as Eb shifts every point. |

## 2. Record and analysis window

- Windowed periodogram power identity: `sum(x.^2.*w.^2)/sum(w.^2)` -- **not**
  `mean(x.^2)`. The gap between the two is the taper re-weighting the noise
  (measured 7.3e-3 Hann / 6.7e-3 Hamming for a noisy record), estimator
  variance, not a scaling bug. `mas_measure_contract` compares a power claim
  against BOTH values and reports which one matched: a claim made with a
  different window lands in neither.
- Leakage: a tone at a bin boundary concentrates **0.408** of its energy
  (measured) instead of 1.000; `leakage = HIGH` makes time-domain-derived
  metrics unreadable and switches the relevant checks to `fail`/`undetermined`
  rather than grading a noisy peak.
- A claim must state its window; the default assumption (`hann`) is recorded in
  `r.claimWindow`, never silently substituted.

## 3. Steady vs transient

- `regime = 'steady'` (default): the record must be stationary at the stated
  confidence -- first-half vs second-half block powers, two-sample t screen
  with the **exact** t table for 95% and nu <= 15 (the Cornish-Fisher closed
  form is 4% low at nu = 3, which makes a correct record fail ~1 run in 20).
  Drift beyond the limit is printed as a `fail` with both half-powers.
- `regime = 'transient'`: stationarity is deliberately not asserted
  (`status = na`); a note warns that whole-record spectra mix the transient.
  The rest of the contract still applies.

## 4. Confidence intervals

- Power: block t-interval (default 12 blocks) -- every PASS carries one.
- Frequency: quoted only when each block holds >= 64 samples AND >= 10 cycles
  of the measured tone. With 83 samples per block (4.15 cycles of a 50 Hz
  tone) per-block peaks averaged **48.58 +/- 0.13 Hz for a 50.00 Hz signal** --
  tight and wrong at the same time. Below the gate the tool says so instead.
- A record too short for an interval (blocks < 8 samples) is `UNDETERMINED`:
  an uncertainty-free number is not graded as a success.

## 5. Four check states, one funnel

| Status | Meaning | Effect on verdict |
|---|---|---|
| `pass` | verified against the record/reference | -- |
| `fail` | contradicted by the record | FAIL |
| `na` | the contract does not apply (spec states no such requirement) | none |
| `undetermined` | missing evidence or missing criterion | UNDETERMINED |

Verdict: any `fail` -> FAIL; else any `undetermined` -> UNDETERMINED; else
PASS. `na` is only for "not asked for" -- it is never a silent pass, and
`undetermined` is never skipped.

## 6. Filter verification

- Two independent routes: `freqz(b,a,fGrid,fs)` vs direct evaluation of
  `H(z) = sum(b_k z^-k)/sum(a_k z^-k)` at `z = exp(-j 2 pi f/fs)`; must agree
  to 1e-9, else a unit convention is being misused.
- The stopband number is the **worst** response over `[fstop, fs/2]` (or
  `[0, fstop]` for highpass) on a dense grid, with the worst point printed. A
  3-tap comb designed to null 183.07 Hz: 61.79 dB at the token frequency vs
  **11.30 dB** measured at 366.2 Hz -- an edge-only rule certifies the filter,
  worst-over-band fails it against its 40 dB spec. Hand value: the comb's
  minimum is `2/(3*sqrt(6))` -> 11.3033 dB.
- IIR stability = poles strictly inside the unit circle, with the margin
  `1 - max|pole|` printed; a pole at 0.9999 carries a rounding warning.
- Passband ripple is graded only when the spec states `apassDb`; otherwise
  measured and reported as `na`.
- Linear phase: graded only for FIR (a == 1) that is symmetric or
  antisymmetric (types I-IV by length parity); the **measured** group delay
  `-diff(unwrap(angle(H)))/diff(w)` must equal `(N-1)/2` samples. An IIR with
  a symmetric numerator or an asymmetric FIR is not linear-phase and, when the
  spec never asked, is `na` with the measured variation -- not `fail`.

## 7. Sampling chain

- Nyquist vs the **claimed** band, with the fold printed: 300 Hz content at
  fs = 500 appears at `|300-500| = 200` Hz, indistinguishable from a real
  200 Hz signal.
- Asymmetry: the spectrum can CONFIRM content below the claim; it can never
  rule out content above Nyquist -- that is what the fold check is for.
- Reconstruction is graded only against an independent analytic truth, and the
  record is first verified to BE samples of that truth (1e-9); a mismatched
  pair would otherwise grade a reconstruction against the wrong function.
  Bandlimited interpolation is exact for periodic, strictly-below-Nyquist
  signals; for an aliased record the error blows up -- which is the measurement
  of the damage, not an assertion about it. No truth -> `undetermined`
  ("no truth, no pass").

## 8. BER is a count, not an amplitude

- Grade with a z-test against counting noise: `z = (p_hat - p0)/sqrt(p0*(1-p0)/n)`,
  |z| <= 3. A flat tolerance gets both directions wrong: at BER 1e-4 over 1e6
  bits (~100 errors) counting noise is 10% -- slack where it should be tight;
  at 1e-5 (~10 errors) it is 30% -- rejects correct measurements.
- Zero errors certifies only an upper bound `-ln(1-L)/n` (3.0e-6 at 95% over
  1e6 bits), never "BER = 0"; against a 6 dB QPSK theory of 2.4e-3 that same
  zero count is z = -48.9, meaning the noise is SMALLER than the label claims
  -- just as wrong, just as flagged.
- Theory: BPSK/QPSK `0.5*erfc(sqrt(Eb/N0))` exact; 16/64QAM use the standard
  Gray approximation and say so. A run whose CI cannot distinguish the claimed
  SNR from a 2x different one returns `UNDETERMINED` (collect more bits).
- Tolerances come from counting noise, not taste: the frozen S1 reference uses
  20%/20%/45% for 0/4/8 dB because at 8 dB only ~49 errors are counted and the
  Poisson spread is 14% -- a 15% pass mark would reject correct code half the
  time.

## 9. Tool -> dimension map

| Tool | Owns |
|---|---|
| `mas_measure_contract(x, fs, claims)` | units, Nyquist, freq/power/peak/rms agreement with the record, regime, expected-vs-measured, block CIs |
| `mas_filter_check(b, a, spec)` | dual-route response, stability, worst-over-band stopband, ripple, linear-phase group delay |
| `mas_sample_check(x, fs, opts)` | Nyquist margin + fold, peak vs claimed band, reconstruction vs truth |
| `mas_ber_check(nErr, nBits, spec)` | Eb/Es convention, z-test vs theory, Wilson CI, Poisson zero-error bound, resolution |
| `mas_spectrum_check` (legacy) | leakage, concentration, window-weighted Parseval |

## 10. Independent cross-checks used in tests

- Hand algebra: comb null `2/(3*sqrt(6))` -> 11.3033 dB at 366.14 Hz (tool
  agrees to 0.06 Hz); moving-average ripple `20*log10(1/cos(pi*100/1000))` =
  0.4359 dB; worst-over-band on a 20001-point grid 60.1024 vs tool 60.1029 dB
  (diff 4.5e-4).
- Design generators, not the code under test: `kaiserord` orders 37/@5.6533 ->
  60.10 dB vs a 50 dB spec; `buttord` order 7 -> 30.00 dB vs 25 dB.
- Closed forms: `erfc` for QPSK; Wilson interval with literal
  `zq = 1.959963984540054`; `-ln(0.05)/1e6 = 2.9957e-6`.
- Negative controls (every metric that could pass vacuously has one):
  half-bin offset must drop concentration to 0.408; 20log10 power gives 0.25
  where 0.5 is correct; the comb-null filter passes an edge-only rule and must
  fail worst-over-band; a 4 dB record labelled 6 dB must give z ~ +106; zero
  errors against ~2400 expected must give z < -3.
- Never "run the same algorithm twice" and call it independent.

Evidence: `tests/test_signal_contract.m` 42/42, log at
`artifacts/phase53/evidence/task1_contract_tests.log`.