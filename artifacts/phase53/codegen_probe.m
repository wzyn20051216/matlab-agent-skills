d = tempname; mkdir(d);
fid = fopen(fullfile(d, 'cg_probe.m'), 'w');
fwrite(fid, sprintf('function y=cg_probe(x)\ny=0.5*sum(x.^2);\nend\n'), 'char');
fclose(fid);
addpath(d);
try
    codegen('-config', coder.config('mex'), 'cg_probe', '-args', {1:10}, '-d', fullfile(d, 'b'));
    v = 'OK';
catch ME
    v = sprintf('ERR [%s] id=%s', ME.message, ME.identifier);
end
fid = fopen('E:\desktop\MATLAB\artifacts\phase53\codegen_probe.txt', 'w');
fwrite(fid, v, 'char'); fclose(fid);
disp(v);
