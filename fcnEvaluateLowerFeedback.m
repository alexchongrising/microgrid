function feedback = fcnEvaluateLowerFeedback(snd, params_fb)
%FCNEVALUATELOWERFEEDBACK 评估下层 EMS 执行困难程度并生成反馈请求。
%
% 输入:
%   snd       下层结构体，优先使用 snd.u、snd.u0_ref、snd.x。
%   params_fb 反馈机制参数。
%
% 输出:
%   feedback 包含跟踪误差、SOC 风险、EPL_micro、z_M/z_B 总量及分量。

feedback = init_feedback();

u = extract_matrix(snd, 'u', 'u_dyn');
if isempty(u)
    warning('fankuiwei:missingLowerU', ...
        'Cannot find snd.u or snd.u_dyn. Feedback is inactive.');
    return;
end
u = orient_time_by_row(u, 3);

N = size(u, 1);
PM_lower = rowvec(u(:, 1));
PB_lower = safe_column_as_row(u, 2, N);
PSC_lower = safe_column_as_row(u, 3, N);

u0_ref = extract_matrix(snd, 'u0_ref', '');
[PM_ref, PB_ref] = extract_reference(u0_ref, PM_lower, PB_lower, N);

eM = PM_lower - PM_ref;
eB = PB_lower - PB_ref;
feedback.e_track = sum(eM.^2 + eB.^2);
feedback.eM_mean = mean_without_nan(eM);
feedback.eB_mean = mean_without_nan(eB);

x = extract_matrix(snd, 'x', 'x_dyn');
x = orient_time_by_row(x, 3);
[SOC_B, SOC_SC] = extract_soc(x, N);
[bounds, SOC_B, SOC_SC] = scaled_soc_bounds(SOC_B, SOC_SC, params_fb);

feedback.SOC_B_hist = SOC_B;
feedback.SOC_SC_hist = SOC_SC;

if ~isempty(SOC_B)
    [feedback.r_B, feedback.r_B_inst] = normalized_soc_risk( ...
        SOC_B, bounds.B_hard_min, bounds.B_hard_max, ...
        bounds.B_soft_min, bounds.B_soft_max);
    feedback.SOC_B_end = SOC_B(end);
else
    warning('fankuiwei:missingBatterySOC', ...
        'Cannot find battery SOC as snd.x(:,2). r_B is set to zero.');
end

if ~isempty(SOC_SC)
    [feedback.r_SC, feedback.r_SC_inst] = normalized_soc_risk( ...
        SOC_SC, bounds.SC_hard_min, bounds.SC_hard_max, ...
        bounds.SC_soft_min, bounds.SC_soft_max);
    feedback.SOC_SC_min = min(SOC_SC);
    feedback.SOC_SC_max = max(SOC_SC);
    feedback.SOC_SC_end = SOC_SC(end);
else
    warning('fankuiwei:missingSCSOC', ...
        'Cannot find supercapacitor SOC as snd.x(:,3). r_SC is set to zero.');
end

%% z_M / z_B 物理来源拆分
% z_M_track: 电网功率跟踪误差。
z_M_track = params_fb.k_M_track * feedback.eM_mean;

% z_M_SC: 超级电容偏离目标时，少量请求电网侧也参与恢复裕度。
z_M_SC = 0;
if ~isnan(feedback.SOC_SC_end)
    z_M_SC = params_fb.k_M_SC * (bounds.SC_target - feedback.SOC_SC_end);
end

% z_M_balance: 下层超级电容平均出力越大，说明存在预测误差/功率平衡压力。
z_M_balance = params_fb.k_M_balance * mean_without_nan(PSC_lower);

% z_B_track: 电池功率跟踪误差。
z_B_track = params_fb.k_B_track * feedback.eB_mean;

% z_B_SC: 超级电容 SOC 偏离目标时，让电池在下一轮帮助恢复调节裕度。
% 原动态中 PB>0 会降低电池 SOC，因此这里用负号表达“低 SOC 时请求减少放电/增加充电”。
z_B_SC = 0;
if ~isnan(feedback.SOC_SC_end)
    z_B_SC = -params_fb.k_B_SC * (bounds.SC_target - feedback.SOC_SC_end);
end

% z_B_safe: 电池 SOC 偏离目标时，抑制进一步接近边界。
z_B_safe = 0;
if ~isnan(feedback.SOC_B_end)
    z_B_safe = -params_fb.k_B_safe * (bounds.B_target - feedback.SOC_B_end);
end

[s_SC_warning, z_M_SC_warning, z_B_SC_warning, s_SC_low, s_SC_high, ...
    SC_warning_source_id, SC_warning_fallback, k_warning_M_used, ...
    k_warning_B_used, alpha_warning_used, EPL_warning] = compute_sc_warning( ...
    feedback.SOC_SC_hist, feedback.SOC_SC_end, bounds, params_fb);
z_M_SC = z_M_SC + z_M_SC_warning;
z_B_SC = z_B_SC + z_B_SC_warning;
feedback.s_SC_low = s_SC_low;
feedback.s_SC_high = s_SC_high;
feedback.s_SC_warning = s_SC_warning;
feedback.SC_warning_source_id = SC_warning_source_id;
feedback.SC_warning_fallback = SC_warning_fallback;
feedback.use_asymmetric_SC_warning = read_optional(params_fb, 'use_asymmetric_SC_warning', false);
feedback.k_warning_M_used = k_warning_M_used;
feedback.k_warning_B_used = k_warning_B_used;
feedback.alpha_warning_used = alpha_warning_used;
feedback.EPL_warning = EPL_warning;
feedback.z_M_SC_warning = z_M_SC_warning;
feedback.z_B_SC_warning = z_B_SC_warning;

raw_components = struct();
raw_components.z_M_track = z_M_track;
raw_components.z_M_SC = z_M_SC;
raw_components.z_M_balance = z_M_balance;
raw_components.z_B_track = z_B_track;
raw_components.z_B_SC = z_B_SC;
raw_components.z_B_safe = z_B_safe;
raw_components.s_SC_warning = s_SC_warning;
raw_components.s_SC_low = s_SC_low;
raw_components.s_SC_high = s_SC_high;
raw_components.SC_warning_source_id = SC_warning_source_id;
raw_components.k_warning_M_used = k_warning_M_used;
raw_components.k_warning_B_used = k_warning_B_used;
raw_components.alpha_warning_used = alpha_warning_used;
raw_components.EPL_warning = EPL_warning;
raw_components.z_M_SC_warning = z_M_SC_warning;
raw_components.z_B_SC_warning = z_B_SC_warning;
feedback.raw_components = raw_components;

% 消融开关：关闭后该项参与总请求时置零，但 raw_components 中仍保留原始值。
if ~params_fb.enable_M_track,   z_M_track = 0; end
if ~params_fb.enable_M_SC,      z_M_SC = 0; end
if ~params_fb.enable_M_balance, z_M_balance = 0; end
if ~params_fb.enable_B_track,   z_B_track = 0; end
if ~params_fb.enable_B_SC,      z_B_SC = 0; end
if ~params_fb.enable_B_safe,    z_B_safe = 0; end

feedback.components = struct();
feedback.components.z_M_track = z_M_track;
feedback.components.z_M_SC = z_M_SC;
feedback.components.z_M_balance = z_M_balance;
feedback.components.z_M_SC_warning = z_M_SC_warning;
feedback.components.z_M_total = z_M_track + z_M_SC + z_M_balance;
feedback.components.z_B_track = z_B_track;
feedback.components.z_B_SC = z_B_SC;
feedback.components.z_B_safe = z_B_safe;
feedback.components.z_B_SC_warning = z_B_SC_warning;
feedback.components.z_B_total = z_B_track + z_B_SC + z_B_safe;

% 兼容旧变量名。
feedback.z_M = feedback.components.z_M_total;
feedback.z_M = feedback.components.z_M_total;
feedback.z_B = feedback.components.z_B_total;
feedback.z_M_total = feedback.components.z_M_total;
feedback.z_B_total = feedback.components.z_B_total;
feedback.z_M_SC = feedback.components.z_M_SC;
feedback.z_B_SC = feedback.components.z_B_SC;

if ~isfield(params_fb, 'delta_PM_max') || isempty(params_fb.delta_PM_max)
    params_fb.delta_PM_max = params_fb.ratio_PM * (params_fb.PM_max - params_fb.PM_min);
end
if ~isfield(params_fb, 'delta_PB_max') || isempty(params_fb.delta_PB_max)
    params_fb.delta_PB_max = params_fb.ratio_PB * (params_fb.PB_max - params_fb.PB_min);
end
if ~isfield(params_fb, 'z_norm_clip') || isempty(params_fb.z_norm_clip)
    params_fb.z_norm_clip = 3.8;
end
if ~isfield(params_fb, 'use_soft_z_saturation') || isempty(params_fb.use_soft_z_saturation)
    params_fb.use_soft_z_saturation = true;
end
if ~isfield(params_fb, 'e_track_scale') || isempty(params_fb.e_track_scale)
    params_fb.e_track_scale = 1.0;
end

% Raw z_M/z_B remain physical power requests. The legacy normalization is
% kept for backward-compatible diagnostics; event experiments can optionally
% use the normalized EPL fields below as the control signal.
feedback.z_M_norm = feedback.z_M / max(params_fb.delta_PM_max, eps);
feedback.z_B_norm = feedback.z_B / max(params_fb.delta_PB_max, eps);
if params_fb.use_soft_z_saturation
    feedback.z_M_norm_clipped = params_fb.z_norm_clip * tanh(feedback.z_M_norm / params_fb.z_norm_clip);
    feedback.z_B_norm_clipped = params_fb.z_norm_clip * tanh(feedback.z_B_norm / params_fb.z_norm_clip);
else
    feedback.z_M_norm_clipped = min(max(feedback.z_M_norm, -params_fb.z_norm_clip), params_fb.z_norm_clip);
    feedback.z_B_norm_clipped = min(max(feedback.z_B_norm, -params_fb.z_norm_clip), params_fb.z_norm_clip);
end
feedback.e_track_norm = feedback.e_track / max(params_fb.e_track_scale, eps);

feedback.EPL_track_legacy = params_fb.alpha_track * feedback.e_track_norm;
feedback.EPL_SC_legacy = params_fb.alpha_SC * feedback.r_SC;
feedback.EPL_B_legacy = params_fb.alpha_B * feedback.r_B;
feedback.EPL_z_legacy = params_fb.alpha_z * ...
    (feedback.z_M_norm_clipped^2 + feedback.z_B_norm_clipped^2);
feedback.EPL_warning_legacy = feedback.EPL_warning;
feedback.EPL_micro_legacy = feedback.EPL_track_legacy + ...
    feedback.EPL_SC_legacy + feedback.EPL_B_legacy + ...
    feedback.EPL_warning_legacy + feedback.EPL_z_legacy;

[bases, norm_weight] = normalized_epl_settings(params_fb);
feedback.e_track_base = bases.e_track_base;
feedback.r_SC_base = bases.r_SC_base;
feedback.r_B_base = bases.r_B_base;
feedback.z_M_base = bases.z_M_base;
feedback.z_B_base = bases.z_B_base;
feedback.EPL_warning_base = bases.warning_base;

feedback.e_track_norm_EPL = feedback.e_track / max(bases.e_track_base, eps);
feedback.r_SC_norm_EPL = feedback.r_SC / max(bases.r_SC_base, eps);
feedback.r_B_norm_EPL = feedback.r_B / max(bases.r_B_base, eps);
feedback.z_M_norm_EPL = feedback.z_M / max(bases.z_M_base, eps);
feedback.z_B_norm_EPL = feedback.z_B / max(bases.z_B_base, eps);
feedback.EPL_warning_signal = warning_signal_for_epl(feedback);
feedback.EPL_warning_norm_raw = feedback.EPL_warning_signal / max(bases.warning_base, eps);

feedback.EPL_track_norm = norm_weight.alpha_track * feedback.e_track_norm_EPL^2;
feedback.EPL_SC_norm = norm_weight.alpha_SC * feedback.r_SC_norm_EPL^2;
feedback.EPL_B_norm = norm_weight.alpha_B * feedback.r_B_norm_EPL^2;
feedback.EPL_z_norm = norm_weight.alpha_z * ...
    (feedback.z_M_norm_EPL^2 + feedback.z_B_norm_EPL^2);
feedback.EPL_warning_norm = norm_weight.alpha_warn * feedback.EPL_warning_norm_raw^2;
feedback.EPL_micro_norm = feedback.EPL_track_norm + feedback.EPL_SC_norm + ...
    feedback.EPL_B_norm + feedback.EPL_z_norm + feedback.EPL_warning_norm;

feedback.EPL_mode_used = read_optional(params_fb, 'EPL_mode', 'legacy');
if read_optional(params_fb, 'use_normalized_EPL', false) || strcmpi(feedback.EPL_mode_used, 'normalized')
    feedback.EPL_mode_used = 'normalized';
    feedback.EPL_micro_used = feedback.EPL_micro_norm;
else
    feedback.EPL_mode_used = 'legacy';
    feedback.EPL_micro_used = feedback.EPL_micro_legacy;
end
feedback.EPL_micro = feedback.EPL_micro_used;

if feedback.EPL_micro_used > 10 * (params_fb.EPL_deadband + params_fb.EPL_hysteresis)
    warning('fankuiwei:largeNormalizedEPL', ...
        'EPL_micro_used %.4g is much larger than deadband %.4g. Consider recalibrating EPL_deadband.', ...
        feedback.EPL_micro_used, params_fb.EPL_deadband);
end

% active 只是初步候选，最终是否触发由 fcnNegotiateFeedback 的死区/滞回/间隔决定。
feedback.active_candidate = feedback.EPL_micro > params_fb.EPL_deadband;
feedback.active_candidate = feedback.EPL_micro > params_fb.EPL_deadband;
feedback.active = feedback.active_candidate;

end

function feedback = init_feedback()
feedback = struct();
feedback.e_track = 0;
feedback.eM_mean = 0;
feedback.eB_mean = 0;
feedback.r_SC = 0;
feedback.r_B = 0;
feedback.r_SC_inst = [];
feedback.r_B_inst = [];
feedback.EPL_micro = 0;
feedback.EPL_micro_legacy = 0;
feedback.EPL_track_legacy = 0;
feedback.EPL_SC_legacy = 0;
feedback.EPL_B_legacy = 0;
feedback.EPL_z_legacy = 0;
feedback.EPL_warning_legacy = 0;
feedback.EPL_micro_norm = 0;
feedback.EPL_track_norm = 0;
feedback.EPL_SC_norm = 0;
feedback.EPL_B_norm = 0;
feedback.EPL_z_norm = 0;
feedback.EPL_warning_norm = 0;
feedback.EPL_micro_used = 0;
feedback.EPL_mode_used = 'legacy';
feedback.e_track_base = 1;
feedback.r_SC_base = 1;
feedback.r_B_base = 1;
feedback.z_M_base = 1;
feedback.z_B_base = 1;
feedback.EPL_warning_base = 1;
feedback.e_track_norm_EPL = 0;
feedback.r_SC_norm_EPL = 0;
feedback.r_B_norm_EPL = 0;
feedback.z_M_norm_EPL = 0;
feedback.z_B_norm_EPL = 0;
feedback.EPL_warning_signal = 0;
feedback.EPL_warning_norm_raw = 0;
feedback.z_M = 0;
feedback.z_B = 0;
feedback.e_track_norm = 0;
feedback.z_M_norm = 0;
feedback.z_B_norm = 0;
feedback.z_M_norm_clipped = 0;
feedback.z_B_norm_clipped = 0;
feedback.s_SC_warning = 0;
feedback.s_SC_low = 0;
feedback.s_SC_high = 0;
feedback.SC_warning_source_id = 0;
feedback.SC_warning_fallback = true;
feedback.use_asymmetric_SC_warning = false;
feedback.k_warning_M_used = 0;
feedback.k_warning_B_used = 0;
feedback.alpha_warning_used = 0;
feedback.EPL_warning = 0;
feedback.z_M_SC_warning = 0;
feedback.z_B_SC_warning = 0;
feedback.SOC_B_end = NaN;
feedback.SOC_SC_end = NaN;
feedback.SOC_SC_min = NaN;
feedback.SOC_SC_max = NaN;
feedback.SOC_B_hist = [];
feedback.SOC_SC_hist = [];
feedback.active_candidate = false;
feedback.active = false;
feedback.components = empty_components();
feedback.raw_components = empty_components();
end

function c = empty_components()
c = struct('z_M_track', 0, 'z_M_SC', 0, 'z_M_balance', 0, ...
    'z_M_SC_warning', 0, 'z_M_total', 0, 'z_B_track', 0, 'z_B_SC', 0, ...
    'z_B_SC_warning', 0, ...
    'z_B_safe', 0, 'z_B_total', 0);
end

function [bases, weight] = normalized_epl_settings(params_fb)
persistent warned_zM_base warned_zB_base
bases = struct();
bases.e_track_base = read_optional(params_fb, 'e_track_base', 1.0);
bases.r_SC_base = read_optional(params_fb, 'r_SC_base', 1.0);
bases.r_B_base = read_optional(params_fb, 'r_B_base', 1.0);
bases.warning_base = read_optional(params_fb, 'EPL_warning_base', 1.0);

if isfield(params_fb, 'z_M_base') && ~isempty(params_fb.z_M_base)
    bases.z_M_base = params_fb.z_M_base;
elseif isfield(params_fb, 'PM_max') && isfield(params_fb, 'PM_min')
    bases.z_M_base = abs(params_fb.PM_max - params_fb.PM_min);
else
    bases.z_M_base = 1.0;
    if isempty(warned_zM_base)
        fprintf('WARNING: z_M_base is missing; normalized EPL uses fallback z_M_base=1.\n');
        warned_zM_base = true;
    end
end

if isfield(params_fb, 'z_B_base') && ~isempty(params_fb.z_B_base)
    bases.z_B_base = params_fb.z_B_base;
elseif isfield(params_fb, 'PB_max') && isfield(params_fb, 'PB_min')
    bases.z_B_base = abs(params_fb.PB_max - params_fb.PB_min);
else
    bases.z_B_base = 1.0;
    if isempty(warned_zB_base)
        fprintf('WARNING: z_B_base is missing; normalized EPL uses fallback z_B_base=1.\n');
        warned_zB_base = true;
    end
end

bases.e_track_base = max(bases.e_track_base, eps);
bases.r_SC_base = max(bases.r_SC_base, eps);
bases.r_B_base = max(bases.r_B_base, eps);
bases.z_M_base = max(bases.z_M_base, eps);
bases.z_B_base = max(bases.z_B_base, eps);
bases.warning_base = max(bases.warning_base, eps);

weight = struct();
weight.alpha_track = read_optional(params_fb, 'alpha_track_norm', 1.0);
weight.alpha_SC = read_optional(params_fb, 'alpha_SC_norm', 1.0);
weight.alpha_B = read_optional(params_fb, 'alpha_B_norm', 1.0);
weight.alpha_z = read_optional(params_fb, 'alpha_z_norm', 0.2);
weight.alpha_warn = read_optional(params_fb, 'alpha_warn_norm', 0.1);
end

function value = warning_signal_for_epl(feedback)
if isfield(feedback, 's_SC_warning') && ~isempty(feedback.s_SC_warning)
    value = abs(feedback.s_SC_warning);
elseif isfield(feedback, 'alpha_warning_used') && feedback.alpha_warning_used > eps
    value = abs(feedback.EPL_warning) / feedback.alpha_warning_used;
else
    value = abs(feedback.EPL_warning);
end
end

function [s_SC_warning, z_M_SC_warning, z_B_SC_warning, s_SC_low, s_SC_high, ...
    SC_warning_source_id, SC_warning_fallback, k_warning_M_used, ...
    k_warning_B_used, alpha_warning_used, EPL_warning] = compute_sc_warning(SOC_SC_traj, SOC_SC_end, bounds, params_fb)
persistent printed_fallback_warning
s_SC_warning = 0;
s_SC_low = 0;
s_SC_high = 0;
SC_warning_source_id = 0;
SC_warning_fallback = true;
z_M_SC_warning = 0;
z_B_SC_warning = 0;
k_warning_M_used = 0;
k_warning_B_used = 0;
alpha_warning_used = 0;
EPL_warning = 0;

if isnan(SOC_SC_end) || ~isfield(params_fb, 'enable_SC_warning_feedback') || ...
        ~params_fb.enable_SC_warning_feedback
    return;
end

use_extreme = read_optional(params_fb, 'use_SC_trajectory_extreme_warning', false);
SOC_SC_traj = SOC_SC_traj(:);
SOC_SC_traj = SOC_SC_traj(~isnan(SOC_SC_traj));
if use_extreme && ~isempty(SOC_SC_traj)
    SOC_SC_min = min(SOC_SC_traj);
    SOC_SC_max = max(SOC_SC_traj);
    SC_warning_fallback = false;
else
    SOC_SC_min = SOC_SC_end;
    SOC_SC_max = SOC_SC_end;
    if use_extreme && isempty(printed_fallback_warning)
        fprintf(['WARNING: SOC_SC_traj not found. SC warning falls back to SOC_SC_end. ' ...
            'Trajectory-extreme warning is not active.\n']);
        printed_fallback_warning = true;
    end
end

warning_min = params_fb.SOC_SC_warning_min;
warning_max = params_fb.SOC_SC_warning_max;
if max(abs([bounds.SC_soft_min, bounds.SC_soft_max])) > 1.5 && ...
        max(abs([warning_min, warning_max])) <= 1.5
    warning_min = warning_min * 100;
    warning_max = warning_max * 100;
end

if SOC_SC_min < warning_min
    s_SC_low = (warning_min - SOC_SC_min) / ...
        max(warning_min - bounds.SC_soft_min, eps);
else
    s_SC_low = 0;
end

if SOC_SC_max > warning_max
    s_SC_high = -(SOC_SC_max - warning_max) / ...
        max(bounds.SC_soft_max - warning_max, eps);
else
    s_SC_high = 0;
end

if s_SC_low == 0 && s_SC_high == 0
    s_SC_warning = 0;
    SC_warning_source_id = 0;
elseif abs(s_SC_low) >= abs(s_SC_high)
    s_SC_warning = s_SC_low;
    SC_warning_source_id = 1;
else
    s_SC_warning = s_SC_high;
    SC_warning_source_id = 2;
end

clip_value = read_optional(params_fb, 'SC_warning_clip', 1.0);
s_SC_warning = min(max(s_SC_warning, -clip_value), clip_value);
if read_optional(params_fb, 'use_smooth_SC_warning', true)
    s_SC_warning = tanh(s_SC_warning);
end

if read_optional(params_fb, 'use_asymmetric_SC_warning', false)
    if SC_warning_source_id == 1
        k_warning_M_used = read_optional(params_fb, 'k_SC_warning_M_low', ...
            read_optional(params_fb, 'k_SC_warning_M', 1.25));
        k_warning_B_used = read_optional(params_fb, 'k_SC_warning_B_low', ...
            read_optional(params_fb, 'k_SC_warning_B', 0.22));
        alpha_warning_used = read_optional(params_fb, 'alpha_SC_warning_low', ...
            read_optional(params_fb, 'alpha_SC_warning', 2.7));
    elseif SC_warning_source_id == 2
        k_warning_M_used = read_optional(params_fb, 'k_SC_warning_M_high', ...
            read_optional(params_fb, 'k_SC_warning_M', 1.25));
        k_warning_B_used = read_optional(params_fb, 'k_SC_warning_B_high', ...
            read_optional(params_fb, 'k_SC_warning_B', 0.22));
        alpha_warning_used = read_optional(params_fb, 'alpha_SC_warning_high', ...
            read_optional(params_fb, 'alpha_SC_warning', 2.7));
    end
else
    k_warning_M_used = read_optional(params_fb, 'k_SC_warning_M', 1.25);
    k_warning_B_used = read_optional(params_fb, 'k_SC_warning_B', 0.22);
    alpha_warning_used = read_optional(params_fb, 'alpha_SC_warning', 2.7);
    if SC_warning_source_id == 0
        k_warning_M_used = 0;
        k_warning_B_used = 0;
        alpha_warning_used = 0;
    end
end

z_M_SC_warning = k_warning_M_used * s_SC_warning * params_fb.delta_PM_max;
z_B_SC_warning = k_warning_B_used * s_SC_warning * params_fb.delta_PB_max;
EPL_warning = alpha_warning_used * abs(s_SC_warning);
end

function value = read_optional(s, name, default_value)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default_value;
end
end

function data = extract_matrix(s, primary_field, fallback_field)
data = [];
if isstruct(s) && isfield(s, primary_field) && ~isempty(s.(primary_field))
    data = s.(primary_field);
elseif ~isempty(fallback_field) && isstruct(s) && isfield(s, fallback_field) && ~isempty(s.(fallback_field))
    data = s.(fallback_field);
end
end

function m = orient_time_by_row(m, expected_cols)
if isempty(m)
    return;
end
if size(m, 2) < expected_cols && size(m, 1) >= expected_cols
    m = m';
end
end

function v = rowvec(v)
v = v(:)';
end

function v = safe_column_as_row(m, col, N)
if size(m, 2) >= col
    v = rowvec(m(:, col));
else
    v = zeros(1, N);
    warning('fankuiwei:missingColumn', ...
        'Expected column %d is missing. It is filled with zeros.', col);
end
end

function [PM_ref, PB_ref] = extract_reference(u0_ref, PM_lower, PB_lower, N)
if isempty(u0_ref)
    warning('fankuiwei:missingReference', ...
        'Cannot find snd.u0_ref. Lower-layer output is used as reference.');
    PM_ref = PM_lower;
    PB_ref = PB_lower;
    return;
end

if size(u0_ref, 1) >= 2
    PM_ref = rowvec(u0_ref(1, 1:min(N, size(u0_ref, 2))));
    PB_ref = rowvec(u0_ref(2, 1:min(N, size(u0_ref, 2))));
else
    u0_ref = orient_time_by_row(u0_ref, 2);
    PM_ref = rowvec(u0_ref(1:min(N, size(u0_ref, 1)), 1));
    PB_ref = rowvec(u0_ref(1:min(N, size(u0_ref, 1)), 2));
end

PM_ref = pad_to_length(PM_ref, N);
PB_ref = pad_to_length(PB_ref, N);
end

function v = pad_to_length(v, N)
if isempty(v)
    v = zeros(1, N);
elseif length(v) < N
    v = [v, repmat(v(end), 1, N - length(v))];
else
    v = v(1:N);
end
end

function [SOC_B, SOC_SC] = extract_soc(x, N)
SOC_B = [];
SOC_SC = [];
if isempty(x)
    return;
end
if size(x, 2) >= 2
    SOC_B = rowvec(x(1:min(N, size(x, 1)), 2));
end
if size(x, 2) >= 3
    SOC_SC = rowvec(x(1:min(N, size(x, 1)), 3));
end
end

function [bounds, SOC_B, SOC_SC] = scaled_soc_bounds(SOC_B, SOC_SC, params_fb)
soc_all = [SOC_B(:); SOC_SC(:)];
soc_all = soc_all(~isnan(soc_all));
is_pu = ~isempty(soc_all) && max(abs(soc_all)) <= 1.5;

param_soc = [params_fb.SOC_B_hard_min, params_fb.SOC_B_hard_max, ...
    params_fb.SOC_B_soft_min, params_fb.SOC_B_soft_max, params_fb.SOC_B_target, ...
    params_fb.SOC_SC_hard_min, params_fb.SOC_SC_hard_max, ...
    params_fb.SOC_SC_soft_min, params_fb.SOC_SC_soft_max, params_fb.SOC_SC_target];
params_are_pu = max(abs(param_soc)) <= 1.5;

if is_pu && ~params_are_pu
    scale = 1 / 100;
elseif ~is_pu && params_are_pu
    scale = 100;
else
    scale = 1;
end

bounds.B_hard_min = params_fb.SOC_B_hard_min * scale;
bounds.B_hard_max = params_fb.SOC_B_hard_max * scale;
bounds.B_soft_min = params_fb.SOC_B_soft_min * scale;
bounds.B_soft_max = params_fb.SOC_B_soft_max * scale;
bounds.B_target = params_fb.SOC_B_target * scale;
bounds.SC_hard_min = params_fb.SOC_SC_hard_min * scale;
bounds.SC_hard_max = params_fb.SOC_SC_hard_max * scale;
bounds.SC_soft_min = params_fb.SOC_SC_soft_min * scale;
bounds.SC_soft_max = params_fb.SOC_SC_soft_max * scale;
bounds.SC_target = params_fb.SOC_SC_target * scale;
end

function [risk_sum, risk_inst] = normalized_soc_risk(SOC, hard_min, hard_max, soft_min, soft_max)
if isempty(SOC)
    risk_sum = 0;
    risk_inst = [];
    return;
end

den_low = max(soft_min - hard_min, eps);
den_high = max(hard_max - soft_max, eps);
r_low = max(0, (soft_min - SOC) ./ den_low);
r_high = max(0, (SOC - soft_max) ./ den_high);
risk_inst = max(r_low, r_high);
% 允许超过 1，表示已经越过硬边界或非常接近不可行区域。
risk_sum = sum(risk_inst.^2);
end

function m = mean_without_nan(v)
v = v(~isnan(v));
if isempty(v)
    m = 0;
else
    m = mean(v);
end
end
