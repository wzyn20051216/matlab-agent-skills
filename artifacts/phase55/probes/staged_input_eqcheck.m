% Phase 5.5: verify v3 staged inputs are data-identical to the v2 pilot batch.
dirs={'R1\H-SIG-F','R2\H-SIG-F','R3\H-SIG-B','R3\H-SIG-F','R3\H-DATA-B','R3\H-DATA-F','R3\H-ROB-B','R3\H-ROB-F','R3\H54-ODE-N','R3\H54-ODE-B','R3\H54-ODE-F','R3\H54-VIS-N','R3\H54-VIS-B','R3\H54-VIS-F'};
fprintf('== prompt hashes ==\n');
m2=jsondecode(fileread('E:\desktop\MATLAB-bench-phase55-v2\stage_manifest.json'));
m3=jsondecode(fileread('E:\desktop\MATLAB-bench-phase55-v3\stage_manifest.json'));
for i=1:numel(m3.entries)
  e3=m3.entries(i); e2=m2.entries(i);
  samePrompt=strcmp(e3.promptSha256,e2.promptSha256);
  sameInput=strcmp(e3.inputSha256,e2.inputSha256);
  fprintf('%-4s %-12s promptSame=%d inputFileSame=%d nFiles=%d/%d\n', e3.arm, e3.task, samePrompt, sameInput, e2.nFiles, e3.nFiles);
end
fprintf('\n== variable-level comparison ==\n');
for i=1:numel(dirs)
  d=dirs{i};
  f2=['E:\desktop\MATLAB-bench-phase55-v2\' d '\input.mat'];
  f3=['E:\desktop\MATLAB-bench-phase55-v3\' d '\input.mat'];
  fid=fopen(f2,'r'); h2=strtrim(fread(fid,116,'uint8=>char')'); fclose(fid);
  s2=load(f2); s3=load(f3);
  ks=sort(fieldnames(s2));
  exact=true; texteq=true; det='';
  for k=1:numel(ks)
    nm=ks{k}; a=s2.(nm); b=s3.(nm);
    if isequaln(a,b), continue; end
    exact=false;
    ta=evalc('disp(a)'); tb=evalc('disp(b)');
    if ~strcmp(ta,tb), texteq=false; det=[det nm ':REALDIFF ']; end
  end
  if exact, tag='IDENTICAL'; elseif texteq, tag='IDENTICAL_MOD_FH_SERIALIZATION'; else, tag=['DIFF ' det]; end
  fprintf('%-16s vars=%d %s | v2 header: %s\n', d, numel(ks), tag, h2);
end
