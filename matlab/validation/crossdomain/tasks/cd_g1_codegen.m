function out = cd_g1_codegen()
%CD_G1_CODEGEN  Codegen (held-out): generated C must reproduce MATLAB exactly.
%
% Exercises mas_codegen_verify on a function whose closed-form result is known:
%   y = 0.5 * sum(k^2 for k=1..10) = 0.5 * 385 = 192.5
% The task reports the MATLAB value y and the trip count n; the frozen reference
% grades them exactly. When no compiler is configured mas_codegen_verify returns
% SKIP, and this task propagates that honestly rather than faking a pass.

% A local helper that codegen can compile, written so its answer is exact.
helper = @codegen_target;

r = mas_codegen_verify('codegen_target', {1:10});
y = feval(helper, 1:10);

out.values = struct('y', y, 'n', 10);
out.reference = struct('y', 192.5, 'n', 10);
if strcmp(r.verdict, 'SKIP')
    out.status = 'SKIP';
else
    out.status = tern(strcmp(r.verdict, 'PASS'), 'PASS', 'FAIL');
end
out.detail = sprintf('y=%.6g (codegen %s)', y, r.verdict);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
