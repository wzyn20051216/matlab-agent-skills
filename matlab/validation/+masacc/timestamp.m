function value = timestamp()
%TIMESTAMP 返回带本地时区偏移的 ISO 8601 时间戳。
%
% 验收报告要求 startedAt / finishedAt 可直接被 JSON Schema 的 date-time 校验，
% 因此不能使用 datestr，也不能省略时区。

value = string(datetime("now", "TimeZone", "local", "Format", "yyyy-MM-dd'T'HH:mm:ssXXX"));
end
