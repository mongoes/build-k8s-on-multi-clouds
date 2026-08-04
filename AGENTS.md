# GitCode K8s 项目协作规则

- 改动 Kubernetes 检查或构建脚本前，先确认目标集群、云厂商和权限边界。
- 不在仓库中写入 kubeconfig、云密钥、令牌或真实集群标识。
- 脚本改动应提供可复现的验证命令与预期输出。
- 重要取舍更新到 `STATUS.md` 和 `docs/decisions.md`。
