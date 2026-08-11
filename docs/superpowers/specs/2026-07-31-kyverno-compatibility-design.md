# Kyverno K8S 兼容性检查设计

## 目标

在 `k8sAvailCheck.sh` 中新增独立检查项“Kyverno K8S兼容性检查”，位于“K8S集群连通性检查”之后。当集群已安装 Kyverno 且 Kubernetes 版本为 1.34 或更高时，发现旧版或无法确认版本的 Kyverno，自动执行一次受控重装。

## 发现与解析

- 仅查询 `te-system` 与 `kube-system`，按 Pod 名包含 `kyverno` 识别平台预装 Kyverno，避免扫描其他命名空间的无关工作负载。
- 对每个匹配 Pod 的常规容器镜像解析 tag，支持 `kyverno-background-controller:v1.10.3` 和 `kyvernopre:v1.10.3` 等任意镜像仓库/组件名。
- 仅接受稳定 `vX.Y.Z` 或 `X.Y.Z` tag，按三个数字字段比较；预发布后缀和非语义 tag 均视为不可解析，不依赖字符串或 `sort -V`。
- 任一匹配镜像 tag 无法解析即视为版本不可确认；任一已解析版本低于 `1.18.0` 即视为旧版。

## 决策

| 条件 | 动作与结果 |
| --- | --- |
| 未发现匹配 Pod | `SKIP`，不安装、不报错。 |
| 无法查询任一目标命名空间 | `WARN`，说明权限或 API 查询异常，不能误报未安装。 |
| 集群版本低于 1.34 | `PASS`，披露发现的版本，不重装。 |
| 集群版本大于等于 1.34，全部版本可解析且均不低于 1.18.0 | `PASS`，不重装。 |
| 集群版本大于等于 1.34，任一版本低于阈值或无法解析 | 执行一次 `/data/app/.admin_manager_ta/ta-admin te_k8s install -name kyverno`。成功记录 `PASS`；失败记录 `FAIL` 并打印该命令供人工执行。 |

## 位置与边界

- 在 `main` 中 `test_k8s_connection` 和其结果登记后立即调用，编号为第 3 项；之后所有计划项顺延。
- 重装命令最多每次脚本运行一次；不删除 Pod、PVC、PV、StorageClass 或其他资源。
- 本地测试替换 `kubectl` 和重装二进制调用，不执行真实安装。
