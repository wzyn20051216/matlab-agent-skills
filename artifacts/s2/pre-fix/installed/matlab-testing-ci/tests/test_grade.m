function res = test_grade(verbose)
%TEST_GRADE  Pins the three-level verdict, including the combinations that used
%to be reported as "PASS".
%
%   res = test_grade()

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here),'scripts'));

T = struct('name',{},'checks',{},'expect',{},'expectCorrect',{},'expectMeets',{});

T(end+1) = mk('all good', [ ...
    chk('v',true,'numeric',1.00,1.00,0.01,NaN,'le')
    chk('d',true,'domain',0.4,NaN,NaN,0.5,'le') ], 'PASS', true, true);

T(end+1) = mk('skipped check', [ ...
    chk('v',true,'numeric',1.00,1.00,0.01,NaN,'le')
    chk('d',false,'domain',NaN,NaN,NaN,0.5,'le') ], 'FAIL', true, 'UNDETERMINED');
% "meets" cannot be TRUE when a required check never ran: the evidence is
% missing, not satisfactory. The verdict is still FAIL because ran = false.

T(end+1) = mk('wrong number', [ ...
    chk('v',true,'numeric',1.30,1.00,0.01,NaN,'le')
    chk('d',true,'domain',0.4,NaN,NaN,0.5,'le') ], 'FAIL', false, true);

T(end+1) = mk('correct but not accepted', [ ...
    chk('v',true,'numeric',47.884,47.884,1e-3,NaN,'le')
    chk('recovery',true,'domain',2.252,NaN,NaN,2.0,'le') ], ...
    'CORRECT_NOT_ACCEPTED', true, false);

T(end+1) = mk('no numeric check', [ ...
    chk('d',true,'domain',0.4,NaN,NaN,0.5,'le') ], ...
    'UNDETERMINED', 'UNDETERMINED', true);

T(end+1) = mk('no reference', [ ...
    chk('v',true,'numeric',1.00,NaN,0.01,NaN,'le') ], ...
    'FAIL', false, 'UNDETERMINED');

nP = 0;
if verbose, fprintf('=== grading tests ===\n'); end
R = struct('case',{},'overall',{},'correct',{},'meets',{},'pass',{});
for k = 1:numel(T)
    t = T(k);
    r = mas_grade(t.checks);
    ok = strcmp(r.overall, t.expect);
    if ischar(t.expectCorrect), ok = ok && strcmp(r.correct, t.expectCorrect);
    else, ok = ok && isequal(r.correct, t.expectCorrect); end
    if ischar(t.expectMeets), ok = ok && strcmp(r.meets, t.expectMeets);
    else, ok = ok && isequal(r.meets, t.expectMeets); end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-26s -> %-22s correct=%s meets=%s\n', tern(ok,'PASS','FAIL'), ...
            t.name, r.overall, val2s(r.correct), val2s(r.meets));
    end
    R(end+1) = struct('case',t.name,'overall',r.overall,'correct',val2s(r.correct), ...
        'meets',val2s(r.meets),'pass',ok); %#ok<AGROW>
end
res = struct('nPass',nP,'nTotal',numel(T),'cases',R,'pass',nP==numel(T));
if verbose, fprintf('\n---- %d / %d grading cases passed ----\n', nP, numel(T)); end
end

function c = chk(id, executed, kind, value, reference, tol, limit, cmp)
c = struct('id',id,'executed',executed,'kind',kind,'value',value, ...
    'reference',reference,'tol',tol,'limit',limit,'cmp',cmp,'reason','');
end

function t = mk(name, checks, overall, correct, meets)
t = struct('name',name,'checks',checks,'expect',overall, ...
    'expectCorrect',correct,'expectMeets',meets);
end

function s = val2s(v)
if ischar(v), s = v; else, s = mat2str(v); end
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
