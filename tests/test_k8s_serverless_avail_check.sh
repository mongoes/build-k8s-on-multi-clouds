#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/k8sServerlessAvailCheck.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$script" ]] || fail "serverless script must exist"
grep -qF 'detect_cloud_platform()' "$script" || fail "must detect cloud platform"
grep -qF 'check_platform_features()' "$script" || fail "must retain platform feature checks"
grep -qF 'verify_storage_e2e "te-disk"' "$script" || fail "must verify te-disk"
grep -qF 'verify_storage_e2e "te-nfs"' "$script" || fail "must verify te-nfs"
! grep -qE 'nodeSelector|kubectl get nodes|nodepool-name|auto_build_nodepool' "$script" || fail "must not depend on nodes or node pools"
grep -qF 'kind: Deployment' "$script" || fail "must create a network probe deployment"
grep -qF 'kind: Service' "$script" || fail "must create a ClusterIP service"
grep -qF 'app: serverless-avail-probe' "$script" || fail "probe resources need an exclusive label"
grep -qF 'kubectl delete deployment' "$script" || fail "must clean deployments"
grep -qF 'kubectl delete service' "$script" || fail "must clean services"
grep -qF 'kubectl delete pvc' "$script" || fail "must clean PVCs"
grep -qF 'ReadWriteOnce' "$script" || fail "te-disk must use RWO"
grep -qF 'ReadWriteMany' "$script" || fail "te-nfs must use RWX"
grep -qF 'storage-probe: ${pvc_name}' "$script" || fail "storage pod must have an exclusive readiness label"
grep -qF 'wait_for_pod_ready "storage-probe=${pvc_name}"' "$script" || fail "storage readiness must not select the network probe"
! grep -qF 'verify_nfs_rwx_cross_node' "$script" || fail "must not assert cross-node RWX"

echo 'PASS: serverless availability-check regression assertions'
