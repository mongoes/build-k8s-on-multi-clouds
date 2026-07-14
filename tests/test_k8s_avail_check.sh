#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/k8sAvailCheck.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() { grep -qF "$1" "$SCRIPT" || fail "missing required text: $1"; }
forbid_text() { ! grep -qF "$1" "$SCRIPT" || fail "forbidden text remains: $1"; }

require_text 'get_huawei_cce_vpc_id()'
require_text 'HUAWEI_CCE_VPC_ID'
require_text 'capture_huawei_csi_nas_diagnostics warning'
require_text 'SERVICE_DATA_PLANE_RETRY_TIMEOUT=30'
require_text 'curl_service_with_retry()'
require_text 'local deadline=$((SECONDS + SERVICE_DATA_PLANE_RETRY_TIMEOUT))'
require_text '等待Service数据面同步'
require_text 'record_result "Pod网段iptables放行(install.properties持久化)" "WARN"'
forbid_text 'record_result "Pod网段iptables放行(install.properties持久化)" "IMPORTANT"'
require_text '集群内Service(ClusterIP)'
require_text 'Pod内访问NodePort'
require_text '本地服务器和K8S绑定的安全组未相互放行所有流量'
require_text 'K8S CNI未允许直连Pod ip'
forbid_text 'everest.io/share-access-to: b35d40d7-1d27-4914-beb9-79c8f3a31174'
forbid_text 'record_result "StorageClass就绪检查" "WARN"'
forbid_text 'record_result "端到端存储验证(块存储 te-disk, RWO)" "WARN"'
forbid_text 'record_result "端到端存储验证(文件存储 te-nfs, RWX基础)" "WARN"'
forbid_text 'record_result "端到端存储验证(文件存储 te-nfs, RWX跨节点共享)" "WARN"'

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# 仅加载华为 te-nfs 函数，避免 macOS 自带 Bash 不支持脚本其他部分的关联数组。
# 用 kubectl mock 覆盖华为 te-nfs 分支。
source_script="$test_tmp/k8sAvailCheck.functions.sh"
sed -n '/^capture_huawei_csi_nas_diagnostics()/,/^# ==================== 端到端存储验证/p' "$SCRIPT" >"$source_script"
log_step() { :; }
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }
record_result() {
    RESULT_NAMES+=("$1")
    RESULT_STATUS+=("$2")
    RESULT_DETAIL+=("${3:-}")
}
# shellcheck disable=SC1090
source "$source_script"

kubectl() {
    local cmd="$*"
    case "$cmd" in
    "get sc csi-nas -o jsonpath="*)
        [[ -n "${MOCK_CSI_NAS_VPC:-}" ]] || return 1
        printf '%s' "$MOCK_CSI_NAS_VPC"
        ;;
    "get sc csi-nas -o yaml"*)
        printf 'kind: StorageClass\nmetadata:\n  name: csi-nas\n'
        ;;
    "describe sc csi-nas"*)
        printf 'Name: csi-nas\n'
        ;;
    "get sc te-nfs -o jsonpath="*)
        [[ "${MOCK_TE_NFS_EXISTS:-0}" == 1 || -s "${MOCK_APPLIED_MANIFEST:-/nonexistent}" ]] || return 1
        printf '%s' "${MOCK_TE_NFS_VPC:-}"
        ;;
    "get sc te-nfs")
        [[ "${MOCK_TE_NFS_EXISTS:-0}" == 1 || -s "${MOCK_APPLIED_MANIFEST:-/nonexistent}" ]]
        ;;
    "get sc"*)
        printf 'csi-nas\nte-nfs\n'
        ;;
    "auth can-i get storageclass/csi-nas")
        printf 'yes\n'
        ;;
    "apply -f -")
        [[ "${MOCK_APPLY_FAIL:-0}" == 1 ]] && return 1
        cat >"$MOCK_APPLIED_MANIFEST"
        MOCK_TE_NFS_EXISTS=1
        ;;
    *)
        return 0
        ;;
    esac
}

run_huawei_case() {
    local csi_vpc="$1" manual_vpc="$2" te_nfs_exists="$3" te_nfs_vpc="$4"
    RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
    HUAWEI_CCE_VPC_ID="$manual_vpc"
    HUAWEI_CCE_VPC_ID_RESOLVED=""
    MOCK_CSI_NAS_VPC="$csi_vpc"
    MOCK_TE_NFS_EXISTS="$te_nfs_exists"
    MOCK_TE_NFS_VPC="$te_nfs_vpc"
    MOCK_APPLIED_MANIFEST="$test_tmp/applied-${RANDOM}.yaml"
    ARTIFACT_DIR="$test_tmp/artifacts-${RANDOM}"
    LOG_FILE="$test_tmp/k8s.log"
    ensure_nfs_storageclass huawei
}

# 自动解析成功时不需要人工变量，并生成匹配的 te-nfs。
run_huawei_case 'auto-vpc' '' 0 '' || fail 'automatic csi-nas VPC ID should create te-nfs'
grep -qF 'everest.io/share-access-to: auto-vpc' "$MOCK_APPLIED_MANIFEST" || fail 'te-nfs must use csi-nas VPC ID'

# csi-nas 缺失时允许管理员使用环境变量重试。
run_huawei_case '' 'manual-vpc' 0 '' || fail 'manual VPC ID should create te-nfs when csi-nas is unavailable'
grep -qF 'everest.io/share-access-to: manual-vpc' "$MOCK_APPLIED_MANIFEST" || fail 'te-nfs must use manual VPC ID fallback'

# 自动来源与人工值冲突、已有 te-nfs VPC 不一致，都必须失败并登记 FAIL。
if run_huawei_case 'auto-vpc' 'other-vpc' 0 ''; then
    fail 'conflicting automatic and manual VPC IDs must fail'
fi
[[ "${RESULT_STATUS[0]:-}" == FAIL ]] || fail 'VPC source conflict must record FAIL'
find "$ARTIFACT_DIR" -name 'huawei_csi_nas_diagnostic.txt' -print -quit | grep -q . || fail 'VPC source conflict must save diagnostics'

if run_huawei_case 'auto-vpc' '' 1 'wrong-vpc'; then
    fail 'existing te-nfs with a different VPC ID must fail'
fi
[[ "${RESULT_STATUS[0]:-}" == FAIL ]] || fail 'te-nfs VPC mismatch must record FAIL'

# 没有自动或人工来源时必须失败并写入 csi-nas 诊断物料。
if run_huawei_case '' '' 0 ''; then
    fail 'missing automatic and manual VPC IDs must fail'
fi
[[ "${RESULT_STATUS[0]:-}" == FAIL ]] || fail 'missing VPC ID must record FAIL'
find "$ARTIFACT_DIR" -name 'huawei_csi_nas_diagnostic.txt' -print -quit | grep -q . || fail 'missing VPC ID must save diagnostics'

# 自动创建 te-nfs 失败时，网络存储就绪检查本身必须登记 FAIL。
RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
HUAWEI_CCE_VPC_ID=''
MOCK_CSI_NAS_VPC='auto-vpc'
MOCK_TE_NFS_EXISTS=0
MOCK_APPLY_FAIL=1
MOCK_APPLIED_MANIFEST="$test_tmp/apply-fail.yaml"
ARTIFACT_DIR="$test_tmp/apply-fail-artifacts"
LOG_FILE="$test_tmp/apply-fail.log"
if ensure_nfs_storageclass huawei; then
    fail 'failed te-nfs creation must fail the storage-class check'
fi
[[ "${RESULT_STATUS[0]:-}" == FAIL ]] || fail 'failed te-nfs creation must record FAIL'
MOCK_APPLY_FAIL=0

# Service Endpoint 就绪后，数据面可能尚未完成同步；首次失败、下次成功必须重试。
service_source="$test_tmp/k8sAvailCheck.service.functions.sh"
sed -n '/^_capture_service_diagnostics()/,/^# 为指定节点池创建临时/p' "$SCRIPT" >"$service_source"
# shellcheck disable=SC1090
source "$service_source"
SERVICE_DATA_PLANE_RETRY_TIMEOUT=2
service_probe_count_file="$test_tmp/service-probe-count"
printf '0\n' >"$service_probe_count_file"
sleep() { :; }
service_probe() {
    local calls
    calls=$(<"$service_probe_count_file")
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$service_probe_count_file"
    if [[ $calls -eq 1 ]]; then
        echo 'service rule not ready' >&2
        return 7
    fi
    echo 'Welcome to nginx!'
}
if ! curl_service_with_retry 'mock-service' service_probe; then
    fail 'service data plane should succeed after retry'
fi
[[ $SERVICE_CURL_ATTEMPTS -eq 2 ]] || fail 'service data plane should retry once before succeeding'

echo 'PASS: availability-check regression assertions'
