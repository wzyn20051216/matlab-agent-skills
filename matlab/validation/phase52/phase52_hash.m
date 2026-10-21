function h = phase52_hash(values, checks)
%PHASE52_HASH  SHA-256 over frozen values and their grading checks.
%   The canonical form sorts fields and prints numbers with %.17g, so the hash
%   does not depend on struct ordering or display format. Changing a tolerance
%   without re-freezing therefore changes the hash.

parts = {};
f = sort(fieldnames(values));
for k = 1:numel(f)
    x = values.(f{k});
    parts{end+1} = sprintf('%s=%s', f{k}, canon_value(x)); %#ok<AGROW>
end
cparts = {};
for k = 1:numel(checks)
    c = checks(k);
    cparts{end+1} = sprintf('%s|%s|%s|%.17g', c.field, ...
        canon_value(c.ref), c.op, c.tol); %#ok<AGROW>
end
canon = [strjoin(parts, ';') '||' strjoin(cparts, ';')];
md = java.security.MessageDigest.getInstance('SHA-256');
d = md.digest(double(canon));
h = lower(reshape(dec2hex(typecast(d, 'uint8'), 2).', 1, []));
end

function s = canon_value(x)
if isnumeric(x) || islogical(x)
    s = sprintf('%.17g,', double(x(:)));
elseif iscell(x)
    p = cellfun(@(q) canon_value(q), x, 'UniformOutput', false);
    s = ['{' strjoin(p, ',') '}'];
else
    s = char(string(x));
end
end
