function res = p57_sync_redisovery()
%P57_SYNC_REDISCOVERY  Install the real skills into an isolated root, then let
%the install audit discover them again.
%
%   res = p57_sync_redisovery()
%
% This is the "re-discovery" leg of the Phase 5.7 install audit: the sync script
% writes a copy, and the audit tool must subsequently see that copy as CURRENT
% for a client that reads the same root. Both steps run against a temp root; the
% real user roots are never touched.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
outDir = fullfile(repo, 'artifacts', 'phase57', 'install');
if ~isfolder(outDir), mkdir(outDir); end

root = fullfile(tempdir, sprintf('mas_p57_redisovery_%s', datestr(now, 'yyyymmddHHMMSSFFF')));
skillsRoot = fullfile(root, 'skills');
backupRoot = fullfile(root, 'backups');
rootsFile = fullfile(root, 'roots.json');
cleaner = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>

syncScript = fullfile(repo, 'scripts', 'Sync-Skills.ps1');
cmd = sprintf(['powershell -NoProfile -ExecutionPolicy Bypass -File "%s" ' ...
    '-RepositoryRoot "%s" -SkillRoot "%s" -BackupRoot "%s"'], ...
    syncScript, repo, skillsRoot, backupRoot);
[st, out] = system(cmd);
jsonStart = strfind(out, '{');
sync = struct('ok', false, 'exitCode', st);
if st == 0 && ~isempty(jsonStart)
    try
        sync = jsondecode(out(jsonStart(1):end));
        sync.ok = true;
        sync.exitCode = st;
    catch ME
        sync.parseError = ME.message;
    end
else
    sync.rawTail = out(max(1, end-800):end);
end

% One observed client whose only root is the freshly synced temp root. The
% resolution level is "observed" only because this run itself exercises the
% same precedence order the real Qoder client uses (single root here).
R = struct();
R.schema = 'mas-skill-install-roots/1';
R.roots = struct('id', 'tmp-observed', 'client', 'phase57-fixture', 'scope', 'user', ...
    'path', skillsRoot, 'priority', 10, 'evidence', 'p57_sync_redisovery.m');
R.clients = struct('id', 'phase57-fixture', 'display', 'freshly synced root', ...
    'roots', {{'tmp-observed'}}, 'resolutionLevel', 'observed-precedence', ...
    'observed', true, 'evidence', 'sync + audit in one process');
fid = fopen(rootsFile, 'w'); fwrite(fid, jsonencode(R), 'char'); fclose(fid);

addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));
audit = mas_skill_install_audit('repoRoot', repo, 'rootsFile', rootsFile, ...
    'outFile', fullfile(outDir, 'redisovery_audit.json'));

client = audit.clients(strcmp({audit.clients.id}, 'phase57-fixture'));
names = arrayfun(@(s) string(s.skill), client.skills);
status = arrayfun(@(s) string(s.status), client.skills);
missing = names(status ~= "CURRENT");

res = struct();
res.schema = 'mas-phase57-sync-redisovery/1';
res.generatedAt = datestr(now, 31);
res.sync = struct('ok', sync.ok, 'exitCode', st, ...
    'installed', getfield_default(sync, 'installed', -1), ...
    'updated', getfield_default(sync, 'updated', -1), ...
    'unchanged', getfield_default(sync, 'unchanged', -1));
res.audit = struct('verdict', audit.summary.verdict, ...
    'nSkills', audit.summary.nSkills, 'nCurrent', nnz(status == "CURRENT"), ...
    'missing', missing);
res.pass = sync.ok && audit.summary.verdict == "CONSISTENT" && isempty(missing) ...
    && res.sync.installed == 9;
fid = fopen(fullfile(outDir, 'sync_redisovery.json'), 'w');
fwrite(fid, jsonencode(res, 'PrettyPrint', true), 'char'); fclose(fid);

fprintf('sync: ok=%d installed=%d updated=%d unchanged=%d exit=%d\n', ...
    sync.ok, res.sync.installed, res.sync.updated, res.sync.unchanged, st);
fprintf('audit: verdict=%s nSkills=%d nCurrent=%d missing=%s\n', ...
    audit.summary.verdict, audit.summary.nSkills, res.audit.nCurrent, ...
    strjoin(cellstr(missing), ','));
fprintf('pass=%d -> %s\n', res.pass, fullfile(outDir, 'sync_redisovery.json'));
end

function v = getfield_default(s, name, dflt)
if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = dflt; end
end
