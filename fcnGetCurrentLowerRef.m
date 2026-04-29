function u0_ref = fcnGetCurrentLowerRef(ref_schedule, j_lower, horizon, params)
%FCNGETCURRENTLOWERREF 提取当前下层 MPC 预测窗口所需的 PM/PB 参考序列。
% 该函数把事件更新后的参考轨迹转换为 snd.u0_ref 格式：[PM; PB; PSC_ref]。

if nargin < 4
    params = struct(); %#ok<NASGU>
end
if nargin < 3 || isempty(horizon)
    horizon = 12;
end

PM = read_ref_vector(ref_schedule, 'PM_ref_after', 'PM_ref');
PB = read_ref_vector(ref_schedule, 'PB_ref_after', 'PB_ref');
if isempty(PM)
    PM = zeros(horizon, 1);
end
if isempty(PB)
    PB = zeros(size(PM));
end

idx = j_lower:(j_lower + horizon - 1);
idx(idx < 1) = 1;
idx(idx > numel(PM)) = numel(PM);
PM_win = PM(idx);
PB_win = PB(idx);
PSC_ref = zeros(size(PM_win));
u0_ref = [PM_win(:)'; PB_win(:)'; PSC_ref(:)'];
end

function v = read_ref_vector(s, primary, fallback)
v = [];
if isstruct(s) && isfield(s, primary) && ~isempty(s.(primary))
    v = s.(primary)(:);
elseif isstruct(s) && isfield(s, fallback) && ~isempty(s.(fallback))
    v = s.(fallback)(:);
end
end
