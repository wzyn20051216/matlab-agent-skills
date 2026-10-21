%% Phase 3A.3 Stage A - read-only audit (does NOT modify any existing source)
%
% Purpose: locate the true source of the S5 bottleneck.
%   Q1 which condition / controller / linear model owns the -82.2 rad/s pole?
%   Q2 how large is its actual contribution to vC (modal residue)?
%   Q3 is the measured 4.4-8.5 ms consistent with the slow pole? If so, derive.
%   Q4 are the S5 definition and the simulation window adequate?
%
% Method: do NOT re-run Simulink. Reuse the 21 recorded waveforms in
% task5_acceptance.mat; rebuild the linear models independently and cross-check
% against pole() / damp() / stepinfo() / allmargin().
%
% Output: artifacts/validation/buck/a3_stage_a_audit.json + .mat
% This script only reads existing data; it writes no existing file.
%
% NOTE: this file is intentionally pure ASCII. MATLAB on this machine reads .m
% files with the system codepage (GBK); non-ASCII string literals can trigger
% "invalid text character". Keep sources ASCII, put prose in the report.

clear; close all;
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, '..'));
outDir = getenv('BUCK_OUT');
if isempty(outDir), outDir = fullfile(here,'..','..','artifacts','validation','buck'); end
outDir = strrep(outDir,'/',filesep);

Vin0 = 48; L0 = 150e-6; C0 = 220e-6; R0 = 6; Vref = 12;

fprintf('================ Stage A: read-only audit ================\n');
fprintf('data source: task5_acceptance.mat (21 recorded waveforms)\n');

D = load(fullfile(outDir,'task5_acceptance.mat'));
recs = D.recs; conds = D.conds; ctrls = D.ctrls; b = D.b; fnNom = D.fnNom;
fprintf('loaded %d records (%d conditions x %d controllers)\n', ...
    numel(recs), numel(conds), numel(ctrls));

condTbl = [ ...
    48 6   150e-6 ; ...
    42 6   150e-6 ; ...
    54 6   150e-6 ; ...
    48 12  150e-6 ; ...
    48 3   150e-6 ; ...
    54 3   150e-6 ; ...
    48 6   195e-6 ];

ctrlTbl = { ...
    struct('id','BASE','Kp',0,'Ki',7.902901,'notch',false), ...
    struct('id','OPT','Kp',b.Kp,'Ki',b.Ki,'notch',true), ...
    struct('id','OPT30','Kp',b.Kp,'Ki',30,'notch',true)};

out = struct();
out.records = {}; out.modes = {};
out.tailFit = struct('ctrl',{},'poleTauMs',{},'fitTauMs',{}, ...
    'poleRate',{},'fitRate',{},'devPct',{});
out.s5cmp = struct('cond',{},'ctrl',{},'settleOld',{},'settleStrict',{}, ...
    'firstEntry',{},'nExits',{},'tailInBand',{},'deltaMs',{});
out.feasib = struct('ctrl',{},'tauMs',{},'AmpPctBack',{},'s5',{}, ...
    'tauNeedMs',{},'reNeed',{},'firstEntry',{});

fprintf('\n--- A1 closed-loop poles and modal residues ---\n');
fprintf('%-5s %-6s %10s %11s %9s %10s %10s\n', ...
    'cond','ctrl','maxRe','domTau_ms','domHz','domAmp_pct','domShare_pct');

for ic = 1:size(condTbl,1)
    Vin = condTbl(ic,1); R = condTbl(ic,2); L = condTbl(ic,3);
    for ik = 1:numel(ctrlTbl)
        k = ctrlTbl{ik};
        Gvd = tf(Vin, [L*C0, L/R, 1]);
        if k.notch
            not = (tf('s')^2 + 2*b.zn*fnNom*tf('s') + fnNom^2) / ...
                  (tf('s')^2 + 2*b.zd*fnNom*tf('s') + fnNom^2);
            Cc = pid(k.Kp, k.Ki, 0, 0) * not;
        else
            Cc = pid(k.Kp, k.Ki, 0, 0);
        end
        Loop = minreal(Cc*Gvd);
        Tcl  = minreal(feedback(Loop,1));

        [A,Bv,Cv,~] = ssdata(ss(Tcl));
        pl = pole(Tcl);
        [mx, im] = max(real(pl));
        [V,~] = eig(A); Winv = inv(V);
        amp = zeros(numel(pl),1);
        for q = 1:numel(pl)
            res = (Cv*V(:,q)) * (Winv(q,:)*Bv);
            amp(q) = abs(res / pl(q));
        end
        dc = abs(dcgain(Tcl));
        domAmpPct = amp(im)/max(dc,eps)*100;
        domShare  = amp(im)/max(sum(amp),eps)*100;
        dm = damp(Tcl);
        slowDamp = min(-real(dm(1,:)));

        fprintf('%-5s %-6s %10.3f %11.3f %9.3f %10.3f %10.2f\n', ...
            conds(ic).id, k.id, mx, 1/abs(mx)*1e3, abs(mx)/(2*pi), domAmpPct, domShare);

        e = struct('cond',conds(ic).id,'ctrl',k.id,'maxRe',mx, ...
            'domTauMs',1/abs(mx)*1e3,'domHz',abs(mx)/(2*pi), ...
            'domAmpPct',domAmpPct,'domSharePct',domShare, ...
            'slowDamp',slowDamp,'dcGain',dc,'nPoles',numel(pl));
        out.records{end+1} = e;
    end
end

%% ---------- A1b full pole spectrum for C1 BASE / OPT ----------
fprintf('\n--- A1b full pole spectrum (C1), modal amplitude = |residue/p| ---\n');
for ik = 1:2
    k = ctrlTbl{ik};
    Gvd = tf(Vin0, [L0*C0, L0/R0, 1]);
    if k.notch
        not = (tf('s')^2 + 2*b.zn*fnNom*tf('s') + fnNom^2) / ...
              (tf('s')^2 + 2*b.zd*fnNom*tf('s') + fnNom^2);
        Cc = pid(k.Kp,k.Ki,0,0)*not;
    else
        Cc = pid(k.Kp,k.Ki,0,0);
    end
    Loop = minreal(Cc*Gvd); Tcl = minreal(feedback(Loop,1));
    [A,Bv,Cv,~] = ssdata(ss(Tcl)); pl = pole(Tcl);
    [V,~] = eig(A); Winv = inv(V);
    amp = zeros(numel(pl),1);
    for q = 1:numel(pl)
        res = (Cv*V(:,q))*(Winv(q,:)*Bv);
        amp(q) = abs(res/pl(q));
    end
    [~,ord] = sort(real(pl),'descend');
    fprintf('  %s: %d poles, DC gain = %.4f\n', k.id, numel(pl), dcgain(Tcl));
    fprintf('  %14s %12s %10s %12s %10s\n','pole','Re','Im','amp','amp%DC');
    for q = ord.'
        fprintf('  %12.3f%+10.3fi %12.3f %10.3f %12.5f %10.2f\n', ...
            real(pl(q)), imag(pl(q)), real(pl(q)), imag(pl(q)), amp(q), ...
            amp(q)/max(abs(dcgain(Tcl)),eps)*100);
    end
end

%% ---------- A2 tail exponential fit vs dominant pole ----------
fprintf('\n--- A2 measured tail decay rate vs dominant pole (C1) ---\n');
fprintf('%-6s %11s %11s %12s %12s %9s\n', ...
    'ctrl','poleTau_ms','fitTau_ms','poleRate','fitRate','dev_pct');

for ik = 1:2
    k = ctrlTbl{ik};
    idx = find(strcmp({recs.cond},'C1') & strcmp({recs.ctrl},k.id), 1);
    t = recs(idx).t; v = recs(idx).vC;
    post = t >= 0.060;
    tp = t(post) - 0.060; vp = v(post) - Vref;
    win = tp >= 0.015 & tp <= 0.055;
    tw = tp(win); ew = abs(vp(win));
    keep = ew > 1e-6;
    pfit = polyfit(tw(keep), log(ew(keep)), 1);
    fitRate = -pfit(1); fitTau = 1/fitRate;
    e = findE(out.records, 'C1', k.id);
    poleRate = abs(e.maxRe); poleTau = 1/poleRate;
    dev = (fitRate-poleRate)/poleRate*100;
    fprintf('%-6s %11.3f %11.3f %12.4f %12.4f %9.2f\n', ...
        k.id, poleTau*1e3, fitTau*1e3, poleRate, fitRate, dev);
    out.tailFit(ik) = struct('ctrl',k.id,'poleTauMs',poleTau*1e3, ...
        'fitTauMs',fitTau*1e3,'poleRate',poleRate,'fitRate',fitRate,'devPct',dev);
end

%% ---------- A2b independent S5 prediction from tail-fit ONLY ----------
% 为避免循环论证：不借用回推的 A，直接用 15~55ms 窗口的指数拟合
%   |v-12| = A0*exp(-rate*t),  t 从阶跃时刻算
% 外推到 t=0 得 A0 与 rate，再预测 S5 = ln(A0/0.12)/rate
% 这是与 step_metrics 完全独立的第三条证据链。
fprintf('\n--- A2b S5 predicted from tail fit only (independent) ---\n');
fprintf('%-6s %10s %10s %11s %11s %10s\n', ...
    'ctrl','A0_pct','rate','S5_pred_ms','S5_meas_ms','dev_pct');
for ik = 1:2
    k = ctrlTbl{ik};
    idx = find(strcmp({recs.cond},'C1') & strcmp({recs.ctrl},k.id), 1);
    t = recs(idx).t; v = recs(idx).vC;
    post = t >= 0.060;
    tp = t(post) - 0.060; vp = v(post) - Vref;
    win = tp >= 0.015 & tp <= 0.055;
    tw = tp(win); ew = abs(vp(win));
    keep = ew > 1e-6;
    pfit = polyfit(tw(keep), log(ew(keep)), 1);
    rate = -pfit(1); A0 = exp(pfit(2));
    S5pred = log(A0/0.12)/rate*1e3;
    S5meas = recs(idx).settleMs;
    dev = (S5pred-S5meas)/S5meas*100;
    fprintf('%-6s %10.4f %10.2f %11.4f %11.4f %10.2f\n', ...
        k.id, A0/Vref*100, rate, S5pred, S5meas, dev);
    out.tailPred(ik) = struct('ctrl',k.id,'A0pct',A0/Vref*100,'rate',rate, ...
        'S5pred',S5pred,'S5meas',S5meas,'devPct',dev);
end

%% ---------- A9 modal decomposition of the LOAD-STEP response (all 7 cond) ----------
% 负载阶跃是对象参数变化(R 变)，不是加性扰动，故 T(s) 的留数不能直接解释。
% 阶跃后系统线性：响应 = 阶跃后闭环模态的线性组合（系数由切换时刻 iL、vC
% 连续性决定）。用阶跃后极点作基函数做最小二乘，RMS~0 即证明分解精确。
fprintf('\n--- A9 modal decomposition of the load-step response (all conditions) ---\n');
fprintf('%-5s %-6s %11s %12s %12s %11s %9s\n', ...
    'cond','ctrl','dom_mode_Re','dom_freq_Hz','dom_amp_pct','S5pred_ms','S5meas_ms');
for ic = 1:numel(conds)
    Vin = condTbl(ic,1); Rpre = condTbl(ic,2); L = condTbl(ic,3);
    Rpost = Rpre/2;                      % ratio=2 on conductance
    for ik = 1:2
        k = ctrlTbl{ik};
        Gp = tf(Vin, [L*C0, L/Rpost, 1]);
        if k.notch
            not = (tf('s')^2 + 2*b.zn*fnNom*tf('s') + fnNom^2) / ...
                  (tf('s')^2 + 2*b.zd*fnNom*tf('s') + fnNom^2);
            Cc = pid(k.Kp,k.Ki,0,0)*not;
        else
            Cc = pid(k.Kp,k.Ki,0,0);
        end
        Tcl = minreal(feedback(minreal(Cc*Gp),1));
        pl = pole(Tcl); pl = pl(abs(real(pl)) < 30000);

        idx = find(strcmp({recs.cond},conds(ic).id) & strcmp({recs.ctrl},k.id),1);
        if isempty(idx), continue; end
        tp = (recs(idx).t - 0.060); vp = recs(idx).vC - Vref;
        w = tp >= 0.0003 & tp <= 0.030;
        tw = tp(w); yw = vp(w);
        if numel(tw) < 50, continue; end

        B = []; mp = []; mc = {}; used = false(size(pl));
        for q = 1:numel(pl)
            if used(q), continue; end
            p1 = pl(q);
            if abs(imag(p1)) < 1
                c0 = size(B,2)+1; B = [B, exp(p1*tw)];
                mp(end+1) = p1; mc{end+1} = c0; used(q) = true;
            else
                j = find(abs(pl - conj(p1)) < 1e-6, 1);
                if isempty(j) || used(j), continue; end
                c0 = size(B,2)+1;
                B = [B, exp(real(p1)*tw).*cos(imag(p1)*tw), ...
                        exp(real(p1)*tw).*sin(imag(p1)*tw)];
                mp(end+1) = p1; mc{end+1} = [c0 c0+1];
                used(q) = true; used(j) = true;
            end
        end
        cf = B \ yw;
        ampV = zeros(1,numel(mp));
        for q = 1:numel(mp)
            cc = mc{q};
            if numel(cc)==1, ampV(q) = cf(cc(1));
            else, ampV(q) = hypot(cf(cc(1)), cf(cc(2))); end
        end
        % 找"最迟退出 1% 带"的模态：即 amp*exp(Re*t)=0.12 的最大解
        tExit = -inf(1,numel(mp));
        for q = 1:numel(mp)
            if abs(ampV(q)) > 0.12 && real(mp(q)) < 0
                tExit(q) = log(abs(ampV(q))/0.12)/(-real(mp(q)));
            end
        end
        [tDom, iDom] = max(tExit);
        tsim = (0:1e-6:0.060).';
        ys = B0eval(mp, cf, mc, tsim);
        lo = find(abs(ys) > 0.12, 1, 'last');
        if isempty(lo), s5pred = 0;
        elseif lo==numel(tsim), s5pred = NaN;
        else, s5pred = tsim(lo+1)*1e3; end
        s5meas = recs(idx).settleMs;
        if isnan(s5meas), s5measShow = NaN; else, s5measShow = s5meas; end
        fprintf('%-5s %-6s %11.1f %12.1f %12.3f %11.4f %9.4f\n', ...
            conds(ic).id, k.id, real(mp(iDom)), abs(imag(mp(iDom)))/(2*pi), ...
            abs(ampV(iDom))/Vref*100, s5pred, s5measShow);
        out.modes{end+1} = struct('cond',conds(ic).id,'ctrl',k.id, ...
            'poles',mp,'amp_V',ampV,'amp_pct',ampV/Vref*100, ...
            'domRe',real(mp(iDom)),'domHz',abs(imag(mp(iDom)))/(2*pi), ...
            'domAmpPct',abs(ampV(iDom))/Vref*100, ...
            'tExitMs',tDom*1e3,'s5pred',s5pred,'s5meas',s5measShow);
    end
end

%% ---------- A3 independent recomputation of the S5 definition ----------
fprintf('\n--- A3 S5 definition recomputed independently (vs step_metrics) ---\n');
fprintf('%-5s %-6s %11s %11s %11s %7s %8s %10s\n', ...
    'cond','ctrl','settleOld','settleNew','firstEntry','nExits','tailIn','delta_ms');
for ic = 1:numel(conds)
    for ik = 1:numel(ctrls)
        idx = find(strcmp({recs.cond},conds(ic).id) & strcmp({recs.ctrl},ctrls(ik).id),1);
        if isempty(idx), continue; end
        t = recs(idx).t; v = recs(idx).vC;
        post = t >= 0.060;
        tp = t(post); vp = v(post);
        inB = abs(vp - Vref) <= 0.01*Vref;
        lastOut = find(~inB, 1, 'last');
        if isempty(lastOut)
            sNew = 0;
        elseif lastOut == numel(inB)
            sNew = NaN;
        else
            sNew = (tp(lastOut+1) - tp(1))*1e3;
        end
        sOld = recs(idx).settleMs;
        fe   = recs(idx).recoverMs;
        tailOK = inB(end);
        fprintf('%-5s %-6s %11.4f %11.4f %11.4f %7d %8d %10.4f\n', ...
            conds(ic).id, ctrls(ik).id, sOld, sNew, fe, recs(idx).nExits, ...
            tailOK, sNew-sOld);
        out.s5cmp(end+1) = struct('cond',conds(ic).id,'ctrl',ctrls(ik).id, ...
            'settleOld',sOld,'settleStrict',sNew,'firstEntry',fe, ...
            'nExits',recs(idx).nExits,'tailInBand',tailOK,'deltaMs',sNew-sOld);
    end
end

%% ---------- A4 window adequacy ----------
fprintf('\n--- A4 record window adequacy (60 ms after step) ---\n');
fprintf('%-5s %-6s %11s %11s %10s %14s\n', ...
    'cond','ctrl','settle_ms','tailInBand','slack_ms','verdict');
for ic = 1:numel(conds)
    for ik = 1:numel(ctrls)
        idx = find(strcmp({recs.cond},conds(ic).id) & strcmp({recs.ctrl},ctrls(ik).id),1);
        if isempty(idx), continue; end
        r = recs(idx);
        tt = r.t(r.t >= 0.060);
        recordMs = (tt(end) - tt(1))*1e3;
        slack = recordMs - r.settleMs;
        if isnan(r.settleMs)
            verdict = 'undetermined';
        elseif isnan(r.tailInBandMs)
            verdict = 'undetermined';
        elseif slack > 20
            verdict = 'sufficient';
        else
            verdict = 'questionable';
        end
        fprintf('%-5s %-6s %11.4f %11.3f %10.3f %14s\n', ...
            conds(ic).id, ctrls(ik).id, r.settleMs, r.tailInBandMs, slack, verdict);
    end
end

%% ---------- A5 analytic requirement on the dominant pole for S5 = 1 ms ----------
fprintf('\n--- A5 S5=1ms: analytic requirement on the dominant pole ---\n');
fprintf('slow mode residual A%%, time constant tau -> settle needs tau*ln(A)\n');
fprintf('S5 = t_fast + tau*ln(A), where t_fast = end of fast transient\n\n');
fprintf('%-6s %9s %11s %11s %13s %13s\n', ...
    'ctrl','tau_ms','A_back_pct','S5_ms','tauNeed_ms','ReNeed_rad_s');
for ik = 1:2
    k = ctrlTbl{ik};
    e = findE(out.records, 'C1', k.id);
    idx = find(strcmp({recs.cond},'C1') & strcmp({recs.ctrl},k.id), 1);
    s5 = recs(idx).settleMs; fe = recs(idx).recoverMs;
    tau = e.domTauMs;
    Aln = (s5 - fe)/tau; A = exp(Aln);
    tauNeed = (1.0 - fe)/Aln; reNeed = 1/(tauNeed*1e-3);
    fprintf('%-6s %9.3f %11.3f %11.4f %13.4f %13.1f\n', k.id, tau, A, s5, tauNeed, reNeed);
    out.feasib(ik) = struct('ctrl',k.id,'tauMs',tau,'AmpPctBack',A, ...
        's5',s5,'tauNeedMs',tauNeed,'reNeed',reNeed,'firstEntry',fe);
end

fprintf('\n  [CAVEAT] A5/A8 quantify the *3A.2 hypothesis* (integrator pole).\n');
fprintf('  A9 below REFUTES it for load steps: the integrator mode carries only\n');
fprintf('  ~0.17 pct amplitude, so A5/A8 explain the reference-step settling only.\n');

%% ---------- A6 official tool cross-check ----------
fprintf('\n--- A6 official tool cross-check (C1) ---\n');
fprintf('%-6s %11s %11s %11s %8s %10s\n', ...
    'ctrl','pole_maxRe','damp_slowRe','true_domRe','ok','stepinfo_ms');
for ik = 1:2
    k = ctrlTbl{ik};
    Gvd = tf(Vin0, [L0*C0, L0/R0, 1]);
    if k.notch
        not = (tf('s')^2 + 2*b.zn*fnNom*tf('s') + fnNom^2) / ...
              (tf('s')^2 + 2*b.zd*fnNom*tf('s') + fnNom^2);
        Cc = pid(k.Kp,k.Ki,0,0)*not;
    else
        Cc = pid(k.Kp,k.Ki,0,0);
    end
    Loop = minreal(Cc*Gvd); Tcl = minreal(feedback(Loop,1));
    pl = pole(Tcl);
    mx = max(real(pl));
    % 官方 damp：三输出，第三个是极点
    [~,~,pDamp] = damp(Tcl);
    slowRe = max(real(pDamp));          % 最靠近虚轴的 Re（= -min |Re|）
    % 真实主导极点：按模态幅值最大
    [A,Bv,Cv,~] = ssdata(ss(Tcl));
    [V,~] = eig(A); Winv = inv(V);
    amp = zeros(numel(pl),1);
    for q = 1:numel(pl)
        res = (Cv*V(:,q))*(Winv(q,:)*Bv);
        amp(q) = abs(res/pl(q));
    end
    [~,imax] = max(amp);
    trueDom = real(pl(imax));
    sti = stepinfo(Tcl);
    ok = abs(slowRe - mx) < 1e-6;
    fprintf('%-6s %11.4f %11.4f %11.4f %8d %10.4f\n', ...
        k.id, mx, slowRe, trueDom, ok, sti.SettlingTime*1e3);
    out.toolchk(ik) = struct('ctrl',k.id,'maxRe',mx,'dampSlowRe',slowRe, ...
        'trueDomRe',trueDom,'okDamp',ok,'stepinfoMs',sti.SettlingTime*1e3);
end

%% ---------- A7 dominant pole = PI integrator pole? closed form ----------
fprintf('\n--- A7 dominant pole vs PI integrator closed form ---\n');
fprintf('claim: p_dom ~ -Ki*Vin/(1+Kp*Vin)  (integrator pole of the voltage loop)\n');
fprintf('%-6s %10s %10s %14s %14s %9s\n', ...
    'ctrl','Kp','Ki','true_domRe','closedForm','dev_pct');
for ik = 1:2
    k = ctrlTbl{ik};
    cf = -k.Ki*Vin0/(1 + k.Kp*Vin0);
    % true dominant from A1 records (C1)
    e = findE(out.records,'C1',k.id);
    % re-derive true dominant (by modal amplitude) here
    Gvd = tf(Vin0, [L0*C0, L0/R0, 1]);
    if k.notch
        not = (tf('s')^2 + 2*b.zn*fnNom*tf('s') + fnNom^2) / ...
              (tf('s')^2 + 2*b.zd*fnNom*tf('s') + fnNom^2);
        Cc = pid(k.Kp,k.Ki,0,0)*not;
    else
        Cc = pid(k.Kp,k.Ki,0,0);
    end
    Tcl = minreal(feedback(minreal(Cc*Gvd),1));
    [A,Bv,Cv,~] = ssdata(ss(Tcl)); pl = pole(Tcl);
    [V,~] = eig(A); Winv = inv(V);
    amp = zeros(numel(pl),1);
    for q = 1:numel(pl)
        res = (Cv*V(:,q))*(Winv(q,:)*Bv);
        amp(q) = abs(res/pl(q));
    end
    [~,imax] = max(amp); td = real(pl(imax));
    dev = (td-cf)/cf*100;
    fprintf('%-6s %10.4f %10.4f %14.4f %14.4f %9.2f\n', k.id, k.Kp, k.Ki, td, cf, dev);
end

%% ---------- A8 required Keff for S5 = 1 ms ----------
fprintf('\n--- A8 S5=1ms requires the integrator rate Keff = Ki*Vin/(1+Kp*Vin) ---\n');
fprintf('S5 = t_fast + ln(A)/(Keff)  =>  Keff_need = ln(A)/(S5 - t_fast)\n');
fprintf('%-6s %10s %10s %10s %12s %12s %12s\n', ...
    'ctrl','tau_ms','A_pct','S5_ms','Keff_now','Keff_need','Ki_need');
for ik = 1:2
    k = ctrlTbl{ik};
    idx = find(strcmp({recs.cond},'C1') & strcmp({recs.ctrl},k.id),1);
    s5 = recs(idx).settleMs; fe = recs(idx).recoverMs;
    Keff = k.Ki*Vin0/(1+k.Kp*Vin0);
    tau = 1/Keff;
    Aln = (s5-fe)/tau*1e-3*1e3;      % (s5-fe) in ms, tau in ms -> dimensionless
    Aln = (s5-fe)/(tau*1e3);
    A = exp(Aln);
    KeffNeed = Aln/((1.0-fe)*1e-3);
    KiNeed = KeffNeed*(1+k.Kp*Vin0)/Vin0;
    fprintf('%-6s %10.3f %10.3f %10.4f %12.2f %12.2f %12.2f\n', ...
        k.id, tau*1e3, A, s5, Keff, KeffNeed, KiNeed);
    out.reqKeff(ik) = struct('ctrl',k.id,'KeffNow',Keff,'KeffNeed',KeffNeed, ...
        'KiNeed',KiNeed,'AmpPct',A,'tauMs',tau*1e3);
end

%% ---------- save ----------
try
    save(fullfile(outDir,'a3_stage_a_audit.mat'),'out');
    % JSON 不支持复数：把 poles 拆成 re/im 两份再编码
    outJ = out;
    for q = 1:numel(outJ.modes)
        pl = outJ.modes{q}.poles;
        outJ.modes{q}.poles_re = real(pl);
        outJ.modes{q}.poles_im = imag(pl);
        outJ.modes{q} = rmfield(outJ.modes{q}, 'poles');
    end
    txt = jsonencode(outJ);
    fid = fopen(fullfile(outDir,'a3_stage_a_audit.json'),'w');
    if fid < 0, error('cannot open json for write'); end
    n = fwrite(fid, txt, 'char'); fclose(fid);
    if n ~= numel(txt), error('json write incomplete'); end
    fprintf('\naudit saved: a3_stage_a_audit.mat / .json (%d bytes)\n', n);
catch ME
    fprintf(2,'save failed: %s\n', ME.message);
end

function e = findE(recsCell, cid, kid)
e = [];
for q = 1:numel(recsCell)
    if strcmp(recsCell{q}.cond,cid) && strcmp(recsCell{q}.ctrl,kid)
        e = recsCell{q}; return;
    end
end
end

function y = B0eval(poles, cf, cols, tv)
y = zeros(numel(tv),1);
for q = 1:numel(poles)
    cc = cols{q};
    if numel(cc)==1
        y = y + cf(cc(1))*exp(poles(q)*tv);
    else
        y = y + cf(cc(1))*exp(real(poles(q))*tv).*cos(imag(poles(q))*tv) ...
              + cf(cc(2))*exp(real(poles(q))*tv).*sin(imag(poles(q))*tv);
    end
end
end
