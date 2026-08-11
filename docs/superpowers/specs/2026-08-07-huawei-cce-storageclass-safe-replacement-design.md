# 华为 CCE StorageClass 安全替换设计

## 目标

让华为 CCE 可用性检查准确说明受保护的历史 StorageClass，并在管理员明确确认后，仅替换错误的 `te-nfs` StorageClass 对象为标准 CCE 文件存储定义；不得修改、删除或重建任何 PV、PVC 或 Pod。

## 范围

- 当 `te-disk` 被 PVC 或 PV 引用时，不更新到 GPSSD2；将此兼容保护视为检查通过，而不是告警或失败。
- `te-disk` 的结果说明必须明确：旧 SC 被业务存储使用，已绑定卷和现有 Pod 不受本次检查影响；GPSSD2 更新被有意跳过。
- 当华为 CCE 的 `te-nfs` 的 provisioner 或 VPC 参数不符合标准模板，且它被 PV/PVC 引用时，列出受影响引用并拒绝自动替换。
- 仅在交互终端中收到完整肯定确认后，删除旧 `te-nfs` StorageClass 并立即创建同名标准 CCE `te-nfs`。该动作只操作 StorageClass；PV、PVC、Pod 均不可成为 kubectl delete/apply/patch 的目标。

## 不变量与风险控制

- 确认提示须说明：已 Bound 的 PV/PVC 不会被本脚本直接改动，但管理员应先确认不存在依赖旧 SC 创建新 PVC 的流程。
- 无 TTY、超时、空输入、任何非明确肯定输入均跳过替换，并以失败结果要求人工处理。
- 删除成功但创建失败时，必须显示恢复指引、保留诊断物料，并记录失败；不可假报旧工作负载受影响。
- 标准 `te-nfs` 使用当前已验证的 Everest NAS 配置，VPC ID 仅使用 `csi-nas` 自动解析值或管理员显式提供且经冲突校验的 `HUAWEI_CCE_VPC_ID`。

## 行为流程

1. 检查 `te-disk`：有业务引用时记录 PASS，输出保护原因和 GPSSD2 未迁移说明；无引用时沿用现有创建/更新逻辑。
2. 检查 CCE `te-nfs`：先取得可信 VPC ID，读取 provisioner、`share-access-to`，并查询引用它的 PV/PVC。
3. 若 `te-nfs` 合规，直接通过；若不合规则保存诊断并打印引用清单。
4. 当没有引用时，沿用创建标准 SC 的正常路径；有引用时要求管理员在限定时间内完整输入 `yes`。
5. 确认后只执行 `kubectl delete sc te-nfs`，再 apply 标准 `te-nfs` YAML；创建后回读 provisioner 与 VPC 参数。任一阶段失败即记录 FAIL 并给出人工恢复步骤。

## 验证

shell 回归测试覆盖：

- 被引用的旧 `te-disk` 返回成功并包含 GPSSD2 保护提示。
- 不合规且被引用的 `te-nfs` 在未确认时不产生删除动作。
- 明确确认时只删除/创建 `StorageClass/te-nfs`，不调用 PV、PVC、Pod 的变更命令，且新定义通过回读校验。
- 删除后创建失败时记录失败和恢复指引。
