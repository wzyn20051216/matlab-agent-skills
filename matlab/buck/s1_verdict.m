function [pass, verdict] = s1_verdict(converged, maxAbs)
%S1_VERDICT  The ONE definition of S1 at the switching level. Single source of truth.
%
%   [pass, verdict] = s1_verdict(converged, maxAbs)
%
% Phase 3A.5 graded S1 as "the run converged and the steady-state error is small".
% That is not a stability statement: a slowly growing oscillation can stay inside
% a 60 ms window, and a LIMIT CYCLE can look perfectly "converged" in the sense of
% having a bounded, repeatable waveform. The replacement rule is:
%
%   S1 PASS  <=>  a period-1 orbit was found  AND  max|eig(DP(x*))| < 1
%
% Note the conjunction. Either half alone is wrong:
%   * max|lambda| = 0.5 measured at a point that is NOT an orbit proves nothing
%     (that is exactly what the nDly = 2 case produces);
%   * a converged orbit with max|lambda| >= 1 is a repelling orbit.
%
% This function exists so that the acceptance script and the regression test
% cannot implement the rule differently -- and so that the 3A.5 mistake
% (finite-time convergence treated as stability) cannot come back silently.

if ~converged
    pass = false;
    verdict = 'UNDETERMINED (no period-1 orbit)';
elseif maxAbs < 1
    pass = true;
    verdict = 'PASS';
else
    pass = false;
    verdict = 'FAIL (repelling orbit)';
end
end
