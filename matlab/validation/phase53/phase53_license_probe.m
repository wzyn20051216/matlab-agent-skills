function res = phase53_license_probe()
%PHASE53_LICENSE_PROBE  Per-domain toolbox licence status for Phase 5.3.
%
%   res = phase53_license_probe()
%
% Uses mas_dep_probe so that "not installed" and "installed but not licensed"
% stay distinct states. A domain is marked AVAILABLE only when every
% representative function resolves and runs; otherwise the domain is
% PARTIAL or SKIP, and no test in that domain may claim PASS.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
for d = {'matlab-orchestrator', 'matlab-runner', 'matlab-testing-ci', ...
        'matlab-simulink-modeling', 'matlab-control-optimization', ...
        'matlab-data-analysis', 'matlab-signal-vision-ai', 'matlab-robotics-autonomy'}
    p = fullfile(repo, 'skills', d{1}, 'scripts');
    if isfolder(p), addpath(p); end
end

D = struct();
D(1).domain = 'signal';
D(1).functions = {'butter', 'freqz', 'pwelch', 'upfirdn', 'comm.QPSKModulator', ...
    'comm.OFDMModulator', 'mas_ofdm_ber'};
D(2).domain = 'data';
D(2).functions = {'integral', 'ode45', 'fitlm', 'tinv', 'kstest', ...
    'randsample', 'cond', 'svd'};
D(3).domain = 'robotics';
% `ikunc` was removed from recent Robotics System Toolbox releases; probing for it
% says nothing about the licence. `generalizedInverseKinematics` is the current
% inverse-kinematics entry point. mas_fk/mas_ik do not exist in this repo; the
% shipped tools are mas_kin_check and mas_kin_ik, and those are probed.
D(3).functions = {'rigidBodyTree', 'inverseKinematics', 'generalizedInverseKinematics', ...
    'rotm2quat', 'quat2rotm', 'trvec2tform', 'mas_kin_check', 'mas_kin_ik'};
D(4).domain = 'control';
D(4).functions = {'tf', 'margin', 'allmargin', 'mas_stability_verdict'};
D(5).domain = 'simulink';
D(5).functions = {'sim', 'new_system', 'mas_dist_enter', 'mas_model_check'};

R = struct('domain', {}, 'function', {}, 'state', {}, 'level', {}, 'pass', {});
for d = 1:numel(D)
    for f = 1:numel(D(d).functions)
        name = D(d).functions{f};
        if ~isempty(which(name)) || endsWith(name, '.QPSKModulator') || endsWith(name, '.OFDMModulator')
            try
                r = mas_dep_probe('function', name, struct('deep', true));
                st = r.state; lv = r.level; ok = r.pass;
            catch ME
                st = ['PROBE_ERROR: ' ME.identifier]; lv = 0; ok = false;
            end
        else
            st = 'FN_NOT_FOUND'; lv = 0; ok = false;
        end
        R(end+1) = struct('domain', D(d).domain, 'function', name, ...
            'state', st, 'level', lv, 'pass', ok); %#ok<AGROW>
    end
end

dom = unique({R.domain}, 'stable');
S = struct('domain', {}, 'available', {}, 'total', {}, 'missing', {});
for d = 1:numel(dom)
    ix = strcmp({R.domain}, dom{d});
    missing = {R(ix & ~[R.pass]).function};
    S(end+1) = struct('domain', dom{d}, 'available', nnz([R(ix).pass]), ...
        'total', nnz(ix), 'missing', {missing}); %#ok<AGROW>
end

res = struct('level', 'phase53-licence-probe', 'byFunction', R, 'byDomain', S, ...
    'matlabVersion', version, 'timestamp', datestr(now, 31));

ev = fullfile(repo, 'artifacts', 'phase53', 'evidence');
if ~isfolder(ev), mkdir(ev); end
fid = fopen(fullfile(ev, 'task0_license_probe.json'), 'w');
fwrite(fid, jsonencode(res), 'char');
fclose(fid);

fprintf('=== licence probe (%s) ===\n', version);
for d = 1:numel(S)
    fprintf('%-9s %d/%d available', S(d).domain, S(d).available, S(d).total);
    if ~isempty(S(d).missing)
        fprintf('  missing: %s', strjoin(S(d).missing, ', '));
    end
    fprintf('\n');
end
for k = 1:numel(R)
    fprintf('  %-9s %-20s %-20s level %d\n', R(k).domain, R(k).function, R(k).state, R(k).level);
end
end