function res = test_table_audit(verbose)
%TEST_TABLE_AUDIT  The cleaning pipeline must account for every row it removes.
%
%   res = test_table_audit()
%
% The cases that matter are the ones where the arithmetic can silently disagree with
% reality: a row that qualifies for two rules, a fill rule that must not drop
% anything, and a table whose columns are not all numeric.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-data-analysis', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

T(end+1) = tc('nominal: 40 -> 33', @() nominal(), '40/33');
T(end+1) = tc('nominal: counted 3/2/2', @() counted(), '3/2/2');
T(end+1) = tc('nominal: balance holds', @() bal(), true);

% A row that is BOTH a duplicate and an outlier. Counting it twice is the classic
% way the audit stops adding up; the first rule must claim it.
T(end+1) = tc('double-qualified row counted once', @() doubleQualified(), true);

% fill must drop nothing and report the number filled
T(end+1) = tc('fill: nothing dropped', @() fillNoDrop(), '0/33');
T(end+1) = tc('fill: 3 values filled', @() fillCount(), 3);

% a non-numeric column must survive and be reported, not silently converted
T(end+1) = tc('text column survives', @() textKept(), true);
T(end+1) = tc('mixed types warned', @() mixedWarned(), true);

% keep-everything must be a no-op with a clean balance
T(end+1) = tc('keep-all is a no-op', @() keepAll(), true);

% an empty table must not crash or report a broken balance
T(end+1) = tc('empty table balanced', @() emptyTable(), true);

% a non-table must be rejected loudly
T(end+1) = tc('non-table rejected', @() nonTable(), 'ERR');

nP = 0;
if verbose, fprintf('=== table audit tests ===\n'); end
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
        fprintf('  [%s] %-34s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, ...
            char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d data-audit cases passed ----\n', nP, numel(T));
end
end

% ---------------------------------------------------------------------------
function [r, T] = fixture()
rng(3); n = 40;
x = round(sin((1:n).'/3), 3);
g = repmat(["A"; "B"], n/2, 1);
T = table((1:n).', x, g, 'VariableNames', {'id', 'x', 'group'});
T.x([5 12 27]) = NaN;
T.x(20) = T.x(10); T.group(20) = T.group(10);
T.x(33) = T.x(1);  T.group(33) = T.group(1);
T.x([8 35]) = 500;
rules = struct('missing', 'drop', 'duplicates', 'drop', 'dupKeys', {{'x', 'group'}}, ...
    'outliers', struct('method', 'iqr', 'factor', 1.5, 'action', 'remove'));
r = mas_table_audit(T, rules);
end

function v = nominal()
[r, ~] = fixture(); v = sprintf('%d/%d', r.nRowsIn, r.nRowsOut);
end
function v = counted()
[r, ~] = fixture();
c = struct();
for k = 1:numel(r.audit), c.(r.audit(k).rule) = r.audit(k).nDropped; end
v = sprintf('%d/%d/%d', c.missing, c.duplicates, c.outliers);
end
function v = bal()
[r, ~] = fixture(); v = r.balanced;
end

function v = doubleQualified()
% row 33 duplicates row 1 AND is given an outlying value: it must be counted once,
% as a duplicate, and the balance must still hold.
rng(3); n = 40;
x = round(sin((1:n).'/3), 3);
g = repmat(["A"; "B"], n/2, 1);
T = table((1:n).', x, g, 'VariableNames', {'id', 'x', 'group'});
% Both rows get the SAME outlying value: row 33 is then a duplicate of row 1 AND an
% outlier in its own right. Setting only row 33 to 500 (the first attempt) makes it
% no longer a duplicate at all, so the test proved nothing.
T.x(1) = 500; T.x(33) = 500; T.group(33) = T.group(1);
rules = struct('missing', 'drop', 'duplicates', 'drop', 'dupKeys', {{'x', 'group'}}, ...
    'outliers', struct('method', 'iqr', 'factor', 1.5, 'action', 'remove'));
r = mas_table_audit(T, rules);
c = struct();
for k = 1:numel(r.audit), c.(r.audit(k).rule) = r.audit(k).nDropped; end
% 2 rows removed, not 3: the duplicate is claimed by the duplicate rule and never
% reaches the outlier rule. Double counting would give 3 and break the balance.
v = r.balanced && c.duplicates == 1 && c.outliers == 1 && r.nDropped == 2;
end

function v = fillNoDrop()
[r, ~] = fixture();
rules = struct('missing', 'fill', 'duplicates', 'keep', ...
    'outliers', struct('action', 'flag'));
q = mas_table_audit(r.clean, rules);
% r.clean already has 33 rows, so filling must leave 33 and drop 0
v = sprintf('%d/%d', q.nDropped, q.nRowsOut);
end

function v = fillCount()
rng(3); n = 40;
x = round(sin((1:n).'/3), 3);
T = table((1:n).', x, 'VariableNames', {'id', 'x'});
T.x([5 12 27]) = NaN;
q = mas_table_audit(T, struct('missing', 'fill', 'duplicates', 'keep'));
v = q.audit(1).nFilled;
end

function v = textKept()
[r, ~] = fixture();
v = any(strcmp(r.clean.Properties.VariableNames, 'group')) && ...
    isstring(r.clean.group);
end

function v = mixedWarned()
T = table([1;2;3], {1;2;3}, 'VariableNames', {'a', 'cellcol'});
q = mas_table_audit(T, struct('missing', 'keep', 'duplicates', 'keep'));
v = ~isempty(q.typeWarnings);
end

function v = keepAll()
[r, ~] = fixture();
q = mas_table_audit(r.clean, struct('missing', 'keep', 'duplicates', 'keep', ...
    'outliers', struct('action', 'flag')));
v = q.balanced && q.nDropped == 0 && q.nRowsOut == r.nRowsOut;
end

function v = emptyTable()
T = table(zeros(0, 1), strings(0, 1), 'VariableNames', {'a', 'b'});
q = mas_table_audit(T, struct('missing', 'drop', 'duplicates', 'drop'));
v = q.balanced && q.nRowsOut == 0;
end

function v = nonTable()
try
    mas_table_audit([1 2 3]);
    v = 'NO_ERROR';
catch
    v = 'ERR';
end
end

function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
