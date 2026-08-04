# AWS EKS 标准可用性检查与特殊入口设计

## 1. 目标

将 AWS EKS 恢复到 `k8sAvailCheck.sh` 的统一标准检查流程。默认检查不得自动下载或执行高权限AWS建设脚本；只有检测到与某项AWS特殊能力直接相关的问题时，才向用户暴露上下文入口。

AWS 1.36权威物料目录：

```text
aws eks k8s/v1.36 eks v1.13 karpenter/01eks_build/
```

职责固定为：

- `build_eks_v1.36.sh`：新建Kubernetes 1.36 EKS；需要AWS Admin Full Access，先于可用性检查执行。
- `auto_build_nodepool.sh`：为已经存在且连通的EKS创建Karpenter NodePool。
- `storage_ready_for_existing_eks.sh`：为存量EKS补充EBS/EFS CSI、EFS及 `te-disk` / `te-nfs`。
- `set_nodepool_consolidation_policy.sh`：其治理逻辑并入通用检查脚本，不再作为独立入口维护。

所有发布脚本使用统一下载目录：

```text
https://download-thinkingdata.oss-cn-shanghai.aliyuncs.com/ta/tools/
```

## 2. 总体流程

```text
kubectl / kubeconfig检查
  ├─ 不存在或不可用
  │    └─ FAIL并停止；提示先完成集群创建、kubeconfig和授权
  │       若目标是AWS EKS，打印build_eks_v1.36.sh参考入口
  └─ 集群连通
       └─ 云平台识别
            ├─ 非AWS：保持现有标准流程
            └─ AWS EKS
                 └─ NodePool前置门禁
                      ├─ CRD缺失/查询异常：FAIL并停止
                      ├─ CRD存在、NodePool为0：立即询问是否执行auto_build_nodepool.sh
                      │    ├─ 确认并成功：结束本轮，要求重新执行标准检查
                      │    └─ 拒绝/超时/非TTY/失败：FAIL并停止
                      └─ 至少一个NodePool：执行完整标准检查
                           ├─ 节点组规划/Pod/契约/网络
                           ├─ te-disk / te-nfs与存储E2E
                           ├─ 历史测试PV清理
                           └─ 总览后提供命中的AWS修复入口
```

AWS不得再因 `check_aws_cloud_features` 提前 `return`，也不得把执行专用脚本登记成“可用性检查通过”。

## 3. kubeconfig与连接失败

没有可用kubeconfig时无法可靠判断云平台，所以错误信息保持跨云通用：

```text
未找到或无法使用KUBECONFIG。请先确认目标Kubernetes集群已经创建、访问凭证和RBAC授权已经配置，再重试可用性检查。
如果目标是AWS EKS：新集群请先参考build_eks_v1.36.sh；已有集群请先执行aws eks update-kubeconfig并确认kubectl cluster-info可用。
```

此路径只打印权威脚本名称和下载来源，不自动下载或执行 `build_eks_v1.36.sh`。

## 4. AWS NodePool前置门禁

### 4.1 CRD检查

精确查询：

```bash
kubectl get crd nodepools.karpenter.sh -o name
```

结果分流：

- 成功：继续查询NodePool对象。
- 明确 `NotFound`：Karpenter API未安装，记录FAIL并停止；不执行节点组创建脚本。
- `Forbidden`、连接错误或其他异常：记录FAIL并停止；不得误判为零NodePool。

### 4.2 NodePool对象检查

精确查询：

```bash
kubectl get nodepools.karpenter.sh \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
```

结果分流：

- 查询失败：记录FAIL并停止。
- 输出非空：打印NodePool名称并进入完整标准流程。
- 查询成功但输出为空：立即触发节点组创建交互。

普通Node、EKS Managed Node Group和 `kubectl get karpenter` 聚合输出均不能替代以上判断。

### 4.3 零NodePool交互

提示：

```text
当前AWS EKS已安装Karpenter NodePool CRD，但未发现任何标准NodePool资源。
是否下载并执行auto_build_nodepool.sh进入EKS节点组创建流程？[y/N]（30秒后跳过）:
```

行为：

- `Y/y`：下载、校验并以 `bash` 执行。
- 其他输入、30秒超时或非TTY：不执行，记录FAIL并结束本轮。
- 创建脚本成功：打印“节点组配置已变化，请重新运行k8sAvailCheck.sh完成标准检查”，结束本轮。
- 创建脚本失败：记录退出码和FAIL，结束本轮。

本轮不在节点组创建后继续检查，避免同一日志混合创建前后的两套集群状态。

## 5. 专用脚本下载与执行

统一helper仅接受白名单脚本名：

```text
auto_build_nodepool.sh
storage_ready_for_existing_eks.sh
```

固定行为：

1. 下载到 `/tmp/thinkingai/<script-name>`。
2. 下载失败、文件为空均终止该动作。
3. 执行 `bash -n`，语法失败不得执行。
4. 使用 `bash` 而不是 `sh`。
5. 透传真实退出码；禁止无条件登记PASS。
6. 日志打印下载URL、临时路径和人工执行命令。

`build_eks_v1.36.sh`只作为前置参考，不进入这个执行helper。

## 6. AWS完整标准检查

NodePool门禁通过后，AWS与其他托管云一致执行：

- 节点组业务规划选择；
- StorageClass检查；
- Pod并发调度与弹性能力检查；
- 节点池配置和契约检查；
- 本机、Pod、Service、MySQL与RTT检查；
- `te-disk` RWO；
- `te-nfs` RWX基础及跨节点共享；
- 测试PV回收；
- 结果总览。

AWS同规格常规池继续使用：

```text
reserved-${规格}|od-${规格}
```

任一候选可调度即满足该档。

## 7. 存量EKS补存储入口

AWS标准检查不得在缺少存储时静默转入建设流程。

以下任一条件将设置“需要存储修复”上下文：

- 缺少 `te-disk`；
- 缺少 `te-nfs`；
- 缺少 `ebs.csi.aws.com`；
- 缺少 `efs.csi.aws.com`；
- AWS存储E2E因PVC供给、挂载或读写失败。

检查项照常记录FAIL并继续非依赖项。完整总览和本轮临时资源清理完成后再询问：

```text
检测到当前AWS EKS存储未就绪，是否下载并执行storage_ready_for_existing_eks.sh？[y/N]（30秒后跳过）:
```

- `Y/y`：通过统一下载helper执行。
- 其他输入、超时或非TTY：跳过并打印手工命令。
- 执行结束后要求重新运行标准检查，不修改本轮既有总览。

AWS分支不再由通用脚本自动创建缺失的 `te-disk`；存量AWS存储建设统一交给专用脚本。

## 8. NodePool consolidation策略内置检查

`check_aws_cloud_features`只承担AWS只读审计：

```bash
kubectl get nodepool -o \
  jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.disruption.consolidationPolicy}{"\n"}{end}'
```

规则：

- 没有NodePool：由前置门禁处理。
- 全部为 `WhenEmpty` 或其他非目标值：记录PASS，不提供治理入口。
- 任一精确等于 `WhenEmptyOrUnderutilized`：列出名称并记录WARN，设置治理上下文。
- 查询失败：记录FAIL，不进入patch。

总览完成后，对候选再次查询确认并要求操作者输入完整 `yes`。只有仍为 `WhenEmptyOrUnderutilized` 的对象才执行：

```bash
kubectl patch nodepool "$name" --type=merge \
  -p '{"spec":{"disruption":{"consolidationPolicy":"WhenEmpty"}}}'
```

逐对象回读确认；任一失败均打印名称和实际值。该逻辑并入 `k8sAvailCheck.sh` 后，删除 `01eks_build/set_nodepool_consolidation_policy.sh`，历史由Git保留。

## 9. AWS后置动作顺序

标准总览完成后按以下顺序处理实际命中的上下文：

1. 存量EKS补存储；
2. consolidation策略治理。

节点组创建不在后置动作中，因为零NodePool已由前置门禁提前处理。

每项独立确认；一项拒绝或失败不自动授权下一项。完成任一变更后均提示重新运行标准检查。

## 10. 结果语义

- “AWS NodePool前置门禁”作为独立检查项进入总览。
- “AWS NodePool consolidation策略”作为独立检查项进入总览。
- 专用脚本的执行结果作为“后置动作结果”打印，不反向修改本轮标准检查的PASS/FAIL。
- AWS没有特殊问题时，只看到两项简短PASS，不展示无关入口。

## 11. 测试矩阵

### NodePool门禁

- CRD存在且有NodePool：继续标准流程，不下载脚本。
- CRD `NotFound`：FAIL并停止，不提示创建NodePool。
- CRD `Forbidden`：FAIL并停止，不误判为缺少NodePool。
- CRD存在、NodePool为0、输入 `y`：下载、`bash -n`、以Bash执行，随后结束并要求重跑。
- 同场景输入 `n`、超时、非TTY：不下载，FAIL并结束。
- 下载失败、空文件、语法失败、执行非零：分别保留准确失败原因。

### 标准流程

- AWS有NodePool时，Pod、契约、网络、RWO、RWX和总览全部执行。
- AWS不再出现“特殊流程处理，不再进行其他检测”。
- 非AWS平台调用链不改变。

### 存储入口

- AWS存储全部就绪：不展示入口。
- 任一SC/CSI缺失：标准检查记录FAIL，总览后才询问。
- 存储E2E失败：总览后提供入口。
- 拒绝、超时、非TTY：只打印手工命令。
- 确认执行：验证下载、语法、Bash执行和退出码。

### consolidation

- 无目标策略：PASS且不提示。
- 单个/多个目标：WARN并只列准确候选。
- 用户取消：无patch。
- 候选在确认前已变化：跳过该对象。
- patch失败或回读不一致：逐对象FAIL。
- 只修改 `spec.disruption.consolidationPolicy`，不删除、不重启、不驱逐资源。

## 12. 验收

本地必须通过：

```bash
bash -n k8sAvailCheck.sh
bash tests/test_k8s_avail_check.sh
bash tests/test_k8s_serverless_avail_check.sh
git diff --check
```

EKS现场至少覆盖：

1. 已有NodePool的正常集群完整跑完现有全部标准检查项及新增AWS审计项。
2. 隔离EKS中零NodePool前置提示，分别验证取消和确认创建。
3. 存储缺失时先完成总览，再出现补存储入口。
4. 含 `WhenEmptyOrUnderutilized` 的NodePool先WARN，确认后精确改为 `WhenEmpty` 并回读。

任何现场测试不得在生产集群构造零NodePool、删除CSI/SC或人为破坏网络。
