function results = fcnSummarizeUpperCosts(results)
%FCNSUMMARIZEUPPERCOSTS 统计上层调度周期总成本。
%
% 说明：
%   results.upper.grid_cost_hist 和 batt_deg_cost_hist 在 main_fankuiwei.m
%   中按每个上层阶段成本保存。这里默认它们已经是“阶段成本”，因此
%   直接 sum，不再额外乘时间步长，避免重复放大总成本。
%
% 输出字段：
%   results.upper.grid_cost_hist
%   results.upper.batt_deg_cost_hist
%   results.upper.total_cost_hist
%   results.upper.total_grid_cost_sum
%   results.upper.total_batt_deg_cost_sum
%   results.upper.total_upper_cost_sum

if ~isstruct(results)
    warning('fankuiwei:invalidResults', ...
        'Input results is not a struct. Skip upper cost summary.');
    return;
end

if ~isfield(results, 'upper') || ~isstruct(results.upper)
    warning('fankuiwei:missingUpperResults', ...
        'results.upper does not exist. Skip upper cost summary.');
    return;
end

grid_cost = read_cost_field(results.upper, ...
    {'grid_cost_hist', 'grid_cost', 'C_M_upper', 'upper_grid_cost_hist'}, ...
    'grid_cost_hist');

batt_deg_cost = read_cost_field(results.upper, ...
    {'batt_deg_cost_hist', 'batt_deg_cost', 'C_B_upper', 'upper_batt_deg_cost_hist'}, ...
    'batt_deg_cost_hist');

if isempty(grid_cost) && isempty(batt_deg_cost)
    warning('fankuiwei:missingUpperCostHist', ...
        'No upper-layer cost history was found. Summary fields are set to NaN.');
    results.upper.total_grid_cost_sum = NaN;
    results.upper.total_batt_deg_cost_sum = NaN;
    results.upper.total_upper_cost_sum = NaN;
    return;
end

if isempty(grid_cost)
    warning('fankuiwei:missingGridCostHist', ...
        'grid_cost_hist not found. It is filled with zeros using batt_deg_cost length.');
    grid_cost = zeros(size(batt_deg_cost));
end

if isempty(batt_deg_cost)
    warning('fankuiwei:missingBattDegCostHist', ...
        'batt_deg_cost_hist not found. It is filled with zeros using grid_cost length.');
    batt_deg_cost = zeros(size(grid_cost));
end

n = min(length(grid_cost), length(batt_deg_cost));
if length(grid_cost) ~= length(batt_deg_cost)
    warning('fankuiwei:upperCostLengthMismatch', ...
        'Cost history length mismatch. Use common length %d.', n);
end

grid_cost = grid_cost(1:n);
batt_deg_cost = batt_deg_cost(1:n);

if isfield(results.upper, 'total_cost_hist') && ~isempty(results.upper.total_cost_hist)
    total_cost = results.upper.total_cost_hist(:);
    if length(total_cost) ~= n
        warning('fankuiwei:totalCostLengthMismatch', ...
            'total_cost_hist length mismatch. Recompute it from grid_cost_hist + batt_deg_cost_hist.');
        total_cost = grid_cost + batt_deg_cost;
    else
        total_cost = total_cost(1:n);
    end
else
    total_cost = grid_cost + batt_deg_cost;
end

results.upper.grid_cost_hist = grid_cost;
results.upper.batt_deg_cost_hist = batt_deg_cost;
results.upper.total_cost_hist = total_cost;

results.upper.total_grid_cost_sum = sum(grid_cost);
results.upper.total_batt_deg_cost_sum = sum(batt_deg_cost);
results.upper.total_upper_cost_sum = sum(total_cost);

end

function value = read_cost_field(upper, candidate_names, canonical_name)
value = [];
for i = 1:length(candidate_names)
    name = candidate_names{i};
    if isfield(upper, name) && ~isempty(upper.(name))
        value = upper.(name)(:);
        if ~strcmp(name, canonical_name)
            warning('fankuiwei:costFieldAlias', ...
                'Use upper.%s as %s.', name, canonical_name);
        end
        return;
    end
end
end
