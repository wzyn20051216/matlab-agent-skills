function bar_grouped(ax, valSets, thr, ttl, ylab, logy, xv, cids, ctrlIds, cmap)
%BARN 分组柱状图：支持任意数量控制器
%
% 拆成独立函数文件的原因：脚本级局部函数在 `-batch run()` 下会触发
% "文本字符无效"（R2026a 实测），而验收脚本必须能被 run() 直接执行。
%
% 注意：bar() 要求 x 为递增行向量且与 y 长度严格相等。3A.2 实测踩到两个坑：
%   1) [recs(ix).fld] 在结构体索引后被求值成全量（返回 N x numel(ix) 矩阵）
%   2) x 用 xv+(q-..)*w 生成行向量而 y 是列，长度语义不一致 -> "数据类型无效"
% 本函数对两者都做了防御：强制行向量 + 长度不符时置零（绝不崩溃）。
n = numel(valSets);
subplot(2,3,ax); hold on; grid on;
w = 0.8/n;
hs = gobjects(1,n);
nCond = numel(cids);
for q = 1:n
    v = valSets{q};
    if ~isnumeric(v)
        v = [];
    end
    v = reshape(v, 1, []);
    v(isnan(v)) = 0;                    % NaN（如未收敛的 settleMs）按 0 显示
    if numel(v) ~= nCond
        v = zeros(1, nCond);             % 长度不符则置零
    end
    xq = reshape(xv, 1, []) + (q-(n+1)/2)*w;
    hs(q) = bar(xq, v, w*0.9, 'FaceColor', cmap(q,:), 'EdgeColor', 'k');
end
if thr ~= 0
    hT = yline(thr, 'r--', 'LineWidth', 1.5);
    leg = [hs hT];
    names = [ctrlIds, {'spec line'}];
else
    leg = hs;
    names = ctrlIds;
end
if logy, set(gca, 'YScale', 'log'); end
set(gca, 'XTick', xv, 'XTickLabel', cids);
xlabel('condition'); ylabel(ylab); title(ttl);
legend(leg, names, 'Location', 'best');
end