function [u_ref_new, ref_info] = fcnApplyFeedbackReference(u_ref_upper, feedback, p_feedback, params_fb, prev_ref)
%FCNAPPLYFEEDBACKREFERENCE Apply negotiated feedback to [PM_ref; PB_ref].
% Raw z_M/z_B are physical power correction requests. The normalized z
% values are used only by EPL and negotiation, not by this reference update.
if nargin < 5
    prev_ref = [];
end

u_ref_upper = u_ref_upper(:);
if length(u_ref_upper) < 2
    warning('fankuiwei:shortReference', ...
        'u_ref_upper has fewer than two elements. Missing entries are padded with zero.');
    u_ref_upper(2, 1) = 0;
end

ref_info = init_ref_info(u_ref_upper);

if isstruct(feedback) && isfield(feedback, 'active') && feedback.active
    z_M_total = read_feedback_field(feedback, 'z_M_total', feedback.z_M);
    z_B_total = read_feedback_field(feedback, 'z_B_total', feedback.z_B);
    delta_PM_raw = p_feedback * z_M_total;
    delta_PB_raw = p_feedback * z_B_total;
else
    delta_PM_raw = 0;
    delta_PB_raw = 0;
end

% 1. One-step amplitude clipping.
delta_PM_clipped = min(max(delta_PM_raw, -params_fb.delta_PM_max), params_fb.delta_PM_max);
delta_PB_clipped = min(max(delta_PB_raw, -params_fb.delta_PB_max), params_fb.delta_PB_max);

PM_ref_candidate = u_ref_upper(1) + delta_PM_clipped;
PB_ref_candidate = u_ref_upper(2) + delta_PB_clipped;

% 2. Physical projection.
PM_ref_projected = min(max(PM_ref_candidate, params_fb.PM_min), params_fb.PM_max);
PB_ref_projected = min(max(PB_ref_candidate, params_fb.PB_min), params_fb.PB_max);

% 3. Rate limit on adjacent dispatched references.
PM_ref_new = PM_ref_projected;
PB_ref_new = PB_ref_projected;
if ~isempty(prev_ref)
    prev_ref = prev_ref(:);
    if length(prev_ref) >= 2
        PM_rate = get_rate_limit(params_fb, 'PM');
        PB_rate = get_rate_limit(params_fb, 'PB');
        PM_ref_new = min(max(PM_ref_projected, prev_ref(1) - PM_rate), prev_ref(1) + PM_rate);
        PB_ref_new = min(max(PB_ref_projected, prev_ref(2) - PB_rate), prev_ref(2) + PB_rate);
    end
end

% 4. Project again after rate limiting.
PM_ref_new = min(max(PM_ref_new, params_fb.PM_min), params_fb.PM_max);
PB_ref_new = min(max(PB_ref_new, params_fb.PB_min), params_fb.PB_max);
u_ref_new = [PM_ref_new; PB_ref_new];

ref_info.PM_ref_candidate = PM_ref_candidate;
ref_info.PB_ref_candidate = PB_ref_candidate;
ref_info.PM_ref_projected = PM_ref_projected;
ref_info.PB_ref_projected = PB_ref_projected;
ref_info.PM_new = PM_ref_new;
ref_info.PB_new = PB_ref_new;
ref_info.delta_PM_raw = delta_PM_raw;
ref_info.delta_PB_raw = delta_PB_raw;
ref_info.delta_PM_clipped = delta_PM_clipped;
ref_info.delta_PB_clipped = delta_PB_clipped;
ref_info.delta_PM_final = PM_ref_new - u_ref_upper(1);
ref_info.delta_PB_final = PB_ref_new - u_ref_upper(2);

% Backward-compatible aliases.
ref_info.delta_PM = ref_info.delta_PM_final;
ref_info.delta_PB = ref_info.delta_PB_final;
ref_info.PM_ref_new = PM_ref_new;
ref_info.PB_ref_new = PB_ref_new;
end

function value = read_feedback_field(feedback, name, fallback_value)
if isstruct(feedback) && isfield(feedback, name) && ~isempty(feedback.(name))
    value = feedback.(name);
else
    value = fallback_value;
end
end

function ref_info = init_ref_info(u_ref_upper)
ref_info = struct();
ref_info.PM_old = u_ref_upper(1);
ref_info.PB_old = u_ref_upper(2);
ref_info.PM_new = u_ref_upper(1);
ref_info.PB_new = u_ref_upper(2);
ref_info.PM_ref_candidate = u_ref_upper(1);
ref_info.PB_ref_candidate = u_ref_upper(2);
ref_info.PM_ref_projected = u_ref_upper(1);
ref_info.PB_ref_projected = u_ref_upper(2);
ref_info.delta_PM_raw = 0;
ref_info.delta_PB_raw = 0;
ref_info.delta_PM_clipped = 0;
ref_info.delta_PB_clipped = 0;
ref_info.delta_PM_final = 0;
ref_info.delta_PB_final = 0;
ref_info.delta_PM = 0;
ref_info.delta_PB = 0;
ref_info.PM_ref_new = u_ref_upper(1);
ref_info.PB_ref_new = u_ref_upper(2);
end

function limit = get_rate_limit(params_fb, name)
field_new = ['delta_' name '_rate_max'];
field_old = ['rate_' name '_max'];
if isfield(params_fb, field_new) && ~isempty(params_fb.(field_new))
    limit = params_fb.(field_new);
elseif isfield(params_fb, field_old) && ~isempty(params_fb.(field_old))
    limit = params_fb.(field_old);
else
    limit = inf;
end
end
