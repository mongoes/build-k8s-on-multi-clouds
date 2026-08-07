# Serverless K8S 模式识别与逐调度域可用性检查设计

## 目标

安全识别当前 kubeconfig 对应集群的云厂商（腾讯/阿里）与运行模式（Standard-only、Serverless-only、Hybrid）；仅在结论具备足够证据时执行相应检查，按每个 Serverless 虚拟节点调度域验证 Pod、网络和存储可用性。

## 非目标

- 不使用虚拟节点的 CPU、内存、Pod 容量、已分配百分比或 InternalIP 做容量规划或健康结论。
- 不在缺少可信云厂商/模式结论时回退到标准节点或 Serverless 检查。
- 不在检查中创建节点、节点池、云网络、NAS/CFS/CBS 等云资源。

## 识别模型

脚本从 `kubectl get nodes -o json` 收集 Node 元数据、条件、污点和拓扑标签，并分别计数虚拟节点与标准节点。

### 腾讯 Serverless 虚拟节点（强证据）

任一 Node 命中下列之一：

- `node.kubernetes.io/instance-type=eklet`；
- 存在 `eks.tke.cloud.tencent.com/` 前缀的 label 或 annotation。

调度域标识为 Node 名、`eks.tke.cloud.tencent.com/subnet-id` 和 `eks.tke.cloud.tencent.com/zone-name`。Pod 使用 hostname selector，并容忍精确的 `eks.tke.cloud.tencent.com/eklet:NoSchedule` 污点。

### 阿里 ACK Serverless 虚拟节点（强证据）

同一 Node 必须同时具有 `type=virtual-kubelet`，并且至少具有一个阿里专属信号：`alibabacloud.com/`、`service.alibabacloud.com/` label，或 `vk.alpha.alibabacloud.com/` annotation。Node 名、Kubelet 版本后缀、虚拟容量、InternalIP 和 Lease 都不是独立判据。

调度域标识为 Node 名和 `topology.kubernetes.io/zone`。Pod 使用 hostname selector；仅当目标 Node 实际具有阿里 Virtual Kubelet 专属 NoSchedule 污点时才注入对应 toleration。

### 集群模式

- `Serverless-only`：虚拟节点数大于 0，标准节点数为 0。
- `Hybrid`：虚拟节点数和标准节点数均大于 0。
- `Standard-only`：标准节点数大于 0，虚拟节点数为 0。
- `Unknown/Conflict`：无 Node、供应商强证据冲突、或标准节点场景无法从 providerID、CSI/StorageClass、版本和 kube-system 组件取得一致的云厂商结论。

`Unknown/Conflict` 必须记录 FAIL 并停止；不得猜测后续路径。Standard-only 的云厂商必须至少由两类独立辅助信号一致确认，否则维持 `cloud=unknown`。

## 检查流程

1. 连接 Kubernetes API 后执行模式识别并输出证据和节点计数。
2. `Standard-only` 调用标准节点检查入口；`Serverless-only` 仅调用 Serverless 路径；`Hybrid` 分别执行两种路径并分开汇总。
3. 对每个虚拟调度域做只读健康门槛：Ready、NetworkUnavailable、Unschedulable、平台可用 IP（腾讯）和平台专属污点。
4. 为每个通过门槛的域创建固定 hostname 的通用 CPU Probe，验证调度、镜像拉取、Pod IP、ClusterIP Service、可选业务地址和 MySQL TCP。ClusterIP 失败必须落盘 Probe 命令输出、Service、EndpointSlice、Endpoints 和 Pod YAML；如果探测镜像缺少 wget/curl，只能记录 WARN，不得把探针依赖误判为数据面 FAIL。
5. 每个域独立创建 `te-disk` RWO PVC/Pod 验证块存储；每个域独立创建 `te-nfs` RWX PVC/Pod 验证文件存储。
6. 每个通过的域都创建一个共享 RWX PVC，固定 Writer 与 Reader 在同一虚拟节点调度域，验证两 Pod 的共享读写；这是单超级节点集群的必测项。具有至少两个通过的域时，再创建共享 RWX PVC，固定 Writer 与 Reader 在不同虚拟节点，验证跨调度域共享读写。
7. GPU/特殊规格仅由显式参数启用，默认通用 CPU Probe 不推断这些规格可用。

## 安全与故障行为

- 全部临时资源带专属标签，退出时精确清理；保留 YAML 和 describe 物料。
- 不验证 NodePort、宿主机直连或标准 autoscaler/节点池契约。
- 单域失败不阻断其他域，最终分别报告通过/失败域及跨域 RWX 状态。
- Hybrid 汇总不能以标准节点或 Serverless 节点任一侧通过掩盖另一侧失败。

## 验证矩阵

- 腾讯纯 Serverless 单/多 EKlet 节点、腾讯混合、腾讯可用 IP 为零、腾讯污点缺失/无法容忍。
- 阿里纯 Serverless 多 Virtual Kubelet 节点、阿里混合、仅名称相似但缺少阿里专属信号、无 Lease 的正常虚拟节点。
- 标准集群、云厂商未知、腾讯/阿里证据冲突。
- 每域通用 Probe、每域 RWO/RWX、双域 RWX Writer/Reader、单域跳过跨域验证。
