function [Gm_dB, Pm_deg, Wcg, Wcp, xover] = local_margins(L, w)
%LOCAL_MARGINS 数值扫描求环路增益裕度/相位裕度（稠密网格 + 对数二分细化）
%
% 为什么要绕开 margin()：
%   1) margin() 只返回"一个"交越点的结果。陷波器环路存在两次 0dB 交越
%      （谐振峰出口 + 陷波后再入口），单点结果会漏掉另一侧的裕度；
%   2) margin() 默认频率网格可能漏检穿越（本项目实测：无相位穿越时返回
%      Wcg=NaN，而有穿越时其默认网格找不到 159 kHz 处的 -180° 穿越）；
%   3) 本项目曾把 Wcg（相位穿越频率）误当幅值用，导致 GM 恒为 -70 dB 量级。
%      本函数把"频率"与"幅值"两个概念在代码层面彻底分开。
%
% 输入:
%   L - SISO 传递函数（连续/离散均可）
%   w - 频率网格 (rad/s)，可选；默认 logspace(-2, 8, 400001)
% 输出（"最坏值"口径 = 同类全部穿越中裕度最小者，保守）:
%   Gm_dB  - 增益裕度 dB = -mag_dB(相位穿越处)；无相位穿越 -> +Inf
%   Pm_deg - 相位裕度 deg = 180 + phase_deg(0dB 穿越处)；无增益穿越 -> NaN
%   Wcg    - 最坏增益裕度对应的相位穿越频率 (rad/s)
%   Wcp    - 最坏相位裕度对应的增益穿越频率 (rad/s)
%   xover  - 结构数组，全部穿越明细（freq/kind/mag_dB/phase_deg/Pm/Gm_dB）
%
% 判定约定:
%   0dB 穿越   : |L| 幅频曲线穿过 0 dB 的点，该点 PM = 180 + phase
%   -180°穿越  : 相频曲线穿过 -180°-360k 的点，该点 GM = -mag_dB
%   （相位用 unwrap 后的连续相位；网格粗定位 + log 域二分细化到机器精度）

if nargin < 2 || isempty(w), w = logspace(-2, 8, 400001); end
w = w(:);
H = freqresp(L, w);
H = reshape(H, numel(H), 1);           % SISO -> N x 1

mag   = abs(H);
magdb = 20*log10(max(mag, realmin));
ph    = rad2deg(unwrap(reshape(angle(H), numel(H), 1)));

xover = struct('freq',{}, 'kind',{}, 'mag_dB',{}, 'phase_deg',{}, ...
               'Pm',{}, 'Gm_dB',{});

% ---------- 0 dB 穿越（增益交越）----------
sg = sign(magdb);
sg(sg == 0) = 1;                        % 恰好 0 dB 视为在 0dB 上方
idx = find(sg(1:end-1) ~= sg(2:end));
for k = 1:numel(idx)
    i0 = idx(k);
    wc = bisect_logw(L, w(i0), w(i0+1), 'magdb0');
    [mdb, pdeg] = eval_at(L, wc);
    xover(end+1) = struct('freq', wc, 'kind', 'gain', ...
        'mag_dB', mdb, 'phase_deg', pdeg, 'Pm', 180 + pdeg, 'Gm_dB', NaN);
end

% ---------- 相位穿越 -180° - 360k ----------
kmax = max(0, ceil((-min(ph) - 180)/360));
for k = 0:kmax
    lvl = -180 - 360*k;
    d = ph - lvl;
    d(d == 0) = -eps;                   % 恰好命中视为正在穿越
    sg2 = sign(d);
    idx2 = find(sg2(1:end-1) ~= sg2(2:end));
    for j = 1:numel(idx2)
        i0 = idx2(j);
        wg = bisect_logw(L, w(i0), w(i0+1), 'phase', lvl);
        [mdb, ~] = eval_at(L, wg);
        xover(end+1) = struct('freq', wg, 'kind', 'phase', ...
            'mag_dB', mdb, 'phase_deg', lvl, 'Pm', NaN, 'Gm_dB', -mdb);
    end
end

% ---------- 汇总（最坏值口径）----------
% 注意：iw 是过滤后数组的下标，必须从过滤后的数组里取 freq，
% 不能拿回全数组用（曾因此把 Wcg 错取成增益交越的频率）
isG = strcmp({xover.kind}, 'gain');
isP = strcmp({xover.kind}, 'phase');
gX = xover(isG);
pX = xover(isP);
if ~isempty(gX)
    [Pm_deg, iw] = min([gX.Pm]);
    Wcp = gX(iw).freq;
else
    Pm_deg = NaN; Wcp = NaN;
end
if ~isempty(pX)
    [Gm_dB, iw] = min([pX.Gm_dB]);
    Wcg = pX(iw).freq;
else
    Gm_dB = Inf; Wcg = NaN;
end
end

function wc = bisect_logw(L, wa, wb, mode, lvl)
% 在 [wa,wb] 的对数区间上二分，定位 magdb=0 或 phase=lvl 的频率
if nargin < 5 || isempty(lvl), lvl = NaN; end
la = log(wa); lb = log(wb);
fa = target(L, wa, mode, lvl);
fb = target(L, wb, mode, lvl);
if ~isfinite(fa) || ~isfinite(fb) || fa*fb > 0
    wc = sqrt(wa*wb);                    % 几何中点兜底（理论上不会到这里）
    return;
end
for it = 1:100
    lm = 0.5*(la + lb);
    wm = exp(lm);
    fm = target(L, wm, mode, lvl);
    if fa*fm <= 0
        lb = lm; fb = fm;
    else
        la = lm; fa = fm;
    end
    if abs(lb - la) < 1e-14, break; end
end
wc = exp(0.5*(la + lb));
end

function v = target(L, w, mode, lvl)
[mdb, pdeg] = eval_at(L, w);
switch mode
    case 'magdb0', v = mdb;
    case 'phase',  v = pdeg - lvl;
end
end

function [magdb, phasedeg] = eval_at(L, w)
H = freqresp(L, w);
magdb = 20*log10(max(abs(H(1,1)), realmin));
phasedeg = rad2deg(angle(H(1,1)));       % 单点求值无需 unwrap（穿越判定已由网格相位完成）
end
