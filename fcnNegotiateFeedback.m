function [p_feedback, negotiation] = fcnNegotiateFeedback(feedback, params_fb, state_fb)
%FCNNEGOTIATEFEEDBACK Compute the upper-layer acceptance ratio p_feedback.
% The trigger uses deadband + hysteresis. The negotiation cost uses
% normalized and clipped z requests, while physical raw z is kept for the
% later reference correction step.
if nargin < 3 || isempty(state_fb)
    state_fb = struct();
end
if ~isfield(state_fb, 'prev_active'), state_fb.prev_active = false; end
if ~isfield(state_fb, 'last_active_k'), state_fb.last_active_k = -inf; end
if ~isfield(state_fb, 'current_k'), state_fb.current_k = 0; end

negotiation = struct();
negotiation.C_extra = 0;
negotiation.benefit_feedback = 0;
negotiation.cost_feedback = 0;
negotiation.p_raw = 0;
negotiation.p_limited = 0;
negotiation.active = false;
negotiation.reason = 'inactive_feedback';
negotiation.EPL_deadband = params_fb.EPL_deadband;
negotiation.EPL_hysteresis = params_fb.EPL_hysteresis;
negotiation.interval_since_last = state_fb.current_k - state_fb.last_active_k;

p_feedback = 0;

if ~isstruct(feedback)
    negotiation.reason = 'invalid_feedback';
    return;
end

% Deadband + hysteresis:
% - inactive state turns on only above deadband + hysteresis;
% - active state turns off once EPL falls below deadband.
if state_fb.prev_active
    active_by_epl = feedback.EPL_micro > params_fb.EPL_deadband;
    if active_by_epl
        negotiation.reason = 'active_hold_above_off_threshold';
    else
        negotiation.reason = 'below_deadband';
    end
else
    active_by_epl = feedback.EPL_micro > params_fb.EPL_deadband + params_fb.EPL_hysteresis;
    if active_by_epl
        negotiation.reason = 'above_hysteresis';
    else
        negotiation.reason = 'below_on_threshold';
    end
end

if active_by_epl && negotiation.interval_since_last < params_fb.min_feedback_interval
    active_by_epl = false;
    negotiation.reason = 'suppressed_by_min_interval';
end

if ~active_by_epl
    return;
end

[z_M_norm_clipped, z_B_norm_clipped] = read_normalized_z(feedback, params_fb);

benefit_feedback = params_fb.lambda_loss * max(0, feedback.EPL_micro - params_fb.EPL_deadband);
cost_feedback = params_fb.lambda_cost * (z_M_norm_clipped^2 + z_B_norm_clipped^2);
p_raw = benefit_feedback / (benefit_feedback + cost_feedback + params_fb.eps_denom);
p_feedback = min(1, max(0, p_raw));

% Keep the physical correction within one-step maximum correction bounds.
if abs(feedback.z_M) > 0
    p_feedback = min(p_feedback, params_fb.delta_PM_max / ...
        (abs(feedback.z_M) + params_fb.eps_denom));
end
if abs(feedback.z_B) > 0
    p_feedback = min(p_feedback, params_fb.delta_PB_max / ...
        (abs(feedback.z_B) + params_fb.eps_denom));
end
p_feedback = min(1, max(0, p_feedback));

negotiation.C_extra = cost_feedback;
negotiation.benefit_feedback = benefit_feedback;
negotiation.cost_feedback = cost_feedback;
negotiation.p_raw = p_raw;
negotiation.p_limited = p_feedback;
negotiation.active = p_feedback > 0;
if negotiation.active
    negotiation.reason = 'accepted_by_rule';
else
    negotiation.reason = 'zero_after_limits';
end
end

function [z_M_norm_clipped, z_B_norm_clipped] = read_normalized_z(feedback, params_fb)
if isfield(feedback, 'z_M_norm_clipped') && isfield(feedback, 'z_B_norm_clipped')
    z_M_norm_clipped = feedback.z_M_norm_clipped;
    z_B_norm_clipped = feedback.z_B_norm_clipped;
    return;
end

warning('fankuiwei:missingNormalizedZ', ...
    'Normalized z fields are missing. They are reconstructed from raw z.');
z_M_norm_clipped = feedback.z_M / max(params_fb.delta_PM_max, params_fb.eps_denom);
z_B_norm_clipped = feedback.z_B / max(params_fb.delta_PB_max, params_fb.eps_denom);
if isfield(params_fb, 'z_norm_clip') && ~isempty(params_fb.z_norm_clip)
    z_M_norm_clipped = min(max(z_M_norm_clipped, -params_fb.z_norm_clip), params_fb.z_norm_clip);
    z_B_norm_clipped = min(max(z_B_norm_clipped, -params_fb.z_norm_clip), params_fb.z_norm_clip);
end
end
