# 决策记录

## 2026-08-03：Karpenter consolidation policy 使用独立、字段级治理脚本

- 决定：新增独立脚本 `aws eks k8s/v1.35 eks v1.11 karpenter/set_nodepool_consolidation_policy.sh`，不并入 `auto_build_nodepool.sh`。它仅对实时 `spec.disruption.consolidationPolicy` 精确等于 `WhenEmptyOrUnderutilized` 的 NodePool，在操作者输入完整 `yes` 后执行 merge patch 为 `WhenEmpty`，并逐对象回读确认。
- 原因：该项是线上存量配置风险治理，不属于创建节点池流程；整份 YAML 导出后 `apply` 会覆盖并发更新的 budgets、`consolidateAfter` 等字段，而窄 JSON patch 保留其余配置。
- 不选：不采用 `rollout restart`、删除 NodePool 或 NodeClaim 等间接手段，因为目标仅是降低后续 consolidation 激进度，不能引入节点驱逐或业务中断。

## 2026-07-22：补齐项目级上下文文件

- 决定：为既有仓库新增 `STATUS.md`、`AGENTS.md` 和本文件，不移动或重命名已有资产。
- 原因：使 Codex 在独立打开该仓库时能恢复当前状态与协作边界。

## 2026-07-28：GKE Filestore 网络从 GCE Metadata 获取

- 决定：脚本从执行主机的 GCE Metadata 字段 `instance/network-interfaces/0/network` 读取并校验完整资源路径，例如 `projects/<HOST_PROJECT>/networks/<NETWORK>`，但传给 Google `te-nfs` StorageClass `parameters.network` 的值只取末段网络名 `<NETWORK>`。
- 原因：2026-07-30 真实 PVC Event 证实 Filestore CreateInstance 对 `network` 只接受符合网络名称正则的短名称；原样传递完整路径会被 GCP API 以 `InvalidArgument` 拒绝。Metadata 仍是可信来源，避免猜测或写死 `default`。
- 不选：不请求 `instance/?recursive=true` 后再解析，因为该响应包含 SSH keys、服务账号等无关敏感元数据；不在请求失败时回退 `default`，因为会将错误网络变成隐蔽的 Filestore 供给失败。

## 2026-07-28：以 Filestore 实例容量而非 PVC 容量作为 `te-nfs` 成本基线

- 决定：`te-nfs` 的预算以 Enterprise Multishare 后端 Filestore 实例为单位计算。首个动态 PVC 会触发最小 1TiB 实例；同一 PVC 被任意数量 Pod 挂载不新增 share 或后端容量。
- 原因：`multishare: "true"` 让不同 PVC 对应同一实例中的独立 NFS share，但 Google 按已供给的 Filestore 实例容量计费，不按已使用数据或单个 PVC 的 20Gi 请求计费。
- 后续：按 `instance-storageclass-label` 核查实例复用。`te-nfs` 与 `te-nfs-128` 是否共用实例不能仅由 PVC 列表判断，须查 PV `volumeHandle` 和 Filestore 实例 labels/capacity。

## 2026-07-28：线上 GKE Multishare 的 share 上限以 `max-volume-size` 控制

- 观察：线上 `te-nfs` 已配置 `max-volume-size: 256Gi` 与 `instance-storageclass-label: te-nfs`，对应每个 Enterprise Multishare 实例最多 40 个 share；`te-nfs-128` 配置 128Gi 与独立 label，对应最多 80 个 share。
- 决定：仓库 GKE `te-nfs` 模板不能继续省略 `max-volume-size`，否则新环境会落入旧兼容的 1024Gi/10-share 行为，和线上容量装箱策略不一致。
- 影响：不同 `instance-storageclass-label` 是不同实例复用池。`te-nfs` 与 `te-nfs-128` 应按两个潜在的最小 1TiB Filestore 实例分别预算，直到通过 Filestore 实例清单证实实际数量。

## 2026-07-29：GKE 仅维护 128Gi 策略的 `te-nfs`

- 决定：不创建或维护 `te-nfs-128`。唯一的 GKE StorageClass 仍名为 `te-nfs`，其 `instance-storageclass-label` 也固定为 `te-nfs`，并配置 `max-volume-size: "128Gi"`，实现每个 Enterprise Multishare 实例最多 80 个 share。
- 网络：自动创建前仅请求 GCE Metadata `instance/network-interfaces/0/network`；返回值必须是完整 `projects/<PROJECT>/networks/<NETWORK>` 路径，再提取符合 GCP 网络名称规范的 `<NETWORK>` 写入 StorageClass。获取失败时记录 FAIL、提示到 Google Cloud Console 确认 network 并打印手工 YAML，绝不回退 `default`。
- 取舍：不保留 256Gi/40-share 的第二个实例池，避免业务侧 StorageClass 名称选择、预算和后端实例复用策略分叉。
- 现场结果：2026-07-30 修复后的真实 GKE 运行已创建 `network=default`、`max-volume-size=128Gi` 的 `te-nfs`，并完成 RWX PVC 动态供给、挂载读写和临时 PV 回收；此前完整路径导致的 Filestore `InvalidArgument` 不再出现。
- 后续核销：用户确认历史 9 个 `debug/te-csi-check-*` Released PV/share 已按逐 PV 安全流程清理，且双节点 RWX Writer/Reader 跨节点共享读写已通过；不再把这两项保留为未验证风险。

## 2026-07-31：将 GKE 成本盘点与异常矩阵降级为 P2

- 决定：GKE Filestore 实例/share 成本复用核验、标准节点 `te-nfs` 异常分流回归从 P0 降为 P2 阻塞项。
- 原因：前者需要目标项目 Filestore 与账单读取权限，后者需要独立 GKE Standard/VPC 及控制 CSI、API、NFS 网络的权限；在当前授权边界下强行构造失败会带来生产风险或额外 1TiB Filestore 成本。
- 重启条件：取得所需只读/隔离环境授权，并先完成基于 PVC/Pod Event 的失败分类实现与本地回归。

## 2026-07-31：Kyverno 按 Pod 名和稳定镜像版本做 K8S 兼容性处理

- 决定：在“K8S集群连通性检查”之后，仅从 `te-system` 与 `kube-system` 查找 Pod 名含 `kyverno` 的工作负载；解析其所有常规容器的稳定 `vX.Y.Z`/`X.Y.Z` image tag。
- 规则：集群 K8S>=1.34 时，任一版本低于 `v1.18.0`、预发布 tag 或无法解析 tag 即执行一次 `/data/app/.admin_manager_ta/ta-admin/ta-admin te_k8s install -name kyverno`。未发现 Kyverno 为 SKIP；命名空间查询或服务端版本查询失败为 WARN；重装失败为 FAIL 并打印可复制的人工命令。
- 原因：Kyverno 对 K8S 1.34+ 版本敏感，admission/background/预处理组件可能版本漂移；用镜像组件名白名单会漏掉 `kyvernopre:v1.10.3` 等实际格式。

## 2026-07-31：节点组业务规划作为云厂商 map 的第二层

- 决定：托管云运行时先由管理员选择业务方案，再将该业务基准节点组按云厂商能力翻译成唯一的最终节点组契约；Pod 可调度探测与节点组契约对账均只读取该运行期契约。预制方案在菜单中直接显示业务名和基准节点组，帮助有经验的管理员判断。
- 跨云规则：ACK/华为等将 `reserved` 与 `od` 作为独立必需池；GCP/AWS 同规格常规池转为 `reserved|od` 二选一；腾讯/火山的 Trino/SR 预制方案继续包含 `od-32c128g`。自定义输入是完整替代规划，不追加默认池；仅接受 `reserved`、`od`、`on-demand`、`spot` 加 `${CPU}c${MEM}g`。
- 失败策略：交互菜单或自定义输入等待 30 秒；非 TTY、超时或三次无效输入时记录 WARN 并回退原云厂商全量 map，不阻塞自动化执行。
- 不选：不让执行者直接选择云厂商池组合，因为这会迫使其记忆不同云的付费能力；不在自定义规划中自动补全腾讯/火山池，以保留管理员对完整规划的控制权。

## 2026-07-31：核心功能必须以可执行样例逐项验收

- 决定：所有脚本新功能在设计、实施和现场回灌时，均须提供覆盖核心分支的测试样例矩阵：前置条件、操作输入、预期关键输出、通过/失败判定及证据位置。不能仅以“脚本整体跑完”或单个正常路径作为验收。
- 原因：本次自定义节点组输入已正确解析、打印成功信息，却因结果登记函数的返回码被外层判为失败并循环；原本的函数级映射测试未覆盖真实交互调用链与真实 `record_result` 返回码，未能提前发现。
- 落地：测试必须覆盖正常预制选择、自定义成功、非法输入重试、输入超时、非交互回退、云厂商翻译及结果总览；现场回灌按样例逐项记录。测试替身不得无意间改变被测函数的返回码语义。

## 2026-07-30：仅为存储探测 PV 覆盖 Retain 回收策略

- 决定：不修改业务 `te-nfs` StorageClass 的 `reclaimPolicy: Retain`。脚本清理 `te-csi-check-*` 临时 PVC 时，先读取其已绑定 PV，并将该 PV 的 `persistentVolumeReclaimPolicy` 补丁为 `Delete`，再删除 PVC；最多等待 60 秒确认 PV 已消失。
- 原因：现场已证实直接删除临时 PVC 会因 `Retain` 留下 `Released` PV 和 Filestore share，产生持续资源开销。限定到本次探测 PVC/PV，既能让 CSI 回收临时卷/share，也不改变业务数据保留语义。
- 失败处理：PV 无法切换或超时未删除时，存储端到端检查按失败处理并打印 PV 名称，避免把资源残留伪装为通过。
- 现场结果：2026-07-30 二次 GKE 实测的 `te-disk`、`te-nfs` 基础和 `te-nfs` 跨节点三项临时 PV 均打印“已回收”。本次 `kubectl get pv` 仍显示的 9 个 `Released` PV 是旧脚本运行遗留，不属于本轮新资源。

## 2026-07-30：节点池与延迟结果即时可见

- 决定：节点池部署阶段的实时结论和汇总均列出实际就绪节点池；每个节点池到 MySQL 目标的延迟采样完成后立即打印通过/失败、RTT 和阈值。
- 原因：历史 GKE 环境仅有 `od-4c32g` 继续完成后续网络检查，但原输出只展示失败档位，且延迟通过值仅在最终汇总中出现，降低现场可解释性。

## 2026-08-01：历史测试 PV 以多重身份门槛自动清理

- 决定：脚本在云环境识别后扫描历史 PV；只把同时满足 `Released`、claim 位于 `debug`、claim 名精确为 `te-csi-check-disk-pvc`/`te-csi-check-nfs-pvc`/`te-csi-check-nfs-rwx-pvc`、StorageClass 为 `te-disk`/`te-nfs`、含 CSI driver 与 volumeHandle、`pv.kubernetes.io/provisioned-by` 等于当前 StorageClass provisioner、且原 PVC 已不存在的 PV 列为候选。先打印候选；管理员输入 `N` 才跳过，30 秒超时或非 TTY 按默认清理。每个候选删除前再次核验，切换该 PV 的回收策略为 `Delete` 后删除并等待最多 60 秒。
- 原因：仅按 `Released + te-nfs` 会误伤业务的 Retain PV；claim namespace、固定历史测试名、动态供给身份、SC provisioner 和 PVC 不存在共同构成可审计的最小删除边界。CCE 的 SC provisioner 与 CSI driver 名称不同，因此比对 provisioner 不能错误地直接比 CSI driver。
- 不选：不扫描或删除 `te-agent`、其他 namespace、模糊 `te-csi-check-*` 名称、静态 PV 或无法证明供给来源的 PV；不修改业务 StorageClass 的 `Retain`。

## 2026-08-01：节点组首层菜单接受直接自定义输入，测试 PV 在收尾执行

- 决定：节点组业务规划的首层输入除 `1-5` 菜单编号外，直接尝试解析合法的完整自定义节点组；输入 `5` 时仍展示原有第二次输入提示。所有正常结束路径统一经 `finalize_availability_check`，其中先执行“测试PV清理”，再打印结果总览。
- 原因：CCE 现场执行者直接输入 `reserved-4c32g`，它符合既定格式却被菜单分支拒绝，随后回退到默认四池并触发不属于当前业务规划的高规格池失败。历史 PV 清理属于资源回收，不应抢占节点组选择和核心可用性检查的交互/执行时间。
- 边界：异常退出仍不处理历史 PV，仅由 EXIT trap 清理本轮临时资源；AWS 提前结束路径同样必须进入统一收尾，避免绕过测试 PV 清理。

## 2026-08-03：多云回灌后的展示缺陷优先级校准

- 决定：节点组规划的“非 TTY 立即回退”现场验证降为 P2；其行为已有本地 mock 覆盖，不阻塞当前多云验收。
- 决定：火山云 memory Quantity 的 `m` 后缀展示错误升为 P1。该特征目前只由火山云实测证明，因此不修改通用 `format_resource()`；新增的平台感知内存格式化只在真实平台标识 `volcengine`（代码匹配域 `*volc*`）的节点汇总路径生效，其他云、CPU 和磁盘行为保持不变。
- 决定：GKE 成功结果的扩容结论真实性和自定义路径 OR 语义提示升为 P1。`0→1` 只能根据本轮探测前后的节点池可观察状态输出，不再无条件声称 autoscaler 已验证。
- 实施边界：本轮只落计划与验收标准，生产脚本待用户 review 通过后再修改。
- 实施结果：用户 review 通过后已落地。火山云分支使用脚本真实平台标识 `volcengine`（匹配域 `*volc*`）；GKE 扩容展示以探测前节点池标签快照为基线，结果只陈述可观察到的状态变化。
- 现场结果：2026-08-03 火山 VKE 回灌显示 capacity=31.1Gi、allocatable=27.2Gi、CPU=3.9C，且节点契约校验通过，确认平台限定内存展示修复有效；同次非 TTY 运行立即回退默认 map，符合 P2 设计。
- GKE 现场结果：管理员自定义 `reserved-4c32g` 正确展开为 `reserved-4c32g|od-4c32g` 并打印 OR 语义，现存 `od-4c32g` 使单档 Pod 检查整体 PASS，成功结论和总览均未出现 `0→1`；两项展示真实性 P1 完成现场闭环。
