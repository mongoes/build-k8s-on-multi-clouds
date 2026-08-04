# GCP Filestore `te-nfs` 调研与配置说明

## 适用范围

本说明仅适用于标准节点模式的 GKE 集群。只维护一个名为 `te-nfs` 的 StorageClass；它使用 GKE 托管的 Filestore CSI Driver，动态创建 Enterprise Multishares 形式的 RWX 卷。

前置条件：Standard 集群已启用 `GcpFilestoreCsiDriver`，Cloud Filestore API 和 GKE API 已启用。若使用非默认 VPC 或 Shared VPC，还必须完成 Google Cloud 要求的网络和防火墙配置。

## 项目采用的模板

模板位于 `health-check-yaml/nfs-sc/te-nfs-sc.google.yaml`，且由 `k8sAvailCheck.sh` 在 GCP 环境缺失 `te-nfs` 时自动创建。模板由业务要求确定，必须保持以下参数不变：

| 配置 | 作用 | 成本或管理影响 |
| --- | --- | --- |
| `provisioner: filestore.csi.storage.gke.io` | 使用 GKE 托管的 Filestore CSI Driver。 | Driver 未启用、API 或 IAM/网络前置异常时，PVC 动态供给会失败。 |
| `tier: enterprise` | 选择 Enterprise Filestore 层级。 | 底层实例最小 1 TiB；相较 Basic 层级成本更高，但具备区域级能力。 |
| `multishare: "true"` | 一个 Enterprise 实例可承载多个独立 NFS share/PV。 | 共享同一实例的容量与性能，需评估应用间资源竞争；减少小 PVC 各自创建实例的成本浪费。 |
| `instance-storageclass-label: te-nfs` | 为同一 StorageClass 创建的实例池设置归属标签。 | 值保持稳定，便于归因与实例池复用。 |
| `max-volume-size: "128Gi"` | 将每个 PVC/share 的最大容量限制为 128Gi。 | 一个 Enterprise Multishare 实例最多容纳 80 个 share；不维护独立的 `te-nfs-128` StorageClass。 |
| `network` | 指定创建 Filestore 实例的网络短名称，例如 `default`。 | 脚本只从 GCE Metadata 的 `instance/network-interfaces/0/network` 获取完整资源路径、校验后提取末段网络名；手工应用模板时必须替换占位符。 |
| `reclaimPolicy: Retain` | 删除 PVC 后保留 PV/后端数据。 | 防止误删数据，但脚本的临时探测 PVC 删除后可能遗留 Released PV/share 和持续计费资源；线上实测后需纳入清理流程。 |
| `allowVolumeExpansion: true` | 允许扩容 PVC。 | 扩容会增加 share/底层实例容量和费用，不能通过缩小 PVC 回收。 |
| `volumeBindingMode: Immediate` | PVC 创建时即开始供给。 | 无需等待 Pod 调度；未被实际使用的 PVC 也可能创建云资源。 |
| `nolock` | NFS 客户端不使用 NLM 锁。 | 依赖文件锁的应用需按业务验证一致性与兼容性。 |
| `hard`, `timeo=600`, `retrans=3` | NFS I/O 故障重试策略；`timeo=600` 为 60 秒。 | 服务端/网络故障时 I/O 可能长时间阻塞，应用需具备超时、重试及健康检查。 |

## 可用性检查覆盖范围

主脚本在 `te-nfs` 创建或已存在后，会创建 20Gi RWX PVC、启动挂载 Pod 并进行读写；当至少两个节点可调度时，还会验证跨节点共享读写。Enterprise Multishares 支持从 10Gi 开始的单个 share，因此 20Gi 探测 PVC 符合该模式。后端实例最小供给为 1TiB，按实例容量计费而不是按 20Gi 探测 PVC 或实际写入数据计费；单个实例最多容纳 80 个独立 share。

脚本自动创建前只读取并校验 GCE Metadata `instance/network-interfaces/0/network`，不会请求递归 Metadata；该接口返回完整资源路径，脚本仅提取最后一段网络名传给 Filestore，也不会在获取失败时回退到 `default`。Metadata 失败时，脚本以红色 FAIL 提示操作人到 Google Cloud Console 确认 network，并打印可手工替换 network 占位符的完整 YAML。该检查仍不校验 Filestore CSI Add-on、Cloud API、IAM、Shared VPC Private Service Access 或防火墙的配置语义；这些前置异常会在 PVC/Pod 的 describe 诊断中体现。

## 官方资料

- [使用 Filestore CSI 驱动程序访问 Filestore 实例](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/filestore-csi-driver?hl=zh-cn)
- [Filestore Multishares for GKE](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/multishares?hl=en)
- [gcp-filestore-csi-driver README](https://github.com/kubernetes-sigs/gcp-filestore-csi-driver/blob/master/README.md)
