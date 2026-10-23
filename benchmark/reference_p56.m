function A = reference_p56(tasksFile, answersFile)
%REFERENCE_P56  Evaluation-side answer generator for the Phase 5.6 gain tasks.
%
%   A = reference_p56(tasksFile, answersFile)
%
% Two rules make this file usable in a causal comparison:
%
%  1. NOTHING HERE CALLS A mas_* TOOL. Every expectation is re-derived from a
%     closed form written out below (textbook QPSK bit-error rate, the Wilson
%     score interval, the binomial z, an analytic ODE solution). If the answers
%     were "whatever our own tool prints", the tool arm would match by
%     construction and the experiment would measure nothing.
%  2. It is COMMITTED BY HASH BEFORE ANY EPISODE RUNS (benchmark_publish.m
%     records sha256 of this file and never copies it into an arm workspace), so
%     the expectations cannot be fitted to results after seeing them. Absence
%     from the workspace is not enforcement -- the Phase 5.6 isolation probe
%     found none -- but the commitment is verifiable after the fact.
%
% Answers are generated only at grade time by benchmark_seal.m. Between publish
% and seal there is no answer file anywhere on this host to read.

T = load_tasks(tasksFile);
ids = cellfun(@(s) char(s.id), T, 'UniformOutput', false);

recs = cell(1, numel(T));
for k = 1:numel(T)
    id = ids{k};
    switch id
        case 'P56-SIG-B'
            % 0 errors in n = 26624 bits, QPSK at Eb/N0 = 8.8 dB, target BER 1e-4,
            % 95% level. Closed forms:
            %   p_theory = 1/2 erfc(sqrt(Eb/N0))          -> 4.9085676e-05
            %   Wilson upper (k = 0)  = z^2 / (n + z^2), z = 1.959963984540054
            %                          = 1.4426475e-04   ( > target -> cannot certify)
            %   Wilson lower (k = 0)  = 0                 ( < target -> cannot refute)
            %   expected events n*p   = 1.31              ( < 10 -> no power either way)
            [verdict, state] = sig_expect(0, 26624, 8.8, 1e-4);
            recs{k} = task_record(id, 'matlab-signal-vision-ai', 'mas_ber_check', ...
                verdict, state);
        case 'P56-SIG-F'
            % 550 errors in 1e6 bits, QPSK at 8.8 dB. n*p = 49.1 (powered) and
            %   z = (phat - p)/sqrt(p(1-p)/n) = 71.5  >>  3
            % so the "matches theory" claim is refuted with sufficient evidence.
            [verdict, state] = sig_expect(550, 1000000, 8.8, []);
            recs{k} = task_record(id, 'matlab-signal-vision-ai', 'mas_ber_check', ...
                verdict, state);
        case 'P56-ODE-N'
            % y' = [y2;-y1], y0 = [1;0] on [0,2pi], y = [cos t; -sin t].
            % ode45 at RelTol 1e-8 / AbsTol 1e-10 tracks it to ~1e-9 in absolute
            % error, so the MAGNITUDE-scaled error (divide by max(1, max|yRef|) = 1)
            % is <= 1e-6 while the SOLVER-scaled error (divide by
            % AbsTol + RelTol*|yRef|) is an O(1) count of tolerances. Grading the
            % field at 1e-6 is exactly what separates the two conventions; the
            % min check on solverMaxScaled forces the arm to report both.
            recs{k} = task_record(id, 'matlab-data-analysis', 'mas_ode_check', ...
                'PASS', '');
        otherwise
            error('reference_p56:task', 'no expectation for task %s', id);
    end
end

A = struct();
A.schema = 'mas-benchmark-answers/2';
A.generatedAt = datestr(now, 31);
A.generator = 'benchmark/reference_p56.m';
A.derivation = ['closed forms only (1/2 erfc(sqrt(Eb/N0)), Wilson score interval, ' ...
    'binomial z, analytic ODE solution); no mas_* tool is called here'];
A.tasks = recs;

if nargin > 1 && ~isempty(answersFile)
    fid = fopen(answersFile, 'w');
    if fid < 0, error('reference_p56:write', 'cannot write %s', answersFile); end
    fwrite(fid, jsonencode(A), 'char'); fclose(fid);
end
end

% ===========================================================================
function rec = task_record(id, skill, tool, verdict, state)
F = struct('name', {}, 'op', {}, 'ref', {}, 'tol', {});
switch id
    case 'P56-SIG-B'
        % graded observable names are fixed by the task's report spec so a
        % number can never be quoted without the formula that produced it
        F(end+1) = field('state', 'exact', state, 0);
        F(end+1) = field('ciWilsonUpper95', 'rel', 1.4426475e-04, 0.02);
        F(end+1) = field('theoryExpectedEvents', 'rel', 1.3069, 0.05);
    case 'P56-SIG-F'
        F(end+1) = field('state', 'exact', state, 0);
        F(end+1) = field('z', 'rel', 71.4985, 0.02);
        F(end+1) = field('theoryExpectedEvents', 'rel', 49.086, 0.02);
    case 'P56-ODE-N'
        F(end+1) = field('errorMaxScaled', 'max', 0, 1e-6);
        F(end+1) = field('errorSolverMaxScaled', 'min', 0.05, 0);
        F(end+1) = field('stiffnessClassified', 'exact', 'nonstiff', 0);
        F(end+1) = field('invariantMaxRelDrift', 'max', 0, 1e-6);
end
rec = struct('id', id, 'skill', skill, 'tool', tool, 'verdict', verdict, 'fields', F);
end

function [verdict, state] = sig_expect(nErr, nBits, ebn0dB, targetBer)
% Independent derivation of the verdict from the five-state evidence flow.
p = 0.5*erfc(sqrt(10^(ebn0dB/10)));          % textbook QPSK, coherent, Gray
z95 = 1.959963984540054;
lo = wilson_lo(nErr, nBits, z95);  hi = wilson_hi(nErr, nBits, z95);
if ~isempty(targetBer)
    % the claim under test is "BER <= target"
    if lo > targetBer
        verdict = 'FAIL'; state = 'sufficient-refutation';
    elseif hi <= targetBer
        verdict = 'PASS'; state = 'sufficient-support';
    elseif nBits*targetBer < 10
        verdict = 'UNDETERMINED'; state = 'insufficient-sample';
    else
        verdict = 'UNDETERMINED'; state = 'interval-straddles-target';
    end
else
    z = (nErr/nBits - p)/sqrt(p*(1 - p)/nBits);
    if nBits*p < 10
        verdict = 'UNDETERMINED'; state = 'insufficient-sample';
    elseif abs(z) <= 3
        verdict = 'PASS'; state = 'sufficient-support';
    else
        verdict = 'FAIL'; state = 'sufficient-refutation';
    end
end
end

function c = field(name, op, ref, tol)
c = struct('name', name, 'op', op, 'ref', ref, 'tol', tol);
end

function u = wilson_hi(k, n, z)
if k == 0
    % closed form for k = 0: (z^2/2 + z^2/2) / (n + z^2)
    u = z^2/(n + z^2);
    return;
end
ph = k/n; d = 1 + z^2/n;
u = (ph + z^2/(2*n) + z*sqrt(ph*(1 - ph)/n + z^2/(4*n^2)))/d;
end

function l = wilson_lo(k, n, z)
if k == 0, l = 0; return; end
ph = k/n; d = 1 + z^2/n;
l = (ph + z^2/(2*n) - z*sqrt(ph*(1 - ph)/n + z^2/(4*n^2)))/d;
end

function T = load_tasks(tasksFile)
TF = jsondecode(fileread(tasksFile));
T = TF.tasks; if isstruct(T), T = num2cell(T(:)); end
end
