function res = test_precheck(verbose)
%TEST_PRECHECK  Pins each pre-check against a case that must pass and one that
%must fail.
%
%   res = test_precheck()
%
% The failing cases are the defects from Phase 3A/3B, reproduced on purpose:
% a mask whose length does not match its target (silent in MATLAB), a struct with
% a missing field, a NaN in a numeric result, a product name passed to license().
% A pre-check that only ever says PASS is worse than none.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(fileparts(here),'scripts'));
addpath(fullfile(repo,'matlab','boost'));

T = struct('name',{},'kind',{},'args',{},'expect',{},'note',{});

T(end+1) = ck('function present','function',{'boost_params'},true,'');
T(end+1) = ck('function missing','function',{'no_such_fn_xyz'},false,'MISSING_FUNCTION');

s = struct('a',1,'b',2);
T(end+1) = ck('struct complete','struct',{s,{'a','b'}},true,'');
T(end+1) = ck('struct missing field','struct',{s,{'a','c'}},false,'STRUCT_FIELD_MISMATCH');

T(end+1) = ck('numeric finite','numeric',{1:3,struct('finite',true)},true,'');
T(end+1) = ck('numeric NaN','numeric',{[1 NaN 3],struct('finite',true)},false,'NUMERIC_CONSTRAINT');
T(end+1) = ck('numeric range','numeric',{1.5,struct('range',[0 1])},false,'NUMERIC_CONSTRAINT');

% the exact Phase 3B.2 bug: a per-period mask used on a waveform array
T(end+1) = ck('mask length ok','index',{true(3000,1),3000},true,'');
T(end+1) = ck('mask length wrong','index',{true(3000,1),120000},false,'INDEX_MASK_MISMATCH');

T(end+1) = ck('cells uniform','cell',{{1,2,3},[1 1]},true,'');
T(end+1) = ck('cells ragged','cell',{{1,[2 3],4},[]},false,'CELL_SHAPE_MISMATCH');

% product name vs license feature: this product IS licensed on this machine
T(end+1) = ck('toolbox by product name','toolbox',{'Deep Learning Toolbox'},true,'');
T(end+1) = ck('unknown toolbox','toolbox',{'Quantum Basket Weaver'},false,'TOOLBOX_UNAVAILABLE');

T(end+1) = ck('path exists','path',{fullfile(repo,'matlab','boost')},true,'');
T(end+1) = ck('path missing','path',{fullfile(repo,'no_such_dir')},false,'PATH_MISSING');

mdl = fullfile(repo,'matlab','boost','models','boost_avg.slx');
T(end+1) = ck('model loads','model',{mdl},true,'');

nP = 0;
if verbose, fprintf('=== precheck tests ===\n'); end
R = struct('name',{},'pass',{},'detail',{});
for k = 1:numel(T)
    t = T(k);
    r = mas_precheck(t.kind, t.args{:});
    ok = (r.pass == t.expect);
    if ~t.expect && ~isempty(t.note)
        ok = ok && strcmp(r.errorClass, t.note);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-24s %-9s %s\n', tern(ok,'PASS','FAIL'), t.name, ...
            t.kind, r.detail);
    end
    R(end+1) = struct('name',t.name,'pass',ok,'detail',r.detail); %#ok<AGROW>
end
res = struct('nPass',nP,'nTotal',numel(T),'cases',R,'pass',nP==numel(T));
if verbose, fprintf('\n---- %d / %d precheck cases passed ----\n', nP, numel(T)); end
end

% ---------------------------------------------------------------------------
function t = ck(name, kind, args, expect, note)
% struct('args',{args}) would EXPAND the cell into a struct array; assign after
% construction so the cell is stored as one argument list.
t = struct('name',name,'kind',kind,'expect',expect,'note',note);
t.args = args;
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
