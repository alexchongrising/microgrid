function [ref_schedule, update_info] = fcnUpdateRemainingLowerReference(ref_schedule, event_solution, event_param, j_lower, params)
%FCNUPDATEREMAININGLOWERREFERENCE 事件触发后更新当前小时剩余 5 分钟参考。
% 已经执行过的参考不再修改；剩余参考采用事件 OCP 结果和旧参考的平滑融合。

if nargin < 5 || isempty(params)
    params = init_fankuiwei_params();
end
if ~isfield(params, 'event')
    default_params = init_fankuiwei_params();
    params.event = default_params.event;
end
gamma = params.event.reference_blend;
z_decay = params.event.z_decay;

PM_old = ref_schedule.PM_ref_after(:);
PB_old = ref_schedule.PB_ref_after(:);
PM_new = PM_old;
PB_new = PB_old;
start_idx = min(numel(PM_old) + 1, max(1, j_lower + 1));
idx = start_idx:numel(PM_old);

if isempty(idx)
    update_info = struct('updated_count', 0, 'p_feedback_opt', NaN, ...
        'PM_event', NaN, 'PB_event', NaN);
    return;
end

p_feedback_opt = read_solution_p(event_solution);
PM_event_base = event_param.PM_old + p_feedback_opt * event_param.z_M;
PB_event_base = event_param.PB_old + p_feedback_opt * event_param.z_B;
if isfield(event_solution, 'u_event') && ~isempty(event_solution.u_event)
    PM_event_base = event_solution.u_event(1, 1);
    PB_event_base = event_solution.u_event(2, 1);
end

for n = 1:numel(idx)
    decay = z_decay^(n - 1);
    PM_event = event_param.PM_old + decay * (PM_event_base - event_param.PM_old);
    PB_event = event_param.PB_old + decay * (PB_event_base - event_param.PB_old);
    PM_blend = gamma * PM_event + (1 - gamma) * PM_old(idx(n));
    PB_blend = gamma * PB_event + (1 - gamma) * PB_old(idx(n));
    [PM_blend, PB_blend] = project_reference(PM_blend, PB_blend, params);
    if idx(n) > 1
        PM_blend = rate_limit(PM_blend, PM_new(idx(n) - 1), read_rate(params, 'PM'));
        PB_blend = rate_limit(PB_blend, PB_new(idx(n) - 1), read_rate(params, 'PB'));
    end
    [PM_blend, PB_blend] = project_reference(PM_blend, PB_blend, params);
    PM_new(idx(n)) = PM_blend;
    PB_new(idx(n)) = PB_blend;
end

ref_schedule.PM_ref_after = PM_new;
ref_schedule.PB_ref_after = PB_new;
ref_schedule.PM_ref = PM_new;
ref_schedule.PB_ref = PB_new;

update_info = struct();
update_info.updated_count = numel(idx);
update_info.p_feedback_opt = p_feedback_opt;
update_info.PM_event = PM_event_base;
update_info.PB_event = PB_event_base;
update_info.start_idx = start_idx;
end

function p = read_solution_p(event_solution)
p = NaN;
if isstruct(event_solution) && isfield(event_solution, 'p_feedback_opt') && ~isempty(event_solution.p_feedback_opt)
    p = event_solution.p_feedback_opt;
elseif isstruct(event_solution) && isfield(event_solution, 'u_event') && size(event_solution.u_event, 1) >= 3
    p = event_solution.u_event(3, 1);
end
if isnan(p)
    p = 0;
end
p = min(1, max(0, p));
end

function [PM, PB] = project_reference(PM, PB, params)
PM = min(max(PM, read_param(params, 'PM_min', -5)), read_param(params, 'PM_max', 10));
PB = min(max(PB, read_param(params, 'PB_min', -4)), read_param(params, 'PB_max', 4));
end

function y = rate_limit(x, x_prev, limit_value)
if isinf(limit_value)
    y = x;
else
    y = min(max(x, x_prev - limit_value), x_prev + limit_value);
end
end

function value = read_rate(params, name)
field_new = ['delta_' name '_rate_max'];
field_old = ['rate_' name '_max'];
if isfield(params, field_new) && ~isempty(params.(field_new))
    value = params.(field_new);
elseif isfield(params, field_old) && ~isempty(params.(field_old))
    value = params.(field_old);
else
    value = inf;
end
end

function value = read_param(params, field, default_value)
if isstruct(params) && isfield(params, field) && ~isempty(params.(field))
    value = params.(field);
else
    value = default_value;
end
end
