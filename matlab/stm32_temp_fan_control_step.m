function [u, nextState] = stm32_temp_fan_control_step(setpoint, measurement, state)
%STM32_TEMP_FAN_CONTROL_STEP STM32F103C8T6 温控风扇 PID 步进函数。
% @brief 根据设定温度和测量温度计算风扇 PWM 控制量。
% @param setpoint 设定温度，单位 degC。
% @param measurement 测量温度，单位 degC。
% @param state 控制器状态和参数结构体。
% @return u 风扇 PWM 占空比，范围由 state.uMin/state.uMax 限定。
% @return nextState 更新后的控制器状态。

error = setpoint - measurement;
nextState = state;
nextState.integrator = state.integrator + state.Ts * state.Ki * error;
derivative = (error - state.previousError) / state.Ts;

rawControl = state.Kp * error + nextState.integrator + state.Kd * derivative;
u = min(max(rawControl, state.uMin), state.uMax);
nextState.previousError = error;
end
