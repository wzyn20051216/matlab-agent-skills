function r = mas_image_metrics(pred, truth, opts)
%MAS_IMAGE_METRICS  Overlap metrics for a binary segmentation, with the conventions stated.
%
%   r = mas_image_metrics(predMask, trueMask)
%   r.iou, r.dice, r.precision, r.recall, r.f1, r.accuracy
%   r.tp, r.fp, r.fn, r.tn
%   r.perObject        per predicted blob: area, best-matching truth label, IoU
%   r.objectIouMean    mean per-object IoU      (NaN if bwlabel unavailable)
%   r.objectIouWorst   worst per-object IoU
%   r.detail
%
% CONVENTIONS THAT ARE EASY TO GET WRONG
% - Both inputs are LOGICAL. A uint8 image with 0/255 is converted with ~= 0, not by
%   comparing to 1; treating 255 as "false" is a silent 100 % error.
% - The result does NOT depend on orientation, but every reported AREA is in pixels
%   and every centroid is [COLUMN ROW] (regionprops convention), which is stated
%   here once instead of being re-guessed in each task.
% - An empty prediction and an empty truth is a perfect match (IoU = 1), not 0/0; a
%   metric that returns NaN there breaks every averaged score downstream.
%
% These are aggregate pixel metrics. They do NOT measure whether the OBJECTS are
% right: a prediction that covers the correct total area in the wrong place scores
% well on pixel recall and badly on every object-level metric. `r.perObject` reports
% the per-object IoU when both masks are labelled, so the difference is visible.

if nargin < 3, opts = struct(); end
opts = dflt(opts, struct('threshold', 0));

p = to_logical(pred, opts.threshold);
if ~isempty(truth), t = to_logical(truth, opts.threshold); else, t = false(size(p)); end
if ~isequal(size(p), size(t))
    error('mas_image_metrics:size', 'pred %s and truth %s differ in size', ...
        mat2str(size(p)), mat2str(size(t)));
end

tp = nnz(p & t); fp = nnz(p & ~t); fn = nnz(~p & t); tn = nnz(~p & ~t);
if tp + fp + fn == 0
    % both masks empty: a perfect match by definition
    iou = 1; dice = 1; prec = 1; rec = 1;
else
    iou = tp / max(tp + fp + fn, 1);
    dice = 2*tp / max(2*tp + fp + fn, 1);
    prec = tp / max(tp + fp, 1);
    rec = tp / max(tp + fn, 1);
end
if prec + rec == 0, f1 = 0; else, f1 = 2*prec*rec/(prec + rec); end

r = struct();
po = per_object(p, t);

r.tp = tp; r.fp = fp; r.fn = fn; r.tn = tn;
r.iou = iou; r.dice = dice; r.precision = prec; r.recall = rec; r.f1 = f1;
r.accuracy = (tp + tn) / max(numel(p), 1);
r.predArea = nnz(p); r.trueArea = nnz(t);
r.perObject = po;
if ~isempty(po) && all(isfinite([po.iou]))
    r.objectIouMean = mean([po.iou]);
    r.objectIouWorst = min([po.iou]);
else
    r.objectIouMean = NaN; r.objectIouWorst = NaN;
end
r.detail = sprintf('IoU %.4f, Dice %.4f, P %.4f, R %.4f (%d/%d/%d px)', ...
    iou, dice, prec, rec, tp, fp, fn);
end

% ---------------------------------------------------------------------------
function po = per_object(p, t)
% Per-object IoU, each predicted blob matched to the truth blob it overlaps most.
%
% The matching is by argmax over ALL truth labels, not by index. bwlabel numbers
% blobs in raster (column-major) scan order, so "object 1" is simply the first one
% the scan happens to reach -- assuming Lp==k corresponds to Lt==k is wrong as soon
% as the two masks disagree, which is exactly the case this function exists for.
%
% Requires Image Processing Toolbox (bwlabel). Without it the caller still gets
% every pixel metric and an empty perObject; segmentation quality assessment is
% not silently degraded, it is reported as unavailable.
po = struct('label', {}, 'area', {}, 'truthLabel', {}, 'iou', {});
if exist('bwlabel', 'file') ~= 2, return; end
if isempty(p) || isempty(t), return; end

Lp = bwlabel(p, 4);
Lt = bwlabel(t, 4);
np = max(Lp(:));
nt = max(Lt(:));
if np == 0 || nt == 0, return; end

for i = 1:np
    mask = (Lp == i);
    best = 0; bestj = 0;
    for j = 1:nt
        tm = (Lt == j);
        un = nnz(mask | tm);
        if un == 0, continue; end
        v = nnz(mask & tm) / un;
        if v > best, best = v; bestj = j; end
    end
    po(end+1) = struct('label', i, 'area', nnz(mask), 'truthLabel', bestj, 'iou', best); %#ok<AGROW>
end
end

% ---------------------------------------------------------------------------
function m = to_logical(x, thr)
if islogical(x)
    m = x;
elseif isnumeric(x)
    if isempty(thr) || thr == 0
        m = x ~= 0;                 % 0/255 images included
    else
        m = x > thr;
    end
else
    error('mas_image_metrics:type', 'mask must be logical or numeric, got %s', class(x));
end
end

function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
