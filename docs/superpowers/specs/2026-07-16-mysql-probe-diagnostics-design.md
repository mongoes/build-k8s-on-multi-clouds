# MySQL 探测诊断与失败物料设计

## 目标

保留现有 nginx 探测 Pod 与 Bash `/dev/tcp` 连通性方法；在失败时留下可复现证据，避免把探测工具缺失、DNS 失败和真实 TCP 不通混为网络故障。任何检查项登记为 FAIL 时均保留通用失败物料。

## MySQL 失败诊断

`test_pod_to_mysql_connectivity` 的成功路径不变。失败时，在清理探测 Pod 前为每个“节点池 + MySQL 目标”写入物料文件，包含：目标、节点池、Pod、Pod IP、实际执行的 TCP 命令、kubectl exec 退出码、stdout、stderr、`command -v bash`、`command -v timeout`、`/etc/resolv.conf`、可用时的 `getent hosts` 结果，以及一次不抑制错误的 Bash `/dev/tcp` 尝试。

诊断结果将明确归类为工具缺失、DNS 失败、TCP 连接失败或命令执行异常；汇总失败详情引用物料路径，而不把所有情况笼统表述成安全组或路由故障。

延迟测试只在该目标 TCP 连通成功后执行；连通失败不再重复执行延迟命令，而是记录“未执行，复用连通性失败诊断”。

## 通用失败物料

`record_result` 在状态为 FAIL 时自动创建每项检查的摘要文件，内容包含检查名、状态、结果详情、日志文件、物料目录和生成时间。涉及 Kubernetes 资源的现有生成 YAML、`describe`、Event 物料继续保留；通用摘要引用物料目录，便于从失败结果定位完整证据。

所有物料写入已有 `ARTIFACT_DIR`，不会引入容器、镜像、外部服务或云 API。

## 验收

- TCP 探测失败时，生成 MySQL 诊断文件且不吞没 stderr/退出码。
- 探测 Pod 缺少 `timeout` 或 `bash` 时，失败文案指向探测工具环境，不误称 MySQL 网络不通。
- TCP 失败后不执行延迟采样。
- 任意 `record_result(..., FAIL, ...)` 生成通用失败摘要。
- 现有 nginx、节点池、Service、存储和 JDBC 解析回归保持通过。
