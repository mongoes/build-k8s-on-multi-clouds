# Huawei GPSSD2 StorageClass Reconciliation Plan

**Goal:** Safely reconcile Huawei CCE `te-disk` to GPSSD2 without using Everest CSI version or support gating.

**Architecture:** Bash helpers inspect `te-disk` and enumerate PVC/PV references. Reconciliation is based solely on StorageClass state and references; the existing PVC-to-Pod read/write check remains the final storage verdict.

## Rules

- Apply only to Huawei CCE; preserve other cloud paths.
- Expected values are `everest-csi-provisioner`, `GPSSD2`, `3000`, and `125`.
- Missing `te-disk`: directly apply the GPSSD2 template.
- Expected `te-disk`: do not change it.
- Legacy `te-disk` with any PVC/PV reference: WARN and do not mutate it.
- Legacy `te-disk` without references: back up YAML, delete it, recreate GPSSD2, then re-inspect it.
- Do not detect Everest versions, produce support results, or block on version information.
- Keep `verify_storage_e2e "te-disk"` as the final PASS/FAIL verdict.

## Regression coverage

The shell harness mocks `kubectl` and proves all five states: missing direct creation, expected no-op, legacy with PVC retention, legacy with PV retention, and unreferenced legacy backup/delete/create. It also statically rejects version-gating symbols and messages.

## Verification

Run `bash -n k8sAvailCheck.sh`, `bash tests/test_k8s_avail_check.sh`, and `git diff --check`. Stage only the script, test, spec, plan, and implementation report before committing.
