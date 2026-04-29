function ref_schedule = fcnBuildLowerReferenceFromUpper(fst, snd, i_upper, params)
%FCNBUILDLOWERREFERENCEFROMUPPER 将上层小时级参考展开为下层 5 分钟参考轨迹。
% 上层 MPC 输出 PM/PB 的小时级经济调度；下层 MPC 需要 5 分钟尺度参考。
% 这里把当前小时及未来 from_fst 个上层步展开为 12 倍长度，作为事件触发更新的基础轨迹。

if nargin < 4
    params = struct();
end
if ~isfield(snd, 'iter') || isempty(snd.iter)
    snd.iter = 12;
end
if ~isfield(snd, 'from_fst') || isempty(snd.from_fst)
    snd.from_fst = 2;
end

u_upper = [];
if isfield(fst, 'u_dyn') && ~isempty(fst.u_dyn)
    u_upper = fst.u_dyn;
elseif isfield(fst, 'u0') && ~isempty(fst.u0)
    u_upper = fst.u0;
end
if isempty(u_upper)
    u_upper = zeros(2, max(1, snd.from_fst));
end
if size(u_upper, 1) < 2
    u_upper(2, :) = 0;
end

n_upper_ref = min(size(u_upper, 2), max(1, snd.from_fst));
PM = [];
PB = [];
upper_idx = [];
for k = 1:n_upper_ref
    PM = [PM; repmat(u_upper(1, k), snd.iter, 1)]; %#ok<AGROW>
    PB = [PB; repmat(u_upper(2, k), snd.iter, 1)]; %#ok<AGROW>
    upper_idx = [upper_idx; repmat(i_upper + k - 1, snd.iter, 1)]; %#ok<AGROW>
end

ref_schedule = struct();
ref_schedule.PM_ref = PM(:);
ref_schedule.PB_ref = PB(:);
ref_schedule.PM_ref_before = PM(:);
ref_schedule.PB_ref_before = PB(:);
ref_schedule.PM_ref_after = PM(:);
ref_schedule.PB_ref_after = PB(:);
ref_schedule.upper_idx = upper_idx(:);
ref_schedule.lower_per_upper = snd.iter;
ref_schedule.params = params;
end
