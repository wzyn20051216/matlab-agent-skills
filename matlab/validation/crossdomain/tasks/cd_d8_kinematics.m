function out = cd_d8_kinematics()
%CD_D8_KINEMATICS  Robotics: planar 2-link forward kinematics.
%
% INDEPENDENT REFERENCE (geometric, not the same formula)
%   L1 = 1, L2 = 0.8, q1 = 30 deg, q2 = 60 deg relative -> the second link is at
%   90 deg to the base, i.e. VERTICAL. By inspection of the geometry:
%       x = L1*cos(30) = sqrt(3)/2 = 0.8660254037844386
%       y = L1*sin(30) + L2  = 0.5 + 0.8 = 1.3
%   The code composes two homogeneous transforms (a different route to the same
%   point), so agreement is a real check and not a tautology.

L1 = 1; L2 = 0.8;
q1 = deg2rad(30); q2 = deg2rad(60);

A1 = [cos(q1) -sin(q1) L1*cos(q1); sin(q1) cos(q1) L1*sin(q1); 0 0 1];
A2 = [cos(q2) -sin(q2) L2*cos(q2); sin(q2) cos(q2) L2*sin(q2); 0 0 1];
T = A1*A2;
pos = T(1:2,3).';

refX = sqrt(3)/2;
refY = 0.5 + L2;

ok = abs(pos(1)-refX) < 1e-12 && abs(pos(2)-refY) < 1e-12 && ...
     abs(det(T(1:2,1:2)) - 1) < 1e-12;

out.values = struct('x',pos(1),'y',pos(2),'detR',det(T(1:2,1:2)));
out.reference = struct('x',refX,'y',refY);
out.status = tern(ok,'PASS','FAIL');
out.detail = sprintf('(%.12f, %.12f) vs (%.12f, %.12f)', pos(1), pos(2), refX, refY);
end

function s = tern(c,a,b)
if c, s = a; else, s = b; end
end
