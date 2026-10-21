function y = codegen_target(x)
%CODEGEN_TARGET  Codegen-friendly reference: scaled sum of squares.
%   y = 0.5 * sum(x.^2), so y(1:10) = 0.5*385 = 192.5 exactly.
y = 0.5 * sum(x.^2);
end
