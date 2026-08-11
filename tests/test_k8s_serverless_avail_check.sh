#!/usr/bin/env bash
set -euo pipefail

# 这是统一主脚本的 Serverless 模式回归，不对应独立 Serverless 可执行脚本。

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/k8sAvailCheck.sh"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "$script" ]] || fail "main availability script must exist"
grep -qF 'detect_serverless_mode()' "$script" || fail "must detect cluster mode"
grep -qF 'SERVERLESS_MODE="Standard"' "$script" || fail "standard mode must use the unified mode name"
grep -qF 'SERVERLESS_MODE="Serverless"' "$script" || fail "serverless mode must use the unified mode name"
! grep -qF 'Standard-only' "$script" || fail "legacy Standard-only mode name must not remain"
! grep -qF 'Serverless-only' "$script" || fail "legacy Serverless-only mode name must not remain"
grep -qF 'serverless_check_domain_health()' "$script" || fail "must gate each Serverless domain"
grep -qF 'serverless_check_platform_features()' "$script" || fail "must retain platform feature checks"
grep -qF 'serverless_verify_storage_e2e "te-disk"' "$script" || fail "must verify te-disk"
grep -qF 'serverless_verify_storage_e2e "te-nfs"' "$script" || fail "must verify te-nfs"
grep -qF 'nodeSelector:' "$script" || fail "must pin each Serverless probe to its virtual node"
grep -qF 'kubernetes.io/hostname:' "$script" || fail "must use hostname to identify a scheduling domain"
serverless_network_source="$test_tmp/serverless-network-probe.sh"
sed -n '/^serverless_apply_network_probe()/,/^}/p' "$script" >"$serverless_network_source"
grep -qF 'build_probe_host_aliases' "$serverless_network_source" || fail "Serverless network probe must inherit validated hostAliases from the Standard probe"
grep -qF '${host_aliases}' "$serverless_network_source" || fail "Serverless network probe must inject generated hostAliases into the Pod spec"
grep -qF 'eks.tke.cloud.tencent.com/eklet' "$script" || fail "must tolerate Tencent EKlet only"
grep -qF 'type: virtual-kubelet' "$script" || fail "must identify Alibaba virtual nodes"
grep -qF 'available-ip-count' "$script" || fail "must validate Tencent subnet IP availability"
grep -qF 'kind: Deployment' "$script" || fail "must create a network probe deployment"
grep -qF 'kind: Service' "$script" || fail "must create a ClusterIP service"
grep -qF 'app: serverless-avail-probe' "$script" || fail "probe resources need an exclusive label"
grep -qF 'Serverless/' "$script" || fail "all Serverless results must be namespaced in the unified summary"
grep -qF 'serverless_record_result()' "$script" || fail "Serverless results must be printed immediately as well as registered"
grep -qF 'serverless_log_wait_progress()' "$script" || fail "long Serverless waits must publish visible progress"
grep -qF 'ensure_namespace' "$script" || fail "Serverless must share namespace preparation"
grep -qF 'SERVERLESS_WAIT_REASON' "$script" || fail "Serverless waits must preserve classified failure reasons"
grep -qF '_storage_e2e_capture_diagnostics' "$script" || fail "Serverless storage failures must reuse detailed diagnostics"
grep -qF '_storage_e2e_cleanup' "$script" || fail "Serverless cleanup must reuse safe PV reclaim logic"
grep -qF 'inspect_tencent_imc_operator()' "$script" || fail "Tencent feature status must have one shared inspector"
grep -qF 'probe-run: ${PROBE_RUN_LABEL}' "$script" || fail "Serverless resources must carry a run-specific cleanup label"
grep -qF 'app=${PROBE_LABEL},probe-run=${PROBE_RUN_LABEL}' "$script" || fail "Serverless cleanup must target only the current run"
grep -qF 'storage: ${E2E_PVC_SIZE}' "$script" || fail "Serverless storage probes must share the common PVC size"
grep -qF 'parse_mysql_targets' "$script" || fail "Serverless must reuse the Standard MySQL target resolver"
grep -qF '"${MYSQL_PROBE_TARGETS[@]}"' "$script" || fail "Serverless must probe every resolved MySQL target"
! grep -qF 'SERVERLESS_NETWORK_TARGET' "$script" || fail "unowned optional business-address probe must be removed"
grep -qF 'kubectl delete deployment' "$script" || fail "must clean deployments"
grep -qF 'kubectl delete service' "$script" || fail "must clean services"
grep -qF 'kubectl delete pvc' "$script" || fail "must clean PVCs"
grep -qF 'ReadWriteOnce' "$script" || fail "te-disk must use RWO"
grep -qF 'ReadWriteMany' "$script" || fail "te-nfs must use RWX"
grep -qF 'storage-probe: ${pvc_name}' "$script" || fail "storage pod must have an exclusive readiness label"
grep -qF 'serverless_wait_for_pod_ready "storage-probe=${pvc_name}"' "$script" || fail "storage readiness must not select the network probe"
grep -qF 'serverless_capture_clusterip_diagnostics()' "$script" || fail "ClusterIP failure must preserve diagnostics"
grep -qF 'PROBE_CLIENT_MISSING' "$script" || fail "must distinguish a missing probe client from network failure"
grep -qF 'serverless_verify_rwx_same_domain()' "$script" || fail "single Serverless domain must verify shared RWX with two Pods"
grep -qF 'Serverless/同一虚拟节点RWX共享' "$script" || fail "same-node RWX result must use the operator-friendly virtual-node name"
grep -qF 'rwx-probe: ${pvc_name}' "$script" || fail "same-domain RWX Pods need an exclusive selector"
grep -qF 'serverless_make_probe_id()' "$script" || fail "must generate bounded RFC1123 probe identifiers"
grep -qF '\$(cat /data/ready)' "$script" || fail "storage command substitution must reach the probe container"

sed -n '/^serverless_make_probe_id()/,/^}/p' "$script" >"$test_tmp/probe-id.sh"
# shellcheck disable=SC1090
source "$test_tmp/probe-id.sh"
probe_id="$(serverless_make_probe_id disk 'eklet-subnet-7o1abju9-06ns10le')"
[[ ${#probe_id} -le 55 ]] || fail "probe identifier must leave room for pod-generated suffixes: $probe_id"
[[ "$probe_id" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || fail "probe identifier must be RFC1123 compatible: $probe_id"
[[ "$probe_id" != *'_'* ]] || fail "probe identifier must not contain underscore: $probe_id"
cross_id="$(serverless_make_probe_id nfs-cross 'eklet-subnet-7o1abju9-06ns10le-eklet-subnet-0qep6zpp-aaq4colp')"
[[ $((${#cross_id} + 7)) -le 63 ]] || fail "cross-domain name must leave room for -writer/-reader: $cross_id"

sed -n '/^serverless_record_result()/,/^}/p' "$script" >"$test_tmp/visible-result.sh"
visible_output=$(
    log_success() { printf 'PASS:%s\n' "$*"; }
    log_warning() { printf 'WARN:%s\n' "$*"; }
    log_error() { printf 'FAIL:%s\n' "$*"; }
    log_info() { printf 'INFO:%s\n' "$*"; }
    record_result() { printf 'REGISTER:%s|%s|%s\n' "$1" "$2" "$3"; }
    # shellcheck disable=SC1090
    source "$test_tmp/visible-result.sh"
    serverless_record_result "Serverless/示例检查" PASS "即时可见"
)
[[ "$visible_output" == *'PASS:即时可见'* ]] || fail "Serverless PASS must be visible before the final summary"
[[ "$visible_output" == *'REGISTER:Serverless/示例检查|PASS|即时可见'* ]] || fail "visible Serverless result must still enter the unified registry"

echo 'PASS: serverless availability-check regression assertions'
