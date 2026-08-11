#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/k8sAvailCheck.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }
require_text() { grep -qF "$1" "$SCRIPT" || fail "missing required text: $1"; }
forbid_text() { ! grep -qF -- "$1" "$SCRIPT" || fail "forbidden text remains: $1"; }

require_text 'get_huawei_cce_vpc_id()'
require_text '检查项说明'
require_text 'Standard集群：节点池与调度能力、NodePort Service、宿主机网络及标准存储验证'
require_text 'Hybrid：分别执行Serverless与Standard检查，统一汇总且互不遮蔽失败'
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
require_text 'cleanup_historical_test_pvs || true'
require_text 'HISTORICAL_TEST_PV_CONFIRM_TIMEOUT=30'
require_text 'HISTORICAL_TEST_PV_DELETE_TIMEOUT=60'
require_text 'finalize_availability_check()'
require_text 'check_aws_nodepool_gate()'
require_text 'K8S_VERSION="1.34"'
require_text 'K8S_MINOR_VERSION="34"'
require_text 'kubectl get crd nodepools.karpenter.sh -o name'
require_text "kubectl get nodepools.karpenter.sh -o jsonpath="
require_text 'AWS_TOOL_BASE_URL='
require_text 'bash -n "$script_path"'
require_text 'bash "$script_path"'
require_text 'storage_ready_for_existing_eks.sh'
require_text 'check_aws_consolidation_policy()'
require_text 'detect_serverless_mode()'
require_text 'eks\.tke\.cloud\.tencent\.com'
require_text 'print_common_preflight_plan()'
require_text 'print_standard_check_plan()'
require_text 'print_serverless_check_plan()'
require_text 'print_serverless_skip_plan()'
require_text 'run_serverless_checks_inline()'
require_text 'cleanup_serverless_resources()'
require_text 'ensure_namespace'
require_text 'inspect_tencent_imc_operator()'
require_text 'SERVERLESS_WAIT_REASON'
require_text 'probe-run: ${PROBE_RUN_LABEL}'
require_text 'Serverless/'
forbid_text 'Serverless调度域'
forbid_text '同调度域'
forbid_text '跨Serverless调度域'
require_text 'K8S_CHECK_SCOPE="${K8S_CHECK_SCOPE:-auto}"'
require_text 'get_standard_node_names()'
require_text 'node.k8s.te/nodepool-name'
require_text 'operator: Exists'
forbid_text 'bash "$serverless_script"'
forbid_text 'SERVERLESS_NETWORK_TARGET'
forbid_text 'Serverless/Pod访问指定业务地址网络'
require_text 'Serverless'
require_text 'Hybrid'
require_text 'SERVERLESS_MODE="Standard"'
require_text 'if [[ "$SERVERLESS_MODE" == "Serverless" ]]'
forbid_text 'sh "${script_path}"'
forbid_text 'AWS EKS环境经由特殊流程(auto_build_nodepool.sh)处理，不再进行其他检测'

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# 总览集群名来自管理节点 license 的 company_name；缺文件或无有效字段时必须完全不打印。
cluster_name_source="$test_tmp/k8sAvailCheck.cluster-name.functions.sh"
sed -n '/^_disp_width()/,/^# ==================== 日志函数/p' "$SCRIPT" >"$cluster_name_source"
sed -n '/^get_cluster_name()/,/^# 打印最终汇总/p' "$SCRIPT" >>"$cluster_name_source"
LICENSE_TEST_MODE=valid
license_test_file="$test_tmp/test.license"
touch "$license_test_file"
TA_LICENSE_GLOB="$test_tmp/*license"
jq() {
    [[ "$LICENSE_TEST_MODE" == valid ]] && printf '%s\n' '测试大数据集群' || printf '%s\n' 'null'
}
# shellcheck disable=SC1090
source "$cluster_name_source"
[[ "$(get_cluster_name)" == '测试大数据集群' ]] || fail 'license company_name must be used as the cluster name'
LICENSE_TEST_MODE=missing
rm -f "$license_test_file"
missing_cluster_name=''
if missing_cluster_name=$(get_cluster_name); then
    fail 'missing license must not produce a printable cluster name'
fi
[[ -z "$missing_cluster_name" ]] || fail 'missing license must return no cluster-name text'
LICENSE_TEST_MODE=invalid
touch "$license_test_file"
invalid_cluster_name=''
if invalid_cluster_name=$(get_cluster_name); then
    fail 'invalid company_name must not produce a printable cluster name'
fi
[[ -z "$invalid_cluster_name" ]] || fail 'invalid company_name must return no cluster-name text'

CLUSTER_SUMMARY_LINES=''
log_info() { CLUSTER_SUMMARY_LINES="${CLUSTER_SUMMARY_LINES}$*\n"; }
LICENSE_TEST_MODE=valid
print_cluster_name_summary 12
[[ "$CLUSTER_SUMMARY_LINES" == *'  [ 信息 ] 集群名称     —— 测试大数据集群'* ]] || fail 'valid license must print an aligned information row at summary start'
[[ "$CLUSTER_SUMMARY_LINES" != *'集群名：'* ]] || fail 'cluster name must not use the old standalone summary format'
CLUSTER_SUMMARY_LINES=''
LICENSE_TEST_MODE=missing
rm -f "$license_test_file"
print_cluster_name_summary
[[ -z "$CLUSTER_SUMMARY_LINES" ]] || fail 'non-management node must omit the cluster-name summary line entirely'
require_text 'print_cluster_name_summary'

# te-disk初始化是有风险的SC变更：300秒无输入或非Y输入必须保持原SC，
# 并把Serverless SC及后续RWO路径标记为SKIP，而不是误报PASS后创建必失败PVC。
te_disk_confirm_source="$test_tmp/k8sAvailCheck.te-disk-confirm.functions.sh"
awk '/^_confirm_te_disk_reinitialize\(\)/ { capture=1 } capture && /^ensure_nfs_storageclass\(\)/ { exit } capture { print }' "$SCRIPT" >"$te_disk_confirm_source"
# shellcheck disable=SC1090
source "$te_disk_confirm_source"
TE_DISK_REINIT_CONFIRM_TIMEOUT=300
TE_DISK_CONFIRM_OUTPUT_PATH=/dev/null
TE_DISK_CONFIRM_LOG=''
log_warning() { TE_DISK_CONFIRM_LOG="${TE_DISK_CONFIRM_LOG}$*"; }
log_info() { TE_DISK_CONFIRM_LOG="${TE_DISK_CONFIRM_LOG}$*"; }

empty_confirm_input="$test_tmp/empty-confirm-input"
: >"$empty_confirm_input"
TE_DISK_CONFIRM_INPUT_PATH="$empty_confirm_input"
te_disk_confirm_rc=0
_confirm_te_disk_reinitialize || te_disk_confirm_rc=$?
[[ $te_disk_confirm_rc -eq 2 ]] || fail 'te-disk confirmation timeout/EOF must return the intentional-skip status 2'
[[ "$TE_DISK_CONFIRM_LOG" == *'300秒内未收到确认，已保持原StorageClass不变，不会重新初始化te-disk'* ]] || fail 'te-disk confirmation timeout must clearly state that the existing SC is unchanged'

printf 'n\n' >"$test_tmp/reject-confirm-input"
TE_DISK_CONFIRM_INPUT_PATH="$test_tmp/reject-confirm-input"
TE_DISK_CONFIRM_LOG=''
te_disk_confirm_rc=0
_confirm_te_disk_reinitialize || te_disk_confirm_rc=$?
[[ $te_disk_confirm_rc -eq 2 ]] || fail 'non-y te-disk confirmation must return the intentional-skip status 2'
[[ "$TE_DISK_CONFIRM_LOG" == *'已保持原StorageClass不变，不会重新初始化te-disk'* ]] || fail 'non-y te-disk confirmation must clearly state that the existing SC is unchanged'

printf 'y\n' >"$test_tmp/accept-confirm-input"
TE_DISK_CONFIRM_INPUT_PATH="$test_tmp/accept-confirm-input"
_confirm_te_disk_reinitialize || fail 'y must authorize te-disk reinitialization'

printf 'n\n' >"$test_tmp/ensure-reject-confirm-input"
TE_DISK_CONFIRM_INPUT_PATH="$test_tmp/ensure-reject-confirm-input"
log_step() { :; }
log_success() { :; }
record_result() { :; }
kubectl() {
    case "$*" in
    'get sc -o jsonpath='*) printf '%s\n' 'te-disk-essd' ;;
    *) return 0 ;;
    esac
}
ensure_te_disk_rc=0
ensure_storageclass alibaba || ensure_te_disk_rc=$?
[[ $ensure_te_disk_rc -eq 2 ]] || fail 'ensure_storageclass must propagate intentional te-disk initialization refusal as status 2'

serverless_sc_source="$test_tmp/k8sAvailCheck.serverless-sc.functions.sh"
awk '/^serverless_ensure_storageclass\(\)/ { capture=1 } capture && /^serverless_wait_reason_detail\(\)/ { exit } capture { print }' "$SCRIPT" >"$serverless_sc_source"
# shellcheck disable=SC1090
source "$serverless_sc_source"
SERVERLESS_RESULT_STATUS=''
SERVERLESS_RESULT_DETAIL=''
cloud_platform=alibaba
ensure_storageclass() { return 2; }
serverless_record_result() { SERVERLESS_RESULT_STATUS="$2"; SERVERLESS_RESULT_DETAIL="$3"; }
serverless_sc_rc=0
serverless_ensure_storageclass te-disk || serverless_sc_rc=$?
[[ $serverless_sc_rc -eq 2 ]] || fail 'Serverless te-disk refusal must preserve the intentional-skip status 2'
[[ "$SERVERLESS_RESULT_STATUS" == SKIP ]] || fail 'Serverless te-disk refusal must record SC readiness as SKIP'
[[ "$SERVERLESS_RESULT_DETAIL" == *'保持原StorageClass不变'* ]] || fail 'Serverless te-disk SKIP must explain that the existing SC was preserved'

serverless_inline_source="$test_tmp/k8sAvailCheck.serverless-inline.functions.sh"
awk '/^run_serverless_checks_inline\(\)/ { capture=1 } capture && /^# ==================== 内置K8S节点标签统一/ { exit } capture { print }' "$SCRIPT" >"$serverless_inline_source"
# shellcheck disable=SC1090
source "$serverless_inline_source"
SERVERLESS_DOMAINS=('virtual-kubelet-zone-a|alibaba|zone-a|||')
SERVERLESS_DISK_E2E_CALLS=0
SERVERLESS_DISK_SKIP_ROWS=0
serverless_check_platform_features() { :; }
serverless_ensure_storageclass() { [[ "$1" == te-disk ]] && return 2; return 1; }
serverless_check_domain_health() { return 0; }
serverless_check_network_readiness() { return 0; }
serverless_make_probe_id() { printf 'probe-%s\n' "$1"; }
serverless_verify_storage_e2e() { [[ "$1" == te-disk ]] && ((SERVERLESS_DISK_E2E_CALLS += 1)); return 0; }
serverless_record_result() {
    [[ "$1" == Serverless/端到端存储验证\(te-disk,* && "$2" == SKIP ]] && ((SERVERLESS_DISK_SKIP_ROWS += 1))
    return 0
}
cleanup_serverless_resources() { :; }
run_serverless_checks_inline
[[ $SERVERLESS_DISK_E2E_CALLS -eq 0 ]] || fail 'Serverless must not create a te-disk E2E probe after initialization was refused'
[[ $SERVERLESS_DISK_SKIP_ROWS -eq 1 ]] || fail 'Serverless must record one te-disk E2E SKIP per healthy virtual node when te-disk is unavailable'

# 历史 PV 清理必须只在完成现场标准检查后执行；AWS NodePool 前置门禁失败时不得
# 顺带扫描或删除历史 PV，以免一个只读门禁扩大为无关资源变更。
main_source="$test_tmp/k8sAvailCheck.main.sh"
sed -n '/^main()/,/^# ==================== 资源清理/p' "$SCRIPT" >"$main_source"
! grep -q 'cleanup_historical_test_pvs || true' "$main_source" || fail 'test PV cleanup must not run before the end of the main flow'
[[ "$(grep -c 'finalize_availability_check' "$main_source")" -eq 3 ]] || fail 'Serverless scope, auto Serverless, and completed Standard/Hybrid paths must each finalize exactly once'
grep -q 'check_aws_nodepool_gate' "$main_source" || fail 'AWS NodePool gate must run before nodepool plan and storage checks'
grep -q 'print_common_preflight_plan' "$main_source" || fail 'main must publish the common preflight plan before mode detection'
grep -q 'print_mode_specific_plan' "$main_source" || fail 'main must publish a mode-specific plan after environment detection'
grep -q 'run_serverless_checks_inline' "$main_source" || fail 'main must execute Serverless checks in-process'
grep -q 'run_serverless_checks_inline' "$main_source" && grep -q 'select_nodepool_business_plan' "$main_source" || fail 'Hybrid path must retain both Serverless and Standard branches'

# 计划展示必须先公共前置、后模式专属；Serverless计划不得混入标准节点检查项。
plan_source="$test_tmp/k8sAvailCheck.plan.functions.sh"
sed -n '/^print_common_preflight_plan()/,/^# ==================== 主执行流程/p' "$SCRIPT" >"$plan_source"
plan_output=$(
    BOLD='' NC='' HOST_LATENCY_THRESHOLD_MS=50 SERVERLESS_MODE=Serverless
    _banner_line() { printf '%s' "$1"; }
    log_info() { printf '%s\n' "$*"; }
    # shellcheck disable=SC1090
    source "$plan_source"
    print_common_preflight_plan
    print_mode_specific_plan
)
[[ "$plan_output" == *'- kubectl检查'* ]] || fail 'common preflight plan must be published without numbering'
[[ "$plan_output" == *'Serverless后续检查计划'* ]] || fail 'Serverless plan must be published after mode detection'
[[ "$plan_output" == *'Pod访问ClusterIP Service检查'* ]] || fail 'Serverless plan must describe ClusterIP validation'
[[ "$plan_output" != *'节点组业务规划选择'* ]] || fail 'Serverless-only plan must not include standard nodepool checks'
[[ "$plan_output" != *'本地服务器访问Kubernetes Service连通性检查(NodePort)'* ]] || fail 'Serverless-only plan must not include NodePort checks'
! grep -qE '(^|[[:space:]])([0-9]+|S[0-9]+)\.' <<<"$plan_output" || fail 'published plans must not contain numeric item prefixes'

skip_plan_output=$(
    BOLD='' NC=''
    _banner_line() { printf '%s' "$1"; }
    log_info() { printf '%s\n' "$*"; }
    # shellcheck disable=SC1090
    source "$plan_source"
    print_serverless_skip_plan
)
[[ "$skip_plan_output" == *'不执行Standard检查'* ]] || fail 'Serverless compatibility entry must clearly skip Standard checks on a Standard cluster'

# 阿里/腾讯仅以虚拟节点强指纹分流；普通节点及其他云不能被误导进入Serverless路径。
serverless_mode_source="$test_tmp/k8sAvailCheck.serverless-mode.functions.sh"
sed -n '/^detect_serverless_mode()/,/^}/p' "$SCRIPT" >"$serverless_mode_source"
log_info() { :; }
log_error() { :; }
# shellcheck disable=SC1090
source "$serverless_mode_source"
kubectl() {
    case "$*" in
    "get nodes -o jsonpath="*) printf '%b' "$MODE_NODES" ;;
    "get node "*)
        local node="${3}"
        case "$node" in
        eklet-a) printf '%s\n' "$MODE_EKLET_A" ;;
        eklet-b) printf '%s\n' "$MODE_EKLET_B" ;;
        worker-a) printf '%s\n' "$MODE_WORKER_A" ;;
        virtual-kubelet-a) printf '%s\n' "$MODE_VIRTUAL_KUBELET_A" ;;
        *) return 1 ;;
        esac
        ;;
    *) return 1 ;;
    esac
}
MODE_NODES=$'eklet-a\neklet-b\n'
MODE_EKLET_A='node.kubernetes.io/instance-type: eklet'
MODE_EKLET_B='eks.tke.cloud.tencent.com/subnet-id: subnet-b'
detect_serverless_mode tencent || fail 'Tencent EKlet-only mode detection must succeed'
[[ "$SERVERLESS_MODE" == Serverless ]] || fail 'Tencent EKlet-only cluster must be Serverless'

MODE_NODES=$'eklet-a\nworker-a\n'
MODE_WORKER_A='node.kubernetes.io/instance-type: S5.MEDIUM4'
detect_serverless_mode tencent || fail 'Tencent hybrid mode detection must succeed'
[[ "$SERVERLESS_MODE" == Hybrid ]] || fail 'Tencent virtual plus standard nodes must be Hybrid'

MODE_NODES=$'worker-a\n'
detect_serverless_mode tencent || fail 'Tencent standard mode detection must succeed'
[[ "$SERVERLESS_MODE" == Standard ]] || fail 'Tencent standard nodes must remain Standard'

MODE_NODES=$'virtual-kubelet-a\n'
MODE_VIRTUAL_KUBELET_A=$'type: virtual-kubelet\nservice.alibabacloud.com/eni-id: eni-1'
detect_serverless_mode alibaba || fail 'Alibaba virtual-kubelet mode detection must succeed'
[[ "$SERVERLESS_MODE" == Serverless ]] || fail 'Alibaba virtual-kubelet cluster must be Serverless'

# 第二层业务节点组规划：预制方案必须经云厂商规则展开，并允许管理员完整替代默认规划。
nodepool_plan_source="$test_tmp/k8sAvailCheck.nodepool-plan.functions.sh"
sed -n '/^get_cloud_default_nodepools()/,/^# Pod探测就绪总超时/p' "$SCRIPT" >"$nodepool_plan_source"
PLAN_RESULTS=()
record_result() { PLAN_RESULTS+=("$1|$2|${3:-}"); }
log_info() { PLAN_LOGS="${PLAN_LOGS:-}$*\n"; }
log_warning() { PLAN_LOGS="${PLAN_LOGS:-}$*\n"; }
log_error() { PLAN_LOGS="${PLAN_LOGS:-}$*\n"; }
log_success() { PLAN_LOGS="${PLAN_LOGS:-}$*\n"; }
# shellcheck disable=SC1090
source "$nodepool_plan_source"

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
NODEPOOL_PLAN_LABEL=''
NODEPOOL_PLAN_BASELINE=''
NODEPOOL_PLAN_SOURCE=''
select_predefined_nodepool_plan alibaba 3 || fail 'ACK Trino/SR preset should be selectable'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-32c128g spot-32c128g' ]] || fail 'ACK high-cost preset must require reserved and spot pools'
[[ -n "$NODEPOOL_PLAN_LABEL" ]] || fail 'preset must retain a business label for the final summary'

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
select_predefined_nodepool_plan google 1 || fail 'GKE base preset should be selectable'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-4c32g|od-4c32g' ]] || fail 'GKE base preset must translate regular pools to OR'

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
select_predefined_nodepool_plan tencent 3 || fail 'Tencent high-cost preset should be selectable'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-32c128g od-32c128g spot-32c128g' ]] || fail 'Tencent preset must preserve high-cost od pool'

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
_nodepool_plan_try_menu_input alibaba 'reserved-4c32g' || fail 'a valid nodepool entered at the first menu prompt should become a custom plan'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-4c32g' ]] || fail 'direct custom input must not fall back to the cloud default map'
[[ "$NODEPOOL_PLAN_LABEL" == '管理员自定义' ]] || fail 'direct custom input must be summarized as administrator custom plan'

if _nodepool_plan_try_menu_input alibaba 'not-a-nodepool'; then
    fail 'an invalid first-menu input must still be rejected for retry handling'
fi

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
PLAN_LOGS=''
set_custom_nodepool_plan google 'reserved-8c32g od-8c32g spot-32c128g' || fail 'valid custom plan should be accepted'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-8c32g|od-8c32g spot-32c128g' ]] || fail 'GKE custom regular pools must be OR-normalized'
[[ "$(get_expected_nodepools google)" == "$NODEPOOL_PLAN_EFFECTIVE" ]] || fail 'custom plan must replace the cloud default map'
[[ "$PLAN_LOGS" == *'同规格reserved/od任一可调度即通过'* ]] || fail 'GKE custom plan must explain reserved/od OR semantics'

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
PLAN_LOGS=''
set_custom_nodepool_plan alibaba 'on-demand-8c32g' || fail 'legacy on-demand custom pool should be accepted'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'on-demand-8c32g' ]] || fail 'Alibaba custom on-demand pool must retain its real nodepool label'
[[ "$PLAN_LOGS" != *'同规格reserved/od任一可调度即通过'* ]] || fail 'Alibaba custom plan must not print GKE/AWS OR semantics'

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
set_custom_nodepool_plan google 'on-demand-8c32g' || fail 'GKE legacy on-demand custom pool should be accepted'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-8c32g|od-8c32g|on-demand-8c32g' ]] || fail 'GKE custom on-demand pool must remain a schedulable OR candidate'

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
if set_custom_nodepool_plan alibaba 'reserved-8c32g malformed-pool'; then
    fail 'malformed custom nodepool name must be rejected'
fi

# 真实 record_result 在 PASS 时曾返回条件表达式的 1，导致已成功解析的自定义规划被外层误判为非法并循环。
# 必须加载生产函数，不能再用总是返回 0 的 mock 掩盖返回码回归。
record_result_source="$test_tmp/k8sAvailCheck.record-result.functions.sh"
sed -n '/^record_result()/,/^}/p' "$SCRIPT" >"$record_result_source"
write_failure_artifact() { :; }
# shellcheck disable=SC1090
source "$record_result_source"
NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
if ! set_custom_nodepool_plan alibaba 'reserved-4c32g'; then
    fail 'valid custom nodepool plan must return success after recording PASS'
fi
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-4c32g' ]] || fail 'custom nodepool plan must remain selected after recording PASS'

NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
NODEPOOL_PLAN_LABEL=''
NODEPOOL_PLAN_SOURCE=''
RESULT_NAMES=()
RESULT_STATUS=()
RESULT_DETAIL=()
fallback_nodepool_plan alibaba '交互输入超时'
[[ "$NODEPOOL_PLAN_EFFECTIVE" == 'reserved-4c32g od-4c32g reserved-32c128g spot-32c128g' ]] || fail 'timeout fallback must retain the legacy Alibaba map'
[[ "$NODEPOOL_PLAN_SOURCE" == fallback ]] || fail 'timeout fallback must be marked as fallback'
[[ "${RESULT_NAMES[*]}|${RESULT_STATUS[*]}|${RESULT_DETAIL[*]}" == *'节点组业务规划|WARN|交互输入超时'* ]] || fail 'timeout fallback must record WARN'
require_text '1. Agent / 基础运营：reserved-4c32g od-4c32g'
require_text '5. 管理员自定义节点组'
require_text 'select_nodepool_business_plan "$cloud_platform"'
require_text 'NODEPOOL_PLAN_INPUT_TIMEOUT=300'
! grep -q '^NODEPOOL_PLAN_INPUT_TIMEOUT=30$' "$SCRIPT" || fail 'legacy 30-second nodepool timeout must not remain'

# 自动化/管道执行没有 TTY 时不得卡住，必须回退旧云 map 并登记 WARN。
NODEPOOL_PLAN_SELECTED=false
NODEPOOL_PLAN_EFFECTIVE=''
NODEPOOL_PLAN_SOURCE=''
select_nodepool_business_plan alibaba
[[ "$NODEPOOL_PLAN_SOURCE" == fallback ]] || fail 'non-interactive execution must fall back instead of waiting for input'

# 火山云现场会返回 milli-byte 形式的 memory Quantity；修复必须限定在火山云内存展示，
# 不能改变其他云、通用资源或 CPU 的现有格式化行为。
resource_format_source="$test_tmp/k8sAvailCheck.resource-format.functions.sh"
sed -n '/^format_resource()/,/^# ==================== 通用检查函数/p' "$SCRIPT" >"$resource_format_source"
# shellcheck disable=SC1090
source "$resource_format_source"
[[ "$(format_memory_for_platform volcengine 29258405314600m)" == '27.2Gi' ]] || fail 'Volcengine milli-byte memory must be displayed as GiB'
[[ "$(format_memory_for_platform google 29258405314600m)" == '29258405314.6C' ]] || fail 'non-Volcano memory formatting must retain the existing generic behavior'
[[ "$(format_resource 31240700Ki)" == '29.8Gi' ]] || fail 'standard Ki memory formatting must remain unchanged'
[[ "$(format_resource 33634467840)" == '31.3Gi' ]] || fail 'plain-byte memory formatting must remain unchanged'
[[ "$(format_cpu 3920m)" == '3.9C' ]] || fail 'CPU millicore formatting must remain unchanged'

# 扩容结论只能基于本轮探测前的节点池快照与最终就绪池之差；已有池、自建占位池不得误报0->1。
probe_scale_source="$test_tmp/k8sAvailCheck.probe-scale.functions.sh"
awk '/^_probe_newly_available_pools\(\)/ { capture=1 } capture && /^pod_deploy_check\(\)/ { exit } capture { print }' "$SCRIPT" >"$probe_scale_source"
# shellcheck disable=SC1090
source "$probe_scale_source"
[[ -z "$(_probe_newly_available_pools 'od-4c32g' 'od-4c32g')" ]] || fail 'an existing ready pool must not be reported as 0->1'
[[ "$(_probe_newly_available_pools '' 'od-4c32g')" == 'od-4c32g' ]] || fail 'a newly available pool must be reported as 0->1'
[[ "$(_probe_newly_available_pools 'reserved-4c32g' 'reserved-4c32g od-4c32g')" == 'od-4c32g' ]] || fail 'mixed existing/new pools must report only the new pool'
[[ -z "$(_probe_newly_available_pools '' 'default')" ]] || fail 'the self-managed default probe must never be reported as autoscaler 0->1'
[[ "$(_probe_success_detail 1 'od-4c32g' '')" != *'0节点'* ]] || fail 'success detail for an existing pool must not claim a 0->1 observation'
[[ "$(_probe_success_detail 1 'od-4c32g' 'od-4c32g')" == *'从0节点变为可调度:od-4c32g'* ]] || fail 'success detail must identify a pool newly made available during this run'

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
    *'get sc te-nfs'*'jsonpath='*)
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

curl() {
    local url="${*: -1}"
    [[ "$url" == *'/instance/network-interfaces/0/network' ]] || return 1
    [[ "${MOCK_GCE_METADATA_FAIL:-0}" != 1 ]] || return 22
    printf '%s' "${MOCK_GCE_NETWORK:-projects/test-project/networks/test-network}"
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

# GKE 缺失 te-nfs 时必须创建 Filestore Enterprise Multishare StorageClass。
RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
MOCK_TE_NFS_EXISTS=0
MOCK_APPLIED_MANIFEST="$test_tmp/google-te-nfs.yaml"
ARTIFACT_DIR="$test_tmp/google-artifacts"
LOG_FILE="$test_tmp/google.log"
MOCK_GCE_METADATA_FAIL=0
MOCK_GCE_NETWORK='projects/customer-host/networks/customer-vpc'
ensure_nfs_storageclass google || fail 'GKE should create the Filestore te-nfs StorageClass'
grep -qF 'provisioner: filestore.csi.storage.gke.io' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must use the Filestore CSI provisioner'
grep -qF 'tier: enterprise' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must use the Enterprise tier'
grep -qF 'multishare: "true"' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must enable multishare'
grep -qF 'instance-storageclass-label: te-nfs' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must retain the instance storageclass label'
grep -qF 'max-volume-size: "128Gi"' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must limit each Multishare PVC to 128Gi'
grep -qF 'network: "customer-vpc"' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must pass only the Metadata network name to Filestore'
! grep -qF 'network: "projects/customer-host/networks/customer-vpc"' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must not pass the Metadata resource path to Filestore'
! grep -qF 'name: te-nfs-128' "$MOCK_APPLIED_MANIFEST" || fail 'GKE must not create a te-nfs-128 StorageClass'
grep -qF 'reclaimPolicy: Retain' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must retain the user-selected reclaim policy'
grep -qF 'volumeBindingMode: Immediate' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must retain immediate binding'
grep -qF -- '- nolock' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must retain nolock mount option'
grep -qF -- '- hard' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must retain hard mount option'
grep -qF -- '- timeo=600' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must retain timeo mount option'
grep -qF -- '- retrans=3' "$MOCK_APPLIED_MANIFEST" || fail 'GKE te-nfs must retain retrans mount option'

# GCE Metadata 不可用时不得回退 default 或 apply；必须给出 Google Cloud Console 手工模版。
RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
MOCK_TE_NFS_EXISTS=0
MOCK_GCE_METADATA_FAIL=1
MOCK_APPLIED_MANIFEST="$test_tmp/google-te-nfs-metadata-fail.yaml"
ARTIFACT_DIR="$test_tmp/google-fail-artifacts"
LOG_FILE="$test_tmp/google-fail.log"
if ensure_nfs_storageclass google; then
    fail 'GKE must fail when Metadata does not provide a trusted network'
fi
[[ "${RESULT_STATUS[0]:-}" == FAIL ]] || fail 'GKE Metadata failure must record FAIL'
[[ ! -s "$MOCK_APPLIED_MANIFEST" ]] || fail 'GKE Metadata failure must not apply a StorageClass'
grep -qF 'Google Cloud控制台确认network信息' "$LOG_FILE" || fail 'GKE Metadata failure must direct the operator to Google Cloud Console'
grep -qF 'network: "<NETWORK_NAME>"' "$LOG_FILE" || fail 'GKE Metadata failure must print a Filestore-compatible manual network template'

# 华为不合规且仍被引用的 te-nfs 只能经明确确认替换同名 StorageClass；PV/PVC/Pod
# 只允许读取，绝不能成为删除目标。
HUAWEI_CCE_VPC_ID_RESOLVED='trusted-vpc'
MOCK_REPLACE_CALLS="$test_tmp/huawei-te-nfs-replace.calls"
: >"$MOCK_REPLACE_CALLS"
MOCK_REPLACE_SC_EXISTS=1
MOCK_REPLACE_APPLY_FAIL=0
MOCK_REPLACE_PROVISIONER='nfs-provisioner'
MOCK_REPLACE_VPC=''
REPLACE_LOG="$test_tmp/huawei-te-nfs-replace.log"
: >"$REPLACE_LOG"
log_error() { printf '%s\n' "$*" >>"$REPLACE_LOG"; }
kubectl() {
    local cmd="$*"
    printf '%s\n' "$cmd" >>"$MOCK_REPLACE_CALLS"
    if [[ "$cmd" == *provisioner* ]]; then
        [[ "$MOCK_REPLACE_SC_EXISTS" == 1 || -s "$test_tmp/huawei-te-nfs-replaced.yaml" ]] || return 1
        if [[ -s "$test_tmp/huawei-te-nfs-replaced.yaml" ]]; then
            printf '%s' everest-csi-provisioner
        else
            printf '%s' "$MOCK_REPLACE_PROVISIONER"
        fi
        return 0
    fi
    if [[ "$cmd" == *share-access-to* ]]; then
        [[ "$MOCK_REPLACE_SC_EXISTS" == 1 || -s "$test_tmp/huawei-te-nfs-replaced.yaml" ]] || return 1
        if [[ -s "$test_tmp/huawei-te-nfs-replaced.yaml" ]]; then
            printf '%s' trusted-vpc
        else
            printf '%s' "$MOCK_REPLACE_VPC"
        fi
        return 0
    fi
    case "$cmd" in
    "get pv -o jsonpath="*) printf 'pvc-legacy-nfs|te-agent/pvc-nfs-share|Bound\n' ;;
    "get sc te-nfs -o yaml") printf 'kind: StorageClass\nmetadata:\n  name: te-nfs\n' ;;
    "delete sc te-nfs") MOCK_REPLACE_SC_EXISTS=0 ;;
    "get pod storage-image -n debug -o jsonpath={.status.phase}") printf 'Pending' ;;
    "get pod storage-image -n debug -o jsonpath={.status.containerStatuses[0].state.waiting.reason}") printf 'ImagePullBackOff' ;;
    "apply -f -")
        cat >"$test_tmp/huawei-te-nfs-replaced.yaml"
        [[ "$MOCK_REPLACE_APPLY_FAIL" == 0 ]] || return 1
        MOCK_REPLACE_SC_EXISTS=1
        MOCK_REPLACE_PROVISIONER='everest-csi-provisioner'
        MOCK_REPLACE_VPC='trusted-vpc'
        ;;
    *) return 0 ;;
    esac
}
read_huawei_te_nfs_replacement_confirmation() { [[ "${MOCK_REPLACE_CONFIRM:-}" == yes ]]; }
forbid_text '$(read_huawei_te_nfs_replacement_confirmation)'

MOCK_REPLACE_CONFIRM=''
if huawei_te_nfs_replace_after_confirmation; then
    fail 'blank confirmation must not replace te-nfs'
fi
! grep -q '^delete sc te-nfs$' "$MOCK_REPLACE_CALLS" || fail 'blank confirmation must not delete te-nfs'

: >"$MOCK_REPLACE_CALLS"
MOCK_REPLACE_CONFIRM='yes'
huawei_te_nfs_replace_after_confirmation || fail 'exact yes must replace incompatible te-nfs'
grep -q '^delete sc te-nfs$' "$MOCK_REPLACE_CALLS" || fail 'confirmed replacement must delete only te-nfs StorageClass'
grep -q '^apply -f -$' "$MOCK_REPLACE_CALLS" || fail 'confirmed replacement must create standard te-nfs'
! grep -Eq '^delete (pv|pvc|pod) ' "$MOCK_REPLACE_CALLS" || fail 'te-nfs replacement must never delete PV PVC or Pod'
grep -qF 'provisioner: everest-csi-provisioner' "$test_tmp/huawei-te-nfs-replaced.yaml" || fail 'replacement must apply the Everest CCE template'

: >"$MOCK_REPLACE_CALLS"
MOCK_REPLACE_CONFIRM='yes'
MOCK_REPLACE_APPLY_FAIL=1
rm -f "$test_tmp/huawei-te-nfs-replaced.yaml"
if huawei_te_nfs_replace_after_confirmation; then
    fail 'failed te-nfs recreation must fail'
fi
grep -qF '手动恢复' "$REPLACE_LOG" || fail 'failed recreation must print manual restore guidance'
MOCK_REPLACE_APPLY_FAIL=0

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
sed -n '/^_parse_mysql_targets_from_file()/,/^# ==================== 混合部署: Pod -> 集群内 MySQL TCP 连通性/p' "$SCRIPT" >"$mysql_source"
log_warning() { MYSQL_WARNINGS="${MYSQL_WARNINGS:-}$*\n"; }
log_info() { MYSQL_INFOS="${MYSQL_INFOS:-}$*\n"; }
MYSQL_PROBE_TARGETS=()
# shellcheck disable=SC1090
source "$mysql_source"

APP_CONFIG_FILE="$test_tmp/base-application.yml"
LEGACY_APP_CONFIG_FILE="$test_tmp/etl-application.yml"
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
cat >"$LEGACY_APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    url: jdbc:mysql://legacy.mysql.example:3306/ta
EOF
MYSQL_WARNINGS=''
parse_mysql_targets || fail 'valid JDBC MySQL targets should parse'
[[ " ${MYSQL_PROBE_TARGETS[*]} " == *' primary.mysql.example:3306 '* ]] || fail 'hostname target must be retained'
[[ " ${MYSQL_PROBE_TARGETS[*]} " == *' 10.10.0.25:3306 '* ]] || fail 'IP target must retain default port'
[[ ${#MYSQL_PROBE_TARGETS[@]} -eq 2 ]] || fail 'same host and port must be deduplicated'
[[ " ${MYSQL_PROBE_TARGETS[*]} " != *' commented.mysql.example:3307 '* ]] || fail 'commented JDBC URL must be ignored'
[[ " ${MYSQL_PROBE_TARGETS[*]} " != *' legacy.mysql.example:3306 '* ]] || fail 'valid standard config must prevent legacy fallback'
[[ "$MYSQL_CONFIG_SELECTED" == "$APP_CONFIG_FILE" ]] || fail 'standard config must be recorded as selected'

# 标准文件含有效和损坏URL时，继续使用有效地址并告警，不得回退。
cat >"$APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    url: jdbc:mysql://primary.mysql.example:3306/ta
broken:
    url: jdbc:mysql:///missing-host
EOF
MYSQL_WARNINGS=''
parse_mysql_targets || fail 'valid JDBC target must remain usable alongside a malformed URL'
[[ "${MYSQL_PROBE_TARGETS[*]}" == 'primary.mysql.example:3306' ]] || fail 'mixed standard config must keep only its valid endpoint'
[[ "$MYSQL_WARNINGS" == *'无法解析'* ]] || fail 'malformed JDBC URL alongside valid target must warn'
[[ "$MYSQL_CONFIG_SELECTED" == "$APP_CONFIG_FILE" ]] || fail 'mixed standard config must not fall back to legacy'

# 标准文件无有效目标时，回退历史配置；相同host:port必须去重。
cat >"$APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    username: ta
EOF
cat >"$LEGACY_APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    url: jdbc:mysql://ta3:3306/ta?useSSL=false
hive:
  mysql:
    url: jdbc:mysql://ta3:3306/hive?useSSL=false
EOF
MYSQL_WARNINGS=''
parse_mysql_targets || fail 'standard config without a valid target must fall back to historical config'
[[ "${MYSQL_PROBE_TARGETS[*]}" == 'ta3:3306' ]] || fail 'historical spring/hive URLs on same endpoint must deduplicate'
[[ "$MYSQL_CONFIG_SELECTED" == "$LEGACY_APP_CONFIG_FILE" ]] || fail 'historical config must be recorded as selected'
[[ "$MYSQL_WARNINGS" == *'回退历史配置'* ]] || fail 'historical fallback must be disclosed'

# 标准文件不存在时也回退；两者均无有效目标时必须给出完整人工处理提示。
rm "$APP_CONFIG_FILE"
MYSQL_WARNINGS=''
parse_mysql_targets || fail 'missing standard config must fall back to historical config'
[[ "$MYSQL_CONFIG_SELECTED" == "$LEGACY_APP_CONFIG_FILE" ]] || fail 'missing standard config must select historical config'

cat >"$LEGACY_APP_CONFIG_FILE" <<'EOF'
spring:
  datasource:
    url: jdbc:mysql:///missing-host
EOF
MYSQL_WARNINGS=''
if parse_mysql_targets; then
    fail 'two configs without any valid endpoint must fail'
fi
[[ "$MYSQL_PARSE_ERROR" == *"$APP_CONFIG_FILE"* && "$MYSQL_PARSE_ERROR" == *"$LEGACY_APP_CONFIG_FILE"* ]] || fail 'final failure must name both attempted config paths'
[[ "$MYSQL_PARSE_ERROR" == *'自行测试MySQL地址'* ]] || fail 'final failure must instruct manual MySQL testing'

require_text 'parse_mysql_targets()'
require_text 'LEGACY_APP_CONFIG_FILE="/data/home/ta/data_etl_ta/application.yml"'
require_text 'for mysql_target in "${MYSQL_PROBE_TARGETS[@]}"'
require_text 'test_pod_to_mysql_connectivity "$mysql_target"'
require_text 'MYSQL_KUBECTL_EXEC_TIMEOUT'
require_text '_run_kubectl_exec_with_timeout()'
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
10.0.0.13 MixedCase.INTERNAL valid-on-mixed-line.internal bad_name bad..dots trailing- .leading trailing.
10.0.0.14 mixedcase.internal second-valid.internal
not-an-ip ignored.internal
EOF
long_host_label="$(printf 'a%.0s' {1..64})"
long_host_total="$(printf 'a%.0s' {1..63}).$(printf 'b%.0s' {1..63}).$(printf 'c%.0s' {1..63}).$(printf 'd%.0s' {1..62})"
printf '10.0.0.15 %s valid-with-long-label.internal\n' "$long_host_label" >>"$HOST_ALIAS_SOURCE_FILE"
printf '10.0.0.16 %s valid-with-long-total.internal\n' "$long_host_total" >>"$HOST_ALIAS_SOURCE_FILE"
: >"$HOST_ALIAS_WARNING_FILE"
probe_host_aliases=$(build_probe_host_aliases)
[[ "$probe_host_aliases" == *'ip: "10.0.0.10"'* ]] || fail 'valid executor hosts mapping must become a hostAlias'
[[ "$probe_host_aliases" == *'mysql.internal'* && "$probe_host_aliases" == *'api.internal'* && "$probe_host_aliases" == *'ip: "2001:db8::8"'* ]] || fail 'valid IPv4/IPv6 host mappings must be retained'
[[ "$probe_host_aliases" != *'localhost'* && "$probe_host_aliases" != *'loopback.internal'* && "$probe_host_aliases" != *'ip6-localhost'* ]] || fail 'localhost and loopback mappings must be filtered'
[[ "$probe_host_aliases" != *'k8sAvailCheck.sh'* && "$probe_host_aliases" != *'test_k8s_avail_check.sh'* ]] || fail 'glob-shaped hosts aliases must not expand into workspace filenames'
[[ "$probe_host_aliases" == *'ip: "10.0.0.11"'* && "$probe_host_aliases" == *'duplicate.internal'* ]] || fail 'conflicting hostname must retain non-conflicting aliases'
[[ $(grep -o 'mysql.internal' <<<"$probe_host_aliases" | wc -l) -eq 1 ]] || fail 'conflicting hostname must keep only its first mapping'
[[ "$probe_host_aliases" == *'mixedcase.internal'* && "$probe_host_aliases" != *'MixedCase.INTERNAL'* ]] || fail 'uppercase hostname must be normalized to lowercase'
[[ $(grep -o 'mixedcase.internal' <<<"$probe_host_aliases" | wc -l) -eq 1 ]] || fail 'case-folded cross-IP conflict must keep only the first mapping'
[[ "$probe_host_aliases" == *'valid-on-mixed-line.internal'* && "$probe_host_aliases" == *'second-valid.internal'* ]] || fail 'invalid aliases must not discard valid aliases on the same IP'
[[ "$probe_host_aliases" == *'valid-with-long-label.internal'* && "$probe_host_aliases" == *'valid-with-long-total.internal'* ]] || fail 'invalid long aliases must not discard valid siblings'
[[ "$probe_host_aliases" != *'bad_name'* && "$probe_host_aliases" != *'bad..dots'* && "$probe_host_aliases" != *'trailing-'* && "$probe_host_aliases" != *'.leading'* && "$probe_host_aliases" != *'trailing.'* ]] || fail 'RFC1123-invalid aliases must never enter hostAliases'
[[ "$probe_host_aliases" != *"$long_host_label"* && "$probe_host_aliases" != *"$long_host_total"* ]] || fail 'overlong RFC1123 label/subdomain must be discarded'
grep -qF 'mysql.internal' "$HOST_ALIAS_WARNING_FILE" || fail 'conflicting hostname must emit a warning'
grep -qF 'MixedCase.INTERNAL' "$HOST_ALIAS_WARNING_FILE" || fail 'uppercase normalization must be disclosed'
grep -qF 'bad_name' "$HOST_ALIAS_WARNING_FILE" || fail 'discarded illegal hostname must warn'
grep -qF "$long_host_label" "$HOST_ALIAS_WARNING_FILE" || fail 'discarded overlong label must warn'
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
grep -A1 -F 'valid-with-long-total.internal' "$probe_manifest" | grep -q '^      containers:' || fail 'last hostAlias hostname and containers must be separate YAML lines'
! grep -qF 'build_probe_host_aliases' "$probe_manifest" || fail 'probe Deployment manifest must not contain literal command substitution text'
_apply_probe_deployment 'np-probe-selector' 'spot' 'spot-32c128g' 'nginx:stable'
selector_manifest="$ARTIFACT_DIR/np-probe-selector.yaml"
grep -qF 'nodeSelector:' "$selector_manifest" || fail 'selector pool manifest must include nodeSelector'
grep -qF 'node.k8s.te/nodepool-name: "spot-32c128g"' "$selector_manifest" || fail 'selector pool manifest must target the requested node pool'
grep -q '^      nodeSelector:$' "$selector_manifest" || fail 'nodeSelector must be at template.spec indentation'
grep -q '^      hostAliases:$' "$selector_manifest" || fail 'hostAliases must be at template.spec indentation alongside nodeSelector'
# MySQL 探测必须以 curl 已连接到远端地址为准，不能等待 MySQL 主动关闭 telnet 会话。
require_text '%{remote_ip}'
require_text '%{remote_port}'
require_text '%{time_connect}'
forbid_text 'telnet://'
forbid_text '--connect-only'
forbid_text '/dev/tcp'
forbid_text 'command -v bash'
! grep -qF -- '-- sh -c command -v timeout' "$SCRIPT" || fail 'MySQL probe must not depend on timeout inside the container'

# curl 成功、缺失、DNS 与 TCP 失败均必须可被 MySQL 探测分类。生产实现需以这些 curl 退出码/输出为准。
mysql_curl_source="$test_tmp/k8sAvailCheck.mysql-curl.functions.sh"
sed -n '/^_run_kubectl_exec_with_timeout()/,/^# ==================== 混合部署: Pod -> MySQL 所在云主机延迟/p' "$SCRIPT" >"$mysql_curl_source"
log_step() { :; }
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }
# 测试替身：生产使用coreutils timeout；单测需在同一shell内继续调用mock kubectl函数。
timeout() {
    [[ "$1" == --signal=TERM ]] && shift
    shift
    "$@"
}
# shellcheck disable=SC1090
source "$mysql_curl_source"
POD_NAME=mysql-probe NAMESPACE=debug RUN_TS=test ARTIFACT_DIR="$test_tmp/mysql-curl-artifacts"
MYSQL_KUBECTL_EXEC_TIMEOUT=15
MYSQL_CURL_MODE=success
kubectl() {
    local cmd="$*"
    case "$cmd" in
    *'http://mysql.example.internal:3306/'*)
        case "$MYSQL_CURL_MODE" in
        success) printf 'remote_ip=10.0.0.12;remote_port=3306;time_connect=0.012\n'; return 0 ;;
        protocol) printf 'remote_ip=10.0.0.12;remote_port=3306;time_connect=0.012\n'; printf 'curl: (1) Received HTTP/0.9 when not allowed\n' >&2; return 1 ;;
        partial) printf 'remote_ip=10.0.0.12;remote_port=3306;time_connect=0.012\n'; printf 'curl: (28) Time-out\n' >&2; return 28 ;;
        zero) printf 'remote_ip=10.0.0.12;remote_port=3306;time_connect=0.000000\n'; return 1 ;;
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
connectivity_output=$(test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a 2>&1) || fail 'rc=28 with remote_ip must still pass connectivity'
[[ "$connectivity_output" != *'Time-out'* && "$connectivity_output" != *'command terminated'* ]] || fail 'partial curl stderr must not leak to connectivity output'
MYSQL_CURL_MODE=protocol
test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a || fail 'MySQL greeting reported as curl HTTP/0.9 error must still pass after TCP connect'
MYSQL_CURL_MODE=success
test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a || fail 'curl remote_ip success must pass MySQL connectivity'
MYSQL_CURL_MODE=zero
test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a || fail 'remote_ip with zero-rounded time_connect must pass connectivity'
for mysql_case in missing dns tcp; do
    MYSQL_CURL_MODE="$mysql_case"
    if test_pod_to_mysql_connectivity 'mysql.example.internal:3306' pool-a; then
        fail "curl ${mysql_case} failure must fail MySQL connectivity"
    fi
    case "$mysql_case" in
    missing) [[ "$MYSQL_PROBE_FAILURE_REASON" == *'缺少 curl'* ]] || fail 'missing curl must be classified as a probe-tool failure' ;;
    dns) [[ "$MYSQL_PROBE_FAILURE_REASON" == *'DNS'* ]] || fail 'curl DNS failure must be classified as DNS' ;;
    tcp) [[ "$MYSQL_PROBE_FAILURE_REASON" == *'TCP'* ]] || fail 'curl TCP failure must be classified as TCP' ;;
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
[[ "$MYSQL_PROBE_FAILURE_REASON" == 'curl 诊断复测已确认TCP连接成功' ]] || fail 'rc28 with remote_ip must classify as diagnostic reprobe success'
mysql_partial_artifact="$MYSQL_PROBE_DIAGNOSTIC_ARTIFACT"
grep -qF 'exit_code=28' "$mysql_partial_artifact" || fail 'diagnostic artifact must retain curl rc28'
grep -qF 'remote_ip=10.0.0.12' "$mysql_partial_artifact" || fail 'diagnostic artifact must retain connected remote IP'
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
    [[ "$cmd" == *'http://mysql.example.internal:3306/'* ]] && { printf 'remote_ip=10.0.0.12;remote_port=3306;time_connect=0.012\n'; printf 'curl: (1) Received HTTP/0.9 when not allowed\n' >&2; return 1; }
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
sed -n '/^_run_kubectl_exec_with_timeout()/,/^# ==================== 混合部署: Pod -> MySQL 所在云主机延迟/p' "$SCRIPT" >"$mysql_diagnostic_source"
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
    *'http://mysql.example.internal:3306/'*)
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
grep -qF "raw_curl_command=curl --noproxy '*' --connect-timeout 5 --max-time 5 --silent --show-error --output /dev/null --write-out 'remote_ip=%{remote_ip};remote_port=%{remote_port};time_connect=%{time_connect}' http://mysql.example.internal:3306/" "$mysql_diagnostic_artifact" || fail 'MySQL diagnostic artifact must retain the raw curl command'
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

# MySQL 连通且延迟达标时，实时输出必须说明节点池、目标和阈值，不能只在最终汇总中可见。
mysql_fail=0 lat_total=0 lat_fail=0
mysql_failed_pools='' lat_failed_pools='' lat_detail='' lat_skipped_detail=''
MYSQL_LATENCY_SUCCESS_LOG=''
test_pod_to_mysql_connectivity() { return 0; }
test_pod_to_host_latency() { HOST_LATENCY_LAST_MS=12; return 0; }
log_success() { MYSQL_LATENCY_SUCCESS_LOG="$*"; }
run_mysql_latency_gate 'reserved-4c32g' 'mysql.example.internal:3306'
[[ "$MYSQL_LATENCY_SUCCESS_LOG" == *'节点池[reserved-4c32g]'* ]] || fail 'passing latency must identify the ready node pool in realtime output'
[[ "$MYSQL_LATENCY_SUCCESS_LOG" == *'mysql.example.internal:3306'* ]] || fail 'passing latency must identify the target in realtime output'
[[ "$MYSQL_LATENCY_SUCCESS_LOG" == *'12ms'* && "$MYSQL_LATENCY_SUCCESS_LOG" == *"<${HOST_LATENCY_THRESHOLD_MS}ms"* ]] || fail 'passing latency must include measured value and threshold in realtime output'

# te-nfs 的业务 reclaimPolicy 保持 Retain；仅脚本临时 PVC 对应 PV 必须先切换 Delete，随后删除 PVC。
storage_cleanup_source="$test_tmp/k8sAvailCheck.storage-cleanup.functions.sh"
awk '/^_storage_e2e_cleanup\(\)/ { capture=1 } capture && /^_storage_e2e_capture_diagnostics\(\)/ { exit } capture { print }' "$SCRIPT" >"$storage_cleanup_source"
# shellcheck disable=SC1090
source "$storage_cleanup_source"
NAMESPACE='debug'
STORAGE_CLEANUP_CALLS="$test_tmp/storage-cleanup.calls"
: >"$STORAGE_CLEANUP_CALLS"
MOCK_STORAGE_PV_EXISTS=1
kubectl() {
    local cmd="$*"
    printf '%s\n' "$cmd" >>"$STORAGE_CLEANUP_CALLS"
    case "$cmd" in
    "get pvc te-csi-check-nfs-pvc -n debug -o jsonpath="*) printf 'pvc-temporary-nfs' ;;
    "patch pv pvc-temporary-nfs --type=merge -p "*) return 0 ;;
    "delete pvc te-csi-check-nfs-pvc -n debug --ignore-not-found") MOCK_STORAGE_PV_EXISTS=0 ;;
    "get pv pvc-temporary-nfs") [[ "$MOCK_STORAGE_PV_EXISTS" -eq 1 ]] ;;
    *) return 0 ;;
    esac
}
log_success() { :; }
log_error() { :; }
_storage_e2e_cleanup 'te-csi-check-nfs-pvc' 'te-csi-check-nfs-pod' || fail 'temporary storage cleanup must succeed after PV reclaim policy is switched'
grep -q '^patch pv pvc-temporary-nfs --type=merge -p ' "$STORAGE_CLEANUP_CALLS" || fail 'temporary test PV must be patched to Delete before PVC deletion'
patch_index=$(grep -n -m1 '^patch pv pvc-temporary-nfs ' "$STORAGE_CLEANUP_CALLS" | cut -d: -f1)
delete_index=$(grep -n -m1 '^delete pvc te-csi-check-nfs-pvc ' "$STORAGE_CLEANUP_CALLS" | cut -d: -f1)
(( patch_index < delete_index )) || fail 'temporary test PV must be patched before its PVC is deleted'

require_text '就绪节点池: ${ready_pools_display}'
require_text 'huawei_te_disk_before_gpssd2.yaml'
require_text '旧SC仍被业务PVC/PV使用，因此不会更新为GPSSD2'
require_text '已绑定卷和现有Pod不受影响'
require_text 'record_result "块存储StorageClass就绪检查" "PASS" "旧SC仍被业务PVC/PV使用，因此不会更新为GPSSD2；已绑定卷和现有Pod不受影响"'
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

# Kyverno 兼容性检查：Pod 名识别、镜像 tag 版本比较、解析失败兜底与重装失败提示。
kyverno_source="$test_tmp/k8sAvailCheck.kyverno.functions.sh"
awk '/^_kyverno_version_lt\(\)/ { capture=1 } capture && /^check_tencent_cloud_features\(\)/ { exit } capture { print }' "$SCRIPT" >"$kyverno_source"
# shellcheck disable=SC1090
source "$kyverno_source"

# Kyverno重装的自动执行与失败提示必须共用线上真实的单层ta-admin绝对路径。
fake_ta_admin="$test_tmp/ta-admin"
fake_ta_admin_calls="$test_tmp/ta-admin.calls"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"%s"\n' "$fake_ta_admin_calls" >"$fake_ta_admin"
chmod +x "$fake_ta_admin"
TA_ADMIN_BIN="$fake_ta_admin"
run_kyverno_reinstall
[[ "$(cat "$fake_ta_admin_calls")" == 'te_k8s install -name kyverno' ]] || fail 'Kyverno reinstall must invoke ta-admin with the exact install arguments'
TA_ADMIN_BIN='/data/app/.admin_manager_ta/ta-admin'

run_kyverno_case() {
    local server_version="$1" te_rows="$2" kube_rows="$3" query_fail_namespace="${4:-}" install_rc="${5:-0}"
    RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
    MOCK_KYVERNO_SERVER_VERSION="$server_version"
    MOCK_KYVERNO_TE_ROWS="$te_rows"
    MOCK_KYVERNO_KUBE_ROWS="$kube_rows"
    MOCK_KYVERNO_QUERY_FAIL_NAMESPACE="$query_fail_namespace"
    MOCK_KYVERNO_INSTALL_RC="$install_rc"
    KYVERNO_INSTALL_CALLS=0
    KYVERNO_LAST_ERROR=''
    kubectl() {
        local cmd="$*"
        case "$cmd" in
        "version -o json") printf '{"serverVersion":{"gitVersion":"%s"}}' "$MOCK_KYVERNO_SERVER_VERSION" ;;
        "get pods -n te-system -o jsonpath="*)
            [[ "$MOCK_KYVERNO_QUERY_FAIL_NAMESPACE" != te-system ]] || return 1
            printf '%b' "$MOCK_KYVERNO_TE_ROWS"
            ;;
        "get pods -n kube-system -o jsonpath="*)
            [[ "$MOCK_KYVERNO_QUERY_FAIL_NAMESPACE" != kube-system ]] || return 1
            printf '%b' "$MOCK_KYVERNO_KUBE_ROWS"
            ;;
        *) return 0 ;;
        esac
    }
    run_kyverno_reinstall() { ((KYVERNO_INSTALL_CALLS++)); return "$MOCK_KYVERNO_INSTALL_RC"; }
    log_step() { :; }
    log_info() { :; }
    log_success() { :; }
    log_warning() { :; }
    log_error() { KYVERNO_LAST_ERROR="$*"; }
    check_kyverno_compatibility
}

run_kyverno_case 'v1.35.6-gke.1' '' ''
[[ "${RESULT_STATUS[0]:-}" == SKIP ]] || fail 'Kyverno must skip when no Kyverno Pod exists'
[[ $KYVERNO_INSTALL_CALLS -eq 0 ]] || fail 'Kyverno absence must not invoke reinstall'

run_kyverno_case 'v1.33.9' $'kyverno-admission\tdocker.example/kyvernopre:v1.10.3\n' ''
[[ "${RESULT_STATUS[0]:-}" == PASS ]] || fail 'legacy Kyverno on Kubernetes below 1.34 must pass without reinstall'
[[ $KYVERNO_INSTALL_CALLS -eq 0 ]] || fail 'Kubernetes below 1.34 must not invoke reinstall'

run_kyverno_case 'v1.34.0' $'kyverno-admission\tdocker.example/kyvernopre:v1.18.0\n' $'kyverno-background\tdocker.example/kyverno-background-controller:v1.18.1\n'
[[ "${RESULT_STATUS[0]:-}" == PASS ]] || fail 'supported Kyverno versions must pass'
[[ $KYVERNO_INSTALL_CALLS -eq 0 ]] || fail 'supported Kyverno versions must not invoke reinstall'

run_kyverno_case 'v1.34.0' $'kyverno-admission\tdocker.example/kyvernopre:v1.10.3\n' ''
[[ "${RESULT_STATUS[0]:-}" == PASS ]] || fail 'successful Kyverno reinstall must pass the check'
[[ $KYVERNO_INSTALL_CALLS -eq 1 ]] || fail 'kyvernopre legacy image must invoke exactly one reinstall'

run_kyverno_case 'v1.34.0' $'kyverno-admission\tdocker.example/kyvernopre:stable\n' $'kyverno-background\tdocker.example/kyverno-background-controller:v1.18.1\n'
[[ $KYVERNO_INSTALL_CALLS -eq 1 ]] || fail 'an unparseable Kyverno image must invoke the fallback reinstall'

run_kyverno_case 'v1.34.0' $'kyverno-admission\tdocker.example/kyvernopre:v1.18.0-rc.1\n' ''
[[ $KYVERNO_INSTALL_CALLS -eq 1 ]] || fail 'a prerelease Kyverno image must invoke the stable-version fallback reinstall'

run_kyverno_case 'v1.34.0' $'kyverno-admission\tdocker.example/kyvernopre:v1.10.3\n' '' '' 9
[[ "${RESULT_STATUS[0]:-}" == FAIL ]] || fail 'failed Kyverno reinstall must record FAIL'
[[ "$KYVERNO_LAST_ERROR" == *'/data/app/.admin_manager_ta/ta-admin te_k8s install -name kyverno'* ]] || fail 'failed Kyverno reinstall must print the single-level ta-admin absolute path'
[[ "$KYVERNO_LAST_ERROR" != *'/ta-admin/ta-admin '* ]] || fail 'failed Kyverno reinstall must never print the duplicated ta-admin path'

run_kyverno_case 'v1.34.0' '' '' te-system
[[ "${RESULT_STATUS[0]:-}" == WARN ]] || fail 'failed Kyverno discovery must warn instead of reporting absence'


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

# 历史测试 PV 清理：只有精确命名、debug claim、Released、CSI 动态卷且 PVC 已不存在的候选可删除。
historical_cleanup_source="$test_tmp/k8sAvailCheck.historical-pv-cleanup.functions.sh"
awk '/^historical_test_pv_is_candidate\(\)/ { capture=1 } capture && /^_storage_e2e_cleanup\(\)/ { exit } capture { print }' "$SCRIPT" >"$historical_cleanup_source"
HISTORICAL_CLEANUP_CALLS="$test_tmp/historical-pv-cleanup.calls"
: >"$HISTORICAL_CLEANUP_CALLS"
HISTORICAL_TEST_PV_EXISTS=1
HISTORICAL_SERVERLESS_PV_EXISTS=1
HISTORICAL_TEST_PV_CONFIRM_TIMEOUT=30
HISTORICAL_TEST_PV_DELETE_TIMEOUT=60
RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
log_step() { :; }
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
record_result() {
    RESULT_NAMES+=("$1")
    RESULT_STATUS+=("$2")
    RESULT_DETAIL+=("${3:-}")
}
sleep() { :; }
kubectl() {
    local cmd="$*"
    printf '%s\n' "$cmd" >>"$HISTORICAL_CLEANUP_CALLS"
    case "$cmd" in
    "get pv -o jsonpath="*)
        [[ "$HISTORICAL_TEST_PV_EXISTS" == 1 ]] && printf 'test-debug-pv '
        [[ "$HISTORICAL_SERVERLESS_PV_EXISTS" == 1 ]] && printf 'serverless-released-pv '
        printf 'serverless-non-test-pv business-released-pv'
        ;;
    "get pv test-debug-pv -o jsonpath="*)
        [[ "$HISTORICAL_TEST_PV_EXISTS" == 1 ]] || return 1
        printf 'Released|debug|te-csi-check-nfs-pvc|te-nfs|nas.csi.everest.io|everest-csi-provisioner|volume-test'
        ;;
    "get pv business-released-pv -o jsonpath="*)
        printf 'Released|te-agent|home-sandbox-1-business|te-nfs|nas.csi.everest.io|everest-csi-provisioner|volume-business'
        ;;
    "get pv serverless-released-pv -o jsonpath="*)
        [[ "$HISTORICAL_SERVERLESS_PV_EXISTS" == 1 ]] || return 1
        printf 'Released|debug|sl-nfs-shared-2327932362-203509-3838|te-nfs|nas.csi.everest.io|everest-csi-provisioner|volume-serverless-test'
        ;;
    "get pv serverless-non-test-pv -o jsonpath="*)
        printf 'Released|debug|sl-nfs-business-data|te-nfs|nas.csi.everest.io|everest-csi-provisioner|volume-serverless-business'
        ;;
    "get sc te-nfs -o jsonpath="*) printf 'everest-csi-provisioner' ;;
    "get pvc te-csi-check-nfs-pvc -n debug") return 1 ;;
    "get pvc sl-nfs-shared-2327932362-203509-3838 -n debug") return 1 ;;
    "patch pv test-debug-pv --type=merge -p "*) return 0 ;;
    "delete pv test-debug-pv --ignore-not-found --wait=false") HISTORICAL_TEST_PV_EXISTS=0 ;;
    "patch pv serverless-released-pv --type=merge -p "*) return 0 ;;
    "delete pv serverless-released-pv --ignore-not-found --wait=false") HISTORICAL_SERVERLESS_PV_EXISTS=0 ;;
    "get pv test-debug-pv") [[ "$HISTORICAL_TEST_PV_EXISTS" == 1 ]] ;;
    "get pv serverless-released-pv") [[ "$HISTORICAL_SERVERLESS_PV_EXISTS" == 1 ]] ;;
    *) return 0 ;;
    esac
}
# shellcheck disable=SC1090
source "$historical_cleanup_source"
cleanup_historical_test_pvs || fail 'non-interactive historical cleanup should complete when only an exact test PV qualifies'
grep -q '^patch pv test-debug-pv ' "$HISTORICAL_CLEANUP_CALLS" || fail 'qualified historical test PV must be switched to Delete before deletion'
grep -q '^delete pv test-debug-pv ' "$HISTORICAL_CLEANUP_CALLS" || fail 'qualified historical test PV must be deleted'
grep -q '^patch pv serverless-released-pv ' "$HISTORICAL_CLEANUP_CALLS" || fail 'qualified Serverless historical test PV must be switched to Delete before deletion'
grep -q '^delete pv serverless-released-pv ' "$HISTORICAL_CLEANUP_CALLS" || fail 'qualified Serverless historical test PV must be deleted'
! grep -q 'patch pv business-released-pv\|delete pv business-released-pv\|patch pv serverless-non-test-pv\|delete pv serverless-non-test-pv' "$HISTORICAL_CLEANUP_CALLS" || fail 'Released business PVs and non-test Serverless names must never be cleaned'
[[ "${RESULT_STATUS[*]}" == *PASS* ]] || fail 'successful historical cleanup must record PASS'

require_text 'STORAGE_PV_RECLAIM_TIMEOUT="${STORAGE_PV_RECLAIM_TIMEOUT:-180}"'

echo 'PASS: availability-check regression assertions'
