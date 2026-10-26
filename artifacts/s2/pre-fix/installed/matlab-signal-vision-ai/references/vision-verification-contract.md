# Vision verification contract

Three tools: `mas_seg_check` (segmentation), `mas_detect_check` (box detection) and
`mas_image_contract` (image data, geometry, preprocessing, splits). They exist because
"the prediction image looks right" is not a criterion: every accepted number has a
stated convention, an independent truth, and a negative control that must fail.

All three return `verdict` (PASS | FAIL | UNDETERMINED) and per-check status
(`pass | fail | na | undetermined`). A missing truth, a missing tolerance, or a missing
matching threshold is UNDETERMINED — never PASS.

---

## 1. Segmentation — `mas_seg_check`

```matlab
r = mas_seg_check(predLabels, trueLabels, struct('bg', 0, 'iouThreshold', 0.5, ...
        'metrics', struct('name','f1','value',8/9,'tolRel',1e-12)));
```

`pred` and `truth` are label maps of the same size (logical, integer labels, or a score
map with `scoreMap=true` plus `decisionThreshold`). Indexing is MATLAB array order:
row = y, column = x. Label values are pixel classes, not coordinates.

### Pixel contingency table

For each class (background excluded from the foreground union):

| | truth = c | truth != c |
|---|---|---|
| pred = c | TP | FP |
| pred != c | FN | TN |

- `iou = TP/(TP+FP+FN)`, `dice = 2TP/(2TP+FP+FN)`, `precision = TP/(TP+FP)`,
  `recall = TP/(TP+FN)`, `f1 = 2PR/(P+R)`.
- `accuracy = (TP+TN)/N` where every non-class pixel counts as TN.
- `binaryIoU` is the foreground union over all non-background classes; it is undefined
  when no foreground/background convention applies, and the tool says so rather than
  returning a number.
- `macroIoU` averages per-class IoU over classes **with support** (including background);
  `macroIoUForeground` excludes background. Both are printed with the support counts,
  because a macro mean over classes with three pixels is not a quality claim.
- `exactRecount` (default true) recomputes TP/FP/FN by a second, independent pixel route
  and requires agreement. A recount mismatch is a FAIL of the tool's own arithmetic
  (`pixelRecount`), not a property of the prediction.

Worked example (`sc_base`): truth is a 2×2 block in a 4×4 image; prediction adds one
false-positive pixel. TP = 4, FP = 1, FN = 0 → pixel IoU 4/5, F1 8/9, accuracy 15/16.
Object metrics: 2 predicted components, 1 truth component, 1 matched, matchedFraction
0.5.

### Object matching

- Components are found with `bwlabel(..., 4)` (4-connectivity), matching `mas_image_metrics`.
- Predictions are visited in **descending area** order; each is compared with every truth
  component of the same class and assigned the highest-IoU **unused** one.
- A prediction whose best IoU passes the threshold but whose best truth is already used is
  a **duplicate candidate**: it is reported and counted as a false positive, never as a
  second true positive.
- `objectIouMean`/`objectIouWorst` are computed over matched objects only. If nothing is
  matched they are NaN, and an object-metric claim on them is UNDETERMINED, not zero.
- The IoU threshold is explicit. `iouThreshold` defaults to 0.5 for reporting, but an
  **object-metric claim without a caller-stated threshold is UNDETERMINED**
  (`iouThreshold`): a matching rule that the claimant never stated cannot grade the claim.
- `matchedFraction = nMatched / max(nPred,1)`, `objectRecall = nMatched / nTruthObjects`,
  `objectPrecision = nMatched / nPred`.

Negative controls from the suite:

| fixture | what goes wrong | what the tool reports |
|---|---|---|
| right-area mask in the wrong corner | pixel recall 1 | pixel IoU 0, 0 matched, objectIouMean NaN |
| one truth object, two predicted pieces each at IoU 0.4 | many-to-one matching inflation | 1 matched, 1 duplicate candidate, objectRecall 1 |
| multi-class miss of 1 of 4 pixels in class 2 | macro hides local loss | class 2 IoU 0.75, recall 0.75; macroIoU 0.8875 incl. background |

### Empty conventions

| truth | prediction | IoU | precision / recall / F1 |
|---|---|---|---|
| empty | empty | 1 (perfect by convention) | 1 / 1 / 1 (vacuous) |
| empty | non-empty | 0 | 0 / undefined / 0 |
| non-empty | empty | 0 | undefined / 0 / 0 |

0/0 is never silently reported as a good score. A claim of recall on empty truth is
UNDETERMINED (`claim_recall`), because the denominator is undefined.

### Imbalance and threshold sensitivity

- `imbalance.majorityShare` is reported for every run. Above `imbalanceLimit` (default
  0.9), an **accuracy-only** claim cannot support a quality conclusion: the number is true
  but the conclusion is not, so the check is UNDETERMINED (`imbalanceDisclosure`). A macro
  or per-class claim on the same data is graded normally.
- Score maps: `decisionThreshold` is required, its `thresholdSource` is part of the claim,
  and a sweep over `thresholdSweep` (default 0.1:0.2:0.9) reports `bestThreshold`,
  `bestF1` and `sensitivityF1Range`. If `maxSensitivity` is stated, a range above it
  FAILS (`thresholdSensitivity`).
- A threshold whose source is `test` FAILS (`thresholdSource`); an absent source is
  UNDETERMINED. Tuning the decision threshold on the data being reported is leakage, even
  when the resulting F1 is perfect.
- Worked sweep: a 2×4 score map whose five foreground pixels have scores ≥ 0.6 yields F1
  1.000 at threshold 0.5, but only 4/7 ≈ 0.571 at 0.9 — range 1 − 4/7 ≈ 0.429. A claimed
  single threshold with no sensitivity statement is the defect this measures.
- A metric claim with no `tolRel`/`tolAbs` is UNDETERMINED (`claim_*`), every time.

---

## 2. Detection — `mas_detect_check`

```matlab
r = mas_detect_check(gtBox, gtLab, predBox, predLab, scores, struct( ...
        'iouThreshold', 0.5, 'imageSize', [480 640], ...
        'scoreThreshold', 0.3, 'scoreThresholdSource', 'validation', ...
        'metrics', struct('name','f1','value',0.75,'tolRel',1e-12)));
```

### Box convention

Boxes are `[x y w h]` with `x,y` the 1-based top-left corner and `w,h > 0`. A box covers
the half-open span `[x, x+w) × [y, y+h)`. With `imageSize = [H W]` the valid range is
`x >= 1`, `y >= 1`, `x+w <= W+1`, `y+h <= H+1`. Any other format (e.g. `xyxy`) is
rejected with an error rather than reinterpreted. Boxes outside the image FAIL
(`boxBounds`); a non-positive width is an error.

### Matching contract

- Per class, predictions are visited in **descending score** order.
- Each prediction is matched to the highest-IoU **unused** ground-truth box of the same
  class, at the explicit `iouThreshold` (required; missing → error).
- A second prediction on an already-matched GT is a **false positive** and is reported as
  a duplicate candidate. This is the duplicate-detection defect that inflates recall when
  matching is many-to-one: two identical boxes on one GT must give precision 0.5, not 1.
- Predictions of a class absent from GT are false positives and are never dropped. Such a
  label also raises a `labelAlignment` warning, because a class-name mapping bug looks
  exactly like a detector that invented a class. A GT class with no predictions is FN and
  is not an error.
- `tp/fp/fn`, micro precision/recall/F1 are counted over all classes; `macroF1` averages
  only classes with GT support. A micro-only claim on imbalanced data is UNDETERMINED
  (`imbalanceDisclosure`); a macro claim on the same data is graded.

### AP and mAP

AP is **all-point interpolated** (precision envelope) per class:

```
AP = Σ (r_i − r_{i−1}) · max_{j >= i} p_j
```

mAP averages AP over classes with at least one GT box; classes with no GT have no AP.
Worked example: three GT boxes, predictions in score order TP, FP, TP, TP give
recall points 1/3, 1/3, 2/3, 1 and envelope 1, 0.75, 0.75, 0.75, so
`AP = (1/3)(1 + 0.75 + 0.75) = 0.8333`. A score threshold at 0.85 keeps only the first
prediction: AP 1/3, TP 1, FN 2 — the curve, not just the F1, records what was cut.

### Operating point and provenance

- `scoreThreshold` (default 0) filters predictions before matching; the threshold is part
  of the reported result. `scoreThresholdSource` must be `train`/`validation`/`spec`;
  `test` FAILS, absence is UNDETERMINED.
- `scoreSweep` + `maxSensitivity` work as in segmentation: a single lucky operating point
  is not a detector claim.
- Empty conventions match segmentation: no GT and no predictions is P=R=F1=1 (vacuous);
  no GT with predictions is P=0, recall undefined, F1=0; GT with no predictions is
  precision undefined, recall 0, F1=0.
- Without `imageSize`, the bounds check is `na` and no geometry claim is made.

---

## 3. Image, geometry and split hygiene — `mas_image_contract`

```matlab
r = mas_image_contract(I, struct('expectedSize',[256 256 3], ...
        'expectedClass','uint8','expectedRange',[0 255],'space','rgb', ...
        'labels',L, ...
        'normalization', struct('original',I0,'inverse',@inv,'forward',@fwd), ...
        'transform',T,'points',P,'pointsTransformed',Q,'outputSize',[H W], ...
        'edgeMap',E,'edgeTruth',E0,'edgeTolPx',1,'edgeF1Min',0.9, ...
        'features',F,'featureTruth',F0,'matchTol',1,'featureF1Min',0.9, ...
        'split', struct('trainIdx',tr,'valIdx',va,'sampleHash',h, ...
                        'groups',g,'tunedOn','train','reportedOn','test')));
```

At least one acceptance criterion is required; an empty claims struct is UNDETERMINED
(`criteria`), not a pass.

### Data and label alignment

- `expectedSize` is compared exactly (including channels); `expectedClass` is the MATLAB
  class; `expectedRange` requires the data to lie inside the stated interval.
- `requireFinite` defaults true. NaN/Inf is a FAIL unless explicitly allowed — and if it
  is allowed, the finite-only checks say that they were skipped.
- `space` (`gray`/`rgb`/`rgba`) is checked against the channel count: declaring `rgb` for
  a 2-D image FAILS `channels`.
- `labels` must match the image size exactly (`labelAlignment`) and every declared label
  value must be in `labelClasses` (`labelClasses`). A resized mask that "looks aligned" is
  the defect this catches.

### Preprocessing invertibility

- `normalization.original`, `inverse`, optional `forward`: the tool runs the inverse and
  requires exact recovery of the original values (`normalizationInvertible`). An integer
  image that returns as unscaled doubles FAILS. If `forward` is given, forward-then-inverse
  is also checked (`normalizationForward`).
- A threshold used for binarization needs `threshold` plus `thresholdSource`; source
  `test` FAILS (`thresholdSource`), absence is UNDETERMINED.

### Geometry

- `transform` is a 2×3 or 3×3 affine acting on homogeneous `[x; y; 1]`. The bottom row
  must be `[0 0 1]` (non-affine → error); a singular or ill-conditioned matrix FAILS
  (`transformInvertible`).
- Claimed point correspondences `points → pointsTransformed` are checked after applying
  the transform (`transformPoints`). Transformed points must lie inside `outputSize`
  (`transformBounds`); a transform that maps content off-canvas is not a resize.
- Features are `[x y]` with x = column in `[1,W]`, y = row in `[1,H]`. Features outside
  the image FAIL (`featureBounds`); exact duplicates FAIL (`featureDuplicates`) unless
  explicitly allowed; `minFeatures` is a count criterion (`featureCount`).
- Edge maps and feature sets are matched to an **independent truth** with Chebyshev
  (`max(|dx|,|dy|)`) distance within `matchTol`/`edgeTolPx`, and precision/recall/F1 are
  reported. `edgeF1Min`/`featureF1Min` are required to grade — a truth without a criterion
  is UNDETERMINED. An all-ones edge map scores recall 1 and precision 0.2, and FAILS;
  "many edges" is not "correct edges".
- Worked tolerance case: an edge truth in column 3 and a map in column 4 pass at
  `edgeTolPx = 1` and FAIL at 0 (disjoint sets → F1 0). The tolerance is part of the
  acceptance criterion, not a hidden convenience.

### Split leakage

- `split` accepts `trainIdx`, `valIdx`, `testIdx`, `sampleHash`, `groups`, `tunedOn`,
  `reportedOn`.
- Three independent checks: index overlap (`splitOverlap`), content-hash overlap
  (`contentLeakage`), and group overlap (`groupLeakage`). Disjoint indices prove nothing:
  the same image under two indices, or the same patient in two splits, is leakage.
- A split without hashes is UNDETERMINED for content leakage (`contentLeakage`), not
  assumed clean. A single split is UNDETERMINED for overlap (`splitOverlap`); overlap needs
  two sides.
- `tunedOn = test` (or `tunedOn == reportedOn` where reported is the evaluation set) FAILS
  `tuningLeakage`. Training on the test set and reporting test performance is the leak,
  even when every index is disjoint.

---

## Cross-tool rules

- Every claim needs a stated tolerance; no tolerance, no PASS.
- Every truth must be independent of the code under test: hand-counted contingency
  tables, explicit matching traces, constructed edges/features/transforms, and split
  indices written by hand.
- Duplicate matches are false positives in both segmentation and detection; a many-to-one
  match is never allowed to raise recall.
- Empty/empty is perfect by convention, empty/anything-else is zero, and an undefined
  denominator is UNDETERMINED — never 0 and never 1.
- Thresholds (decision, matching, binarization) are claims with provenance; a threshold
  tuned on the reported set is a FAIL, silence is UNDETERMINED.
- A high pixel accuracy, a large mask area, or a visually plausible overlay is never
  sufficient evidence. The tests deliberately include the right-area/wrong-place mask,
  the shifted edge map, and the all-ones edge map as negative controls.

Tests: `tests/test_vision_contract.m` (103/103). Segmentations, detections, images,
transforms and splits are all synthetic and deterministic; expected numbers are recomputed
by hand in the test file, never taken from the tool's own output.
