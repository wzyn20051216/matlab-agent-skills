function res = test_skill_install_audit(verbose)
%TEST_SKILL_INSTALL_AUDIT  Fixture tests for the read-only install audit:
%precedence, fallback, assumed roots, unresolved conflicts, drift details,
%dependency gaps, and the no-write guarantee.
%
%   res = test_skill_install_audit()

if nargin < 1, verbose = true; end
here = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(here), 'scripts'));

base = fullfile(tempdir, sprintf('mas_install_audit_%s', datestr(now, 'yyyymmddHHMMSSFFF')));
repo = fullfile(base, 'repo');
r1 = fullfile(base, 'root1');
r2 = fullfile(base, 'root2');
r3 = fullfile(base, 'root3');
outFile = fullfile(base, 'audit.json');
cfgFile = fullfile(base, 'roots.json');
cleaner = onCleanup(@() cleanup_dir(base)); %#ok<NASGU>

% Repository: alpha references one of its own tools; beta references alpha's
% tool, which proves the dependency scan is repository-wide rather than local.
w(fullfile(repo, 'skills', 'alpha', 'SKILL.md'), ...
    ['---' newline 'name: alpha' newline '---' newline 'Run mas_alpha_check.' newline]);
w(fullfile(repo, 'skills', 'alpha', 'scripts', 'mas_alpha_check.m'), 'function mas_alpha_check()' + newline);
w(fullfile(repo, 'skills', 'alpha', 'references', 'contract.md'), 'alpha contract' + newline);
w(fullfile(repo, 'skills', 'beta', 'SKILL.md'), ...
    ['---' newline 'name: beta' newline '---' newline 'Run mas_alpha_check.' newline]);
w(fullfile(repo, 'skills', 'beta', 'scripts', 'mas_beta_check.m'), 'function mas_beta_check()' + newline);

% root1: alpha current, beta absent.
w(fullfile(r1, 'alpha', 'SKILL.md'), fileread(fullfile(repo, 'skills', 'alpha', 'SKILL.md')));
w(fullfile(r1, 'alpha', 'scripts', 'mas_alpha_check.m'), 'function mas_alpha_check()' + newline);
w(fullfile(r1, 'alpha', 'references', 'contract.md'), 'alpha contract' + newline);
% root2: alpha stale (calls a missing tool, misses a reference, keeps a local
% custom file), beta current.
w(fullfile(r2, 'alpha', 'SKILL.md'), ...
    ['---' newline 'name: alpha' newline '---' newline 'Run mas_missing_tool.' newline]);
w(fullfile(r2, 'alpha', 'scripts', 'mas_alpha_check.m'), 'function mas_alpha_check() % old' + newline);
w(fullfile(r2, 'alpha', 'custom.md'), 'user customisation' + newline);
w(fullfile(r2, 'beta', 'SKILL.md'), fileread(fullfile(repo, 'skills', 'beta', 'SKILL.md')));
w(fullfile(r2, 'beta', 'scripts', 'mas_beta_check.m'), 'function mas_beta_check()' + newline);

C = struct('id', {}, 'display', {}, 'roots', {}, 'resolutionLevel', {}, ...
    'observed', {}, 'evidence', {});
C(end+1) = struct('id', 'observed', 'display', 'observed precedence', ...
    'roots', {{'r1', 'r2'}}, 'resolutionLevel', 'observed-precedence', ...
    'observed', true, 'evidence', 'fixture log');
C(end+1) = struct('id', 'assumed', 'display', 'assumed single root', ...
    'roots', {{'r2'}}, 'resolutionLevel', 'known-root', ...
    'observed', false, 'evidence', 'fixture assumption');
C(end+1) = struct('id', 'unresolved', 'display', 'unobserved precedence', ...
    'roots', {{'r1', 'r2'}}, 'resolutionLevel', 'known-root', ...
    'observed', false, 'evidence', 'fixture unknown');
C(end+1) = struct('id', 'missing', 'display', 'empty root', ...
    'roots', {{'r3'}}, 'resolutionLevel', 'known-root', ...
    'observed', false, 'evidence', 'fixture empty');

cfg = struct('schema', 'mas-skill-install-roots/1', 'clients', C, 'roots', ...
    struct('id', {'r1', 'r2', 'r3'}, 'client', {'fixture', 'fixture', 'fixture'}, ...
    'scope', {'user', 'user', 'user'}, 'path', {r1, r2, r3}, ...
    'priority', {10, 20, 30}, 'evidence', {'fixture', 'fixture', 'fixture'}));
w(cfgFile, jsonencode(cfg));

sigBefore = tree_sig({r1, r2, r3});
r = mas_skill_install_audit('repoRoot', repo, 'rootsFile', cfgFile, 'outFile', outFile);
sigAfter = tree_sig({r1, r2, r3});

nP = 0; nT = 0;
if verbose, fprintf('=== install audit tests ===\n'); end
chk(r.schema, 'mas-skill-install-audit/1', 'schema');
chk(r.readOnly, true, 'read-only flag');
chk(numel(r.skills), 2, 'two repository skills');
chk(r.summary.nSkills, 2, 'summary skill count');
chk(r.summary.verdict, 'DRIFTED', 'overall verdict');

e = find_skill(r.clients(strcmp({r.clients.id}, 'observed')).skills, 'alpha');
chk(e.status, 'CURRENT', 'observed precedence picks the current root');
e = find_skill(r.clients(strcmp({r.clients.id}, 'observed')).skills, 'beta');
chk(e.status, 'CURRENT', 'observed client falls back to the second root');
e = find_skill(r.clients(strcmp({r.clients.id}, 'assumed')).skills, 'alpha');
chk(e.status, 'DRIFTED', 'assumed root reports drift');
chk(e.confidence, 'assumed', 'assumed root is labelled');
e = find_skill(r.clients(strcmp({r.clients.id}, 'unresolved')).skills, 'alpha');
chk(e.status, 'UNRESOLVED', 'unobserved duplicate roots are unresolved');
e = find_skill(r.clients(strcmp({r.clients.id}, 'missing')).skills, 'alpha');
chk(e.status, 'MISSING', 'absent skill is missing, not drifted');
chk(numel(r.recommendations) >= 3, true, 'recommendations emitted');
chk(all([r.recommendations.requiresApproval]), true, 'every suggestion needs approval');

k = find_conflict(r.conflicts, 'alpha');
chk(k.distinctHashes, 2, 'conflict counts distinct SKILL.md hashes');

rec = find_rec(r.recommendations, 'alpha', r2);
chk(rec.action, 'SYNC', 'drifted root gets a sync suggestion');
chk(any(strcmp(rec.add, 'references/contract.md')), true, 'missing reference listed');
chk(any(strcmp(rec.overwrite, 'SKILL.md')), true, 'stale SKILL.md listed');
chk(any(strcmp(rec.onlyInInstall, 'custom.md')), true, 'user custom file is not deleted');

a = r.skills(strcmp({r.skills.name}, 'alpha'));
if isempty(a), error('test_skill_install_audit:missing', 'no repository row for alpha'); end
a = a(1);
chk(isempty(a.missingReferencedToolsInRepo), true, 'repository references resolve');
r2rec = a.installs(strcmp({a.installs.rootId}, 'r2'));
chk(any(strcmp(r2rec.missingReferencedTools, 'mas_missing_tool')), true, ...
    'installed copy reports a missing referenced tool');

chk(strcmp(sigBefore, sigAfter), true, 'no install root was modified');
parsed = jsondecode(fileread(outFile));
chk(parsed.schema, 'mas-skill-install-audit/1', 'report file is machine-readable');
chk(isempty(dir(fullfile(r3, '*'))), true, 'empty root stayed empty');

% The real machine audit must also run and stay schema-valid. It is allowed to
% be DRIFTED; that is a finding, not a test failure.
real = mas_skill_install_audit();
chk(real.summary.nSkills, 9, 'real repository has nine skills');
chk(numel(real.clients) >= 3, true, 'real audit covers the observed clients');

res = struct('nPass', nP, 'nTotal', nT, 'pass', nP == nT, ...
    'realVerdict', real.summary.verdict);
if verbose
    fprintf('\n---- %d / %d install audit cases passed (real machine: %s) ----\n', ...
        nP, nT, real.summary.verdict);
end

    function chk(got, want, label)
        nT = nT + 1;
        if ischar(want), ok = ischar(got) && strcmp(got, want);
        elseif islogical(want) || isnumeric(want), ok = isequal(got, want);
        else, ok = isequal(got, want); end
        nP = nP + ok;
        if verbose
            fprintf('  [%s] %s\n', tern(ok, 'PASS', 'FAIL'), label);
        end
        if ~ok
            error('test_skill_install_audit:case', '%s (got %s, want %s)', ...
                label, tostr(got), tostr(want));
        end
    end
end

% ===========================================================================
function w(p, s)
d = fileparts(p);
if ~isfolder(d), mkdir(d); end
fid = fopen(p, 'w');
if fid < 0, error('test_skill_install_audit:write', 'cannot write %s', p); end
fwrite(fid, s, 'char'); fclose(fid);
end

function s = tree_sig(roots)
s = '';
for k = 1:numel(roots)
    if ~isfolder(roots{k}), continue; end
    d = dir(fullfile(roots{k}, '**', '*'));
    for q = 1:numel(d)
        if d(q).isdir, continue; end
        p = fullfile(d(q).folder, d(q).name);
        s = [s strrep(p, '\', '/') '=' fileread(p) newline]; %#ok<AGROW>
    end
end
end

function e = find_skill(skills, name)
e = skills(strcmp({skills.skill}, name));
if isempty(e), error('test_skill_install_audit:missing', 'no row for %s', name); end
e = e(1);
end

function k = find_conflict(conflicts, name)
k = conflicts(strcmp({conflicts.skill}, name));
if isempty(k), error('test_skill_install_audit:missing', 'no conflict for %s', name); end
k = k(1);
end

function rec = find_rec(recs, skill, root)
rec = recs(strcmp({recs.skill}, skill) & strcmp({recs.targetRoot}, root));
if isempty(rec), error('test_skill_install_audit:missing', 'no suggestion for %s', skill); end
rec = rec(1);
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end

function s = tostr(v)
if ischar(v), s = v; elseif islogical(v) && isscalar(v), s = mat2str(v);
elseif isnumeric(v) && isscalar(v), s = num2str(v); else, s = class(v); end
end

function cleanup_dir(p)
if isfolder(p), rmdir(p, 's'); end
end
