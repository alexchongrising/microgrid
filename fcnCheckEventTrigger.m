function [event_triggered, event_info, fb_state] = fcnCheckEventTrigger(feedback, snd, fb_state, params, global_lower_idx, j_lower)
%FCNCHECKEVENTTRIGGER 判断是否需要在 5 分钟尺度触发上层重优化。
% 事件由下层执行压力驱动：跟踪误差、SOC 风险、EPL_micro 或求解失败都会触发。
% fb_state 记录滞环、最小事件间隔和每小时事件次数，避免频繁重算。

if nargin < 3 || isempty(fb_state)
    fb_state = struct();
end
if nargin < 4 || isempty(params)
    params = init_fankuiwei_params();
end
if ~isfield(params, 'event')
    default_params = init_fankuiwei_params();
    params.event = default_params.event;
end
event = params.event;

fb_state = init_state_fields(fb_state);
event_info = init_event_info(feedback, snd, global_lower_idx, j_lower);
event_triggered = false;

if isfield(event, 'enable') && ~event.enable
    event_info.reasons = {'event_disabled'};
    return;
end

reasons = {};
EPL_for_trigger = safe_get(feedback, 'EPL_micro_used', safe_get(feedback, 'EPL_micro', 0));
if EPL_for_trigger > event.EPL_on
    reasons{end+1} = 'EPL_micro_high'; %#ok<AGROW>
elseif fb_state.event_latched && EPL_for_trigger > event.EPL_off
    reasons{end+1} = 'EPL_hysteresis_hold'; %#ok<AGROW>
end

SOC_B = event_info.SOC_B;
SOC_SC = event_info.SOC_SC;
if ~isnan(SOC_SC) && (SOC_SC < event.SC_soft_min || SOC_SC > event.SC_soft_max)
    reasons{end+1} = 'SC_SOC_soft_risk'; %#ok<AGROW>
end
if ~isnan(SOC_B) && (SOC_B < event.B_soft_min || SOC_B > event.B_soft_max)
    reasons{end+1} = 'Battery_SOC_soft_risk'; %#ok<AGROW>
end
if safe_get(feedback, 'e_track_norm', 0) > event.track_on
    reasons{end+1} = 'tracking_error_high'; %#ok<AGROW>
end
if isfield(snd, 'exitflag_current') && ~isempty(snd.exitflag_current) && snd.exitflag_current <= 0
    reasons{end+1} = 'lower_solver_failed'; %#ok<AGROW>
end
if isfield(snd, 'fallback_used_current') && ~isempty(snd.fallback_used_current) && snd.fallback_used_current ~= 0
    reasons{end+1} = 'lower_fallback_used'; %#ok<AGROW>
end

if isempty(reasons)
    fb_state.event_latched = false;
    event_info.reasons = {'no_event'};
    return;
end

remaining_steps = max(0, safe_get(fb_state, 'lower_steps_per_upper', 12) - j_lower);
interval_ok = (global_lower_idx - fb_state.last_event_idx) >= event.min_event_interval;
count_ok = fb_state.event_count_this_upper < event.max_event_per_upper;
remaining_ok = remaining_steps >= event.min_remaining_steps;

if interval_ok && count_ok && remaining_ok
    event_triggered = true;
    fb_state.last_event_idx = global_lower_idx;
    fb_state.event_count_this_upper = fb_state.event_count_this_upper + 1;
    fb_state.event_latched = true;
else
    if ~interval_ok
        reasons{end+1} = 'suppressed_by_min_interval'; %#ok<AGROW>
    end
    if ~count_ok
        reasons{end+1} = 'suppressed_by_max_event_per_upper'; %#ok<AGROW>
    end
    if ~remaining_ok
        reasons{end+1} = 'suppressed_by_few_remaining_steps'; %#ok<AGROW>
    end
end

event_info.reasons = reasons;
event_info.event_triggered = event_triggered;
event_info.remaining_steps = remaining_steps;
end

function fb_state = init_state_fields(fb_state)
if ~isfield(fb_state, 'last_event_idx'), fb_state.last_event_idx = -inf; end
if ~isfield(fb_state, 'event_count_this_upper'), fb_state.event_count_this_upper = 0; end
if ~isfield(fb_state, 'event_latched'), fb_state.event_latched = false; end
if ~isfield(fb_state, 'lower_steps_per_upper'), fb_state.lower_steps_per_upper = 12; end
end

function event_info = init_event_info(feedback, snd, global_lower_idx, j_lower)
event_info = struct();
event_info.global_lower_idx = global_lower_idx;
event_info.j_lower = j_lower;
event_info.reasons = {};
event_info.event_triggered = false;
event_info.EPL_micro = safe_get(feedback, 'EPL_micro', 0);
event_info.EPL_micro_used = safe_get(feedback, 'EPL_micro_used', event_info.EPL_micro);
event_info.EPL_mode_used = read_text(feedback, 'EPL_mode_used', 'legacy');
event_info.r_SC = safe_get(feedback, 'r_SC', 0);
event_info.r_B = safe_get(feedback, 'r_B', 0);
event_info.e_track_norm = safe_get(feedback, 'e_track_norm', 0);
event_info.z_M = read_z(feedback, 'z_M_total', 'z_M');
event_info.z_B = read_z(feedback, 'z_B_total', 'z_B');
event_info.SOC_B = NaN;
event_info.SOC_SC = NaN;
if isstruct(snd) && isfield(snd, 'xmeasure') && numel(snd.xmeasure) >= 3
    event_info.SOC_B = snd.xmeasure(2);
    event_info.SOC_SC = snd.xmeasure(3);
end
end

function value = read_text(s, field, default_value)
if isstruct(s) && isfield(s, field) && ~isempty(s.(field))
    value = s.(field);
else
    value = default_value;
end
end

function value = safe_get(s, field, default_value)
if isstruct(s) && isfield(s, field) && ~isempty(s.(field)) && all(~isnan(s.(field)(:)))
    value = s.(field);
else
    value = default_value;
end
end

function value = read_z(feedback, primary, fallback)
if isstruct(feedback) && isfield(feedback, primary) && ~isempty(feedback.(primary))
    value = feedback.(primary);
elseif isstruct(feedback) && isfield(feedback, fallback) && ~isempty(feedback.(fallback))
    value = feedback.(fallback);
else
    value = 0;
end
end
