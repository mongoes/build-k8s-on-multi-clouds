# NodePool Consolidation Policy Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone, confirmation-gated Bash utility that changes eligible Karpenter NodePools from `WhenEmptyOrUnderutilized` to `WhenEmpty`.

**Architecture:** The script will query all NodePools through the current kubectl context, parse its own tabular JSONPath output, preview only exact policy matches, and apply a narrow merge patch only after exact `yes` confirmation. A shell test installs a temporary mocked `kubectl` executable to assert command arguments and state transitions without contacting a cluster.

**Tech Stack:** Bash, kubectl JSONPath, kubectl merge patch, mock Bash test harness.

## Global Constraints

- Create a standalone utility; do not edit or call `auto_build_nodepool.sh`.
- Never modify resources until the operator inputs the exact string `yes`.
- Patch only `spec.disruption.consolidationPolicy` and only from `WhenEmptyOrUnderutilized` to `WhenEmpty`.
- Do not require `jq`, AWS CLI, or write kubeconfig, cloud keys, or cluster identifiers.
- Test with a mock `kubectl` and verify syntax with `bash -n`.

---

### Task 1: Build a red test harness for preview and confirmation behavior

**Files:**
- Create: `tests/test_set_nodepool_consolidation_policy.sh`
- Create: `aws eks k8s/v1.35 eks v1.11 karpenter/set_nodepool_consolidation_policy.sh`

**Interfaces:**
- Consumes: script stdin containing `yes` or `no`; a `kubectl` command on `PATH`.
- Produces: stdout preview/result text, exit status, and `kubectl patch nodepool <name> --type=merge -p <payload>` calls.

- [ ] **Step 1: Write the failing cancellation test**

```bash
output="$(printf 'no\n' | PATH="$mock_bin:$PATH" bash "$script")"
assert_contains "$output" 'will change: risky-pool'
assert_not_contains "$(cat "$calls")" 'patch nodepool'
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/test_set_nodepool_consolidation_policy.sh`

Expected: FAIL because `set_nodepool_consolidation_policy.sh` does not exist.

- [ ] **Step 3: Implement the smallest executable script shell**

```bash
#!/usr/bin/env bash
set -u -o pipefail

main() {
  command -v kubectl >/dev/null || return 1
  kubectl get nodepool -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.disruption.consolidationPolicy}{"\n"}{end}'
}

main "$@"
```

- [ ] **Step 4: Run the test to verify the intended assertion still fails**

Run: `bash tests/test_set_nodepool_consolidation_policy.sh`

Expected: FAIL because preview and confirmation logic are absent.

### Task 2: Implement selection, exact confirmation, patch, and read-back verification

**Files:**
- Modify: `aws eks k8s/v1.35 eks v1.11 karpenter/set_nodepool_consolidation_policy.sh`
- Modify: `tests/test_set_nodepool_consolidation_policy.sh`

**Interfaces:**
- Consumes: line-oriented `<nodepool-name>\t<policy>` output from `kubectl get nodepool -o jsonpath=...` and `kubectl get nodepool <name> -o jsonpath=...`.
- Produces: a merge patch `{"spec":{"disruption":{"consolidationPolicy":"WhenEmpty"}}}` for each selected name, then verified success/failure summary.

- [ ] **Step 1: Add failing confirmed-update and verification-failure tests**

```bash
output="$(printf 'yes\n' | PATH="$mock_bin:$PATH" bash "$script")"
assert_contains "$(cat "$calls")" 'patch nodepool risky-pool --type=merge'
assert_not_contains "$(cat "$calls")" 'patch nodepool safe-pool'
assert_contains "$output" 'Modified: risky-pool'

set_mock_readback_policy risky-pool WhenEmptyOrUnderutilized
assert_nonzero "$(printf 'yes\n' | PATH="$mock_bin:$PATH" bash "$script")"
```

- [ ] **Step 2: Run tests to verify they fail for missing behavior**

Run: `bash tests/test_set_nodepool_consolidation_policy.sh`

Expected: FAIL because no patch or verification exists.

- [ ] **Step 3: Implement minimal behavior**

```bash
if [[ "$policy" == 'WhenEmptyOrUnderutilized' ]]; then
  candidates+=("$name")
fi
# after exact yes confirmation
kubectl patch nodepool "$name" --type=merge \
  -p '{"spec":{"disruption":{"consolidationPolicy":"WhenEmpty"}}}'
actual="$(kubectl get nodepool "$name" -o jsonpath='{.spec.disruption.consolidationPolicy}')"
[[ "$actual" == 'WhenEmpty' ]]
```

- [ ] **Step 4: Run tests and syntax validation**

Run: `bash tests/test_set_nodepool_consolidation_policy.sh && bash -n 'aws eks k8s/v1.35 eks v1.11 karpenter/set_nodepool_consolidation_policy.sh'`

Expected: PASS; cancellation has no patch, exact match is patched once, noneligible policy is untouched, and failed read-back returns nonzero.

### Task 3: Document operational use and project state

**Files:**
- Modify: `STATUS.md`
- Modify: `docs/decisions.md`

**Interfaces:**
- Consumes: completed script behavior and test result.
- Produces: a durable record of the standalone scope, exact confirmation gate, narrow patch method, and rerunnable test command.

- [ ] **Step 1: Add an implementation-state entry to `STATUS.md`**

```markdown
新增 P1：独立 Karpenter NodePool consolidation policy 治理脚本；仅预览后经 `yes` 确认，逐对象 JSON merge patch 并回读验证，待目标 EKS 现场回灌。
```

- [ ] **Step 2: Add the safety decision to `docs/decisions.md`**

```markdown
决定：不用导出 YAML 后 apply，也不并入节点池创建脚本；仅对实时值精确匹配 `WhenEmptyOrUnderutilized` 的 NodePool 做字段级 merge patch。
```

- [ ] **Step 3: Re-run checks after documentation updates**

Run: `bash tests/test_set_nodepool_consolidation_policy.sh && bash -n 'aws eks k8s/v1.35 eks v1.11 karpenter/set_nodepool_consolidation_policy.sh' && git diff --check`

Expected: PASS, with no whitespace errors.
