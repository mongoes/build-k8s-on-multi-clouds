#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/k8sServerlessAvailCheck.sh"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$script" ]] || fail "serverless script must exist"
grep -qF 'detect_cluster_mode()' "$script" || fail "must detect cluster mode"
grep -qF 'CLUSTER_MODE="Standard"' "$script" || fail "standard mode must use the unified mode name"
grep -qF 'CLUSTER_MODE="Serverless"' "$script" || fail "serverless mode must use the unified mode name"
! grep -qF 'Standard-only' "$script" || fail "legacy Standard-only mode name must not remain"
! grep -qF 'Serverless-only' "$script" || fail "legacy Serverless-only mode name must not remain"
grep -qF 'discover_serverless_domains()' "$script" || fail "must discover Serverless scheduling domains"
grep -qF 'check_serverless_domain_health()' "$script" || fail "must gate each Serverless domain"
grep -qF 'check_platform_features()' "$script" || fail "must retain platform feature checks"
grep -qF 'verify_storage_e2e "te-disk"' "$script" || fail "must verify te-disk"
grep -qF 'verify_storage_e2e "te-nfs"' "$script" || fail "must verify te-nfs"
grep -qF 'nodeSelector:' "$script" || fail "must pin each Serverless probe to its virtual node"
grep -qF 'kubernetes.io/hostname:' "$script" || fail "must use hostname to identify a scheduling domain"
grep -qF 'eks.tke.cloud.tencent.com/eklet' "$script" || fail "must tolerate Tencent EKlet only"
grep -qF 'type: virtual-kubelet' "$script" || fail "must identify Alibaba virtual nodes"
grep -qF 'available-ip-count' "$script" || fail "must validate Tencent subnet IP availability"
! grep -qE 'nodepool-name|auto_build_nodepool' "$script" || fail "must not depend on standard node pools"
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
grep -qF 'capture_clusterip_diagnostics()' "$script" || fail "ClusterIP failure must preserve diagnostics"
grep -qF 'PROBE_CLIENT_MISSING' "$script" || fail "must distinguish a missing probe client from network failure"
grep -qF 'verify_rwx_same_domain()' "$script" || fail "single Serverless domain must verify shared RWX with two Pods"
grep -qF '同一Serverless调度域RWX共享' "$script" || fail "same-domain RWX result must be explicit"
grep -qF 'rwx-probe: ${pvc_name}' "$script" || fail "same-domain RWX Pods need an exclusive selector"
grep -qF 'make_probe_id()' "$script" || fail "must generate bounded RFC1123 probe identifiers"
grep -qF '\$(cat /data/ready)' "$script" || fail "storage command substitution must reach the probe container"

sed -n '/^make_probe_id()/,/^}/p' "$script" >"$test_tmp/probe-id.sh"
# shellcheck disable=SC1090
source "$test_tmp/probe-id.sh"
probe_id="$(make_probe_id disk 'eklet-subnet-7o1abju9-06ns10le')"
[[ ${#probe_id} -le 55 ]] || fail "probe identifier must leave room for pod-generated suffixes: $probe_id"
[[ "$probe_id" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "probe identifier must be RFC1123 compatible: $probe_id"
[[ "$probe_id" != *'_'* ]] || fail "probe identifier must not contain underscore: $probe_id"
cross_id="$(make_probe_id nfs-cross 'eklet-subnet-7o1abju9-06ns10le-eklet-subnet-0qep6zpp-aaq4colp')"
[[ $((${#cross_id} + 7)) -le 63 ]] || fail "cross-domain name must leave room for -writer/-reader: $cross_id"

echo 'PASS: serverless availability-check regression assertions'
