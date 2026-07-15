# 探测 Pod 失败原因精确归类

## 目标

节点池探测失败时，以该探测 Pod 的实际状态与 Kubernetes Events 为依据输出可操作的根因。避免镜像拉取失败被统一覆盖为“调度超时/标签错误”。存储端到端探测遇到相同镜像问题时，明确标识为镜像前置失败，而不是 CSI 或 PVC 失败。

## 范围

- 为每个节点池探测维护独立终态，而非在等待结束后全部覆写为 `timeout`。
- 识别并展示：无匹配节点池、调度失败、镜像拉取失败、容器启动失败、超时未明。
- 在产物目录保存对应 Pod 的 `describe`；终端和结果总览使用同一失败原因。
- 存储验证将镜像拉取失败单独归类为“未验证存储”。

不改变节点池规划、镜像来源、等待超时、资源清理或实际部署资源。

## 状态模型与优先级

每个探测池保存一个终态。检查按以下优先级进行，避免调度事件掩盖容器状态：

1. `ready`：Pod 已 Running。
2. `image-pull-failed`：container waiting reason 为 `ErrImagePull` 或 `ImagePullBackOff`，或 Events 含对应拉取失败信息。
3. `container-start-failed`：容器处于 `CrashLoopBackOff`、`CreateContainerConfigError`、`CreateContainerError` 或 `RunContainerError`，或 Events 显示对应错误。
4. `no-nodepool`：Events 明确显示 autoscaler 没有匹配节点池或拒绝扩容。
5. `scheduling-failed`：Pod 仍 Pending，Events 显示 `FailedScheduling`；诊断输出调度器给出的资源、污点、亲和性等原因。
6. `timeout-unknown`：超时但无法由 Pod 状态或 Events 得到以上结论。

若同一 Pod 同时存在历史调度事件和当前镜像拉取状态，容器失败状态优先，因为它证明 Pod 已被调度到节点。

## 行为与输出

- 等待循环一旦发现可判定的失败终态，立即结束该池的等待；其他节点池继续独立探测。
- 失败行使用状态对应的准确文案。镜像失败必须说明“节点池已可调度或正在节点上启动，但无法拉取探测镜像”，并提示检查节点到镜像仓库的网络、DNS、认证与 TKE 镜像缓存配置。
- `scheduling-failed` 与 `no-nodepool` 保留现有节点 Ready/污点诊断，并补充 `describe` 中的关键 Event。
- 存储探测的镜像失败不宣称 PVC/CSI 故障，结果记为失败且详情为“镜像拉取失败，存储端到端未完成验证”。

## 测试

Shell 回归测试以 mocked `kubectl` 模拟真实命令返回，覆盖：

- `ImagePullBackOff` 被保存并输出为 `image-pull-failed`，且不会被改写为 `timeout`。
- `FailedScheduling` 被归类为 `scheduling-failed`。
- autoscaler 明确拒绝扩容仍归类为 `no-nodepool`。
- 存储 Pod 的 `ImagePullBackOff` 产生“未验证存储”的精确结果。
- 既有华为、Service 数据面重试与文本断言继续通过。

## 验收标准

在 TKE 的“节点 Ready 但不能拉取镜像”场景，`reserved-4c32g` 的最终失败原因是镜像拉取失败；不会出现“调度异常/标签问题”的误导性结论。所有既有回归断言和新增分类回归断言通过。
