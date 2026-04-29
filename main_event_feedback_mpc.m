function [results, params_fb, event_history, fst, snd, mpcdata] = main_event_feedback_mpc(use_cached_results, params)
%MAIN_EVENT_FEEDBACK_MPC Event-triggered two-layer feedback MPC runner.
% Backward-compatible calls:
%   main_event_feedback_mpc
%   main_event_feedback_mpc(false)
%   main_event_feedback_mpc(false, options)
%
% options.ablation_mode:
%   event_base_no_detect_no_reopt : event driver baseline; no detection or reopt.
%   event_detect_no_reopt : detect and log events, but do not reopt/update refs.
%   event_reopt_p0_legacy / event_reopt_p0_normEPL : reopt with p_feedback=0.
%   event_reopt_popt_legacy / event_reopt_popt_normEPL : optimized p_feedback.
%   periodic_fast_reopt  : fixed-interval intra-hour reopt, not event-threshold based.

if nargin < 1 || isempty(use_cached_results)
    use_cached_results = false; %#ok<NASGU>
end
if nargin < 2 || isempty(params)
    params_fb = init_fankuiwei_params();
else
    params_fb = merge_params(init_fankuiwei_params(), params);
end

params_fb.event.enable = true;
params_fb.enable_feedback = true;
params_fb.ablation_mode = normalize_ablation_mode(read_char_field(params_fb, 'ablation_mode', 'event_reopt_popt'));
[params_fb.ablation_mode, params_fb.EPL_mode, params_fb.use_normalized_EPL] = ...
    configure_event_mode(params_fb.ablation_mode, read_char_field(params_fb, 'EPL_mode', params_fb.EPL_mode));
if ~isfield(params_fb, 'periodic_fast_reopt_interval_steps') || isempty(params_fb.periodic_fast_reopt_interval_steps)
    params_fb.periodic_fast_reopt_interval_steps = 6;
end
sim_tic = tic;

script_folder = fileparts(mfilename('fullpath'));
addpath(genpath(script_folder), '-begin');
archive_folder = fullfile(script_folder, 'cleanup_archive_unused');
if exist(archive_folder, 'dir') == 7
    rmpath(genpath(archive_folder));
end
rolling_archive_folder = fullfile(script_folder, 'archive_rolling_feedback');
if exist(rolling_archive_folder, 'dir') == 7
    rmpath(genpath(rolling_archive_folder));
end
cd(script_folder);

fig_folder = fullfile(script_folder, 'figures', 'event_feedback_results');
if ~exist(fig_folder, 'dir')
    mkdir(fig_folder);
end

tol_opt = 1e-8;
opt_option = 1;
iprint = 5;
[tol_opt, opt_option, iprint, printClosedloopDataFunc] = ...
    fcnChooseAlgorithm(tol_opt, opt_option, iprint, @printClosedloopData);

global fst_output_data;
global snd_output_data;
fst_output_data = [];
snd_output_data = [];

fst = fcnSetStageParam('fst');
snd = fcnSetStageParam('snd');
[fst, snd] = apply_sim_override(fst, snd, params_fb);
fst.iprint = iprint;
snd.iprint = iprint;
fst.printClosedloopData = printClosedloopDataFunc;
snd.printClosedloopData = printClosedloopDataFunc;

fprintf('Import data for event-triggered feedback MPC (%s)....', params_fb.ablation_mode);
mpcdata = fcnImportData('data/data_all.csv', 'data/price_seq_RT.csv');
pv_file = read_char_field(params_fb, 'pv_file', fullfile('data', 'pv_5m_5percent.xlsx'));
wind_file = read_char_field(params_fb, 'wind_file', fullfile('data', 'wind_5m_5percent.xlsx'));
pv_5m_data_all = xlsread(pv_file);
wind_5m_data_all = xlsread(wind_file);
fprintf('Finish.\n');

fst.option = fcnChooseOption(opt_option, tol_opt, fst.u0);
snd.option = fcnChooseOption(opt_option, tol_opt, repmat([5; 0; 0], 1, snd.horizon));

event_history = init_event_history();
traj = init_traj_history();
upper_history = init_upper_history();
fb_state = struct('last_event_idx', -inf, 'event_latched', false, ...
    'lower_steps_per_upper', snd.iter, 'event_count_this_upper', 0);

fst.mpciter = 0;
while fst.mpciter < fst.iter
    i_upper = fst.mpciter + 1;
    fb_state.event_count_this_upper = 0;

    fst.load = mpcdata.load(i_upper:i_upper + fst.horizon - 1, :);
    fst.PV = mpcdata.PV(i_upper:i_upper + fst.horizon - 1, :);
    fst.wind = mpcdata.wind(i_upper:i_upper + fst.horizon - 1, :);
    fst.price = mpcdata.price(i_upper:i_upper + fst.horizon - 1, :);
    [fst.f_dyn, fst.x_dyn, fst.u_dyn] = fst_mpc(fst, fst_output_data);
    [grid_cost, batt_deg_cost, total_cost] = compute_upper_step_cost_local(fst);
    upper_history = append_upper_history_local(upper_history, i_upper, grid_cost, batt_deg_cost, total_cost);

    ref_schedule = fcnBuildLowerReferenceFromUpper(fst, snd, i_upper, params_fb);

    if snd.flag == 0
        snd.xmeasure = [fst.x_dyn(1, :), 50];
    else
        snd.xmeasure = [fst.xmeasure(1, 1:2), snd.xmeasure(1, 3)];
    end
    snd.flag = 1;

    for j_lower = 1:snd.iter
        global_lower_idx = (i_upper - 1) * snd.iter + j_lower;
        snd.mpciter = j_lower - 1;
        snd.u0_ref = fcnGetCurrentLowerRef(ref_schedule, j_lower, snd.horizon, params_fb);
        snd.u0 = snd.u0_ref(:, 1:snd.horizon);

        data_idx = min(global_lower_idx, size(pv_5m_data_all, 1));
        snd.PV = pv_5m_data_all(data_idx, 1:12)';
        snd.wind = wind_5m_data_all(data_idx, 1:12)';
        snd.load = repmat(mpcdata.load(i_upper), snd.horizon, 1);
        snd.price = repmat(mpcdata.price(i_upper), snd.horizon, 1);

        PM_ref_before = ref_scalar(ref_schedule, 'PM_ref_after', j_lower, 0);
        PB_ref_before = ref_scalar(ref_schedule, 'PB_ref_after', j_lower, 0);
        snd = snd_mpc_one_step(snd, snd_output_data);

        feedback_snd = build_feedback_snapshot(snd, PM_ref_before, PB_ref_before);
        feedback = fcnEvaluateLowerFeedback(feedback_snd, params_fb);
        feedback.exitflag_current = snd.exitflag_current;
        feedback.fallback_used_current = snd.fallback_used_current;

        fb_state_before = fb_state;
        if is_base_no_detect_mode(params_fb.ablation_mode)
            rule_triggered = false;
            rule_info = build_event_info_local(feedback, snd, global_lower_idx, j_lower);
            rule_info.reasons = {'no_detection_baseline'};
            fb_state_rule = fb_state;
        else
            [rule_triggered, rule_info, fb_state_rule] = ...
                fcnCheckEventTrigger(feedback, snd, fb_state, params_fb, global_lower_idx, j_lower);
        end
        [event_triggered, event_info, fb_state] = choose_trigger_for_mode( ...
            rule_triggered, rule_info, fb_state_rule, fb_state_before, ...
            feedback, snd, params_fb, global_lower_idx, j_lower);

        PM_remain_before = remain_ref(ref_schedule, 'PM_ref_after', j_lower + 1);
        PB_remain_before = remain_ref(ref_schedule, 'PB_ref_after', j_lower + 1);
        PM_remain_after = PM_remain_before;
        PB_remain_after = PB_remain_before;

        p_feedback_opt = 0;
        upper_reopt_exitflag = NaN;
        upper_reopt_time = NaN;
        upper_reopt_message = '';
        event_fallback_used = 0;
        fallback_reason = '';
        do_reopt = event_triggered && ~(is_detect_only_mode(params_fb.ablation_mode) || ...
            is_base_no_detect_mode(params_fb.ablation_mode));

        if event_triggered && do_reopt
            feedback_for_reopt = feedback;
            if is_p0_mode(params_fb.ablation_mode)
                feedback_for_reopt = disable_feedback_request(feedback_for_reopt);
            end

            [fst_event, event_param] = fcnBuildEventReoptProblem( ...
                fst, snd, feedback_for_reopt, ref_schedule, i_upper, j_lower, params_fb);
            [fst_event, event_solution] = fst_mpc_event(fst_event, event_param);
            upper_reopt_exitflag = event_solution.exitflag;
            upper_reopt_time = event_solution.solver_time;
            p_feedback_opt = event_solution.p_feedback_opt;
            if isfield(event_solution, 'output') && isfield(event_solution.output, 'message')
                upper_reopt_message = event_solution.output.message;
            end

            if is_p0_mode(params_fb.ablation_mode)
                [event_solution, event_param] = force_zero_feedback_solution(event_solution, event_param);
                p_feedback_opt = 0;
            end

            if event_solution.success
                [ref_schedule, ~] = fcnUpdateRemainingLowerReference( ...
                    ref_schedule, event_solution, event_param, j_lower, params_fb);
                fst.u_dyn = fst_event.u_dyn;
            else
                event_fallback_used = 1;
                fallback_reason = upper_reopt_message;
                if isempty(fallback_reason)
                    fallback_reason = sprintf('event_reopt_failed_exitflag_%g', upper_reopt_exitflag);
                end
                if is_popt_mode(params_fb.ablation_mode) && ...
                        safe_logical_field(params_fb.event, 'enable_fallback_rule', true)
                    [ref_schedule, p_feedback_opt] = apply_rule_fallback(ref_schedule, feedback, params_fb, j_lower);
                    fallback_reason = ['rule_fallback: ' fallback_reason];
                else
                    p_feedback_opt = 0;
                end
            end
        elseif event_triggered
            upper_reopt_message = 'event_detect_no_reopt: detection logged, no reopt or reference update';
        end

        PM_remain_after = remain_ref(ref_schedule, 'PM_ref_after', j_lower + 1);
        PB_remain_after = remain_ref(ref_schedule, 'PB_ref_after', j_lower + 1);
        PM_delta = align_delta(PM_remain_after, PM_remain_before);
        PB_delta = align_delta(PB_remain_after, PB_remain_before);
        delta_stats = struct( ...
            'PM_max_abs', max_abs_or_zero(PM_delta), ...
            'PB_max_abs', max_abs_or_zero(PB_delta), ...
            'PM_RMS', rms_or_zero(PM_delta), ...
            'PB_RMS', rms_or_zero(PB_delta), ...
            'PM_abs_sum', sum(abs(PM_delta(:))), ...
            'PB_abs_sum', sum(abs(PB_delta(:))));

        if event_triggered
            fprintf('Event #%d at hour %d step %d: PM remain delta RMS = %.6g, PB remain delta RMS = %.6g, p_feedback mean = %.6g, exitflag = %.6g, solve_time = %.6g, fallback_used = %d\n', ...
                event_history.event_count + 1, i_upper, j_lower, delta_stats.PM_RMS, ...
                delta_stats.PB_RMS, mean_scalar(p_feedback_opt), upper_reopt_exitflag, ...
                upper_reopt_time, event_fallback_used);
        end

        PM_ref_after = ref_scalar(ref_schedule, 'PM_ref_after', j_lower, PM_ref_before);
        PB_ref_after = ref_scalar(ref_schedule, 'PB_ref_after', j_lower, PB_ref_before);

        step_record = make_step_event_record(i_upper, j_lower, global_lower_idx, ...
            event_triggered, do_reopt, event_info, feedback, p_feedback_opt, ...
            upper_reopt_exitflag, upper_reopt_time, event_fallback_used, ...
            fallback_reason, upper_reopt_message, PM_remain_before, PB_remain_before, ...
            PM_remain_after, PB_remain_after, delta_stats);
        event_history = append_event_history(event_history, step_record);
        traj = append_traj_history(traj, global_lower_idx, PM_ref_before, PB_ref_before, ...
            PM_ref_after, PB_ref_after, snd, event_triggered, event_info);
    end

    fst.u0 = shiftHorizon(fst.u_dyn);
    fst.xmeasure = snd.xmeasure(1, 1:2);
    fst.mpciter = fst.mpciter + 1;
    fst.f = [fst.f, fst.f_dyn];
    fst.x = [fst.x; fst.xmeasure];
    fst.u = [fst.u; fst.u_dyn(:, 1)'];
end

event_history.total_sim_time = toc(sim_tic);
event_history.summary = summarize_event_history(event_history);
results = build_event_results(params_fb, event_history, traj, upper_history, fst, snd, mpcdata);
results.sim_time = safe_field(event_history, 'total_sim_time', NaN);
results = fcnSummarizeUpperCosts(results);

save(fullfile(fig_folder, sprintf('event_feedback_results_%s.mat', params_fb.ablation_mode)), ...
    'results', 'params_fb', 'event_history', 'fst', 'snd', 'mpcdata');

if safe_logical_field(params_fb, 'enable_plot', false)
    plot_event_feedback_results(results, fig_folder);
end

print_event_log_summary(event_history.summary);
fprintf('Saved event-triggered feedback MPC results to: %s\n', ...
    fullfile(fig_folder, sprintf('event_feedback_results_%s.mat', params_fb.ablation_mode)));
end

function mode = normalize_ablation_mode(mode)
valid = {'event_base_no_detect_no_reopt', 'event_detect_no_reopt', ...
    'event_reopt_p0_legacy', 'event_reopt_popt_legacy', ...
    'event_reopt_p0_normEPL', 'event_reopt_popt_normEPL', ...
    'event_reopt_p0', 'event_reopt_popt', 'periodic_fast_reopt'};
if isempty(mode) || strcmp(mode, 'event') || strcmp(mode, 'event_triggered_feedback_mpc')
    mode = 'event_reopt_popt_legacy';
end
if ~any(strcmp(mode, valid))
    warning('eventMPC:unknownAblationMode', 'Unknown ablation_mode "%s"; use event_reopt_popt_legacy.', mode);
    mode = 'event_reopt_popt_legacy';
end
end

function [mode, EPL_mode, use_normalized_EPL] = configure_event_mode(mode, EPL_mode_in)
EPL_mode = EPL_mode_in;
if isempty(EPL_mode)
    EPL_mode = 'legacy';
end
if strcmp(mode, 'event_reopt_p0')
    mode = 'event_reopt_p0_legacy';
elseif strcmp(mode, 'event_reopt_popt')
    mode = 'event_reopt_popt_legacy';
end
if contains(mode, 'normEPL')
    EPL_mode = 'normalized';
elseif contains(mode, 'legacy')
    EPL_mode = 'legacy';
end
use_normalized_EPL = strcmpi(EPL_mode, 'normalized');
end

function tf = is_base_no_detect_mode(mode)
tf = strcmp(mode, 'event_base_no_detect_no_reopt');
end

function tf = is_detect_only_mode(mode)
tf = strcmp(mode, 'event_detect_no_reopt');
end

function tf = is_p0_mode(mode)
tf = contains(mode, 'event_reopt_p0');
end

function tf = is_popt_mode(mode)
tf = contains(mode, 'event_reopt_popt') || strcmp(mode, 'periodic_fast_reopt');
end

function [fst, snd] = apply_sim_override(fst, snd, params_fb)
if ~isstruct(params_fb) || ~isfield(params_fb, 'sim') || ~isstruct(params_fb.sim)
    return;
end
sim = params_fb.sim;
if isfield(sim, 'fst_iter') && ~isempty(sim.fst_iter)
    fst.iter = sim.fst_iter;
end
if isfield(sim, 'fst_horizon') && ~isempty(sim.fst_horizon)
    fst.horizon = sim.fst_horizon;
    fst.u0 = repmat(fst.u0(:, 1), 1, fst.horizon);
end
if isfield(sim, 'snd_iter') && ~isempty(sim.snd_iter)
    snd.iter = sim.snd_iter;
end
if isfield(sim, 'snd_horizon') && ~isempty(sim.snd_horizon)
    snd.horizon = sim.snd_horizon;
end
end

function feedback_snd = build_feedback_snapshot(snd, PM_ref, PB_ref)
feedback_snd = snd;
feedback_snd.u = snd.u_applied(:)';
feedback_snd.u0_ref = [PM_ref; PB_ref; 0];
feedback_snd.x = snd.xmeasure;
end

function [event_triggered, event_info, fb_state] = choose_trigger_for_mode(rule_triggered, rule_info, fb_state_rule, fb_state_before, feedback, snd, params_fb, global_lower_idx, j_lower)
if is_base_no_detect_mode(params_fb.ablation_mode)
    event_triggered = false;
    event_info = build_event_info_local(feedback, snd, global_lower_idx, j_lower);
    event_info.reasons = {'no_detection_baseline'};
    event_info.event_triggered = false;
    event_info.remaining_steps = max(0, safe_field(fb_state_before, 'lower_steps_per_upper', 12) - j_lower);
    fb_state = fb_state_before;
    fb_state.event_latched = false;
elseif strcmp(params_fb.ablation_mode, 'periodic_fast_reopt')
    [event_triggered, event_info, fb_state] = periodic_trigger_decision( ...
        feedback, snd, fb_state_before, params_fb, global_lower_idx, j_lower);
else
    event_triggered = rule_triggered;
    event_info = rule_info;
    fb_state = fb_state_rule;
end
end

function [event_triggered, event_info, fb_state] = periodic_trigger_decision(feedback, snd, fb_state, params_fb, global_lower_idx, j_lower)
event_info = build_event_info_local(feedback, snd, global_lower_idx, j_lower);
interval_steps = max(1, round(params_fb.periodic_fast_reopt_interval_steps));
remaining_steps = max(0, safe_field(fb_state, 'lower_steps_per_upper', 12) - j_lower);
remaining_ok = remaining_steps >= params_fb.event.min_remaining_steps;
event_triggered = (mod(j_lower, interval_steps) == 0) && remaining_ok;
if event_triggered
    event_info.reasons = {'periodic_fast_reopt'};
    event_info.event_triggered = true;
    fb_state.last_event_idx = global_lower_idx;
    fb_state.event_count_this_upper = safe_field(fb_state, 'event_count_this_upper', 0) + 1;
    fb_state.event_latched = true;
else
    event_info.reasons = {'periodic_not_due'};
    event_info.event_triggered = false;
end
event_info.remaining_steps = remaining_steps;
end

function event_info = build_event_info_local(feedback, snd, global_lower_idx, j_lower)
event_info = struct();
event_info.global_lower_idx = global_lower_idx;
event_info.j_lower = j_lower;
event_info.reasons = {};
event_info.event_triggered = false;
event_info.EPL_micro = safe_field(feedback, 'EPL_micro', 0);
event_info.EPL_micro_used = safe_field(feedback, 'EPL_micro_used', event_info.EPL_micro);
event_info.EPL_micro_legacy = safe_field(feedback, 'EPL_micro_legacy', event_info.EPL_micro);
event_info.EPL_micro_norm = safe_field(feedback, 'EPL_micro_norm', event_info.EPL_micro);
event_info.EPL_mode_used = read_char_field(feedback, 'EPL_mode_used', 'legacy');
event_info.r_SC = safe_field(feedback, 'r_SC', 0);
event_info.r_B = safe_field(feedback, 'r_B', 0);
event_info.e_track_norm = safe_field(feedback, 'e_track_norm', 0);
event_info.z_M = read_feedback_value(feedback, 'z_M_total', 'z_M');
event_info.z_B = read_feedback_value(feedback, 'z_B_total', 'z_B');
event_info.SOC_B = NaN;
event_info.SOC_SC = NaN;
if isstruct(snd) && isfield(snd, 'xmeasure') && numel(snd.xmeasure) >= 3
    event_info.SOC_B = snd.xmeasure(2);
    event_info.SOC_SC = snd.xmeasure(3);
end
end

function feedback = disable_feedback_request(feedback)
fields = {'z_M', 'z_B', 'z_M_total', 'z_B_total', 'z_M_norm', 'z_B_norm', ...
    'z_M_norm_clipped', 'z_B_norm_clipped', 'z_M_norm_EPL', 'z_B_norm_EPL', ...
    'EPL_micro', 'EPL_micro_used', 'EPL_micro_legacy', 'EPL_micro_norm', ...
    'EPL_z_legacy', 'EPL_z_norm', 'p_feedback'};
for i = 1:numel(fields)
    if isfield(feedback, fields{i})
        feedback.(fields{i}) = 0;
    end
end
if isfield(feedback, 'components') && isstruct(feedback.components)
    cfields = fieldnames(feedback.components);
    for i = 1:numel(cfields)
        feedback.components.(cfields{i}) = 0;
    end
end
end

function [event_solution, event_param] = force_zero_feedback_solution(event_solution, event_param)
event_solution.p_feedback_opt = 0;
if isfield(event_solution, 'u_event') && ~isempty(event_solution.u_event) && size(event_solution.u_event, 1) >= 3
    event_solution.u_event(3, :) = 0;
end
event_param.z_M = 0;
event_param.z_B = 0;
event_param.EPL_micro = 0;
if isfield(event_param, 'EPL_micro_legacy')
    event_param.EPL_micro_legacy = 0;
end
if isfield(event_param, 'EPL_micro_norm')
    event_param.EPL_micro_norm = 0;
end
end

function [ref_schedule, p_feedback] = apply_rule_fallback(ref_schedule, feedback, params_fb, j_lower)
try
    state_fb = struct('prev_active', false, 'last_active_k', -inf, 'current_k', j_lower);
    [p_feedback, negotiation] = fcnNegotiateFeedback(feedback, params_fb, state_fb); %#ok<ASGLU>
    feedback.active = p_feedback > 0;
    for idx = (j_lower + 1):numel(ref_schedule.PM_ref_after)
        u_old = [ref_schedule.PM_ref_after(idx); ref_schedule.PB_ref_after(idx)];
        [u_new, ~] = fcnApplyFeedbackReference(u_old, feedback, p_feedback, params_fb, u_old);
        ref_schedule.PM_ref_after(idx) = u_new(1);
        ref_schedule.PB_ref_after(idx) = u_new(2);
    end
catch ME
    warning('eventMPC:fallbackRuleFailed', 'Rule fallback failed; keep previous references: %s', ME.message);
    p_feedback = 0;
end
end

function results = build_event_results(params_fb, event_history, traj, upper_history, fst, snd, mpcdata)
results = struct();
results.mode = params_fb.ablation_mode;
results.case_name = params_fb.ablation_mode;
results.params = params_fb;
results.params_fb = params_fb;
results.applied_feedback = is_popt_mode(params_fb.ablation_mode);

results.event = event_history;
results.event.trigger_flag = event_history.trigger_flag;
results.event.trigger_time = event_history.trigger_time;
results.event.trigger_upper_idx = event_history.trigger_upper_idx;
results.event.trigger_lower_idx = event_history.trigger_lower_idx;
results.event.reason = event_history.reason;
results.event.EPL_micro = event_history.EPL_micro;
results.event.EPL_micro_used = event_history.EPL_micro_used;
results.event.EPL_micro_legacy = event_history.EPL_micro_legacy;
results.event.EPL_micro_norm = event_history.EPL_micro_norm;
results.event.EPL_mode_used = event_history.EPL_mode_used;
results.event.EPL_track_legacy = event_history.EPL_track_legacy;
results.event.EPL_SC_legacy = event_history.EPL_SC_legacy;
results.event.EPL_B_legacy = event_history.EPL_B_legacy;
results.event.EPL_z_legacy = event_history.EPL_z_legacy;
results.event.EPL_warning_legacy = event_history.EPL_warning_legacy;
results.event.EPL_track_norm = event_history.EPL_track_norm;
results.event.EPL_SC_norm = event_history.EPL_SC_norm;
results.event.EPL_B_norm = event_history.EPL_B_norm;
results.event.EPL_z_norm = event_history.EPL_z_norm;
results.event.EPL_warning_norm = event_history.EPL_warning_norm;
results.event.e_track_base = event_history.e_track_base;
results.event.r_SC_base = event_history.r_SC_base;
results.event.r_B_base = event_history.r_B_base;
results.event.z_M_base = event_history.z_M_base;
results.event.z_B_base = event_history.z_B_base;
results.event.e_track = event_history.e_track;
results.event.r_SC = event_history.r_SC;
results.event.r_B = event_history.r_B;
results.event.e_track_norm = event_history.e_track_norm;
results.event.z_M = event_history.z_M;
results.event.z_B = event_history.z_B;
results.event.p_feedback_opt = event_history.p_feedback_opt;
results.event.p_feedback_times_z_M = event_history.p_feedback_times_z_M;
results.event.p_feedback_times_z_B = event_history.p_feedback_times_z_B;
results.event.upper_reopt_exitflag = event_history.upper_reopt_exitflag;
results.event.upper_reopt_time = event_history.upper_reopt_time;
results.event.fallback_used = event_history.fallback_used;
results.event.fallback_reason = event_history.fallback_reason;
results.event.upper_reopt_message = event_history.upper_reopt_message;
results.event.reopt_attempt_flag = event_history.reopt_attempt_flag;
results.event.tracking_triggered = event_history.tracking_triggered;
results.event.SC_SOC_triggered = event_history.SC_SOC_triggered;
results.event.B_SOC_triggered = event_history.B_SOC_triggered;
results.event.EPL_triggered = event_history.EPL_triggered;
results.event.solver_failure_triggered = event_history.solver_failure_triggered;
results.event.PM_ref_remain_delta_RMS = event_history.PM_ref_remain_delta_RMS;
results.event.PB_ref_remain_delta_RMS = event_history.PB_ref_remain_delta_RMS;
results.event.PM_ref_remain_delta_max_abs = event_history.PM_ref_remain_delta_max_abs;
results.event.PB_ref_remain_delta_max_abs = event_history.PB_ref_remain_delta_max_abs;
results.event.PM_ref_remain_delta_abs_sum = event_history.PM_ref_remain_delta_abs_sum;
results.event.PB_ref_remain_delta_abs_sum = event_history.PB_ref_remain_delta_abs_sum;
results.event.event_log = event_history.event_log;
results.event.summary = event_history.summary;

results.feedback.active_flag_hist = event_history.trigger_flag;
results.feedback.active_count = sum(event_history.trigger_flag ~= 0);
results.feedback.active_ratio = sum(event_history.trigger_flag ~= 0) / max(1, numel(event_history.trigger_flag));
results.feedback.p_feedback_hist = event_history.p_feedback_opt;
results.feedback.mean_p_feedback = mean(event_history.p_feedback_opt);
results.feedback.max_p_feedback = max(event_history.p_feedback_opt);
results.feedback.EPL_micro_hist = event_history.EPL_micro_used;
results.feedback.applied_feedback = results.applied_feedback;

results.traj = traj;
results.traj.PM_lower = traj.PM_final;
results.traj.PB_lower = traj.PB_final;
results.traj.SOC_B = traj.Battery_SOC;
results.traj.SOC_SC = traj.SC_SOC;
results.traj.PM_ref = traj.PM_ref_after;
results.traj.PB_ref = traj.PB_ref_after;
results.traj.PM_ref_new = traj.PM_ref_after;
results.traj.PB_ref_new = traj.PB_ref_after;
results.traj.PM_ref_raw = traj.PM_ref_before;
results.traj.PB_ref_raw = traj.PB_ref_before;

results.upper.grid_cost_hist = upper_history.grid_cost_hist;
results.upper.batt_deg_cost_hist = upper_history.batt_deg_cost_hist;
results.upper.total_cost_hist = upper_history.total_cost_hist;
results.lower.exitflag_hist = traj.lower_exitflag;
results.lower.fallback_used_hist = traj.lower_fallback_used;
results.raw.event_history = event_history;
results.raw.fst = fst;
results.raw.snd = snd;
results.raw.mpcdata = mpcdata;
end

function plot_event_feedback_results(results, fig_folder)
t = (1:numel(results.traj.PM_final))';
save_line(t, [results.traj.PM_ref_after(:), results.traj.PM_final(:)], ...
    {'PM_ref_after', 'PM_final'}, 'PM_ref_vs_PM_final_event', fig_folder);
save_line(t, [results.traj.PB_ref_after(:), results.traj.PB_final(:)], ...
    {'PB_ref_after', 'PB_final'}, 'PB_ref_vs_PB_final_event', fig_folder);
save_line(t, [results.traj.Battery_SOC(:), results.traj.SC_SOC(:)], ...
    {'Battery SOC', 'SC SOC'}, 'SOC_event', fig_folder);
save_line(t, results.traj.tracking_error(:), {'tracking error'}, 'tracking_error_event', fig_folder);
save_line(t, results.event.EPL_micro(:), {'EPL_micro'}, 'EPL_micro_event', fig_folder);
save_line(t, [results.event.z_M(:), results.event.z_B(:)], {'z_M', 'z_B'}, 'z_request_event', fig_folder);
save_line(t, results.event.p_feedback_opt(:), {'p_feedback_opt'}, 'p_feedback_opt_event', fig_folder);
end

function save_line(t, y, labels, name, fig_folder)
fig = figure('Name', name, 'Visible', 'off');
plot(t, y, 'LineWidth', 1.1);
grid on; xlabel('5-min step');
legend(labels, 'Location', 'best');
title(strrep(name, '_', ' '));
saveas(fig, fullfile(fig_folder, [name '.png']));
saveas(fig, fullfile(fig_folder, [name '.fig']));
close(fig);
end

function h = init_event_history()
h.event_count = 0;
h.trigger_flag = [];
h.trigger_time = [];
h.trigger_upper_idx = [];
h.trigger_lower_idx = [];
h.reason = {};
h.EPL_micro = [];
h.EPL_micro_used = [];
h.EPL_micro_legacy = [];
h.EPL_micro_norm = [];
h.EPL_mode_used = {};
h.EPL_track_legacy = [];
h.EPL_SC_legacy = [];
h.EPL_B_legacy = [];
h.EPL_z_legacy = [];
h.EPL_warning_legacy = [];
h.EPL_track_norm = [];
h.EPL_SC_norm = [];
h.EPL_B_norm = [];
h.EPL_z_norm = [];
h.EPL_warning_norm = [];
h.e_track_base = [];
h.r_SC_base = [];
h.r_B_base = [];
h.z_M_base = [];
h.z_B_base = [];
h.e_track = [];
h.r_SC = [];
h.r_B = [];
h.e_track_norm = [];
h.z_M = [];
h.z_B = [];
h.p_feedback_opt = [];
h.p_feedback_times_z_M = [];
h.p_feedback_times_z_B = [];
h.upper_reopt_exitflag = [];
h.upper_reopt_time = [];
h.fallback_used = [];
h.fallback_reason = {};
h.upper_reopt_message = {};
h.reopt_attempt_flag = [];
h.tracking_triggered = [];
h.SC_SOC_triggered = [];
h.B_SOC_triggered = [];
h.EPL_triggered = [];
h.solver_failure_triggered = [];
h.SC_SOC_before = [];
h.B_SOC_before = [];
h.PM_ref_remain_before = {};
h.PB_ref_remain_before = {};
h.PM_ref_remain_after = {};
h.PB_ref_remain_after = {};
h.PM_ref_remain_delta_max_abs = [];
h.PB_ref_remain_delta_max_abs = [];
h.PM_ref_remain_delta_RMS = [];
h.PB_ref_remain_delta_RMS = [];
h.PM_ref_remain_delta_abs_sum = [];
h.PB_ref_remain_delta_abs_sum = [];
h.constraint_violation_max = [];
h.constraint_violation_mean = [];
h.event_log = struct([]);
end

function h = append_event_history(h, rec)
h.trigger_flag(end+1, 1) = rec.event_triggered;
h.trigger_time(end+1, 1) = rec.global_lower_step_index;
h.trigger_upper_idx(end+1, 1) = rec.upper_hour_index;
h.trigger_lower_idx(end+1, 1) = rec.lower_step_index;
h.reason{end+1, 1} = rec.trigger_reason;
h.EPL_micro(end+1, 1) = rec.EPL_micro;
h.EPL_micro_used(end+1, 1) = rec.EPL_micro_used;
h.EPL_micro_legacy(end+1, 1) = rec.EPL_micro_legacy;
h.EPL_micro_norm(end+1, 1) = rec.EPL_micro_norm;
h.EPL_mode_used{end+1, 1} = rec.EPL_mode_used;
h.EPL_track_legacy(end+1, 1) = rec.EPL_track_legacy;
h.EPL_SC_legacy(end+1, 1) = rec.EPL_SC_legacy;
h.EPL_B_legacy(end+1, 1) = rec.EPL_B_legacy;
h.EPL_z_legacy(end+1, 1) = rec.EPL_z_legacy;
h.EPL_warning_legacy(end+1, 1) = rec.EPL_warning_legacy;
h.EPL_track_norm(end+1, 1) = rec.EPL_track_norm;
h.EPL_SC_norm(end+1, 1) = rec.EPL_SC_norm;
h.EPL_B_norm(end+1, 1) = rec.EPL_B_norm;
h.EPL_z_norm(end+1, 1) = rec.EPL_z_norm;
h.EPL_warning_norm(end+1, 1) = rec.EPL_warning_norm;
h.e_track_base(end+1, 1) = rec.e_track_base;
h.r_SC_base(end+1, 1) = rec.r_SC_base;
h.r_B_base(end+1, 1) = rec.r_B_base;
h.z_M_base(end+1, 1) = rec.z_M_base;
h.z_B_base(end+1, 1) = rec.z_B_base;
h.e_track(end+1, 1) = rec.e_track;
h.r_SC(end+1, 1) = rec.r_SC;
h.r_B(end+1, 1) = rec.r_B;
h.e_track_norm(end+1, 1) = rec.e_track_norm;
h.z_M(end+1, 1) = rec.z_M;
h.z_B(end+1, 1) = rec.z_B;
h.p_feedback_opt(end+1, 1) = rec.p_feedback;
h.p_feedback_times_z_M(end+1, 1) = rec.p_feedback_times_z_M;
h.p_feedback_times_z_B(end+1, 1) = rec.p_feedback_times_z_B;
h.upper_reopt_exitflag(end+1, 1) = rec.exitflag;
h.upper_reopt_time(end+1, 1) = rec.solve_time;
h.fallback_used(end+1, 1) = rec.fallback_used;
h.fallback_reason{end+1, 1} = rec.fallback_reason;
h.upper_reopt_message{end+1, 1} = rec.solver_message;
h.reopt_attempt_flag(end+1, 1) = rec.reopt_attempted;
h.tracking_triggered(end+1, 1) = rec.trigger_flags.tracking_triggered;
h.SC_SOC_triggered(end+1, 1) = rec.trigger_flags.SC_SOC_triggered;
h.B_SOC_triggered(end+1, 1) = rec.trigger_flags.B_SOC_triggered;
h.EPL_triggered(end+1, 1) = rec.trigger_flags.EPL_triggered;
h.solver_failure_triggered(end+1, 1) = rec.trigger_flags.solver_failure_triggered;
h.SC_SOC_before(end+1, 1) = rec.SC_SOC_before;
h.B_SOC_before(end+1, 1) = rec.B_SOC_before;
h.PM_ref_remain_before{end+1, 1} = rec.PM_ref_remain_before;
h.PB_ref_remain_before{end+1, 1} = rec.PB_ref_remain_before;
h.PM_ref_remain_after{end+1, 1} = rec.PM_ref_remain_after;
h.PB_ref_remain_after{end+1, 1} = rec.PB_ref_remain_after;
h.PM_ref_remain_delta_max_abs(end+1, 1) = rec.PM_ref_remain_delta_max_abs;
h.PB_ref_remain_delta_max_abs(end+1, 1) = rec.PB_ref_remain_delta_max_abs;
h.PM_ref_remain_delta_RMS(end+1, 1) = rec.PM_ref_remain_delta_RMS;
h.PB_ref_remain_delta_RMS(end+1, 1) = rec.PB_ref_remain_delta_RMS;
h.PM_ref_remain_delta_abs_sum(end+1, 1) = rec.PM_ref_remain_delta_abs_sum;
h.PB_ref_remain_delta_abs_sum(end+1, 1) = rec.PB_ref_remain_delta_abs_sum;
h.constraint_violation_max(end+1, 1) = rec.constraint_violation_max;
h.constraint_violation_mean(end+1, 1) = rec.constraint_violation_mean;
if rec.event_triggered
    h.event_count = h.event_count + 1;
    rec.event_index = h.event_count;
    h.event_log = append_struct(h.event_log, rec);
end
end

function rec = make_step_event_record(i_upper, j_lower, global_idx, event_triggered, reopt_attempted, info, feedback, p, exitflag, solve_time, fallback_used, fallback_reason, solver_message, PM_before, PB_before, PM_after, PB_after, delta_stats)
reason = '';
if isfield(info, 'reasons') && ~isempty(info.reasons)
    reason = strjoin(info.reasons, '|');
end
flags = reason_flags(reason);
z_M = read_feedback_value(feedback, 'z_M_total', 'z_M');
z_B = read_feedback_value(feedback, 'z_B_total', 'z_B');
p_scalar = mean_scalar(p);
rec = struct();
rec.event_index = NaN;
rec.upper_hour_index = i_upper;
rec.lower_step_index = j_lower;
rec.global_lower_step_index = global_idx;
rec.trigger_time = global_idx;
rec.event_triggered = logical(event_triggered);
rec.reopt_attempted = logical(reopt_attempted);
rec.trigger_reason = reason;
rec.trigger_flags = flags;
rec.EPL_micro = safe_field(feedback, 'EPL_micro', 0);
rec.EPL_micro_used = safe_field(feedback, 'EPL_micro_used', rec.EPL_micro);
rec.EPL_micro_legacy = safe_field(feedback, 'EPL_micro_legacy', rec.EPL_micro);
rec.EPL_micro_norm = safe_field(feedback, 'EPL_micro_norm', rec.EPL_micro);
rec.EPL_mode_used = read_char_field(feedback, 'EPL_mode_used', 'legacy');
rec.EPL_track_legacy = safe_field(feedback, 'EPL_track_legacy', 0);
rec.EPL_SC_legacy = safe_field(feedback, 'EPL_SC_legacy', 0);
rec.EPL_B_legacy = safe_field(feedback, 'EPL_B_legacy', 0);
rec.EPL_z_legacy = safe_field(feedback, 'EPL_z_legacy', 0);
rec.EPL_warning_legacy = safe_field(feedback, 'EPL_warning_legacy', 0);
rec.EPL_track_norm = safe_field(feedback, 'EPL_track_norm', 0);
rec.EPL_SC_norm = safe_field(feedback, 'EPL_SC_norm', 0);
rec.EPL_B_norm = safe_field(feedback, 'EPL_B_norm', 0);
rec.EPL_z_norm = safe_field(feedback, 'EPL_z_norm', 0);
rec.EPL_warning_norm = safe_field(feedback, 'EPL_warning_norm', 0);
rec.e_track_base = safe_field(feedback, 'e_track_base', 1);
rec.r_SC_base = safe_field(feedback, 'r_SC_base', 1);
rec.r_B_base = safe_field(feedback, 'r_B_base', 1);
rec.z_M_base = safe_field(feedback, 'z_M_base', 1);
rec.z_B_base = safe_field(feedback, 'z_B_base', 1);
rec.e_track = safe_field(feedback, 'e_track', 0);
rec.e_track_norm = safe_field(feedback, 'e_track_norm', 0);
rec.r_SC = safe_field(feedback, 'r_SC', 0);
rec.r_B = safe_field(feedback, 'r_B', 0);
rec.SC_SOC_before = read_info_soc(info, 'SOC_SC');
rec.B_SOC_before = read_info_soc(info, 'SOC_B');
rec.PM_ref_remain_before = PM_before(:);
rec.PB_ref_remain_before = PB_before(:);
rec.PM_ref_remain_after = PM_after(:);
rec.PB_ref_remain_after = PB_after(:);
rec.PM_ref_remain_delta_max_abs = delta_stats.PM_max_abs;
rec.PB_ref_remain_delta_max_abs = delta_stats.PB_max_abs;
rec.PM_ref_remain_delta_RMS = delta_stats.PM_RMS;
rec.PB_ref_remain_delta_RMS = delta_stats.PB_RMS;
rec.PM_ref_remain_delta_abs_sum = delta_stats.PM_abs_sum;
rec.PB_ref_remain_delta_abs_sum = delta_stats.PB_abs_sum;
rec.p_feedback = p_scalar;
rec.p_feedback_vector = p(:);
rec.p_feedback_mean = p_scalar;
rec.p_feedback_min = min_or_nan(p);
rec.p_feedback_max = max_or_nan(p);
rec.z_M = z_M;
rec.z_B = z_B;
rec.p_feedback_times_z_M = p_scalar * z_M;
rec.p_feedback_times_z_B = p_scalar * z_B;
rec.exitflag = exitflag;
rec.solver_message = solver_message;
rec.solve_time = solve_time;
rec.fallback_used = logical(fallback_used);
rec.fallback_reason = fallback_reason;
rec.constraint_violation_max = NaN;
rec.constraint_violation_mean = NaN;
end

function flags = reason_flags(reason)
flags = struct();
flags.tracking_triggered = contains(reason, 'tracking_error_high');
flags.SC_SOC_triggered = contains(reason, 'SC_SOC');
flags.B_SOC_triggered = contains(reason, 'Battery_SOC');
flags.EPL_triggered = contains(reason, 'EPL_');
flags.solver_failure_triggered = contains(reason, 'solver_failed') || contains(reason, 'fallback_used');
end

function s = append_struct(s, item)
if isempty(s)
    s = item;
else
    s(end+1, 1) = item;
end
end

function traj = init_traj_history()
traj.time = [];
traj.PM_ref_before = [];
traj.PB_ref_before = [];
traj.PM_ref_after = [];
traj.PB_ref_after = [];
traj.PM_final = [];
traj.PB_final = [];
traj.PSC_final = [];
traj.Battery_SOC = [];
traj.SC_SOC = [];
traj.tracking_error = [];
traj.event_trigger_flag = [];
traj.event_reason = {};
traj.lower_exitflag = [];
traj.lower_fallback_used = [];
end

function traj = append_traj_history(traj, global_idx, PM_ref_before, PB_ref_before, PM_ref_after, PB_ref_after, snd, flag, info)
traj.time(end+1, 1) = global_idx;
traj.PM_ref_before(end+1, 1) = PM_ref_before;
traj.PB_ref_before(end+1, 1) = PB_ref_before;
traj.PM_ref_after(end+1, 1) = PM_ref_after;
traj.PB_ref_after(end+1, 1) = PB_ref_after;
traj.PM_final(end+1, 1) = snd.PM_final;
traj.PB_final(end+1, 1) = snd.PB_final;
traj.PSC_final(end+1, 1) = snd.PSC_final;
traj.Battery_SOC(end+1, 1) = snd.xmeasure(2);
traj.SC_SOC(end+1, 1) = snd.xmeasure(3);
traj.tracking_error(end+1, 1) = sqrt((snd.PM_final - PM_ref_after)^2 + (snd.PB_final - PB_ref_after)^2);
traj.event_trigger_flag(end+1, 1) = flag;
if isfield(info, 'reasons') && ~isempty(info.reasons)
    traj.event_reason{end+1, 1} = strjoin(info.reasons, '|');
else
    traj.event_reason{end+1, 1} = '';
end
traj.lower_exitflag(end+1, 1) = snd.exitflag_current;
traj.lower_fallback_used(end+1, 1) = snd.fallback_used_current;
end

function upper = init_upper_history()
upper.k = [];
upper.grid_cost_hist = [];
upper.batt_deg_cost_hist = [];
upper.total_cost_hist = [];
end

function upper = append_upper_history_local(upper, k, grid_cost, batt_deg_cost, total_cost)
upper.k(end+1, 1) = k;
upper.grid_cost_hist(end+1, 1) = grid_cost;
upper.batt_deg_cost_hist(end+1, 1) = batt_deg_cost;
upper.total_cost_hist(end+1, 1) = total_cost;
end

function [grid_cost, batt_deg_cost, total_cost] = compute_upper_step_cost_local(fst)
u = fst.u_dyn(:, 1);
x = fst.x_dyn(1, :);
price = fst.price(1);
if u(1) >= 0
    grid_cost = price * u(1);
else
    grid_cost = 0.8 * price * u(1);
end
A = fst.battery.lifeParam(1, 1);
b = fst.battery.lifeParam(1, 2);
coeff = fst.battery.totalprice / (2 * A * (fst.battery.capacity ^ b));
if u(2) * x(1) >= 0
    batt_deg_cost = coeff * (abs(x(1) + u(2))^b - abs(x(1)^b));
else
    batt_deg_cost = coeff * abs(u(2))^b;
end
total_cost = grid_cost + batt_deg_cost;
end

function summary = summarize_event_history(h)
event_mask = h.trigger_flag ~= 0;
reopt_mask = h.reopt_attempt_flag ~= 0;
exitflags = h.upper_reopt_exitflag(reopt_mask);
solve_times = h.upper_reopt_time(reopt_mask);
summary = struct();
summary.event_count = sum(event_mask);
summary.reopt_count = sum(reopt_mask);
summary.events_with_nonzero_PM_ref_change = sum(event_mask & h.PM_ref_remain_delta_RMS > 1e-9);
summary.events_with_nonzero_PB_ref_change = sum(event_mask & h.PB_ref_remain_delta_RMS > 1e-9);
summary.mean_PM_ref_remain_delta_RMS = mean_or_nan(h.PM_ref_remain_delta_RMS(event_mask));
summary.mean_PB_ref_remain_delta_RMS = mean_or_nan(h.PB_ref_remain_delta_RMS(event_mask));
summary.max_PM_ref_remain_delta_RMS = max_or_nan(h.PM_ref_remain_delta_RMS(event_mask));
summary.max_PB_ref_remain_delta_RMS = max_or_nan(h.PB_ref_remain_delta_RMS(event_mask));
summary.fallback_count = sum(h.fallback_used ~= 0);
summary.strict_success_count = sum(exitflags > 0);
summary.exitflag0_count = sum(exitflags == 0);
summary.failure_count = sum(exitflags < 0);
summary.solve_time_mean = mean_or_nan(solve_times);
summary.solve_time_max = max_or_nan(solve_times);
summary.solve_time_p95 = percentile_or_nan(solve_times, 95);
summary.solve_time_over_300s_count = sum(solve_times > 300);
summary.p_feedback_mean = mean_or_nan(h.p_feedback_opt(event_mask));
summary.p_feedback_max = max_or_nan(h.p_feedback_opt(event_mask));
summary.p_feedback_nonzero_ratio = mean_or_nan(double(abs(h.p_feedback_opt(event_mask)) > 1e-9));
summary.z_M_mean = mean_or_nan(h.z_M(event_mask));
summary.z_B_mean = mean_or_nan(h.z_B(event_mask));
summary.pz_M_mean = mean_or_nan(h.p_feedback_times_z_M(event_mask));
summary.pz_B_mean = mean_or_nan(h.p_feedback_times_z_B(event_mask));
summary.EPL_micro_used_mean = mean_or_nan(h.EPL_micro_used(event_mask));
summary.EPL_micro_used_max = max_or_nan(h.EPL_micro_used(event_mask));
summary.EPL_micro_legacy_mean = mean_or_nan(h.EPL_micro_legacy(event_mask));
summary.EPL_micro_norm_mean = mean_or_nan(h.EPL_micro_norm(event_mask));
summary.EPL_track_legacy_mean = mean_or_nan(h.EPL_track_legacy(event_mask));
summary.EPL_SC_legacy_mean = mean_or_nan(h.EPL_SC_legacy(event_mask));
summary.EPL_B_legacy_mean = mean_or_nan(h.EPL_B_legacy(event_mask));
summary.EPL_z_legacy_mean = mean_or_nan(h.EPL_z_legacy(event_mask));
summary.EPL_warning_legacy_mean = mean_or_nan(h.EPL_warning_legacy(event_mask));
summary.EPL_track_norm_mean = mean_or_nan(h.EPL_track_norm(event_mask));
summary.EPL_SC_norm_mean = mean_or_nan(h.EPL_SC_norm(event_mask));
summary.EPL_B_norm_mean = mean_or_nan(h.EPL_B_norm(event_mask));
summary.EPL_z_norm_mean = mean_or_nan(h.EPL_z_norm(event_mask));
summary.EPL_warning_norm_mean = mean_or_nan(h.EPL_warning_norm(event_mask));
end

function print_event_log_summary(summary)
fprintf('\n================ Event Evidence Summary ================\n');
fprintf('event_count                         = %d\n', summary.event_count);
fprintf('reopt_count                         = %d\n', summary.reopt_count);
fprintf('events_with_nonzero_PM_ref_change   = %d\n', summary.events_with_nonzero_PM_ref_change);
fprintf('events_with_nonzero_PB_ref_change   = %d\n', summary.events_with_nonzero_PB_ref_change);
fprintf('mean_PM_ref_remain_delta_RMS        = %.6g\n', summary.mean_PM_ref_remain_delta_RMS);
fprintf('mean_PB_ref_remain_delta_RMS        = %.6g\n', summary.mean_PB_ref_remain_delta_RMS);
fprintf('max_PM_ref_remain_delta_RMS         = %.6g\n', summary.max_PM_ref_remain_delta_RMS);
fprintf('max_PB_ref_remain_delta_RMS         = %.6g\n', summary.max_PB_ref_remain_delta_RMS);
fprintf('strict_success / exitflag0 / failure = %d / %d / %d\n', ...
    summary.strict_success_count, summary.exitflag0_count, summary.failure_count);
fprintf('solve_time mean/max/p95             = %.6g / %.6g / %.6g\n', ...
    summary.solve_time_mean, summary.solve_time_max, summary.solve_time_p95);
fprintf('fallback_count                      = %d\n', summary.fallback_count);
fprintf('p_feedback mean/max/nonzero_ratio   = %.6g / %.6g / %.6g\n', ...
    summary.p_feedback_mean, summary.p_feedback_max, summary.p_feedback_nonzero_ratio);
fprintf('EPL used mean/max                   = %.6g / %.6g\n', ...
    summary.EPL_micro_used_mean, summary.EPL_micro_used_max);
fprintf('EPL legacy z mean / norm z mean     = %.6g / %.6g\n', ...
    summary.EPL_z_legacy_mean, summary.EPL_z_norm_mean);
fprintf('========================================================\n');
end

function params_out = merge_params(params_out, params_in)
fields = fieldnames(params_in);
for i = 1:numel(fields)
    params_out.(fields{i}) = params_in.(fields{i});
end
end

function value = safe_field(s, field, default_value)
if isstruct(s) && isfield(s, field) && ~isempty(s.(field)) && all(~isnan(s.(field)(:)))
    value = s.(field);
else
    value = default_value;
end
end

function value = safe_logical_field(s, field, default_value)
if isstruct(s) && isfield(s, field) && ~isempty(s.(field))
    value = logical(s.(field));
else
    value = default_value;
end
end

function value = read_char_field(s, field, default_value)
if isstruct(s) && isfield(s, field) && ~isempty(s.(field))
    value = s.(field);
else
    value = default_value;
end
end

function value = read_feedback_value(feedback, primary, fallback)
value = 0;
if isstruct(feedback) && isfield(feedback, primary) && ~isempty(feedback.(primary))
    value = feedback.(primary);
elseif isstruct(feedback) && isfield(feedback, fallback) && ~isempty(feedback.(fallback))
    value = feedback.(fallback);
end
value = mean_scalar(value);
end

function value = read_info_soc(info, field)
if isstruct(info) && isfield(info, field) && ~isempty(info.(field))
    value = info.(field);
else
    value = NaN;
end
end

function value = ref_scalar(ref_schedule, field, idx, default_value)
value = default_value;
if isstruct(ref_schedule) && isfield(ref_schedule, field) && ~isempty(ref_schedule.(field))
    v = ref_schedule.(field)(:);
    idx = min(max(1, idx), numel(v));
    value = v(idx);
end
end

function v = remain_ref(ref_schedule, field, start_idx)
v = [];
if isstruct(ref_schedule) && isfield(ref_schedule, field) && ~isempty(ref_schedule.(field))
    data = ref_schedule.(field)(:);
    if start_idx <= numel(data)
        v = data(start_idx:end);
    end
end
end

function d = align_delta(after, before)
after = after(:);
before = before(:);
n = min(numel(after), numel(before));
if n == 0
    d = [];
else
    d = after(1:n) - before(1:n);
end
end

function value = rms_or_zero(x)
x = x(:);
if isempty(x)
    value = 0;
else
    value = sqrt(mean(x.^2));
end
end

function value = max_abs_or_zero(x)
x = x(:);
if isempty(x)
    value = 0;
else
    value = max(abs(x));
end
end

function value = mean_scalar(x)
x = x(:);
x = x(~isnan(x));
if isempty(x)
    value = 0;
else
    value = mean(x);
end
end

function value = mean_or_nan(x)
x = x(:);
x = x(~isnan(x));
if isempty(x)
    value = NaN;
else
    value = mean(x);
end
end

function value = max_or_nan(x)
x = x(:);
x = x(~isnan(x));
if isempty(x)
    value = NaN;
else
    value = max(x);
end
end

function value = min_or_nan(x)
x = x(:);
x = x(~isnan(x));
if isempty(x)
    value = NaN;
else
    value = min(x);
end
end

function value = percentile_or_nan(x, p)
x = sort(x(:));
x = x(~isnan(x));
if isempty(x)
    value = NaN;
    return;
end
idx = max(1, min(numel(x), ceil(p / 100 * numel(x))));
value = x(idx);
end
