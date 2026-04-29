function [summary_table, results_cases, metrics_cases, params_cases, csv_file] = run_experiment_original_vs_event_feedback(use_cached_results, smoke_mode, force_event_rerun)
%RUN_EXPERIMENT_ORIGINAL_VS_EVENT_FEEDBACK Event-only normEPL ablation run.
% Active event-triggered feedback workflow, 5percent scenario:
%   event_base_no_detect_no_reopt
%   event_detect_no_reopt
%   event_reopt_p0_legacy
%   event_reopt_popt_legacy
%   event_reopt_p0_normEPL
%   event_reopt_popt_normEPL
%
% The file name is kept for backward compatibility, but rolling original /
% rolling feedback are no longer part of this active event workflow.

if nargin < 1 || isempty(use_cached_results)
    use_cached_results = false;
end
if nargin < 2 || isempty(smoke_mode)
    smoke_mode = false;
end
if nargin < 3 || isempty(force_event_rerun)
    force_event_rerun = false;
end

total_tic = tic;
script_folder = fileparts(mfilename('fullpath'));
cd(script_folder);
addpath(genpath(script_folder), '-begin');
rmpath_if_exists(fullfile(script_folder, 'cleanup_archive_unused'));
rmpath_if_exists(fullfile(script_folder, 'archive_rolling_feedback'));

results_folder = fullfile(script_folder, 'results');
if ~exist(results_folder, 'dir')
    mkdir(results_folder);
end

event_modes = {'event_base_no_detect_no_reopt', ...
    'event_detect_no_reopt', ...
    'event_reopt_p0_legacy', ...
    'event_reopt_popt_legacy', ...
    'event_reopt_p0_normEPL', ...
    'event_reopt_popt_normEPL'};

fprintf('\n================ Event normEPL Ablation ================\n');
fprintf('Scenario          : 5percent\n');
fprintf('Smoke mode        : %d\n', smoke_mode);
fprintf('Use cached        : %d\n', use_cached_results);
fprintf('Force rerun       : %d\n', force_event_rerun);
fprintf('Output folder     : %s\n', results_folder);
fprintf('=========================================================\n');

rows = [];
results_cases = struct();
metrics_cases = struct();
params_cases = struct();

for i = 1:numel(event_modes)
    mode = event_modes{i};
    clear global fst_output_data snd_output_data
    close all force;
    drawnow;

    result_file = fullfile(results_folder, ['results_' mode '.mat']);
    params_event = make_event_params(mode, smoke_mode);

    if use_cached_results && ~force_event_rerun && exist(result_file, 'file') == 2
        fprintf('\n[%s] Load cached result: %s\n', mode, result_file);
        try
            data = load(result_file);
            [results_case, metrics_case, params_event] = unpack_saved_case(data);
            status = 'success';
            error_message = '';
        catch ME
            results_case = struct();
            metrics_case = struct();
            status = 'failed';
            error_message = ME.message;
        end
    else
        fprintf('\n[%s] Run event-triggered MPC...\n', mode);
        t_case = tic;
        try
            [results_case, params_event, event_history, fst, snd, mpcdata] = ...
                main_event_feedback_mpc(false, params_event); %#ok<ASGLU>
            results_case.sim_time = toc(t_case);
            metrics_case = evaluate_mpc_metrics(results_case, params_event);
            save(result_file, 'results_case', 'metrics_case', 'params_event', ...
                'event_history', 'fst', 'snd', 'mpcdata');
            status = 'success';
            error_message = '';
        catch ME
            results_case = struct();
            metrics_case = struct();
            status = 'failed';
            error_message = ME.message;
            warning('eventNormEPL:caseFailed', '[%s] failed: %s', mode, ME.message);
            save(result_file, 'status', 'error_message', 'params_event');
        end
    end

    key = matlab.lang.makeValidName(mode);
    results_cases.(key) = results_case;
    metrics_cases.(key) = metrics_case;
    params_cases.(key) = params_event;
    rows = append_row(rows, make_summary_row(mode, result_file, ...
        results_case, metrics_case, status, error_message));
    print_mode_summary(mode, rows(end));
end

summary_table = struct2table(rows);
csv_file = fullfile(results_folder, 'event_normEPL_ablation_summary.csv');
writetable(summary_table, csv_file);

print_key_comparisons(summary_table);
fprintf('\nTotal experiment wall time: %.3f s\n', toc(total_tic));
fprintf('Summary CSV = %s\n', csv_file);
end

function params_event = make_event_params(mode, smoke_mode)
params_event = init_fankuiwei_params();
params_event.enable_plot = false;
params_event.scenario_name = '5percent';
params_event.pv_file = fullfile('data', 'pv_5m_5percent.xlsx');
params_event.wind_file = fullfile('data', 'wind_5m_5percent.xlsx');
params_event.ablation_mode = mode;
if contains(mode, 'normEPL')
    params_event.EPL_mode = 'normalized';
    params_event.use_normalized_EPL = true;
else
    params_event.EPL_mode = 'legacy';
    params_event.use_normalized_EPL = false;
end
if smoke_mode
    params_event.sim.fst_iter = 2;
    params_event.sim.fst_horizon = 6;
    params_event.sim.snd_iter = 12;
    params_event.sim.snd_horizon = 12;
end
end

function [results_case, metrics_case, params_case] = unpack_saved_case(data)
results_case = struct();
metrics_case = struct();
params_case = struct();

result_names = {'results_case', 'results', 'results_event'};
for i = 1:numel(result_names)
    name = result_names{i};
    if isfield(data, name) && isstruct(data.(name)) && is_result_struct(data.(name))
        results_case = data.(name);
        break;
    end
end
if isempty(fieldnames(results_case))
    error('No recognizable event results struct in saved file.');
end

metric_names = {'metrics_case', 'metrics', 'metrics_event'};
for i = 1:numel(metric_names)
    name = metric_names{i};
    if isfield(data, name) && isstruct(data.(name)) && is_metric_struct(data.(name))
        metrics_case = data.(name);
        break;
    end
end
if isempty(fieldnames(metrics_case))
    if isfield(results_case, 'params') && isstruct(results_case.params)
        metrics_case = evaluate_mpc_metrics(results_case, results_case.params);
    else
        metrics_case = evaluate_mpc_metrics(results_case, struct());
    end
end

param_names = {'params_event', 'params_case', 'params_fb'};
for i = 1:numel(param_names)
    name = param_names{i};
    if isfield(data, name) && isstruct(data.(name))
        params_case = data.(name);
        break;
    end
end
end

function tf = is_result_struct(s)
tf = isstruct(s) && (isfield(s, 'traj') || isfield(s, 'upper') || isfield(s, 'event'));
end

function tf = is_metric_struct(s)
tf = isstruct(s) && (isfield(s, 'total_cost') || isfield(s, 'tracking_rms') || isfield(s, 'J_total_sum'));
end

function row = make_summary_row(mode, result_file, results_case, metrics_case, status, error_message)
row = empty_summary_row();
row.mode = mode;
row.EPL_mode = mode_to_epl(mode, results_case);
row.result_file = result_file;
row.status = status;
row.error_message = error_message;
if ~strcmp(status, 'success') || isempty(fieldnames(metrics_case))
    return;
end

summary = read_event_summary(results_case);
row.total_cost = read_num(metrics_case, {'total_cost', 'J_total_sum'}, NaN);
row.grid_cost = read_num(metrics_case, {'grid_cost', 'economic_cost', 'J_grid_sum'}, NaN);
row.battery_deg_cost = read_num(metrics_case, {'battery_deg_cost', 'degradation_cost', 'J_batt_deg_sum'}, NaN);
row.tracking_RMS = read_num(metrics_case, {'tracking_rms', 'e_track_RMS'}, NaN);
row.PM_tracking_RMS = read_num(metrics_case, {'e_PM_RMS', 'PM_tracking_RMS'}, NaN);
row.PB_tracking_RMS = read_num(metrics_case, {'e_PB_RMS', 'PB_tracking_RMS'}, NaN);
row.SC_SOC_risk_ratio = read_num(metrics_case, {'sc_soc_risk_ratio', 'SOC_SC_risk_ratio'}, NaN);
row.B_SOC_risk_ratio = read_num(metrics_case, {'battery_soc_risk_ratio', 'SOC_B_risk_ratio'}, NaN);
row.SC_hard_violation_count = read_num(metrics_case, {'SOC_SC_violation_count', 'SC_hard_violation_count'}, NaN);
row.B_hard_violation_count = read_num(metrics_case, {'SOC_B_violation_count', 'B_hard_violation_count'}, NaN);
row.event_count = read_num(summary, {'event_count'}, 0);
row.reopt_count = read_num(summary, {'reopt_count'}, 0);
row.fallback_count = read_num(summary, {'fallback_count'}, read_num(metrics_case, {'fallback_count'}, 0));
row.strict_success_count = read_num(summary, {'strict_success_count'}, 0);
row.exitflag0_count = read_num(summary, {'exitflag0_count'}, 0);
row.failure_count = read_num(summary, {'failure_count'}, 0);
row.solve_time_mean = read_num(summary, {'solve_time_mean'}, NaN);
row.solve_time_max = read_num(summary, {'solve_time_max'}, NaN);
row.solve_time_p95 = read_num(summary, {'solve_time_p95'}, NaN);
row.p_feedback_mean = read_num(summary, {'p_feedback_mean'}, read_num(metrics_case, {'mean_p_feedback'}, NaN));
row.p_feedback_max = read_num(summary, {'p_feedback_max'}, read_num(metrics_case, {'max_p_feedback'}, NaN));
row.p_feedback_nonzero_ratio = read_num(summary, {'p_feedback_nonzero_ratio'}, NaN);
row.z_M_mean = read_num(summary, {'z_M_mean'}, NaN);
row.z_B_mean = read_num(summary, {'z_B_mean'}, NaN);
row.pz_M_mean = read_num(summary, {'pz_M_mean'}, NaN);
row.pz_B_mean = read_num(summary, {'pz_B_mean'}, NaN);
row.EPL_micro_used_mean = read_num(summary, {'EPL_micro_used_mean'}, NaN);
row.EPL_micro_used_max = read_num(summary, {'EPL_micro_used_max'}, NaN);
row.EPL_track_norm_mean = read_num(summary, {'EPL_track_norm_mean'}, NaN);
row.EPL_SC_norm_mean = read_num(summary, {'EPL_SC_norm_mean'}, NaN);
row.EPL_B_norm_mean = read_num(summary, {'EPL_B_norm_mean'}, NaN);
row.EPL_z_norm_mean = read_num(summary, {'EPL_z_norm_mean'}, NaN);
row.EPL_track_legacy_mean = read_num(summary, {'EPL_track_legacy_mean'}, NaN);
row.EPL_SC_legacy_mean = read_num(summary, {'EPL_SC_legacy_mean'}, NaN);
row.EPL_B_legacy_mean = read_num(summary, {'EPL_B_legacy_mean'}, NaN);
row.EPL_z_legacy_mean = read_num(summary, {'EPL_z_legacy_mean'}, NaN);
row.PM_ref_remain_delta_RMS_mean = read_num(summary, {'mean_PM_ref_remain_delta_RMS'}, NaN);
row.PB_ref_remain_delta_RMS_mean = read_num(summary, {'mean_PB_ref_remain_delta_RMS'}, NaN);
row.events_with_nonzero_PM_ref_change = read_num(summary, {'events_with_nonzero_PM_ref_change'}, 0);
row.events_with_nonzero_PB_ref_change = read_num(summary, {'events_with_nonzero_PB_ref_change'}, 0);
end

function row = empty_summary_row()
row = struct( ...
    'mode', '', ...
    'EPL_mode', '', ...
    'result_file', '', ...
    'total_cost', NaN, ...
    'grid_cost', NaN, ...
    'battery_deg_cost', NaN, ...
    'tracking_RMS', NaN, ...
    'PM_tracking_RMS', NaN, ...
    'PB_tracking_RMS', NaN, ...
    'SC_SOC_risk_ratio', NaN, ...
    'B_SOC_risk_ratio', NaN, ...
    'SC_hard_violation_count', NaN, ...
    'B_hard_violation_count', NaN, ...
    'event_count', NaN, ...
    'reopt_count', NaN, ...
    'fallback_count', NaN, ...
    'strict_success_count', NaN, ...
    'exitflag0_count', NaN, ...
    'failure_count', NaN, ...
    'solve_time_mean', NaN, ...
    'solve_time_max', NaN, ...
    'solve_time_p95', NaN, ...
    'p_feedback_mean', NaN, ...
    'p_feedback_max', NaN, ...
    'p_feedback_nonzero_ratio', NaN, ...
    'z_M_mean', NaN, ...
    'z_B_mean', NaN, ...
    'pz_M_mean', NaN, ...
    'pz_B_mean', NaN, ...
    'EPL_micro_used_mean', NaN, ...
    'EPL_micro_used_max', NaN, ...
    'EPL_track_norm_mean', NaN, ...
    'EPL_SC_norm_mean', NaN, ...
    'EPL_B_norm_mean', NaN, ...
    'EPL_z_norm_mean', NaN, ...
    'EPL_track_legacy_mean', NaN, ...
    'EPL_SC_legacy_mean', NaN, ...
    'EPL_B_legacy_mean', NaN, ...
    'EPL_z_legacy_mean', NaN, ...
    'PM_ref_remain_delta_RMS_mean', NaN, ...
    'PB_ref_remain_delta_RMS_mean', NaN, ...
    'events_with_nonzero_PM_ref_change', NaN, ...
    'events_with_nonzero_PB_ref_change', NaN, ...
    'status', '', ...
    'error_message', '');
end

function rows = append_row(rows, row)
if isempty(rows)
    rows = row;
else
    rows(end+1, 1) = row;
end
end

function summary = read_event_summary(results_case)
summary = struct();
if isstruct(results_case) && isfield(results_case, 'event') && isstruct(results_case.event) && ...
        isfield(results_case.event, 'summary') && isstruct(results_case.event.summary)
    summary = results_case.event.summary;
end
end

function value = read_num(s, names, default_value)
value = default_value;
if ~isstruct(s)
    return;
end
for i = 1:numel(names)
    name = names{i};
    if isfield(s, name) && ~isempty(s.(name))
        v = s.(name);
        if isnumeric(v) || islogical(v)
            value = double(v(1));
            return;
        end
    end
end
end

function mode = mode_to_epl(mode_name, results_case)
if contains(mode_name, 'normEPL')
    mode = 'normalized';
elseif contains(mode_name, 'legacy') || strcmp(mode_name, 'event_detect_no_reopt') || ...
        strcmp(mode_name, 'event_base_no_detect_no_reopt')
    mode = 'legacy';
elseif isstruct(results_case) && isfield(results_case, 'params') && ...
        isstruct(results_case.params) && isfield(results_case.params, 'EPL_mode')
    mode = results_case.params.EPL_mode;
else
    mode = 'legacy';
end
end

function print_mode_summary(mode, row)
fprintf('\nMode: %s\n', mode);
fprintf('status = %s\n', row.status);
if strcmp(row.status, 'success')
    fprintf('EPL_mode = %s\n', row.EPL_mode);
    fprintf('total_cost = %.6g\n', row.total_cost);
    fprintf('tracking_RMS = %.6g (PM %.6g, PB %.6g)\n', ...
        row.tracking_RMS, row.PM_tracking_RMS, row.PB_tracking_RMS);
    fprintf('SC_SOC_risk_ratio = %.6g\n', row.SC_SOC_risk_ratio);
    fprintf('B_SOC_risk_ratio = %.6g\n', row.B_SOC_risk_ratio);
    fprintf('event_count / reopt_count = %.0f / %.0f\n', row.event_count, row.reopt_count);
    fprintf('p_feedback mean/max/nonzero_ratio = %.6g / %.6g / %.6g\n', ...
        row.p_feedback_mean, row.p_feedback_max, row.p_feedback_nonzero_ratio);
    fprintf('EPL used mean/max = %.6g / %.6g\n', row.EPL_micro_used_mean, row.EPL_micro_used_max);
    fprintf('EPL_z legacy/norm mean = %.6g / %.6g\n', ...
        row.EPL_z_legacy_mean, row.EPL_z_norm_mean);
    fprintf('PM/PB remain delta RMS mean = %.6g / %.6g\n', ...
        row.PM_ref_remain_delta_RMS_mean, row.PB_ref_remain_delta_RMS_mean);
    fprintf('strict_success / exitflag0 / failure = %.0f / %.0f / %.0f\n', ...
        row.strict_success_count, row.exitflag0_count, row.failure_count);
    fprintf('solve_time mean/max/p95 = %.6g / %.6g / %.6g\n', ...
        row.solve_time_mean, row.solve_time_max, row.solve_time_p95);
else
    fprintf('error_message = %s\n', row.error_message);
end
end

function print_key_comparisons(T)
fprintf('\n================ Event normEPL Attribution Checks ================\n');
print_pair_delta(T, 'event_detect_no_reopt', 'event_base_no_detect_no_reopt', ...
    'event_base_no_detect_no_reopt vs event_detect_no_reopt');
print_pair_delta(T, 'event_reopt_p0_legacy', 'event_base_no_detect_no_reopt', ...
    'event_base_no_detect_no_reopt vs event_reopt_p0_legacy');
print_pair_delta(T, 'event_reopt_popt_legacy', 'event_reopt_p0_legacy', ...
    'event_reopt_p0_legacy vs event_reopt_popt_legacy');
print_pair_delta(T, 'event_reopt_popt_normEPL', 'event_reopt_p0_normEPL', ...
    'event_reopt_p0_normEPL vs event_reopt_popt_normEPL');
print_pair_delta(T, 'event_reopt_popt_normEPL', 'event_reopt_popt_legacy', ...
    'event_reopt_popt_legacy vs event_reopt_popt_normEPL');
fprintf('===================================================================\n');
end

function print_pair_delta(T, mode_a, mode_b, label)
ia = find(strcmp(T.mode, mode_a), 1);
ib = find(strcmp(T.mode, mode_b), 1);
if isempty(ia) || isempty(ib)
    fprintf('%s: missing data\n', label);
    return;
end
fprintf('\n%s\n', label);
fprintf('tracking_RMS: %.6g vs %.6g (delta %.6g)\n', ...
    T.tracking_RMS(ia), T.tracking_RMS(ib), T.tracking_RMS(ia) - T.tracking_RMS(ib));
fprintf('SC_SOC_risk_ratio: %.6g vs %.6g (delta %.6g)\n', ...
    T.SC_SOC_risk_ratio(ia), T.SC_SOC_risk_ratio(ib), T.SC_SOC_risk_ratio(ia) - T.SC_SOC_risk_ratio(ib));
fprintf('B_SOC_risk_ratio: %.6g vs %.6g (delta %.6g)\n', ...
    T.B_SOC_risk_ratio(ia), T.B_SOC_risk_ratio(ib), T.B_SOC_risk_ratio(ia) - T.B_SOC_risk_ratio(ib));
fprintf('event_count/reopt_count: %.0f/%.0f vs %.0f/%.0f\n', ...
    T.event_count(ia), T.reopt_count(ia), T.event_count(ib), T.reopt_count(ib));
fprintf('p_feedback mean/max/nonzero_ratio: %.6g/%.6g/%.6g vs %.6g/%.6g/%.6g\n', ...
    T.p_feedback_mean(ia), T.p_feedback_max(ia), T.p_feedback_nonzero_ratio(ia), ...
    T.p_feedback_mean(ib), T.p_feedback_max(ib), T.p_feedback_nonzero_ratio(ib));
fprintf('EPL_z legacy/norm mean: %.6g/%.6g vs %.6g/%.6g\n', ...
    T.EPL_z_legacy_mean(ia), T.EPL_z_norm_mean(ia), ...
    T.EPL_z_legacy_mean(ib), T.EPL_z_norm_mean(ib));
fprintf('solve_time mean/max/p95: %.6g/%.6g/%.6g vs %.6g/%.6g/%.6g\n', ...
    T.solve_time_mean(ia), T.solve_time_max(ia), T.solve_time_p95(ia), ...
    T.solve_time_mean(ib), T.solve_time_max(ib), T.solve_time_p95(ib));
end

function rmpath_if_exists(folder)
if exist(folder, 'dir') == 7
    try
        rmpath(genpath(folder));
    catch
    end
end
end
