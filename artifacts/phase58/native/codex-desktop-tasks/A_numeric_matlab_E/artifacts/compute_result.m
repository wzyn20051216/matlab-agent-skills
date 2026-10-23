% @brief 计算指定矩阵的行列式和最大特征值模，并核对 JSON 输出。
M = [2 -1 0 0; -1 2 -1 0; 0 -1 2 -1; 0 0 -1 2];
determinant = det(M);
maxAbsEigenvalue = max(abs(eig(M)));

% 使用三对角矩阵的解析结果进行独立数值核对。
assert(abs(determinant - 5) < 1e-12);
assert(abs(maxAbsEigenvalue - (2 + 2*cos(pi/5))) < 1e-12);
jsonText = sprintf('{"determinant": %.6f, "maxAbsEigenvalue": %.6f}\n', ...
    determinant, maxAbsEigenvalue);
resultPath = fullfile(fileparts(mfilename('fullpath')), 'result.json');
[fileId, errorMessage] = fopen(resultPath, 'w');
assert(fileId ~= -1, '无法打开输出文件：%s', errorMessage);
try
    bytesWritten = fprintf(fileId, '%s', jsonText);
catch writeError
    fclose(fileId);
    rethrow(writeError);
end
closeStatus = fclose(fileId);
assert(bytesWritten == numel(jsonText) && closeStatus == 0, 'JSON 写入失败。');

% 读回文件，检查内容、字段和舍入结果。
savedText = fileread(resultPath);
assert(strcmp(savedText, jsonText), '文件内容与预期不一致。');
savedResult = jsondecode(savedText);
assert(savedResult.determinant == round(determinant, 6));
assert(savedResult.maxAbsEigenvalue == round(maxAbsEigenvalue, 6));
fprintf('MATLAB %s\n%s', version, savedText);
fprintf('验证通过：%s\n', resultPath);
