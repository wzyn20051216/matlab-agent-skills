---
name: matlab-signal-vision-ai
description: MATLAB R2026a workflow for signal processing, DSP, image processing, computer vision, lidar, medical imaging, deep learning, and AI-assisted reproducible experiments. Use for filters, spectrograms, wavelets, object detection, segmentation, classification, training, inference, and generated figures.
---

# MATLAB Signal Vision AI

Use this skill when the core artifact is a processed signal, image, video, point cloud, neural network, or AI experiment.

## Workflow

1. Identify data modality, sampling rate, image size, color space, labels, and expected outputs.
2. Confirm toolbox availability before using specialized APIs.
3. Build a tiny reproducible subset first.
4. Save intermediate outputs so failures are inspectable.
5. Validate with numerical metrics, visual artifacts, and data shape checks.

## Preferred APIs

- Signal: `designfilt`, `filter`, `spectrogram`, `pwelch`, `findpeaks`, wavelet functions.
- Vision: `imread`, `im2gray`, `imresize`, `imbinarize`, `regionprops`, `detectSURFFeatures`, `bboxOverlapRatio`.
- Deep learning: `dlnetwork`, `trainnet`, datastores, `minibatchqueue`, pretrained models when licensed.
- Lidar/medical imaging: use domain importers and viewers when available; keep metadata.

## Validation

Choose relevant checks:

- Signal-to-noise ratio, peak frequency, filter stability.
- Image dimensions, pixel range, mask area, IoU, accuracy, F1.
- Training loss decreases on a smoke subset.
- Inference output has expected class names, boxes, or mask shape.
- Exported figure or video is nonempty.

## Reproducibility

Record random seed, split policy, pretrained model version, GPU availability, and dataset hash or URL.

## Tools

```matlab
r = mas_spectrum_check(x, fs, struct('window','hann','nfft',[]));
r.leakage  r.cycles  r.concentration  r.parsevalErr  r.taperBias  r.warnings
o = mas_ofdm_ber([0 2 4 6]);   o.berSim  o.berTheory  o.relErr  o.verdict
m = mas_image_metrics(predMask, trueMask);
m.iou  m.dice  m.precision  m.recall  m.perObject  m.objectIouWorst
s = mas_split_seed(labels, struct('trainFrac',0.7,'seed',0,'stratify',true));
s.trainIdx  s.valIdx  s.noOverlap  s.noGap  s.reproducible  s.classBalance
```

### A spectrum is only trustworthy after two checks

`mas_spectrum_check` runs both, because a spectrum can be wrong while looking
completely normal:

- **Fractional cycles.** A tone at exactly bin k puts 100 % of its energy in one
  bin; half a bin off it concentrates **0.408** (measured). The peak drops, the
  noise floor rises, and any THD or SNR read off it is wrong. Reported as
  `leakage` = low / HIGH / UNKNOWN from the measured fractional cycle count.
- **Power that does not add up.** For a windowed periodogram the integral of the
  one-sided PSD is identically `sum(x.^2.*w.^2)/sum(w.^2)` — **not** `mean(x.^2)`.
  The first version compared against `mean(x.^2)` with a 1e-6 threshold and failed
  every noisy record: 7.3e-3 (Hann), 6.7e-3 (Hamming), 9.0e-3 (Blackman), while the
  same signal with a rectangular window agreed to 5.3e-16. That spread is the taper
  re-weighting the noise realisation — estimator variance, not a scaling bug. Now
  `parsevalErr` is tested against the identity it is equal to (tolerance 1e-8, so it
  holds to machine precision), and the window's own effect is reported separately as
  `taperBias`, which is information about the taper rather than an error.

Concentration is measured on the **un-padded rectangular** DFT: zero padding makes a
tone land between bins, and a Hann display window spreads energy over three bins by
design. Neither is leakage in the record, but both corrupted the metric in v1.

### OFDM: the reference is independent of the code

`mas_ofdm_ber` grades against the closed form `0.5*erfc(sqrt(Eb/N0))`, which has
nothing to do with the IFFT/FFT chain it is testing. The check is deliberately
**two-sided**: a BER well below theory is not a success, it means the noise variance
is too small. Tolerance is 15 % because at 6 dB over 2^18 bits the counted errors
carry ~4 % relative sampling noise, and the defect the check exists to catch —
applying the CP penalty at the receiver instead of at the transmitter — shifts BER by
~30 % (0.102 vs 0.0786 measured at 0 dB). The CP samples are discarded at the
receiver, so the noise in them goes with them; the penalty is a transmit power
penalty only.

### Pixel metrics do not prove the objects are right

`mas_image_metrics` returns the confusion matrix, the aggregate metrics, and
`perObject`: each predicted blob matched to the truth blob it overlaps most. Matching
is by argmax over all truth labels, **not by index** — `bwlabel` numbers blobs in
raster scan order, so `Lp == k` has no correspondence to `Lt == k` once the masks
disagree, which is exactly when the number matters. The test asserts that a prediction
with the correct total area in the wrong place scores **IoU = 0**, so the metric cannot
degenerate into an area tally. 0/255 `uint8` masks are converted with `~= 0`; empty
prediction against empty truth is IoU = 1, not NaN, so averaged scores survive.
`perObject` is empty when Image Processing Toolbox is unavailable — degraded
capability is reported, not hidden.

### Splits: three cheap checks

`mas_split_seed` returns `noOverlap`, `noGap` and `reproducible` as asserted
booleans (a row in both sets inflates validation accuracy; a rounding rule that
leaves a class empty silently rebalances the problem), plus `classBalance` with the
achieved per-class fraction, because per-class rounding can differ from the target by
up to `0.5/n_c` and that is a number to look at rather than a boolean to trust.

`tests/test_signal_vision.m` — 32 cases, each graded against a value that does not come
from the code under test, with a negative control for every metric that could pass
vacuously.
