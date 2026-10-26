function res = test_vision_contract(verbose)
%TEST_VISION_CONTRACT  Segmentation, detection and image/geometry contracts.
%
%   res = test_vision_contract()
%
% Tools under test: mas_seg_check, mas_detect_check, mas_image_contract.
%
% Every expected number is recomputed here from the fixture by a route that does
% not call the tool: pixel contingency counts written out by hand, an explicit
% one-to-one matching trace, all-point AP by hand, and synthetic images whose
% edge/feature/transform truths are constructed, not detected.
%
% Negative controls are the point of the suite: the right area in the wrong
% place must score object IoU 0; a duplicate detection must be a false positive;
% a split with disjoint indices but identical content must leak; an all-ones edge
% map must fail precision; a threshold tuned on test must fail provenance; a
% metric with no tolerance must be UNDETERMINED, not PASS.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ======================= mas_seg_check ==================================
T(end+1) = tc('seg: clean mask PASS',             @() sc_clean(),           'PASS');
T(end+1) = tc('seg: pixel IoU 4/5',               @() sc_pixel(),           true);
T(end+1) = tc('seg: F1 8/9',                      @() sc_f1(),              true);
T(end+1) = tc('seg: accuracy 15/16',              @() sc_acc(),             true);
T(end+1) = tc('seg: objects 2 pred / 1 matched',  @() sc_objects(),         true);
T(end+1) = tc('seg: wrong iou claim FAIL',        @() sc_wrongIou(),        'FAIL/claim_iou');
T(end+1) = tc('seg: no tolerance UNDETERMINED',   @() sc_noTol(),           'UNDETERMINED/claim_iou');
T(end+1) = tc('seg: wrong place object IoU 0',    @() sc_wrongPlace(),      true);
T(end+1) = tc('seg: duplicate match is FP',       @() sc_duplicate(),       true);
T(end+1) = tc('seg: per-class IoU class 2',       @() sc_mcClass2(),        true);
T(end+1) = tc('seg: macro IoU 0.9',               @() sc_mcMacro(),         true);
T(end+1) = tc('seg: foreground IoU 10/13',        @() sc_mcBinary(),        true);
T(end+1) = tc('seg: accuracy-only imbalanced',    @() sc_imbalance(),       'UNDETERMINED/imbalanceDisclosure');
T(end+1) = tc('seg: empty/empty PASS',            @() sc_emptyBoth(),       'PASS');
T(end+1) = tc('seg: empty/empty IoU 1',           @() sc_emptyBothVal(),    true);
T(end+1) = tc('seg: empty truth F1 0',            @() sc_emptyTruth(),      'PASS');
T(end+1) = tc('seg: empty truth recall undefined', @() sc_emptyTruthRec(),  'UNDETERMINED/claim_recall');
T(end+1) = tc('seg: empty pred F1 0',             @() sc_emptyPred(),       'PASS');
T(end+1) = tc('seg: object claim needs threshold', @() sc_objectNoThr(),    'UNDETERMINED/iouThreshold');
T(end+1) = tc('seg: score map validation source', @() sc_scoreOk(),         'PASS');
T(end+1) = tc('seg: score source test FAIL',      @() sc_scoreTest(),       'FAIL/thresholdSource');
T(end+1) = tc('seg: score source missing',        @() sc_scoreNoSrc(),      'UNDETERMINED/thresholdSource');
T(end+1) = tc('seg: sensitivity limit 0.2',       @() sc_sensFail(),        'FAIL/thresholdSensitivity');
T(end+1) = tc('seg: sensitivity limit 0.5',       @() sc_sensPass(),        'PASS');
T(end+1) = tc('seg: score map needs threshold',   @() sc_scoreNoThr(),      'ERR');
T(end+1) = tc('seg: score outside [0,1]',         @() sc_scoreRange(),      'ERR');
T(end+1) = tc('seg: label outside classes',       @() sc_labelOutside(),    'ERR');
T(end+1) = tc('seg: size mismatch',               @() sc_size(),            'ERR');
T(end+1) = tc('seg: non-integer label map',       @() sc_nonInteger(),      'ERR');
T(end+1) = tc('seg: sweep best F1 tie',            @() sc_sweep(),           true);
T(end+1) = tc('seg: two pixel routes agree',      @() sc_recount(),         true);
T(end+1) = tc('seg: explicit object threshold',    @() sc_objThr(),          true);
T(end+1) = tc('seg: wrong F1 claim FAIL',          @() sc_wrongF1(),         'FAIL/claim_f1');
T(end+1) = tc('seg: multi-class claim PASS',       @() sc_mcClaim(),         'PASS');

% ======================= mas_detect_check ===============================
T(end+1) = tc('det: clean F1 0.8 PASS',           @() dc_clean(),           'PASS');
T(end+1) = tc('det: precision 2/3',               @() dc_precision(),       true);
T(end+1) = tc('det: recall 1',                    @() dc_recall(),          true);
T(end+1) = tc('det: mAP 1',                       @() dc_map(),             true);
T(end+1) = tc('det: wrong F1 claim FAIL',         @() dc_wrongF1(),         'FAIL/claim_f1');
T(end+1) = tc('det: no tolerance UNDETERMINED',   @() dc_noTol(),           'UNDETERMINED/claim_f1');
T(end+1) = tc('det: AP hand 0.8333',              @() dc_apHand(),          true);
T(end+1) = tc('det: duplicate is FP',             @() dc_duplicate(),       true);
T(end+1) = tc('det: IoU 0.75 at 0.5',             @() dc_iou05(),           true);
T(end+1) = tc('det: IoU 0.75 at 0.8',             @() dc_iou08(),           true);
T(end+1) = tc('det: score threshold filters FP',  @() dc_scoreFilter(),     'PASS');
T(end+1) = tc('det: score source test FAIL',      @() dc_scoreTest(),       'FAIL/scoreThresholdSource');
T(end+1) = tc('det: score source missing',        @() dc_scoreNoSrc(),      'UNDETERMINED/scoreThresholdSource');
T(end+1) = tc('det: score source validation',     @() dc_scoreVal(),        'pass');
T(end+1) = tc('det: empty/empty PASS',            @() dc_emptyBoth(),       'PASS');
T(end+1) = tc('det: empty/empty P/R/F1 1',        @() dc_emptyVals(),       true);
T(end+1) = tc('det: empty GT, FP F1 0',           @() dc_emptyGt(),         'PASS');
T(end+1) = tc('det: empty GT recall undefined',   @() dc_emptyGtRec(),      'UNDETERMINED/claim_recall');
T(end+1) = tc('det: empty pred F1 0',             @() dc_emptyPred(),       'PASS');
T(end+1) = tc('det: out-of-bounds box FAIL',      @() dc_bounds(),          'FAIL/boxBounds');
T(end+1) = tc('det: non-positive width',          @() dc_badWidth(),        'ERR');
T(end+1) = tc('det: label mismatch warning',      @() dc_labelMismatch(),   'UNDETERMINED/labelAlignment');
T(end+1) = tc('det: missing IoU threshold',       @() dc_noIou(),           'ERR');
T(end+1) = tc('det: xyxy format rejected',        @() dc_xyxy(),            'ERR');
T(end+1) = tc('det: label count mismatch',        @() dc_labelCount(),      'ERR');
T(end+1) = tc('det: per-class F1',                @() dc_perClass(),        true);
T(end+1) = tc('det: micro-only on imbalance',     @() dc_imbalance(),       'UNDETERMINED/imbalanceDisclosure');
T(end+1) = tc('det: macro claim on imbalance',    @() dc_imbalanceMacro(),  'PASS');
T(end+1) = tc('det: no imageSize, bounds na',     @() dc_noSize(),          'na');
T(end+1) = tc('det: score threshold cuts AP',     @() dc_apCut(),           true);
T(end+1) = tc('det: extra class is FP + warning', @() dc_extraClass(),     'UNDETERMINED/labelAlignment');
T(end+1) = tc('det: missed GT class is FN',       @() dc_missedClass(),     true);

% ======================= mas_image_contract =============================
T(end+1) = tc('img: full contract PASS',          @() ic_full(),            'PASS');
T(end+1) = tc('img: wrong size FAIL',             @() ic_size(),            'FAIL/size');
T(end+1) = tc('img: wrong class FAIL',            @() ic_class(),           'FAIL/class');
T(end+1) = tc('img: wrong range FAIL',            @() ic_range(),           'FAIL/range');
T(end+1) = tc('img: rgb on gray FAIL',            @() ic_space(),           'FAIL/channels');
T(end+1) = tc('img: label size mismatch',         @() ic_labelAlign(),      'FAIL/labelAlignment');
T(end+1) = tc('img: undeclared label class',      @() ic_labelClass(),      'FAIL/labelClasses');
T(end+1) = tc('img: normalization not exact',     @() ic_normFail(),        'FAIL/normalizationInvertible');
T(end+1) = tc('img: forward map wrong',           @() ic_fwdFail(),         'FAIL/normalizationForward');
T(end+1) = tc('img: singular transform',          @() ic_singular(),        'FAIL/transformInvertible');
T(end+1) = tc('img: wrong transformed points',    @() ic_pointsWrong(),     'FAIL/transformPoints');
T(end+1) = tc('img: transform outside output',    @() ic_transBounds(),     'FAIL/transformBounds');
T(end+1) = tc('img: non-affine transform',        @() ic_nonAffine(),       'ERR');
T(end+1) = tc('img: edge shift 1 px tolerated',   @() ic_edgeShiftTol(),    'PASS');
T(end+1) = tc('img: edge shift 1 px strict',      @() ic_edgeShiftStrict(), 'FAIL/edgeF1');
T(end+1) = tc('img: all-ones edge map fails',     @() ic_edgeAllOnes(),     true);
T(end+1) = tc('img: edge map without truth',      @() ic_edgeNoTruth(),     'UNDETERMINED/edgeTruth');
T(end+1) = tc('img: edge without criterion',      @() ic_edgeNoCrit(),      'UNDETERMINED/edgeF1');
T(end+1) = tc('img: feature out of bounds',       @() ic_featOob(),         'FAIL/featureBounds');
T(end+1) = tc('img: duplicate features',          @() ic_featDup(),         'FAIL/featureDuplicates');
T(end+1) = tc('img: min features not met',        @() ic_featCount(),       'FAIL/featureCount');
T(end+1) = tc('img: feature truth mismatch',      @() ic_featTruth(),       'FAIL/featureF1');
T(end+1) = tc('img: clean split PASS',            @() ic_splitOk(),         'PASS');
T(end+1) = tc('img: split index overlap',         @() ic_splitOverlap(),    'FAIL/splitOverlap');
T(end+1) = tc('img: content leak FAIL',           @() ic_contentLeak(),     'FAIL/contentLeakage');
T(end+1) = tc('img: group leak FAIL',             @() ic_groupLeak(),       'FAIL/groupLeakage');
T(end+1) = tc('img: no hashes UNDETERMINED',      @() ic_noHashes(),        'UNDETERMINED/contentLeakage');
T(end+1) = tc('img: one split UNDETERMINED',      @() ic_oneSplit(),        'UNDETERMINED/splitOverlap');
T(end+1) = tc('img: tune on test FAIL',           @() ic_tuneTest(),        'FAIL/tuningLeakage');
T(end+1) = tc('img: threshold source test',       @() ic_thrTest(),         'FAIL/thresholdSource');
T(end+1) = tc('img: threshold no source',         @() ic_thrNoSrc(),        'UNDETERMINED/thresholdSource');
T(end+1) = tc('img: no criteria UNDETERMINED',    @() ic_noClaims(),        'UNDETERMINED/criteria');
T(end+1) = tc('img: NaN rejected',                @() ic_nan(),             'FAIL/finite');
T(end+1) = tc('img: NaN allowed by claim',        @() ic_nanAllowed(),      'PASS');
T(end+1) = tc('img: feature precision 0.5',       @() ic_featPrecision(),   true);
T(end+1) = tc('img: identity round-trip',         @() ic_identity(),        'PASS');
T(end+1) = tc('img: both edge maps empty',        @() ic_edgeEmpty(),       'PASS');

% ======================= harness ========================================
nP = 0;
if verbose, fprintf('=== vision contract tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    try
        got = t.fn();
    catch
        got = 'ERR';
    end
    if ischar(t.expect)
        ok = strcmp(char(string(got)), t.expect);
    else
        ok = isequal(got, t.expect);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-40s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, ...
            char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d vision-contract cases passed ----\n', nP, numel(T));
end
end

% ===========================================================================
% segmentation fixtures
% ===========================================================================
function [P, T] = sc_base()
T = [0 0 1 1; 0 0 1 1; 0 0 0 0; 0 0 0 0];
P = [0 0 1 1; 0 0 1 1; 0 0 0 0; 0 0 1 0];
end
function c = sc_claim(name, value, tol)
c = struct('iouThreshold', 0.5, 'metrics', ...
    struct('name', name, 'value', value, 'tolRel', tol));
end
function v = sc_clean()
[P, T] = sc_base();
r = mas_seg_check(P, T, sc_claim('iou', 0.8, 1e-12));
v = r.verdict;
end
function v = sc_pixel()
[P, T] = sc_base();
r = mas_seg_check(P, T, sc_claim('iou', 0.8, 1e-12));
v = near(r.metrics.binaryIoU, 4/5, 1e-12) && near(r.metrics.tp, 4, 0) && ...
    near(r.metrics.fp, 1, 0) && near(r.metrics.fn, 0, 0);
end
function v = sc_f1()
[P, T] = sc_base();
r = mas_seg_check(P, T, struct());
v = near(r.metrics.f1, 8/9, 1e-12);
end
function v = sc_acc()
[P, T] = sc_base();
r = mas_seg_check(P, T, struct());
v = near(r.metrics.accuracy, 15/16, 1e-12);
end
function v = sc_objects()
[P, T] = sc_base();
r = mas_seg_check(P, T, struct());
v = r.objectMetrics.nPredObjects == 2 && r.objectMetrics.nTruthObjects == 1 && ...
    r.objectMetrics.nMatched == 1 && near(r.objectMetrics.matchedFraction, 0.5, 1e-12);
end
function v = sc_wrongIou()
[P, T] = sc_base();
r = mas_seg_check(P, T, sc_claim('iou', 0.9, 1e-12));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_noTol()
[P, T] = sc_base();
r = mas_seg_check(P, T, sc_claim('iou', 0.8, NaN));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_wrongPlace()
T = zeros(4, 4); T(1:2,1:2) = 1;
P = zeros(4, 4); P(3:4,3:4) = 1;
r = mas_seg_check(P, T, struct());
v = near(r.metrics.binaryIoU, 0, 0) && r.objectMetrics.nMatched == 0 && ...
    near(r.objectMetrics.matchedFraction, 0, 0) && isnan(r.objectMetrics.objectIouMean);
end
function v = sc_duplicate()
T = zeros(4, 5); T(1:2,1:5) = 1;
P = zeros(4, 5); P(1:2,1:2) = 1; P(1:2,4:5) = 1;
r = mas_seg_check(P, T, struct('iouThreshold', 0.4));
v = r.objectMetrics.nPredObjects == 2 && r.objectMetrics.nMatched == 1 && ...
    r.objectMetrics.duplicateCandidates == 1 && near(r.objectMetrics.objectRecall, 1, 1e-12);
end
function [P, T] = sc_mc()
T = [1 1 2 2; 1 1 2 2; 3 3 0 0; 3 3 0 0];
P = T; P(2,4) = 0;
end
function v = sc_mcClass2()
[P, T] = sc_mc();
r = mas_seg_check(P, T, struct());
k = find([r.perClass.label] == 2, 1);
v = near(r.perClass(k).iou, 0.75, 1e-12) && near(r.perClass(k).recall, 0.75, 1e-12) && ...
    near(r.perClass(k).precision, 1, 1e-12);
end
function v = sc_mcMacro()
[P, T] = sc_mc();
r = mas_seg_check(P, T, struct());
v = near(r.metrics.macroIoU, 0.8875, 1e-12);
end
function v = sc_mcBinary()
[P, T] = sc_mc();
r = mas_seg_check(P, T, struct());
v = near(r.metrics.binaryIoU, 11/12, 1e-12) && near(r.metrics.precision, 1, 1e-12) && ...
    near(r.metrics.recall, 11/12, 1e-12);
end
function v = sc_imbalance()
T = zeros(10, 10); T(1,1) = 1;
P = zeros(10, 10);
r = mas_seg_check(P, T, sc_claim('accuracy', 0.99, 1e-12));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_emptyBoth()
r = mas_seg_check(zeros(3), zeros(3), sc_claim('iou', 1, 1e-12));
v = r.verdict;
end
function v = sc_emptyBothVal()
r = mas_seg_check(zeros(3), zeros(3), struct());
v = near(r.metrics.binaryIoU, 1, 0) && near(r.metrics.f1, 1, 0) && ...
    near(r.metrics.accuracy, 1, 0);
end
function v = sc_emptyTruth()
T = zeros(3); P = zeros(3); P(1,1) = 1;
r = mas_seg_check(P, T, sc_claim('f1', 0, 0));
v = r.verdict;
end
function v = sc_emptyTruthRec()
T = zeros(3); P = zeros(3); P(1,1) = 1;
r = mas_seg_check(P, T, sc_claim('recall', 0, 0));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_emptyPred()
T = zeros(3); T(1,1) = 1; P = zeros(3);
r = mas_seg_check(P, T, sc_claim('f1', 0, 0));
v = r.verdict;
end
function v = sc_objectNoThr()
[P, T] = sc_base();
c = struct('metrics', struct('name', 'objectIouMean', 'value', 1, 'tolRel', 1e-12));
r = mas_seg_check(P, T, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function [truth, score] = sc_score()
truth = [0 0 1 1; 0 1 1 1];
score = [0.10 0.20 0.80 0.90; 0.30 0.60 0.70 0.95];
end
function v = sc_scoreOk()
[truth, score] = sc_score();
c = struct('scoreMap', true, 'decisionThreshold', 0.5, ...
    'thresholdSource', 'validation', 'metrics', ...
    struct('name', 'f1', 'value', 1, 'tolRel', 1e-12));
r = mas_seg_check(score, truth, c);
v = r.verdict;
end
function v = sc_scoreTest()
[truth, score] = sc_score();
c = struct('scoreMap', true, 'decisionThreshold', 0.5, ...
    'thresholdSource', 'test', 'metrics', ...
    struct('name', 'f1', 'value', 1, 'tolRel', 1e-12));
r = mas_seg_check(score, truth, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_scoreNoSrc()
[truth, score] = sc_score();
c = struct('scoreMap', true, 'decisionThreshold', 0.5, ...
    'metrics', struct('name', 'f1', 'value', 1, 'tolRel', 1e-12));
r = mas_seg_check(score, truth, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_sensFail()
[truth, score] = sc_score();
c = struct('scoreMap', true, 'decisionThreshold', 0.5, ...
    'thresholdSource', 'validation', 'maxSensitivity', 0.2, ...
    'metrics', struct('name', 'f1', 'value', 1, 'tolRel', 1e-12));
r = mas_seg_check(score, truth, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_sensPass()
[truth, score] = sc_score();
c = struct('scoreMap', true, 'decisionThreshold', 0.5, ...
    'thresholdSource', 'validation', 'maxSensitivity', 0.5, ...
    'metrics', struct('name', 'f1', 'value', 1, 'tolRel', 1e-12));
r = mas_seg_check(score, truth, c);
v = r.verdict;
end
function v = sc_scoreNoThr()
[truth, score] = sc_score();
try
    mas_seg_check(score, truth, struct('scoreMap', true));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = sc_scoreRange()
[truth, score] = sc_score(); score(1) = 1.2;
try
    mas_seg_check(score, truth, struct('scoreMap', true, 'decisionThreshold', 0.5));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = sc_labelOutside()
[P, T] = sc_mc();
try
    mas_seg_check(P, T, struct('classes', [0 1 2]));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = sc_size()
try
    mas_seg_check(zeros(3), zeros(4), struct());
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = sc_nonInteger()
try
    mas_seg_check([0 0.5; 1 1], [0 0; 1 1], struct());
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = sc_sweep()
[truth, score] = sc_score();
r = mas_seg_check(score, truth, struct('scoreMap', true, ...
    'decisionThreshold', 0.5, 'thresholdSource', 'validation'));
v = (near(r.bestThreshold, 0.3, 1e-12) || near(r.bestThreshold, 0.5, 1e-12)) && ...
    near(r.bestF1, 1, 1e-12) && near(r.sensitivityF1Range, 1 - 4/7, 1e-12);
end
function v = sc_recount()
[P, T] = sc_base();
r = mas_seg_check(P, T, struct());
v = strcmp(local_status(r, 'pixelRecount'), 'pass');
end
function v = sc_objThr()
[P, T] = sc_base();
r = mas_seg_check(P, T, sc_claim('objectIouMean', 1, 1e-12));
v = strcmp(local_status(r, 'iouThreshold'), 'pass');
end
function v = sc_wrongF1()
[P, T] = sc_base();
r = mas_seg_check(P, T, sc_claim('f1', 0.5, 1e-12));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = sc_mcClaim()
[P, T] = sc_mc();
c = struct('metrics', struct('name', 'macroIoU', 'value', 0.8875, 'tolRel', 1e-12));
r = mas_seg_check(P, T, c);
v = r.verdict;
end

% ===========================================================================
% detection fixtures
% ===========================================================================
function [G, GL, P, PL, S] = dc_base()
G = [1 1 2 2; 10 10 2 2];
GL = {'a'; 'a'};
P = [1 1 2 2; 10 10 2 2; 20 20 2 2];
PL = {'a'; 'a'; 'a'};
S = [0.9; 0.8; 0.7];
end
function c = dc_claim(name, value, tol)
c = struct('iouThreshold', 0.5, 'imageSize', [32 32], 'metrics', ...
    struct('name', name, 'value', value, 'tolRel', tol));
end
function v = dc_clean()
[G, GL, P, PL, S] = dc_base();
r = mas_detect_check(G, GL, P, PL, S, dc_claim('f1', 0.8, 1e-12));
v = r.verdict;
end
function v = dc_precision()
[G, GL, P, PL, S] = dc_base();
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = near(r.metrics.precision, 2/3, 1e-12) && r.metrics.tp == 2 && r.metrics.fp == 1;
end
function v = dc_recall()
[G, GL, P, PL, S] = dc_base();
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = near(r.metrics.recall, 1, 1e-12) && r.metrics.fn == 0;
end
function v = dc_map()
[G, GL, P, PL, S] = dc_base();
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = near(r.mAP, 1, 1e-12);
end
function v = dc_wrongF1()
[G, GL, P, PL, S] = dc_base();
r = mas_detect_check(G, GL, P, PL, S, dc_claim('f1', 0.5, 1e-12));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_noTol()
[G, GL, P, PL, S] = dc_base();
r = mas_detect_check(G, GL, P, PL, S, dc_claim('f1', 0.8, NaN));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_apHand()
G = [1 1 2 2; 5 5 2 2; 10 10 2 2];
GL = {'a'; 'a'; 'a'};
P = [1 1 2 2; 20 20 2 2; 5 5 2 2; 10 10 2 2];
PL = {'a'; 'a'; 'a'; 'a'};
S = [0.95; 0.90; 0.80; 0.70];
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
% hand: ranks TP,FP,TP,TP -> rec [1/3 1/3 2/3 1], envelope [1 .75 .75 .75]
v = near(r.mAP, 1/3*1 + 1/3*0.75 + 1/3*0.75, 1e-12);
end
function v = dc_duplicate()
G = [1 1 4 4]; GL = {'a'};
P = [1 1 4 4; 1 1 4 4]; PL = {'a'; 'a'}; S = [0.9; 0.8];
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = r.duplicateCandidates == 1 && r.metrics.tp == 1 && r.metrics.fp == 1 && ...
    near(r.metrics.precision, 0.5, 1e-12);
end
function v = dc_iou05()
G = [1 1 4 4]; GL = {'a'};
P = [1 1 4 3]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = r.metrics.tp == 1 && r.metrics.fn == 0;
end
function v = dc_iou08()
G = [1 1 4 4]; GL = {'a'};
P = [1 1 4 3]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.8));
v = r.metrics.tp == 0 && r.metrics.fn == 1 && r.metrics.fp == 1;
end
function v = dc_scoreFilter()
G = [1 1 2 2; 10 10 2 2]; GL = {'a'; 'a'};
P = [1 1 2 2; 20 20 2 2; 10 10 2 2]; PL = {'a'; 'a'; 'a'};
S = [0.9; 0.4; 0.8];
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'scoreThreshold', 0.5, 'scoreThresholdSource', 'validation', ...
    'metrics', struct('name', 'f1', 'value', 1, 'tolRel', 1e-12)));
v = r.verdict;
end
function v = dc_scoreTest()
G = [1 1 2 2]; GL = {'a'}; P = [1 1 2 2]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'scoreThreshold', 0.5, 'scoreThresholdSource', 'test'));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_scoreNoSrc()
G = [1 1 2 2]; GL = {'a'}; P = [1 1 2 2]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'scoreThreshold', 0.5));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_scoreVal()
G = [1 1 2 2]; GL = {'a'}; P = [1 1 2 2]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'scoreThreshold', 0.5, 'scoreThresholdSource', 'validation'));
v = local_status(r, 'scoreThresholdSource');
end
function v = dc_emptyBoth()
r = mas_detect_check([], {}, [], {}, [], struct('iouThreshold', 0.5, ...
    'metrics', struct('name', 'f1', 'value', 1, 'tolRel', 1e-12)));
v = r.verdict;
end
function v = dc_emptyVals()
r = mas_detect_check([], {}, [], {}, [], struct('iouThreshold', 0.5));
v = near(r.metrics.precision, 1, 0) && near(r.metrics.recall, 1, 0) && ...
    near(r.metrics.f1, 1, 0);
end
function v = dc_emptyGt()
P = [1 1 2 2]; PL = {'a'}; S = 0.9;
r = mas_detect_check([], {}, P, PL, S, struct('iouThreshold', 0.5, ...
    'metrics', struct('name', 'f1', 'value', 0, 'tolRel', 1e-12)));
v = r.verdict;
end
function v = dc_emptyGtRec()
P = [1 1 2 2]; PL = {'a'}; S = 0.9;
r = mas_detect_check([], {}, P, PL, S, struct('iouThreshold', 0.5, ...
    'metrics', struct('name', 'recall', 'value', 0, 'tolRel', 1e-12)));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_emptyPred()
G = [1 1 2 2]; GL = {'a'};
r = mas_detect_check(G, GL, [], {}, [], struct('iouThreshold', 0.5, ...
    'metrics', struct('name', 'f1', 'value', 0, 'tolRel', 1e-12)));
v = r.verdict;
end
function v = dc_bounds()
G = [1 1 2 2]; GL = {'a'}; P = [31 31 4 4]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'imageSize', [32 32]));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_badWidth()
try
    mas_detect_check([1 1 0 2], {'a'}, [1 1 2 2], {'a'}, 0.9, struct('iouThreshold', 0.5));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = dc_labelMismatch()
G = [1 1 2 2]; GL = {'a'}; P = [1 1 2 2]; PL = {'b'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_noIou()
try
    mas_detect_check([1 1 2 2], {'a'}, [1 1 2 2], {'a'}, 0.9, struct());
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = dc_xyxy()
try
    mas_detect_check([1 1 2 2], {'a'}, [1 1 2 2], {'a'}, 0.9, ...
        struct('iouThreshold', 0.5, 'boxFormat', 'xyxy'));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = dc_labelCount()
try
    mas_detect_check([1 1 2 2; 5 5 2 2], {'a'}, [1 1 2 2], {'a'}, 0.9, ...
        struct('iouThreshold', 0.5));
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function [G, GL, P, PL, S] = dc_multiclass()
G = [1 1 2 2; 10 10 2 2; 20 20 2 2];
GL = {'a'; 'a'; 'b'};
P = [1 1 2 2; 10 10 2 2; 20 20 2 2; 25 25 2 2];
PL = {'a'; 'a'; 'b'; 'b'};
S = [0.9; 0.8; 0.7; 0.6];
end
function v = dc_perClass()
[G, GL, P, PL, S] = dc_multiclass();
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
a = find([r.perClass.label] == "a", 1);
b = find([r.perClass.label] == "b", 1);
v = near(r.perClass(a).f1, 1, 1e-12) && near(r.perClass(b).f1, 2/3, 1e-12);
end
function v = dc_imbalance()
G = zeros(11, 4); GL = cell(11, 1);
for k = 1:10, G(k,:) = [1+5*k 1 2 2]; GL{k} = 'a'; end
G(11,:) = [100 100 2 2]; GL{11} = 'b';
P = G; PL = GL; S = (0.99:-0.01:0.89).';
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'metrics', struct('name', 'f1', 'value', 1, 'tolRel', 1e-12)));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_imbalanceMacro()
G = zeros(11, 4); GL = cell(11, 1);
for k = 1:10, G(k,:) = [1+5*k 1 2 2]; GL{k} = 'a'; end
G(11,:) = [100 100 2 2]; GL{11} = 'b';
P = G; PL = GL; S = (0.99:-0.01:0.89).';
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'metrics', struct('name', 'macroF1', 'value', 1, 'tolRel', 1e-12)));
v = r.verdict;
end
function v = dc_noSize()
G = [1 1 2 2]; GL = {'a'}; P = [1 1 2 2]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = local_status(r, 'boxBounds');
end
function v = dc_apCut()
G = [1 1 2 2; 5 5 2 2; 10 10 2 2]; GL = {'a'; 'a'; 'a'};
P = [1 1 2 2; 20 20 2 2; 5 5 2 2; 10 10 2 2]; PL = {'a'; 'a'; 'a'; 'a'};
S = [0.95; 0.90; 0.80; 0.70];
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5, ...
    'scoreThreshold', 0.85, 'scoreThresholdSource', 'validation'));
v = near(r.mAP, 1/3, 1e-12) && r.metrics.tp == 1 && r.metrics.fn == 2;
end
function v = dc_extraClass()
G = [1 1 2 2]; GL = {'a'}; P = [1 1 2 2; 20 20 2 2]; PL = {'a'; 'b'}; S = [0.9; 0.8];
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = dc_missedClass()
G = [1 1 2 2; 20 20 2 2]; GL = {'a'; 'b'}; P = [1 1 2 2]; PL = {'a'}; S = 0.9;
r = mas_detect_check(G, GL, P, PL, S, struct('iouThreshold', 0.5));
v = r.metrics.fn == 1 && strcmp(local_status(r, 'labelAlignment'), 'pass');
end

% ===========================================================================
% image-contract fixtures
% ===========================================================================
function [I0, I, L, edge] = ic_base()
I0 = uint8([zeros(4,2) 255*ones(4,3)]);
I = double(I0)/255;
L = [0 0 1 1 1; 0 0 1 1 1; 0 0 1 1 1; 0 0 1 1 1];
edge = logical([0 0 1 0 0; 0 0 1 0 0; 0 0 1 0 0; 0 0 1 0 0]);
end
function c = ic_claims()
[~, ~, L, edge] = ic_base();
c = struct();
c.expectedSize = [4 5];
c.expectedClass = 'double';
c.expectedRange = [0 1];
c.space = 'gray';
c.labels = L;
c.normalization = struct('original', uint8([zeros(4,2) 255*ones(4,3)]), ...
    'inverse', @(z) uint8(round(z*255)), 'forward', @(o) double(o)/255);
c.transform = [2 0 0; 0 2 0; 0 0 1];
c.points = [1 1; 2 2];
c.pointsTransformed = [2 2; 4 4];
c.outputSize = [16 20];
c.edgeMap = edge;
c.edgeTruth = edge;
c.edgeTolPx = 1;
c.edgeF1Min = 0.9;
c.features = [1 1; 5 4];
c.featureTruth = [1 1; 5 4];
c.featureF1Min = 0.9;
c.split = struct('trainIdx', [1 2 3], 'valIdx', [4 5 6], ...
    'sampleHash', ["a" "b" "c" "d" "e" "f"], ...
    'groups', [1 1 1 2 2 2], 'tunedOn', 'train', 'reportedOn', 'validation');
end
function v = ic_full()
[~, I] = ic_base();
r = mas_image_contract(I, ic_claims());
v = r.verdict;
end
function v = ic_size()
[~, I] = ic_base(); c = ic_claims(); c.expectedSize = [5 4];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_class()
[~, I] = ic_base(); c = ic_claims(); c.expectedClass = 'uint8';
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_range()
[~, I] = ic_base(); c = ic_claims(); c.expectedRange = [0 0.5];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_space()
[~, I] = ic_base(); c = ic_claims(); c.space = 'rgb';
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_labelAlign()
[~, I] = ic_base(); c = ic_claims(); c.labels = zeros(4, 4);
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_labelClass()
[~, I] = ic_base(); c = ic_claims(); c.labelClasses = [0];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_normFail()
[~, I] = ic_base(); c = ic_claims();
c.normalization.inverse = @(z) uint8(round(z*255)) + uint8(1);
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_fwdFail()
[~, I] = ic_base(); c = ic_claims();
c.normalization.forward = @(o) double(o)/510;
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_singular()
[~, I] = ic_base(); c = ic_claims();
c.transform = [1 0 0; 0 0 0; 0 0 1];
c = rmfield(c, {'points', 'pointsTransformed', 'outputSize'});
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_pointsWrong()
[~, I] = ic_base(); c = ic_claims();
c.pointsTransformed = [2 2; 5 5];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_transBounds()
[~, I] = ic_base(); c = ic_claims();
c.outputSize = [3 3];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_nonAffine()
[~, I] = ic_base(); c = ic_claims();
c.transform = [1 0 0; 0 1 0; 0.1 0 1];
try
    mas_image_contract(I, c);
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end
function v = ic_edgeShiftTol()
[~, I] = ic_base(); c = ic_claims();
c.edgeMap = logical([0 0 0 1 0; 0 0 0 1 0; 0 0 0 1 0; 0 0 0 1 0]);
r = mas_image_contract(I, c);
v = r.verdict;
end
function v = ic_edgeShiftStrict()
[~, I] = ic_base(); c = ic_claims();
c.edgeMap = logical([0 0 0 1 0; 0 0 0 1 0; 0 0 0 1 0; 0 0 0 1 0]);
c.edgeTolPx = 0;
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_edgeAllOnes()
[~, I] = ic_base(); c = ic_claims();
c.edgeMap = true(4, 5);
r = mas_image_contract(I, c);
v = strcmp(local_status(r, 'edgeF1'), 'fail') && r.edge.precision < 0.9 && ...
    near(r.edge.recall, 1, 0);
end
function v = ic_edgeNoTruth()
[~, I] = ic_base(); c = ic_claims();
c = rmfield(c, 'edgeTruth');
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_edgeNoCrit()
[~, I] = ic_base(); c = ic_claims();
c = rmfield(c, 'edgeF1Min');
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_featOob()
[~, I] = ic_base(); c = ic_claims(); c.features = [6 1];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_featDup()
[~, I] = ic_base(); c = ic_claims(); c.features = [1 1; 1 1];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_featCount()
[~, I] = ic_base(); c = ic_claims(); c.minFeatures = 3;
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_featTruth()
[~, I] = ic_base(); c = ic_claims(); c.featureTruth = [2 2; 5 4];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_splitOk()
[~, I] = ic_base(); r = mas_image_contract(I, ic_claims());
v = r.verdict;
end
function v = ic_splitOverlap()
[~, I] = ic_base(); c = ic_claims(); c.split.valIdx = [3 4 5];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_contentLeak()
[~, I] = ic_base(); c = ic_claims();
c.split.sampleHash = ["a" "b" "c" "a" "e" "f"];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_groupLeak()
[~, I] = ic_base(); c = ic_claims();
c.split.groups = [1 2 1 1 2 2];
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_noHashes()
[~, I] = ic_base(); c = ic_claims();
c.split = rmfield(c.split, 'sampleHash');
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_oneSplit()
[~, I] = ic_base(); c = ic_claims();
c.split = struct('trainIdx', [1 2 3]);
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_tuneTest()
[~, I] = ic_base(); c = ic_claims();
c.split.tunedOn = 'test'; c.split.reportedOn = 'test';
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_thrTest()
[~, I] = ic_base(); c = ic_claims();
c.threshold = 0.5; c.thresholdSource = 'test';
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_thrNoSrc()
[~, I] = ic_base(); c = ic_claims(); c.threshold = 0.5;
r = mas_image_contract(I, c);
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_noClaims()
[~, I] = ic_base();
r = mas_image_contract(I, struct());
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_nan()
[~, I] = ic_base(); I(1) = NaN;
r = mas_image_contract(I, struct('expectedSize', [4 5]));
v = sprintf('%s/%s', r.verdict, local_bad(r));
end
function v = ic_nanAllowed()
[~, I] = ic_base(); I(1) = NaN;
r = mas_image_contract(I, struct('expectedSize', [4 5], 'requireFinite', false));
v = r.verdict;
end
function v = ic_featPrecision()
[~, I] = ic_base(); c = ic_claims();
c.features = [1 1; 5 4; 2 3];
r = mas_image_contract(I, c);
v = near(r.features.precision, 2/3, 1e-12) && near(r.features.recall, 1, 1e-12);
end
function v = ic_identity()
[~, I] = ic_base(); c = ic_claims();
c.transform = eye(3); c.points = [1 1; 5 4]; c.pointsTransformed = [1 1; 5 4];
r = mas_image_contract(I, c);
v = r.verdict;
end
function v = ic_edgeEmpty()
[~, I] = ic_base(); c = ic_claims();
c.edgeMap = false(4,5); c.edgeTruth = false(4,5); c.edgeF1Min = 1;
r = mas_image_contract(I, c);
v = r.verdict;
end

% ===========================================================================
% helpers
% ===========================================================================
function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end

function s = local_status(r, id)
k = find(strcmp({r.checks.id}, id), 1);
if isempty(k), s = 'missing'; else, s = r.checks(k).status; end
end

function s = local_bad(r)
s = 'none';
for k = 1:numel(r.checks)
    if strcmp(r.checks(k).status, 'fail') || strcmp(r.checks(k).status, 'undetermined')
        s = r.checks(k).id;
        return;
    end
end
end

function v = near(a, b, tol)
v = isfinite(a) && isfinite(b) && abs(a-b) <= tol;
end

function out = tern(cond, a, b)
if cond, out = a; else, out = b; end
end
