function R = p56_session_reset(neutralDir, logFile)
%P56_SESSION_RESET  Put the shared MATLAB session back into a known blind state.
%
%   R = p56_session_reset(repositoryRoot, logFile)
%
% Phase 5.6 measures three arms that are supposed to differ only in what they can
% see. The file system is not the only channel: every episode runs
% evaluate_matlab_code in the SAME MATLAB session. An episode that does
% addpath('<its arm>/matlab-*/scripts') hands the next arm -- including an arm
% that is supposed to be blind -- a working tool, and the tool ledger cannot see
% it because no file was opened.
%
% Measured on this host after the three probe episodes: 4 benchmark/skill path
% entries still present, mas_ber_check resolvable from the repo skill directory,
% 82 leftover variables in the MCP frame, and pwd left inside an arm directory
% (which also locked that directory against deletion on Windows).
%
% This resets the session-visible part and proves it:
%
%   1. cd out of any arm directory (releases the Windows lock);
%   2. rmpath every path entry under a benchmark or repo-skill root;
%   3. verify: pwd neutral, no mas_* resolves, no benchmark path entry remains.
%
% Variables are NOT cleared here. The MCP evaluate context is not the base
% workspace: evalin('base','{(whos()).name}') returns empty while the same frame
% holds 82 variables, so a function cannot reach them. The caller wipes the frame
% with a bare `clear` as its own first statement; this function records only what
% it can actually verify.
%
% Nothing persistent is touched: no savepath, no restoredefaultpath, no write to
% pathdef.m. Only entries a benchmark session added at run time are removed, and
% they are returned and appended to logFile for the audit trail.

if nargin < 1, neutralDir = fileparts(fileparts(fileparts(mfilename('fullpath')))); end
repo = neutralDir;
% Harness directories (matlab/validation/...) are deliberately NOT removed: this
% function has to stay callable from them, and they hold no mas_* tool and no
% SKILL.md, so they are not an arm-blindness channel. skills/, benchmark/ and the
% staging root are.
roots = {fullfile(repo, 'skills'), fullfile(repo, 'benchmark'), ...
         fullfile(fileparts(repo), 'MATLAB-bench-phase56')};

B = struct();
B.pwd = pwd;
B.nBaseVars = numel(baseVarNames());
B.nPathEntries = numel(strsplit(path, pathsep));
B.masResolvable = masResolvable();

try %#ok<TRYNC>
    cd(neutralDir);
end
% pwd returns backslashed paths, so a caller who passed forward slashes would fail
% a plain strcmpi and the function would fall back to USERPROFILE.
if ~dirEq(pwd, neutralDir), cd(getenv('USERPROFILE')); end
removed = rmpathOf(roots);

A = struct();
A.pwd = pwd;
A.nBaseVars = numel(baseVarNames());
A.masResolvable = masResolvable();
A.pathHasBenchmarkEntries = any(anyContains(strsplit(path, pathsep), roots));

R = struct();
R.schema = 'mas-phase56-session-reset/1';
R.at = datestr(now, 31);
R.before = B;
R.removedPaths = removed;
R.after = A;
R.ok = dirEq(A.pwd, neutralDir) && isempty(A.masResolvable) && ~A.pathHasBenchmarkEntries;
R.meaning = ['the shared MATLAB session no longer carries a path entry or a symbol ' ...
    'that an earlier episode could have left for a blind arm'];
R.limitation = ['this resets STATE, not capability: an episode can still open an ' ...
    'absolute path from MATLAB, and the MCP frame keeps variables unless the caller ' ...
    'clears it. It is what makes the tool ledger interpretable. Strong isolation on ' ...
    'this host is BLOCKED (docs/PHASE5_6_ISOLATION_ZH.md).'];

if nargin > 1 && ~isempty(logFile)
    fid = fopen(logFile, 'a');
    if fid >= 0
        fwrite(fid, [strtrim(jsonencode(R)) newline], 'char');
        fclose(fid);
    end
end
end

% ===========================================================================
function tf = dirEq(a, b)
tf = strcmpi(strrep(char(a), '\', '/'), strrep(char(b), '\', '/'));
end

% ===========================================================================
function n = baseVarNames()
% {whos.name} is command syntax and is rejected in an expression context, so the
% parenthesised form is required.
try %#ok<TRYNC>
    n = evalin('base', '{(whos()).name}');
    if ~iscell(n), n = {}; end
catch
    n = {};
end
end

% ===========================================================================
function s = masResolvable()
names = {'mas_ber_check', 'mas_stat_verdict', 'mas_ode_check', 'mas_ctrl_analyze', 'mas_grade'};
hit = {};
for k = 1:numel(names)
    w = which(names{k});
    if ~isempty(w), hit{end+1} = [names{k} ' -> ' w]; end %#ok<AGROW>
end
s = strjoin(hit, '; ');
end

% ===========================================================================
function removed = rmpathOf(roots)
removed = {};
seps = strsplit(path, pathsep);
for k = 1:numel(seps)
    e = strtrim(seps{k});
    if isempty(e), continue; end
    if anyContains({e}, roots)
        rmpath(e);
        removed{end+1} = e; %#ok<AGROW>
    end
end
end

% ===========================================================================
function tf = anyContains(entries, roots)
tf = false(1, numel(entries));
for k = 1:numel(entries)
    e = strrep(lower(char(entries{k})), '\', '/');
    for q = 1:numel(roots)
        r = strrep(lower(char(roots{q})), '\', '/');
        if ~isempty(r) && ~isempty(strfind(e, [r '/']))
            tf(k) = true; break;
        end
    end
end
end
