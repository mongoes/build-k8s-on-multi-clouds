# Huawei CCE StorageClass Safe Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Report protected legacy Huawei `te-disk` as a passing compatibility outcome, and allow a confirmed CCE `te-nfs` StorageClass-only replacement without touching workload storage objects.

**Architecture:** Extend the storage-class inspection functions in `k8sAvailCheck.sh`. A helper finds PV/PVC references, and a CCE helper gates deletion on interactive `yes`, then deletes and recreates only `StorageClass/te-nfs` with live readback. The shell regression mocks every kubectl operation and asserts resource scope.

**Tech Stack:** Bash, kubectl, `tests/test_k8s_avail_check.sh` mock harness.

## Global Constraints

- The implementation must not write kubeconfig, cloud credentials, tokens, or cluster IDs.
- `te-nfs` replacement may mutate only `StorageClass/te-nfs`; PV, PVC and Pod commands remain read-only.
- Non-TTY, timeout, empty input, and input other than exact `yes` skip replacement and retain a FAIL result.
- A legacy `te-disk` referenced by business PV/PVC is a PASS compatibility result and must mention GPSSD2 was intentionally not applied.
- Update `STATUS.md` and `docs/decisions.md`.

---

### Task 1: Protected `te-disk` result copy

**Files:** Modify `tests/test_k8s_avail_check.sh`; modify `k8sAvailCheck.sh` in `ensure_storageclass()` and its main result mapping.

- [ ] Write assertions requiring the two exact phrases `旧SC仍被业务PVC/PV使用，因此不会更新为GPSSD2` and `已绑定卷和现有Pod不受影响`, plus a `record_result "块存储StorageClass就绪检查" "PASS"` mapping.
- [ ] Run `bash tests/test_k8s_avail_check.sh ./k8sAvailCheck.sh`; expect failure because the PASS copy is absent.
- [ ] Add the protected-path `log_success` with those exact phrases; map return code `2` to PASS with the same detail.
- [ ] Re-run the regression; expect exit code 0.

### Task 2: Confirmed StorageClass-only CCE `te-nfs` replacement

**Files:** Modify `tests/test_k8s_avail_check.sh`; modify `k8sAvailCheck.sh` adjacent to `get_huawei_cce_vpc_id()` and `ensure_nfs_storageclass()`.

**Interfaces:** Add `huawei_te_nfs_replace_after_confirmation()`. It consumes `HUAWEI_CCE_VPC_ID_RESOLVED` and returns success only after `provisioner=everest-csi-provisioner` and `share-access-to` exactly match the resolved VPC ID.

- [ ] Extend the Huawei kubectl mock to capture calls and model SC references. Add failing scenarios: non-interactive execution never calls `delete sc te-nfs`; exact `yes` deletes and recreates only the SC; any `delete pv`, `delete pvc`, or `delete pod` call fails the test; apply/readback failure returns non-zero and prints a restore direction.
- [ ] Run `bash tests/test_k8s_avail_check.sh ./k8sAvailCheck.sh`; expect failure because the helper is missing.
- [ ] Implement the helper: list bound `te-nfs` PV claims; require `[[ -t 0 ]]`; read with 30-second timeout and accept only `yes`; execute `kubectl delete sc te-nfs`, apply the existing CCE standard manifest using the resolved VPC ID, then read back provisioner and VPC. On delete/apply/readback failure, save CCE diagnostics and print manual restore guidance.
- [ ] Invoke the helper only from the Huawei mismatch branch when references exist. On success return 0 to continue RWX checks; every declined/unavailable confirmation remains FAIL.
- [ ] Re-run the regression; expect exit code 0 with scope assertions satisfied.

### Task 3: Durable record and final verification

**Files:** Modify `STATUS.md`, `docs/decisions.md`, `k8sAvailCheck.sh`, and `tests/test_k8s_avail_check.sh`.

- [ ] Add dated STATUS and decision entries: same-name SC replacement requires exact `yes`; it never mutates PV/PVC/Pod; CCE live backfill remains required.
- [ ] Run `bash -n k8sAvailCheck.sh`, `bash -n tests/test_k8s_avail_check.sh`, `bash tests/test_k8s_avail_check.sh ./k8sAvailCheck.sh`, and `git diff --check`; expect all exit code 0.
- [ ] Inspect only the feature diff before staging. If pre-existing shared changes overlap, do not stage or commit them; report the conflict instead.
