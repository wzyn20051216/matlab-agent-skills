function hits = benchmark_scan_for_answers(dirName, ids, mode, skipNames)
%BENCHMARK_SCAN_FOR_ANSWERS  Look for hidden-expectation data inside a directory.
%
%   hits = benchmark_scan_for_answers(dirName, ids)          % 'bundle' mode
%   hits = benchmark_scan_for_answers(dirName, ids, 'workspace', skipNames)
%
% Returns a Nx2 cell array of {relativePath, reason} for every file that carries
% an expectation for one of `ids`, or is named like an answer file.
%
% Two modes, because the same words mean different things in different places:
%
%   'bundle'    the published task bundle an arm may read. Strict: a file named
%               answer/solution/grade/expected/manifest is refused outright,
%               because a bundle has no legitimate reason to hold either. This is
%               what benchmark_publish.m enforces before it publishes.
%   'workspace' an arm workspace holding the real skill tree. There, `mas_grade.m`
%               is a grader tool and not an answer key, and `stage_manifest.json`
%               legitimately lists the stripped field name "verdict"; refusing
%               those would be noise. So the filename rule narrows to
%               answer/expected/solution and the content rule carries the weight.
%
% The content rule is SHAPE, not vocabulary. The word "verdict" appears in every
% honest report; an EXPECTATION binds a verdict key to a verdict value:
%
%   "verdict":"PASS"    "ref":0.5    "expectedVerdict":"FAIL"    "answersSha256":"..."
%
% Such a file only counts if it also names one of `ids` (or carries the sealed
% answers hash). Be exact about what this can prove: it detects a COPY of the
% answer key. A value re-typed by hand into an innocently named file is not
% detectable by any scanner. The real control is absence by design -- the answers
% do not exist while an episode runs; this scan verifies that absence.
%
% Scope note: the detectors' own comments quote the shapes they look for, so do
% not point this at benchmark/ -- point it at what an episode is handed (the
% bundle, an arm workspace). `skipNames` exists for exactly one legitimate
% expectation-shaped file inside an arm workspace: the episode's OWN result.json,
% which writes "verdict":"PASS" by instruction. Anything else in that directory
% with the same shape is a leak.

if nargin < 3, mode = 'bundle'; end
if nargin < 4
    skipNames = {};
elseif iscell(skipNames)
    skipNames = skipNames(:);
else
    skipNames = cellstr(skipNames);
end
if nargin < 1 || ~isfolder(dirName)
    error('benchmark_scan_for_answers:dir', 'no such directory: %s', dirName);
end
ids = cellstr(ids);

nameWords = {'answer', 'expected', 'solution'};
if strcmp(mode, 'bundle')
    nameWords = [nameWords, {'grade', 'manifest'}];
end

hits = {};
d = dir(fullfile(dirName, '**', '*'));
for k = 1:numel(d)
    if d(k).isdir, continue; end
    if any(strcmpi(skipNames, d(k).name)), continue; end
    rel = relative_to(d(k), dirName);
    rl = lower(rel);
    for q = 1:numel(nameWords)
        if contains(rl, nameWords{q})
            hits(end+1, :) = {rel, ['named like an answer file: *' nameWords{q} '*']};
        end
    end
    if ~any(strcmpi(ext_of(rl), {'.json', '.m', '.mat', '.txt', '.md'}))
        continue;
    end
    try
        txt = fileread(fullfile(d(k).folder, d(k).name));
    catch
        continue;
    end
    [shape, why] = benchmark_expectation_shape(txt);
    if ~shape, continue; end
    if strcmp(why, 'sealed answers hash') || ...
            any(cellfun(@(s) contains(txt, s), ids))
        hits(end+1, :) = {rel, why};
    end
end
end

% ===========================================================================
function e = ext_of(rl)
[~, ~, e] = fileparts(rl);
if isempty(e), e = ''; end
end

function r = relative_to(d, rootDir)
% dir('<root>/**') reports .name WITHOUT the subpath, so rebuild the path from
% .folder and canonicalise both sides; without this, nine skills collapse into
% nine identical "SKILL.md" entries and the report cannot say WHICH one hit.
absf = strtrim(char(java.io.File(fullfile(d.folder, d.name)).getCanonicalPath()));
root = strtrim(char(java.io.File(rootDir).getCanonicalPath()));
absf = strrep(absf, '\', '/');
root = strrep(root, '\', '/');
if startsWith(absf, [root '/'])
    r = absf(numel(root) + 2:end);
else
    r = d.name;
end
end
