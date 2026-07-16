#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/k8sAvailCheck.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() { grep -qF "$1" "$SCRIPT" || fail "missing required text: $1"; }
forbid_text() { ! grep -qF "$1" "$SCRIPT" || fail "forbidden text remains: $1"; }

require_text 'get_huawei_cce_vpc_id()'
require_text '检查项说明'
require_text '集群、节点池与调度能力'
require_text '存储动态供给、挂载与读写'
require_text 'Pod、Service/NodePort 与云主机网络连通性'
require_text '执行期间会在 namespace=debug 创建临时探测资源'
require_text 'HUAWEI_CCE_VPC_ID'
require_text 'capture_huawei_csi_nas_diagnostics warning'
require_text 'SERVICE_DATA_PLANE_RETRY_TIMEOUT=30'
require_text 'curl_service_with_retry()'
require_text '_classify_probe_failure()'
require_text 'image-pull-failed'
require_text 'scheduling-failed'
require_text '镜像拉取失败，存储端到端未完成验证'
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
    "get pod storage-image -n debug -o jsonpath={.status.phase}")
        printf 'Pending'
        ;;
    "get pod storage-image -n debug -o jsonpath={.status.containerStatuses[0].state.waiting.reason}")
        printf 'ImagePullBackOff'
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

# 节点池探测必须以当前容器状态优先于历史调度事件，防止镜像失败被误报为调度超时。
probe_source="$test_tmp/k8sAvailCheck.probe.functions.sh"
sed -n '/^_classify_probe_failure()/,/^# 探测结果/p' "$SCRIPT" >"$probe_source"
# shellcheck disable=SC1090
source "$probe_source"
[[ "$(_classify_probe_failure 'ImagePullBackOff' 'Warning FailedScheduling: 0/3 nodes are available')" == image-pull-failed ]] || fail 'image pull must take precedence over historical scheduling events'
[[ "$(_classify_probe_failure '' 'Warning FailedScheduling: 0/3 nodes are available')" == scheduling-failed ]] || fail 'FailedScheduling must have its own terminal state'
[[ "$(_classify_probe_failure '' "pod didn't trigger scale-up: no node group")" == no-nodepool ]] || fail 'autoscaler refusal must remain no-nodepool'
[[ "$(_pool_fail_reason image-pull-failed)" == *"镜像拉取失败"* ]] || fail 'image pull must have a dedicated pool failure reason'

# 存储探测镜像失败只能说明未完成存储验证，不能归因为 PVC 或 CSI 故障。
storage_wait_source="$test_tmp/k8sAvailCheck.storage-wait.functions.sh"
sed -n '/^_wait_for_storage_pod()/,/^}/p' "$SCRIPT" >"$storage_wait_source"
# shellcheck disable=SC1090
source "$storage_wait_source"
NAMESPACE=debug
IMAGE_PULL_FAIL_HINT='image pull failed'
STORAGE_WAIT_REASON=''
if _wait_for_storage_pod storage-image 1; then
    fail 'mocked storage image pull must not become ready'
fi
[[ "$STORAGE_WAIT_REASON" == image-pull-failed ]] || fail 'storage image pull must be distinguishable from PVC failure'

# 所有有效 JDBC MySQL URL 都必须作为目标；同一主机端口仅探测一次，且域名/IP 保持原样。
mysql_source="$test_tmp/k8sAvailCheck.mysql.functions.sh"
sed -n '/^parse_mysql_targets()/,/^# ==================== 混合部署: Pod -> 集群内 MySQL TCP 连通性/p' "$SCRIPT" >"$mysql_source"
log_warning() { MYSQL_WARNINGS="${MYSQL_WARNINGS:-}$*\n"; }
MYSQL_PROBE_TARGETS=()
# shellcheck disable=SC1090
source "$mysql_source"

APP_CONFIG_FILE="$test_tmp/application.yml"
cat >"$APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    url: jdbc:mysql://primary.mysql.example:3306/common?useSSL=false
hive:
  metastore:
    mysql:
      url: jdbc:mysql://primary.mysql.example:3306/hive?useSSL=false
secondary:
  url: "jdbc:mysql://10.10.0.25/report"
# ignored: jdbc:mysql://commented.mysql.example:3307/ignored
EOF
MYSQL_WARNINGS=''
parse_mysql_targets || fail 'valid JDBC MySQL targets should parse'
[[ " ${MYSQL_PROBE_TARGETS[*]} " == *' primary.mysql.example:3306 '* ]] || fail 'hostname target must be retained'
[[ " ${MYSQL_PROBE_TARGETS[*]} " == *' 10.10.0.25:3306 '* ]] || fail 'IP target must retain default port'
[[ ${#MYSQL_PROBE_TARGETS[@]} -eq 2 ]] || fail 'same host and port must be deduplicated'
[[ " ${MYSQL_PROBE_TARGETS[*]} " != *' commented.mysql.example:3307 '* ]] || fail 'commented JDBC URL must be ignored'

cat >"$APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    url: jdbc:mysql:///missing-host
EOF
MYSQL_WARNINGS=''
if parse_mysql_targets; then
    fail 'malformed JDBC MySQL URL must fail parsing'
fi
[[ "$MYSQL_WARNINGS" == *'无法解析'* ]] || fail 'malformed JDBC URL must report a parse reason'

cat >"$APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    username: ta
EOF
MYSQL_WARNINGS=''
if parse_mysql_targets; then
    fail 'missing JDBC MySQL URL must fail parsing'
fi
[[ "$MYSQL_WARNINGS" == *'未找到 jdbc:mysql://'* ]] || fail 'missing JDBC URL must report a parse reason'

require_text 'parse_mysql_targets()'
require_text 'for mysql_target in "${MYSQL_PROBE_TARGETS[@]}"'
require_text 'test_pod_to_mysql_connectivity "$mysql_target"'
require_text 'test_pod_to_host_latency "$mysql_target"'
forbid_text 'MYSQL_PROBE_IP'
forbid_text 'MYSQL_HOST_RAW'
require_text 'huawei_te_disk_before_gpssd2.yaml'
require_text 'record_result "块存储StorageClass就绪检查" "WARN" "发现被PVC/PV依赖的历史te-disk，保留现有盘型以兼容存量应用"'
forbid_text 'check_huawei_gpssd2_support'
forbid_text 'HUAWEI_GPSSD2_SUPPORT'
forbid_text 'Everest版本低于'

# 华为 GPSSD2 仅可替换未被 PVC/PV 使用的旧 te-disk，CSI 版本不参与决策。
huawei_gpssd2_source="$test_tmp/k8sAvailCheck.huawei-gpssd2.functions.sh"
sed -n '/^inspect_huawei_te_disk()/,/^# ==================== StorageClass 确保函数/p' "$SCRIPT" >"$huawei_gpssd2_source"
# shellcheck disable=SC1090
source "$huawei_gpssd2_source"

MOCK_TE_DISK_TYPE='SAS'
MOCK_TE_DISK_IOPS=''
MOCK_TE_DISK_THROUGHPUT=''
MOCK_TE_DISK_EXISTS=1
MOCK_TE_DISK_PVC_BOUND=1
KUBECTL_CALL_LOG="$test_tmp/huawei-kubectl-calls"
kubectl() {
    local cmd="$*"
    printf '%s\n' "$cmd" >>"$KUBECTL_CALL_LOG"
    case "$cmd" in
    "get sc te-disk -o jsonpath="*)
        [[ "$MOCK_TE_DISK_EXISTS" == 1 ]] || return 1
        case "$cmd" in
        *'disk-volume-type'*) printf '%s' "$MOCK_TE_DISK_TYPE" ;;
        *'disk-iops'*) printf '%s' "$MOCK_TE_DISK_IOPS" ;;
        *'disk-throughput'*) printf '%s' "$MOCK_TE_DISK_THROUGHPUT" ;;
        esac
        ;;
    "get pvc -A -o jsonpath="*)
        [[ "$MOCK_TE_DISK_PVC_BOUND" == 1 ]] && printf 'debug/legacy-pvc'
        ;;
    "get pvc legacy-pvc -n debug -o jsonpath="*)
        [[ "$MOCK_TE_DISK_PVC_BOUND" == 1 ]] && printf 'te-disk'
        ;;
    "get pv -o jsonpath="*)
        [[ "${MOCK_TE_DISK_PV_BOUND:-0}" == 1 ]] && printf 'pvc-legacy-pv'
        ;;
    "get sc te-disk -o yaml")
        printf 'kind: StorageClass\nmetadata:\n  name: te-disk\n'
        ;;
    "delete sc te-disk")
        MOCK_TE_DISK_EXISTS=0
        MOCK_TE_DISK_TYPE=''
        MOCK_TE_DISK_IOPS=''
        MOCK_TE_DISK_THROUGHPUT=''
        ;;
    "apply -f -")
        cat >/dev/null
        MOCK_TE_DISK_EXISTS=1
        MOCK_TE_DISK_TYPE='GPSSD2'
        MOCK_TE_DISK_IOPS='3000'
        MOCK_TE_DISK_THROUGHPUT='125'
        ;;
    *) return 0 ;;
    esac
}

inspect_huawei_te_disk
[[ "$HUAWEI_TE_DISK_STATE" == legacy ]] || fail 'SAS te-disk must be legacy'
has_te_disk_dependents || fail 'PVC using te-disk must be a dependency'

# 依赖中的历史 SC 绝不可被 apply、patch 或 delete。
: >"$KUBECTL_CALL_LOG"
ARTIFACT_DIR="$test_tmp/huawei-dependent-artifacts"
if reconcile_huawei_te_disk; then
    fail 'dependent legacy te-disk must be retained'
else
    reconcile_rc=$?
fi
[[ $reconcile_rc -eq 2 ]] || fail 'dependent legacy te-disk must return retained status'
! grep -Eq '^(apply|patch|delete sc te-disk)' "$KUBECTL_CALL_LOG" || fail 'dependent te-disk must not mutate'

# 无依赖时必须先备份，再删除旧 SC，最后应用 GPSSD2 模板。
MOCK_TE_DISK_PVC_BOUND=0
MOCK_TE_DISK_PV_BOUND=0
MOCK_TE_DISK_TYPE='SAS'
MOCK_TE_DISK_IOPS=''
MOCK_TE_DISK_THROUGHPUT=''
: >"$KUBECTL_CALL_LOG"
ARTIFACT_DIR="$test_tmp/huawei-unused-artifacts"
reconcile_huawei_te_disk || fail 'unused legacy te-disk must reconcile to GPSSD2'
backup_index=$(grep -n -m1 '^get sc te-disk -o yaml$' "$KUBECTL_CALL_LOG" | cut -d: -f1)
delete_index=$(grep -n -m1 '^delete sc te-disk$' "$KUBECTL_CALL_LOG" | cut -d: -f1)
apply_index=$(grep -n -m1 '^apply -f -$' "$KUBECTL_CALL_LOG" | cut -d: -f1)
(( backup_index >= 0 && backup_index < delete_index && delete_index < apply_index )) || fail 'backup must precede delete, followed by GPSSD2 creation'
[[ -s "$ARTIFACT_DIR/huawei_te_disk_before_gpssd2.yaml" ]] || fail 'legacy te-disk backup must be retained'

# 缺失 te-disk 时直接创建 GPSSD2，不进行备份或删除。
MOCK_TE_DISK_TYPE=''
MOCK_TE_DISK_IOPS=''
MOCK_TE_DISK_THROUGHPUT=''
MOCK_TE_DISK_EXISTS=0
: >"$KUBECTL_CALL_LOG"
ARTIFACT_DIR="$test_tmp/huawei-missing-artifacts"
reconcile_huawei_te_disk || fail 'missing te-disk must create GPSSD2 directly'
grep -qx 'apply -f -' "$KUBECTL_CALL_LOG" || fail 'missing te-disk must apply GPSSD2 manifest'
! grep -Eq '^(get sc te-disk -o yaml|delete sc te-disk)$' "$KUBECTL_CALL_LOG" || fail 'missing te-disk must not back up or delete'

MOCK_TE_DISK_TYPE='GPSSD2'
MOCK_TE_DISK_IOPS='3000'
MOCK_TE_DISK_THROUGHPUT='125'
MOCK_TE_DISK_PVC_BOUND=0
inspect_huawei_te_disk
[[ "$HUAWEI_TE_DISK_STATE" == expected ]] || fail 'GPSSD2/3000/125 te-disk must be expected'
if has_te_disk_dependents; then fail 'te-disk without PVC/PV use must have no dependency'; fi

echo 'PASS: availability-check regression assertions'
