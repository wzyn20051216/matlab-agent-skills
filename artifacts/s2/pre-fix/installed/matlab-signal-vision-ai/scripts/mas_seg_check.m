function r = mas_seg_check(pred, truth, claims)
%MAS_SEG_CHECK  Grade a segmentation against its label map, pixels and objects kept apart.
%
%   r = mas_seg_check(predMask, trueMask)                 % metrics only, no verdict
%   r = mas_seg_check(predLabels, trueLabels, struct( ...
%           'background', 0, 'iouThreshold', 0.5, ...
%           'metrics', struct('name','f1','value',0.82,'tolRel',0.02)))
%
%   pred, truth   label maps of the same size (numeric or logical). Integer
%                 labels only; for a probability map set claims.scoreMap=true
%                 and give claims.decisionThreshold.
%   claims fields:
%     .classes          labels to evaluate (default: union of pred and truth)
%     .background        background label (default 0)
%     .iouThreshold      object-match IoU threshold (default 0.5; an object-
%                        metric claim without an explicit value is UNDETERMINED)
%     .scoreMap          pred is a score map in [0,1] (default false)
%     .decisionThreshold threshold applied to a score map (required then)
%     .thresholdSource   'train' | 'validation' | 'spec' | 'none' | 'test'
%     .thresholdSweep    thresholds reported for sensitivity (default 0.1:0.2:0.9)
%     .maxSensitivity    fail if the F1 range over the sweep exceeds this
%     .imbalanceLimit    majority-class share above which an accuracy-only
%                        claim cannot support a quality conclusion (default 0.9)
%     .exactRecount      require two independent pixel routes to agree (default true)
%     .metrics           struct array with name, value, tolRel or tolAbs
%
%   metric names: iou (foreground union), binaryIoU, dice, precision, recall,
%   f1 (foreground micro), accuracy, macroF1, macroIoU, macroIoUForeground,
%   objectIouMean, objectIouWorst, objectRecall, objectPrecision, matchedFraction.
%
% Returns
%   r.verdict     PASS | FAIL | UNDETERMINED
%   r.checks      id / status (pass | fail | na | undetermined) / detail
%   r.metrics     binary foreground metrics + pixel accuracy + macro values
%   r.perClass    per-class tp/fp/fn, precision, recall, f1, iou, support
%   r.objects     per predicted component: class, area, matched truth label, IoU
%   r.objectMetrics, r.imbalance, r.thresholdSweep, r.detail
%
% WHAT THIS REFUSES TO CONFLATE
% 1. Pixel accuracy is not segmentation quality. A 95 % majority background
%    predicts 95 % accurately while finding nothing, so per-class values are
%    always reported and an accuracy-only claim on imbalanced data is
%    UNDETERMINED -- the number is true, the conclusion is not supported.
% 2. Pixel IoU is not object IoU. A mask covering the correct total area in the
%    wrong place has high pixel recall and zero object IoU; objects are matched
%    one-to-one by IoU at an EXPLICIT threshold, so duplicates are false
%    positives rather than a second match.
% 3. An empty prediction and an empty truth is a perfect match (IoU = 1) by
%    convention; an empty truth with predictions is IoU = 0. 0/0 is never
%    silently returned as a good score.
% 4. A score threshold tuned on the set being reported is a leak. The source of
%    the threshold is part of the claim; 'test' fails, silence is UNDETERMINED.
% 5. A metric with no tolerance is not a criterion: the deviation is printed
%    and the claim is UNDETERMINED, never PASS.
%
% Coordinate and label conventions: both maps use the same array indexing
% (row = y, column = x); label values are pixel classes, not coordinates.
% Connected components use 4-connectivity, matching mas_image_metrics.

if nargin < 2, error('mas_seg_check:args', 'need pred and truth'); end
if nargin < 3 || isempty(claims), claims = struct(); end
if ~isstruct(claims), error('mas_seg_check:claims', 'claims must be a struct'); end

scoreMap = logical(local_field(claims, 'scoreMap', false));
bg = local_field(claims, 'background', 0);
if ~isscalar(bg) || ~isfinite(bg)
    error('mas_seg_check:background', 'background must be a finite scalar');
end
if ~isnumeric(pred) && ~islogical(pred)
    error('mas_seg_check:predType', 'pred must be numeric or logical, got %s', class(pred));
end
if ~isnumeric(truth) && ~islogical(truth)
    error('mas_seg_check:truthType', 'truth must be numeric or logical, got %s', class(truth));
end
if ~isequal(size(pred), size(truth))
    error('mas_seg_check:size', 'pred %s and truth %s differ in size; resize deliberately, never silently', ...
        mat2str(size(pred)), mat2str(size(truth)));
end
if isempty(pred), error('mas_seg_check:empty', 'the label maps are empty'); end
if any(~isfinite(truth(:))), error('mas_seg_check:truthNan', 'truth contains NaN or Inf labels'); end
if any(~isfinite(pred(:))), error('mas_seg_check:predNan', 'pred contains NaN or Inf values'); end
if ~isreal(pred) || ~isreal(truth), error('mas_seg_check:complex', 'label maps must be real'); end

if scoreMap
    thr = local_field(claims, 'decisionThreshold', []);
    if isempty(thr) || ~isscalar(thr) || ~isfinite(thr)
        error('mas_seg_check:threshold', 'claims.decisionThreshold is required for a score map');
    end
    if any(pred(:) < 0 | pred(:) > 1)
        error('mas_seg_check:scoreRange', 'score map values must lie in [0,1]');
    end
    if any(truth(:) ~= 0 & truth(:) ~= 1)
        error('mas_seg_check:scoreTruth', 'a score-map evaluation needs a binary truth (0/1)');
    end
    labels = double(pred >= thr);
    truth = double(truth);
else
    if any(pred(:) ~= round(pred(:)))
        error('mas_seg_check:predLabels', ['pred must hold integer labels; ' ...
            'set claims.scoreMap=true for a probability map']);
    end
    if any(truth(:) ~= round(truth(:)))
        error('mas_seg_check:truthLabels', 'truth must hold integer labels');
    end
    labels = double(pred);
    truth = double(truth);
end

C = local_check_empty();
classList = local_field(claims, 'classes', []);
if isempty(classList)
    classList = unique([truth(:); labels(:)]).';
else
    classList = classList(:).';
    if any(~isfinite(classList)) || any(classList ~= round(classList))
        error('mas_seg_check:classes', 'classes must be finite integer labels');
    end
    badT = setdiff(unique(truth(:)).', classList);
    badP = setdiff(unique(labels(:)).', classList);
    if ~isempty(badT) || ~isempty(badP)
        error('mas_seg_check:classesCover', ...
            'classes must cover every truth and predicted label (missing truth %s, pred %s)', ...
            mat2str(badT), mat2str(badP));
    end
end

isBinary = all(ismember(unique([truth(:); labels(:)]).', [0 1]));
hasBg = any(truth(:) == bg) || any(labels(:) == bg);
fgClasses = classList(classList ~= bg);

% ---- per-class pixel table, two independent routes ----------------------
nC = numel(classList);
ti = local_index(truth, classList);
pi = local_index(labels, classList);
T = accumarray([ti(:), pi(:)], 1, [nC, nC]);
tp = zeros(1, nC); fp = zeros(1, nC); fn = zeros(1, nC);
recountMax = 0;
for k = 1:nC
    c = classList(k);
    tp(k) = T(k, k);
    fp(k) = sum(T(:, k)) - tp(k);
    fn(k) = sum(T(k, :)) - tp(k);
    tp2 = nnz(truth == c & labels == c);
    fp2 = nnz(truth ~= c & labels == c);
    fn2 = nnz(truth == c & labels ~= c);
    recountMax = max([recountMax, abs(tp(k)-tp2), abs(fp(k)-fp2), abs(fn(k)-fn2)]);
end
if logical(local_field(claims, 'exactRecount', true))
    C = local_check_add(C, 'pixelRecount', recountMax == 0, ...
        sprintf('two pixel routes differ by at most %d pixel(s)', recountMax));
end

perClass = struct('label', {}, 'support', {}, 'predicted', {}, 'tp', {}, ...
    'fp', {}, 'fn', {}, 'precision', {}, 'recall', {}, 'f1', {}, 'iou', {});
for k = 1:nC
    denomP = tp(k) + fp(k);
    denomR = tp(k) + fn(k);
    if denomP == 0, prec = NaN; else, prec = tp(k)/denomP; end
    if denomR == 0, rec = NaN; else, rec = tp(k)/denomR; end
    if tp(k)+fp(k)+fn(k) == 0
        f1 = 1; iou = 1;
    else
        f1 = 2*tp(k) / max(2*tp(k)+fp(k)+fn(k), 1);
        iou = tp(k) / max(tp(k)+fp(k)+fn(k), 1);
    end
    perClass(end+1) = struct('label', classList(k), 'support', denomR, ...
        'predicted', denomP, 'tp', tp(k), 'fp', fp(k), 'fn', fn(k), ...
        'precision', prec, 'recall', rec, 'f1', f1, 'iou', iou); %#ok<AGROW>
end

% macro over classes actually supported by truth (recall defined), including bg
supported = [perClass.support] > 0;
if any(supported)
    macroF1 = mean([perClass(supported).f1]);
    macroIoU = mean([perClass(supported).iou]);
else
    macroF1 = NaN; macroIoU = NaN;
end
fgSupported = arrayfun(@(s) s.support > 0 && s.label ~= bg, perClass);
if any(fgSupported)
    macroIoUfg = mean([perClass(fgSupported).iou]);
else
    macroIoUfg = NaN;
end

% foreground union (binary and multi-class with a declared background)
if isBinary
    fgMaskP = labels == 1;
    fgMaskT = truth == 1;
    fgDefined = true;
elseif hasBg
    fgMaskP = labels ~= bg;
    fgMaskT = truth ~= bg;
    fgDefined = true;
else
    fgMaskP = false(size(labels));
    fgMaskT = false(size(truth));
    fgDefined = false;
end

if fgDefined
    btp = nnz(fgMaskP & fgMaskT);
    bfp = nnz(fgMaskP & ~fgMaskT);
    bfn = nnz(~fgMaskP & fgMaskT);
    if btp+bfp+bfn == 0
        bIou = 1; bDice = 1; bPrec = 1; bRec = 1; bF1 = 1;
    else
        bIou = btp / max(btp+bfp+bfn, 1);
        bDice = 2*btp / max(2*btp+bfp+bfn, 1);
        bPrec = btp / max(btp+bfp, 1);
        if btp+bfn == 0, bRec = NaN; else, bRec = btp/(btp+bfn); end
        bF1 = 2*btp / max(2*btp+bfp+bfn, 1);
    end
else
    btp = NaN; bfp = NaN; bfn = NaN;
    bIou = NaN; bDice = NaN; bPrec = NaN; bRec = NaN; bF1 = NaN;
end

acc = nnz(labels == truth) / numel(truth);
r = struct();
r.metrics = struct('accuracy', acc, 'binaryIoU', bIou, 'iou', bIou, ...
    'dice', bDice, 'precision', bPrec, 'recall', bRec, 'f1', bF1, ...
    'macroF1', macroF1, 'macroIoU', macroIoU, 'macroIoUForeground', macroIoUfg, ...
    'tp', btp, 'fp', bfp, 'fn', bfn);
r.perClass = perClass;
r.classes = classList;
r.background = bg;
r.isBinary = isBinary;
r.scoreMap = scoreMap;
r.decisionThreshold = NaN;
if scoreMap, r.decisionThreshold = thr; end

% empty-data conventions, stated once and checked
if fgDefined
    nTf = nnz(fgMaskT); nPf = nnz(fgMaskP);
    if nTf == 0 && nPf == 0
        C = local_check_add(C, 'emptyPolicy', true, ...
            'empty truth AND empty prediction: IoU/Dice/P/R/F1 = 1 by stated convention');
    elseif nTf == 0
        C = local_check_add(C, 'emptyPolicy', true, ...
            sprintf('empty truth with %d predicted foreground pixel(s): IoU 0, precision 0, recall undefined, F1 0', nPf));
    elseif nPf == 0
        C = local_check_add(C, 'emptyPolicy', true, ...
            sprintf('non-empty truth with no predicted foreground: IoU 0, precision undefined, recall 0, F1 0'));
    else
        C = local_check_add(C, 'emptyPolicy', true, ...
            sprintf('%d truth / %d predicted foreground pixels', nTf, nPf));
    end
else
    C = local_check_add(C, 'emptyPolicy', 'na', ...
        'no background label and not a binary map: foreground-union IoU is undefined; use macroIoU');
end

% ---- object-level matching (one-to-one, explicit threshold) -------------
iouThr = local_field(claims, 'iouThreshold', []);
iouThrStated = ~isempty(iouThr);
if isempty(iouThr), iouThr = 0.5; end
if ~isscalar(iouThr) || ~isfinite(iouThr) || iouThr <= 0 || iouThr > 1
    error('mas_seg_check:iouThreshold', 'iouThreshold must lie in (0,1]');
end
r.objectThreshold = iouThr;
r.objectThresholdStated = iouThrStated;
if iouThrStated
    C = local_check_add(C, 'iouThreshold', true, ...
        sprintf('object matching at explicitly stated IoU >= %.4g', iouThr));
end

O = struct('class', {}, 'predLabel', {}, 'area', {}, 'truthLabel', {}, ...
    'iou', {}, 'matched', {}, 'duplicateCandidate', {});
doObjects = exist('bwlabel', 'file') == 2 && fgDefined;
if doObjects
    for k = 1:numel(fgClasses)
        c = fgClasses(k);
        Lp = bwlabel(labels == c, 4);
        Lt = bwlabel(truth == c, 4);
        np = max(Lp(:)); nt = max(Lt(:));
        if np == 0, continue; end
        areas = zeros(1, np);
        for i = 1:np, areas(i) = nnz(Lp == i); end
        [~, order] = sort(areas, 'descend');
        used = false(1, nt);
        for ii = 1:numel(order)
            i = order(ii);
            pm = Lp == i;
            best = 0; bestj = 0;
            for j = 1:nt
                tm = Lt == j;
                un = nnz(pm | tm);
                if un == 0, continue; end
                v = nnz(pm & tm) / un;
                if v > best, best = v; bestj = j; end
            end
            matched = best >= iouThr && bestj > 0 && ~used(bestj);
            dup = best >= iouThr && bestj > 0 && used(bestj);
            if matched, used(bestj) = true; end
            O(end+1) = struct('class', c, 'predLabel', i, 'area', areas(i), ...
                'truthLabel', bestj, 'iou', best, 'matched', matched, ...
                'duplicateCandidate', dup); %#ok<AGROW>
        end
    end
else
    C = local_check_add(C, 'objectMatching', 'na', ...
        'bwlabel unavailable or foreground undefined: object metrics not computed');
end

r.objects = O;
if ~isempty(O)
    matched = [O.matched];
    nPred = numel(O);
    nTruthObj = 0;
    for k = 1:numel(fgClasses)
        Lt = bwlabel(truth == fgClasses(k), 4);
        nTruthObj = nTruthObj + max(Lt(:));
    end
    nMatch = nnz(matched);
    if nMatch > 0
        objMean = mean([O(matched).iou]);
        objWorst = min([O(matched).iou]);
    else
        objMean = NaN; objWorst = NaN;
    end
    r.objectMetrics = struct('nPredObjects', nPred, 'nTruthObjects', nTruthObj, ...
        'nMatched', nMatch, 'matchedFraction', nMatch/max(nPred,1), ...
        'objectIouMean', objMean, 'objectIouWorst', objWorst, ...
        'objectRecall', nMatch/max(nTruthObj,1), ...
        'objectPrecision', nMatch/max(nPred,1), ...
        'duplicateCandidates', nnz([O.duplicateCandidate]));
else
    r.objectMetrics = struct('nPredObjects', 0, 'nTruthObjects', 0, ...
        'nMatched', 0, 'matchedFraction', NaN, 'objectIouMean', NaN, ...
        'objectIouWorst', NaN, 'objectRecall', NaN, 'objectPrecision', NaN, ...
        'duplicateCandidates', 0);
end

if ~isempty(O)
    C = local_check_add(C, 'objectMatching', true, sprintf( ...
        '%d predicted / %d truth object(s), %d matched at IoU >= %.2f, %d duplicate candidate(s)', ...
        r.objectMetrics.nPredObjects, r.objectMetrics.nTruthObjects, ...
        r.objectMetrics.nMatched, iouThr, r.objectMetrics.duplicateCandidates));
end

% ---- class imbalance is a fact to report, not a failure by itself -------
truthCounts = arrayfun(@(c) nnz(truth == c), classList);
shares = truthCounts / max(numel(truth), 1);
majorityShare = max(shares);
minorityShare = min(shares(shares > 0));
if isempty(minorityShare), minorityShare = 1; end
r.imbalance = struct('majorityShare', majorityShare, 'minorityShare', minorityShare, ...
    'ratio', majorityShare/max(minorityShare, eps), 'counts', truthCounts);
C = local_check_add(C, 'imbalance', true, sprintf( ...
    'majority class covers %.1f %% of truth; per-class metrics reported', 100*majorityShare));

% ---- score threshold provenance and sensitivity -------------------------
r.thresholdSweep = struct('threshold', {}, 'nPred', {}, 'precision', {}, ...
    'recall', {}, 'f1', {}, 'iou', {});
if scoreMap
    src = local_field(claims, 'thresholdSource', '');
    switch lower(char(src))
        case {'train', 'validation', 'spec', 'none'}
            C = local_check_add(C, 'thresholdSource', true, ...
                sprintf('decision threshold %.4g sourced from %s', thr, char(src)));
        case 'test'
            C = local_check_add(C, 'thresholdSource', false, sprintf( ...
                ['decision threshold %.4g was tuned on the evaluation set: ' ...
                 'the reported metrics are optimistically biased'], thr));
        otherwise
            C = local_check_add(C, 'thresholdSource', 'undetermined', ...
                'decision threshold has no stated source; train/validation/spec is required');
    end
    sweep = local_field(claims, 'thresholdSweep', 0.1:0.2:0.9);
    sweep = sort(unique(sweep(:).'));
    for t = sweep
        L = double(pred >= t);
        p = L == 1; q = truth == 1;
        tpS = nnz(p & q); fpS = nnz(p & ~q); fnS = nnz(~p & q);
        if tpS+fpS+fnS == 0
            iouS = 1; f1S = 1; pS = 1; rS = 1;
        else
            iouS = tpS / max(tpS+fpS+fnS, 1);
            pS = tpS / max(tpS+fpS, 1);
            if tpS+fnS == 0, rS = NaN; else, rS = tpS/(tpS+fnS); end
            f1S = 2*tpS / max(2*tpS+fpS+fnS, 1);
        end
        r.thresholdSweep(end+1) = struct('threshold', t, 'nPred', nnz(p), ...
            'precision', pS, 'recall', rS, 'f1', f1S, 'iou', iouS); %#ok<AGROW>
    end
    if ~isempty(r.thresholdSweep)
        f1s = [r.thresholdSweep.f1];
        [bestF1, bi] = max(f1s);
        r.bestThreshold = r.thresholdSweep(bi).threshold;
        r.bestF1 = bestF1;
        f1Range = max(f1s) - min(f1s);
        r.sensitivityF1Range = f1Range;
        maxSens = local_field(claims, 'maxSensitivity', []);
        if isempty(maxSens)
            C = local_check_add(C, 'thresholdSensitivity', true, sprintf( ...
                'F1 ranges %.4f over thresholds %.2f..%.2f (best %.2f at %.2f)', ...
                f1Range, min(sweep), max(sweep), bestF1, r.bestThreshold));
        else
            C = local_check_add(C, 'thresholdSensitivity', f1Range <= maxSens, sprintf( ...
                'F1 range %.4f vs limit %.4f over thresholds %.2f..%.2f', ...
                f1Range, maxSens, min(sweep), max(sweep)));
        end
    end
else
    C = local_check_add(C, 'thresholdSource', 'na', 'label map supplied: no decision threshold to source');
    C = local_check_add(C, 'thresholdSensitivity', 'na', 'label map supplied: no score sweep');
end

% ---- metric claims -------------------------------------------------------
MC = local_metric_claims(claims);
if isempty(MC)
    C = local_check_add(C, 'claims', 'undetermined', ...
        'no metric claim with a tolerance was supplied: metrics are computed but not accepted');
else
    anyObjectClaim = false;
    accuracyOnly = true;
    for k = 1:numel(MC)
        name = lower(char(MC(k).name));
        if any(strcmp(name, {'objectioumean','objectiouworst','objectrecall', ...
                'objectprecision','matchedfraction'}))
            anyObjectClaim = true;
        end
        if ~any(strcmp(name, {'accuracy','pixelaccuracy'}))
            accuracyOnly = false;
        end
        [actual, known] = local_metric_value(r, name);
        if ~known
            C = local_check_add(C, ['claim_' name], 'na', ...
                sprintf('metric "%s" is not part of this contract', name));
            continue
        end
        if isempty(MC(k).name) || ~isfinite(MC(k).value)
            C = local_check_add(C, ['claim_' name], 'undetermined', 'claim value is missing or non-finite');
            continue
        end
        hasTol = isfinite(MC(k).tolRel) || isfinite(MC(k).tolAbs);
        if ~hasTol
            C = local_check_add(C, ['claim_' name], 'undetermined', sprintf( ...
                'claimed %s = %.6g but no tolerance was stated; deviation is not graded', ...
                name, MC(k).value));
            continue
        end
        if isnan(actual)
            C = local_check_add(C, ['claim_' name], 'undetermined', ...
                sprintf('claimed %s = %.6g but the metric is undefined on this map (empty/absent foreground)', ...
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
    if anyObjectClaim && ~iouThrStated
        C = local_check_add(C, 'iouThreshold', 'undetermined', ...
            'an object metric was claimed without an explicit IoU threshold');
    end
    if accuracyOnly && majorityShare > local_field(claims, 'imbalanceLimit', 0.9)
        C = local_check_add(C, 'imbalanceDisclosure', 'undetermined', sprintf( ...
            ['accuracy %.4f was the only claim and the majority class covers %.1f %% ' ...
             'of truth: accuracy alone cannot support a quality conclusion'], ...
            acc, 100*majorityShare));
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
r.detail = sprintf(['accuracy %.4f, foreground IoU %.4f, micro F1 %.4f, ' ...
    'macro IoU %.4f, objects %d/%d matched (IoU >= %.2f)'], ...
    acc, bIou, bF1, macroIoU, r.objectMetrics.nMatched, ...
    r.objectMetrics.nPredObjects, iouThr);
end

% ===========================================================================
function idx = local_index(v, classList)
% Map label values to their column in classList; a missing label maps to 0.
idx = zeros(size(v));
for k = 1:numel(classList)
    idx(v == classList(k)) = k;
end
end

function MC = local_metric_claims(claims)
MC = struct('name', {}, 'value', {}, 'tolRel', {}, 'tolAbs', {});
raw = {};
if isfield(claims, 'metric') && ~isempty(claims.metric), raw{end+1} = claims.metric; end
if isfield(claims, 'metrics') && ~isempty(claims.metrics), raw{end+1} = claims.metrics; end
for rIdx = 1:numel(raw)
    s = raw{rIdx};
    if ~isstruct(s), error('mas_seg_check:metric', 'metric claims must be structs'); end
    for k = 1:numel(s)
        if ~isfield(s(k), 'name'), error('mas_seg_check:metricName', 'each metric needs a name'); end
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
    case {'iou', 'binaryiou'}, v = r.metrics.binaryIoU;
    case 'dice', v = r.metrics.dice;
    case 'precision', v = r.metrics.precision;
    case 'recall', v = r.metrics.recall;
    case 'f1', v = r.metrics.f1;
    case {'accuracy', 'pixelaccuracy'}, v = r.metrics.accuracy;
    case 'macrof1', v = r.metrics.macroF1;
    case 'macroiou', v = r.metrics.macroIoU;
    case 'macroiouforeground', v = r.metrics.macroIoUForeground;
    case 'objectioumean', v = r.objectMetrics.objectIouMean;
    case 'objectiouworst', v = r.objectMetrics.objectIouWorst;
    case 'objectrecall', v = r.objectMetrics.objectRecall;
    case 'objectprecision', v = r.objectMetrics.objectPrecision;
    case 'matchedfraction', v = r.objectMetrics.matchedFraction;
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
