# Serverless K8S 可用性检查设计

## 目标

新增独立临时脚本 `k8sServerlessAvailCheck.sh`，用于 Serverless 模式 Kubernetes 的部署前检查。脚本不读取或校验节点、节点组或 `node.k8s.te/nodepool-name` 标签，也不生成 `nodeSelector`；重点验证网络互通和指定存储类 `te-disk`、`te-nfs` 的端到端可用性。现有 `k8sAvailCheck.sh` 不作任何修改。

## 保留能力

- 检查 `kubectl` 与 Kubernetes API 连通性。
- 识别云平台，并执行原脚本对应的平台特性检查；AWS 环境跳过 `auto_build_nodepool.sh`，因为该流程创建并验证节点组。
- 按已识别的云平台执行 `te-disk`、`te-nfs` 的 StorageClass 就绪检查与原有的配置指引/创建规则。
- 将日志、生成的 YAML 与失败诊断按本次运行时间戳保存在独立物料目录。

## 网络验证

脚本在 `debug` 命名空间创建无调度约束的单副本探测 Deployment。其 Pod 就绪后执行：

1. 执行机访问探测 Service 的 ClusterIP。
2. 探测 Pod 访问执行机 hosts 中可解析的业务地址。
3. 探测 Pod 访问应用配置中发现的 MySQL 地址及云主机地址，并记录 TCP/DNS 诊断与延迟。

不创建或验证 NodePort，不直接访问 Pod IP，也不查询节点；这些操作在 Serverless 集群中没有稳定语义或常被平台限制。Service 数据面不支持、未配置可测目标或应用配置文件不存在时，应明确记录 `SKIP`，而不是误判为节点故障。

## 存储验证

- `te-disk`：检查 StorageClass 后创建 RWO PVC，等待 Bound，启动无调度约束的单 Pod 挂载并执行读写验证。
- `te-nfs`：检查 StorageClass 后创建 RWX PVC，等待 Bound，启动无调度约束的单 Pod 挂载并执行读写验证。
- 不进行 RWX 跨节点共享验证，因为 Serverless 模式不暴露可稳定判断的节点拓扑。基础 PVC 供给、挂载和读写是本脚本的就绪标准。

## 资源与失败处理

临时资源使用脚本专属标签和名称前缀。正常结束以及异常退出时，脚本都清理 Deployment、Service、Pod 和 PVC；生成的 YAML、Pod `describe` 与网络诊断保留在物料目录以便复现。镜像拉取失败、调度/容器启动超时和存储挂载失败应区分记录，且不归因于节点池。

## 测试

新增 Shell 回归测试，静态验证新脚本：

- 不包含 `nodeSelector`、节点或节点组查询、`nodepool-name` 标签引用和 AWS 节点组构建调用；
- 保留云平台识别和平台特性检查入口；
- 包含无调度约束的网络 Deployment 与 Service 探测；
- 包含 `te-disk` RWO 和 `te-nfs` RWX 端到端验证，且不包含跨节点 RWX 验证；
- 包含正常与异常资源清理。
