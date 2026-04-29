function [fst_event, event_param] = fcnBuildEventReoptProblem(fst, snd, feedback, ref_schedule, i_upper, j_lower, params)
%FCNBUILDEVENTREOPTPROBLEM 构造事件触发后的上层重优化问题。
% 该函数把下层反馈 z_M/z_B/EPL_micro 带入上层 OCP 参数，使上层通过 p_feedback
% 在经济性、退化成本和下层执行风险之间重新权衡。

if nargin < 7 || isempty(params)
    params = init_fankuiwei_params();
end
event_param = struct();
event_param.params = params;
event_param.feedback = feedback;
event_param.i_upper = i_upper;
event_param.j_lower = j_lower;
event_param.z_M = read_feedback(feedback, 'z_M_total', 'z_M');
event_param.z_B = read_feedback(feedback, 'z_B_total', 'z_B');
event_param.EPL_micro = read_feedback(feedback, 'EPL_micro_used', 'EPL_micro');
event_param.EPL_mode_used = read_text(feedback, 'EPL_mode_used', 'legacy');
event_param.EPL_micro_legacy = read_feedback(feedback, 'EPL_micro_legacy', 'EPL_micro');
event_param.EPL_micro_norm = read_feedback(feedback, 'EPL_micro_norm', 'EPL_micro');
event_param.PM_old = read_ref_at(ref_schedule, 'PM_ref_after', j_lower, 0);
event_param.PB_old = read_ref_at(ref_schedule, 'PB_ref_after', j_lower, 0);
event_param.PM_min = read_param(params, 'PM_min', -5);
event_param.PM_max = read_param(params, 'PM_max', 10);
event_param.PB_min = read_param(params, 'PB_min', -4);
event_param.PB_max = read_param(params, 'PB_max', 4);
event_param.previous_u = [];
event_param.lower_remaining_start = j_lower + 1;

if isfield(fst, 'u_dyn') && ~isempty(fst.u_dyn)
    event_param.previous_u = fst.u_dyn(1:2, :);
end

fst_event = fst;
if isfield(fst_event, 'load') && isfield(fst_event, 'PV') && isfield(fst_event, 'wind')
    % 原 fst_mpc 在函数内部临时计算 net_load，不会写回外部 fst。
    % 事件触发重优化需要独立构造功率平衡右端项，因此这里显式恢复。
    fst_event.net_load = fst_event.load * 2 - fst_event.PV / 3 - fst_event.wind;
end
if isfield(snd, 'xmeasure') && numel(snd.xmeasure) >= 2
    % 当前下层 5 分钟执行后的电池状态直接作为上层重算初始状态。
    fst_event.xmeasure = snd.xmeasure(1, 1:2);
end
if ~isfield(fst_event, 'u0') || isempty(fst_event.u0)
    fst_event.u0 = repmat([event_param.PM_old; event_param.PB_old], 1, fst_event.horizon);
end

p0 = 0.5;
if isfield(feedback, 'p_feedback') && ~isempty(feedback.p_feedback)
    p0 = min(1, max(0, feedback.p_feedback));
end
fst_event.u0_event = [fst_event.u0(1:2, :); repmat(p0, 1, size(fst_event.u0, 2))];
fst_event.event_param = event_param;
end

function value = read_feedback(feedback, primary, fallback)
value = 0;
if isstruct(feedback) && isfield(feedback, primary) && ~isempty(feedback.(primary))
    value = feedback.(primary);
elseif isstruct(feedback) && isfield(feedback, fallback) && ~isempty(feedback.(fallback))
    value = feedback.(fallback);
end
end

function value = read_text(feedback, primary, default_value)
if isstruct(feedback) && isfield(feedback, primary) && ~isempty(feedback.(primary))
    value = feedback.(primary);
else
    value = default_value;
end
end

function value = read_ref_at(ref_schedule, field, idx, default_value)
value = default_value;
if isstruct(ref_schedule) && isfield(ref_schedule, field) && ~isempty(ref_schedule.(field))
    v = ref_schedule.(field)(:);
    idx = min(max(1, idx), numel(v));
    value = v(idx);
end
end

function value = read_param(params, field, default_value)
if isstruct(params) && isfield(params, field) && ~isempty(params.(field))
    value = params.(field);
else
    value = default_value;
end
end
