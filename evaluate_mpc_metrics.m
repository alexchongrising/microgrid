function metrics = evaluate_mpc_metrics(results, params)
%EVALUATE_MPC_METRICS 统一计算原始MPC和反馈MPC的评价指标。
% 输入:
%   results  main_fankuiwei.m 保存的结果结构体
%   params   反馈参数结构体，主要用于SOC软/硬边界
% 输出:
%   metrics  成本、跟踪误差、SOC风险、反馈统计和计算时间指标

if nargin < 2 || isempty(params)
    params = struct();
end

if exist('fcnSummarizeUpperCosts', 'file') == 2
    results = fcnSummarizeUpperCosts(results);
end

metrics = struct();
metrics.mode = read_scalar_field(results, 'mode', '');

%% 1. 成本指标：hist字段按“每个上层时段阶段成本”处理，直接求和。
upper = read_struct_field(results, 'upper');
grid_cost = read_vector_alias(upper, ...
    {'grid_cost_hist', 'grid_cost', 'C_M_upper', 'upper_grid_cost_hist'}, ...
    'upper.grid_cost_hist');
batt_cost = read_vector_alias(upper, ...
    {'batt_deg_cost_hist', 'batt_deg_cost', 'C_B_upper', 'upper_batt_deg_cost_hist'}, ...
    'upper.batt_deg_cost_hist');

[grid_cost, batt_cost] = common_length_pair(grid_cost, batt_cost, ...
    'grid_cost_hist', 'batt_deg_cost_hist');
total_cost = grid_cost + batt_cost;

n_upper = max(1, length(total_cost));
metrics.J_grid_sum = sum_or_nan(grid_cost);
metrics.J_batt_deg_sum = sum_or_nan(batt_cost);
metrics.J_total_sum = metrics.J_grid_sum + metrics.J_batt_deg_sum;
metrics.J_grid_avg = metrics.J_grid_sum / n_upper;
metrics.J_batt_deg_avg = metrics.J_batt_deg_sum / n_upper;
metrics.J_total_avg = metrics.J_total_sum / n_upper;
metrics.n_upper_steps = n_upper;

%% 2. 下层跟踪误差指标。
traj = read_struct_field(results, 'traj');
traj = augment_traj_from_raw(traj, results);
PM_lower = read_vector_alias(traj, {'PM_lower'}, 'traj.PM_lower');
PB_lower = read_vector_alias(traj, {'PB_lower'}, 'traj.PB_lower');
[PM_ref, PB_ref] = choose_reference_vectors(traj);

PM_ref = align_reference_to_lower(PM_ref, length(PM_lower), 'PM_ref');
PB_ref = align_reference_to_lower(PB_ref, length(PB_lower), 'PB_ref');

[PM_lower, PM_ref] = common_length_pair(PM_lower, PM_ref, 'PM_lower', 'PM_ref');
[PB_lower, PB_ref] = common_length_pair(PB_lower, PB_ref, 'PB_lower', 'PB_ref');
n_track = min(length(PM_lower), length(PB_lower));

if n_track > 0
    PM_lower = PM_lower(1:n_track);
    PB_lower = PB_lower(1:n_track);
    PM_ref = PM_ref(1:n_track);
    PB_ref = PB_ref(1:n_track);
    e_PM = PM_lower - PM_ref;
    e_PB = PB_lower - PB_ref;
    metrics.e_PM_RMS = sqrt(mean(e_PM.^2));
    metrics.e_PB_RMS = sqrt(mean(e_PB.^2));
    metrics.e_track_RMS = sqrt(mean(e_PM.^2 + e_PB.^2));
    metrics.e_track_mean = mean(abs(e_PM) + abs(e_PB));
    metrics.e_track_max = max(abs(e_PM) + abs(e_PB));
    metrics.e_PM_series = e_PM;
    metrics.e_PB_series = e_PB;
    metrics.e_track_series = abs(e_PM) + abs(e_PB);
else
    warning('fankuiwei:missingTrackingData', ...
        'Tracking data is incomplete. Tracking metrics are set to NaN.');
    metrics.e_PM_RMS = NaN;
    metrics.e_PB_RMS = NaN;
    metrics.e_track_RMS = NaN;
    metrics.e_track_mean = NaN;
    metrics.e_track_max = NaN;
    metrics.e_PM_series = [];
    metrics.e_PB_series = [];
    metrics.e_track_series = [];
end

%% 3. SOC风险指标。
SOC_SC = read_vector_alias(traj, {'SOC_SC'}, 'traj.SOC_SC');
SOC_B = read_vector_alias(traj, {'SOC_B'}, 'traj.SOC_B');
metrics = append_soc_metrics(metrics, SOC_SC, params, 'SC');
metrics = append_soc_metrics(metrics, SOC_B, params, 'B');
metrics.SOC_SC_final = last_or_nan(SOC_SC);
metrics.SOC_B_final = last_or_nan(SOC_B);

%% 3b. Reference correction and storage throughput metrics.
PM_ref_raw = read_vector_alias(traj, {'PM_ref_raw'});
PB_ref_raw = read_vector_alias(traj, {'PB_ref_raw'});
PM_ref_new = read_vector_alias(traj, {'PM_ref_new', 'PM_ref'});
PB_ref_new = read_vector_alias(traj, {'PB_ref_new', 'PB_ref'});
PSC_lower = read_vector_alias(traj, {'PSC_lower', 'PSC_final'});

metrics.PM_diff_std = reference_delta_std_or_nan(PM_ref_new, PM_ref_raw, 'PM_ref_new', 'PM_ref_raw');
metrics.PB_diff_std = reference_delta_std_or_nan(PB_ref_new, PB_ref_raw, 'PB_ref_new', 'PB_ref_raw');
metrics.PM_abs_diff_sum = reference_delta_sum_or_nan(PM_ref_new, PM_ref_raw, 'PM_ref_new', 'PM_ref_raw');
metrics.PB_abs_diff_sum = reference_delta_sum_or_nan(PB_ref_new, PB_ref_raw, 'PB_ref_new', 'PB_ref_raw');
metrics.PB_throughput = throughput_5min_or_nan(PB_lower);
metrics.SC_throughput = throughput_5min_or_nan(PSC_lower);
metrics.applied_feedback = read_logical_or_default(results, 'applied_feedback', false);
if ~metrics.applied_feedback && isfield(results, 'feedback') && isstruct(results.feedback)
    metrics.applied_feedback = read_logical_or_default(results.feedback, 'applied_feedback', false);
end

%% 4. 反馈机制自身指标。
if isfield(results, 'feedback') && isstruct(results.feedback)
    fb = results.feedback;
    p_hist = read_vector_alias(fb, {'p_feedback_hist', 'p_feedback'}, 'feedback.p_feedback_hist');
    epl_hist = read_vector_alias(fb, {'EPL_micro_hist', 'EPL_micro'}, 'feedback.EPL_micro_hist');
    active_hist = read_vector_alias(fb, {'active_flag_hist', 'active_flag'}, 'feedback.active_flag_hist');
    dPM = read_vector_alias(fb, {'delta_PM_clipped_hist', 'delta_PM_hist'}, 'feedback.delta_PM_clipped_hist');
    dPB = read_vector_alias(fb, {'delta_PB_clipped_hist', 'delta_PB_hist'}, 'feedback.delta_PB_clipped_hist');

    metrics.active_count = read_number_or_default(fb, 'active_count', sum(active_hist ~= 0));
    metrics.active_ratio = read_number_or_default(fb, 'active_ratio', safe_ratio(metrics.active_count, max(1, length(active_hist))));
    metrics.mean_p_feedback = mean_or_nan(p_hist);
    metrics.max_p_feedback = max_or_nan(p_hist);
    metrics.mean_EPL_micro = mean_or_nan(epl_hist);
    metrics.max_EPL_micro = max_or_nan(epl_hist);
    metrics.mean_abs_delta_PM = mean_or_nan(abs(dPM));
    metrics.max_abs_delta_PM = max_or_nan(abs(dPM));
    metrics.mean_abs_delta_PB = mean_or_nan(abs(dPB));
    metrics.max_abs_delta_PB = max_or_nan(abs(dPB));
else
    metrics.active_count = NaN;
    metrics.active_ratio = NaN;
    metrics.mean_p_feedback = NaN;
    metrics.max_p_feedback = NaN;
    metrics.mean_EPL_micro = NaN;
    metrics.max_EPL_micro = NaN;
    metrics.mean_abs_delta_PM = NaN;
    metrics.max_abs_delta_PM = NaN;
    metrics.mean_abs_delta_PB = NaN;
    metrics.max_abs_delta_PB = NaN;
end

%% 4b. 事件触发反馈 MPC 专用指标。
% 这些字段不会影响 original / rolling_feedback；当 results.event 不存在时返回 NaN。
if isfield(results, 'event') && isstruct(results.event)
    ev = results.event;
    trigger_flag = read_vector_alias(ev, {'trigger_flag'}, 'event.trigger_flag');
    fallback_hist = read_vector_alias(ev, {'fallback_used'}, 'event.fallback_used');
    upper_exit = read_vector_alias(ev, {'upper_reopt_exitflag'}, 'event.upper_reopt_exitflag');
    upper_time = read_vector_alias(ev, {'upper_reopt_time'}, 'event.upper_reopt_time');
    metrics.event_trigger_count = sum(trigger_flag ~= 0);
    metrics.event_trigger_ratio = safe_ratio(metrics.event_trigger_count, max(1, length(trigger_flag)));
    metrics.event_fallback_count = sum(fallback_hist ~= 0);
    metrics.upper_reopt_success_count = sum(upper_exit >= 0);
    metrics.upper_reopt_attempt_count = sum(~isnan(upper_exit));
    metrics.upper_reopt_success_ratio = safe_ratio(metrics.upper_reopt_success_count, metrics.upper_reopt_attempt_count);
    metrics.upper_reopt_exitflag_hist = upper_exit;
    metrics.upper_reopt_mean_time = mean_or_nan(upper_time(~isnan(upper_time)));
    if isfield(ev, 'reason')
        metrics.event_reason = ev.reason;
        metrics.event_reason_count = count_reason_cells(ev.reason);
    else
        metrics.event_reason = {};
        metrics.event_reason_count = struct();
    end
else
    metrics.event_trigger_count = 0;
    metrics.event_trigger_ratio = 0;
    metrics.event_fallback_count = 0;
    metrics.upper_reopt_success_count = 0;
    metrics.upper_reopt_attempt_count = 0;
    metrics.upper_reopt_success_ratio = NaN;
    metrics.upper_reopt_exitflag_hist = [];
    metrics.upper_reopt_mean_time = NaN;
    metrics.event_reason = {};
    metrics.event_reason_count = struct();
end

if isfield(results, 'lower') && isstruct(results.lower)
    lower_exit = read_vector_alias(results.lower, {'exitflag_hist'}, 'lower.exitflag_hist');
    lower_fallback = read_vector_alias(results.lower, {'fallback_used_hist'}, 'lower.fallback_used_hist');
    metrics.lower_exitflag_hist = lower_exit;
    metrics.lower_exitflag_distribution = count_numeric_values(lower_exit);
    metrics.lower_fallback_count = sum(lower_fallback ~= 0);
else
    metrics.lower_exitflag_hist = [];
    metrics.lower_exitflag_distribution = struct();
    metrics.lower_fallback_count = NaN;
end

%% 5. 计算时间指标。
time_hist = read_vector_alias(results, ...
    {'solver_time', 'computation_time', 'solver_time_hist', 'computation_time_hist'}, ...
    'results.solver_time');
metrics.total_solver_time = sum_or_nan(time_hist);
metrics.mean_solver_time = mean_or_nan(time_hist);

%% 6. 论文/绘图统一别名，兼容 J_total_sum 等历史字段。
metrics.total_cost = metrics.J_total_sum;
metrics.economic_cost = metrics.J_grid_sum;
metrics.degradation_cost = metrics.J_batt_deg_sum;
metrics.grid_cost = metrics.J_grid_sum;
metrics.battery_deg_cost = metrics.J_batt_deg_sum;
metrics.tracking_rms = metrics.e_track_RMS;
metrics.sc_soc_risk_ratio = metrics.SOC_SC_risk_ratio;
metrics.battery_soc_risk_ratio = metrics.SOC_B_risk_ratio;
metrics.pm_diff_std = metrics.PM_diff_std;
metrics.pb_diff_std = metrics.PB_diff_std;
metrics.pm_abs_diff_sum = metrics.PM_abs_diff_sum;
metrics.pb_abs_diff_sum = metrics.PB_abs_diff_sum;
metrics.pb_throughput = metrics.PB_throughput;
metrics.sc_throughput = metrics.SC_throughput;
metrics.sc_soc_min = metrics.SOC_SC_min;
metrics.sc_soc_max = metrics.SOC_SC_max;
metrics.sc_soc_final = metrics.SOC_SC_final;
metrics.battery_soc_min = metrics.SOC_B_min;
metrics.battery_soc_max = metrics.SOC_B_max;
metrics.battery_soc_final = metrics.SOC_B_final;
metrics.fallback_count = max_nan_zero(metrics.event_fallback_count, metrics.lower_fallback_count);
metrics.upper_reopt_success_rate = metrics.upper_reopt_success_ratio;
metrics.upper_exitflag_distribution = count_numeric_values(metrics.upper_reopt_exitflag_hist);
metrics.avg_upper_reopt_time = metrics.upper_reopt_mean_time;
metrics.total_sim_time = read_number_or_default(results, 'sim_time', metrics.total_solver_time);

end

function s = read_struct_field(parent, field_name)
if isstruct(parent) && isfield(parent, field_name) && isstruct(parent.(field_name))
    s = parent.(field_name);
else
    s = struct();
end
end

function value = read_scalar_field(parent, field_name, default_value)
if isstruct(parent) && isfield(parent, field_name)
    value = parent.(field_name);
else
    value = default_value;
end
end

function value = read_vector_alias(s, names, label)
value = [];
if ~isstruct(s)
    return;
end
for i = 1:length(names)
    name = names{i};
    if isfield(s, name) && ~isempty(s.(name))
        value = s.(name)(:);
        return;
    end
end
if nargin >= 3
    warning('fankuiwei:missingMetricField', 'Missing field: %s', label);
end
end

function [a, b] = common_length_pair(a, b, name_a, name_b)
a = a(:);
b = b(:);
if isempty(a) || isempty(b)
    return;
end
n = min(length(a), length(b));
if length(a) ~= length(b)
    warning('fankuiwei:lengthMismatch', ...
        '%s and %s have different lengths. Use common length %d.', ...
        name_a, name_b, n);
end
a = a(1:n);
b = b(1:n);
end

function [PM_ref, PB_ref] = choose_reference_vectors(traj)
if isfield(traj, 'PM_ref_new') && ~isempty(traj.PM_ref_new)
    PM_ref = traj.PM_ref_new(:);
elseif isfield(traj, 'PM_ref') && ~isempty(traj.PM_ref)
    PM_ref = traj.PM_ref(:);
elseif isfield(traj, 'PM_ref_raw') && ~isempty(traj.PM_ref_raw)
    PM_ref = traj.PM_ref_raw(:);
else
    PM_ref = [];
end

if isfield(traj, 'PB_ref_new') && ~isempty(traj.PB_ref_new)
    PB_ref = traj.PB_ref_new(:);
elseif isfield(traj, 'PB_ref') && ~isempty(traj.PB_ref)
    PB_ref = traj.PB_ref(:);
elseif isfield(traj, 'PB_ref_raw') && ~isempty(traj.PB_ref_raw)
    PB_ref = traj.PB_ref_raw(:);
else
    PB_ref = [];
end
end

function traj = augment_traj_from_raw(traj, results)
% 兼容旧版结果：如果没有results.traj，则从raw.snd和raw.history_feedback中回填。
if ~isstruct(traj)
    traj = struct();
end
if ~isfield(results, 'raw') || ~isstruct(results.raw)
    return;
end

if isfield(results.raw, 'snd') && isstruct(results.raw.snd)
    snd = results.raw.snd;
    if isfield(snd, 'u') && ~isempty(snd.u)
        u = snd.u;
        if size(u, 2) >= 1 && ~isfield(traj, 'PM_lower')
            traj.PM_lower = u(:, 1);
        end
        if size(u, 2) >= 2 && ~isfield(traj, 'PB_lower')
            traj.PB_lower = u(:, 2);
        end
        if size(u, 2) >= 3 && ~isfield(traj, 'PSC_lower')
            traj.PSC_lower = u(:, 3);
        end
    end
    if isfield(snd, 'x') && ~isempty(snd.x)
        x = snd.x;
        if size(x, 2) >= 2 && ~isfield(traj, 'SOC_B')
            traj.SOC_B = x(:, 2);
        end
        if size(x, 2) >= 3 && ~isfield(traj, 'SOC_SC')
            traj.SOC_SC = x(:, 3);
        end
    end
end

if isfield(results.raw, 'history_feedback') && isstruct(results.raw.history_feedback)
    h = results.raw.history_feedback;
    if isfield(h, 'PM_ref_old') && ~isfield(traj, 'PM_ref_raw')
        traj.PM_ref_raw = h.PM_ref_old(:);
    end
    if isfield(h, 'PB_ref_old') && ~isfield(traj, 'PB_ref_raw')
        traj.PB_ref_raw = h.PB_ref_old(:);
    end
    if isfield(h, 'PM_ref_new') && ~isfield(traj, 'PM_ref_new')
        traj.PM_ref_new = h.PM_ref_new(:);
        traj.PM_ref = h.PM_ref_new(:);
    end
    if isfield(h, 'PB_ref_new') && ~isfield(traj, 'PB_ref_new')
        traj.PB_ref_new = h.PB_ref_new(:);
        traj.PB_ref = h.PB_ref_new(:);
    end
end
end

function ref = align_reference_to_lower(ref, n_lower, label)
ref = ref(:);
if isempty(ref) || n_lower <= 0
    return;
end
if length(ref) == n_lower
    return;
end
if length(ref) < n_lower
    ratio = n_lower / length(ref);
    ratio_round = round(ratio);
    if abs(ratio - ratio_round) < 1e-8 && ratio_round >= 1
        ref = repelem(ref, ratio_round);
    else
        warning('fankuiwei:referenceLengthNotInteger', ...
            '%s length cannot be expanded by integer factor. Use nearest repeat.', label);
        idx = ceil((1:n_lower)' * length(ref) / n_lower);
        idx(idx < 1) = 1;
        idx(idx > length(ref)) = length(ref);
        ref = ref(idx);
    end
end
if length(ref) > n_lower
    ref = ref(1:n_lower);
end
end

function metrics = append_soc_metrics(metrics, SOC, params, tag)
SOC = SOC(:);
prefix = ['SOC_' tag];
if isempty(SOC)
    metrics.([prefix '_min']) = NaN;
    metrics.([prefix '_max']) = NaN;
    metrics.([prefix '_risk_count']) = NaN;
    metrics.([prefix '_risk_ratio']) = NaN;
    metrics.([prefix '_violation_count']) = NaN;
    return;
end

bounds = get_soc_bounds(params, tag, SOC);
risk_flag = SOC < bounds.soft_min | SOC > bounds.soft_max;
violate_flag = SOC < bounds.hard_min | SOC > bounds.hard_max;

metrics.([prefix '_min']) = min(SOC);
metrics.([prefix '_max']) = max(SOC);
metrics.([prefix '_risk_count']) = sum(risk_flag);
metrics.([prefix '_risk_ratio']) = sum(risk_flag) / length(SOC);
metrics.([prefix '_violation_count']) = sum(violate_flag);
end

function bounds = get_soc_bounds(params, tag, SOC)
if strcmp(tag, 'SC')
    defaults = [0, 100, 20, 80];
else
    defaults = [10, 90, 20, 80];
end

hard_min = read_param(params, ['SOC_' tag '_hard_min'], defaults(1));
hard_max = read_param(params, ['SOC_' tag '_hard_max'], defaults(2));
soft_min = read_param(params, ['SOC_' tag '_soft_min'], defaults(3));
soft_max = read_param(params, ['SOC_' tag '_soft_max'], defaults(4));

% 如果结果SOC是0~1标幺值而参数是0~100百分数，则自动换算边界。
if max(abs(SOC)) <= 1.5 && max([hard_min, hard_max, soft_min, soft_max]) > 1.5
    hard_min = hard_min / 100;
    hard_max = hard_max / 100;
    soft_min = soft_min / 100;
    soft_max = soft_max / 100;
elseif max(abs(SOC)) > 1.5 && max([hard_min, hard_max, soft_min, soft_max]) <= 1.5
    hard_min = hard_min * 100;
    hard_max = hard_max * 100;
    soft_min = soft_min * 100;
    soft_max = soft_max * 100;
end

bounds.hard_min = hard_min;
bounds.hard_max = hard_max;
bounds.soft_min = soft_min;
bounds.soft_max = soft_max;
end

function value = reference_delta_std_or_nan(new_ref, raw_ref, name_new, name_raw)
[new_ref, raw_ref] = common_length_pair(new_ref, raw_ref, name_new, name_raw);
if isempty(new_ref) || isempty(raw_ref)
    value = NaN;
else
    value = std(new_ref(:) - raw_ref(:));
end
end

function value = reference_delta_sum_or_nan(new_ref, raw_ref, name_new, name_raw)
[new_ref, raw_ref] = common_length_pair(new_ref, raw_ref, name_new, name_raw);
if isempty(new_ref) || isempty(raw_ref)
    value = NaN;
else
    value = sum(abs(new_ref(:) - raw_ref(:)));
end
end

function value = throughput_5min_or_nan(power_series)
power_series = power_series(:);
if isempty(power_series)
    value = NaN;
else
    value = sum(abs(power_series)) / 12;
end
end

function value = read_param(params, name, default_value)
if isstruct(params) && isfield(params, name) && ~isempty(params.(name))
    value = params.(name);
else
    value = default_value;
end
end

function value = read_number_or_default(s, name, default_value)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = s.(name);
else
    value = default_value;
end
end

function value = read_logical_or_default(s, name, default_value)
if isstruct(s) && isfield(s, name) && ~isempty(s.(name))
    value = logical(s.(name));
else
    value = default_value;
end
end

function value = mean_or_nan(x)
if isempty(x)
    value = NaN;
else
    value = mean(x(:));
end
end

function value = max_or_nan(x)
if isempty(x)
    value = NaN;
else
    value = max(x(:));
end
end

function value = sum_or_nan(x)
if isempty(x)
    value = NaN;
else
    value = sum(x(:));
end
end

function value = last_or_nan(x)
x = x(:);
if isempty(x)
    value = NaN;
else
    value = x(end);
end
end

function value = safe_ratio(a, b)
if isempty(b) || b == 0
    value = NaN;
else
    value = a / b;
end
end

function out = count_reason_cells(reason_cells)
out = struct();
if isempty(reason_cells)
    return;
end
for i = 1:numel(reason_cells)
    txt = reason_cells{i};
    if isempty(txt)
        continue;
    end
    parts = regexp(txt, '\|', 'split');
    for j = 1:numel(parts)
        key = matlab.lang.makeValidName(parts{j});
        if isempty(key)
            continue;
        end
        if ~isfield(out, key)
            out.(key) = 0;
        end
        out.(key) = out.(key) + 1;
    end
end
end

function out = count_numeric_values(values)
out = struct();
values = values(:);
values = values(~isnan(values));
if isempty(values)
    return;
end
unique_values = unique(values)';
for v = unique_values
    key = matlab.lang.makeValidName(sprintf('exitflag_%g', v));
    out.(key) = sum(values == v);
end
end

function value = max_nan_zero(a, b)
vals = [a, b];
vals = vals(~isnan(vals));
if isempty(vals)
    value = NaN;
else
    value = max(vals);
end
end
