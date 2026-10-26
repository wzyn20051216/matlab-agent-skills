function res = test_stat_decision(verbose)
%TEST_STAT_DECISION  Five-state evidence flow for count-based / statistical claims.
%
%   res = test_stat_decision()
%
% The defect this suite exists for: a digital-comm measurement with too few
% events to see the rate it is grading was reported as a REFUTATION. "The run
% cannot show the claim" and "the run shows the claim false" are different
% facts, and conflating them loses the second failure mode too -- a zero-error
% run is genuine evidence for a loose target (rule of three) and must not be
% downgraded to inconclusive either.
%
% Five states, each with its own name:
%   sufficient-support         PASS
%   sufficient-refutation      FAIL
%   insufficient-sample        UNDETERMINED (no power to see the claimed rate)
%   interval-straddles-target  UNDETERMINED (powered, but the target sits inside)
%   criterion-missing          UNDETERMINED (nothing was asked)
%
% Expected numbers are computed in-test from closed forms (rule-of-three bound
% 1-(1-L)^(1/n), textbook Wilson interval, erfc theory), never from the tool.

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
addpath(fullfile(repo, 'skills', 'matlab-signal-vision-ai', 'scripts'));

T = struct('name', {}, 'fn', {}, 'expect', {});

% ---------------- the flow itself ----------------------------------------
T(end+1) = tc('flow: nothing asked is not a failure', @() sd_noCriterion(), ...
    'UNDETERMINED/criterion-missing');
T(end+1) = tc('flow: 0/128 DOES certify 3e-2',  @() sd_ruleOfThree(), ...
    'PASS/sufficient-support');
T(end+1) = tc('flow: 0/128 cannot certify theory', @() sd_zeroNoPower(), ...
    'UNDETERMINED/insufficient-sample');
T(end+1) = tc('flow: H-SIG-B class is inconclusive', @() sd_sigBoundary(), ...
    'UNDETERMINED/insufficient-sample');
T(end+1) = tc('flow: 50/1000 refutes 1e-2',    @() sd_refuteTarget(), ...
    'FAIL/sufficient-refutation');
T(end+1) = tc('flow: 0/1e6 refutes a 6 dB label', @() sd_zeroRefutes(), ...
    'FAIL/sufficient-refutation');
T(end+1) = tc('flow: powered straddle is its own state', @() sd_straddle(), ...
    'UNDETERMINED/interval-straddles-target');
T(end+1) = tc('flow: count generated from theory passes', @() sd_supportTheory(), ...
    'PASS/sufficient-support');
T(end+1) = tc('flow: verdict follows state, never the reverse', @() sd_consistent(), true);

% ---------------- mas_ber_check keeps its frozen verdicts ----------------
T(end+1) = tc('ber_check: 0/128 @6dB stays UNDETERMINED', @() bc_zero128(), ...
    'UNDETERMINED');
T(end+1) = tc('ber_check: 0/128 now names why', @() bc_zero128State(), ...
    'insufficient-sample');
T(end+1) = tc('ber_check: target branch, loose target passes', @() bc_targetLoose(), ...
    'PASS/sufficient-support');
T(end+1) = tc('ber_check: target branch, 50/1000 fails', @() bc_targetTight(), ...
    'FAIL/sufficient-refutation');
T(end+1) = tc('ber_check: 626/2^18 @6dB still PASS', @() bc_bigStillPass(), ...
    'PASS/sufficient-support');

% ---------------- mas_ofdm_ber: the regression that started this ---------
T(end+1) = tc('ofdm: 0 errors at 8 dB must NOT be FAIL', @() of_tinyZero(), ...
    'UNDETERMINED');
T(end+1) = tc('ofdm: tiny run states why it cannot conclude', @() of_tinyState(), ...
    'insufficient-sample');
T(end+1) = tc('ofdm: default ladder still PASS', @() of_defaultPass(), 'PASS');
T(end+1) = tc('ofdm: every default point has power', @() of_defaultPower(), true);
T(end+1) = tc('ofdm: one unpowered point among powered ones is UNDET', @() of_mixed(), ...
    'UNDETERMINED');

nP = 0;
if verbose, fprintf('=== statistical evidence decision tests ===\n'); end
R = struct('case', {}, 'got', {}, 'pass', {});
for k = 1:numel(T)
    t = T(k);
    try
        got = t.fn();
    catch e
        got = sprintf('ERR/%s', e.identifier);
    end
    if ischar(t.expect)
        ok = strcmp(char(string(got)), t.expect);
    else
        ok = isequal(got, t.expect);
    end
    nP = nP + ok;
    if verbose
        fprintf('  [%s] %-44s -> %s\n', tern(ok, 'PASS', 'FAIL'), t.name, char(string(got)));
    end
    R(end+1) = struct('case', t.name, 'got', char(string(got)), 'pass', ok); %#ok<AGROW>
end
res = struct('nPass', nP, 'nTotal', numel(T), 'cases', R, 'pass', nP == numel(T));
if verbose
    fprintf('\n---- %d / %d decision cases passed ----\n', nP, numel(T));
end
end

% ===========================================================================
% helpers with independently computed reference numbers
% ===========================================================================
function up = ruleOfThree(n, L)
% exact one-sided upper bound for a zero count: (1-p)^n = 1-L
up = 1 - (1 - L)^(1/n);
end
function [lo, hi] = wilson(k, n, L)
zq = 1.959963984540054;                       % normal quantile at 95%, literal
if L ~= 0.95, zq = abs(sqrt(2))*erfcinv(2*(1 - (1+L)/2)); end
p = k/n; den = 1 + zq^2/n;
c = (p + zq^2/(2*n))/den;
h = zq/den*sqrt(p*(1-p)/n + zq^2/(4*n^2));
lo = max(0, c-h); hi = min(1, c+h);
end
function st = one(r)
if isfield(r, 'state') && ~isempty(r.state), st = r.state; else, st = 'NONE'; end
end
function v = sv(nErr, n, spec)
r = mas_stat_verdict(nErr, n, spec);
v = sprintf('%s/%s', r.verdict, one(r));
end

function v = sd_noCriterion()
v = sv(0, 128, struct('level', 0.95));
end
function v = sd_ruleOfThree()
u = ruleOfThree(128, 0.95);                   % 0.023132 < 0.03, so support is real
assert(u > 0.02313 && u < 0.02314);
v = sv(0, 128, struct('target', 0.03));
end
function v = sd_zeroNoPower()
v = sv(0, 128, struct('target', 0.5*erfc(sqrt(10^0.6))));
end
function v = sd_sigBoundary()
% exactly the frozen H-SIG-B input: 0 errors in 128 bits, QPSK at 6 dB Eb/N0.
p0 = 0.5*erfc(sqrt(10^0.6));
v = sv(0, 128, struct('theory', p0));
end
function v = sd_refuteTarget()
[lo, ~] = wilson(50, 1000, 0.95);
assert(lo > 0.01);                            % the hand bound really does refute
v = sv(50, 1000, struct('target', 0.01));
end
function v = sd_zeroRefutes()
p0 = 0.5*erfc(sqrt(10^0.6));
assert(1e6*p0 > 10);                          % plenty of power, so a zero count
v = sv(0, 1e6, struct('theory', p0));         % refutes the SNR label
end
function v = sd_straddle()
[lo, hi] = wilson(10, 1000, 0.95);
assert(lo < 0.01 && hi > 0.01 && 1000*0.01 >= 10);
v = sv(10, 1000, struct('target', 0.01));
end
function v = sd_supportTheory()
p0 = 0.5*erfc(sqrt(10^0.6));
n = 2^18;
v = sv(round(p0*n), n, struct('theory', p0));
end
function v = sd_consistent()
ok = true;
cases = {struct('nErr', 0, 'n', 128, 'spec', struct('target', 0.03)); ...
         struct('nErr', 50, 'n', 1000, 'spec', struct('target', 0.01)); ...
         struct('nErr', 10, 'n', 1000, 'spec', struct('target', 0.01)); ...
         struct('nErr', 0, 'n', 128, 'spec', struct())};
want = {'PASS', 'FAIL', 'UNDETERMINED', 'UNDETERMINED'};
for k = 1:numel(cases)
    r = mas_stat_verdict(cases{k}.nErr, cases{k}.n, cases{k}.spec);
    ok = ok && strcmp(r.verdict, want{k}) && ~isempty(r.state);
end
v = ok;
end

function v = bc_zero128()
r = mas_ber_check(0, 128, struct('scheme', 'QPSK', 'ebn0dB', 6));
v = r.verdict;
end
function v = bc_zero128State()
r = mas_ber_check(0, 128, struct('scheme', 'QPSK', 'ebn0dB', 6));
v = one(r);
end
function v = bc_targetLoose()
r = mas_ber_check(0, 128, struct('scheme', 'QPSK', 'ebn0dB', 6, 'targetBer', 0.03));
v = sprintf('%s/%s', r.verdict, one(r));
end
function v = bc_targetTight()
r = mas_ber_check(50, 1000, struct('scheme', 'QPSK', 'ebn0dB', 6, 'targetBer', 0.01));
v = sprintf('%s/%s', r.verdict, one(r));
end
function v = bc_bigStillPass()
p0 = 0.5*erfc(sqrt(10^0.6));
r = mas_ber_check(round(p0*2^18), 2^18, struct('scheme', 'QPSK', 'ebn0dB', 6));
v = sprintf('%s/%s', r.verdict, one(r));
end

function v = of_tinyZero()
% 320 bits at 8 dB: theory expects 0.06 errors, so a zero count is the MOST
% likely outcome and must not be called a refutation of the simulation.
o = mas_ofdm_ber(8, struct('nSym', 20, 'nSub', 8, 'cpLen', 2, 'seed', 7));
v = o.verdict;
end
function v = of_tinyState()
o = mas_ofdm_ber(8, struct('nSym', 20, 'nSub', 8, 'cpLen', 2, 'seed', 7));
v = one(o);
end
function v = of_defaultPass()
o = mas_ofdm_ber([0 2 4 6]);
v = o.verdict;
end
function v = of_defaultPower()
o = mas_ofdm_ber([0 2 4 6]);
v = all(o.nErrors >= 10) && all(strcmp(o.states, 'sufficient-support'));
end
function v = of_mixed()
% 6 dB point is powered, 12 dB point is not: the aggregate cannot be PASS.
o = mas_ofdm_ber([6 12], struct('nSym', 2000, 'nSub', 64, 'seed', 11));
v = o.verdict;
end

% ===========================================================================
function t = tc(name, fn, expect)
t = struct('name', name, 'fn', fn, 'expect', expect);
end
function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
