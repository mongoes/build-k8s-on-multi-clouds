# K8S就绪性检查已验收基线（2026-11-17）

## 分支用途

本分支冻结已经过自动回归和线上实践验收的K8S就绪性检查能力，作为下一轮性能与职责收敛改造的稳定对照。它不是`main`发布决定，后续优化仍需完成真实环境验收后再评审合并。

## 已验收能力

1. 通用Standard检查完整回归。
2. Serverless检查回归。
3. 指定Node Selector专项检查。
4. Pod访问数数公网仓库严格HTTPS检查。
5. AWS Karpenter NodePool构建脚本回归。
6. AWS EKS创建或补充NodePool、检查现有NodePool及EKS可用性的双入口。
7. 多调度域Serverless检查。
8. 华为云CCE检查和存储健康检查。

## 成对发布约束

- `k8sAvailCheck.sh`下载AWS NodePool脚本前校验固定SHA256。
- 固定值必须与同一提交内的`auto_build_nodepool.sh`真实SHA256一致。
- 任一脚本变化都必须同步更新配对测试和完整性校验值，不允许单独发布。

## 下一轮优化范围

- 超大集群只读取一次Nodes JSON，后续节点汇总、节点池契约、调度域和污点标签检查复用该快照。
- 增加阶段耗时和Kubernetes API调用次数统计，区分节点遍历、调度等待和存储回收等待。
- 保持AWS NodePool脚本独立，但将通用可用性结论统一交给`k8sAvailCheck.sh`；创建脚本只保留AWS身份/权限预检、创建和最小资源读回。
- Hybrid不可调度Serverless域重复等待是独立P1体验项，本轮不与节点快照重构混改。

## 尚待定向现场样例

- Kubernetes不低于1.34且旧版Kyverno的自动升级成功及失败人工兜底。
- 历史测试PV明确选择删除和拒绝删除。
- `/etc/hosts`含大写或非法主机名时的容错。
- 历史环境从`data_etl_ta/application.yml`解析MySQL。
- Unschedulable、NotTriggerScaleUp、镜像拉取、DNS、MySQL和网络延迟超标的失败分类。

以上样例用于补齐异常证据，不推翻已经验收的主流程基线；发现真实缺陷时按独立问题修复和回归。

## 可复现验收命令

```bash
bash -n k8sAvailCheck.sh
bash tests/test_k8s_avail_check.sh
bash tests/test_k8s_serverless_avail_check.sh
bash tests/test_k8s_target_node_selector.sh
bash tests/test_k8s_public_repository_connectivity.sh
bash tests/test_auto_build_nodepool.sh
bash tests/test_k8s_ack_te_nfs_subpath.sh
bash tests/test_set_nodepool_consolidation_policy.sh
git diff --check
```

预期：各测试退出码均为0，语法检查与差异检查无输出。
