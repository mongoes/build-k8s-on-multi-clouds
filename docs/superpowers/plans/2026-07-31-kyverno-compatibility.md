# Kyverno Compatibility Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe, version-aware Kyverno compatibility check immediately after Kubernetes connectivity validation.

**Architecture:** Add isolated Bash helpers to obtain the server minor version, enumerate Kyverno Pod container images in `te-system` and `kube-system`, parse semantic version tags, and decide whether to run the existing ta-admin installer once. Integrate through `record_result`, keeping discovery failure distinct from absence and installation failure actionable.

**Tech Stack:** Bash, kubectl JSONPath, existing log/summary helpers, mocked Bash regression test.

## Global Constraints

- Only Pod names containing `kyverno` in `te-system` and `kube-system` are platform Kyverno candidates.
- Kubernetes threshold is `1.34`; Kyverno minimum is `1.18.0`.
- Any unparseable candidate image version is an upgrade fallback when Kubernetes is at least `1.34`.
- Use `/data/app/.admin_manager_ta/ta-admin te_k8s install -name kyverno` exactly once at most.
- Failed installer execution must record `FAIL` and print the copyable command.

---

### Task 1: Test the Kyverno decision matrix

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- Produces test expectations for `check_kyverno_compatibility`.

- [ ] **Step 1: Add mocked cases**

Add fixtures for no Pod, modern `v1.18.0`, legacy `kyvernopre:v1.10.3`, mixed versions, unparseable tag, Kubernetes `v1.33.x`, and installer nonzero exit.

- [ ] **Step 2: Run the test before production code**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: FAIL because `check_kyverno_compatibility` does not exist.

### Task 2: Implement and integrate the compatibility check

**Files:**
- Modify: `k8sAvailCheck.sh`
- Test: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- Consumes: `kubectl version -o json`, `kubectl get pods -n <namespace>`, `log_*`, `record_result`.
- Produces: `check_kyverno_compatibility()` and one summary result named `Kyverno K8S兼容性检查`.

- [ ] **Step 1: Implement helpers**

Implement numeric `major.minor.patch` comparison, server major/minor extraction, Pod/container image enumeration, image tag parsing, and a single installer wrapper.

- [ ] **Step 2: Place call after connection validation**

Insert `check_kyverno_compatibility` immediately after `record_result "K8S集群连通性检查" ...`, and renumber the displayed plan.

- [ ] **Step 3: Verify unit regression**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: PASS with installer calls asserted exactly once for legacy/unparseable cases.

### Task 3: Update operator-facing records

**Files:**
- Modify: `K8S_AVAILABILITY_CHECK_TODO.md`
- Modify: `STATUS.md`
- Modify: `docs/decisions.md`

- [ ] **Step 1: Add P1 Kyverno compatibility item**

Document namespace scope, thresholds, fallback, installer command, and live-test evidence requirement.

- [ ] **Step 2: Run final verification**

Run: `bash -n k8sAvailCheck.sh && bash tests/test_k8s_avail_check.sh && bash tests/test_k8s_serverless_avail_check.sh && git diff --check`

Expected: all commands exit zero.
