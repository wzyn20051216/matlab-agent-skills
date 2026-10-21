function out = cd_r1_ik()
%CD_R1_IK  Robotics (held-out): IK must invert FK, and FK(IK(pose)) must reproduce.
%
% Exercises mas_kin_ik and mas_kin_check. A 2-link arm with L=[1.0 0.7] is placed
% at q=[35 50] deg by forward kinematics, then IK must recover those angles; the
% forward kinematics of the recovered angles must reproduce the pose. The frozen
% reference grades q1deg/q2deg/fkErr, not the task's own verdict.

L = [1.0 0.7];
qdeg = [35 50];
q = deg2rad(qdeg);
pose = mas_kin_check(L, q);
p = pose.pos;

r = mas_kin_ik(L, p, deg2rad([10 10]), struct('method', 'dls', 'tol', 1e-9));

q1 = rad2deg(r.q(1));
q2 = rad2deg(r.q(2));
fk = mas_kin_check(L, r.q);
fkErr = norm(fk.pos - p);

out.values = struct('q1deg', q1, 'q2deg', q2, 'fkErr', fkErr);
out.reference = struct('q1deg', 35, 'q2deg', 50, 'fkErr', 0);
out.status = tern(r.converged && fkErr < 1e-6, 'PASS', 'FAIL');
out.detail = sprintf('IK -> (%.2f, %.2f) deg, fkErr %.2e', q1, q2, fkErr);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
