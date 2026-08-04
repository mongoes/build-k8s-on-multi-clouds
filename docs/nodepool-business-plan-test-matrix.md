# 节点组业务规划：核心功能验收矩阵

> 适用脚本：`k8sAvailCheck.sh`。每次现场验证保留完整日志、`k8sAvailCheckArtifacts_<时间戳>/` 目录及本表的实际结果；不要只凭脚本最终退出或整体总览通过验收。

## 执行前置条件

- 在真实终端执行（`test -t 0` 返回 0），除“非交互回退”用例外不得经管道、`nohup` 或 stdin 重定向启动。
- 先运行 `kubectl get nodes -L node.k8s.te/nodepool-name`，选择与当前环境完整业务规划相符的用例；脚本会创建 `debug` 探测资源及存储验证资源。
- 保存本次日志路径和物料目录；如用例故意选择不存在节点池，只验收节点组结论，不把该次整体结果当作集群可用性结论。

## ACK 现场用例

| ID | 前置条件 | 操作输入 | 预期关键输出 | 通过判定 / 证据 |
| --- | --- | --- | --- | --- |
| ACK-01 预制方案 | `reserved-4c32g`、`od-4c32g` 均为当前完整规划且可调度 | 选择 `1` | `已选择业务规划：Agent / 基础运营`；实际检查两池 | 总览“节点组业务规划”为 PASS；Pod 阶段为 2 档；保存日志 |
| ACK-02 自定义成功 | 存在 `reserved-4c32g` | 选择 `5`，输入 `reserved-4c32g` | 成功信息后立即进入块存储检查，不再出现“输入无效”或第二次菜单 | 总览显示“管理员自定义”；Pod 阶段仅 1 个探测目标 |
| ACK-02A 首层直接自定义 | 存在 `reserved-4c32g` | 在首层提示直接输入 `reserved-4c32g` | 立即显示“管理员自定义”；不要求先输入 `5` | Pod 阶段仅 1 个探测目标；不探测默认高规格池 |
| ACK-03 自定义校验重试 | 同 ACK-02 | 选择 `5`，依次输入 `bad-pool`、`reserved-4c32g` | 第一次提示格式错误和剩余次数；第二次成功且立即离开菜单 | 仅一次格式错误；最终实际检查为 `reserved-4c32g` |
| ACK-04 连续无效回退 | 可接受按旧默认全量规划进行一次检查 | 菜单输入 `9` 三次 | 三次错误后输出“连续3次输入无效，回退云厂商默认节点组” | 总览“节点组业务规划”为 WARN；实际检查为旧 ACK 四池 |
| ACK-05 菜单超时 | 可接受按旧默认全量规划进行一次检查 | 菜单出现后不输入，等待 30 秒 | 输出“交互输入超时，回退云厂商默认节点组” | WARN；整个脚本继续运行，不阻塞 |
| ACK-06 自定义超时 | 同 ACK-05 | 选择 `5` 后不输入，等待 30 秒 | 输出“自定义节点组输入超时” | WARN；回退旧 ACK 四池并继续运行 |
| ACK-07 历史 on-demand | 实际标签为 `on-demand-<规格>` | 选择 `5`，输入实际完整 `on-demand-<规格>` 名 | 实际检查池仍显示 `on-demand-<规格>`，不被改写为 `od-*` | Pod selector 与实际标签一致；契约不因名称改写报计划外 |

## GKE / AWS 语义用例

| ID | 前置条件 | 操作输入 | 预期关键输出 | 通过判定 / 证据 |
| --- | --- | --- | --- | --- |
| GKE-01 预制常规池 OR | 同规格常规池使用 `reserved-*` 或 `od-*` 任一命名 | 选择 `1` | 业务基准为 `reserved-4c32g od-4c32g`；实际检查为 `reserved-4c32g|od-4c32g` | Pod 阶段将该 OR 组作为 1 档；任一候选就绪即通过 |
| GKE-02 自定义 on-demand | 实际池名为 `on-demand-8c32g` | 选择 `5`，输入 `on-demand-8c32g` | 实际检查为 `reserved-8c32g|od-8c32g|on-demand-8c32g` | `on-demand` 是可调度候选，不被拆为 `on` / `demand-*` |
| AWS-01 当前边界 | EKS 特殊流程可安全运行 | 任一预制选择 | 总览记录业务规划，但随后进入 `auto_build_nodepool.sh` 特殊流程 | 仅验收选择记录；当前不把它当作通用 Pod/契约检查验收，直到 AWS 特殊流程接入最终契约 |

## 本地自动回归

```bash
bash -n k8sAvailCheck.sh
bash tests/test_k8s_avail_check.sh
bash tests/test_k8s_serverless_avail_check.sh
git diff --check
```

自动测试必须覆盖：预制方案跨云展开、自定义成功的真实 `record_result` 返回码、非法格式、`on-demand`、非交互回退及主流程接入。涉及 `read -t` 的真实终端超时和人工输入分支以本表现场用例验收。

## 收尾测试 PV 清理现场用例

> 仅在确认候选均为废弃测试资源的隔离或变更窗口内执行；先保存 `kubectl get pv -o wide`、候选 PV YAML 和 Filestore/NAS 后端证据。业务 `te-agent` PV 即使为 `Released` 也必须作为排除样本保留。

| ID | 前置条件 | 操作输入 | 预期关键输出 | 通过判定 / 证据 |
| --- | --- | --- | --- | --- |
| PV-00 收尾顺序 | 至少存在一个候选或允许无候选 | 完成全体存储端到端检查后观察输出 | “测试PV清理”在最后一个端到端存储检查之后、结果总览之前出现 | 它不抢占节点组选择；正常流程与 AWS 特殊流程均进入该步骤 |
| PV-01 精确候选清理 | 至少一个 PV 同时满足全部门槛；另有 `te-agent` Released PV | 出现候选后输入 `Y` | 打印候选的 PV/claim/SC/driver/volumeHandle；每个目标打印“已回收” | 目标 PV 已不存在，后端 share/卷已回收；业务 PV 未被 patch/delete |
| PV-02 管理员跳过 | 同 PV-01 | 输入 `N` | `历史测试PV清理` 为 SKIP，候选数正确 | 所有候选仍存在，日志中无 `patch pv`/`delete pv` |
| PV-03 超时默认清理 | 同 PV-01，真实 TTY | 不输入，等待 30 秒 | 明确提示确认超时并按默认策略清理 | 与 PV-01 相同的回收结论 |
| PV-04 非交互默认清理 | 同 PV-01，stdin 非 TTY | 例如由 agent 工具或 `</dev/null` 运行 | 明确提示非交互环境并按默认策略清理 | 与 PV-01 相同；脚本不等待输入 |
| PV-05 候选排除 | 构造 namespace 非 debug、业务 claim、SC 非 te-disk/te-nfs、PVC 尚存在、静态 PV 或 provisioner 不匹配的任一资源 | 正常运行 | 不出现在候选清单 | 不向这些 PV 发出 patch/delete；保存命令审计与 PV YAML |
