function out = cd_c2_unstable()
%CD_C2_UNSTABLE  Control: an open-loop UNSTABLE plant.
%
% REFERENCE (id C2)
%   G(s) = 1/(s^2+s-2) = 1/((s+2)(s-1)): one pole at +1, one at -2.
%   Routh on s^2+s-2 gives one sign change in the first column, so one RHP root.
%   The point of this case is that a controller analysis must SAY "unstable"; a
%   tool that only reports margins would happily print a number here too.
%
% The verifier grades nRhpPoles, maxRealPole and loopStable.

cd_setup();

G = tf(1, [1 1 -2]);
r = mas_ctrl_analyze(G);
p = pole(G);

out.values = struct('nRhpPoles', r.rhpPoles, 'maxRealPole', max(real(p)), ...
    'loopStable', double(strcmp(r.verdict, 'STABLE')), ...
    'polesReal', real(p).', 'polesImag', imag(p).');
out.reference = struct('note', 'Routh: one sign change => one RHP pole at +1');
out.status = tern(r.rhpPoles == 1 && ~strcmp(r.verdict, 'STABLE'), 'PASS', 'FAIL');
out.detail = sprintf('%d RHP pole(s), max real part %.4f, verdict %s', ...
    r.rhpPoles, max(real(p)), r.verdict);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
