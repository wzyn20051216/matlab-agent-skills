function r = mas_grade(checks)
%MAS_GRADE  Separate three questions that are usually conflated:
%             1. did it run?
%             2. is the number right?
%             3. does it meet the engineering requirement?
%
%   r = mas_grade(checks)
%
% WHY THIS SPLIT MATTERS
% Phase 3A/3B produced all three failure combinations, and each one was once
% reported as "PASS" by somebody:
%   * a run that finished with NaN (ran, not correct)
%   * a correct number for a design that cannot meet the spec (correct, not
%     acceptable -- e.g. 47.9 V steady state but 2.25 ms recovery)
%   * a skipped check counted as a pass (not even ran)
% A single boolean cannot express that, so it does not get to.
%
% CHECK FIELDS
%   id          string
%   executed    logical   -- was the check actually run?
%   kind        'numeric' | 'domain'
%   value       measured number        (numeric only)
%   reference   independent reference  (numeric only; must NOT be self-generated)
%   tol         absolute tolerance, OR struct('rel',x)  (numeric only)
%   limit       threshold             (domain only)
%   cmp         'le' | 'ge'            (domain only; default 'le')
%   reason      optional explanation for a skip/fail
%
% OUTPUT
%   r.ran      logical
%   r.correct  true | false | 'UNDETERMINED'   (no numeric check = undetermined,
%                                               NOT true: absence of evidence)
%   r.meets    true | false | 'UNDETERMINED'   (no domain check = undetermined)
%   r.overall  'FAIL' | 'RAN_ONLY' | 'CORRECT_NOT_ACCEPTED' | 'PASS' | 'UNDETERMINED'
%   r.failures cellstr of ids that failed, with the measured value

if ~isstruct(checks) || isempty(checks)
    error('mas_grade:input','checks must be a non-empty struct array');
end

nNum = 0; nDom = 0;
ran = true;
numOK = true; domOK = true;
failures = {};

for k = 1:numel(checks)
    c = checks(k);
    if ~isfield(c,'executed') || ~c.executed
        ran = false;
        why = '';
        if isfield(c,'reason'), why = c.reason; end
        failures{end+1} = sprintf('%s: not executed %s', c.id, why); %#ok<AGROW>
        continue;
    end
    kind = 'domain';
    if isfield(c,'kind') && ~isempty(c.kind), kind = c.kind; end
    switch lower(kind)
        case 'numeric'
            nNum = nNum + 1;
            if ~isfield(c,'reference') || isempty(c.reference)
                numOK = false;
                failures{end+1} = sprintf('%s: no independent reference', c.id); %#ok<AGROW>
                continue;
            end
            tol = 0;
            if isfield(c,'tol') && ~isempty(c.tol)
                if isstruct(c.tol), tol = c.tol.rel*abs(c.reference);
                else, tol = c.tol; end
            end
            err = abs(c.value - c.reference);
            if ~(err <= tol)
                numOK = false;
                failures{end+1} = sprintf('%s: |%.6g - %.6g| = %.3g > tol %.3g', ...
                    c.id, c.value, c.reference, err, tol); %#ok<AGROW>
            end
        case 'domain'
            nDom = nDom + 1;
            cmp = 'le';
            if isfield(c,'cmp') && ~isempty(c.cmp), cmp = c.cmp; end
            if strcmpi(cmp,'le'), ok = c.value <= c.limit;
            else, ok = c.value >= c.limit; end
            if ~ok
                domOK = false;
                failures{end+1} = sprintf('%s: %.6g vs limit %s %.6g', ...
                    c.id, c.value, cmp, c.limit); %#ok<AGROW>
            end
        otherwise
            error('mas_grade:kind','unknown check kind "%s"', kind);
    end
end

r = struct();
r.ran = ran;
if nNum == 0
    r.correct = 'UNDETERMINED';
else
    r.correct = numOK;
end
if nDom == 0
    r.meets = 'UNDETERMINED';
else
    r.meets = domOK;
end
r.nNumeric = nNum; r.nDomain = nDom;
r.failures = failures;

if ~ran
    r.overall = 'FAIL';                       % not everything ran
elseif isequal(r.correct,false)
    r.overall = 'FAIL';                       % numbers are wrong
elseif isequal(r.meets,false)
    r.overall = 'CORRECT_NOT_ACCEPTED';       % numbers right, requirement not met
elseif ischar(r.correct) || ischar(r.meets)
    r.overall = 'UNDETERMINED';               % missing evidence is not a pass
else
    r.overall = 'PASS';
end
end
