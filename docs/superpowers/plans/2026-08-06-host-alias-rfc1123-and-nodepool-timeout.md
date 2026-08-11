# HostAliases RFC1123 and NodePool Timeout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 防止非法`/etc/hosts`别名破坏探测Deployment，并把节点组交互等待调整为300秒。

**Architecture:** 新增单一职责的`_normalize_probe_hostname`函数，输出合法小写RFC1123名称或返回失败；`build_probe_host_aliases`只接收其成功输出，并基于规范化值去重与冲突检测。节点组菜单继续复用单一超时常量。

**Tech Stack:** Bash、Kubernetes RFC1123 hostAliases、现有Shell回归测试。

## Global Constraints

- 大写名称只转小写，不改变其他字符。
- 无法通过RFC1123校验的别名整条丢弃并WARN。
- 任意非法别名不得进入Deployment YAML。
- `NODEPOOL_PLAN_INPUT_TIMEOUT=300`。

---

### Task 1: 失败样例

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`

- [ ] 增加300秒常量和提示文本断言。
- [ ] 增加大写规范化、规范化冲突、非法字符、空标签、非法横线、标签/总长超限及合法别名共存测试。
- [ ] 运行`bash tests/test_k8s_avail_check.sh`，确认旧实现因输出大写或非法名称而失败。

### Task 2: 最小实现

**Files:**
- Modify: `k8sAvailCheck.sh`

- [ ] 将`NODEPOOL_PLAN_INPUT_TIMEOUT`改为300。
- [ ] 实现`_normalize_probe_hostname <原始名称>`。
- [ ] 在`build_probe_host_aliases`中先规范化再去重，非法值WARN后继续。
- [ ] 运行定向测试并确认PASS。

### Task 3: 记录与完整验证

**Files:**
- Modify: `STATUS.md`
- Modify: `docs/decisions.md`

- [ ] 记录300秒交互边界和非法hosts逐别名隔离策略。
- [ ] 运行`bash -n k8sAvailCheck.sh`、三套回归测试和`git diff --check`。
