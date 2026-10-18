function m = step_metrics(t, y, yRef, tEvent, bandPct)
%STEP_METRICS 阶跃响应的时域指标（首次进入 vs 持续稳定，双口径）
%
% Phase 3A.2 修复（缺陷 F-16）：旧口径只报"首次进入 ±band 频带的时刻"，
% 无法排除之后再次越界——一个先跌进频带、再冲出去振荡的信号会被误报为
% "已恢复"。本函数同时给出两个口径并附加健全性诊断：
%
%   dipPct        事件后全程最小值的相对偏差（%）
%   osPct         事件后全程最大值的相对偏差（%）
%   firstEntryMs  首次进入口径：自跌落点之后首次满足 |y-yRef|<=band 的时刻
%                 （与 3A.1 口径一致，仅作对照）
%   settleMs      持续稳定口径：此后一直保持在带内直到记录末点的时刻；
%                 末点仍越界 -> NaN（未收敛）；从未越界 -> 0
%   nExits        首次进入之后的越界次数（>0 即说明首次进入口径高估了恢复）
%   lastExitMs    最后一次越界的时刻
%   converged     末点在带内（且其前无越界）——配合 tailInBandMs 判断
%   tailInBandMs  末段连续在带内的时长（判断仿真窗口是否足以证明稳定）
%   settleSlackMs settleMs 之后还剩多长记录（太小则"已稳定"结论存疑）
%   growth        事件后前 1/3 与后 1/3 的包络比（>1 且末段不在带内 = 增长）
%   hasNaN        输入含非有限值（此时所有指标为 NaN，不输出虚假数字）
%   recordMs      事件后记录时长
%
% 输入:
%   t, y     - 时间 (s) 与信号（等间距或不等间距均可）
%   yRef     - 参考值（稳态目标）
%   tEvent   - 事件时刻 (s)，只统计此后
%   bandPct  - 频带半宽（% of |yRef|）

m = struct();
m.hasNaN = any(~isfinite(y)) || any(~isfinite(t));
iEv = find(t >= tEvent, 1, 'first');
if isempty(iEv)
    error('step_metrics: 事件时刻 %.4g 超出记录范围 [%.4g, %.4g]', tEvent, t(1), t(end));
end
tv = t(iEv:end);
yv = y(iEv:end);
m.recordMs = (tv(end) - tv(1))*1e3;
if m.hasNaN
    m.dipPct = NaN; m.osPct = NaN; m.firstEntryMs = NaN; m.settleMs = NaN;
    m.nExits = NaN; m.lastExitMs = NaN; m.converged = false;
    m.tailInBandMs = NaN; m.settleSlackMs = NaN; m.growth = NaN;
    return;
end

band = bandPct/100*abs(yRef);
dev = yv - yRef;
inB = abs(dev) <= band;

% 跌落与超调（事件后全程极值）
[m.dip, diDip] = min(yv);
m.dipPct = (m.dip - yRef)/yRef*100;
m.osPct = (max(yv) - yRef)/yRef*100;

% 首次进入：锚点取事件后**最大偏差**处（不是最小值）——对跌落型响应两者
% 一致（偏差最大就在跌落点），但对起步型单调衰减（最小值在记录末尾）才不会
% 退化成"从末尾开始找"。3A.1 旧实现锚在最小值，起步型响应会报出记录时长。
[~, di] = max(abs(dev));
after = inB(di:end);
bi = find(after, 1, 'first');
if isempty(bi)
    m.firstEntryMs = NaN;
else
    m.firstEntryMs = (tv(di+bi-1) - tv(1))*1e3;
end

% 持续稳定：从末尾向前找最后一次越界
outIdx = find(~inB);
if isempty(outIdx)
    m.settleMs = 0; m.nExits = 0; m.lastExitMs = NaN;
else
    lastOut = outIdx(end);
    if lastOut == numel(inB)
        m.settleMs = NaN;                 % 末点仍越界：未收敛
    else
        % 3A.4 修正（缺陷 D-A4）：持续稳定的时刻是**最后一个越界样本之后的
        % 第一个在带内样本**，即 tv(lastOut+1)。旧实现取 tv(lastOut)，把
        % "仍在越界的时刻"当成"已稳定的时刻"，系统性低估恰好一个采样间隔
        % （本工程 1 µs，19 个案例偏差恒为 +0.0010 ms）。
        % 定义依据：S5 = 输出进入 ±1% 带并**从此持续保持**在带内的时间，
        % 进入发生在最后一个越界样本之后，不在该样本本身。
        m.settleMs = (tv(lastOut+1) - tv(1))*1e3;
    end
    m.lastExitMs = (tv(lastOut) - tv(1))*1e3;
    if ~isempty(bi)
        % 首次进入之后的越界"次数"（连续越界段数，不是采样点数）
        oo = ~inB(di+bi-1:end);
        d2 = diff([0; oo(:); 0]);
        m.nExits = sum(d2 == 1);
    else
        m.nExits = NaN;
    end
end

% 末段在带内时长与收敛判定
if inB(end)
    k = numel(inB);
    while k > 1 && inB(k-1), k = k-1; end
    m.tailInBandMs = (tv(end) - tv(k))*1e3;
    m.converged = true;
else
    m.tailInBandMs = 0;
    m.converged = false;
end
if isnan(m.settleMs)
    m.settleSlackMs = 0;
else
    m.settleSlackMs = m.recordMs - m.settleMs;
end

% 增长检测：事件后前 1/3 与后 1/3 的偏差包络比
n1 = max(1, round(numel(yv)/3));
e1 = max(abs(yv(1:n1) - yRef));
e2 = max(abs(yv(end-n1+1:end) - yRef));
m.growth = e2/max(e1, eps);
end
