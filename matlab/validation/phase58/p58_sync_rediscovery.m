function res = p58_sync_rediscovery()
%P58_SYNC_REDISCOVERY  Sync into a temp root, then re-discover it twice.
%
%   res = p58_sync_rediscovery()
%
% The first sync installs all nine Skills into a temporary root. The second
% sync must be a no-op. The install audit must then resolve every Skill in that
% root as CURRENT. No real user-level Skills directory is read or written.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(fileparts(here)));
outDir = fullfile(repo, 'artifacts', 'phase58', 'install');
if ~isfolder(outDir), mkdir(outDir); end

root = fullfile(tempdir, sprintf('mas_p58_rediscovery_%s', datestr(now, 'yyyymmddHHMMSSFFF')));
skillsRoot = fullfile(root, 'skills');
backupRoot = fullfile(root, 'backups');
rootsFile = fullfile(root, 'roots.json');
cleaner = onCleanup(@() rmdir(root, 's')); %#ok<NASGU>

syncScript = fullfile(repo, 'scripts', 'Sync-Skills.ps1');
runSync = @(extra) sync_once(syncScript, repo, skillsRoot, backupRoot, extra);

first = runSync('');
second = runSync('');

R = struct();
R.schema = 'mas-skill-install-roots/1';
R.roots = struct('id', 'tmp-observed', 'client', 'phase58-fixture', 'scope', 'user', ...
    'path', skillsRoot, 'priority', 10, 'evidence', 'p58_sync_rediscovery.m');
R.clients = struct('id', 'phase58-fixture', 'display', 'freshly synced root', ...
    'roots', {{'tmp-observed'}}, 'resolutionLevel', 'observed-single-root', ...
    'observed', true, 'evidence', 'sync + audit in one process');
fid = fopen(rootsFile, 'w'); fwrite(fid, jsonencode(R), 'char'); fclose(fid);

addpath(fullfile(repo, 'skills', 'matlab-testing-ci', 'scripts'));
audit = mas_skill_install_audit('repoRoot', repo, 'rootsFile', rootsFile, ...
    'outFile', fullfile(outDir, 'sync_rediscovery_audit.json'));

client = audit.clients(strcmp({audit.clients.id}, 'phase58-fixture'));
names = arrayfun(@(s) string(s.skill), client.skills);
status = arrayfun(@(s) string(s.status), client.skills);
missing = names(status ~= "CURRENT");

res = struct();
res.schema = 'mas-phase58-sync-rediscovery/1';
res.generatedAt = datestr(now, 31);
res.readOnlyRealRoots = true;
res.syncRoot = skillsRoot;
res.firstSync = struct('ok', first.ok, 'exitCode', first.exitCode, ...
    'installed', first.installed, 'updated', first.updated, 'unchanged', first.unchanged);
res.secondSync = struct('ok', second.ok, 'exitCode', second.exitCode, ...
    'installed', second.installed, 'updated', second.updated, 'unchanged', second.unchanged);
res.audit = struct('verdict', audit.summary.verdict, ...
    'nSkills', audit.summary.nSkills, 'nCurrent', nnz(status == "CURRENT"), ...
    'missing', missing);
res.pass = first.ok && second.ok && first.installed == 9 ...
    && second.installed == 0 && second.updated == 0 && second.unchanged == 9 ...
    && audit.summary.verdict == "CONSISTENT" && isempty(missing);
fid = fopen(fullfile(outDir, 'sync_rediscovery.json'), 'w');
fwrite(fid, jsonencode(res, 'PrettyPrint', true), 'char'); fclose(fid);

fprintf('first:  ok=%d installed=%d updated=%d unchanged=%d exit=%d\n', ...
    first.ok, first.installed, first.updated, first.unchanged, first.exitCode);
fprintf('second: ok=%d installed=%d updated=%d unchanged=%d exit=%d\n', ...
    second.ok, second.installed, second.updated, second.unchanged, second.exitCode);
fprintf('audit:  verdict=%s nSkills=%d nCurrent=%d missing=%s\n', ...
    audit.summary.verdict, audit.summary.nSkills, nnz(status == "CURRENT"), ...
    strjoin(cellstr(missing), ','));
fprintf('pass=%d -> %s\n', res.pass, fullfile(outDir, 'sync_rediscovery.json'));
end

function s = sync_once(script, repo, skillsRoot, backupRoot, extra)
cmd = sprintf(['powershell -NoProfile -ExecutionPolicy Bypass -File "%s" ' ...
    '-RepositoryRoot "%s" -SkillRoot "%s" -BackupRoot "%s" %s'], ...
    script, repo, skillsRoot, backupRoot, extra);
[st, out] = system(cmd);
jsonStart = strfind(out, '{');
s = struct('ok', false, 'exitCode', st, 'installed', -1, 'updated', -1, 'unchanged', -1);
if st == 0 && ~isempty(jsonStart)
    try
        d = jsondecode(out(jsonStart(1):end));
        s.ok = true;
        s.installed = getfield_default(d, 'installed', -1);
        s.updated = getfield_default(d, 'updated', -1);
        s.unchanged = getfield_default(d, 'unchanged', -1);
    catch ME
        s.parseError = ME.message;
    end
else
    s.rawTail = out(max(1, end-800):end);
end
end

function v = getfield_default(s, name, dflt)
if isfield(s, name) && ~isempty(s.(name)), v = s.(name); else, v = dflt; end
end
