function r = mas_codegen_ready(fileOrFcn, opts)
%MAS_CODEGEN_READY  Static readiness audit of a MATLAB file for C/C++ code generation.
%
%   r = mas_codegen_ready('myAlg.m')
%   r = mas_codegen_ready('myAlg', struct('strict', true))
%
%   r.findings   struct array: id, severity, line, symbol, message
%   r.counts     struct: blocker, warning, info
%   r.ok         true when there are no blockers
%   r.verdict    'READY' | 'BLOCKED' | 'READY_WITH_WARNINGS'
%   r.detail
%
% WHAT IT CAN AND CANNOT TELL YOU
% This is a static audit, not a build. It finds the constructs that make
% `codegen` fail outright -- dynamic introspection, interactive I/O, workspace
% mutation, unbounded array growth -- and reports them with line numbers before
% you spend a build cycle on them. It does NOT prove the code will compile;
% `mas_codegen_verify` does that by actually running `codegen`.
%
% The rules fall into two classes, and the difference matters:
%
%   BLOCKER  the construct is not supported for code generation at all, or it
%            changes array size in a way the Coder cannot bound. `codegen`
%            will fail or silently produce a variable-size path.
%   WARNING  the construct IS supported but has restrictions worth knowing
%            about (tables, datetime, graphics, cells used as heterogeneous
%            containers).
%
% ARRAY GROWTH IS ONLY A BLOCKER INSIDE A LOOP
% `x(end+1) = v` is legal MATLAB and legal codegen if it happens once, but
% inside a for/while it forces a variable-size array with no upper bound, which
% the Coder cannot dimension. The same line outside a loop is only a warning.
% That distinction is why this is a scan and not a regex grep.

if nargin < 2, opts = struct(); end
opts = dflt(opts, struct('strict', false));

path_ = resolve_path(fileOrFcn);
txt = read_text(path_);
lines = split_lines(txt);

rules = rule_table();
F = struct('id', {}, 'severity', {}, 'line', {}, 'symbol', {}, 'message', {});

depth = 0;                                  % for/while nesting depth
inBlock = false;                            % inside a %{ ... %} block comment
for k = 1:numel(lines)
    raw = lines{k};
    s = strtrim(raw);

    % ---- block comment state (checked before anything else) -------------
    if inBlock
        if ~isempty(regexp(s, '^%\}', 'once')), inBlock = false; end
        continue;
    end
    if ~isempty(regexp(s, '^%\{', 'once')), inBlock = true; continue; end
    if isempty(s) || s(1) == '%', continue; end

    % ---- strip a trailing comment, then drop string literals -------------
    code = strip_comment(raw);
    code = blank_strings(code);

    for j = 1:size(rules, 1)
        rid = rules{j, 1}; sev = rules{j, 2}; sym = rules{j, 3}; pat = rules{j, 4};
        if isempty(regexp(code, pat, 'once')), continue; end

        if strcmp(rid, 'CG010') && depth == 0
            sev = 'warning';                % growth outside a loop is bounded
        end
        if opts.strict && strcmp(sev, 'warning')
            sev = 'blocker';                 % strict = warnings gate the build
        end
        F(end+1) = struct('id', rid, 'severity', sev, 'line', k, 'symbol', sym, ...
            'message', rules{j, 5}); %#ok<AGROW>
    end

    % ---- loop depth tracking (after scanning, so the closing `end` matches) --
    if ~isempty(regexp(code, '\<(for|while)\s', 'once')), depth = depth + 1; end
    if ~isempty(regexp(code, '^end\>', 'once')) || ...
       ~isempty(regexp(code, '\bend\b\s*$', 'once'))
        depth = max(depth - 1, 0);
    end
end

nB = sum(strcmp({F.severity}, 'blocker'));
nW = sum(strcmp({F.severity}, 'warning'));
r = struct();
r.file = path_;
r.findings = F;
r.counts = struct('blocker', nB, 'warning', nW, 'total', numel(F));
r.ok = (nB == 0);
if nB > 0
    r.verdict = 'BLOCKED';
elseif nW > 0
    r.verdict = 'READY_WITH_WARNINGS';
else
    r.verdict = 'READY';
end
r.detail = sprintf('%s: %d blocker(s), %d warning(s) -- %s', ...
    just_name(path_), nB, nW, r.verdict);
end

% ===========================================================================
function R = rule_table()
% id, severity, symbol, pattern, message
R = {
'CG001', 'blocker', 'eval',        '\<(eval|evalc|evalin|assignin)\s*\(', ...
    'dynamic evaluation is not supported for code generation';
'CG002', 'blocker', 'input',       '\<(input|keyboard|pause|uiwait|ginput)\s*\(', ...
    'interactive I/O cannot be compiled to C';
'CG003', 'blocker', 'clear',       '\<(clear|clearvars|addpath|cd|save|diary|dbstop)\s*\(?', ...
    'workspace/path mutation is not supported for code generation';
'CG004', 'blocker', 'load',        '\<(load|fopen|fscanf|webread|urlread)\s*\(', ...
    'file/network I/O is not supported for code generation';
'CG005', 'blocker', 'containers',  '(containers\.Map|javaArray|javaMethod|javaObject)', ...
    'Map/Java containers are not supported for code generation';
'CG006', 'warning', 'table',       '\<(table|timetable)\s*\(', ...
    'table has restricted support: prefer numeric arrays in generated code';
'CG007', 'warning', 'datetime',    '\<(datetime|duration)\s*\(', ...
    'datetime/duration have restricted support in generated code';
'CG008', 'warning', 'graphics',  '\<(figure|plot|subplot|axes|imshow|surf)\s*\(', ...
    'graphics are extrinsic: they will not appear in generated C code';
'CG009', 'warning', 'cell',      '\<cell\s*\(', ...
    'cell arrays are supported but heterogeneous cells often fail: prefer structs';
'CG010', 'blocker', 'grow',       '\(\s*end\s*\+\s*1\s*\)', ...
    'array grows inside a loop: preallocate to a fixed maximum size';
};
end

% ===========================================================================
function p = resolve_path(x)
% Resolve a file name OR a full path to a real file path.
%
% The first version only knew how to look up a FUNCTION NAME with `which`, and
% the documentation explicitly accepts a file path -- so `mas_codegen_ready(fullfile(tempdir,'x.m'))`
% returned an empty string and read_text() failed with "cannot open " (empty
% argument), which reads like an I/O problem rather than a path-resolution bug.
%
% Two facts drive the order below:
%   - `exist(x,'file')` answers for BOTH a bare name on the path and a full path
%   - `which(fullPath)` returns EMPTY for a full path, because which() searches
%     the MATLAB path rather than the file system
% So the file system is checked first, and `which` is only consulted for a name
% that is not a file as given.
if ischar(x) || (isstring(x) && isscalar(x))
    x = char(x);
    % Resolve in this order, because each step fails for a different shape of
    % input:
    %   1. which([x '.m']) -- a bare NAME without the extension
    %   2. which(x)        -- a name WITH the extension, or a .p / .mex file
    %   3. the string as a PATH -- which() returns '' for a full path, because
    %      it searches the path rather than the file system, and that is the
    %      case the original version dropped
    % Step 3 is verified with a real fopen() rather than trusted: a bare name
    % that exist() reports as a file is not necessarily openable as a path
    % (exist('grow_outside','file') is 2, fopen('grow_outside','r') fails).
    p = which([x '.m']);
    if isempty(p), p = which(x); end
    if isempty(p)
        if exist(x, 'file') ~= 0
            fid = fopen(x, 'r');
            if fid >= 0
                fclose(fid);
                p = x;
            end
        end
    end
    if isempty(p)
        error('mas_codegen_ready:notfound', 'cannot resolve "%s" to a file', x);
    end
    return;
else
    error('mas_codegen_ready:type', 'expected a file name or function name');
end
end

% ===========================================================================
function t = read_text(p)
fid = fopen(p, 'r');
if fid < 0, error('mas_codegen_ready:open', 'cannot open %s', p); end
t = fread(fid, inf, '*char').';
fclose(fid);
end

% ===========================================================================
function L = split_lines(t)
t = strrep(t, sprintf('\r\n'), sprintf('\n'));
t = strrep(t, sprintf('\r'), sprintf('\n'));
L = strsplit(t, sprintf('\n'), 'CollapseDelimiters', false).';
end

% ===========================================================================
function c = strip_comment(raw)
% Remove a trailing comment, but not a % inside quotes or a %% section break.
inStr = false;
for k = 1:numel(raw)
    ch = raw(k);
    if ch == ''''
        inStr = ~inStr;
    elseif ch == '%' && ~inStr
        c = raw(1:k-1);
        return;
    end
end
c = raw;
end

% ===========================================================================
function c = blank_strings(code)
% Replace the CONTENTS of quoted strings with spaces so that keywords inside
% them cannot trip a rule. Quote chars are kept so the quote-parity state stays
% readable to the caller.
c = code;
inStr = false;
for k = 1:numel(c)
    if inStr
        if c(k) == ''''
            inStr = false;               % closing quote: keep it
        else
            c(k) = ' ';
        end
    else
        if c(k) == ''''
            inStr = true;                % opening quote: keep it
        end
    end
end
end

% ===========================================================================
function n = just_name(p)
[~, n, e] = fileparts(p);
n = [n e];
end

% ===========================================================================
function o = dflt(o, d)
f = fieldnames(d);
for k = 1:numel(f)
    if ~isfield(o, f{k}), o.(f{k}) = d.(f{k}); end
end
end
