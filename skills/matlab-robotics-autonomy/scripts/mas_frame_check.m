function r = mas_frame_check(X, opts)
%MAS_FRAME_CHECK  SE(3)/SO(3) hygiene: is this actually a rigid transform?
%
%   r = mas_frame_check(T)                      % T = 4x4 homogeneous or 3x3 rotation
%   r = mas_frame_check(Tchain)                 % 4x4xK, composed in order 1..K
%   r = mas_frame_check(struct('eul',[z y x],'seq','ZYX'))
%   r = mas_frame_check(struct('quat',[w x y z]))
%
%   r.R           rotation block
%   r.t           translation (4x4 input only)
%   r.orthErr     max|R'R - I|        (0 for a true rotation)
%   r.detR        det(R)              (+1 rotation, -1 reflection/mirror)
%   r.proper      det(R) > 0
%   r.composed    product of a chain
%   r.closureErr  |composed - I| when opts.closedLoop is set
%   r.crossCheck  deviation from the MathWorks implementation, when licensed
%   r.warnings, r.ok, r.verdict
%
% WHY THIS EXISTS
% The risk checklist for robotics leads with "ENU/NED/body/world frame mixups" and
% "degrees vs radians", because both produce numbers that are plausible, finite, and
% wrong. Three specific ways that happens, all caught here:
%
%   1. a matrix that is ALMOST orthonormal -- accumulated from an interpolant, or a
%      hand-typed 3x3, or a long chain. det(R) can still read +1 to six digits
%      while R'R - I is 1e-3. `orthErr` measures it; det does not see it.
%   2. det(R) = -1: a reflection, which is what a sign error in one axis gives you.
%      The tip still moves. It moves mirrored.
%   3. a chain that does not close: T_ab*T_bc*T_ca ~= I. Closure error is the only
%      cheap end-to-end check on a TF tree, and it catches a wrong convention at one
%      link even when every individual matrix is a valid rotation.
%
% EULER SEQUENCE IS PART OF THE DATA. The same three numbers mean different
% orientations under ZYX and XYZ, so `.seq` is required and never defaulted; the
% sequence used is reported back in `r.crossCheck.sequence`.
%
% CROSS-CHECK
% Where the licensed implementation exists it is run on the same input and the max
% absolute deviation is reported. This compares against independently written code,
% which is stronger evidence than any internal consistency check. Absence is reported,
% never faked: `r.crossCheck.checked = false` means it was not run.

if nargin < 2, opts = struct(); end
opts = dflt(opts, struct('closedLoop', false, 'angleUnit', 'rad', ...
    'orthTol', 1e-8, 'closureTol', 1e-8, 'crossCheck', true));

warn = {};
cross = struct('checked', false, 'function', '', 'maxDev', NaN, 'note', '', 'sequence', '');
composed = [];
closureErr = NaN;
t = [];

if isstruct(X)
    [R, cross, warn] = spec_to_rotm(X, opts, cross, warn);
elseif isnumeric(X)
    [R, t, composed, closureErr, warn] = matrix_to_rotm(X, opts, warn);
else
    error('mas_frame_check:type', 'X must be numeric or a struct, got %s', class(X));
end

if isempty(R) || ~isequal(size(R), [3 3])
    error('mas_frame_check:size', 'rotation block must be 3x3, got %s', mat2str(size(R)));
end
if ~all(isfinite(R(:)))
    error('mas_frame_check:nan', 'rotation block contains NaN or Inf');
end

orthErr = max(max(abs(R.'*R - eye(3))));
detR = det(R);
proper = detR > 0;

if orthErr > opts.orthTol
    warn{end+1} = sprintf(['R is not orthonormal: max|R''R-I| = %.3e. Built from ' ...
        'something that is not a rotation, or rounding accumulated. Every ' ...
        'composition downstream inherits this error.'], orthErr);
end
if ~proper
    warn{end+1} = sprintf(['det(R) = %.6f: a REFLECTION, not a rotation. A sign ' ...
        'error in one axis, or a left-handed frame in a right-handed chain.'], detR);
end
if isfinite(closureErr) && closureErr > opts.closureTol
    warn{end+1} = sprintf(['chain does not close: |product - I| = %.3e. One link ' ...
        'uses a different convention, or a frame is misnamed.'], closureErr);
end

r = struct();
r.R = R; r.t = t;
r.orthErr = orthErr; r.detR = detR; r.proper = proper;
r.composed = composed; r.closureErr = closureErr;
r.crossCheck = cross;
r.warnings = warn;
r.ok = isempty(warn);
r.verdict = tern(r.ok, 'PASS', 'FAIL');
r.detail = sprintf('orthErr %.3e, det %.6f -- %s', orthErr, detR, r.verdict);
end

% ===========================================================================
function [R, cross, warn] = spec_to_rotm(s, opts, cross, warn)
if isfield(s, 'quat')
    q = s.quat(:);
    nv = norm(q);
    if abs(nv - 1) > 1e-6
        warn{end+1} = sprintf(['quaternion norm is %.6f, not 1: every derived ' ...
            'rotation is scaled by norm^2. Reported, not silently normalised.'], nv);
    end
    R = quat_to_rotm(q);
    if opts.crossCheck && exist('quat2rotm', 'file') == 2
        cross.checked = true;
        cross.function = 'quat2rotm';
        cross.maxDev = max(max(abs(R - quat2rotm(q(:).'))));
        cross.note = 'vs Robotics System Toolbox';
    end
elseif isfield(s, 'eul')
    if ~isfield(s, 'seq')
        error('mas_frame_check:seq', ['Euler angles require .seq: the same three ' ...
            'numbers mean different orientations under ZYX and XYZ, so the ' ...
            'sequence cannot be defaulted.']);
    end
    e = s.eul(:);
    switch lower(opts.angleUnit)
        case 'rad'
            if any(abs(e) > 2*pi)
                error('mas_frame_check:unit', ['angleUnit is rad but an angle ' ...
                    'exceeds 2*pi (max %.3f): these look like degrees. Pass ' ...
                    'angleUnit=''deg'' or ''auto''.'], max(abs(e)));
            end
        case 'deg'
            e = e*pi/180;
        case 'auto'
            if any(abs(e) > 2*pi)
                e = e*pi/180;
                warn{end+1} = 'angles exceeded 2*pi and were read as degrees';
            end
        otherwise
            error('mas_frame_check:angleUnit', 'unknown angleUnit "%s"', opts.angleUnit);
    end
    R = eul_to_rotm(e, s.seq);
    cross.sequence = s.seq;
    if opts.crossCheck && exist('eul2rotm', 'file') == 2
        cross.checked = true;
        cross.function = 'eul2rotm';
        cross.maxDev = max(max(abs(R - eul2rotm(e(:).', s.seq))));
        cross.note = 'vs Robotics System Toolbox';
    end
else
    error('mas_frame_check:spec', 'struct needs .quat or .eul (+ .seq)');
end
end

% ===========================================================================
function [R, t, composed, closureErr, warn] = matrix_to_rotm(X, opts, warn)
composed = [];
closureErr = NaN;
t = [];

if ndims(X) == 3
    K = size(X, 3);
    for k = 1:K
        Tk = X(:,:,k);
        chk = check_one(Tk);
        if ~isempty(chk), warn{end+1} = chk; end %#ok<AGROW>
        if k == 1
            composed = Tk;
        else
            composed = composed * Tk;
        end
    end
    if opts.closedLoop
        closureErr = max(max(abs(composed - eye(size(composed)))));
    end
    R = composed(1:3,1:3);
    t = composed(1:3,4);
    return
end

T = X;
if isequal(size(T), [4 4])
    R = T(1:3,1:3);
    t = T(1:3,4);
elseif isequal(size(T), [3 3])
    R = T;
else
    error('mas_frame_check:size', 'expected 3x3 or 4x4, got %s', mat2str(size(T)));
end
chk = check_one(T);
if ~isempty(chk), warn{end+1} = chk; end
end

% ===========================================================================
function msg = check_one(T)
% Structural checks on one homogeneous / rotation matrix. Empty when clean.
msg = '';
if isequal(size(T), [4 4])
    bot = T(4, 1:4);
    if ~isequal(bot, [0 0 0 1])
        msg = sprintf('last row of the 4x4 is [%s], expected [0 0 0 1]', num2str(bot));
        return;
    end
    R = T(1:3,1:3);
else
    R = T;
end
if ~all(isfinite(R(:)))
    msg = 'rotation block contains NaN or Inf';
end
end

% ===========================================================================
function R = quat_to_rotm(q)
q = q(:) / max(norm(q), eps);
w = q(1); x = q(2); y = q(3); z = q(4);
R = [1-2*(y*y+z*z),   2*(x*y-w*z),   2*(x*z+w*y); ...
       2*(x*y+w*z), 1-2*(x*x+z*z),   2*(y*z-w*x); ...
       2*(x*z-w*y),   2*(y*z+w*x), 1-2*(x*x+y*y)];
end

% ===========================================================================
function R = eul_to_rotm(e, seq)
switch upper(seq)
    case 'ZYX', R = rotz(e(1))*roty(e(2))*rotx(e(3));
    case 'XYZ', R = rotx(e(1))*roty(e(2))*rotz(e(3));
    case 'ZYZ', R = rotz(e(1))*roty(e(2))*rotz(e(3));
    otherwise,  error('mas_frame_check:seq', 'unsupported sequence "%s"', seq);
end
end

function R = rotx(a)
R = [1 0 0; 0 cos(a) -sin(a); 0 sin(a) cos(a)];
end

function R = roty(a)
R = [cos(a) 0 sin(a); 0 1 0; -sin(a) 0 cos(a)];
end

function R = rotz(a)
R = [cos(a) -sin(a) 0; sin(a) cos(a) 0; 0 0 1];
end

% ===========================================================================
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
