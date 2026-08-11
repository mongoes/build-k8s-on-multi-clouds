# Serverless Visible Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让主脚本按“无编号计划、逐项可视执行、即时结论、唯一总览”的项目规范运行Serverless检查。

**Architecture:** 保留现有Serverless探测与结果登记逻辑，在计划层移除所有数字编号，在执行层为每个结果项补齐主脚本统一步骤横幅和等待进度。公共前置与模式专属计划仍分阶段发布，但各自都是干净的无编号列表。

**Tech Stack:** Bash、kubectl、现有shell回归测试。

## Global Constraints

- 不改变现有ClusterIP、RWO、RWX探测判定。
- Serverless结果继续进入主结果数组、主日志与唯一总览。
- Hybrid的Serverless失败不得阻断Standard分支。
- 计划与执行输出均不使用数字或`S`编号。

---

### Task 1: 无编号计划

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`
- Modify: `k8sAvailCheck.sh`

**Interfaces:**
- Consumes: `print_common_preflight_plan`、`print_standard_check_plan`、`print_serverless_check_plan`
- Produces: 三类无编号计划输出

- [ ] 写入执行计划输出测试，断言公共与Serverless计划不包含`1.`或`S1.`等编号。
- [ ] 运行`bash tests/test_k8s_avail_check.sh`并确认测试因现有编号失败。
- [ ] 移除计划函数中的编号，保留现有区段标题与顺序。
- [ ] 重跑测试并确认通过。

### Task 2: Serverless逐项可视执行

**Files:**
- Modify: `tests/test_k8s_serverless_avail_check.sh`
- Modify: `k8sAvailCheck.sh`

**Interfaces:**
- Consumes: `log_step`、`log_info`、`log_success`、`log_error`、`record_result`
- Produces: `serverless_begin_check(name)`以及等待Pod/PVC时的周期进度输出

- [ ] 写入行为测试，执行受控Serverless流程并断言检查横幅在最终总览前出现。
- [ ] 运行测试并确认因当前流程静默而失败。
- [ ] 为平台特性、调度域、固定Pod、ClusterIP、可选网络、SC、RWO、RWX、同域、跨域和清理逐项打印步骤横幅。
- [ ] 在Pod/PVC等待循环首次及每30秒打印当前状态和剩余时限。
- [ ] 每项结果登记时同步打印即时PASS/FAIL/WARN/SKIP结论。
- [ ] 重跑Serverless与主脚本回归。

### Task 3: 文档与完整验证

**Files:**
- Modify: `STATUS.md`
- Modify: `docs/decisions.md`

**Interfaces:**
- Consumes: Task 1和Task 2最终行为
- Produces: 现场回灌口径

- [ ] 更新项目状态与展示决策。
- [ ] 执行两个脚本`bash -n`、主脚本/Serverless/AWS回归和`git diff --check`。
