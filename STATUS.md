# 项目状态

## 当前阶段

2026-08-07 Serverless专项检查已合并到`k8sAvailCheck.sh`入口：阿里/腾讯从虚拟节点强指纹识别`Serverless`、`Standard`、`Hybrid`三种模式；`Serverless`委派固定虚拟节点调度域专项验证并跳过NodePort、宿主机网络及标准节点池契约，`Standard`保持原完整主流程，`Hybrid`先做专项验证再继续标准节点路径。独立`k8sServerlessAvailCheck.sh`仍保留为单独回灌入口。腾讯单EKlet已实测通过ClusterIP、`te-disk` RWO、`te-nfs` RWX单Pod及同域双Pod共享；跨域RWX因单调度域正确SKIP。下一步：回灌阿里多Virtual Kubelet、腾讯多EKlet和Hybrid，验证跨调度域RWX与两条路径汇总。

2026-08-07 华为CCE存储回灌已真实验证：历史`te-disk`被业务PVC/PV引用时，检查按通过呈现且未改变SC。旧`te-nfs`（`nfs-provisioner`、无VPC授权）在人工确认后已仅替换同名StorageClass，未触碰PV/PVC/Pod；后续临时RWX PVC由`everest-csi-provisioner`成功供给并Bound，证明脚本改造与SC参数生效。Pod失败于节点对SFS地址的NFS挂载（`FailedMount`），现场已确认CCE缺少VPCEP，属于云侧文件存储访问通路前置条件，不是脚本逻辑误判。

2026-08-06 节点组交互与hostAliases健壮性已实施、待现场回灌：业务规划菜单及自定义输入等待由30秒延长到300秒；`/etc/hosts`别名进入Pod前统一做RFC1123校验。合法大写DNS名称转小写并披露，无法可靠处理的非法别名逐条WARN并丢弃，同一行其他合法别名不受影响；规范化后再去重和判断跨IP冲突，确保单条非法hosts记录不会导致探测Deployment整体apply失败。

2026-08-06 MySQL历史环境兼容已实施、待现场回灌：混合部署网络探测优先从`/data/home/ta/base_server_ta/application.yml`解析全部非注释JDBC MySQL目标；标准文件不存在或零有效目标时，回退`/data/home/ta/data_etl_ta/application.yml`。标准文件只要存在一个有效目标就不回退，损坏URL按文件路径和行号WARN，其余有效目标继续检测；两个文件均无有效目标时FAIL并提示管理员自行测试MySQL地址。

2026-08-04 P0 已实施、待真实 EKS 回灌：通用检查的kubectl目标版本继续保持多云共同基线Kubernetes 1.34；EKS 1.36仅用于AWS专用建设物料，待所有云平台支持1.36后再统一升级通用检查。AWS EKS 已移除识别后无条件下载 `auto_build_nodepool.sh` 并提前 PASS 的旧路径。现在平台识别后精确检查 `nodepools.karpenter.sh` CRD和资源对象；CRD缺失、Forbidden/查询失败分别报错，零NodePool仅在TTY输入Y/y后执行外部创建脚本并要求重跑，已有NodePool继续节点规划、存储、调度、网络和端到端存储的完整标准流程。AWS工具限定白名单、统一下载目录、非空及`bash -n`校验并用Bash执行。

AWS存储缺失不再由通用脚本静默创建：`te-disk`、`te-nfs`、EBS/EFS CSI或存储端到端失败会聚合原因，在总览后按需提供`storage_ready_for_existing_eks.sh`入口。NodePool `WhenEmptyOrUnderutilized` 已迁入通用脚本只读审计；总览后仅完整输入`yes`才执行重读、字段级patch和读回验证，原独立`set_nodepool_consolidation_policy.sh`已移除。

新增P0设计：AWS EKS不得再自动进入 `auto_build_nodepool.sh` 并提前结束。已确定Kubernetes 1.36 / Karpenter 1.13物料以 `aws eks k8s/v1.36 eks v1.13 karpenter/01eks_build/` 为权威源；AWS识别后先精确检查 `nodepools.karpenter.sh` CRD和NodePool对象，零NodePool立即交互式进入创建流程，已有NodePool则执行完整标准检查。存储修复和内置consolidation治理仅在对应问题出现时于总览后提供。

原独立 consolidation policy 治理脚本的精确筛选、完整确认、字段级patch和回读逻辑已经过本地测试；根据2026-08-04 P0新边界，该逻辑将在实施时迁入通用检查的AWS特性环节，`01eks_build/set_nodepool_consolidation_policy.sh` 不再作为独立入口维护。

P0 设计确认：GKE Filestore `te-nfs` 不能隐式依赖 `default` VPC；需从脚本执行的 GCE VM Metadata 获取实际 VPC 并注入 StorageClass。
当前成本基线：`te-nfs` 使用 Enterprise Multishare，首个动态 PVC 即按最小 1TiB Filestore 实例计费，而非按 20Gi PVC 计费；同一 PVC 被多个 Pod 挂载不增加存储供给。
已完成 GKE P0 现场验证：只维护 `te-nfs`，使用 `max-volume-size=128Gi`（每实例最多 80 shares）；脚本从 GCE Metadata 获取并校验完整 VPC 路径、提取网络短名称写入 Filestore SC，失败时给出 Google Cloud Console 指引和手工 YAML，不回退 `default`。2026-07-30 修复后真实运行确认新建 SC 为 `network=default`、`max-volume-size=128Gi`，并完成 RWX PVC 动态供给、Pod 挂载读写及临时 PV 回收。该临时集群仅有一个节点，跨节点 RWX 被正确跳过，仍需双节点现场验证。

用户随后确认：历史 9 个 `debug/te-csi-check-*` Released PV/share 已完成安全清理，且 GKE 双节点 RWX 跨节点共享验证符合预期，以上两项 P0 已核销。当前剩余重点为 Filestore 实例/share 装箱与成本核验，以及标准节点 `te-nfs` 异常分流回归。

优先级调整：上述成本/实例复用核验及标准节点异常矩阵依赖额外 GCP、账单和隔离集群权限，当前无法安全开展，已降级为 P2 阻塞项；获得授权和合适测试环境后恢复执行。

新增 P1（已实现，待现场验证）：Kyverno K8S兼容性检查紧随集群连通性检查执行。仅检查 `te-system` 和 `kube-system` 中 Pod 名含 `kyverno` 的常规容器镜像；K8S>=1.34 时，任一稳定语义版本低于 `v1.18.0`、预发布 tag 或不可解析 tag 都会执行一次 Kyverno 重装。重装失败记录 FAIL 并打印人工命令。
新增 P1（已实现，待现场验证）：托管云节点组业务规划交互。识别云厂商后，终端执行者可在 Agent/基础运营、复杂运营/数据开发、Trino/SR、基础+高开销或自定义节点组之间选择；脚本将业务基准按云厂商能力展开为最终契约，供 Pod 探测和节点组对账共用。GCP/AWS 同规格常规池为 reserved/od 二选一；30 秒无输入或非交互运行记录 WARN 后回退旧版全量云 map。
2026-08-03 优先级校准：非 TTY 立即回退已由本地 mock 覆盖，现场验证降为 P2；火山云 `allocatable.memory` 的 `m` 后缀误展示为 CPU 单位升为 P1；GKE 已有节点却无条件提示“autoscaler 0→1已验证”及自定义路径漏打印 OR 语义升为 P1。两项 P1 已形成 review 计划，尚未修改生产脚本。
2026-08-03 P1 本地实施：火山云内存修复限定在真实平台标识 `volcengine` 域，其他云继续使用通用格式化；GKE/AWS 预制和自定义规划统一展示 OR 语义；Pod 探测以启动前节点池快照和最终就绪池差异决定是否输出本轮 `0→1` 观察，不再无条件声称扩容已验证。新增核心样例覆盖平台隔离、已有池、新增池、混合池和自建占位池，待真实火山云/GKE 回灌。
2026-08-03 火山云现场闭环：VKE v1.34.6-vke.7 被正确识别为 `volcengine`，节点汇总显示 capacity 31.1Gi、allocatable 27.2Gi、CPU 3.9C，节点池规格/标签/污点契约继续通过，火山云内存 P1 核销。该次运行同时证明非 TTY 会立即 WARN 并回退默认五池 map；由于现场仅存在 reserved-4c32g，其余四池失败属于完整默认契约对账结果，并非脚本回归。
2026-08-03 GKE 非 TTY 回灌：默认规划正确展开为三档 OR 契约，现存 `od-4c32g` 被准确选中，存储、网络及跨节点 RWX 均通过，且未出现错误的 `0→1` 文案。但该运行未进入管理员自定义分支，且 Pod 检查因高规格两档缺失走 FAIL 分支，不能覆盖原缺陷所在的“全部档成功”输出；GKE 两项 P1 暂不核销，下一次交互直接输入 `reserved-4c32g` 即可同时验收。
2026-08-03 GKE 交互成功路径闭环：管理员直接输入 `reserved-4c32g` 后，脚本正确展开并展示 `reserved-4c32g|od-4c32g` OR 语义，按现存节点选中 `od-4c32g`；Pod 检查全部1档 PASS，实时结论与总览均未误报 `0→1`。节点组自定义 OR 展示和扩容结论真实性两项 P1 均核销。现场唯一 WARN 为历史 GKE 节点缺少 `node.k8s.te/billing-mode=od`，属于既有标签契约风险。
2026-07-31 ACK 回灌修复：自定义节点组输入成功后曾因 `record_result(PASS)` 泄漏退出码 1 被外层误判为非法，导致重复询问；现已令结果登记显式返回 0，并以生产函数返回码回归测试覆盖。后续所有新增核心功能必须先提供“输入/前置条件/预期输出/判定标准”的测试样例矩阵，逐项验收后才能标记为可用。
新增 P1（已实现，待现场验证）：测试 PV 清理。仅扫描 `Released`、`debug`、固定 `te-csi-check-{disk,nfs,nfs-rwx}-pvc` claim、`te-disk/te-nfs`、CSI 动态卷、provisioner 与当前 StorageClass 匹配且原 PVC 已不存在的 PV；先展示候选，再允许管理员跳过。该动作位于所有正常检查路径的最终总览之前；30 秒未输入或非交互运行时默认清理，删除前重新核验，逐 PV 切换回收策略为 `Delete`、删除并等待最多 60 秒。
2026-08-01 CCE 回灌修复：首层节点组菜单原本仅接受 `1-5`，直接输入合法 `reserved-4c32g` 被误当作无效，继而回退默认全量 map 并探测计划外高规格池。现首层同时接受菜单编号或直接自定义节点组；保留选择 `5` 后二次输入的兼容路径。
2026-07-30 历史 GKE 现场回灌：`te-disk`、`te-nfs` RWX 基础和跨节点读写均通过；历史节点池标签/污点不符合新契约已被脚本披露，属于预期风险。因 `te-nfs` 已存在，Metadata 自动创建分支本次未执行，仍待合适环境回灌。第二次线上验证确认三项修复生效：3 个本轮临时 PV 均打印“已回收”；部署结论列出 `od-4c32g`；延迟阶段即时输出 `od-4c32g -> ta3:3306 0ms (<50ms)`。现场仍有 9 个 `Released` 的 `debug/te-csi-check-*` PV，均为旧脚本遗留，需另行按变更流程清理。

## 已识别资产

- Kubernetes 集群可用性检查脚本：`k8sAvailCheck.sh`、`k8sServerlessAvailCheck.sh`。
- 节点池构建脚本：`auto_build_nodepool.sh`。
- 测试与文档目录：`tests/`、`docs/`。

## 下一步

- [ ] P0：在腾讯多EKlet环境复跑已修复的Serverless专项脚本，再在阿里多Virtual Kubelet环境回灌：逐域Pod/网络/RWO/RWX、双域RWX共享、纯Serverless/混合/Standard-only/未知冲突拒绝路径；确认Tencent EKlet toleration和Alibaba无污点节点均可起服。
- [ ] P0：华为CCE已完成SC替换实测；待在控制台补齐SFS所需VPCEP后，重跑RWX基础与跨节点共享验证，并同时复核`od-4c32g`节点池缺失问题。
- [ ] P1：在含大写及非法`/etc/hosts`别名的环境回灌，确认生成物料只含小写RFC1123名称且Deployment可apply；确认节点组提示显示300秒。
- [ ] P1：在只有`data_etl_ta/application.yml`的历史环境回灌MySQL目标解析、Pod TCP连通性及延迟检查结果。
- [ ] P0：针对 garena-新物理机内置 K8S，API Server 已确认正常，根因收敛为 `FORWARD` 中客户无条件 DROP 位于 `FLANNEL-FWD` 之前、截断 Pod 转发。管理员不允许改动 DROP：立即恢复仅在该 DROP 前插入一条 `-j FLANNEL-FWD`，原 DROP 与其后的历史 Flannel 跳转均不动。每次策略刷新、Flannel/kube-proxy 重建后回读顺序与 Pod 到 `10.96.0.1:443` 连通性；若客户刷新会整表 restore，则必须由其维护方提供不覆盖 K8S/CNI 链的集成方式，否则本侧插入无法持久。
- [ ] P0：garena-新暂停 `kruise-daemon` 后，残留的集群级 validating webhook `vpod.kb.io` 仍指向无 Endpoints 的 `kruise-webhook-service.kruise-system:443`，导致包括删除 Pod 在内的 Admission 请求失败。需先对该精确 webhook 临时设 `failurePolicy: Ignore` 或恢复 webhook endpoint，删除/修复工作负载后按原值恢复；不可把 `--force` 当成绕过 Admission 的方案。
- [ ] P0：ACK `te-agent` 的 Agent Sandbox `sandbox-1-*` CrashLoop 已排除 Kruise、驱逐和 OOM：Pod 由 `Sandbox` CR 控制，Kruise 仅注入 promtail sidecar；kubelet Event 明确为 `Container sandbox failed liveness probe, will be restarted`。现场 `node dist/main` 实际监听 `*:80`，`te-agent-sandbox` ConfigMap 亦为 `app.port: 80`，但 Pod liveness/readiness 固定探测 `:8080/health`，是确定的配置/控制器模板不一致。npm 中 SIGTERM 是 kubelet 终止后的表象。需修正生成 Sandbox Pod 的 liveness/readiness port 为 80（并以新 Pod 验证）；不应先改重启策略或误停 Kruise。
- [ ] P0：华为 `te-system/kubete-controller-manager:6.0.8` 在 node `192.168.0.170` CrashLoop 的根因已定位：`metricscollection-controller` 初始化 DB client 时连接 `192.168.0.16:3306` 超时，随后构建全部 controller context 失败并 Exit 1。它已成功解析 `te-global-config`、监听 `8443` 且 liveness 曾多次 Healthy；不是探针、OOM、驱逐或 Kruise。下一步以宿主机/POD 双向 TCP 测试和 node tcpdump 验证 MySQL 本身、Pod 出站 SNAT/路由、以及已知 FORWARD DROP 的实际命中；修复网络路径后重启 Deployment 验收。
- [ ] P0：按AWS EKS验收矩阵回灌：CRD不存在、CRD Forbidden、零NodePool的Y/拒绝/非TTY、已有NodePool完整标准流程、存储缺失入口、consolidation合规/不合规。
- [ ] P0：在至少一个 Serverless 集群完成独立脚本回归，证明不依赖 Node / NodePool 假设。
- [ ] P1：在真实存在旧版 Kyverno 且 K8S>=1.34 的环境回灌升级成功路径，并验证重装失败时的人工指令提示。
- [ ] P1：在含历史 `debug/te-csi-check-*` Released PV 的隔离集群逐项验收 `Y` 清理、`N` 跳过、30 秒超时默认清理和业务 PV 排除。
- [ ] P1：完成 CCE NAS / Everest 的 VPC ID 自动解析与端到端复测。
- [ ] P1：补齐 `Unschedulable`、`NotTriggerScaleUp`、冷启动、镜像/DNS/MySQL/RTT 失败矩阵的可执行样例与现场证据。
- [ ] P2：取得 GCP Filestore/账单和隔离集群权限后，再启动实例/share 成本复用核验及 `te-nfs` 异常分流矩阵。
- [ ] P2：整理多云回灌证据、README 使用说明和安全边界；顺手修复失败节点池文案双层方括号。

## 阻塞项

- GKE Filestore 成本/实例复用缺少目标项目 Filestore 与账单只读权限。
- 标准节点 `te-nfs` 异常矩阵缺少可安全控制 CSI/API/NFS 网络的隔离 GKE 集群。
- Kyverno 升级仍缺少“已安装旧版 Kyverno + K8S>=1.34”的真实测试环境。
