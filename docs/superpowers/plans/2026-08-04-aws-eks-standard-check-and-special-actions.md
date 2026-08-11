# AWS EKS 标准检查回归与按需特殊入口实施计划

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 AWS EKS 回归 `k8sAvailCheck.sh` 的完整标准检查流程，同时只在真实故障场景中、经管理员明确确认后进入节点组或存储修复流程，并把 NodePool consolidation 审计与安全修复合并到通用脚本。

**Architecture:** AWS 平台识别后先执行只读 Karpenter NodePool 前置门禁；只有 CRD 存在且资源数为零时才提供 `auto_build_nodepool.sh` 入口并结束本轮。存在 NodePool 时继续统一的节点组、存储、调度、网络和端到端验证。AWS 存储缺失与 consolidation 偏差只在标准检查完成、总览已经打印后提供可选修复入口，所有外部脚本均经过白名单、非空和 `bash -n` 校验。

**Tech Stack:** Bash 4+、kubectl、Karpenter `nodepools.karpenter.sh` CRD、wget、现有 Shell mock 测试框架。

---

## Task 1：为 AWS NodePool 前置门禁建立失败测试

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_k8s_avail_check.sh`

1. 新增静态断言：AWS 主流程不得在 `check_aws_cloud_features` 后提前 `return 0`，外部工具必须用 `bash` 而非 `sh`。
2. 新增函数级测试，覆盖：
   - CRD `NotFound` 返回失败且不下载工具；
   - CRD/NodePool 查询 `Forbidden` 返回失败且不误判为空；
   - 存在 NodePool 时返回成功并继续；
   - CRD 存在但零 NodePool，输入 `Y/y` 时下载、语法检查并执行；
   - 拒绝、超时或非 TTY 时不执行高权限脚本并返回失败。
3. 运行新增测试并确认因缺少新门禁函数而按预期失败。

## Task 2：实现安全的 AWS 工具入口与 NodePool 门禁

**Files:**
- Modify: `k8sAvailCheck.sh`
- Test: `tests/test_k8s_avail_check.sh`

1. 增加固定下载基址、工具白名单和 `/tmp/thinkingai` 临时路径。
2. 实现统一下载执行函数：下载失败、空文件、`bash -n` 失败、执行非零均保留精确错误并返回失败；仅允许两个已批准脚本名。
3. 实现 `check_aws_nodepool_gate`，严格区分 CRD 不存在、权限/查询失败、零对象和已有对象。
4. 将门禁接入云平台识别之后、节点组业务规划之前：
   - 已有 NodePool 继续完整标准流程；
   - 零 NodePool 且工具成功后提示重新运行并结束本轮；
   - 其他失败均打印本轮总览后结束，不执行后续无效探测。
5. 删除 AWS 的旧提前成功分支，确保不再无条件记录 `auto_build_nodepool` PASS。
6. 运行定向测试直至通过。

## Task 3：建立 AWS 存储缺失按需修复的失败测试

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_k8s_avail_check.sh`

1. 新增测试覆盖 AWS 缺少 `te-disk`、`te-nfs`、EBS CSI 或 EFS CSI 时只标记修复需求，不在标准检查阶段静默创建资源。
2. 新增测试覆盖总览后：
   - TTY 输入 `Y/y` 执行 `storage_ready_for_existing_eks.sh`；
   - 拒绝、超时、非 TTY 仅打印人工命令；
   - 工具失败不会覆盖前面真实检查结果。
3. 运行测试并确认因现有 AWS 分支仍自动创建 StorageClass 而按预期失败。

## Task 4：实现 AWS 存储审计与总览后修复入口

**Files:**
- Modify: `k8sAvailCheck.sh`
- Test: `tests/test_k8s_avail_check.sh`

1. 增加 AWS 存储修复状态变量和原因聚合函数。
2. 在 AWS 特性检查中只读检查 `ebs.csi.aws.com`、`efs.csi.aws.com` CSIDriver。
3. AWS 缺失 `te-disk`/`te-nfs` 时按标准检查记录 FAIL 并设置修复标记，不修改默认 SC、不自动 apply。
4. AWS 存储端到端验证失败时补充修复原因，避免只检查对象存在却忽略不可用。
5. 在 `finalize_availability_check` 打印总览之后调用存储修复询问；执行后要求管理员重新运行完整检查。
6. 运行定向测试直至通过。

## Task 5：建立 consolidation 审计与修复的失败测试

**Files:**
- Modify: `tests/test_set_nodepool_consolidation_policy.sh`
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_set_nodepool_consolidation_policy.sh`

1. 将原独立脚本测试改为 source 通用检查脚本内函数。
2. 覆盖：
   - 所有 NodePool 已为 `WhenEmpty` 时 PASS；
   - `WhenEmptyOrUnderutilized` 时 WARN 并收集精确候选；
   - 字段为空或未知值时只披露，不擅自修复；
   - 总览后只有完整输入 `yes` 才执行 merge patch；
   - patch 前重新读取，状态已变化则跳过；
   - patch 后必须读回 `WhenEmpty` 才算成功；
   - 查询或 patch 失败保留失败明细。
3. 运行测试并确认因通用脚本尚无对应函数而按预期失败。

## Task 6：合并 consolidation 逻辑并移除独立入口

**Files:**
- Modify: `k8sAvailCheck.sh`
- Delete: `aws eks k8s/v1.36 eks v1.13 karpenter/01eks_build/set_nodepool_consolidation_policy.sh`
- Modify: `tests/test_set_nodepool_consolidation_policy.sh`

1. 将只读 audit 接入 AWS 特性检查，标准流程中不改集群。
2. 在总览后提供 consolidation 修复确认，要求管理员完整输入 `yes`。
3. 对每个候选实施“重读—精确 merge patch—读回验证”，避免并发状态变化和误报成功。
4. 删除独立脚本，保证 consolidation 只有通用检查脚本这一处维护入口。
5. 运行 consolidation 定向测试直至通过。

## Task 7：补齐 kubeconfig/连接失败指引与完整回归

**Files:**
- Modify: `k8sAvailCheck.sh`
- Modify: `tests/test_k8s_avail_check.sh`
- Modify: `STATUS.md`
- Modify: `docs/decisions.md`

1. 在 kubeconfig 缺失或集群连接失败时增加条件化 AWS EKS 提示：
   - 确认 EKS 已由 `build_eks_v1.36.sh` 创建；
   - 确认 AWS 密钥授权与 `aws eks update-kubeconfig` 已完成；
   - 不自动下载或执行建集群脚本。
2. 运行：
   - `bash -n k8sAvailCheck.sh`
   - `bash tests/test_k8s_avail_check.sh`
   - `bash tests/test_k8s_serverless_avail_check.sh`
   - `bash tests/test_set_nodepool_consolidation_policy.sh`
   - 四个保留 AWS v1.36 脚本的 `bash -n`
3. 检查 `git diff --check`，复核未写入 kubeconfig、密钥、令牌或真实集群标识。
4. 更新 `STATUS.md` 与 `docs/decisions.md`：记录标准流程、前置门禁、后置修复入口、权限边界、线上待验样例。
5. 提供线上验收矩阵，至少覆盖：
   - CRD 不存在；
   - CRD Forbidden；
   - 零 NodePool 的 Y 与拒绝/超时；
   - 已有 NodePool 的完整标准流程；
   - AWS 存储缺失；
   - consolidation 合规与不合规。
