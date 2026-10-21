function out = cd_s1_ofdm()
%CD_S1_OFDM  Signal (held-out): OFDM/QPSK BER must match theory at 0/4/8 dB.
%
% Exercises mas_ofdm_ber, which itself runs the full OFDM chain (modulate,
% AWGN, demodulate, count bit errors) against the closed-form QPSK BER
% Q(sqrt(2*Eb/N0)). The task reports only the simulated BER at three Eb/N0
% points; the frozen reference grades it against the erfc formula, so the
% task's own verdict is not what is believed.

r = mas_ofdm_ber([0 4 8]);

out.values = struct('ber0', r.berSim(1), 'ber4', r.berSim(2), 'ber8', r.berSim(3));
out.reference = struct('ber0', r.berTheory(1), 'ber4', r.berTheory(2), 'ber8', r.berTheory(3));
out.status = tern(strcmp(r.verdict, 'PASS'), 'PASS', 'FAIL');
out.detail = r.detail;
end

function s = tern(c, a, b)
if c, s = a; else, s = b; end
end
