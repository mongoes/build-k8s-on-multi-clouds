# 华为 CCE GPSSD2 StorageClass 安全校验设计

## 目标

华为 CCE 环境的 `te-disk` 预期使用 Everest GPSSD2，参数固定为 `disk-iops=3000` 与 `disk-throughput=125`。在不依赖华为云鉴权 API 的前提下，识别历史 SAS 环境并避免影响其存量应用；最终仍以真实 PVC、挂载与读写验证为准。

## 现有 te-disk 的处置

脚本读取 `te-disk` 的 provisioner、`everest.io/disk-volume-type`、`everest.io/disk-iops` 与 `everest.io/disk-throughput`。

- 值符合 Everest + `GPSSD2/3000/125`：继续既有端到端验证。
- 值不符合：扫描所有命名空间 PVC 与全部 PV。任一对象的 `spec.storageClassName` 为 `te-disk` 即视为存在依赖，包含 Bound、Pending、Released 等状态。
- 存在依赖：不修改 StorageClass；记录 WARN，说明发现历史 SAS/非预期 te-disk 并保留兼容性。
- 无任何依赖：把当前 SC YAML 备份到物料目录后，将 `te-disk` 调整为 GPSSD2 模板并重新读取参数确认。更新失败记录 FAIL。

## 轻量 GPSSD2 支持度检查

只使用 `kubectl`：确认 Everest controller/driver 工作负载存在，并从 controller 镜像标签提取 Everest 语义版本。

- 已识别且低于 `2.4.4`：记录 `华为GPSSD2支持度检查` FAIL，说明 GPSSD2 不受支持。
- 找不到控制器或无法可靠提取版本：记录 `华为GPSSD2支持度检查` WARN；不把该情况误判为支持或不支持。

当历史 `te-disk` 被 PVC/PV 依赖时，主结果记录 `块存储StorageClass就绪检查` WARN，明确说明保留盘型以兼容存量应用。无依赖重建严格遵循“备份 YAML、删除旧 SC、创建 GPSSD2”顺序。

不调用华为云 API、元数据服务或任何需要云鉴权的接口。EVS 区域可用性、配额、库存与 CSI 实际供给都不由此预检查断言。

## 黄金验证与边界

既有 `te-disk` 的 `20Gi PVC -> Pod 挂载 -> 读写` 保持为最终裁决：它成功才表示当前集群的 CSI、可用区、权限、配额和网络可实际使用目标盘型；失败继续保留 PVC/Pod 诊断物料。

JDBC MySQL 地址继续使用配置中的端口原值，不新增端口范围校验。

## 验收测试

- 预期 GPSSD2 `te-disk`：通过参数检查，不发生更新。
- 非预期 `te-disk` 且任一 PVC/PV 引用：WARN，禁止更新。
- 非预期 `te-disk` 且无引用：备份、更新、复核 GPSSD2 参数。
- Everest 版本低于 2.4.4、版本可识别且合格、版本无法识别三种结果，以及精确的主结果文案。
- 依赖场景不执行 `apply`、`patch` 或 `delete sc te-disk`；无依赖场景验证备份、删除、创建顺序。
- 保留现有完整回归测试和存储端到端结果处理。
