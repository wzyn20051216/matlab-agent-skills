function r = mas_image_contract(img, claims)
%MAS_IMAGE_CONTRACT  Check image data, geometry, preprocessing and split hygiene.
%
%   r = mas_image_contract(I, struct( ...
%           'expectedSize', [256 256 3], 'expectedClass', 'uint8', ...
%           'expectedRange', [0 255], 'space', 'rgb', ...
%           'labels', labelMap, ...
%           'normalization', struct('original', I0, 'inverse', @(z) ..., ...
%                                   'forward', @(o) ...), ...
%           'transform', T, 'points', P, 'pointsTransformed', Q, ...
%           'edgeMap', E, 'edgeTruth', E0, 'edgeTolPx', 1, 'edgeF1Min', 0.9, ...
%           'features', F, 'featureTruth', F0, 'matchTol', 1, ...
%           'split', struct('trainIdx', tr, 'valIdx', va, ...
%                           'sampleHash', h, 'groups', g, ...
%                           'tunedOn', 'train', 'reportedOn', 'test')))
%
% Image convention: img is H x W (gray) or H x W x C (C=3 RGB), 1-based pixel
% coordinates. Features are [x y] with x the column in [1,W] and y the row in
% [1,H]. Affine transforms act on homogeneous [x; y; 1].
%
% Claims (all optional, but at least one acceptance criterion is required):
%   .expectedSize / .expectedClass / .expectedRange / .space
%   .requireFinite       reject NaN/Inf (default true)
%   .labels, .labelClasses   label map aligned with the image
%   .normalization       invertible preprocessing: original, inverse, optional forward
%   .transform           affine 2x3 or 3x3; .points and .pointsTransformed
%   .outputSize          [H W] bounds for transformed points
%   .edgeMap, .edgeTruth, .edgeTolPx (default 1), .edgeF1Min (required to grade)
%   .features, .featureTruth, .matchTol (default 1), .featureF1Min
%   .minFeatures, .allowFeatureDuplicates (default false)
%   .split               trainIdx/valIdx/testIdx, sampleHash, groups,
%                        tunedOn, reportedOn
%   .threshold, .thresholdSource  preprocessing/binarization threshold provenance
%
% Returns
%   r.verdict   PASS | FAIL | UNDETERMINED
%   r.checks    id / status (pass | fail | na | undetermined) / detail
%   r.image     size, class, channels, range
%   r.labels, r.normalization, r.transform, r.edge, r.features, r.split
%   r.detail
%
% WHAT THE CONTRACT REFUSES
% - "The picture looks right" is not a criterion. Every check is numeric and has
%   a stated convention: size and dtype, declared range, label alignment,
%   invertible normalization, invertible affine geometry, edge/feature agreement
%   with an independent truth, and split leakage.
% - Normalization is graded by running the inverse (and the forward when given)
%   and comparing with the original, not by assuming it is invertible. An
%   integer image that comes back as unscaled doubles fails exact recovery.
% - A singular or ill-conditioned affine transform fails; a transform is also
%   checked against claimed point correspondences and the declared output size.
% - Edge maps are matched to an independent truth within a stated pixel
%   tolerance; an all-ones edge map has perfect recall and terrible precision and
%   is rejected. Features outside the image, duplicated, or missing from the
%   truth are counted, never silently clipped.
% - A split is checked for index overlap AND content-hash overlap AND group
%   overlap. Disjoint indices are not enough: the same image or the same patient
%   on both sides is leakage. A threshold tuned on the evaluation set fails.
% - A missing truth or a missing criterion is UNDETERMINED, never PASS.

if nargin < 2 || isempty(claims), claims = struct(); end
if ~isstruct(claims), error('mas_image_contract:claims', 'claims must be a struct'); end
if ~isnumeric(img) && ~islogical(img)
    error('mas_image_contract:imgType', 'img must be numeric or logical, got %s', class(img));
end
if isempty(img), error('mas_image_contract:empty', 'img is empty'); end
if ~isreal(img), error('mas_image_contract:complex', 'img must be real'); end
sz = size(img);
if ndims(img) > 3, error('mas_image_contract:dims', 'img must be 2-D or 3-D'); end
H = sz(1); W = sz(2);
if numel(sz) < 3, C = 1; else, C = sz(3); end

Ck = local_check_empty();
r = struct();
finiteImg = all(isfinite(img(:)));
r.image = struct('height', H, 'width', W, 'channels', C, ...
    'class', class(img), 'finite', finiteImg);
if finiteImg
    r.image.min = min(img(:));
    r.image.max = max(img(:));
else
    r.image.min = min(img(isfinite(img)));
    r.image.max = max(img(isfinite(img)));
end
criteria = 0;

requireFinite = logical(local_field(claims, 'requireFinite', true));
if ~finiteImg
    if requireFinite
        Ck = local_check_add(Ck, 'finite', false, ...
            sprintf('%d non-finite pixel value(s); a numeric contract cannot be evaluated', nnz(~isfinite(img(:)))));
    else
        Ck = local_check_add(Ck, 'finite', true, 'non-finite pixels permitted by requireFinite=false');
    end
else
    Ck = local_check_add(Ck, 'finite', true, 'all pixels are finite');
end

% ---- size / class / channels / range ------------------------------------
if isfield(claims, 'expectedSize') && ~isempty(claims.expectedSize)
    criteria = criteria + 1;
    es = claims.expectedSize(:).';
    if numel(es) ~= 2 && numel(es) ~= 3
        error('mas_image_contract:expectedSize', 'expectedSize must be [H W] or [H W C]');
    end
    if numel(es) == 2
        ok = isequal([H W], es);
        detail = sprintf('image %dx%d (HxW) vs expected %dx%d', H, W, es(1), es(2));
    else
        ok = isequal([H W C], es);
        detail = sprintf('image %dx%dx%d (HxWxC) vs expected %dx%dx%d', H, W, C, es(1), es(2), es(3));
    end
    Ck = local_check_add(Ck, 'size', ok, detail);
else
    Ck = local_check_add(Ck, 'size', 'na', 'no expected size stated');
end

if isfield(claims, 'expectedClass') && ~isempty(claims.expectedClass)
    criteria = criteria + 1;
    want = char(claims.expectedClass);
    Ck = local_check_add(Ck, 'class', strcmp(class(img), want), ...
        sprintf('image class %s vs expected %s', class(img), want));
else
    Ck = local_check_add(Ck, 'class', 'na', 'no expected class stated');
end

if isfield(claims, 'space') && ~isempty(claims.space)
    criteria = criteria + 1;
    sp = lower(char(claims.space));
    switch sp
        case 'gray'
            ok = C == 1;
            want = 1;
        case 'rgb'
            ok = C == 3;
            want = 3;
        otherwise
            error('mas_image_contract:space', 'space must be gray or rgb');
    end
    Ck = local_check_add(Ck, 'channels', ok, ...
        sprintf('%d channel(s), space=%s expects %d', C, sp, want));
end

if isfield(claims, 'expectedRange') && ~isempty(claims.expectedRange)
    criteria = criteria + 1;
    er = double(claims.expectedRange(:).');
    if numel(er) ~= 2 || er(1) > er(2)
        error('mas_image_contract:expectedRange', 'expectedRange must be [lo hi]');
    end
    if isinteger(img) || islogical(img)
        rtol = local_field(claims, 'rangeTol', 0);
    else
        rtol = local_field(claims, 'rangeTol', 1e-9*max(1, er(2)-er(1)));
    end
    lo = r.image.min; hi = r.image.max;
    if isempty(lo) || isempty(hi)
        ok = false;
        Ck = local_check_add(Ck, 'range', ok, ...
            'no finite pixel values exist: the declared range cannot be met');
    else
        ok = lo >= er(1)-rtol && hi <= er(2)+rtol;
        Ck = local_check_add(Ck, 'range', ok, sprintf( ...
            'observed [%.6g, %.6g] vs declared [%.6g, %.6g] (tol %.3g)', ...
            lo, hi, er(1), er(2), rtol));
    end
else
    Ck = local_check_add(Ck, 'range', 'na', 'no value range stated');
end

% ---- label alignment -----------------------------------------------------
r.labels = struct('present', false);
if isfield(claims, 'labels') && ~isempty(claims.labels)
    criteria = criteria + 1;
    L = claims.labels;
    if ~isnumeric(L) && ~islogical(L)
        error('mas_image_contract:labels', 'labels must be numeric or logical');
    end
    if ~isequal(size(L), [H W])
        Ck = local_check_add(Ck, 'labelAlignment', false, sprintf( ...
            'label map is %s for an %dx%d image', mat2str(size(L)), H, W));
    else
        Ck = local_check_add(Ck, 'labelAlignment', true, ...
            sprintf('label map %dx%d aligns with the image', H, W));
    end
    if any(~isfinite(L(:)))
        Ck = local_check_add(Ck, 'labelClasses', false, 'label map contains NaN or Inf');
    elseif any(L(:) ~= round(L(:)))
        Ck = local_check_add(Ck, 'labelClasses', false, 'label map contains non-integer values');
    else
        r.labels.present = true;
        r.labels.values = unique(L(:)).';
        if isfield(claims, 'labelClasses') && ~isempty(claims.labelClasses)
            want = claims.labelClasses(:).';
            missing = setdiff(unique(L(:)).', want);
            if ~isempty(missing)
                Ck = local_check_add(Ck, 'labelClasses', false, sprintf( ...
                    'label classes %s are outside the declared set', mat2str(missing)));
            else
                Ck = local_check_add(Ck, 'labelClasses', true, ...
                    sprintf('%d declared class(es) cover every label', numel(want)));
            end
        else
            Ck = local_check_add(Ck, 'labelClasses', true, ...
                sprintf('%d distinct label value(s); no class list declared', numel(r.labels.values)));
        end
    end
else
    Ck = local_check_add(Ck, 'labelAlignment', 'na', 'no label map supplied');
end

% ---- normalization invertibility ---------------------------------------
r.normalization = struct('present', false);
if isfield(claims, 'normalization') && ~isempty(claims.normalization)
    criteria = criteria + 1;
    N = claims.normalization;
    if ~isstruct(N) || ~isfield(N, 'original') || ~isfield(N, 'inverse')
        error('mas_image_contract:normalization', ...
            'normalization needs original and inverse (and optionally forward)');
    end
    if ~isa(N.inverse, 'function_handle')
        error('mas_image_contract:normalizationInverse', 'normalization.inverse must be a function handle');
    end
    orig = N.original;
    if ~isequal(size(orig), size(img))
        Ck = local_check_add(Ck, 'normalizationInvertible', false, sprintf( ...
            'original is %s but the processed image is %s', mat2str(size(orig)), mat2str(size(img))));
    else
        forwardErr = NaN;
        if isfield(N, 'forward') && ~isempty(N.forward)
            if ~isa(N.forward, 'function_handle')
                error('mas_image_contract:normalizationForward', 'normalization.forward must be a function handle');
            end
            try
                fwd = N.forward(orig);
            catch ME
                fwd = [];
                fwdErrMsg = ME.message; %#ok<NASGU>
            end
            if isempty(fwd)
                Ck = local_check_add(Ck, 'normalizationForward', false, ...
                    'normalization.forward failed or returned empty');
            else
                forwardErr = local_scaled_err(fwd, img);
                ftol = local_field(claims, 'forwardTol', 1e-9);
                Ck = local_check_add(Ck, 'normalizationForward', forwardErr <= ftol, sprintf( ...
                    'forward(original) vs processed image: scaled error %.3g (tol %.3g)', ...
                    forwardErr, ftol));
            end
        else
            Ck = local_check_add(Ck, 'normalizationForward', 'na', 'no forward map supplied');
        end
        try
            invImg = N.inverse(img);
            invErr = local_scaled_err(invImg, orig);
            if isfield(claims, 'exactRecovery') && ~isempty(claims.exactRecovery)
                exact = logical(claims.exactRecovery);
            elseif isinteger(orig) || islogical(orig)
                exact = true;
            else
                exact = false;
            end
            classOk = strcmp(class(invImg), class(orig));
            if exact
                ok = isequal(invImg, orig);
                detail = sprintf('exact recovery: %s (class %s vs %s, scaled err %.3g)', ...
                    tern(ok, 'yes', 'no'), class(invImg), class(orig), invErr);
            else
                rtol = local_field(claims, 'roundTripTol', 1e-9);
                ok = invErr <= rtol;
                detail = sprintf('inverse round-trip scaled error %.3g (tol %.3g, class %s vs %s)', ...
                    invErr, rtol, class(invImg), class(orig));
            end
            Ck = local_check_add(Ck, 'normalizationInvertible', ok, detail);
            r.normalization = struct('present', true, 'roundTripScaledErr', invErr, ...
                'forwardScaledErr', forwardErr, 'classPreserved', classOk, ...
                'exact', exact);
        catch ME
            Ck = local_check_add(Ck, 'normalizationInvertible', false, ...
                sprintf('normalization.inverse failed: %s', ME.message));
            r.normalization = struct('present', true, 'roundTripScaledErr', NaN, ...
                'forwardScaledErr', forwardErr, 'classPreserved', false, 'exact', false);
        end
    end
else
    Ck = local_check_add(Ck, 'normalizationInvertible', 'na', 'no normalization map supplied');
end

% ---- affine transform ----------------------------------------------------
r.transform = struct('present', false);
if isfield(claims, 'transform') && ~isempty(claims.transform)
    criteria = criteria + 1;
    T = claims.transform;
    if ~isnumeric(T) || ~ismatrix(T) || ~any(isequal(size(T), [2 3]) | isequal(size(T), [3 3]))
        error('mas_image_contract:transform', 'transform must be 2x3 or 3x3');
    end
    if any(~isfinite(T(:))), error('mas_image_contract:transformFinite', 'transform contains NaN or Inf'); end
    if isequal(size(T), [2 3]), T = [T; 0 0 1]; end
    if any(abs(T(3,:) - [0 0 1]) > 1e-12)
        error('mas_image_contract:transformAffine', 'transform must be affine (last row [0 0 1])');
    end
    detT = det(T);
    detTol = local_field(claims, 'detTol', 1e-12);
    condT = cond(T(1:2,1:2));
    invertible = abs(detT) > detTol && isfinite(condT) && condT < 1/eps;
    Ck = local_check_add(Ck, 'transformInvertible', invertible, sprintf( ...
        'det %.6g (tol %.3g), 2x2 condition %.6g', detT, detTol, condT));
    r.transform = struct('present', true, 'matrix', T, 'det', detT, ...
        'condition', condT, 'invertible', invertible);
    if invertible
        Tinv = inv(T);
        if isfield(claims, 'points') && ~isempty(claims.points)
            P = claims.points;
            if ~isnumeric(P) || size(P, 2) ~= 2 || any(~isfinite(P(:)))
                error('mas_image_contract:points', 'points must be a finite N x 2 matrix');
            end
            Q = local_apply(T, P);
            if isfield(claims, 'pointsTransformed') && ~isempty(claims.pointsTransformed)
                Qc = claims.pointsTransformed;
                if ~isequal(size(Qc), size(Q)) || any(~isfinite(Qc(:)))
                    error('mas_image_contract:pointsTransformed', 'pointsTransformed must match points in size');
                end
                ptol = local_field(claims, 'pointTol', 1e-9);
                ferr = max(sqrt(sum((Q - Qc).^2, 2)));
                Ck = local_check_add(Ck, 'transformPoints', ferr <= ptol, sprintf( ...
                    'T(points) vs claimed transformed points: max error %.3g px (tol %.3g)', ferr, ptol));
                r.transform.pointError = ferr;
            else
                Pback = local_apply(Tinv, Q);
                rerr = max(sqrt(sum((P - Pback).^2, 2)));
                rtol = local_field(claims, 'pointTol', 1e-9);
                Ck = local_check_add(Ck, 'transformPoints', rerr <= rtol, sprintf( ...
                    'inverse(T)*T(points) round-trip max error %.3g px (tol %.3g)', rerr, rtol));
                r.transform.pointError = rerr;
            end
            if isfield(claims, 'outputSize') && ~isempty(claims.outputSize)
                os = claims.outputSize;
                if numel(os) ~= 2 || any(~isfinite(os)) || any(os <= 0)
                    error('mas_image_contract:outputSize', 'outputSize must be [H W]');
                end
                out = Q(:,1) < 1 | Q(:,1) > os(2) | Q(:,2) < 1 | Q(:,2) > os(1);
                Ck = local_check_add(Ck, 'transformBounds', ~any(out), sprintf( ...
                    '%d of %d transformed point(s) outside [1,%d]x[1,%d]', ...
                    nnz(out), size(Q,1), os(2), os(1)));
            else
                Ck = local_check_add(Ck, 'transformBounds', 'na', 'no outputSize stated');
            end
        else
            Ck = local_check_add(Ck, 'transformPoints', 'na', 'no point correspondences supplied');
        end
    else
        Ck = local_check_add(Ck, 'transformPoints', 'na', 'transform is not invertible');
    end
else
    Ck = local_check_add(Ck, 'transformInvertible', 'na', 'no affine transform supplied');
end

% ---- edge map against an independent truth ------------------------------
r.edge = struct('present', false);
hasEdgeMap = isfield(claims, 'edgeMap') && ~isempty(claims.edgeMap);
hasEdgeTruth = isfield(claims, 'edgeTruth') && ~isempty(claims.edgeTruth);
if hasEdgeMap || hasEdgeTruth
    if ~(hasEdgeMap && hasEdgeTruth)
        Ck = local_check_add(Ck, 'edgeTruth', 'undetermined', ...
            'edge verification needs BOTH edgeMap and edgeTruth; one is missing');
    else
        E = local_edge(claims.edgeMap, H, W, 'edgeMap');
        E0 = local_edge(claims.edgeTruth, H, W, 'edgeTruth');
        tolPx = local_field(claims, 'edgeTolPx', 1);
        if ~isscalar(tolPx) || ~isfinite(tolPx) || tolPx < 0
            error('mas_image_contract:edgeTolPx', 'edgeTolPx must be a non-negative scalar');
        end
        Ed = local_dilate(E, tolPx);
        E0d = local_dilate(E0, tolPx);
        if ~any(E(:)) && ~any(E0(:))
            prec = 1; rec = 1; f1 = 1;
        else
            prec = nnz(E & E0d) / max(nnz(E), 1);
            rec  = nnz(E0 & Ed) / max(nnz(E0), 1);
            if prec + rec == 0, f1 = 0; else, f1 = 2*prec*rec/(prec+rec); end
        end
        if any(E0(:))
            strictRec = nnz(E & E0) / nnz(E0);
        else
            strictRec = NaN;
        end
        if any(E(:))
            strictPrec = nnz(E & E0) / nnz(E);
        else
            strictPrec = NaN;
        end
        r.edge = struct('present', true, 'tolerancePx', tolPx, ...
            'precision', prec, 'recall', rec, 'f1', f1, ...
            'strictPrecision', strictPrec, 'strictRecall', strictRec, ...
            'nPred', nnz(E), 'nTruth', nnz(E0));
        Ck = local_check_add(Ck, 'edgePrecision', true, sprintf( ...
            'tolerance-matched precision %.4f (strict %.4f), %d predicted edge pixel(s)', ...
            prec, strictPrec, nnz(E)));
        Ck = local_check_add(Ck, 'edgeRecall', true, sprintf( ...
            'tolerance-matched recall %.4f (strict %.4f), %d truth edge pixel(s)', ...
            rec, strictRec, nnz(E0)));
        if isfield(claims, 'edgeF1Min') && ~isempty(claims.edgeF1Min)
            criteria = criteria + 1;
            fmin = claims.edgeF1Min;
            if ~isscalar(fmin) || ~isfinite(fmin) || fmin < 0 || fmin > 1
                error('mas_image_contract:edgeF1Min', 'edgeF1Min must lie in [0,1]');
            end
            Ck = local_check_add(Ck, 'edgeF1', f1 >= fmin, sprintf( ...
                'edge F1 %.4f vs required %.4f at %g px tolerance', f1, fmin, tolPx));
        else
            Ck = local_check_add(Ck, 'edgeF1', 'undetermined', ...
                'edge F1 computed but no edgeF1Min criterion was stated');
        end
    end
end

% ---- features ------------------------------------------------------------
r.features = struct('present', false);
if isfield(claims, 'features') && ~isempty(claims.features)
    criteria = criteria + 1;
    F = claims.features;
    if ~isnumeric(F) || size(F, 2) ~= 2 || any(~isfinite(F(:)))
        error('mas_image_contract:features', 'features must be a finite N x 2 matrix of [x y]');
    end
    inX = F(:,1) >= 1 & F(:,1) <= W;
    inY = F(:,2) >= 1 & F(:,2) <= H;
    nOut = nnz(~(inX & inY));
    Ck = local_check_add(Ck, 'featureBounds', nOut == 0, sprintf( ...
        '%d feature(s), %d outside [1,%d]x[1,%d]', size(F,1), nOut, W, H));
    dupCount = size(F,1) - size(unique(F, 'rows'), 1);
    allowDup = logical(local_field(claims, 'allowFeatureDuplicates', false));
    Ck = local_check_add(Ck, 'featureDuplicates', allowDup || dupCount == 0, sprintf( ...
        '%d exact duplicate coordinate(s), duplicates %s', dupCount, ...
        tern(allowDup, 'allowed by claim', 'not allowed')));
    minF = local_field(claims, 'minFeatures', []);
    if ~isempty(minF)
        Ck = local_check_add(Ck, 'featureCount', size(F,1) >= minF, sprintf( ...
            '%d feature(s) vs minimum %d', size(F,1), minF));
    else
        Ck = local_check_add(Ck, 'featureCount', 'na', 'no minimum feature count stated');
    end
    r.features = struct('present', true, 'count', size(F,1), ...
        'outOfBounds', nOut, 'duplicates', dupCount);
    if isfield(claims, 'featureTruth') && ~isempty(claims.featureTruth)
        F0 = claims.featureTruth;
        if ~isnumeric(F0) || size(F0, 2) ~= 2 || any(~isfinite(F0(:)))
            error('mas_image_contract:featureTruth', 'featureTruth must be a finite N x 2 matrix');
        end
        mtol = local_field(claims, 'matchTol', 1);
        [nMatch, meanDist] = local_match_features(F, F0, mtol);
        fprec = nMatch / max(size(F,1), 1);
        frec = nMatch / max(size(F0,1), 1);
        if fprec + frec == 0, ff1 = 0; else, ff1 = 2*fprec*frec/(fprec+frec); end
        r.features.truthCount = size(F0,1);
        r.features.matched = nMatch;
        r.features.meanMatchDistance = meanDist;
        r.features.precision = fprec;
        r.features.recall = frec;
        r.features.f1 = ff1;
        Ck = local_check_add(Ck, 'featureMatch', true, sprintf( ...
            '%d/%d features matched within %.3g px; precision %.4f, recall %.4f, F1 %.4f', ...
            nMatch, size(F0,1), mtol, fprec, frec, ff1));
        if isfield(claims, 'featureF1Min') && ~isempty(claims.featureF1Min)
            criteria = criteria + 1;
            fmin = claims.featureF1Min;
            if ~isscalar(fmin) || ~isfinite(fmin) || fmin < 0 || fmin > 1
                error('mas_image_contract:featureF1Min', 'featureF1Min must lie in [0,1]');
            end
            Ck = local_check_add(Ck, 'featureF1', ff1 >= fmin, sprintf( ...
                'feature F1 %.4f vs required %.4f', ff1, claims.featureF1Min));
        else
            Ck = local_check_add(Ck, 'featureF1', 'undetermined', ...
                'feature F1 computed but no featureF1Min criterion was stated');
        end
    else
        Ck = local_check_add(Ck, 'featureMatch', 'na', 'no feature truth supplied');
    end
else
    Ck = local_check_add(Ck, 'featureBounds', 'na', 'no features supplied');
end

% ---- split / leakage -----------------------------------------------------
r.split = struct('present', false);
if isfield(claims, 'split') && ~isempty(claims.split)
    criteria = criteria + 1;
    S = claims.split;
    names = {'trainIdx', 'valIdx', 'testIdx'};
    sets = {};
    setNames = {};
    for k = 1:numel(names)
        if isfield(S, names{k}) && ~isempty(S.(names{k}))
            idx = S.(names{k});
            if ~isnumeric(idx) || any(~isfinite(idx)) || any(idx < 1) || any(idx ~= round(idx))
                error('mas_image_contract:splitIndex', '%s must hold positive integer indices', names{k});
            end
            sets{end+1} = idx(:); %#ok<AGROW>
            setNames{end+1} = strrep(names{k}, 'Idx', ''); %#ok<AGROW>
        end
    end
    if numel(sets) < 2
        Ck = local_check_add(Ck, 'splitOverlap', 'undetermined', ...
            'fewer than two non-empty splits: no held-out set to check');
    else
        overlap = 0;
        for a = 1:numel(sets)-1
            for b = a+1:numel(sets)
                overlap = overlap + numel(intersect(sets{a}, sets{b}));
            end
        end
        Ck = local_check_add(Ck, 'splitOverlap', overlap == 0, sprintf( ...
            '%d overlapping sample index(es) across %s', overlap, strjoin(setNames, '/')));

        hashes = {};
        if isfield(S, 'sampleHash') && ~isempty(S.sampleHash)
            hashes = string(S.sampleHash(:));
            maxIdx = max(cellfun(@(x) max(x), sets));
            if numel(hashes) < maxIdx
                Ck = local_check_add(Ck, 'contentLeakage', 'undetermined', sprintf( ...
                    'sampleHash has %d entries but the largest split index is %d', numel(hashes), maxIdx));
            else
                leak = 0; example = '';
                for a = 1:numel(sets)-1
                    for b = a+1:numel(sets)
                        ha = hashes(sets{a}); hb = hashes(sets{b});
                        common = intersect(unique(ha), unique(hb));
                        if ~isempty(common)
                            leak = leak + numel(common);
                            if isempty(example), example = common(1); end
                        end
                    end
                end
                if leak > 0
                    Ck = local_check_add(Ck, 'contentLeakage', false, sprintf( ...
                        '%d identical content hash(es) on both sides (example %s): same image(s) leaked', ...
                        leak, example));
                else
                    Ck = local_check_add(Ck, 'contentLeakage', true, ...
                        'no content hash appears in two splits');
                end
                r.split.hashes = hashes;
            end
        else
            Ck = local_check_add(Ck, 'contentLeakage', 'undetermined', ...
                'no sampleHash supplied: index-disjoint splits can still share content');
        end

        if isfield(S, 'groups') && ~isempty(S.groups)
            G = string(S.groups(:));
            maxIdx = max(cellfun(@(x) max(x), sets));
            if numel(G) < maxIdx
                Ck = local_check_add(Ck, 'groupLeakage', 'undetermined', sprintf( ...
                    'groups has %d entries but the largest split index is %d', numel(G), maxIdx));
            else
                gLeak = 0; gExample = '';
                for a = 1:numel(sets)-1
                    for b = a+1:numel(sets)
                        common = intersect(unique(G(sets{a})), unique(G(sets{b})));
                        if ~isempty(common)
                            gLeak = gLeak + numel(common);
                            if isempty(gExample), gExample = common(1); end
                        end
                    end
                end
                Ck = local_check_add(Ck, 'groupLeakage', gLeak == 0, sprintf( ...
                    '%d group(s) shared across splits%s', gLeak, ...
                    tern(gLeak > 0, sprintf(' (example %s)', gExample), '')));
            end
        else
            Ck = local_check_add(Ck, 'groupLeakage', 'na', 'no group labels supplied');
        end

        if isfield(S, 'tunedOn') && isfield(S, 'reportedOn')
            tuned = local_norm_split(char(S.tunedOn));
            reported = local_norm_split(char(S.reportedOn));
            if strcmp(tuned, 'test') && strcmp(reported, 'test')
                Ck = local_check_add(Ck, 'tuningLeakage', false, ...
                    'hyperparameters/threshold were tuned on the reported test set');
            elseif strcmp(tuned, 'test')
                Ck = local_check_add(Ck, 'tuningLeakage', 'undetermined', ...
                    'tuning used the test split; the reported split must be declared and is not test');
            else
                Ck = local_check_add(Ck, 'tuningLeakage', true, sprintf( ...
                    'tuned on %s, reported on %s', tuned, reported));
            end
        else
            Ck = local_check_add(Ck, 'tuningLeakage', 'na', 'tunedOn/reportedOn not stated');
        end
        r.split = struct('present', true, 'sets', {setNames}, 'sizes', cellfun(@numel, sets));
    end
else
    Ck = local_check_add(Ck, 'splitOverlap', 'na', 'no split supplied');
end

% ---- preprocessing threshold provenance ---------------------------------
if isfield(claims, 'threshold') && ~isempty(claims.threshold)
    criteria = criteria + 1;
    src = local_field(claims, 'thresholdSource', '');
    switch lower(char(src))
        case {'train', 'validation', 'spec', 'none'}
            Ck = local_check_add(Ck, 'thresholdSource', true, ...
                sprintf('threshold %.6g sourced from %s', claims.threshold, char(src)));
        case 'test'
            Ck = local_check_add(Ck, 'thresholdSource', false, ...
                'threshold was tuned on the evaluation set');
        otherwise
            Ck = local_check_add(Ck, 'thresholdSource', 'undetermined', ...
                'threshold has no stated source');
    end
else
    Ck = local_check_add(Ck, 'thresholdSource', 'na', 'no threshold claim');
end

if criteria == 0
    Ck = local_check_add(Ck, 'criteria', 'undetermined', ...
        'no acceptance criterion was stated: the data was described, not accepted');
end

r.checks = Ck;
sts = {Ck.status};
if any(strcmp(sts, 'fail'))
    r.verdict = 'FAIL';
elseif any(strcmp(sts, 'undetermined'))
    r.verdict = 'UNDETERMINED';
else
    r.verdict = 'PASS';
end
r.detail = sprintf('image %dx%dx%d %s, %d check(s): %d pass / %d fail / %d na / %d undetermined', ...
    H, W, C, class(img), numel(Ck), nnz(strcmp(sts, 'pass')), ...
    nnz(strcmp(sts, 'fail')), nnz(strcmp(sts, 'na')), nnz(strcmp(sts, 'undetermined')));
end

% ===========================================================================
function M = local_edge(x, H, W, name)
if islogical(x)
    M = x;
elseif isnumeric(x)
    if any(~isfinite(x(:))), error('mas_image_contract:edgeFinite', '%s contains NaN or Inf', name); end
    M = x ~= 0;
else
    error('mas_image_contract:edgeType', '%s must be logical or numeric', name);
end
if ~isequal(size(M), [H W])
    error('mas_image_contract:edgeSize', '%s is %s but the image is %dx%d', ...
        name, mat2str(size(M)), H, W);
end
M = logical(M);
end

function D = local_dilate(M, tol)
if tol <= 0
    D = M;
    return;
end
k = 2*ceil(tol) + 1;
D = conv2(double(M), ones(k, k), 'same') > 0;
end

function [nMatch, meanDist] = local_match_features(F, F0, tol)
% One-to-one greedy matching by nearest distance. Each predicted feature may
% match at most one truth feature; extra predictions count as false positives.
nP = size(F, 1); nT = size(F0, 1);
if nT == 0
    nMatch = 0; meanDist = NaN;
    return;
end
used = false(nT, 1);
nMatch = 0; dists = [];
for i = 1:nP
    d = sqrt(sum((F0 - F(i,:)).^2, 2));
    d(used) = Inf;
    [dmin, j] = min(d);
    if dmin <= tol
        used(j) = true;
        nMatch = nMatch + 1;
        dists(end+1) = dmin; %#ok<AGROW>
    end
end
if isempty(dists), meanDist = NaN; else, meanDist = mean(dists); end
end

function e = local_scaled_err(a, b)
if ~isequal(size(a), size(b)) || isempty(a)
    e = Inf;
    return;
end
d = double(a) - double(b);
scale = max(1, max(abs(double(b(:)))));
if isempty(scale) || ~isfinite(scale)
    e = Inf;
else
    e = max(abs(d(:))) / scale;
end
end

function P = local_apply(T, Pts)
X = [Pts(:,1), Pts(:,2), ones(size(Pts,1), 1)].';
Q = T * X;
P = Q(1:2, :).';
end

function s = local_norm_split(s)
s = lower(strtrim(s));
if strcmp(s, 'val'), s = 'validation'; end
if ~any(strcmp(s, {'train', 'validation', 'test', 'none'}))
    error('mas_image_contract:splitRole', 'split role must be train/val/validation/test/none');
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

function out = tern(cond, a, b)
if cond, out = a; else, out = b; end
end
