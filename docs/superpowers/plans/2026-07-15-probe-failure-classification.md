# Probe Failure Classification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make node-pool and storage probes distinguish image/container startup failures from scheduling and node-pool failures.

**Architecture:** Keep the existing per-pool `POOL_EXIST` associative array as the single source of truth, but add explicit terminal values derived from container waiting state and Pod Events. Centralize the user-facing reason text in `_pool_fail_reason`; storage waiting returns a distinguishable code so `main` can report that storage was not validated rather than blaming CSI.

**Tech Stack:** Bash, kubectl JSONPath and describe Events, existing shell regression test harness.

## Global Constraints

- Keep the existing node-pool plan, probe image, timeout, cleanup behavior, and user-owned working-tree changes intact.
- A current container failure takes precedence over historical scheduling Events because it proves the Pod has already been placed on a node.
- Use only the terminal states defined in the approved design: `ready`, `image-pull-failed`, `container-start-failed`, `no-nodepool`, `scheduling-failed`, and `timeout-unknown`.
- Persist `kubectl describe` for every failed probe in the existing artifact directory.

---

### Task 1: Add failing classifications tests

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- Consumes: `_pool_fail_reason(state)` from `k8sAvailCheck.sh`.
- Produces: regression assertions for `image-pull-failed`, `scheduling-failed`, and storage image-pull reporting.

- [ ] **Step 1: Write the failing test**

Append a test block which extracts the pool reason function and storage wait helper, then asserts the desired copy:

```bash
probe_source="$test_tmp/k8sAvailCheck.probe.functions.sh"
sed -n '/^_pool_fail_reason()/,/^# 探测结果/p' "$SCRIPT" >"$probe_source"
source "$probe_source"

[[ "$(_pool_fail_reason image-pull-failed)" == *"镜像拉取失败"* ]] || fail 'image pull must have its own pool failure reason'
[[ "$(_pool_fail_reason scheduling-failed)" == *"调度失败"* ]] || fail 'failed scheduling must have its own pool failure reason'
```

Add text assertions requiring the storage result wording `镜像拉取失败，存储端到端未完成验证` and ensuring the old generic timeout copy is absent from the image-pull case.

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: failure stating that `image-pull-failed` lacks a dedicated pool failure reason.

- [ ] **Step 3: Write minimal implementation**

Do not implement behavior in this task; leave the regression red for Task 2.

- [ ] **Step 4: Confirm the red failure is specific**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: the same assertion fails, while the harness itself loads successfully.

### Task 2: Preserve node-pool terminal causes

**Files:**
- Modify: `k8sAvailCheck.sh:975-987` (`_pool_fail_reason`)
- Modify: `k8sAvailCheck.sh:1190-1323` (node-pool waiting and summary)
- Test: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- Consumes: `containerStatuses[0].state.waiting.reason` and `kubectl describe pods` Events.
- Produces: terminal `POOL_EXIST` values that are not overwritten by the timeout finalization loop.

- [ ] **Step 1: Extend the failing test for event precedence**

Add a mocked response containing both `FailedScheduling` history and `ImagePullBackOff`, then assert the final state is `image-pull-failed`. Add a `FailedScheduling`-only mocked response and assert `scheduling-failed`.

```bash
[[ "${POOL_EXIST[reserved-4c32g]}" == image-pull-failed ]] || fail 'image pull state must not be overwritten as timeout'
[[ "${POOL_EXIST[od-4c32g]}" == scheduling-failed ]] || fail 'FailedScheduling must be classified separately'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: failure because the current code maps both cases to `timeout`.

- [ ] **Step 3: Implement the minimum classification path**

In the waiting loop, check the current waiting reason before autoscaler Event matching:

```bash
case "$waiting_reason" in
ErrImagePull|ImagePullBackOff)
    POOL_EXIST[$pname]="image-pull-failed"
    log_error "  节点池[${pname}]镜像拉取失败(${waiting_reason})，已停止该池等待"
    continue
    ;;
CrashLoopBackOff|CreateContainerConfigError|CreateContainerError|RunContainerError)
    POOL_EXIST[$pname]="container-start-failed"
    log_error "  节点池[${pname}]容器启动失败(${waiting_reason})，已停止该池等待"
    continue
    ;;
esac
```

After loading `pod_desc`, map `FailedScheduling` Events to `scheduling-failed` only when no container terminal state was found. Extend the terminal-state `case` statements and `_pool_fail_reason` so only unresolved pending probes become `timeout-unknown`.

- [ ] **Step 4: Run node-pool regression tests**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: `PASS: availability-check regression assertions`.

### Task 3: Make storage results precise for image failures

**Files:**
- Modify: `k8sAvailCheck.sh:2641-2656` (`_wait_for_storage_pod`)
- Modify: `k8sAvailCheck.sh:2944-2971` (storage result recording)
- Modify: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- Consumes: `_wait_for_storage_pod(pod, timeout)`.
- Produces: `STORAGE_WAIT_REASON=image-pull-failed` on a storage image pull failure.

- [ ] **Step 1: Write the failing test**

Mock a storage Pod with `ImagePullBackOff`, invoke `_wait_for_storage_pod`, and assert:

```bash
[[ "${STORAGE_WAIT_REASON:-}" == image-pull-failed ]] || fail 'storage image pull must be distinguishable from PVC failure'
```

Require the result text `镜像拉取失败，存储端到端未完成验证`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: failure because the current helper returns an undifferentiated nonzero status.

- [ ] **Step 3: Implement the minimum storage cause propagation**

Initialize `STORAGE_WAIT_REASON=""` at helper entry. On `ErrImagePull|ImagePullBackOff`, set it to `image-pull-failed` before returning nonzero. At both block and file storage call sites, branch on this value and record:

```bash
record_result "端到端存储验证(块存储 te-disk, RWO)" "FAIL" "镜像拉取失败，存储端到端未完成验证；请先检查节点到镜像仓库的网络、DNS、认证或镜像缓存"
```

Use corresponding file-storage wording and skip only the dependent cross-node test.

- [ ] **Step 4: Run the full regression suite**

Run: `bash tests/test_k8s_avail_check.sh && git diff --check`

Expected: regression harness passes and `git diff --check` has no output.

### Task 4: Verify and commit only this change set

**Files:**
- Modify: `k8sAvailCheck.sh`
- Modify: `tests/test_k8s_avail_check.sh`
- Create: `docs/superpowers/specs/2026-07-15-probe-failure-classification-design.md`
- Create: `docs/superpowers/plans/2026-07-15-probe-failure-classification.md`

- [ ] **Step 1: Inspect the final scoped diff**

Run: `git diff -- k8sAvailCheck.sh tests/test_k8s_avail_check.sh docs/superpowers`

Expected: only approved probe classification, storage reporting, regression tests, and the accompanying specification/plan are present.

- [ ] **Step 2: Run final verification**

Run: `bash tests/test_k8s_avail_check.sh && git diff --check`

Expected: `PASS: availability-check regression assertions`; no whitespace diagnostics.

- [ ] **Step 3: Create a scoped local commit**

Run:

```bash
git add k8sAvailCheck.sh tests/test_k8s_avail_check.sh \
  docs/superpowers/specs/2026-07-15-probe-failure-classification-design.md \
  docs/superpowers/plans/2026-07-15-probe-failure-classification.md
git commit -m "fix: classify k8s probe failures precisely"
```

Expected: one new local commit; unrelated untracked files remain untouched.

- [ ] **Step 4: Report push status separately**

Run: `git status --short --branch`

Expected: report whether the local branch is ahead of `origin/codex/optimize-k8s-avail-check`; only push after explicit confirmation to publish the commit.
