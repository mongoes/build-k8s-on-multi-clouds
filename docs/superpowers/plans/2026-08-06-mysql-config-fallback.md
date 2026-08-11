# MySQL Config Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为通用K8S可用性检查增加标准MySQL配置优先、历史配置兜底的目标解析能力，并允许有效与损坏URL并存时继续检测。

**Architecture:** 把单文件JDBC扫描提取为 `_parse_mysql_targets_from_file <path>`，由 `parse_mysql_targets` 负责文件优先级和最终错误语义。目标仍写入现有 `MYSQL_PROBE_TARGETS`，因此下游Pod连通性和延迟检查无需改变。

**Tech Stack:** Bash 4+、现有Shell mock回归框架。

## Global Constraints

- 标准文件固定为 `/data/home/ta/base_server_ta/application.yml`。
- 历史文件固定为 `/data/home/ta/data_etl_ta/application.yml`。
- 标准文件只要解析到至少一个有效目标就不得回退历史文件。
- 损坏URL只记录WARN，不删除同文件已解析的有效目标。
- 仅处理主机和端口，不读取或输出MySQL用户名、密码。

---

### Task 1: 单文件容错解析与配置优先级

**Files:**
- Modify: `k8sAvailCheck.sh:325-330,2105-2164`
- Modify: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- Consumes: `_parse_mysql_targets_from_file <path>`
- Produces: `MYSQL_PROBE_TARGETS[]`、`MYSQL_CONFIG_SELECTED`、`MYSQL_PARSE_ERROR`、`MYSQL_PARSE_WARNINGS`

- [ ] **Step 1: 编写失败测试**

新增临时标准/历史文件样例，覆盖标准正常、标准有效与损坏并存、标准缺失回退、标准无URL回退、历史重复目标去重、双文件失败和注释忽略。断言有效与损坏并存时返回成功且不读取历史目标。

- [ ] **Step 2: 确认测试按预期失败**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: FAIL，原因是历史文件变量或新的回退行为尚不存在。

- [ ] **Step 3: 实现最小解析逻辑**

增加：

```bash
APP_CONFIG_FILE="/data/home/ta/base_server_ta/application.yml"
LEGACY_APP_CONFIG_FILE="/data/home/ta/data_etl_ta/application.yml"
MYSQL_CONFIG_SELECTED=""
MYSQL_PARSE_WARNINGS=""
```

实现 `_parse_mysql_targets_from_file` 返回：

- `0`：至少一个有效目标；
- `1`：文件不可读或零有效目标。

该函数遇到损坏URL时累积警告，但存在有效目标仍返回`0`。`parse_mysql_targets`先调用标准文件，失败才清空中间状态并调用历史文件。

- [ ] **Step 4: 运行定向测试**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: `PASS: availability-check regression assertions`

### Task 2: 输出语义、项目记录和完整回归

**Files:**
- Modify: `k8sAvailCheck.sh`
- Modify: `STATUS.md`
- Modify: `docs/decisions.md`

**Interfaces:**
- Consumes: `MYSQL_CONFIG_SELECTED`、`MYSQL_PARSE_WARNINGS`
- Produces: 可审计的日志与结果总览错误信息

- [ ] **Step 1: 固化日志语义**

成功时打印采用文件与去重目标；历史回退打印WARN；损坏URL打印WARN；双失败错误同时列出两个文件并提示“请确认后自行测试MySQL地址”。

- [ ] **Step 2: 更新项目记录**

记录标准配置优先、历史配置兜底、不用历史文件掩盖标准文件部分损坏的决策及现场待验项。

- [ ] **Step 3: 完整验证**

Run:

```bash
bash -n k8sAvailCheck.sh
bash tests/test_k8s_avail_check.sh
bash tests/test_k8s_serverless_avail_check.sh
bash tests/test_set_nodepool_consolidation_policy.sh
git diff --check
```

Expected: 所有命令退出码为0。
