# GKE 节点组探测展示真实性修复计划

> 状态：P1，已实施并于 2026-08-03 通过 GKE 交互成功路径现场验收。

## 目标

1. 只有本轮真正观察到“探测前该池无节点、探测后该池 Pod 就绪”时，才展示 `0→1` 扩容信息。
2. GKE/AWS 的自定义节点组路径与预制路径都明确展示 `reserved|od` 同规格二选一（OR）语义。

## 实施步骤

### 1. 先补失败测试

**文件：** `tests/test_k8s_avail_check.sh`

- GKE 自定义 `reserved-4c32g od-4c32g`，实际契约为 `reserved-4c32g|od-4c32g`，输出必须含 OR 说明。
- ACK/CCE 自定义规划不得打印 GKE/AWS OR 说明。
- 探测前已有 `od-4c32g`，探测后 Pod 就绪：结果不得包含 `0→1`。
- 探测前无目标池节点，探测后 `od-4c32g` 就绪：只列该池发生本轮可观察的 `0→1`。
- 混合场景：`reserved-4c32g` 原有、`od-4c32g` 新增，只列 `od-4c32g`。
- 物理机/自建的 `default` 探测永不显示 autoscaler 扩容。

### 2. 统一平台语义输出

**文件：** `k8sAvailCheck.sh`

- 抽取一个只打印平台节点组语义的 helper。
- 预制和管理员自定义成功后调用同一 helper。
- GKE/AWS 输出：`同规格 reserved/od 为二选一；任一节点池可调度即通过。`
- 其他平台不输出该说明，继续遵守各自最终契约。

### 3. 记录本轮探测前后的可观察状态

**文件：** `k8sAvailCheck.sh`

- `pod_deploy_check()` 开始时一次性快照现存节点的 `node.k8s.te/nodepool-name`。
- 对最终契约的每个候选记录“探测前是否已有匹配节点”。
- Pod 就绪后，仅当该池在快照中不存在时，将其加入“本轮从 0 节点变为可调度”列表。
- OR 契约只记录实际就绪的候选，不因另一个候选不存在而误报。

建议文案：

```text
Pod部署启动检查通过：全部N档节点池均可调度起Pod（就绪节点池: od-4c32g）
本次观察到节点池从0节点变为可调度: od-4c32g（符合 autoscaler 0→1 扩容结果）
```

探测前已有节点时只打印第一行。这里证明本轮状态变化，不武断声称一定由 autoscaler 导致。

### 4. 本地回归

```bash
bash -n k8sAvailCheck.sh
bash tests/test_k8s_avail_check.sh
```

通过标准：现有测试不回归，六个新增核心样例逐项通过。

### 5. GKE 现场验收

已有节点场景：

```bash
kubectl get node -L node.k8s.te/nodepool-name
bash k8sAvailCheck.sh
```

预期：自定义路径展示 OR 语义；Pod 探测成功；不出现 `0→1`。

真正的零节点弹性池场景只在有权限、成本可控的测试集群执行：运行前证明目标池无节点，运行后证明目标池出现并承载探测 Pod，且只有该池显示“本次观察到从0节点变为可调度”。该现场样例不是实施阻塞项，本地 mock 必须先覆盖。
