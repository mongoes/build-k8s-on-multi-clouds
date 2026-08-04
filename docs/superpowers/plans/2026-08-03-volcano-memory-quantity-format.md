# 火山云节点可分配内存展示修复计划

> 状态：P1，已实施并于 2026-08-03 通过火山 VKE 现场验收。

## 目标

正确解析 Kubernetes `status.capacity.memory` / `status.allocatable.memory` 返回的 Quantity。火山 VKE 实测值 `29258405314600m` 应显示约 `27.2Gi`，不得显示为 CPU 风格的 `29258405314.6C`。

## 根因与边界

- `format_resource()` 当前把所有 `m` 后缀都按 CPU millicore 处理。
- 当前只在火山云现场观察到 memory Quantity 使用 `m`。在没有跨云证据前，不改变通用 `format_resource()`，也不推断其他云的 `m` 具有相同语义。
- 只修展示，不改变节点规格判定使用的原始 Quantity，也不改变调度逻辑。

## 实施步骤

### 1. 先补失败测试

**文件：** `tests/test_k8s_avail_check.sh`

- `format_memory_for_platform volcano 29258405314600m` => `27.2Gi`
- `format_memory_for_platform google 29258405314600m` => 保持通用旧行为，证明修复未扩散到其他云
- `format_resource 31240700Ki` => `29.8Gi`
- `format_resource 33634467840` => `31.3Gi`
- `format_cpu 3920m` => `3.9C`，证明 CPU 展示未被连带修改

先确认第一项在旧代码上失败。

### 2. 增加火山云域内的内存格式化

**文件：** `k8sAvailCheck.sh`

- 保持通用 `format_resource()` 和 `format_cpu()` 原样。
- 新增平台感知的 `format_memory_for_platform(platform, value)`：
  仅当平台标识匹配脚本真实值 `volcengine`（代码域 `*volc*`）且值严格匹配正数 `m` 后缀时，按
  `milli-byte / 1000 / 1024 / 1024 / 1024` 转为 GiB；其他平台、其他后缀全部委托现有 `format_resource()`。
- 给 `discover_and_check_nodes()` 显式传入当前云平台，只在节点池汇总的“内存/可分配内存”两列调用该 helper；CPU、磁盘及其他云路径不变。
- 不采用按数值大小猜平台或单位的启发式判断。

### 3. 本地回归

```bash
bash -n k8sAvailCheck.sh
bash tests/test_k8s_avail_check.sh
```

通过标准：语法检查、完整测试集和新增五个 Quantity 样例全部通过，且测试能证明非火山云输出未改变。

### 4. 火山云现场验收

```bash
NODE='<火山云节点名>'
kubectl get node "$NODE" -o jsonpath='{.status.capacity.memory}{"\n"}{.status.allocatable.memory}{"\n"}'
bash k8sAvailCheck.sh
```

通过标准：

- `可分配内存` 显示合理的 `Gi` 数值；
- 与原始 Quantity 换算误差不超过 0.1Gi；
- CPU 仍以 `C` 展示；
- 节点组规格/契约判断与修复前一致。

当前已有 `29258405314600m -> 27.2Gi` 的充分复现信息，实施不被阻塞。现场复测时补充上述两个原始值作为验收证据即可。
