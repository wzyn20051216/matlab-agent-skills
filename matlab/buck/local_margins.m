function [Gm_dB, Pm_deg, Wcg, Wcp, xover, diag] = local_margins(L, w)
%LOCAL_MARGINS 数值扫描求环路增益裕度/相位裕度（稠密网格 + 分支一致的对数二分）
%
% 为什么要绕开 margin()：
%   1) margin() 只返回"一个"交越点的结果。陷波器环路存在两次 0dB 交越
%      （谐振峰出口 + 陷波后再入口），单点结果会漏掉另一侧的裕度；
%   2) margin() 默认频率网格可能漏检穿越（本项目实测：无相位穿越时返回
%      Wcg=NaN，而有穿越时其默认网格找不到 159 kHz 处的 -180° 穿越）；
%   3) 本项目曾把 Wcg（相位穿越频率）误当幅值用，导致 GM 恒为 -70 dB 量级。
%      本函数把"频率"与"幅值"两个概念在代码层面彻底分开。
%
% ---------------------------------------------------------------------------
% Phase 3A.2 修复（缺陷 F-15）：网格与根求解的相位分支定义统一
%   旧实现：网格侧用 unwrap 连续相位检测穿越；二分细化侧却用 angle() 主值
%   相位直接减 lvl。穿过 ±180 度时主值从 -179 跳到 +179，两侧同号，
%   fa*fb>0 恒成立 -> 二分永远落入"几何中点"兜底（注释还写着"理论上不会
%   到这里"）。实测 BASE 回路 Wcg=5504.749 vs 真值 5504.819（相对误差
%   1.3e-5）；穿越越窄（如轻载陷波器回路的成对穿越）误差越大。
%   现统一为：调用方把网格 unwrap 端点相位传进二分；局部每次求值的主值
%   相位按"log 频率线性插值估计 + 360 取整"归位到该分支。
%
%   配套纪律（不得输出虚假 Inf GM / 虚假精度）：
%   - 内部把频率带向两端各扩展 2^20 倍（每倍频 24 点），带外穿越也检测、
%     细化并计入最坏值（xover.outsideBand 标记），从机制上杜绝"带内无穿越
%     就报 Inf"的虚假结论；
%   - 二分无符号变化或求值非有限 -> ok=false，取该格保守端（相位穿越取
%     |L| 较大者；增益交越取 PM 较小者），xover.refined=false；
%   - 相位恰好命中检查层（含整段贴在临界线上）按穿越处理，保守；
%   - 低端/高端截断、单格相位缠绕(>150°)、非有限值 -> 相关认证置假；
%   - 无任何穿越且上述风险全无时才认证 GM=Inf，否则 NaN + diag.msg。
% ---------------------------------------------------------------------------
%
% 输入:
%   L - SISO 传递函数（连续/离散均可；非 tf 会被转换）
%   w - 频率网格 (rad/s)，可选；默认 logspace(-2, 8, 400001)（自动排序去重）
% 输出（"最坏值"口径 = 同类全部穿越中裕度最小者，保守）:
%   Gm_dB  - 增益裕度 dB = -mag_dB(相位穿越处)；无穿越 -> +Inf（仅认证时），
%            否则 NaN（见 diag.msg）
%   Pm_deg - 相位裕度 deg = 180 + phase_deg(0dB 穿越处，分支修正后，可越出
%            ±180)；无增益穿越 -> NaN
%   Wcg/Wcp- 最坏 GM/PM 对应的频率 (rad/s)
%   xover  - 全部穿越明细：freq/kind/mag_dB/phase_deg/Pm/Gm_dB/refined/
%            atEdge/outsideBand（atEdge=调用方频带端点，outsideBand=扩展区）
%   diag   - 诊断：nGain/nPhase/nUnrefined/nEdge/nOutside/nZeroHit/nNaN/
%            nWrap/lowTruncated/highTruncated/coarseRisk/gmCertified/
%            pmCertified/band/msg
%
% 判定约定:
%   0dB 穿越  : |L| 穿过 0 dB；PM = 180 + phase（分支修正后）
%   -180°穿越 : 相位穿过 -(2k+1)*180（Nyquist 临界点 -1）；GM = -mag_dB。
%               偶数倍 180（正实轴）不算穿越。
%   已知局限（文档化，不伪装）: 相切穿越（不变号）只能靠"恰好命中"规则
%   兜底；扩展网格每倍频 24 点，比这更窄的带外往返穿越可能漏检（此时
%   若带内也无穿越则不会认证 Inf）。

if ~isa(L, 'tf'), L = tf(L); end
if nargin < 2 || isempty(w), w = logspace(-2, 8, 400001); end
w = w(:);
if any(w <= 0) || any(~isfinite(w))
    error('local_margins:badGrid', '频率网格必须全为正有限值');
end
w = unique(sort(w));
if numel(w) < 2
    error('local_margins:badGrid', '频率网格至少需要 2 个点');
end

% ---------- 内部网格 = 调用方网格 + 两端几何扩展（认证带外行为） ----------
% 离散系统封顶到奈奎斯特频率：z=e^(jwTs) 在 w>pi/Ts 上是下半圆的镜像，
% 继续扫描会把镜像区的 +180 穿越误统计成 -180 穿越（虚假 GM/PM）。
% 注意：封顶必须在**内部扩展之后**再做一次——build_internal_grid 会向两端
% 各扩 480 个倍频程，若只封顶输入网格，扩展段仍会越过奈奎斯特频率，
% 产生频率高达 pi/Ts * 2^20 的虚假穿越（3A.2 实测：离散回路报出 26GHz 交越，
% 而奈奎斯特仅 25kHz，PM 从 +57.28deg 错成 -48.66deg）。
wAll = build_internal_grid(w);
if L.Ts > 0
    wNyq = pi/L.Ts;
    wAll = wAll(wAll <= wNyq*(1+1e-12));
    if numel(wAll) < 2
        error('local_margins:badGrid', ...
            '离散系统频率网格需覆盖到奈奎斯特频率 %.4g rad/s', wNyq);
    end
end
H = reshape(freqresp(L, wAll), [], 1);   % SISO -> N x 1
mag   = abs(H);
magdb = 20*log10(max(mag, realmin));
ph    = rad2deg(unwrap(angle(H)));      % 全网格连续相位（分支基准）

% ---------- 诊断：覆盖性与数据健全性 ----------
reldeg = numel(L.den{1}) - numel(L.num{1});
phHF   = -90*reldeg;                    % HF 渐近相位（相对阶次定理）
kmax   = max(0, ceil((-min(ph) - 180)/360));
kmax   = max(kmax, ceil((-max(-min(ph), -phHF) - 180)/360));
nWrap  = sum(abs(diff(ph)) > 150);      % 单格相位变化接近 unwrap 阈值
nNaN   = sum(~isfinite(magdb)) + sum(~isfinite(ph));
lowTruncated  = ph(1) <= -179;          % 扩展后最低频仍在 -180 以下
highTruncated = phHF < (-180 - 360*kmax) - 1e-9;  % 渐近比检查的最深层还低
coarseRisk = (nWrap > 0) || (nNaN > 0);
inBand = (wAll >= w(1)*(1-1e-12)) & (wAll <= w(end)*(1+1e-12));

xover = struct('freq',{}, 'kind',{}, 'mag_dB',{}, 'phase_deg',{}, ...
               'Pm',{}, 'Gm_dB',{}, 'refined',{}, 'atEdge',{}, 'outsideBand',{});
nUnrefined = 0; nZeroHit = 0;

% ---------- 0 dB 穿越（增益交越；幅值单值无分支问题） ----------
sg = sign(magdb);
sg(sg == 0) = 1;                        % 恰好 0 dB 视为在 0dB 上方
idx = find(sg(1:end-1) ~= sg(2:end));
for k = 1:numel(idx)
    i0 = idx(k);
    [wc, ok] = bisect_logw(L, wAll(i0), wAll(i0+1), 'magdb0', []);
    if ok
        [mdb, pdeg] = eval_at(L, wc);
        pdeg = snap_branch(pdeg, wc, wAll, ph);   % 归位到网格分支
    else
        nUnrefined = nUnrefined + 1;
        [~, jj] = min([180+ph(i0), 180+ph(i0+1)]);   % 保守端：PM 较小者
        wc = wAll(i0+jj-1); mdb = magdb(i0+jj-1); pdeg = ph(i0+jj-1);
    end
    xover(end+1) = struct('freq', wc, 'kind', 'gain', ...
        'mag_dB', mdb, 'phase_deg', pdeg, 'Pm', 180 + pdeg, ...
        'Gm_dB', NaN, 'refined', ok, ...
        'atEdge', at_band_edge(wc, w), 'outsideBand', ~in_band_at(wc, inBand, wAll));
end

% ---------- 相位穿越 -(2k+1)*180 度 ----------
% 电平范围：负侧到 kmax；正侧还要查 +180（k=-1）——相位整段恰贴在 +180 时
% （如双积分器 L=K/s^2，主值相位恒为 +180）也必须按穿越处理（合成测试 T5c）
kmin = 0;
while (-180 - 360*(kmin-1)) <= max(ph) + 1e-9
    kmin = kmin - 1;
end
for k = kmin:kmax
    lvl = -180 - 360*k;
    d = ph - lvl;
    zeroIdx = find(abs(d) < 1e-9);       % 恰好命中（含浮点噪声，容差 1e-9 度）
    d(abs(d) < 1e-9) = -eps;
    sg2 = sign(d);
    idx2 = find(sg2(1:end-1) ~= sg2(2:end));
    covered = ismember(zeroIdx, [idx2; idx2+1]);   % 已被括号覆盖的不重复计
    zeroIdx = zeroIdx(~covered);
    for j = 1:numel(idx2)
        i0 = idx2(j);
        [wg, ok] = bisect_logw(L, wAll(i0), wAll(i0+1), 'phase', lvl, ph(i0), ph(i0+1));
        if ok
            [mdb, ~] = eval_at(L, wg);
        else
            nUnrefined = nUnrefined + 1;
            [~, jj] = max([magdb(i0), magdb(i0+1)]);   % 保守端：|L| 较大者
            wg = wAll(i0+jj); mdb = magdb(i0+jj);
        end
        xover(end+1) = struct('freq', wg, 'kind', 'phase', ...
            'mag_dB', mdb, 'phase_deg', lvl, 'Pm', NaN, ...
            'Gm_dB', -mdb, 'refined', ok, ...
            'atEdge', at_band_edge(wg, w), 'outsideBand', ~in_band_at(wg, inBand, wAll));
    end
    % 未被括号覆盖的恰好命中（连续段折叠为一个穿越，取段内 |L| 最大者）
    if ~isempty(zeroIdx)
        nZeroHit = nZeroHit + 1;
        runs = segment_runs(zeroIdx);
        for r = 1:size(runs,1)
            ii = runs(r,1):runs(r,2);
            [~, jm] = max(magdb(ii));
            wg = wAll(ii(jm)); mdb = magdb(ii(jm));
            xover(end+1) = struct('freq', wg, 'kind', 'phase', ...
                'mag_dB', mdb, 'phase_deg', lvl, 'Pm', NaN, ...
                'Gm_dB', -mdb, 'refined', true, ...
                'atEdge', at_band_edge(wg, w), 'outsideBand', ~in_band_at(wg, inBand, wAll));
        end
    end
end

% ---------- 汇总（最坏值口径，含带外穿越） ----------
% 注意：iw 是过滤后数组的下标，必须从过滤后的数组里取 freq，
% 不能拿回全数组用（曾因此把 Wcg 错取成增益交越的频率）
isG = strcmp({xover.kind}, 'gain');
isP = strcmp({xover.kind}, 'phase');
gX = xover(isG);
pX = xover(isP);
nOutside = sum([xover.outsideBand]);
if ~isempty(gX)
    [Pm_deg, iw] = min([gX.Pm]);
    Wcp = gX(iw).freq;
else
    Pm_deg = NaN; Wcp = NaN;
end
bandOK = ~lowTruncated && ~highTruncated && ~coarseRisk;
if ~isempty(pX)
    [Gm_dB, iw] = min([pX.Gm_dB]);
    Wcg = pX(iw).freq;
elseif bandOK
    Gm_dB = Inf; Wcg = NaN;             % 全网格（含扩展）无穿越，Inf 已认证
else
    Gm_dB = NaN; Wcg = NaN;             % 无穿越但覆盖性存疑：不输出虚假 Inf
end

diag = struct('nGain', sum(isG), 'nPhase', sum(isP), ...
    'nUnrefined', nUnrefined, 'nEdge', sum([xover.atEdge]), ...
    'nOutside', nOutside, 'nZeroHit', nZeroHit, 'nNaN', nNaN, 'nWrap', nWrap, ...
    'lowTruncated', lowTruncated, 'highTruncated', highTruncated, ...
    'coarseRisk', coarseRisk, 'gmCertified', bandOK, 'pmCertified', bandOK, ...
    'band', [w(1) w(end)], 'msg', '');
if ~isempty(pX)
    if ~bandOK
        diag.msg = '覆盖性存疑（截断/缠绕/NaN）：GM/PM 为已检测穿越的最坏值，未认证';
    elseif nUnrefined > 0
        diag.msg = sprintf('%d 个穿越未能可靠细化，已取保守端', nUnrefined);
    elseif nOutside > 0
        diag.msg = sprintf('%d 个穿越在调用方频带之外（由内部扩展网格发现，已计入）', nOutside);
    end
elseif ~bandOK
    diag.msg = '覆盖性存疑（截断/缠绕/NaN）：未发现相位穿越，GM 未判定（NaN）';
end
end

% ============================ 局部函数 ============================

function wAll = build_internal_grid(w)
% 调用方网格 + 两端各 2^20 倍、每倍频 24 点的几何扩展（上限 1e12 / 下限 1e-12）
nExt = 20*24;
wLo = w(1) ./ 2.^((1:nExt)/24);
wLo = wLo(wLo >= 1e-12);
wHi = w(end) .* 2.^((1:nExt)/24);
wHi = wHi(wHi <= 1e12);
wAll = unique(sort([w; wLo(:); wHi(:)]));
end

function [wc, ok] = bisect_logw(L, wa, wb, mode, lvl, pha, phb)
% 在 [wa,wb] 的对数区间上二分，定位 magdb=0 或 phase=lvl 的频率。
% phase 模式：pha/phb 是调用方在网格上算出的 unwrap 连续相位端点；局部
% 每次求值的主值相位都归位到该分支（F-15：网格与根求解分支定义统一）。
la = log(wa); lb = log(wb);
switch mode
    case 'magdb0'
        fa = eval_magdb(L, wa);
        fb = eval_magdb(L, wb);
        lvl_b = 0;
    case 'phase'
        lvl_b = lvl + 360*round((pha - lvl)/360);   % level 归位到 pha 所在分支
        fa = pha - lvl_b;
        fb = phb - lvl_b;
    otherwise
        error('local_margins:badMode', '未知二分模式: %s', mode);
end
if ~isfinite(fa) || ~isfinite(fb)
    wc = sqrt(wa*wb); ok = false; return;
end
if fa == 0, wc = wa; ok = true; return; end
if fb == 0, wc = wb; ok = true; return; end
if fa*fb > 0
    wc = NaN; ok = false; return;    % 无符号变化：不冒充精确解
end
for it = 1:100
    lm = 0.5*(la + lb);
    wm = exp(lm);
    switch mode
        case 'magdb0'
            fm = eval_magdb(L, wm);
        case 'phase'
            pm = eval_phase(L, wm);                        % 主值相位
            phL = fa + lvl_b;                              % 当前左端连续相位
            phR = fb + lvl_b;                              % 当前右端连续相位
            est = phL + (phR - phL)*(lm - la)/(lb - la);   % log 频率线性插值
            pm = pm + 360*round((est - pm)/360);           % 归位到连续分支
            fm = pm - lvl_b;
    end
    if fa*fm <= 0
        lb = lm; fb = fm;
    else
        la = lm; fa = fm;
    end
    if abs(lb - la) < 1e-14, break; end
end
wc = exp(0.5*(la + lb)); ok = true;
end

function mdb = eval_magdb(L, w)
H = eval_H(L, w);
mdb = 20*log10(max(abs(H), realmin));
end

function pdeg = eval_phase(L, w)
H = eval_H(L, w);
pdeg = rad2deg(angle(H));              % 主值；分支由调用方归位
end

function [magdb, phasedeg] = eval_at(L, w)
H = eval_H(L, w);
magdb = 20*log10(max(abs(H), realmin));
phasedeg = rad2deg(angle(H));
end

function H = eval_H(L, w)
% SISO **连续** tf 用多项式直接求值（比逐点 freqresp 快约两个量级，数学
% 等价；阶数很高时注意 |jw|^n 的量级）。离散系统必须走 freqresp——其频响
% 定义在 z=e^(jw*Ts) 上，多项式在 jw 上求值是错的（3A.2 抓到的坑）。
if isa(L, 'tf') && isequal(size(L), [1 1]) && (L.Ts == 0)
    jw = 1i*w;
    H = polyval(L.num{1}, jw)/polyval(L.den{1}, jw);
else
    H = freqresp(L, w);
    H = H(1,1);
end
end

function pdeg_c = snap_branch(pdeg, wc, wAll, ph)
% 把主值相位归位到网格 unwrap 相位在 wc 处的分支
lwc = log(wc);
ph_ref = interp1(log(wAll), ph, lwc, 'linear', 'extrap');
n = round((ph_ref - pdeg)/360);
pdeg_c = pdeg + 360*n;
end

function tf = at_band_edge(wc, w)
tol = 1e-9;
tf = (wc <= w(1)*(1+tol)) || (wc >= w(end)*(1-tol));
end

function ob = in_band_at(wc, inBand, wAll)
% wc 是否落在调用方频带内（按内部网格的成员关系近似）
lwc = log(wc);
lb = interp1(log(wAll), double(inBand), lwc, 'nearest', 'extrap');
ob = lb > 0.5;
end

function runs = segment_runs(idx)
% 把下标向量切成连续段，返回 [起 止] 行矩阵；空输入返回空
runs = [];
if isempty(idx), return; end
st = idx(1); pv = idx(1);
for i = 2:numel(idx)
    if idx(i) == pv + 1
        pv = idx(i);
    else
        runs(end+1,:) = [st pv]; %#ok<SAGROW>
        st = idx(i); pv = idx(i);
    end
end
runs(end+1,:) = [st pv]; %#ok<SAGROW>
end
