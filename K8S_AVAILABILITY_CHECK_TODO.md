# K8S 可用性检查：待办与进度台账

> 范围：统一入口 `k8sAvailCheck.sh` 的 Standard / Serverless / Hybrid 检查，以及 replicas 相关变体。
>
> 更新节奏：**每半周至少更新一次**（建议周三、周六），并在完成、阻塞或发现回归时即时更新。
> 本文只追踪尚未闭环的事项；已验证结论保留在“已确认基线”中，避免重复施工。

## 当前目标

让可用性检查在标准节点、弹性节点和 Serverless 场景中，能对存储、调度、镜像拉取、DNS/网络和 MySQL 连通性给出可解释、可回归验证的结论。

## 待办清单

| 优先级 | 状态 | 待办 | 完成标准 | 当前阻塞 / 下一步 | 责任人 |
| --- | --- | --- | --- | --- | --- |
| P0 | 已现场验证 | GKE Filestore `te-nfs` 网络参数自动注入 | StorageClass 使用由执行主机主网卡 Metadata 路径提取的网络短名称，不再隐式依赖 `default` | 2026-07-30 修复后实测：SC 创建为 `network=default`，RWX PVC 成功动态供给、挂载读写；完整 Metadata 路径不再直传 Filestore | Codex/用户 |
| P2 | 阻塞（待授权/环境） | GKE Filestore `te-nfs` 成本与实例复用现场核验 | 记录每个 `instance-storageclass-label` 对应的 Filestore 实例数、容量、share 数和月度预算 | 需目标 GCP 项目 `filestore.instances.list/get` 与账单查看权限；优先使用已有多个 `te-nfs` PVC 的集群，避免为测试额外产生 1TiB Filestore 成本 | 用户/云平台管理员 |
| P0 | 已现场验证 | 回灌线上确认的 `max-volume-size` | 仓库 `te-nfs` 模板与脚本均包含 `max-volume-size: "128Gi"`，且只维护 `te-nfs` 这个名称 | 2026-07-30 修复后新建 SC 已确认 `max-volume-size=128Gi`，并成功完成 RWX PVC 动态供给；实际实例/share 装箱和成本见下一项 | Codex/用户 |
| P0 | 已现场验证 | 临时存储探测 PV / Filestore share 回收 | 任一 `te-csi-check-*` PVC 绑定的 PV 在清理前被显式切换为 `Delete`，删除 PVC 后不遗留 `Released` PV 或 share | 2026-07-30 二次 GKE 实测，3 个本轮临时 PV 均打印“已回收”；历史 Released PV 不由本轮自动删除 | 待定 |
| P0 | 已定位并实施，待现场复验 | 腾讯 TKE Serverless 临时 PV 回收 | 本轮 `probe-run` 下每个临时 PVC 的绑定 PV 均先切为 `Delete`、PVC 删除后在可接受时限内消失；超时必须保留 PV/CSI 证据并准确失败 | `pvc-c37c5c19-5187-498e-a273-e8518c32ad34` 已在60秒后自行消失，根因是CBS异步回收超过旧60秒等待而非清理遗漏；默认等待已调整为180秒，可由`STORAGE_PV_RECLAIM_TIMEOUT`覆盖。待下一次单EKlet回灌确认无假FAIL | Codex/用户 |
| P0 | 已现场验证 | 清理历史 `te-csi-check-*` Released PV / Filestore share | 仅清理已核验为 `Released`、`debug/te-csi-check-*`、Filestore CSI 且无 PVC/Pod 引用的历史 PV，并确认后端 share 消失 | 用户确认历史 9 个测试 PV/share 已按安全流程清理完成；禁止把业务 `te-nfs` SC 改为 Delete | 用户/云平台管理员 |
| P1 | 已实现，待现场验证 | 收尾识别并清理历史测试残留 PV | 候选必须通过 Released/debug/固定测试 claim/te-disk 或 te-nfs/CSI 动态卷/SC provisioner/PVC 不存在的全部门槛；所有正常路径在总览前展示后 `N` 跳过，30 秒超时或非 TTY 默认清理 | 本地 mock 已覆盖合格候选删除与业务 Released PV 排除；待 CCE 或隔离环境回灌 Y、N、超时三条路径 | Codex/用户 |
| P0 | 已现场验证 | GKE `te-nfs` RWX 跨节点共享验证 | Writer/Reader 位于不同节点，Reader 能读取 Writer 写入的 token，临时 PV/share 均回收 | 用户确认双节点真实验证已符合预期 | 用户/Codex |
| P0 | 已现场验证 | GKE Filestore `te-nfs` 端到端验证 | CSI、StorageClass、PVC、挂载 Pod 与检查结论均正确 | SC 创建、RWX PVC Bound、Pod 挂载读写、临时 PV 回收及双节点 Writer/Reader 跨节点共享均已现场通过 | Codex/用户 |
| P2 | 阻塞（待授权/环境） | 标准节点 `te-nfs` 异常分流回归 | 能准确区分：无 CSI、无 StorageClass、PVC 绑定失败、挂载失败和成功 | 需独立 GKE Standard 项目/VPC、可启停 Filestore CSI/API 与控制 NFS 网络的权限；先补 Event 分类逻辑后再跑异常矩阵 | 用户/云平台管理员 |
| P0 | 部分现场验证，待修复回收问题后闭环 | 腾讯 TKE Serverless（单 EKlet）统一主脚本回归 | 识别为 `Serverless`；虚拟节点固定调度、ClusterIP、历史MySQL配置回退、RWO、RWX基础、同虚拟节点双Pod共享、统一总览和本轮资源回收均符合预期 | 2026-08-07 回灌：前述功能检查全部通过；MySQL `ta3:3306` 已按 TCP 握手正确通过；跨虚拟节点 RWX 因仅一个健康虚拟节点 SKIP。仅 PV 回收失败，见“腾讯 TKE Serverless 临时 PV 回收”专项 | Codex/用户 |
| P0 | 设计待review | AWS EKS回归统一标准检查流程 | 已有NodePool的EKS执行完整标准检查；零NodePool前置门禁只在明确确认后进入创建；存储与consolidation按真实问题暴露入口 | 已形成 `docs/superpowers/specs/2026-08-04-aws-eks-standard-check-and-special-actions-design.md`；review后进入实施计划 | Codex/用户 |
| P1 | 已实现，待现场验证 | Kyverno K8S兼容性检查 | `te-system` / `kube-system` 中存在 Kyverno 且 K8S>=1.34 时，发现任一版本<1.18.0或无法解析版本即重装一次；失败明确提示人工命令 | 本地矩阵已覆盖未安装、低版本、`kyvernopre`、混合/无法解析、低 K8S 版本和重装失败；待真实环境回灌 | Codex/用户 |
| P1 | 已现场验证 | 托管云节点组业务规划交互 | 预制业务方案和自定义节点组能统一驱动 Pod 探测、节点组契约及总览；菜单首层可直接输入合法自定义节点组；GCP/AWS OR 语义和 30 秒超时正确 | 2026-08-03 GKE 交互实测：直接输入 `reserved-4c32g` 后展开为 `reserved-4c32g|od-4c32g`、打印 OR 说明并选中现存 `od-4c32g`，规划及 Pod 探测均 PASS | Codex/用户 |
| P1 | 已现场验证 | 火山云节点可分配内存展示 | 仅在火山云域内把 memory Quantity 的 `m` milli-byte 展示为合理 GiB；其他云、CPU 和磁盘格式化行为不变 | 2026-08-03 VKE 实测：识别 `volcengine` 后 capacity=31.1Gi、allocatable=27.2Gi、CPU=3.9C，节点契约继续通过；非火山云隔离由本地负向样例覆盖 | Codex/用户 |
| P1 | 已现场验证 | 节点池扩容结论展示真实性 | 仅在本轮观察到目标池从无节点变为 Pod 可调度时展示 `0→1`；已有节点场景不得声称已验证扩容 | 2026-08-03 GKE 单档成功路径实测：已有36天的 `od-4c32g` 可调度，实时成功结论和结果总览均未出现 `0→1` | Codex/用户 |
| P1 | 进行中 | 核心功能测试样例矩阵与逐项验收 | 每项新功能均有前置条件、输入、预期输出、通过判定和现场证据；不得仅以整体脚本执行完成验收 | 先为节点组业务规划补齐交互成功/失败/超时/回退矩阵，再推广至后续功能 | Codex/用户 |
| P1 | 待验证 | CCE NAS / Everest 兼容性复测 | `csi-nas`、`everest.io/share-access-to` 与 VPC ID 解析在真实 CCE 集群有效 | 收集集群版本、SC、PVC Event 和脚本输出 | 待定 |
| P1 | 待验证 | 调度与弹性扩容异常可解释性 | `Unschedulable`、`NotTriggerScaleUp`、冷启动均有最终摘要，不能卡在“探测中” | 验证 `ELASTIC_COLD_START_GRACE=120` 是否适合目标集群 | 待定 |
| P1 | 待验证 | 网络与依赖探测回归 | 镜像拉取、DNS、MySQL 地址解析、TCP 握手 RTT 的失败原因可区分 | 为每类失败保留最小证据与预期输出 | 待定 |
| P2 | 待整理 | 云与场景回归矩阵 | 下方矩阵中每个目标场景都有日期、结果、证据位置 | 每完成一次现场验证即补齐矩阵 | 待定 |
| P2 | 待整理 | 脚本说明与变更记录 | 写明 GKE Filestore API 前置条件、CCE NAS 差异及 Serverless 边界 | 将已验证结论同步到脚本说明/项目状态文档 | 待定 |
| P2 | 已现场验证 | 非 TTY 节点组规划立即回退 | stdin 非 TTY 时不等待 30 秒，记录 WARN 并回退云厂商默认 map | 2026-08-03 VKE 非交互实测立即回退五池默认 map 并登记 WARN；环境仅有 reserved-4c32g，故其余四池按契约失败，行为符合设计 | Codex/用户 |
| P2 | 已现场验证 | Pod 部署结果展示就绪节点池 | 节点池部署检查的实时结论和总览同时列出成功的节点池名与未通过档位 | 2026-07-30 二次 GKE 实测显示 `就绪节点池: od-4c32g` | 待定 |
| P2 | 已现场验证 | Pod 到云主机延迟实时结果展示 | 每个节点池 × MySQL 目标采样完成后，立即输出通过/失败、RTT 与阈值 | 2026-07-30 二次 GKE 实测即时显示 `od-4c32g -> ta3:3306 0ms (<50ms)` | 待定 |

### 不应合并的边界

- `k8sAvailCheck.sh` 是唯一入口：根据模式执行 Standard、Serverless 或 Hybrid 分支；不再维护独立 Serverless 脚本。
- Serverless 可读取虚拟节点元数据用于模式识别和固定调度，但不得执行标准节点池容量、节点池契约、NodePort 或宿主机网络检查。
- Standard 存储端到端与 Serverless 临时资源回收必须复用 `_storage_e2e_cleanup`：仅本轮临时 PV 在删 PVC 前切为 `Delete`，不得改变业务 StorageClass 的 `Retain`。
- AWS 节点组生命周期检查继续与通用检查器分离，避免通用脚本被云厂商专属逻辑污染。

## 已确认基线

| 结论 | 含义 |
| --- | --- |
| GKE Filestore 报 `PermissionDenied` 且涉及 `file.googleapis.com` | 优先确认并启用 Cloud Filestore API；这是环境前置条件。 |
| 存储探测顺序 | 先检查 CSI，再检查 StorageClass，避免误导性报错。 |
| 异常运行行为 | 无论调度或扩容是否失败，脚本都应完成并输出汇总。 |
| Serverless 兼容策略 | 读取虚拟节点元数据用于识别和固定调度；移除标准节点池、NodePort、宿主机网络前提。 |

## P0 执行说明：GKE Filestore 初始化 `te-nfs`

### 0. 范围与初始化边界

- 本项仅覆盖 **GKE 标准节点** 的动态供给，不包含 Serverless。
- `te-nfs` 是 Filestore CSI 驱动创建的 Enterprise Multishare StorageClass；创建 StorageClass 本身不会创建 Filestore 实例。
- 第一个引用 `te-nfs` 的 PVC（本模板使用 `volumeBindingMode: Immediate`）才会触发实际的 Filestore share / PV 供给。
- 当前业务模板采用 `reclaimPolicy: Retain`：删除 PVC/PV 后可能保留后端资源，测试前必须确认清理与成本责任人。

### 1. 已验证的业务模板（待从原仓库恢复后逐字比对）

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: te-nfs
provisioner: filestore.csi.storage.gke.io
parameters:
  tier: enterprise
  multishare: "true"
  instance-storageclass-label: te-nfs
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: Immediate
mountOptions:
  - nolock
  - hard
  - timeo=600
  - retrans=3
```

> 这是 2026-07-21 已通过脚本回归校验的模板字段。实际初始化前，必须从原 checkout 的 `health-check-yaml/nfs-sc/te-nfs-sc.google.yaml` 取回并与上表比对；原 `k8sAvailCheck.sh` 的 Google 分支也应只引用该模板。

### 2. 初始化前置条件与检查

| Gate | 必须确认的事实 | 建议检查命令 / 证据 | 不满足时的处理 |
| --- | --- | --- | --- |
| GCP 项目与集群上下文 | 当前 `gcloud` 项目、目标 GKE 集群、region/zone 明确且与业务环境一致 | `gcloud config get-value project`; `kubectl config current-context`; `kubectl cluster-info` | 停止；先明确目标项目和集群，禁止在默认上下文 apply。 |
| Filestore API | `file.googleapis.com` 已启用 | `gcloud services list --enabled --filter='config.name:file.googleapis.com' --format='value(config.name)'` | 执行 `gcloud services enable file.googleapis.com --project=<PROJECT_ID>`，等待生效后再继续。 |
| Filestore CSI Driver | Standard GKE 已启用 `GcpFilestoreCsiDriver`，驱动可见 | `kubectl get csidriver filestore.csi.storage.gke.io`; `kubectl get sc` | 未启用时：`gcloud container clusters update <CLUSTER> --update-addons=GcpFilestoreCsiDriver=ENABLED --location=<LOCATION>`。 |
| GKE / 节点支持度 | Linux 节点；GKE 版本支持 Enterprise Multishare 与目标 NFS 协议 | `kubectl get nodes -o wide`; `gcloud container clusters describe <CLUSTER> --location=<LOCATION>` | 不能满足时不初始化；先升级或改用受支持的存储方案。 |
| 网络拓扑 | 确认是普通 VPC 还是 Shared VPC；网络能为 Filestore 提供私有连接 | 记录 VPC、自定义网段、是否 Shared VPC；Shared VPC 还需检查 host project 授权与 Private Service Access | Shared VPC 不要套默认模板；StorageClass 需明确 `network` 和 `connect-mode: PRIVATE_SERVICE_ACCESS`。 |
| IAM | GKE / Filestore 服务账号具备创建及管理 Filestore 实例的权限；操作者具备查看与 apply 权限 | 保存 `gcloud projects get-iam-policy <PROJECT_ID>` 中相关服务账号绑定；`kubectl auth can-i create storageclass` | 权限不足先由云平台管理员授予；`SERVICE_DISABLED` 是 API 问题，不是 YAML 问题。 |
| 配额与成本 | Enterprise Multishare 的容量、区域和配额足够；明确测试可产生的后端实例成本 | `gcloud filestore locations describe <REGION>`（如可用）及配额/预算截图 | 没有预算/配额确认时，不能创建测试 PVC。 |
| 命名冲突 | 集群不存在不兼容的 `te-nfs` StorageClass | `kubectl get sc te-nfs -o yaml` | 存在时先比对 provisioner/parameters；StorageClass 不可原地修改，漂移时新建名称或经变更流程迁移。 |
| 回收与证据 | 预先确定 PVC、Pod、PV 和后端 share 的清理检查方法 | 记录测试 namespace、PVC 名称和执行窗口 | `Retain` 下不能假设删除 PVC 即完成清理。 |

### 3. 推荐的执行顺序（每一步有停点）

1. **收集上下文**：确认 `<PROJECT_ID>`、`<CLUSTER>`、`<LOCATION>`、VPC 类型和测试 namespace；保存命令输出。
2. **通过全部 Gate**：尤其是 `file.googleapis.com`、CSI driver、Shared VPC/IAM、预算和 `te-nfs` 是否已存在。
3. **恢复并审阅原模板**：从原 checkout 取回 `health-check-yaml/nfs-sc/te-nfs-sc.google.yaml`，与上方业务模板逐项 diff；不要手写一个“相近模板”替代。
4. **只初始化 StorageClass**：`kubectl apply -f health-check-yaml/nfs-sc/te-nfs-sc.google.yaml`，随后 `kubectl describe sc te-nfs`；此时不应把“StorageClass 创建成功”当作存储可用。
5. **最小 PVC/Pod 验证**：创建一个业务允许的最小 RWX PVC 和挂载写读 Pod，检查 PVC Bound、PV `csi.driver=filestore.csi.storage.gke.io`、Pod 成功读写。
6. **记录和清理**：把 `describe pvc/pod` Event、PV `volumeHandle`、实际 Filestore 实例/分享信息和清理结果写入半周进度表；因 `Retain` 额外确认后端资源是否仍保留。

### 4. 现场失败分流

| 现象 | 首先看什么 | 结论 / 动作 |
| --- | --- | --- |
| PVC `Pending`，Event 含 `PermissionDenied`、`403`、`SERVICE_DISABLED`、`file.googleapis.com` | `kubectl describe pvc <PVC>` | 启用 Cloud Filestore API 后重建 PVC；不修改 CSI/YAML。 |
| `filestore.csi.storage.gke.io` 不存在 | `kubectl get csidriver` 与集群 addons | 先启用 GKE Filestore CSI driver。 |
| Shared VPC 下供给失败 | SC 的 `network`/`connect-mode`、host project IAM 和 Private Service Access | 按 Shared VPC 方式建专用 SC，不使用普通 VPC 默认值。 |
| PVC Bound 但 Pod 挂载或读写失败 | `kubectl describe pod`、节点网络、NFS 权限/导出规则 | 检查节点到 Filestore 的网络可达性和 POSIX 权限；不要先重建 PVC。 |

### 5. 进入实际初始化前必须由环境提供的四项信息

1. `<PROJECT_ID>`、`<CLUSTER>`、`<LOCATION>` 与 `kubectl config current-context` 输出。
2. VPC 模式：普通 VPC 或 Shared VPC；若 Shared VPC，提供 host project ID 和 network 名称。
3. GKE Standard 集群版本与是否已启用 Filestore CSI Driver。
4. 本次验证允许创建的测试 namespace、PVC 容量上限，以及 `Retain` 后端资源清理责任人。

## 半周进度记录

> 填写规则：每次记录写清楚“做了什么、证据在哪、结论是什么、下一步是什么”。没有进展也记录阻塞原因。

| 日期 | 本期完成 / 发现 | 证据（命令输出、Event、日志、PR） | 结论 | 下一步 | 更新人 |
| --- | --- | --- | --- | --- | --- |
| 2026-07-28 | 建立待办台账；历史遗留项待按当前代码和真实集群状态复核 | 本文件 | 待办按标准节点、Serverless、CCE/GKE 和公共可靠性分组 | 先确认当前脚本分支、变更与可用测试集群 | Codex |
| 2026-07-28 | 梳理 GKE Filestore 初始化 `te-nfs` 的模板、Gate、执行顺序和失败分流 | 本文件“P0 执行说明”及 GKE 官方 Filestore CSI 文档 | 先验证 API、CSI、VPC/IAM、配额和现有 SC，再创建 StorageClass；创建 SC 不等于完成存储验证 | 获取目标 GKE 环境的四项信息后执行现场 Gate | Codex |
| 2026-07-29 | 实现单一 `te-nfs` 的 GCE Metadata network 注入与 128Gi Multishare 策略 | `bash -n k8sAvailCheck.sh`、`bash tests/test_k8s_avail_check.sh`、`bash tests/test_k8s_serverless_avail_check.sh` | 自动路径只读取主网卡 network；失败路径不 apply、记录 FAIL 并输出客户手工 YAML；不创建 `te-nfs-128` | 在真实 GKE Standard 集群验证 StorageClass、PVC、挂载读写及 Filestore 实例/share 数 | Codex |
| 2026-07-30 | 历史 GKE Standard 真实回灌 | 用户提供的 `k8sAvailCheck.sh` 完整输出 | `te-disk`、`te-nfs` RWX 基础与跨节点读写均通过；节点池旧标签/污点风险被如实披露且不阻断后续检查；发现临时 PV 遗留、成功节点池未在部署结论列名、延迟实时输出缺失 | 修复 P0 回收；补足两项 P2 展示；另在不存在 `te-nfs` 的环境验证 Metadata 自动创建分支 | 用户/Codex |
| 2026-07-30 | 修复临时 PV 回收与两项现场展示缺陷 | `bash tests/test_k8s_avail_check.sh`、`bash -n k8sAvailCheck.sh` | 仅临时 `te-csi-check-*` PV 在删 PVC 前改为 `Delete` 并等待回收；部署结论和延迟采样均即时显示实际通过对象 | 在真实 GKE 回灌确认 PV/share 无残留；自动创建 SC 分支仍待无既有 `te-nfs` 的环境验证 | Codex |
| 2026-07-30 | 二次 GKE 真实验证 P0/P2 修复 | 用户回灌日志 `k8sAvailCheckResult_2026-07-30_161230.log` | 新生成的 3 个临时 PV（`f7e...`、`3b85...`、`2faa...`）均已回收；成功节点池和实时延迟信息均完整展示。末尾 9 个 Released PV 是旧脚本遗留 | 历史 Released PV 另行盘点并经变更流程清理；GKE 自动创建 SC 分支仍待验证 | 用户/Codex |
| 2026-07-30 | GKE Metadata network 修复后真实验证 | 用户回灌日志 `k8sAvailCheckResult_2026-07-30_234552.log` | 新建 `te-nfs` 的参数为 `network=default`、`max-volume-size=128Gi`；RWX PVC 动态供给、挂载读写及临时 PV 回收通过。单节点环境使跨节点验证正确 SKIP | 在至少两个节点的 GKE 集群验证 RWX 跨节点共享；核验 Filestore 实例/share 装箱和成本 | 用户/Codex |
| 2026-07-30 | 核销 GKE 历史 PV 清理与双节点 RWX | 用户确认 | 历史 9 个 `debug/te-csi-check-*` Released PV/share 已清理；双节点 RWX 共享验证已通过 | 转向 Filestore 成本/实例复用核验与标准节点异常分流回归设计 | 用户/Codex |
| 2026-08-07 | 腾讯 TKE Serverless 单 EKlet 主脚本回灌 | 用户提供的 `k8sAvailCheckResult_2026-08-07_212349.log` 摘要及 `kubectl get pv` | 模式识别、固定虚拟节点调度、ClusterIP、历史 MySQL 配置回退与 TCP 握手、`te-disk` RWO、`te-nfs` RWX基础和同虚拟节点双Pod共享均通过；跨虚拟节点 RWX 因单虚拟节点正确SKIP。本轮 `te-disk` PV 在 60 秒内未回收，且发现此前多轮 Serverless `te-nfs` Released PV | 按本轮 `probe-run=sl-20260807-212349-33285` 取证超时 PV 的回收策略、finalizer 和 CSI Event；确认公共 `_storage_e2e_cleanup` 在 TKE CBS 上的异步回收边界，再决定是否调整等待或分类 | 用户/Codex |
| 2026-08-10 | 腾讯CBS回收阈值与Serverless历史残留追踪 | 用户确认异常PV后续已消失；`bash tests/test_k8s_avail_check.sh`、`bash tests/test_k8s_serverless_avail_check.sh` | 60秒是假失败窗口，不是CBS/CSI删除故障；本轮等待默认调整为180秒。历史扫描已安全纳入精确`sl-disk/sl-nfs/sl-nfs-shared/sl-nfs-cross`测试命名，Serverless收尾也执行同一历史PV清理流程 | 在腾讯现场确认候选仅包含现有Released `debug/sl-*`测试PV，确认清理后无残留且业务PV不受影响 | Codex/用户 |

## 回归矩阵

| 平台 / 场景 | CSI | StorageClass / PVC | 预期检查结论 | 最近验证日期 | 结果 | 证据位置 |
| --- | --- | --- | --- | --- | --- |
| GKE 标准节点 + Filestore | 有 | `te-nfs` RWX 可绑定、可挂载 | 通过；若 API 未启用，明确报环境前置条件 | 2026-07-30 | RWX基础通过；跨节点因仅 1 节点跳过 | 用户回灌 `k8sAvailCheckResult_2026-07-30_234552.log` |
| GKE 标准节点 + 无 Filestore API | 可能有 | PVC 失败 | 明确指出权限/API 阻塞 | 待验证 | 待验证 | - |
| Huawei CCE + NAS | 有 | `te-nfs` 可用 | 正确识别 Everest/NAS/VPC 要求 | 待验证 | 待验证 | - |
| 无 CSI | 无 | 任意 | 明确指出 CSI 缺失，不误报 SC/PVC | 待验证 | 待验证 | - |
| 有 CSI、无匹配 SC | 有 | 无 | 明确指出 StorageClass 缺失 | 待验证 | 待验证 | - |
| 调度失败 / 不触发扩容 | 有 | Pod Pending | 最终摘要包含失败原因和建议 | 待验证 | 待验证 | - |
| 腾讯 TKE Serverless + 单 EKlet | 腾讯CSI | `te-disk` RWO、`te-nfs` RWX | 虚拟节点固定调度、ClusterIP、MySQL、RWO、RWX基础和同虚拟节点共享通过；跨虚拟节点仅在至少两个健康虚拟节点时执行；本轮PV必须回收 | 2026-08-07 | 功能检查通过，跨虚拟节点RWX正确SKIP；`te-disk` PV回收超时，整体FAIL | 用户回灌 `k8sAvailCheckResult_2026-08-07_212349.log`；待补PV/CSI证据 |
| 腾讯 TKE Serverless + 多 EKlet | 腾讯CSI | `te-disk` RWO、`te-nfs` RWX | 两个虚拟节点分别起服并完成跨虚拟节点RWX共享，临时PV均回收 | 待验证 | 待验证 | - |
| 阿里 Serverless + Virtual Kubelet | 阿里CSI | `te-disk` RWO、`te-nfs` RWX | 正确识别、固定虚拟节点调度、ClusterIP、存储和回收均通过 | 待验证 | 待验证 | - |
| Hybrid | 平台相关 | 两类临时资源 | Serverless失败不阻断Standard；最终统一汇总，任一FAIL保留 | 待验证 | 待验证 | - |

## 每次更新前的最小检查

1. 记录脚本版本或 commit、目标集群与执行时间。
2. 保存关键 `kubectl describe pvc/pod` Event 及脚本最终摘要。
3. 更新本文件的待办状态、半周记录和回归矩阵。
4. 若变更影响实施优先级，同步项目 `STATUS.md`、`decisions.md` 与控制台 `PROJECTS.md`。
