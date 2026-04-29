function params_fb = init_fankuiwei_params()
%INIT_FANKUIWEI_PARAMS Initialize inter-layer feedback parameters.
% All feedback parameters are centralized here. Other scripts should read
% these fields instead of hard-coding another parameter set.
params_fb.case_name = 'scheme_B_norm_deadband8_traj_warning_no_asym';

%% 1. Device limits reused by the feedback layer
params_fb.PM_min = -5;
params_fb.PM_max = 10;

try
    battery = batteryModel();
    params_fb.PB_min = battery.power(1, 2);
    params_fb.PB_max = battery.power(1, 1);
catch
    warning('fankuiwei:paramFallback', ...
        'batteryModel() is not available. Feedback parameters use fallback device limits.');
    params_fb.PB_min = -4;
    params_fb.PB_max = 4;
end

%% 2. SOC hard bounds, soft risk bounds and targets
% The feedback layer uses per-unit SOC. If a trajectory is stored as 0-100,
% fcnEvaluateLowerFeedback converts these bounds to the same scale.
params_fb.SOC_B_hard_min = 0.10;
params_fb.SOC_B_hard_max = 0.90;
params_fb.SOC_B_soft_min = 0.15;
params_fb.SOC_B_soft_max = 0.85;
params_fb.SOC_B_target = 0.50;

params_fb.SOC_SC_hard_min = 0.00;
params_fb.SOC_SC_hard_max = 1.00;
params_fb.SOC_SC_soft_min = 0.20;
params_fb.SOC_SC_soft_max = 0.80;
params_fb.SOC_SC_target = 0.50;
params_fb.SOC_scale = 1;
params_fb = sanitize_soc_bounds(params_fb);

%% 3. EPL weights for restored scheme B
% z_M/z_B are normalized before entering EPL_micro, so alpha_z penalizes a
% dimensionless request rather than raw power. Scheme B keeps the normalized
% deadband-8 family and trajectory warning, but disables asymmetric warning.
params_fb.alpha_track = 2.2;
params_fb.alpha_SC = 2.6;
params_fb.alpha_B = 2.8;
params_fb.alpha_SC_warning = 2.4;
params_fb.alpha_z = 0.35;

%% 4. z_M / z_B component weights
params_fb.k_M_track = 0.55;
params_fb.k_M_SC = 0.95;
params_fb.k_M_balance = 0.60;
params_fb.k_B_track = 0.65;
params_fb.k_B_SC = 0.25;
params_fb.k_B_safe = 1.25;

params_fb.enable_M_track = true;
params_fb.enable_M_SC = true;
params_fb.enable_M_balance = true;
params_fb.enable_B_track = true;
params_fb.enable_B_SC = true;
params_fb.enable_B_safe = true;

%% 5. Feedback trigger parameters
% Deadband 8.5 preserves the norm_deadband8 risk benefit but slightly
% reduces over-frequent feedback.
params_fb.EPL_deadband = 8.5;
params_fb.EPL_hysteresis = 3.0;
params_fb.min_feedback_interval = 2;
params_fb.max_active_ratio_target = 0.5;

%% 6. Negotiation weights
% lambda_cost=3.3 suppresses large reference corrections to repair tracking.
params_fb.lambda_loss = 1.0;
params_fb.lambda_cost = 3.3;
params_fb.lambda_M = 1.0;
params_fb.lambda_B = 1.0;
params_fb.eps_denom = 1e-6;

%% 7. Correction amplitude and adjacent-step rate limits
params_fb.ratio_PM = 0.10;
params_fb.ratio_PB = 0.052;
params_fb.delta_PM_max = params_fb.ratio_PM * (params_fb.PM_max - params_fb.PM_min);
params_fb.delta_PB_max = params_fb.ratio_PB * (params_fb.PB_max - params_fb.PB_min);

% The rate limits constrain adjacent dispatched references after projection.
params_fb.delta_PM_rate_max = 0.55;
params_fb.delta_PB_rate_max = 0.22;
params_fb.rate_PM_max = params_fb.delta_PM_rate_max;
params_fb.rate_PB_max = params_fb.delta_PB_rate_max;

%% 8. SC SOC warning feedback
% These warning bounds are only for early feedback. Final SC risk metrics
% still use SOC_SC_soft_min/max = 0.20/0.80.
params_fb.enable_SC_warning_feedback = true;
params_fb.use_SC_trajectory_extreme_warning = true;
params_fb.SOC_SC_warning_min = 0.26;
params_fb.SOC_SC_warning_max = 0.75;
params_fb.k_SC_warning_M = 1.10;
params_fb.k_SC_warning_B = 0.18;
params_fb.SC_warning_clip = 1.0;
params_fb.use_smooth_SC_warning = true;
params_fb.use_asymmetric_SC_warning = false;
params_fb.k_SC_warning_M_low = 1.20;
params_fb.k_SC_warning_M_high = 0.90;
params_fb.k_SC_warning_B_low = 0.22;
params_fb.k_SC_warning_B_high = 0.14;
params_fb.alpha_SC_warning_low = 2.6;
params_fb.alpha_SC_warning_high = 1.8;

%% 9. z normalization
params_fb.enable_z_normalization = true;
params_fb.z_norm_clip = 3.5;
params_fb.use_soft_z_saturation = true;
params_fb.e_track_scale = 1.0;
params_fb.EPL_mode = 'legacy';
params_fb.use_normalized_EPL = false;
params_fb.e_track_base = 1.0;
params_fb.r_SC_base = 1.0;
params_fb.r_B_base = 1.0;
params_fb.z_M_base = params_fb.PM_max - params_fb.PM_min;
params_fb.z_B_base = params_fb.PB_max - params_fb.PB_min;
params_fb.EPL_warning_base = 1.0;
params_fb.alpha_track_norm = 1.0;
params_fb.alpha_SC_norm = 1.0;
params_fb.alpha_B_norm = 1.0;
params_fb.alpha_z_norm = 0.2;
params_fb.alpha_warn_norm = 0.1;

params_fb.enable_feedback = true;
params_fb.enable_plot = true;
params_fb.verbose = true;

%% 10. 事件触发式多时间尺度反馈 MPC 参数
% event 参数组只被 main_event_feedback_mpc.m 及事件版 OCP 使用，
% 不改变 original 和 rolling_feedback 的原有滚动反馈运行逻辑。
params_fb.event.enable = true;
params_fb.event.mode = 'event_triggered_mts_mpc';

% 事件触发阈值：EPL_on 是进入事件重算的开启阈值，EPL_off 是滞环退出阈值。
params_fb.event.EPL_on = 10.0;
params_fb.event.EPL_off = 6.0;
params_fb.event.track_on = 0.4;

% SOC 软安全边界。下层状态使用百分数制，因此这里采用 0~100 的物理量纲。
params_fb.event.SC_soft_min = 35;
params_fb.event.SC_soft_max = 65;
params_fb.event.B_soft_min = 20;
params_fb.event.B_soft_max = 80;

% 触发频率限制，避免 5 分钟尺度下过于频繁地调用上层重优化。
params_fb.event.min_event_interval = 2;
params_fb.event.max_event_per_upper = 1;
params_fb.event.min_remaining_steps = 3;

% 事件版上层 OCP 中反馈风险、参考调整和调节平滑项的权重。
params_fb.event.beta_feedback = 1.0;
params_fb.event.beta_adjust = 0.2;
params_fb.event.beta_z = 0.1;
params_fb.event.beta_smooth = 0.05;

% 事件触发后参考轨迹更新参数。reference_blend 越大，越信任事件重优化结果。
params_fb.event.reference_blend = 0.7;
params_fb.event.z_decay = 0.85;

% 上层事件重算失败时，回退到已有规则型参考修正，保证仿真不中断。
params_fb.event.enable_fallback_rule = true;
end

function params_fb = sanitize_soc_bounds(params_fb)
margin_B = 0.05 * (params_fb.SOC_B_hard_max - params_fb.SOC_B_hard_min);
margin_SC = 0.05 * (params_fb.SOC_SC_hard_max - params_fb.SOC_SC_hard_min);

if params_fb.SOC_B_soft_min <= params_fb.SOC_B_hard_min
    params_fb.SOC_B_soft_min = params_fb.SOC_B_hard_min + margin_B;
    warning('fankuiwei:SOCBoundAdjusted', 'SOC_B_soft_min was adjusted inside the hard bound.');
end
if params_fb.SOC_B_soft_max >= params_fb.SOC_B_hard_max
    params_fb.SOC_B_soft_max = params_fb.SOC_B_hard_max - margin_B;
    warning('fankuiwei:SOCBoundAdjusted', 'SOC_B_soft_max was adjusted inside the hard bound.');
end
if params_fb.SOC_SC_soft_min <= params_fb.SOC_SC_hard_min
    params_fb.SOC_SC_soft_min = params_fb.SOC_SC_hard_min + margin_SC;
    warning('fankuiwei:SOCBoundAdjusted', 'SOC_SC_soft_min was adjusted inside the hard bound.');
end
if params_fb.SOC_SC_soft_max >= params_fb.SOC_SC_hard_max
    params_fb.SOC_SC_soft_max = params_fb.SOC_SC_hard_max - margin_SC;
    warning('fankuiwei:SOCBoundAdjusted', 'SOC_SC_soft_max was adjusted inside the hard bound.');
end

params_fb.SOC_B_target = min(max(params_fb.SOC_B_target, ...
    params_fb.SOC_B_soft_min), params_fb.SOC_B_soft_max);
params_fb.SOC_SC_target = min(max(params_fb.SOC_SC_target, ...
    params_fb.SOC_SC_soft_min), params_fb.SOC_SC_soft_max);
end
