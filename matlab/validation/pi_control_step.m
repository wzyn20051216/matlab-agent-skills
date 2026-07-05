function y = pi_control_step(ref, meas, state)
%PI_CONTROL_STEP Simple PI controller step for code generation smoke tests.

arguments
    ref (1,1) double
    meas (1,1) double
    state (1,1) struct
end

errorValue = ref - meas;
integrator = state.integrator + errorValue * state.Ts;
y = state.Kp * errorValue + state.Ki * integrator;
end
