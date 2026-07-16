# GPSSD2 version-gate removal report

## Delivered behavior

- A missing Huawei `te-disk` now applies the GPSSD2 StorageClass directly, without backup or deletion.
- An expected `everest-csi-provisioner` `GPSSD2/3000/125` StorageClass remains unchanged.
- A legacy StorageClass referenced by any PVC or PV remains unchanged and returns WARN.
- An unreferenced legacy StorageClass is backed up, deleted, recreated as GPSSD2, and re-inspected.
- Everest CSI version detection, GPSSD2 support outcomes, version-specific tests, and version-based blocking were removed.
- The existing `verify_storage_e2e "te-disk"` PVC-to-Pod read/write check remains the final storage verdict.

## Verification

- `bash -n k8sAvailCheck.sh` — exit 0
- `bash tests/test_k8s_avail_check.sh` — `PASS: availability-check regression assertions`
- `git diff --check` — exit 0 with no output

## Scope

Changed `k8sAvailCheck.sh`, the shell regression test, and the GPSSD2 design and implementation plan. The test harness now verifies direct missing-SC creation and statically rejects the removed version-gating symbols.
