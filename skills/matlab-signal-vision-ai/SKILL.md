---
name: matlab-signal-vision-ai
description: MATLAB workflow for signal processing, DSP, image processing, computer vision, lidar, medical imaging, deep learning, and AI-assisted reproducible experiments. Use for filters, spectrograms, wavelets, object detection, segmentation, classification, training, inference, generated figures, and for verifying signal or vision results — units, windows, Nyquist, filter response, BER/SNR, masks and boxes, IoU/precision/recall/F1, label alignment, transform invertibility, and split leakage.
---

# MATLAB Signal Vision AI

Use this skill when the core artifact is a processed signal, image, video, point cloud, neural network, or AI experiment.

## Workflow

1. 任务识别 — Identify data modality, sampling rate, image size, color space, labels, expected outputs. State the units (Hz vs rad/s), the analysis window, and whether the claim is steady-state or transient.
2. 能力选择 — `r = mas_route(prompt)`; confirm this skill is primary and read the routed tool contract, not the whole toolbox.
3. 环境检查 — confirm toolbox availability (`mas_precheck`) before specialized APIs; a missing toolbox degrades the capability, it does not silently change the method.
4. MATLAB 执行 — build a tiny reproducible subset first; save intermediate outputs so failures are inspectable.
5. 独立验收 — grade with the measurement tools below, never by the figure. Reference values must come from outside the code under test (closed form, hand algebra, a second route).
6. 错误恢复 — a `fail` or `UNDETERMINED` is re-run with the specific fix (longer record, stated window, independent truth) and the attempt is recorded; it is not skipped.
7. 结果交付 — report numbers with units, window, regime and interval. SKIP/BLOCKED is never rewritten to PASS.

## Preferred APIs

- Signal: `designfilt`, `kaiserord`, `butter`/`buttord`, `fir1`, `filter`, `freqz` (always pass `fs` when you mean Hz), `spectrogram`, `pwelch`, `findpeaks`, wavelet functions.
- Vision: `imread`, `im2gray`, `imresize`, `imbinarize`, `regionprops`, `detectSURFFeatures`, `bboxOverlapRatio`.
- Deep learning: `dlnetwork`, `trainnet`, datastores, `minibatchqueue`, pretrained models when licensed.
- Lidar/medical imaging: use domain importers and viewers when available; keep metadata.

## Measurement tools

```matlab
c = mas_measure_contract(x, fs, struct('freq',struct('value',50,'unit','Hz'), ...
        'rms', 0.707, 'expected', struct('value', 0.5, 'tolRel', 1e-2)));
c.verdict  c.checks  c.ci  c.freqHz  c.freqRadPerSec  c.powerLinear  c.powerDb
f = mas_filter_check(b, a, struct('fs',1000,'type','lowpass','fpass',100,'fstop',250,'astopDb',40));
f.verdict  f.achieved.stopbandDb  f.achieved.groupDelaySamples  f.achieved.maxPoleMag
s = mas_sample_check(x, fs, struct('fMax',200,'truth',struct('f',@(t) sin(2*pi*150*t))));
s.verdict  s.measured.fPeak  s.measured.aliasFoldHz  s.measured.reconRelErr
g = mas_ber_check(588, 262144, struct('scheme','QPSK','ebn0dB',6));
g.verdict  g.z  g.berMeasured  g.berTheory  g.ci
```

Every tool returns `verdict` (PASS | FAIL | UNDETERMINED) and per-check status
(`pass | fail | na | undetermined`). `na` = the contract does not apply; it does
not drag the verdict. `undetermined` = missing evidence or missing criterion and
forces UNDETERMINED: no acceptance criterion, no PASS.

Boundary rules these tools encode (each one a paid-for defect):

- `rms <= peak` for ANY signal; ratio ~sqrt(2) means sinusoid, ratio ~1 does not.
- dB power is `10*log10`; an applied `20*log10` is a factor-2-in-dB error, and -3.01 dB IS 0.5.
- The windowed periodogram power identity `sum(x.^2.*w.^2)/sum(w.^2)` is not `mean(x.^2)`; the gap is taper bias, not a scaling bug.
- Stopband = WORST over the whole band, not the value at `fstop`: a comb null reads 61.8 dB at its token point and 11.3 dB where it actually matters.
- Linear phase is graded only for symmetric/antisymmetric FIR; an IIR is `na`, not `fail`, when the spec never asked.
- Nyquist: the fold location is printed; a spectrum can confirm content below the claim but can never rule out content above `fs/2`.
- BER is graded by z-score against counting noise; zero errors certify an upper bound only; tolerances follow the error count, not taste.
- A frequency confidence interval is quoted only when blocks hold >= 10 cycles of the tone; below that the tool refuses a tight-and-wrong interval.

Full contract, worked examples, negative controls: `references/signal-measurement-contract.md`.

## Vision verification tools

```matlab
s = mas_seg_check(predMask, trueMask, struct('iouThreshold',0.5, ...
        'thresholdSource','validation', ...
        'metrics', struct('name','f1','value',0.82,'tolRel',1e-3)));
s.verdict  s.metrics.f1  s.perClass  s.objects  s.objectMetrics  s.thresholdSweep

d = mas_detect_check(gtBox, gtLab, predBox, predLab, scores, struct( ...
        'iouThreshold',0.5,'imageSize',[480 640], ...
        'scoreThreshold',0.3,'scoreThresholdSource','validation', ...
        'metrics', struct('name','f1','value',0.75,'tolRel',1e-3)));
d.verdict  d.metrics  d.perClass  d.matches  d.scoreSweep

v = mas_image_contract(I, struct('expectedSize',[256 256 3], ...
        'expectedClass','uint8','expectedRange',[0 255],'labels',L, ...
        'normalization', struct('original',I0,'inverse',@inv), ...
        'transform',T,'points',P,'pointsTransformed',Q, ...
        'edgeMap',E,'edgeTruth',E0,'edgeF1Min',0.9, ...
        'split', struct('trainIdx',tr,'valIdx',va,'sampleHash',h)));
v.verdict  v.image  v.labels  v.normalization  v.transform  v.edge  v.split
```

- Pixel accuracy is not segmentation quality: 95 % background scores 95 % accuracy while
  finding nothing. Per-class values are always reported, and an accuracy-only claim on
  imbalanced data is UNDETERMINED.
- Pixel IoU is not object IoU. Objects are matched one-to-one at an EXPLICIT IoU
  threshold; a second prediction on one object is a false positive, and an object-metric
  claim without a stated threshold is UNDETERMINED.
- Empty conventions are stated, never 0/0-as-good: empty prediction vs empty truth is a
  perfect match by convention; empty truth with predictions is IoU 0.
- A score/binarization threshold tuned on the set being reported is a leak (`test` fails,
  no stated source is UNDETERMINED). A metric without a tolerance is not a criterion.
- Detection AP is all-point interpolated per class; mAP averages only classes with GT. A
  predicted label missing from the GT set raises a label-alignment warning, because a
  name-mapping bug looks exactly like an invented class.
- Image checks are numeric: size/dtype/range, label alignment, normalization round-trip,
  invertible affine geometry, edge/feature agreement with an independent truth within a
  pixel tolerance, and split leakage by index AND content hash AND group.
- "The picture looks right" is never a criterion; a missing truth or criterion is
  UNDETERMINED.

Full contract: `references/vision-verification-contract.md`.

## Legacy metrics tools

```matlab
r = mas_spectrum_check(x, fs, struct('window','hann','nfft',[]));
r.leakage  r.cycles  r.concentration  r.parsevalErr  r.taperBias  r.warnings
o = mas_ofdm_ber([0 2 4 6]);   o.berSim  o.berTheory  o.relErr  o.verdict
m = mas_image_metrics(predMask, trueMask);
m.iou  m.dice  m.precision  m.recall  m.perObject  m.objectIouWorst
s = mas_split_seed(labels, struct('trainFrac',0.7,'seed',0,'stratify',true));
s.trainIdx  s.valIdx  s.noOverlap  s.noGap  s.reproducible  s.classBalance
```

What they pin:

- `mas_spectrum_check`: a half-bin offset drops concentration 1.000 -> 0.408 (measured); Parseval is tested against the window-weighted identity, taper bias reported separately.
- `mas_ofdm_ber`: two-sided against `0.5*erfc(sqrt(Eb/N0))` — a BER below theory is a failure (noise too small), and the CP penalty belongs at the transmitter (receiver-side application shifts 0 dB BER 0.0786 -> 0.102).
- `mas_image_metrics`: per-object matching by argmax over truth labels, not by index; a mask with the right area in the wrong place must score IoU 0.
- `mas_split_seed`: `noOverlap`/`noGap`/`reproducible` asserted; `classBalance` is a number to read, not a boolean to trust.

## Validation

Choose relevant checks beyond the tools:

- Image dimensions, pixel range, mask area, IoU, accuracy, F1.
- Training loss decreases on a smoke subset.
- Inference output has expected class names, boxes, or mask shape.
- Exported figure or video is nonempty — necessary, never sufficient.

## Reproducibility

Record random seed, split policy, pretrained model version, GPU availability, and dataset hash or URL.

Tests: `tests/test_signal_vision.m`, `tests/test_signal_contract.m` (42/42) and
`tests/test_vision_contract.m` (103/103) — every metric carries a negative control, and
expected values come from hand algebra, closed forms or MATLAB design generators, never
from the code under test.