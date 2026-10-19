function out = cd_d1_linalg()
%CD_D1_LINALG  Scientific computing: linear system + numerical integration.
%
% INDEPENDENT REFERENCE
%   The system is CONSTRUCTED from an integer solution x = [1;-2;3], so the exact
%   answer is known before any solver runs. The integral is 4/(1+x^2) on [0,1],
%   whose exact value is pi (atan(1)-atan(0) = pi/4, times 4).
% Neither reference is produced by the code under test.

A = [4 -2 1; -2 4 -2; 1 -2 3];
xTrue = [1; -2; 3];
b = A*xTrue;                       % b = [11;-16;14] by construction

x = A\b;
resid = norm(A*x - b)/norm(b);
errX  = max(abs(x - xTrue));

f = @(t) 4./(1+t.^2);
Iquad = integral(f, 0, 1);         % adaptive quadrature
tt = linspace(0,1,20001);
Itrap = trapz(tt, f(tt));          % independent trapezoid

refI = pi;
ok = (errX < 1e-10) && (abs(Iquad-refI) < 1e-8) && (abs(Itrap-refI) < 1e-4) && (resid < 1e-12);

out.values = struct('x',x.','residual',resid,'errX',errX, ...
    'I_quad',Iquad,'I_trapz',Itrap);
out.reference = struct('x',xTrue.','I',refI);
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('max|x-x*|=%.2e, |I-pi|=%.2e (quad) / %.2e (trapz)', ...
    errX, abs(Iquad-refI), abs(Itrap-refI));
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
