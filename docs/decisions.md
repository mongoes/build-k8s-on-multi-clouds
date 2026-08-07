# 决策记录

## 2026-08-07：Serverless模式采用虚拟节点强指纹与逐调度域验证

- 模式：腾讯虚拟节点以`instance-type=eklet`或`eks.tke.cloud.tencent.com/`前缀识别；阿里虚拟节点必须同时满足`type=virtual-kubelet`和阿里专属label/annotation。虚拟节点与标准节点计数决定纯Serverless、混合或标准模式；证据冲突、无Node或标准节点云归属未达到双重证据时FAIL停止。
- 调度域：腾讯使用Node名、subnet和AZ；阿里使用Node名和AZ。InternalIP、虚拟CPU/内存/Pod容量和Virtual Kubelet Lease不进入容量或健康结论。
- 验证：每个调度域以hostname selector固定CPU Probe和存储Pod；腾讯只容忍EKlet污点，阿里仅在现场存在对应Virtual Kubelet污点时容忍。每域独立验证RWO/RWX；两个健康域才验证RWX Writer/Reader共享。
- 不选：不把无虚拟节点的集群默认为某个云平台Serverless，也不让Serverless脚本运行标准节点池、NodePort、宿主机网络或autoscaler检查。

## 2026-08-07：Serverless临时资源使用短哈希RFC1123标识

- 现场证据：腾讯EKlet节点名与`2026-08-07_170649`格式时间戳被直接用于Deployment、Service、PVC、Pod和label时，分别触发长度上限和下划线非法；生成存储YAML的未转义`$(cat /data/ready)`还在脚本宿主机执行，导致容器命令失真。
- 决策：以`sl-<探测类型>-<范围哈希>-<运行后缀>`生成对象名和label值，不嵌入节点全名；运行后缀只含数字与连字符。生成YAML时保留字面量`$(cat /data/ready)`，交由容器shell执行。腾讯AZ展示优先取业务可读的`eks.tke.cloud.tencent.com/zone-name`，缺失时再退回通用topology zone。
- 不选：不只把下划线替换为连字符或简单截断节点名；前者仍会超过63字符，后者既可能碰撞又无法保证随后附加`-pod`、`-writer`、`-reader`仍合法。

## 2026-08-07：Serverless单调度域也必须验证RWX多Pod共享

- 现场证据：单EKlet Serverless集群已验证单Pod可供给、挂载并读写`te-nfs`，但跨调度域检查只能SKIP；这不能证明两个独立Pod对同一RWX PVC的数据可见性。
- 决策：每个健康Serverless调度域均执行同域Writer/Reader双Pod共享测试，Writer写入标记后Reader读取；它验证RWX多Pod共享，但不将其称为跨节点/跨子网验证。仅在至少两个健康调度域存在时执行跨域RWX测试。
- 网络结论：NodePort不属于Serverless检查范围；ClusterIP仍是应验证的数据面。失败时必须保存HTTP客户端输出和Kubernetes对象证据；如果镜像没有wget/curl，记录WARN而不是将探针工具缺失误判为网络FAIL。

## 2026-08-07：主检查器仅对阿里/腾讯进行三态服务模式分流

- 模式命名统一为`Serverless`、`Standard`、`Hybrid`，不再使用`*-only`。腾讯以EKlet强指纹、阿里以Virtual Kubelet与阿里专属信号组合识别虚拟节点；无虚拟节点即`Standard`，虚拟节点与标准节点共存即`Hybrid`。
- 决策：`k8sAvailCheck.sh`在云厂商识别后进行分流。`Serverless`运行Serverless专项检查并结束，不执行节点池规划、NodePort、宿主机网络或标准节点契约；`Hybrid`先运行专项检查，再保留原标准路径。AWS、华为、GCP、火山和自建集群不进入该分流，继续原逻辑。
- 不选：不把虚拟节点逻辑复制进标准节点检查函数，也不让Serverless模式强行执行标准节点池检查；两者会把无物理节点的产品边界误报为集群故障。

## 2026-08-07：华为 CCE 存量 StorageClass 采用受保护通过与显式确认替换

- `te-disk`：当旧SC仍被业务PVC/PV引用时，GPSSD2升级不是失败，也不是需要用户处理的“关注项”。脚本不执行apply、patch或delete，并在总览记为通过：旧SC被业务存储使用，因此不会更新GPSSD2；已绑定卷和现有Pod不受本次检查影响。
- `te-nfs`：当provisioner不是`everest-csi-provisioner`或`everest.io/share-access-to`不同于可信CCE VPC ID时，脚本打印PV/PVC引用。仅交互式完整输入`yes`才删除并创建`StorageClass/te-nfs`；拒绝、超时、空输入及非TTY均保留旧SC并报FAIL。
- 资源边界：替换流程仅允许读取PV/PVC/Pod，绝不delete、patch、apply或重建它们。删除SC后创建/回读失败时，保留替换前YAML，保存csi-nas诊断，并输出手动恢复指引。
- 不选：不自动创建`te-nfs-cce`作为默认方案。该名称会让后续业务模板继续引用旧`te-nfs`，无法修复同名契约；用户已确认在明确人工确认后复用标准同名SC。

### 2026-08-07 现场回灌验证

- 现场日志`k8sAvailCheckResult_2026-08-07_114749.log`确认：检测到旧`te-nfs`的`provisioner=nfs-provisioner`且`share-access-to`为空后，管理员确认替换成功；脚本明确记录本次仅删除/创建StorageClass，未触碰PV/PVC/Pod。
- 验证边界：临时RWX PVC被`everest-csi-provisioner`成功Provision并进入`Bound`，证明新SC、CSI动态供给及脚本回读路径有效。后续Pod已Scheduled但持续`FailedMount`，kubelet执行到SFS域名的`mount -t nfs`后被终止；这不是PVC未供给或脚本把旧SC误判为就绪。
- 根因归属：现场已确认CCE缺少VPCEP。CCE到SFS的网络访问前置条件未满足时，SFS NFS挂载无法完成；修复VPCEP后应重跑RWX基础及跨节点共享验证，不应回滚新的标准`te-nfs`。

## 2026-08-06：hosts别名逐条RFC1123隔离，节点组交互等待300秒

- 决定：节点组业务规划菜单和选择5后的自定义输入统一等待300秒；超时仍WARN并回退云厂商默认规划。
- 规范化：DNS名称大小写不敏感且Kubernetes hostAliases只接受小写，因此合法大写名称先完整转小写，再参与去重和跨IP冲突判断。
- 非法处理：下划线、连续点、非法首尾字符、单段超过63或总长超过253等不能可靠转换的名称，整条别名WARN并丢弃；不通过删除非法字符来猜测管理员原意。同一hosts行的其他合法别名继续保留。
- 安全目标：进入Deployment YAML的每个名称都必须先通过RFC1123 subdomain校验，任何单条非法`/etc/hosts`记录不得导致探测Deployment整体apply失败。

## 2026-08-06：MySQL探测采用标准配置优先、历史配置兜底

- 决定：优先解析`/data/home/ta/base_server_ta/application.yml`；仅当文件不可读或没有任何有效MySQL目标时，回退`/data/home/ta/data_etl_ta/application.yml`。不合并两个文件的目标，避免把历史废弃地址带入当前检查。
- 容错：同一配置内有效和损坏JDBC URL并存时，继续使用全部有效`host:port`并去重，损坏项以文件路径和行号WARN；标准配置已有有效目标时绝不回退历史配置。
- 失败：两个文件均无有效目标时记录FAIL，同时打印两个路径并提示管理员自行测试MySQL地址。
- 安全：解析和日志只处理主机、端口及损坏行号，不读取或输出MySQL用户名、密码，也不把可能包含敏感查询参数的完整JDBC行写入警告。

## 2026-08-05：物理机 K8S 与客户主机防火墙采用职责分离的规则维护方式

- 现场证据：garena-新内置 K8S 的 `FORWARD` 链依次为 `KUBE-PROXY-FIREWALL`、`KUBE-FORWARD`、客户无条件 `DROP`、`FLANNEL-FWD`；后者计数为 0。客户的周期性规则刷新会重新引入或改变该顺序，因此即便 kube-proxy/Flannel 曾正确写入规则，也会被后续刷新破坏。
- 决定：客户策略任务不得 `iptables-restore` 整套过滤表、清空链或把终止 `DROP` 插入 Kubernetes/Flannel 链之前。客户规则应放入独立链（例如 `CUSTOM-FIREWALL`），由 INPUT/OUTPUT/FORWARD 的稳定跳转点调用；对 FORWARD，Kubernetes 与 CNI 所需的放行链必须先执行，客户的默认拒绝只能位于其后。规则刷新和 K8S/CNI 更新后均以规则顺序、计数和 Pod->Service 连通性读回验收。
- 诊断边界：ingress-nginx 调用 `https://10.96.0.1:443` 的 `connect: connection refused` 表明 Service VIP 到 API Server 后端路径仍需要独立验证（IPVS 虚拟服务、后端、EndpointSlice、API Server 监听）。不将其直接等同于 FORWARD DROP；该 DROP 已足以解释跨节点 Pod 转发异常和 Flannel 链零命中。
- 不选：不建议用一次性 `iptables -I` 或仅重启 kube-proxy 作为最终方案。客户周期任务会再次覆盖顺序，且 kube-proxy 只能定期修复其自身规则，无法约束客户脚本持续插入的终止规则。

### 2026-08-05 现场确认补充

- API Server 已由现场确认正常，因此 ingress 对 `10.96.0.1:443` 的失败不再作为控制面异常处理；根因收敛为客户直连 `FORWARD` 的无条件 DROP 截断 Kubernetes/Flannel 的 Pod 转发。
- 当前恢复（管理员不允许改动 DROP）：核对目标 DROP 的行号后，使用 `iptables -I FORWARD <DROP行号> -j FLANNEL-FWD` 在其前插入一条 Flannel 跳转；不删除、不替换、不移动管理员 DROP，也不删除其后的旧 Flannel 跳转。该重复 jump 安全且使 Pod 流量先进入 `FLANNEL-FWD`。
- 长期：每次策略刷新或 Flannel 生命周期事件后，检查 `FLANNEL-FWD` 是否仍在第一个客户直连 DROP 前；若没有则重插。客户若使用整表 `iptables-restore`，本侧插入会被重置，必须由客户维护任务改为仅维护其专用链或在其刷新末尾调用本校正动作。Kubernetes 的 kube-proxy 与 Flannel 都可能在生命周期事件中维护或追加规则，因此“首次部署时 DROP 在最后”不是永久保证。
- Kruise 暂停边界：暂停 `kruise-daemon` 不会删除其 `ValidatingWebhookConfiguration`。若 webhook `vpod.kb.io` 的 Service 已无 endpoints 且 failurePolicy 为 Fail，Pod 删除同样会被 API Server Admission 拒绝。优先临时将该单个 webhook 改为 `Ignore`，完成修复后恢复原 failurePolicy；不采用 `kubectl delete pod --force`，因为它不是对 Admission 配置问题的可靠修复。
- Agent Sandbox CrashLoop 诊断边界：当 `kubectl describe pod` 显示 `Liveness probe failed: ... :8080/health: connect: connection refused` 且随后有 `Container ... failed liveness probe, will be restarted`，应用日志中的 npm `SIGTERM` 是 kubelet 重启动作的结果，不是 Node 进程主动崩溃的根因。ACK 现场进一步确认 `node dist/main` 监听 `*:80`，且 `te-agent-sandbox` ConfigMap 为 `app.port: 80`；因此根因是生成 Pod 的探针端口 8080 与应用端口 80 不一致，修复目标是 Sandbox 控制器/模板的 liveness/readiness port=80，而非修改 Node 进程或放宽探针。即使 Pod 有 Kruise SidecarSet 注入注解，也要以 `Controlled By` 与 Events 判定触发方；本例 Owner 为 `Sandbox` CR，promtail sidecar 正常。
- Kubete Controller Manager CrashLoop 取证边界：Exit Code 1 且容器已成功监听健康端口、Event 没有 kubelet `Killing`/OOM/驱逐信号时，不能把 CrashLoop 归因为 probe。先用 `kubectl logs --previous --timestamps` 获取进程退出前的完整错误。本例已确认 `metricscollection-controller` 连接 MySQL `192.168.0.16:3306` 超时，导致 controller context 构建失败、进程退出；修复目标是该 Pod 到 MySQL 的 TCP 网络路径，不是健康检查。需从同一节点比较宿主机与 Pod 连接，并用 tcpdump 区分 MySQL/网络 ACL、SNAT 与 FORWARD 规则截断。

## 2026-08-04：AWS EKS回归标准检查，特殊动作只按真实问题暴露

- 版本边界：通用检查继续要求kubectl 1.34，作为当前多云共同支持基线。EKS新建物料面向Kubernetes 1.36不等于抬高通用检查版本；待所有目标云平台均发布并支持1.36后再统一调整。
- 决定：AWS识别后先用精确资源名检查`nodepools.karpenter.sh` CRD和NodePool对象。已有对象继续完整通用检查；零对象时立即询问是否执行`auto_build_nodepool.sh`，成功后结束本轮并要求重跑；CRD缺失或查询Forbidden不进入创建脚本。
- 权限边界：通用检查脚本不创建EKS。kubeconfig缺失或连接失败时只提示确认`build_eks_v1.36.sh`建集群、AWS授权及`aws eks update-kubeconfig`，不自动获取Admin Full Access。
- 存储边界：AWS缺少StorageClass、CSI或端到端验证失败时先记录真实FAIL，总览后才询问是否执行`storage_ready_for_existing_eks.sh`；拒绝、超时或非TTY不执行高权限动作。
- consolidation：撤销“独立脚本长期维护”的旧决定，将只读审计和经完整`yes`确认的窄patch/读回逻辑合并到通用检查；删除`01eks_build/set_nodepool_consolidation_policy.sh`，避免两个入口漂移。
- 安全：仅白名单允许`auto_build_nodepool.sh`和`storage_ready_for_existing_eks.sh`，下载后必须非空且通过`bash -n`，始终用Bash执行并保留真实退出码。

## 2026-08-03：Karpenter consolidation policy 使用独立、字段级治理脚本

- 状态：已被2026-08-04决策取代；字段级安全机制保留，但维护入口迁入通用检查脚本。
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
