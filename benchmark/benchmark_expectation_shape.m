function [tf, why] = benchmark_expectation_shape(txt)
%BENCHMARK_EXPECTATION_SHAPE  Does this text bind an expectation key to a value?
%
%   [tf, why] = benchmark_expectation_shape(txt)
%
% The word "verdict" appears in every honest report; an EXPECTATION is a shape:
%
%   "verdict":"PASS"    "ref":0.5    "expectedVerdict":"FAIL"    "answersSha256":"..."
%
% Bare key names never match, and neither does the task's own input material (an
% ODE definition, a tolerance, a target stated by management). This is what the
% leak detectors compare against; see benchmark_scan_for_answers.m for what the
% whole check can and cannot prove.

tf = false; why = '';
if ~isempty(regexpi(txt, '"answersSha256"\s*:\s*"', 'once'))
    tf = true; why = 'sealed answers hash'; return;
end
if ~isempty(regexp(txt, '"verdict"\s*:\s*"(PASS|FAIL|UNDETERMINED)"', 'once'))
    tf = true; why = 'binds a verdict key to a verdict value'; return;
end
if ~isempty(regexp(txt, '"(ref|expected|expectedVerdict|answer)"\s*:', 'once'))
    tf = true; why = 'binds an expectation key to a value'; return;
end
end
