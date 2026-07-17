# MySQL 探测诊断与失败物料设计

## 目标

保留现有 nginx 探测 Pod 与 curl `--connect-only` 连通性方法；在失败时留下可复现证据，避免把探测工具缺失、DNS 失败和真实 TCP 不通混为网络故障。任何检查项登记为 FAIL 时均保留通用失败物料。

## MySQL 失败诊断

`test_pod_to_mysql_connectivity` 的成功路径不变。失败时，在清理探测 Pod 前为每个“节点池 + MySQL 目标”写入物料文件，包含：目标、节点池、Pod、Pod IP、实际执行的 TCP 命令、kubectl exec 退出码、stdout、stderr、`command -v curl`、`/etc/resolv.conf`、`/etc/hosts`、可用时的 `getent hosts` 结果，以及一次不抑制错误的 curl `--connect-only` 尝试。

诊断结果将明确归类为工具缺失、DNS 失败、TCP 连接失败或命令执行异常；汇总失败详情引用物料路径，而不把所有情况笼统表述成安全组或路由故障。

延迟测试只在该目标 TCP 连通成功后执行；连通失败不再重复执行延迟命令，而是记录“未执行（复用连通性失败诊断）”。

## 通用失败物料

`record_result` 在状态为 FAIL 时自动创建每项检查的摘要文件，内容包含检查名、状态、结果详情、日志文件、物料目录和生成时间。涉及 Kubernetes 资源的现有生成 YAML、`describe`、Event 物料继续保留；通用摘要引用物料目录，便于从失败结果定位完整证据。

所有物料写入已有 `ARTIFACT_DIR`，不会引入容器、镜像、外部服务或云 API。

## 验收

- TCP 探测失败时，生成 MySQL 诊断文件且不吞没 stderr/退出码。
- 探测 Pod 缺少 `curl` 时，失败文案指向探测工具环境，不误称 MySQL 网络不通。
- TCP 失败后不执行延迟采样。
- 任意 `record_result(..., FAIL, ...)` 生成通用失败摘要。
- 现有 nginx、节点池、Service、存储和 JDBC 解析回归保持通过。


## 执行机 hosts 继承

临时 `np-probe` Deployment 在 `spec.hostAliases` 内继承执行机 `/etc/hosts` 的映射，且仅输出经过严格校验的 IPv4（每段 0–255）或标准十六进制 IPv6。过滤 `127/8`、`::1`、`localhost`/`localhost*`，主机名只允许字母、数字、点和连字符。按主机名首次映射去重；后续同名不同 IP 记录告警，其他同 IP 别名继续保留。所有 YAML 值均来自此受限字符集并以双引号输出，拒绝引号、冒号伪造和非法 IPv6。

注入发生在 `_apply_probe_deployment` 写入的临时 Deployment 模板 `spec` 下，先计算 `host_aliases` 再内联到 heredoc；生成的 YAML 不得含字面 `build_probe_host_aliases`。MySQL TCP 与延迟继续使用 JDBC 中的原始主机名；失败诊断采集 Pod 的 `/etc/hosts`、`resolv.conf` 和可用的 `getent hosts`，用于验证 hosts/DNS 解析路径。

验收：回归测试必须实际调用 `_apply_probe_deployment` 并检查 manifest 的 `hostAliases`；覆盖回环、localhost、冲突首次映射、非法 IPv4、畸形/注入形 IPv6 的拒绝。
