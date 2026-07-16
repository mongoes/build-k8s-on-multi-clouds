# 华为 CCE GPSSD2 StorageClass 安全校验设计

## 目标

华为 CCE 的 `te-disk` 预期为 GPSSD2，参数固定为 `disk-iops=3000` 和 `disk-throughput=125`。脚本不检测、推断或报告 Everest CSI 版本或 GPSSD2 支持度；存储是否真正可用只由端到端 PVC、挂载和读写验证裁决。

## 处置规则

脚本读取 `te-disk` 的 provisioner、`everest.io/disk-volume-type`、`everest.io/disk-iops` 与 `everest.io/disk-throughput`。

- `te-disk` 缺失：直接创建 GPSSD2 StorageClass，不备份、不删除。
- 参数符合 `everest-csi-provisioner` 与 `GPSSD2/3000/125`：保持不变，继续端到端验证。
- 参数不符合：扫描所有命名空间 PVC 与全部 PV；任一 `spec.storageClassName=te-disk` 均视为引用。
- 存在任一引用：不修改 StorageClass，记录 WARN；不执行 apply、patch 或 delete。
- 无引用：备份旧 YAML 到物料目录，删除旧 `te-disk`，创建 GPSSD2，然后重新读取参数确认。

不调用云 API、元数据服务或需要鉴权的接口。

## 最终裁决

既有 `te-disk` 的 `20Gi PVC -> Pod 挂载 -> 读写` 是唯一的最终 PASS/FAIL 裁决。它验证 CSI、权限、配额、可用区与网络能否实际提供并使用目标盘型；失败时保留现有诊断物料。

## 验收测试

- 缺失 `te-disk` 时直接创建 GPSSD2。
- 预期 GPSSD2 `te-disk` 不发生更新。
- 任一 PVC/PV 引用 legacy `te-disk` 时 WARN 且禁止更新。
- 无引用 legacy `te-disk` 时验证“备份、删除、创建”顺序和重建后的预期参数。
- 不包含 Everest 版本检查、支持度结果或基于版本的阻断。
- 保留完整回归测试和端到端存储结果处理。
