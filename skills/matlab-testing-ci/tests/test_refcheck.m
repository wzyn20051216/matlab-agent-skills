function res = test_refcheck(verbose)
%TEST_REFCHECK  The reference mechanism must reject bad values and tampered files.
%
%   res = test_refcheck()
%
% A verifier that only ever says PASS is indistinguishable from no verifier. These
% cases feed it deliberately wrong values and a deliberately edited manifest, and
% require the correct rejection in each case.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
scr = fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts');
addpath(scr);
manifest = fullfile(repo, 'evals', 'references', 'reference_manifest.json');
tmp = fullfile(tempdir, 'mas_refcheck_test');
if ~isfolder(tmp), mkdir(tmp); end

T = struct('name', {}, 'fn', {}, 'expect', {});
T(end+1) = tc('correct values pass', @() mas_verify_task('D3', ...
    struct('magAtFc', -3.0103, 'magAt2Fc', -27.9657, 'stable', true, 'dcGain', 1)), 'PASS');
T(end+1) = tc('analog formula rejected', @() mas_verify_task('D3', ...
    struct('magAtFc', -3.0103, 'magAt2Fc', -24.0998, 'stable', true, 'dcGain', 1)), 'FAIL');
T(end+1) = tc('dc gain 0.707 rejected', @() mas_verify_task('D3', ...
    struct('magAtFc', -3.0103, 'magAt2Fc', -27.9657, 'stable', true, 'dcGain', 0.7071)), 'FAIL');
T(end+1) = tc('missing field -> UNDETERMINED', @() mas_verify_task('D3', ...
    struct('magAtFc', -3.0103, 'stable', true)), 'UNDETERMINED');
T(end+1) = tc('unstable filter rejected', @() mas_verify_task('D3', ...
    struct('magAtFc', -3.0103, 'magAt2Fc', -27.9657, 'stable', false, 'dcGain', 1)), 'FAIL');
T(end+1) = tc('row/col centroid swap rejected', @() mas_verify_task('D4', ...
    struct('areas', [592 100], 'centroidBig', [20.5676 35.5541])), 'FAIL');
T(end+1) = tc('wrong peak time rejected', @() mas_verify_task('D5', ...
    struct('overshoot', 16.3034, 'peakTime', 1.0, 'settlingTime', 4.0, 'stable', true)), 'FAIL');
T(end+1) = tc('unknown task id', @() mas_verify_task('ZZ9', struct()), 'UNDETERMINED');

nP = 0;
if verbose, fprintf('=== reference verifier tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    r = t.fn();
    ok = strcmp(r.status, t.expect);
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-32s -> %-13s (want %s)\n', tern(ok, 'PASS', 'FAIL'), ...
            t.name, r.status, t.expect);
    end
    R(end+1) = struct('case', t.name, 'got', r.status, 'pass', ok); %#ok<AGROW>
end

% ---- manifest tampering ----------------------------------------------------
% Two attacks, because they exercise different guards:
%   (a) edit a value, leave the hash  -> the recomputed value no longer matches
%       the frozen value (VALUE guard)
%   (b) edit the value AND the hash   -> the hash no longer equals the hash of the
%       re-derived values (HASH guard)
% Neither can be caught by the task-level verifier alone, which grades against
% whatever the manifest says. That is why the manifest has its own verify pass.
% fileread, not fread(...,'char'): fread with a 'char' precision still returns a
% DOUBLE array in MATLAB, and jsondecode then rejects it with "JSON text must be a
% character vector". strrep() tolerated the doubles, so the write step worked and
% only the decode failed -- a confusing half-failure.
raw = fileread(manifest);

bad1 = strrep(raw, '-27.9657', '-24.0998');
f1 = fullfile(tmp, 'tamper_value.json');
fid = fopen(f1, 'w'); fwrite(fid, bad1, 'char'); fclose(fid);
c1 = mas_refcheck('verify', f1);
ok1 = ~c1.pass && ~strcmp(c1.entries.D3.status, 'OK');
nP = nP + ok1;
if verbose
    fprintf('  [%s] %-32s -> %s\n', tern(ok1, 'PASS', 'FAIL'), 'value edited', ...
        c1.entries.D3.status);
end

% read the committed hash through the JSON decoder rather than a regexp: the
% pretty-printed file may format the field differently, and a regexp that silently
% matches nothing turns this into a test of nothing (which is what happened first).
Mfull = jsondecode(raw);
hD3 = Mfull.entries.D3.hash;
bad2 = strrep(bad1, hD3, repmat('0', 1, numel(hD3)));
f2 = fullfile(tmp, 'tamper_hash.json');
fid = fopen(f2, 'w'); fwrite(fid, bad2, 'char'); fclose(fid);
c2 = mas_refcheck('verify', f2);
ok2 = ~c2.pass && strcmp(c2.entries.D3.status, 'HASH_CHANGED');
nP = nP + ok2;
if verbose
    fprintf('  [%s] %-32s -> %s\n', tern(ok2, 'PASS', 'FAIL'), 'value and hash edited', ...
        c2.entries.D3.status);
end

% ---- the frozen file itself must verify ------------------------------------
vr = mas_refcheck('verify');
okFrozen = vr.pass;
nP = nP + okFrozen;
if verbose
    fprintf('  [%s] %-32s -> %d/%d referenced verified\n', tern(okFrozen, 'PASS', 'FAIL'), ...
        'committed manifest verifies', vr.nPass, vr.nTotal);
end

total = numel(T) + 3;
res = struct('nPass', nP, 'nTotal', total, 'cases', R, 'pass', nP == total, ...
    'manifestVerify', vr);
if verbose
    fprintf('\n---- %d / %d verifier cases passed ----\n', nP, total);
end
end

% ---------------------------------------------------------------------------
function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
