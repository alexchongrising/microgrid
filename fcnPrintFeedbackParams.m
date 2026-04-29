function fcnPrintFeedbackParams(params)
%FCNPRINTFEEDBACKPARAMS Print and assert active feedback parameters.
if nargin < 1 || isempty(params)
    params = init_fankuiwei_params();
end

fprintf('\n================ Feedback parameter summary ================\n');
fprintf('Case name                       = %s\n', read_text_field(params, 'case_name', 'scheme_B_norm_deadband8_traj_warning_no_asym'));
fprintf('Purpose                         = restore main paper scheme B\n');
fprintf('SC warning mode                 = trajectory min/max\n');
fprintf('Asymmetric SC warning           = %s\n', logical_to_text(read_field(params, 'use_asymmetric_SC_warning', false)));
fprintf('Normalization enabled      = %s\n', logical_to_text(read_field(params, 'enable_z_normalization', true)));
fprintf('Soft z saturation          = %s\n', logical_to_text(read_field(params, 'use_soft_z_saturation', true)));
fprintf('EPL_deadband                    = %.6g\n', params.EPL_deadband);
fprintf('EPL_hysteresis                  = %.6g\n', params.EPL_hysteresis);
fprintf('min_feedback_interval           = %.6g\n', params.min_feedback_interval);
fprintf('lambda_loss                     = %.6g\n', params.lambda_loss);
fprintf('lambda_cost                     = %.6g\n', params.lambda_cost);
fprintf('alpha_track                     = %.6g\n', params.alpha_track);
fprintf('alpha_SC                        = %.6g\n', params.alpha_SC);
fprintf('alpha_B                         = %.6g\n', params.alpha_B);
fprintf('alpha_SC_warning                = %.6g\n', params.alpha_SC_warning);
fprintf('alpha_z                         = %.6g\n', params.alpha_z);
fprintf('ratio_PM                        = %.6g\n', params.ratio_PM);
fprintf('ratio_PB                        = %.6g\n', params.ratio_PB);
fprintf('delta_PM_max                    = %.6g\n', params.delta_PM_max);
fprintf('delta_PB_max                    = %.6g\n', params.delta_PB_max);
fprintf('delta_PM_rate_max               = %.6g\n', params.delta_PM_rate_max);
fprintf('delta_PB_rate_max               = %.6g\n', params.delta_PB_rate_max);
fprintf('k_M_track                       = %.6g\n', params.k_M_track);
fprintf('k_M_SC                          = %.6g\n', params.k_M_SC);
fprintf('k_M_balance                     = %.6g\n', params.k_M_balance);
fprintf('k_B_track                       = %.6g\n', params.k_B_track);
fprintf('k_B_SC                          = %.6g\n', params.k_B_SC);
fprintf('k_B_safe                        = %.6g\n', params.k_B_safe);
fprintf('enable_SC_warning_feedback      = %s\n', logical_to_text(read_field(params, 'enable_SC_warning_feedback', true)));
fprintf('use_SC_trajectory_extreme_warning = %s\n', logical_to_text(read_field(params, 'use_SC_trajectory_extreme_warning', false)));
fprintf('SOC_SC_warning_min/max          = %.6g / %.6g\n', params.SOC_SC_warning_min, params.SOC_SC_warning_max);
fprintf('SOC_SC_eval_min/max             = %.6g / %.6g\n', ...
    params.SOC_SC_soft_min, params.SOC_SC_soft_max);
fprintf('k_SC_warning_M                  = %.6g\n', params.k_SC_warning_M);
fprintf('k_SC_warning_B                  = %.6g\n', params.k_SC_warning_B);
if read_field(params, 'use_asymmetric_SC_warning', false)
    fprintf('k_SC_warning_M_low/high         = %.6g / %.6g\n', ...
        params.k_SC_warning_M_low, params.k_SC_warning_M_high);
    fprintf('k_SC_warning_B_low/high         = %.6g / %.6g\n', ...
        params.k_SC_warning_B_low, params.k_SC_warning_B_high);
    fprintf('alpha_SC_warning_low/high       = %.6g / %.6g\n', ...
        params.alpha_SC_warning_low, params.alpha_SC_warning_high);
end
fprintf('SC_warning_clip                 = %.6g\n', params.SC_warning_clip);
fprintf('use_smooth_SC_warning           = %s\n', logical_to_text(read_field(params, 'use_smooth_SC_warning', true)));
fprintf('z_norm_clip                     = %.6g\n', params.z_norm_clip);
fprintf('use_soft_z_saturation           = %s\n', logical_to_text(read_field(params, 'use_soft_z_saturation', true)));
fprintf('SOC_B_eval_min/max              = %.6g / %.6g\n', ...
    params.SOC_B_soft_min, params.SOC_B_soft_max);
fprintf('============================================================\n');

assert_close(params.EPL_deadband, 8.5, 'EPL_deadband did not update to 8.5.');
assert_close(params.EPL_hysteresis, 3.0, 'EPL_hysteresis did not update to 3.0.');
assert_close(params.min_feedback_interval, 2, 'min_feedback_interval did not update to 2.');
assert_close(params.lambda_loss, 1.0, 'lambda_loss did not update to 1.0.');
assert_close(params.lambda_cost, 3.3, 'lambda_cost did not update to 3.3.');
assert_close(params.alpha_track, 2.2, 'alpha_track did not update to 2.2.');
assert_close(params.alpha_SC, 2.6, 'alpha_SC did not update to 2.6.');
assert_close(params.alpha_B, 2.8, 'alpha_B did not update to 2.8.');
assert_close(params.alpha_SC_warning, 2.4, 'alpha_SC_warning did not update to 2.4.');
assert_close(params.alpha_z, 0.35, 'alpha_z did not update to 0.35.');
assert_close(params.ratio_PM, 0.10, 'ratio_PM did not update to 0.10.');
assert_close(params.ratio_PB, 0.052, 'ratio_PB did not update to 0.052.');
assert_close(params.delta_PM_rate_max, 0.55, 'delta_PM_rate_max did not update to 0.55.');
assert_close(params.delta_PB_rate_max, 0.22, 'delta_PB_rate_max did not update to 0.22.');
assert_close(params.k_M_track, 0.55, 'k_M_track did not update to 0.55.');
assert_close(params.k_M_SC, 0.95, 'k_M_SC did not update to 0.95.');
assert_close(params.k_M_balance, 0.60, 'k_M_balance did not update to 0.60.');
assert_close(params.k_B_track, 0.65, 'k_B_track did not update to 0.65.');
assert_close(params.k_B_SC, 0.25, 'k_B_SC did not update to 0.25.');
assert_close(params.k_B_safe, 1.25, 'k_B_safe did not update to 1.25.');
assert(read_field(params, 'enable_SC_warning_feedback', false) == true, ...
    'enable_SC_warning_feedback did not update to true.');
assert(read_field(params, 'use_SC_trajectory_extreme_warning', false) == true, ...
    'use_SC_trajectory_extreme_warning did not update to true.');
assert(read_field(params, 'use_asymmetric_SC_warning', true) == false, ...
    'use_asymmetric_SC_warning did not update to false.');
assert_close(params.SOC_SC_warning_min, 0.26, 'SOC_SC_warning_min did not update to 0.26.');
assert_close(params.SOC_SC_warning_max, 0.75, 'SOC_SC_warning_max did not update to 0.75.');
assert_close(params.k_SC_warning_M, 1.10, 'k_SC_warning_M did not update to 1.10.');
assert_close(params.k_SC_warning_B, 0.18, 'k_SC_warning_B did not update to 0.18.');
assert_close(params.k_SC_warning_M_low, 1.20, 'k_SC_warning_M_low did not update to 1.20.');
assert_close(params.k_SC_warning_M_high, 0.90, 'k_SC_warning_M_high did not update to 0.90.');
assert_close(params.k_SC_warning_B_low, 0.22, 'k_SC_warning_B_low did not update to 0.22.');
assert_close(params.k_SC_warning_B_high, 0.14, 'k_SC_warning_B_high did not update to 0.14.');
assert_close(params.alpha_SC_warning_low, 2.6, 'alpha_SC_warning_low did not update to 2.6.');
assert_close(params.alpha_SC_warning_high, 1.8, 'alpha_SC_warning_high did not update to 1.8.');
assert_close(params.SC_warning_clip, 1.0, 'SC_warning_clip did not update to 1.0.');
assert(read_field(params, 'use_smooth_SC_warning', false) == true, ...
    'use_smooth_SC_warning did not update to true.');
assert_close(params.z_norm_clip, 3.5, 'z_norm_clip did not update to 3.5.');
assert(read_field(params, 'use_soft_z_saturation', false) == true, ...
    'use_soft_z_saturation did not update to true.');
assert_close(params.SOC_SC_soft_min, 0.20, 'SOC_SC_soft_min did not remain 0.20.');
assert_close(params.SOC_SC_soft_max, 0.80, 'SOC_SC_soft_max did not remain 0.80.');
assert_close(params.SOC_B_soft_min, 0.15, 'SOC_B_soft_min did not remain 0.15.');
assert_close(params.SOC_B_soft_max, 0.85, 'SOC_B_soft_max did not remain 0.85.');
end

function value = read_text_field(s, field_name, default_value)
if isstruct(s) && isfield(s, field_name) && ~isempty(s.(field_name))
    value = s.(field_name);
else
    value = default_value;
end
end

function assert_close(value, expected, message)
assert(abs(value - expected) < 1e-9, message);
end

function value = read_field(s, field_name, default_value)
if isstruct(s) && isfield(s, field_name)
    value = s.(field_name);
else
    value = default_value;
end
end

function txt = logical_to_text(value)
if value
    txt = 'true';
else
    txt = 'false';
end
end
