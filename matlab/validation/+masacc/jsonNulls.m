function text = jsonNulls(text)
%JSONNULLS 把 MATLAB 空值编码出的 [] / "" 还原成 JSON 的 null。
%
% 为什么需要这一步：
%   jsonencode 把空 double 写成 []、把空 string 写成 ""。而验收 schema 里
%   exitCode / durationSeconds / retry / licensed 只允许 number|object|boolean 或 null，
%   errorClass 是带 null 的枚举，reason / command 之类也只接受 string|null。
%   "" 会直接违反 errorClass 的枚举，[] 会被判成"类型是 array 而不是 number"。
%
% 因此在落盘前统一把"空值"翻译成 null，保证 MATLAB 侧与 PowerShell 侧产出的
% 报告在同一个 schema 下都能通过校验。

pairs = {
    '"command"',      '""'
    '"reason"',       '""'
    '"errorClass"',   '""'
    '"sourceReport"', '""'
    '"startedAt"',    '""'
    '"finishedAt"',   '""'
    };
for idx = 1:size(pairs, 1)
    key = pairs{idx, 1};
    empty = pairs{idx, 2};
    text = regexprep(text, [regexptranslate('escape', key) '\s*:\s*' regexptranslate('escape', empty)], [key ': null']);
end

empties = {'"exitCode"', '"durationSeconds"', '"retry"', '"licensed"'};
for idx = 1:numel(empties)
    key = empties{idx};
    text = regexprep(text, [regexptranslate('escape', key) '\s*:\s*\[\s*\]'], [key ': null']);
end
end
