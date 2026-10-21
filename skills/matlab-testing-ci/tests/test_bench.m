function res = test_bench(verbose)
%TEST_BENCH  Pins the benchmark ledger's two load-bearing promises.
%
%   1. A SKIP can never be laundered into a PASS.
%   2. "Unknown" is not "absent". The ledger must not guess.
%
% The second one is the harder promise. A MATLAB process cannot enumerate the
% host agent's MCP tool bindings, so the honest answer from inside `matlab
% -batch` is UNKNOWN. An earlier draft of mas_bench_record returned a hard 0 --
% i.e. it reported "there are no tools" when it had not actually looked. That is
% a fabricated negative, the same defect class as mas_dep_probe reporting a
% built-in as missing, and these tests exist to keep it from coming back.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% Each case builds a ledger; they all write into a scratch folder so a test run
% does not leave one benchmark_ledger_*.json per assertion in the real folder.
SCRATCH = fullfile(tempdir, 'mas_bench_test');
if ~exist(SCRATCH, 'dir'), mkdir(SCRATCH); end
cleanup = onCleanup(@() rmdir(SCRATCH, 's'));

% ---- the SKIP-must-not-become-PASS invariants ----------------------------
T(end+1) = mk('zero tools -> SKIP',            @(d) zeroToolsAreSkip(d),   'SKIP');
T(end+1) = mk('zero tools -> overall PARTIAL', @(d) zeroToolsPartial(d),   'PARTIAL');
T(end+1) = mk('undeclared -> UNKNOWN',         @(d) undeclaredUnknown(d),  'UNKNOWN');
T(end+1) = mk('undeclared -> overall PARTIAL', @(d) undeclaredPartial(d),  'PARTIAL');
T(end+1) = mk('some tools -> NOT_RUN',         @(d) someToolsNotRun(d),    'NOT_RUN');

% ---- R1 evidence must be traceable, not asserted -------------------------
T(end+1) = mk('R1 verdict is a known state',   @(d) r1StateKnown(d),      true);
T(end+1) = mk('R1 evidence cites a report',    @(d) r1CitesReport(d),     true);
T(end+1) = mk('ledger is JSON round-trippable',@(d) roundTrip(d),         true);

% ---- server-on-disk vs bound-to-session must stay distinct --------------
T(end+1) = mk('binding gap != missing install',@(d) bindingVsInstall(d),  true);

% -------------------------------------------------------------------------
% Cases come in two shapes: some compare a returned STATE STRING, others ask a
% yes/no question. `expect` is a char for the former and a logical for the latter.
n = numel(T);
pass = false(n,1); got = cell(n,1);
for k = 1:n
    try
        got{k} = T(k).fn(SCRATCH);
    catch ME
        got{k} = sprintf('<EXC %s>', ME.message);
    end
    if ischar(T(k).expect)
        pass(k) = ischar(got{k}) && strcmp(got{k}, T(k).expect);
    else
        pass(k) = isequal(logical(got{k}), logical(T(k).expect));
    end
    if verbose
        fprintf('  %-4s %-34s -> %-12s (want %s)\n', ...
            tern(pass(k),'PASS','FAIL'), T(k).name, ...
            show(got{k}), show(T(k).expect));
    end
end
fprintf('test_bench: %d / %d passed\n', sum(pass), n);
% Build the struct field by field. `{T.name}` inside struct() introduces a
% SECOND level of cell nesting, which makes struct() build a 1x9 struct ARRAY
% against scalar fields -- an error that surfaces only for some callers, so it
% reads as a flaky suite rather than a construction bug.
res = struct();
res.nPass = sum(pass);
res.nTotal = n;
res.pass = all(pass);
res.cases = T.name;
end

% ===========================================================================
function s = zeroToolsAreSkip(d)
r = mas_bench_record('report', 0, d);
s = r.r2.status;
end

function s = zeroToolsPartial(d)
r = mas_bench_record('report', 0, d);
s = r.overall;
end

function s = undeclaredUnknown(d)
r = mas_bench_record('report', [], d);
s = r.r2.status;
end

function s = undeclaredPartial(d)
r = mas_bench_record('report', [], d);
s = r.overall;
end

function s = someToolsNotRun(d)
r = mas_bench_record('report', 3, d);
s = r.r2.status;
end

function v = r1StateKnown(d)
r = mas_bench_record('report', 0, d);
v = any(strcmp(r.r1.status, {'DONE','FAIL','SKIP'}));
end

function v = r1CitesReport(d)
% A DONE verdict with no file behind it is a claim, not a measurement.
r = mas_bench_record('report', 0, d);
if ~strcmp(r.r1.status, 'DONE')
    v = true;   % nothing to cite; the status itself is the assertion
    return;
end
v = ~isempty(r.r1.bestRun) && ~isempty(r.r1.sha256) && numel(r.r1.sha256) == 64;
end

function v = roundTrip(d)
r = mas_bench_record('report', 0, d);
if isempty(r.ledgerFile) || ~isfile(r.ledgerFile), v = false; return; end
try
    d = jsondecode(fileread(r.ledgerFile));
    v = isfield(d, 'r1') && isfield(d, 'overall') && ...
        strcmp(d.overall, r.overall);
catch
    v = false;
end
end

function v = bindingVsInstall(d)
% The evidence string must distinguish "server absent from the machine" from
% "server present but not bound here", because the fixes differ: install vs bind.
r = mas_bench_record('report', 0, d);
if ~strcmp(r.r2.status, 'SKIP')
    v = true;
    return;
end
v = contains(lower(r.r2.evidence), 'bind') && ...
    isfield(r.r2, 'reason') && strcmp(r.r2.reason, 'NO_MATLAB_MCP_TOOL_IN_SESSION');
end

% ===========================================================================
function t = mk(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

function s = show(v)
if ischar(v)
    if numel(v) > 12, s = [v(1:11) '..']; else, s = v; end
elseif islogical(v)
    s = tern(v, 'true', 'false');
else
    s = mat2str(v);
end
end