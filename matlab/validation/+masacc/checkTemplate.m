function template = checkTemplate()
%CHECKTEMPLATE 单个检查项的空模板（字段顺序即 JSON 输出顺序）。

template = struct();
template.id = "";
template.title = "";
template.level = "";
template.status = "";
template.command = "";
template.exitCode = [];
template.startedAt = "";
template.finishedAt = "";
template.durationSeconds = [];
template.metrics = struct();
template.reason = "";
template.errorClass = "";
template.artifactPaths = {};
template.sourceReport = "";
template.retry = [];
end
