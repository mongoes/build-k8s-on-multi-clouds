# Huawei GPSSD2 StorageClass Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely converge unused Huawei CCE `te-disk` StorageClasses to GPSSD2 and accurately report legacy SAS compatibility and GPSSD2 readiness.

**Architecture:** Add Bash helpers around `ensure_storageclass`: inspect `te-disk`, find every PVC/PV dependency, and detect Everest from kubectl-visible controller images. The existing 20Gi PVC-to-Pod read/write check remains the final storage verdict.

**Tech Stack:** Bash, kubectl JSONPath, existing shell regression harness.

## Global Constraints

- Apply this logic only to Huawei CCE; retain all other cloud paths.
- Expected values are `everest-csi-provisioner`, `GPSSD2`, `3000`, and `125`.
- Any PVC or PV referencing `te-disk`, in any state, prevents a StorageClass modification.
- Do not call cloud APIs, metadata endpoints, or any authenticated cloud interface.
- Everest below `2.4.4` is FAIL; an unidentifiable version is WARN; end-to-end PVC validation is the final PASS/FAIL criterion.
- Preserve the user-owned GPSSD2 template change and do not add JDBC port validation.

---

### Task 1: Add red regression coverage for GPSSD2 decisions

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- Consumes `inspect_huawei_te_disk`, `has_te_disk_dependents`, and `check_huawei_gpssd2_support`.
- Produces mocked coverage for expected, legacy-dependent, legacy-unused, and Everest-version states.

- [ ] **Step 1: Write the failing test**

Extract the Huawei disk helpers into the existing temporary test directory. Add a kubectl mock with a SAS `te-disk`, a Bound PVC using it, and `everest-csi-controller:v2.4.3`:

```bash
inspect_huawei_te_disk
[[ "$HUAWEI_TE_DISK_STATE" == legacy ]] || fail 'SAS te-disk must be legacy'
has_te_disk_dependents || fail 'PVC using te-disk must be a dependency'
if check_huawei_gpssd2_support; then fail 'Everest below 2.4.4 must fail'; fi
```

Add cases for expected `GPSSD2/3000/125`, no PVC/PV dependency, `v2.4.4`, and an image without a semantic version.

- [ ] **Step 2: Prove the test is red**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: failure because the new helpers do not exist.

### Task 2: Implement safe classification and reconciliation

**Files:**
- Modify: `k8sAvailCheck.sh` near `ensure_storageclass`
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_k8s_avail_check.sh`

**Interfaces:**
- `inspect_huawei_te_disk()` sets `HUAWEI_TE_DISK_STATE` to `missing`, `expected`, or `legacy`.
- `has_te_disk_dependents()` returns 0 if a PVC or PV uses `te-disk`, otherwise 1.
- `check_huawei_gpssd2_support()` sets `HUAWEI_GPSSD2_SUPPORT` to `pass`, `fail`, or `warn`; only `fail` returns nonzero.
- `reconcile_huawei_te_disk()` returns 0 for expected/updated, 1 for update failure, and 2 for retained legacy storage.

- [ ] **Step 1: Implement inspection and dependency discovery**

Use JSONPath only; do not parse `kubectl get` tables:

```bash
provisioner=$(kubectl get sc te-disk -o jsonpath='{.provisioner}')
disk_type=$(kubectl get sc te-disk -o jsonpath='{.parameters.everest\.io/disk-volume-type}')
iops=$(kubectl get sc te-disk -o jsonpath='{.parameters.everest\.io/disk-iops}')
throughput=$(kubectl get sc te-disk -o jsonpath='{.parameters.everest\.io/disk-throughput}')
pvc=$(kubectl get pvc -A -o jsonpath='{range .items[?(@.spec.storageClassName=="te-disk")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
pv=$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="te-disk")]}{.metadata.name}{"\n"}{end}')
```

Set `expected` only when all four expected values match. Preserve the PVC/PV name lists for warning text.

- [ ] **Step 2: Implement lightweight Everest version detection**

Read controller images through kubectl, select an image containing `everest-csi-controller`, and extract the first `v?MAJOR.MINOR.PATCH` substring. Compare numeric major/minor/patch parts with `2.4.4`. Missing controller or unparseable tag yields `warn`, not a false PASS.

- [ ] **Step 3: Implement the no-dependency update path**

StorageClass parameters are immutable. For a legacy SC with no PVC/PV dependency, call `_ensure_artifact_dir`, save `kubectl get sc te-disk -o yaml` to `huawei_te_disk_before_gpssd2.yaml`, delete `te-disk`, then recreate it with the existing GPSSD2 template and default annotation. Re-run inspection; return failure unless the result is `expected`. If recreation fails, leave the backup path in the FAIL detail for manual restoration.

For any dependency, only log and record WARN with the names and detected legacy parameters. Do not issue `kubectl apply`, `patch`, or `delete` for `te-disk`.

- [ ] **Step 4: Verify green**

Run: `bash tests/test_k8s_avail_check.sh`

Expected: `PASS: availability-check regression assertions`.

### Task 3: Wire results into storage checks and verify

**Files:**
- Modify: `k8sAvailCheck.sh` in the Huawei storage branch and main result recording
- Modify: `tests/test_k8s_avail_check.sh`
- Modify: `docs/superpowers/specs/2026-07-16-huawei-gpssd2-storageclass-design.md`
- Modify: `docs/superpowers/plans/2026-07-16-huawei-gpssd2-storageclass.md`

**Interfaces:**
- Consumes Task 2 state and return values.
- Produces precise GPSSD2 status while retaining `verify_storage_e2e "te-disk"` as the final usability check.

- [x] **Step 1: Wire Huawei handling before generic te-disk early return**

Record exact outcomes:

```bash
record_result "华为GPSSD2支持度检查" "FAIL" "Everest版本低于2.4.4，不支持GPSSD2"
record_result "华为GPSSD2支持度检查" "WARN" "无法从kubectl可靠识别Everest版本；继续以端到端PVC验证为准"
record_result "块存储StorageClass就绪检查" "WARN" "发现被PVC/PV依赖的历史te-disk，保留现有盘型以兼容存量应用"
```

Do not alter the later `verify_storage_e2e "te-disk"` call.

- [x] **Step 2: Add mutation-safety assertions**

In the mocked dependency case, capture kubectl calls and assert there is no `apply`, `patch`, or `delete sc te-disk`. In the no-dependency case, assert backup precedes `delete sc te-disk`, followed by GPSSD2 creation. Require the backup filename and GPSSD2 result strings in static assertions.

- [ ] **Step 3: Run final verification**

Run `bash -n k8sAvailCheck.sh`, then `bash tests/test_k8s_avail_check.sh`, then `git diff --check`.

Expected: syntax exits 0, regression output contains `PASS: availability-check regression assertions`, and whitespace check prints nothing.

- [ ] **Step 4: Commit only scoped files**

Before staging, inspect `git diff --name-only`. Stage only the script, test, and the GPSSD2 spec/plan files; then create:

```bash
git commit -m "feat: validate huawei gpssd2 storage readiness"
```

Do not push without explicit authorization.
