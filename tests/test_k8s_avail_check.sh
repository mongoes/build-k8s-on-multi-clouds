#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/k8sAvailCheck.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() { grep -qF "$1" "$SCRIPT" || fail "missing required text: $1"; }
forbid_text() { ! grep -qF -- "$1" "$SCRIPT" || fail "forbidden text remains: $1"; }

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
require_text 'build_probe_host_aliases()'
require_text 'hostAliases:'
require_text '/etc/hosts'
require_text 'localhost*'
require_text '127.*'
require_text '::1'

host_alias_source="$test_tmp/k8sAvailCheck.host-alias.functions.sh"
sed -n '/^_valid_probe_host_ip()/,/^# 删除所有探测Deployment/p' "$SCRIPT" >"$host_alias_source"
HOST_ALIAS_WARNING_FILE="$test_tmp/host-alias-warnings"
log_warning() { printf "%s\n" "$*" >>"$HOST_ALIAS_WARNING_FILE"; }
# shellcheck disable=SC1090
source "$host_alias_source"
HOST_ALIAS_SOURCE_FILE="$test_tmp/hosts"
cat >"$HOST_ALIAS_SOURCE_FILE" <<'EOF'
10.0.0.10 mysql.internal api.internal localhost localhost.localdomain
10.0.0.11 mysql.internal duplicate.internal
127.0.0.1 loopback.internal
::1 ip6-localhost
192.168.2.9 valid.internal valid.internal
2001:db8::8 ipv6.internal
10.0.0.12 *
not-an-ip ignored.internal
EOF
: >"$HOST_ALIAS_WARNING_FILE"
probe_host_aliases=$(build_probe_host_aliases)
[[ "$probe_host_aliases" == *'ip: "10.0.0.10"'* ]] || fail 'valid executor hosts mapping must become a hostAlias'
[[ "$probe_host_aliases" == *'mysql.internal'* && "$probe_host_aliases" == *'api.internal'* && "$probe_host_aliases" == *'ip: "2001:db8::8"'* ]] || fail 'valid IPv4/IPv6 host mappings must be retained'
[[ "$probe_host_aliases" != *'localhost'* && "$probe_host_aliases" != *'loopback.internal'* && "$probe_host_aliases" != *'ip6-localhost'* ]] || fail 'localhost and loopback mappings must be filtered'
[[ "$probe_host_aliases" != *'k8sAvailCheck.sh'* && "$probe_host_aliases" != *'test_k8s_avail_check.sh'* ]] || fail 'glob-shaped hosts aliases must not expand into workspace filenames'
[[ "$probe_host_aliases" == *'ip: "10.0.0.11"'* && "$probe_host_aliases" == *'duplicate.internal'* ]] || fail 'conflicting hostname must retain non-conflicting aliases'
[[ $(grep -o 'mysql.internal' <<<"$probe_host_aliases" | wc -l) -eq 1 ]] || fail 'conflicting hostname must keep only its first mapping'
grep -qF 'mysql.internal' "$HOST_ALIAS_WARNING_FILE" || fail 'conflicting hostname must emit a warning'
cat >>"$HOST_ALIAS_SOURCE_FILE" <<'EOF'
999.1.1.1 bad-v4.internal
2001:db8:::1 malformed-v6.internal
2001:db8::1" injected.internal
EOF
probe_host_aliases=$(build_probe_host_aliases)
[[ "$probe_host_aliases" != *'bad-v4.internal'* && "$probe_host_aliases" != *'malformed-v6.internal'* && "$probe_host_aliases" != *'injected.internal'* ]] || fail 'malformed or injection-shaped hosts fields must be rejected'

# 真实 Deployment 物料必须内联 hostAliases，而非残留命令替换文本。
ARTIFACT_DIR="$test_tmp/host-alias-manifest"
NAMESPACE=debug
PROBE_PREFIX=np-probe
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }
kubectl() { :; }
_apply_probe_deployment 'np-probe-test' 'test' '' 'nginx:stable'
probe_manifest="$ARTIFACT_DIR/np-probe-test.yaml"
grep -qF 'hostAliases:' "$probe_manifest" || fail 'probe Deployment manifest must inject hostAliases'
grep -qF 'mysql.internal' "$probe_manifest" || fail 'probe Deployment manifest must include inherited hostname'
grep -A1 -F 'ipv6.internal' "$probe_manifest" | grep -q '^      containers:' || fail 'last hostAlias hostname and containers must be separate YAML lines'
! grep -qF 'build_probe_host_aliases' "$probe_manifest" || fail 'probe Deployment manifest must not contain literal command substitution text'
_apply_probe_deployment 'np-probe-selector' 'spot' 'spot-32c128g' 'nginx:stable'
selector_manifest="$ARTIFACT_DIR/np-probe-selector.yaml"
grep -qF 'nodeSelector:' "$selector_manifest" || fail 'selector pool manifest must include nodeSelector'
grep -qF 'node.k8s.te/nodepool-name: "spot-32c128g"' "$selector_manifest" || fail 'selector pool manifest must target the requested node pool'
grep -q '^      nodeSelector:$' "$selector_manifest" || fail 'nodeSelector must be at template.spec indentation'
grep -q '^      hostAliases:$' "$selector_manifest" || fail 'hostAliases must be at template.spec indentation alongside nodeSelector'
# MySQL 探测必须使用 curl 的 TCP connect-only 与 time_connect，不能依赖 nginx 镜像中的 bash/timeout/devtcp。
require_text 'telnet://'
require_text '%{time_connect}'
forbid_text '--connect-only'
forbid_text '/dev/tcp'
forbid_text 'command -v bash'
forbid_text 'command -v timeout'

# curl 成功、缺失、DNS 与 TCP 失败均必须可被 MySQL 探测分类。生产实现需以这些 curl 退出码/输出为准。
mysql_curl_source="$test_tmp/k8sAvailCheck.mysql-curl.functions.sh"
sed -n '/^_mysql_curl_connect()/,/^# ==================== 混合部署: Pod -> MySQL 所在云主机延迟/p' "$SCRIPT" >"$mysql_curl_source"
log_step() { :; }
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }
# shellcheck disable=SC1090
source "$mysql_curl_source"
POD_NAME=mysql-probe NAMESPACE=debug RUN_TS=test ARTIFACT_DIR="$test_tmp/mysql-curl-artifacts"
MYSQL_CURL_MODE=success
kubectl() {
    local cmd="$*"
    case "$cmd" in
    *'telnet://mysql.example.internal:3306'*)
        case "$MYSQL_CURL_MODE" in
        success) printf '0.012\n'; return 0 ;;
        partial) printf '0.012\n'; printf 'curl: (28) Time-out\n' >&2; return 28 ;;
        zero) printf '0.000000\n'; return 0 ;;
        missing) printf 'curl: not found\n' >&2; return 127 ;;
        dns) printf 'curl: (6) Could not resolve host\n' >&2; return 6 ;;
        tcp) printf 'curl: (7) Failed to connect\n' >&2; return 7 ;;
        esac
        ;;
    *) return 0 ;;
    esac
}
MYSQL_CURL_MODE=partial
log_info() { printf '%s\n' "$*"; }
log_success() { printf '%s\n' "$*"; }
connectivity_output=$(test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a 2>&1) || fail 'rc=28 with non-zero time_connect must still pass connectivity'
[[ "$connectivity_output" == *'MySQL TCP握手已建立，服务保持连接，按连接成功计'* ]] || fail 'partial curl success must explain the established TCP handshake'
[[ "$connectivity_output" != *'Time-out'* && "$connectivity_output" != *'command terminated'* ]] || fail 'partial curl stderr must not leak to connectivity output'
MYSQL_CURL_MODE=success
test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a || fail 'curl telnet time_connect success must pass MySQL connectivity'
for mysql_case in missing dns tcp zero; do
    MYSQL_CURL_MODE="$mysql_case"
    if test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a; then
        fail "curl ${mysql_case} failure must fail MySQL connectivity"
    fi
    case "$mysql_case" in
    missing) [[ "$MYSQL_PROBE_FAILURE_REASON" == *'缺少 curl'* ]] || fail 'missing curl must be classified as a probe-tool failure' ;;
    dns) [[ "$MYSQL_PROBE_FAILURE_REASON" == *'DNS'* ]] || fail 'curl DNS failure must be classified as DNS' ;;
    tcp) [[ "$MYSQL_PROBE_FAILURE_REASON" == *'TCP'* ]] || fail 'curl TCP failure must be classified as TCP' ;;
    zero) [[ "$MYSQL_PROBE_FAILURE_REASON" == *'有效连接'* || "$MYSQL_PROBE_FAILURE_REASON" == *'TCP'* ]] || fail 'zero time_connect must fail connectivity classification' ;;
    esac
done
MYSQL_CURL_MODE=tcp
MYSQL_CURL_LOG=''
log_error() { MYSQL_CURL_LOG="${MYSQL_CURL_LOG}$*\n"; }
test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a && fail 'TCP failure must not pass connectivity'
tcp_diagnostic_artifact="$MYSQL_PROBE_DIAGNOSTIC_ARTIFACT"
grep -qF 'curl: (7) Failed to connect' "$tcp_diagnostic_artifact" || fail 'TCP diagnostic artifact must retain curl stderr'
grep -qF 'exit_code=7' "$tcp_diagnostic_artifact" || fail 'TCP diagnostic artifact must retain curl exit code'
[[ "$MYSQL_CURL_LOG" == *'诊断物料已保存至:'* && "$MYSQL_CURL_LOG" == *'mysql_probe_'* ]] || fail 'connectivity failure must log its diagnostic artifact path'
MYSQL_CURL_MODE=partial
capture_mysql_probe_diagnostics pool-a 'mysql.example.internal:3306'
[[ "$MYSQL_PROBE_FAILURE_REASON" == 'curl 诊断复测成功' ]] || fail 'rc28 with non-zero time_connect must classify as diagnostic reprobe success'
mysql_partial_artifact="$MYSQL_PROBE_DIAGNOSTIC_ARTIFACT"
grep -qF 'exit_code=28' "$mysql_partial_artifact" || fail 'diagnostic artifact must retain curl rc28'
grep -qF 'time_connect=0.012' "$mysql_partial_artifact" || fail 'diagnostic artifact must retain curl time_connect'

# time_connect 的秒值必须在脚本端转换为毫秒，不能被 awk 正则错误丢弃。
mysql_latency_source="$test_tmp/k8sAvailCheck.mysql-latency.functions.sh"
sed -n '/^_mysql_curl_connect()/,/^# 连通失败时复用诊断物料/p' "$SCRIPT" >"$mysql_latency_source"
# shellcheck disable=SC1090
source "$mysql_latency_source"
HOST_LATENCY_SAMPLES=1
HOST_LATENCY_THRESHOLD_MS=50
kubectl() {
    local cmd="$*"
    [[ "$cmd" == *'telnet://mysql.example.internal:3306'* ]] && { printf '0.012\n'; printf 'curl: (28) Time-out\ncommand terminated with exit code 28\n' >&2; return 28; }
    return 0
}
test_pod_to_host_latency 'mysql.example.internal:3306' || fail 'curl time_connect sample must pass latency probe'
[[ "$HOST_LATENCY_LAST_MS" == 12 ]] || fail 'curl time_connect 0.012 seconds must become 12ms'
latency_output=$(test_pod_to_host_latency 'mysql.example.internal:3306' 2>&1) || fail 'partial curl success must pass latency probe'
[[ "$latency_output" != *'Time-out'* && "$latency_output" != *'command terminated'* ]] || fail 'partial curl stderr must not leak to latency output'

require_text 'capture_mysql_probe_diagnostics()'
require_text 'write_failure_artifact()'
require_text '/etc/resolv.conf'
require_text '/etc/hosts'
require_text 'stdout'
require_text 'stderr'
require_text 'exit_code'
forbid_text "tcp_command=\"timeout 5 bash -c 'exec 3<>/dev/tcp/\${host}/\${port}' 2>/dev/null\""

# MySQL TCP 探测失败时必须保留 Pod 内诊断物料，便于区分镜像工具缺失、DNS 与端口不可达。
mysql_diagnostic_source="$test_tmp/k8sAvailCheck.mysql-diagnostic.functions.sh"
sed -n '/^_mysql_curl_connect()/,/^# ==================== 混合部署: Pod -> MySQL 所在云主机延迟/p' "$SCRIPT" >"$mysql_diagnostic_source"
log_step() { :; }
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }
# shellcheck disable=SC1090
source "$mysql_diagnostic_source"

MYSQL_DIAGNOSTIC_POOL='reserved-4c32g'
MYSQL_DIAGNOSTIC_TARGET='mysql.example.internal:3306'
POD_NAME='mysql-probe'
NAMESPACE='debug'
RUN_TS='test-run'
ARTIFACT_DIR="$test_tmp/mysql-diagnostic-artifacts"
kubectl() {
    local cmd="$*"
    case "$cmd" in
    *'command -v bash'*) printf '/bin/bash\n' ;;
    *'command -v timeout'*) printf '/usr/bin/timeout\n' ;;
    *'cat /etc/resolv.conf'*) printf 'nameserver 10.96.0.10\n' ;;
    *'telnet://mysql.example.internal:3306'*)
        printf 'tcp probe stdout\n'
        printf 'tcp probe stderr\n' >&2
        return 42
        ;;
    *) return 0 ;;
    esac
}

capture_mysql_probe_diagnostics "$MYSQL_DIAGNOSTIC_POOL" "$MYSQL_DIAGNOSTIC_TARGET"
mysql_diagnostic_artifact=$(find "$ARTIFACT_DIR" -type f -print -quit)
[[ -n "$mysql_diagnostic_artifact" ]] || fail 'failed MySQL exec must create a diagnostic artifact'
grep -qF "$MYSQL_DIAGNOSTIC_TARGET" "$mysql_diagnostic_artifact" || fail 'MySQL diagnostic artifact must include the target'
grep -qF "$MYSQL_DIAGNOSTIC_POOL" "$mysql_diagnostic_artifact" || fail 'MySQL diagnostic artifact must include the node pool'
grep -qF "raw_curl_command=curl --noproxy '*' --connect-timeout 5 --max-time 5 --silent --show-error --output /dev/null --write-out '%{time_connect}' telnet://mysql.example.internal:3306" "$mysql_diagnostic_artifact" || fail 'MySQL diagnostic artifact must retain the raw curl command'
grep -qF 'tcp probe stdout' "$mysql_diagnostic_artifact" || fail 'MySQL diagnostic artifact must include failed command stdout'
grep -qF 'tcp probe stderr' "$mysql_diagnostic_artifact" || fail 'MySQL diagnostic artifact must include failed command stderr'
grep -qF 'exit_code=42' "$mysql_diagnostic_artifact" || fail 'MySQL diagnostic artifact must include failed command exit code'

# 连通失败必须复用诊断物料，不能发起第二次 latency exec。
mysql_latency_gate_source="$test_tmp/k8sAvailCheck.mysql-latency-gate.functions.sh"
sed -n '/^run_mysql_latency_gate()/,/^# ==================== 遍历每个就绪节点池/p' "$SCRIPT" >"$mysql_latency_gate_source"
# shellcheck disable=SC1090
source "$mysql_latency_gate_source"
mysql_fail=0 lat_total=0 lat_fail=0
mysql_failed_pools='' lat_failed_pools='' lat_detail='' lat_skipped_detail=''
MYSQL_LATENCY_CALLS=0
test_pod_to_mysql_connectivity() { return 1; }
test_pod_to_host_latency() { ((MYSQL_LATENCY_CALLS++)); return 0; }
run_mysql_latency_gate 'reserved-4c32g' 'mysql.example.internal:3306'
[[ $MYSQL_LATENCY_CALLS -eq 0 ]] || fail 'failed MySQL connectivity must not call the latency helper'
[[ $lat_total -eq 0 ]] || fail 'failed MySQL connectivity must not count toward latency samples'
[[ "$lat_skipped_detail" == *'reserved-4c32g->mysql.example.internal:3306:未执行（复用连通性失败诊断）'* ]] || fail 'failed MySQL connectivity must record the reused-diagnostic skip detail'
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

# 华为 GPSSD2 仅可替换未被 PVC/PV 使用的旧 SAS te-disk。
huawei_gpssd2_source="$test_tmp/k8sAvailCheck.huawei-gpssd2.functions.sh"
sed -n '/^inspect_huawei_te_disk()/,/^# ==================== 网络存储 StorageClass 确保函数/p' "$SCRIPT" >"$huawei_gpssd2_source"
# shellcheck disable=SC1090
source "$huawei_gpssd2_source"

MOCK_TE_DISK_PROVISIONER='everest-csi-provisioner'
MOCK_TE_DISK_TYPE='SAS'
MOCK_TE_DISK_IOPS=''
MOCK_TE_DISK_THROUGHPUT=''
MOCK_TE_DISK_PVC_BOUND=1
MOCK_TE_DISK_PV_BOUND=0
kubectl() {
    local cmd="$*"
    [[ -n "${MOCK_KUBECTL_CALLS:-}" ]] && printf '%s\n' "$cmd" >>"$MOCK_KUBECTL_CALLS"
    case "$cmd" in
    "get sc te-disk -o jsonpath="*)
        [[ "${MOCK_TE_DISK_EXISTS:-1}" == 1 ]] || return 1
        case "$cmd" in
        *'.provisioner'*) printf '%s' "$MOCK_TE_DISK_PROVISIONER" ;;
        *'disk-volume-type'*) printf '%s' "$MOCK_TE_DISK_TYPE" ;;
        *'disk-iops'*) printf '%s' "$MOCK_TE_DISK_IOPS" ;;
        *'disk-throughput'*) printf '%s' "$MOCK_TE_DISK_THROUGHPUT" ;;
        esac
        ;;
    "get pvc -A -o jsonpath="*)
        [[ "$MOCK_TE_DISK_PVC_BOUND" == 1 ]] && printf 'debug/legacy-pvc\n'
        ;;
    "get pv -o jsonpath="*)
        [[ "$MOCK_TE_DISK_PV_BOUND" == 1 ]] && printf 'legacy-pv\n'
        ;;
    *) return 0 ;;
    esac
}

inspect_huawei_te_disk
[[ "$HUAWEI_TE_DISK_STATE" == legacy ]] || fail 'SAS te-disk must be legacy'
has_te_disk_dependents || fail 'PVC using te-disk must be a dependency'

MOCK_TE_DISK_TYPE='GPSSD2'
MOCK_TE_DISK_IOPS='3000'
MOCK_TE_DISK_THROUGHPUT='125'
MOCK_TE_DISK_PVC_BOUND=0
MOCK_TE_DISK_PV_BOUND=0
inspect_huawei_te_disk
[[ "$HUAWEI_TE_DISK_STATE" == expected ]] || fail 'everest-csi-provisioner GPSSD2/3000/125 te-disk must be expected'
if has_te_disk_dependents; then fail 'te-disk without PVC or PV use must have no dependency'; fi

MOCK_TE_DISK_PROVISIONER='other-csi-provisioner'
inspect_huawei_te_disk
[[ "$HUAWEI_TE_DISK_STATE" == legacy ]] || fail 'GPSSD2 parameters with a non-Everest provisioner must be legacy'
MOCK_TE_DISK_PROVISIONER='everest-csi-provisioner'

MOCK_TE_DISK_TYPE='SAS'
MOCK_TE_DISK_PV_BOUND=1
has_te_disk_dependents || fail 'PV using te-disk must be a dependency even without PVC use'
MOCK_TE_DISK_PV_BOUND=0


# 所有华为路径都必须先做 GPSSD2 支持度检查；FAIL/WARN 均不能创建或迁移 te-disk。
run_huawei_storageclass_case() {
    local state="$1" image="$2"
    MOCK_TE_DISK_EXISTS=1
    MOCK_TE_DISK_PROVISIONER='everest-csi-provisioner'
    MOCK_TE_DISK_TYPE='GPSSD2'
    MOCK_TE_DISK_IOPS='3000'
    MOCK_TE_DISK_THROUGHPUT='125'
    case "$state" in
    missing) MOCK_TE_DISK_EXISTS=0 ;;
    legacy) MOCK_TE_DISK_TYPE='SAS' ;;
    esac
    MOCK_EVEREST_IMAGE="$image"
    MOCK_TE_DISK_PVC_BOUND=0
    MOCK_TE_DISK_PV_BOUND=0
    MOCK_KUBECTL_CALLS="$test_tmp/huawei-storageclass-${state}-${image##*:}.calls"
    : >"$MOCK_KUBECTL_CALLS"
    RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
    ensure_storageclass huawei
}

echo 'PASS: availability-check regression assertions'
