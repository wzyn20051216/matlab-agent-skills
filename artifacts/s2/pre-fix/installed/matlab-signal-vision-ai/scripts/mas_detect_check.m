function r = mas_detect_check(gtBoxes, gtLabels, predBoxes, predLabels, predScores, claims)
%MAS_DETECT_CHECK  Grade detections with one-to-one matching at an explicit IoU threshold.
%
%   r = mas_detect_check(gtBox, gtLab, predBox, predLab, scores, struct( ...
%           'iouThreshold', 0.5, 'imageSize', [480 640], ...
%           'scoreThreshold', 0.3, 'scoreThresholdSource', 'validation', ...
%           'metrics', struct('name','f1','value',0.75,'tolRel',0.02)));
%
% Boxes are [x y w h] with x,y the 1-based coordinate of the top-left corner and
% w,h > 0. A box covers [x, x+w) x [y, y+h); with imageSize [H W] the valid range
% is x >= 1, y >= 1, x+w <= W+1, y+h <= H+1.
%
% gtLabels / predLabels: numeric, string, cellstr or categorical, one per box.
% predScores: finite scores; higher is better and defines matching priority.
%
% claims fields:
%   .iouThreshold          REQUIRED; match threshold in (0,1]
%   .imageSize             [H W]; enables the box-bounds check
%   .scoreThreshold        operating score threshold (default 0 = keep all)
%   .scoreThresholdSource  'train' | 'validation' | 'spec' | 'none' | 'test'
%   .scoreSweep            thresholds reported for sensitivity (default 0.05:0.15:0.95)
%   .maxSensitivity        fail if micro-F1 range over the sweep exceeds this
%   .imbalanceLimit        majority-class share above which a micro-only claim
%                          cannot support a conclusion (default 0.9)
%   .metrics               struct array name/value/tolRel/tolAbs
%
% metric names: precision, recall, f1 (micro), macroF1, mAP, tp, fp, fn,
% duplicateCandidates.
%
% Returns
%   r.verdict   PASS | FAIL | UNDETERMINED
%   r.checks    id / status / detail
%   r.metrics   micro precision/recall/F1, macroF1, mAP, tp/fp/fn, nGt/nPred
%   r.perClass  gtCount, predCount, tp/fp/fn, precision, recall, f1, ap
%   r.matches   per prediction: score, best GT, IoU, TP/FP, duplicate candidate
%   r.scoreSweep, r.imbalance, r.detail
%
% MATCHING CONTRACT
% - Per class, predictions are visited in descending score order and each is
%   matched to the highest-IoU UNUSED ground-truth box of the same class.
% - A second prediction on an already-matched GT is a FALSE POSITIVE (reported
%   as a duplicate candidate), never a second true positive. This is the
%   duplicate-detection defect that inflates recall when matching is many-to-one.
% - Predictions of a class absent from GT are false positives; they are never
%   dropped. A predicted label that is absent from the GT label set ALSO raises
%   a label-alignment warning, because a class-name mapping error looks exactly
%   like a detector that invented a class.
% - AP is all-point interpolated (precision envelope) per class; mAP averages
%   only classes with at least one GT box. Classes with no GT have no AP.
% - Empty conventions: no GT and no predictions is P=R=F1=1 (vacuous); no GT
%   with predictions is P=0, R undefined, F1=0; GT with no predictions is
%   P undefined, R=0, F1=0. 0/0 is never reported as a good score.
% - A score threshold tuned on the evaluation set fails its provenance check;
%   no stated source is UNDETERMINED. No tolerance on a claim is UNDETERMINED.

if nargin < 6, error('mas_detect_check:args', 'need gt, gtLabels, pred, predLabels, scores and claims'); end
if ~isstruct(claims), error('mas_detect_check:claims', 'claims must be a struct'); end
if ~isfield(claims, 'iouThreshold') || isempty(claims.iouThreshold)
    error('mas_detect_check:iouThreshold', 'claims.iouThreshold is required (matching is meaningless without it)');
end
iouThr = claims.iouThreshold;
if ~isscalar(iouThr) || ~isfinite(iouThr) || iouThr <= 0 || iouThr > 1
    error('mas_detect_check:iouThreshold', 'iouThreshold must lie in (0,1]');
end
if isfield(claims, 'boxFormat') && ~strcmpi(char(claims.boxFormat), 'xywh')
    error('mas_detect_check:boxFormat', 'only [x y w h] boxes are supported');
end

[gtB, gtK] = local_boxes(gtBoxes, gtLabels, 'gt');
[pB, pK, pS] = local_pred(predBoxes, predLabels, predScores);
if isfield(claims, 'imageSize') && ~isempty(claims.imageSize)
    isz = claims.imageSize;
    if numel(isz) ~= 2 || any(~isfinite(isz)) || any(isz <= 0)
        error('mas_detect_check:imageSize', 'imageSize must be [H W] with positive finite values');
    end
else
    isz = [];
end

C = local_check_empty();
r = struct();
r.iouThreshold = iouThr;
nGt = size(gtB, 1); nPred = size(pB, 1);

% ---- box geometry and bounds --------------------------------------------
C = local_check_add(C, 'iouThreshold', true, sprintf('one-to-one matching at IoU >= %.4g', iouThr));
if ~isempty(isz)
    [badG, msgG] = local_bounds(gtB, isz);
    [badP, msgP] = local_bounds(pB, isz);
    if badG + badP == 0
        C = local_check_add(C, 'boxBounds', true, sprintf( ...
            'all %d GT and %d predicted boxes lie inside %dx%d (HxW)', ...
            size(gtB,1), size(pB,1), isz(1), isz(2)));
    else
        C = local_check_add(C, 'boxBounds', false, sprintf( ...
            '%d GT and %d predicted box(es) fall outside [1,W]x[1,H]; %s %s', ...
            badG, badP, msgG, msgP));
    end
else
    C = local_check_add(C, 'boxBounds', 'na', 'no imageSize supplied: coordinates cannot be bounds-checked');
end

% ---- label alignment -----------------------------------------------------
extraPred = setdiff(pK, gtK);
if nGt == 0
    C = local_check_add(C, 'labelAlignment', 'na', ...
        'GT has no boxes: there is no label set to align predictions against');
elseif isempty(extraPred)
    C = local_check_add(C, 'labelAlignment', true, sprintf( ...
        '%d predicted class(es) all exist in the GT label set; %d GT class(es) unpredicted', ...
        numel(unique(pK)), numel(setdiff(gtK, pK))));
else
    C = local_check_add(C, 'labelAlignment', 'undetermined', sprintf( ...
        ['predicted label(s) %s are absent from GT: verify the class-name mapping ' ...
         'before reading these false positives as real'], strjoin(cellstr(extraPred), ', ')));
end

classList = sort(unique([gtK; pK]));
if isempty(classList), classList = strings(0,1); end

% ---- operating-point score threshold ------------------------------------
scoreThr = local_field(claims, 'scoreThreshold', 0);
if ~isscalar(scoreThr) || ~isfinite(scoreThr)
    error('mas_detect_check:scoreThreshold', 'scoreThreshold must be finite scalar');
end
keep = true(nPred, 1);
if scoreThr > 0, keep = pS >= scoreThr; end
E = local_eval(gtB, gtK, pB(keep,:), pK(keep), pS(keep), classList, iouThr);

r.metrics = E.micro;
r.metrics.macroF1 = E.macroF1;
r.metrics.nGt = nGt;
r.metrics.nPred = nnz(keep);
r.metrics.tp = E.tp; r.metrics.fp = E.fp; r.metrics.fn = E.fn;
r.perClass = E.perClass;
r.matches = E.matches;
r.scoreThreshold = scoreThr;
r.nFiltered = nPred - nnz(keep);
r.duplicateCandidates = E.duplicateCandidates;

if scoreThr > 0
    src = local_field(claims, 'scoreThresholdSource', '');
    switch lower(char(src))
        case {'train', 'validation', 'spec', 'none'}
            C = local_check_add(C, 'scoreThresholdSource', true, ...
                sprintf('score threshold %.4g sourced from %s', scoreThr, char(src)));
        case 'test'
            C = local_check_add(C, 'scoreThresholdSource', false, sprintf( ...
                ['score threshold %.4g was tuned on the evaluation set: ' ...
                 'precision/recall/F1 are optimistically biased'], scoreThr));
        otherwise
            C = local_check_add(C, 'scoreThresholdSource', 'undetermined', ...
                'score threshold has no stated source; train/validation/spec is required');
    end
else
    C = local_check_add(C, 'scoreThresholdSource', 'na', ...
        'no positive score threshold applied: all predictions are evaluated');
end

% empty conventions, reported for the operating point
if r.metrics.nGt == 0 && r.metrics.nPred == 0
    C = local_check_add(C, 'emptyPolicy', true, ...
        'no GT and no prediction: P/R/F1 = 1 by stated convention (vacuous)');
elseif r.metrics.nGt == 0
    C = local_check_add(C, 'emptyPolicy', true, ...
        sprintf('no GT and %d prediction(s): P=0, R undefined, F1=0; every prediction is FP', r.metrics.nPred));
elseif r.metrics.nPred == 0
    C = local_check_add(C, 'emptyPolicy', true, ...
        sprintf('%d GT box(es) and no prediction: P undefined, R=0, F1=0; every GT is FN', r.metrics.nGt));
else
    C = local_check_add(C, 'emptyPolicy', true, ...
        sprintf('%d GT / %d prediction(s) evaluated', r.metrics.nGt, r.metrics.nPred));
end

% ---- AP / mAP from the matching order -----------------------------------
ap = NaN(1, numel(classList));
for k = 1:numel(classList)
    nG = E.perClass(k).gtCount;
    if nG == 0, continue; end
    idx = E.perClass(k).predIdx;
    mask = E.perClass(k).tpMask;
    if isempty(idx)
        ap(k) = 0;
        continue;
    end
    tpCum = cumsum(double(mask(:)));
    fpCum = (1:numel(mask)).' - tpCum;
    rec = tpCum / nG;
    prec = tpCum ./ max(tpCum + fpCum, 1);
    rU = unique(rec).';
    if isempty(rU)
        ap(k) = 0;
    else
        pAt = zeros(size(rU));
        for j = 1:numel(rU)
            pAt(j) = max(prec(rec >= rU(j)));
        end
        ap(k) = sum(diff([0, rU]) .* pAt);
    end
end
for k = 1:numel(classList), r.perClass(k).ap = ap(k); end
r.mAP = mean(ap(isfinite(ap)));
r.metrics.mAP = r.mAP;
r.apPerClass = ap;

% ---- imbalance disclosure ------------------------------------------------
gtCounts = zeros(1, numel(classList));
for k = 1:numel(classList), gtCounts(k) = nnz(gtK == classList(k)); end
if nGt > 0
    shares = gtCounts / nGt;
    majorityShare = max(shares);
    minShare = min(shares(shares > 0));
    if isempty(minShare), minShare = 1; end
else
    majorityShare = 0; minShare = 1;
end
r.imbalance = struct('majorityShare', majorityShare, 'minorityShare', minShare, ...
    'ratio', majorityShare/max(minShare, eps), 'gtCounts', gtCounts);
C = local_check_add(C, 'imbalance', true, sprintf( ...
    'majority class covers %.1f %% of GT; per-class and macro values reported', 100*majorityShare));

% ---- score sweep ---------------------------------------------------------
r.scoreSweep = struct('threshold', {}, 'nPred', {}, 'precision', {}, ...
    'recall', {}, 'f1', {});
sweep = local_field(claims, 'scoreSweep', 0.05:0.15:0.95);
sweep = sort(unique(sweep(:).'));
for t = sweep
    keepT = pS >= t;
    ET = local_eval(gtB, gtK, pB(keepT,:), pK(keepT), pS(keepT), classList, iouThr);
    r.scoreSweep(end+1) = struct('threshold', t, 'nPred', nnz(keepT), ...
        'precision', ET.micro.precision, 'recall', ET.micro.recall, ...
        'f1', ET.micro.f1); %#ok<AGROW>
end
f1s = [r.scoreSweep.f1];
finiteF1 = f1s(isfinite(f1s));
if isempty(finiteF1)
    C = local_check_add(C, 'scoreSensitivity', 'na', 'no threshold produced a defined F1');
else
    [bestF1, bi] = max(f1s);
    r.bestScoreThreshold = r.scoreSweep(bi).threshold;
    r.bestF1 = bestF1;
    r.sensitivityF1Range = max(finiteF1) - min(finiteF1);
    maxSens = local_field(claims, 'maxSensitivity', []);
    if isempty(maxSens)
        C = local_check_add(C, 'scoreSensitivity', true, sprintf( ...
            'F1 ranges %.4f over score thresholds %.2f..%.2f (best %.4f at %.2f)', ...
            r.sensitivityF1Range, min(sweep), max(sweep), bestF1, r.bestScoreThreshold));
    else
        C = local_check_add(C, 'scoreSensitivity', r.sensitivityF1Range <= maxSens, sprintf( ...
            'F1 range %.4f vs limit %.4f over score thresholds', r.sensitivityF1Range, maxSens));
    end
end

% ---- metric claims -------------------------------------------------------
MC = local_metric_claims(claims);
if isempty(MC)
    C = local_check_add(C, 'claims', 'undetermined', ...
        'no metric claim with a tolerance was supplied: metrics are computed but not accepted');
else
    microOnly = true;
    for k = 1:numel(MC)
        name = lower(char(MC(k).name));
        if any(strcmp(name, {'macrof1','map'}))
            microOnly = false;
        end
        [actual, known] = local_metric_value(r, name);
        if ~known
            C = local_check_add(C, ['claim_' name], 'na', ...
                sprintf('metric "%s" is not part of this contract', name));
            continue
        end
        if ~isfinite(MC(k).value)
            C = local_check_add(C, ['claim_' name], 'undetermined', 'claim value is missing or non-finite');
            continue
        end
        if ~(isfinite(MC(k).tolRel) || isfinite(MC(k).tolAbs))
            C = local_check_add(C, ['claim_' name], 'undetermined', sprintf( ...
                'claimed %s = %.6g but no tolerance was stated; deviation is not graded', ...
                name, MC(k).value));
            continue
        end
        if isnan(actual)
            C = local_check_add(C, ['claim_' name], 'undetermined', sprintf( ...
                'claimed %s = %.6g but the metric is undefined at this operating point', ...
                name, MC(k).value));
            continue
        end
        if isfinite(MC(k).tolAbs)
            tol = MC(k).tolAbs;
        else
            tol = MC(k).tolRel * max(1, abs(MC(k).value));
        end
        dev = abs(actual - MC(k).value);
        C = local_check_add(C, ['claim_' name], dev <= tol, sprintf( ...
            'claimed %s = %.6g vs measured %.6g (dev %.3g, tol %.3g)', ...
            name, MC(k).value, actual, dev, tol));
    end
    if microOnly && nnz(gtCounts > 0) >= 2 && ...
            majorityShare > local_field(claims, 'imbalanceLimit', 0.9)
        C = local_check_add(C, 'imbalanceDisclosure', 'undetermined', sprintf( ...
            ['micro precision/recall/F1 was the only claim and the majority class ' ...
             'covers %.1f %% of GT: micro averages hide the minority classes'], ...
            100*majorityShare));
    end
end

r.checks = C;
sts = {C.status};
if any(strcmp(sts, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(sts, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.detail = sprintf(['nGt %d, nPred %d, TP %d, FP %d, FN %d, P %.4f, R %.4f, ' ...
    'F1 %.4f, macroF1 %.4f, mAP %.4f (IoU >= %.2f)'], r.metrics.nGt, ...
    r.metrics.nPred, r.metrics.tp, r.metrics.fp, r.metrics.fn, ...
    r.metrics.precision, r.metrics.recall, r.metrics.f1, r.metrics.macroF1, ...
    r.mAP, iouThr);
end

% ===========================================================================
function [B, K] = local_boxes(B, L, what)
if isempty(B)
    B = zeros(0, 4);
else
    if ~isnumeric(B) || size(B, 2) ~= 4
        error('mas_detect_check:boxes', '%sBoxes must be an N x 4 numeric matrix', what);
    end
    if any(~isfinite(B(:))), error('mas_detect_check:boxFinite', '%sBoxes contain NaN or Inf', what); end
    if any(B(:,3) <= 0) || any(B(:,4) <= 0)
        error('mas_detect_check:boxSize', '%s boxes must have width and height > 0', what);
    end
end
if isempty(L)
    K = strings(0, 1);
else
    K = local_keys(L);
    if numel(K) ~= size(B, 1)
        error('mas_detect_check:labels', '%sLabels has %d entries for %d boxes', what, numel(K), size(B,1));
    end
end
end

function [B, K, S] = local_pred(B, L, S)
if isempty(B)
    B = zeros(0, 4);
else
    if ~isnumeric(B) || size(B, 2) ~= 4
        error('mas_detect_check:boxes', 'predBoxes must be an N x 4 numeric matrix');
    end
    if any(~isfinite(B(:))), error('mas_detect_check:boxFinite', 'predBoxes contain NaN or Inf'); end
    if any(B(:,3) <= 0) || any(B(:,4) <= 0)
        error('mas_detect_check:boxSize', 'predicted boxes must have width and height > 0');
    end
end
if isempty(L)
    K = strings(0, 1);
else
    K = local_keys(L);
end
if isempty(S)
    S = zeros(0, 1);
else
    S = S(:);
    if ~isnumeric(S) || numel(S) ~= size(B, 1)
        error('mas_detect_check:scores', 'predScores must have one finite value per predicted box');
    end
    if any(~isfinite(S)), error('mas_detect_check:scores', 'predScores contain NaN or Inf'); end
end
if numel(K) ~= size(B,1)
    error('mas_detect_check:labels', 'predLabels has %d entries for %d boxes', numel(K), size(B,1));
end
end

function K = local_keys(L)
if iscategorical(L), L = string(L); end
if isnumeric(L) || islogical(L)
    K = string(L(:));
elseif iscellstr(L) || isstring(L)
    K = string(L(:));
else
    error('mas_detect_check:labelType', 'labels must be numeric, string, cellstr or categorical');
end
if any(ismissing(K)), error('mas_detect_check:labelMissing', 'labels contain missing values'); end
end

function [bad, msg] = local_bounds(B, isz)
H = isz(1); W = isz(2);
bad = 0; msg = '';
if isempty(B), return; end
outside = B(:,1) < 1 | B(:,2) < 1 | ...
    B(:,1) + B(:,3) > W + 1 | B(:,2) + B(:,4) > H + 1;
bad = nnz(outside);
if bad > 0
    first = find(outside, 1);
    msg = sprintf('first out-of-bounds box at index %d: [%g %g %g %g]', ...
        first, B(first,1), B(first,2), B(first,3), B(first,4));
end
end

function E = local_eval(gtB, gtK, pB, pK, pS, classList, iouThr)
nC = numel(classList);
% A scalar logical mask (single prediction, sweep cut-off) yields 0x0 empties,
% not 0x1; normalise so cell-array fields in E.matches keep one shape.
pK = pK(:); pS = pS(:);
perClass = struct('label', {}, 'gtCount', {}, 'predCount', {}, 'tp', {}, ...
    'fp', {}, 'fn', {}, 'precision', {}, 'recall', {}, 'f1', {}, ...
    'ap', {}, 'predIdx', {}, 'tpMask', {}, 'duplicateMask', {});
m = size(pB, 1);
matchGt = zeros(m, 1);
matchIou = zeros(m, 1);
isTp = false(m, 1);
dup = false(m, 1);
for k = 1:nC
    c = classList(k);
    gtIdx = find(gtK == c);
    prIdx = find(pK == c);
    [~, ord] = sort(pS(prIdx), 'descend');   % stable on ties: original order
    prIdx = prIdx(ord);
    taken = false(numel(gtIdx), 1);
    tpMask = false(numel(prIdx), 1);
    dupMask = false(numel(prIdx), 1);
    for ii = 1:numel(prIdx)
        p = prIdx(ii);
        best = 0; bj = 0;
        for j = 1:numel(gtIdx)
            g = gtIdx(j);
            v = local_iou(pB(p,:), gtB(g,:));
            if v > best, best = v; bj = j; end
        end
        matchGt(p) = 0; matchIou(p) = best;
        if best >= iouThr && bj > 0
            if ~taken(bj)
                taken(bj) = true;
                tpMask(ii) = true;
                isTp(p) = true;
                matchGt(p) = gtIdx(bj);
            else
                dupMask(ii) = true;
                dup(p) = true;
            end
        end
    end
    tp = nnz(tpMask); fp = numel(prIdx) - tp; fn = nnz(~taken);
    if tp+fp == 0, prec = NaN; else, prec = tp/(tp+fp); end
    if tp+fn == 0, rec = NaN; else, rec = tp/(tp+fn); end
    if tp+fp+fn == 0
        f1 = 1;
    else
        f1 = 2*tp / max(2*tp+fp+fn, 1);
    end
    perClass(end+1) = struct('label', c, 'gtCount', numel(gtIdx), ...
        'predCount', numel(prIdx), 'tp', tp, 'fp', fp, 'fn', fn, ...
        'precision', prec, 'recall', rec, 'f1', f1, 'ap', NaN, ...
        'predIdx', prIdx(:), 'tpMask', tpMask, 'duplicateMask', dupMask); %#ok<AGROW>
end
TP = sum([perClass.tp]); FP = sum([perClass.fp]); FN = sum([perClass.fn]);
if TP+FP+FN == 0
    P = 1; R = 1; F1 = 1;
else
    if TP+FP == 0, P = NaN; else, P = TP/(TP+FP); end
    if TP+FN == 0, R = NaN; else, R = TP/(TP+FN); end
    F1 = 2*TP / max(2*TP+FP+FN, 1);
end
gtClasses = [perClass.gtCount] > 0;
if any(gtClasses)
    macroF1 = mean([perClass(gtClasses).f1]);
else
    macroF1 = NaN;
end
E = struct();
E.perClass = perClass;
E.tp = TP; E.fp = FP; E.fn = FN;
E.duplicateCandidates = nnz(dup);
E.macroF1 = macroF1;
E.micro = struct('precision', P, 'recall', R, 'f1', F1);
E.matches = struct('index', num2cell((1:m).'), 'label', cellstr(pK), ...
    'score', num2cell(pS), 'gtIndex', num2cell(matchGt), ...
    'iou', num2cell(matchIou), 'isTp', num2cell(isTp), ...
    'duplicateCandidate', num2cell(dup));
E.isTp = isTp; E.dup = dup;
end

function v = local_iou(a, b)
ix1 = max(a(1), b(1));
iy1 = max(a(2), b(2));
ix2 = min(a(1)+a(3), b(1)+b(3));
iy2 = min(a(2)+a(4), b(2)+b(4));
iw = max(0, ix2-ix1);
ih = max(0, iy2-iy1);
inter = iw*ih;
union = a(3)*a(4) + b(3)*b(4) - inter;
if union <= 0, v = 0; else, v = inter/union; end
end

function MC = local_metric_claims(claims)
MC = struct('name', {}, 'value', {}, 'tolRel', {}, 'tolAbs', {});
raw = {};
if isfield(claims, 'metric') && ~isempty(claims.metric), raw{end+1} = claims.metric; end
if isfield(claims, 'metrics') && ~isempty(claims.metrics), raw{end+1} = claims.metrics; end
for rIdx = 1:numel(raw)
    s = raw{rIdx};
    if ~isstruct(s), error('mas_detect_check:metric', 'metric claims must be structs'); end
    for k = 1:numel(s)
        if ~isfield(s(k), 'name'), error('mas_detect_check:metricName', 'each metric needs a name'); end
        m = struct('name', char(string(s(k).name)), 'value', NaN, 'tolRel', NaN, 'tolAbs', NaN);
        if isfield(s(k), 'value'), m.value = double(s(k).value); end
        if isfield(s(k), 'tolRel'), m.tolRel = double(s(k).tolRel); end
        if isfield(s(k), 'tolAbs'), m.tolAbs = double(s(k).tolAbs); end
        MC(end+1) = m; %#ok<AGROW>
    end
end
end

function [v, known] = local_metric_value(r, name)
known = true;
switch name
    case {'precision', 'microprecision'}, v = r.metrics.precision;
    case {'recall', 'microrecall'}, v = r.metrics.recall;
    case {'f1', 'microf1'}, v = r.metrics.f1;
    case 'macrof1', v = r.metrics.macroF1;
    case 'map', v = r.metrics.mAP;
    case 'tp', v = r.metrics.tp;
    case 'fp', v = r.metrics.fp;
    case 'fn', v = r.metrics.fn;
    case 'duplicatecandidates', v = r.duplicateCandidates;
    otherwise
        v = NaN; known = false;
end
end

function v = local_field(s, f, dflt)
v = dflt;
if isfield(s, f) && ~isempty(s.(f)), v = s.(f); end
end

function C = local_check_empty()
C = struct('id', {}, 'status', {}, 'detail', {});
end

function C = local_check_add(C, id, pass, detail)
if ischar(pass)
    st = pass;
elseif isnan(pass)
    st = 'undetermined';
elseif pass
    st = 'pass';
else
    st = 'fail';
end
C(end+1) = struct('id', id, 'status', st, 'detail', detail); %#ok<AGROW>
end
