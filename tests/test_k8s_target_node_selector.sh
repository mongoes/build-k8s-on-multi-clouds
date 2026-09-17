#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT_DIR/k8sAvailCheck.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 生产函数必须是独立边界；测试真实选择/判定逻辑，只替换外部kubectl API。
FUNCTIONS="$TMP_DIR/target-functions.sh"
awk '/^target_node_selector_validate\(\)/ { capture=1 } capture && /^get_gce_primary_network\(\)/ { exit } capture { print }' "$SCRIPT" >"$FUNCTIONS"
if [[ ! -s "$FUNCTIONS" ]]; then
    echo 'RED: target node-selector focused check is not implemented'
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNCTIONS"

NAMESPACE=debug
ARTIFACT_DIR="$TMP_DIR/artifacts"
PROBE_RUN_LABEL=unit-target-run
PROBE_ID_SUFFIX=unit-1
NGINX_IMAGE=example.invalid/nginx:test
TARGET_NODE_SELECTOR_PROBE_POD=''
TARGET_NODE_SELECTOR='node.k8s.te/nodepool-name=reserved-64c256g,kubernetes.io/arch=amd64'
TARGET_LOG=''
CREATE_COUNT=0
DELETE_COUNT=0
NODE_JSON_MODE=ready
mkdir -p "$ARTIFACT_DIR"

log_step() { :; }
log_info() { TARGET_LOG+="INFO:$*\n"; }
log_warning() { TARGET_LOG+="WARN:$*\n"; }
log_error() { TARGET_LOG+="ERROR:$*\n"; }
log_success() { TARGET_LOG+="PASS:$*\n"; }
ensure_namespace() { :; }
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }

kubectl() {
    case "$*" in
    "get nodes -l $TARGET_NODE_SELECTOR -o json")
        case "$NODE_JSON_MODE" in
        empty) printf '{"apiVersion":"v1","items":[]}' ;;
        ready)
            printf '%s' '{"apiVersion":"v1","items":[
              {"metadata":{"name":"node-a","labels":{"node.k8s.te/nodepool-name":"reserved-64c256g","node.k8s.te/billing-mode":"reserved","kubernetes.io/arch":"amd64"}},"spec":{"unschedulable":false,"taints":[]},"status":{"capacity":{"cpu":"64","memory":"263882000Ki","ephemeral-storage":"100Gi"},"allocatable":{"cpu":"63500m","memory":"258000000Ki","ephemeral-storage":"95Gi"},"conditions":[{"type":"Ready","status":"True"}]}},
              {"metadata":{"name":"node-b","labels":{"node.k8s.te/nodepool-name":"reserved-64c256g","node.k8s.te/billing-mode":"reserved","kubernetes.io/arch":"amd64"}},"spec":{"unschedulable":false,"taints":[]},"status":{"capacity":{"cpu":"64","memory":"263882000Ki","ephemeral-storage":"100Gi"},"allocatable":{"cpu":"63500m","memory":"258000000Ki","ephemeral-storage":"95Gi"},"conditions":[{"type":"Ready","status":"True"}]}}
            ]}'
            ;;
        notready)
            printf '%s' '{"apiVersion":"v1","items":[{"metadata":{"name":"node-a","labels":{"node.k8s.te/nodepool-name":"reserved-64c256g","node.k8s.te/billing-mode":"reserved","kubernetes.io/arch":"amd64"}},"spec":{"unschedulable":false,"taints":[]},"status":{"capacity":{"cpu":"64","memory":"263882000Ki"},"allocatable":{"cpu":"63500m","memory":"258000000Ki"},"conditions":[{"type":"Ready","status":"False"}]}}]}'
            ;;
        esac
        ;;
    create\ -f\ *) CREATE_COUNT=$((CREATE_COUNT + 1)); return 0 ;;
    "get pod target-node-selector-unit-1 -n debug") return 1 ;;
    "get pod target-node-selector-unit-1 -n debug -o jsonpath={.status.containerStatuses[0].ready}") printf 'true' ;;
    "get pod target-node-selector-unit-1 -n debug -o jsonpath={.spec.nodeName}") printf 'node-a' ;;
    "get pod target-node-selector-unit-1 -n debug -o jsonpath={.metadata.labels.probe-run}") printf '%s' "$PROBE_RUN_LABEL" ;;
    "delete pod target-node-selector-unit-1 -n debug --ignore-not-found --wait=false") DELETE_COUNT=$((DELETE_COUNT + 1)); return 0 ;;
    *) fail "unexpected kubectl call: kubectl $*" ;;
    esac
}

# 非法/扩展selector语法不能生成错误nodeSelector，也不得产生写请求。
rc=0
target_node_selector_validate 'node.k8s.te/nodepool-name in (pool-a,pool-b)' || rc=$?
[[ $rc -ne 0 ]] || fail 'set-based selector must be rejected by exact-match focused mode'
[[ $CREATE_COUNT -eq 0 ]] || fail 'invalid selector must perform zero writes'

# 零命中是目标声明错误，必须在创建Pod前失败。
NODE_JSON_MODE=empty
rc=0
run_target_node_selector_check "$TARGET_NODE_SELECTOR" || rc=$?
[[ $rc -ne 0 ]] || fail 'zero matching nodes must fail'
[[ $CREATE_COUNT -eq 0 ]] || fail 'zero matching nodes must not create a probe'

# 命中节点中任一NotReady时，不得用一个成功Pod遮蔽节点级失败。
NODE_JSON_MODE=notready
rc=0
run_target_node_selector_check "$TARGET_NODE_SELECTOR" || rc=$?
[[ $rc -ne 0 ]] || fail 'a NotReady target node must fail the focused check'
[[ $CREATE_COUNT -eq 0 ]] || fail 'NotReady target set must not create a probe'

# 全部节点合规后，只创建一个定向Pod并回读其实际节点，随后精确清理。
NODE_JSON_MODE=ready
TARGET_LOG=''
run_target_node_selector_check "$TARGET_NODE_SELECTOR" || fail 'ready matching nodes and scheduled probe must pass'
[[ $CREATE_COUNT -eq 1 && $DELETE_COUNT -eq 1 ]] || fail 'focused check must create and delete exactly one run-owned probe'
[[ "$TARGET_LOG" == *'命中节点数=2'* ]] || fail 'summary must disclose actual matched count without enforcing an expected count'
[[ "$TARGET_LOG" == *'实际调度节点=node-a'* ]] || fail 'probe success must disclose the actual scheduled target node'

# 分流回归：专项参数走新分支；无参入口保持旧分支，不能调用专项函数。
MODE_LIB="$TMP_DIR/mode-lib.sh"
sed '/^trap .*cleanup_on_exit EXIT/,$d' "$SCRIPT" >"$MODE_LIB"
sed -i.bak '/^declare -gA PROBE_POD_NAME PROBE_POD_IP$/d' "$MODE_LIB"
(
    # shellcheck disable=SC1090
    source "$MODE_LIB"
    TRACE=''
    log_info() { :; }
    log_warning() { :; }
    log_error() { :; }
    log_success() { :; }
    log_step() { :; }
    checkUser() { :; }
    install_kubectl() { :; }
    test_k8s_connection() { :; }
    detect_cloud_platform() { printf 'alibaba\n'; }
    ensure_namespace() { :; }
    record_result() { :; }
    print_summary() { TRACE+=' summary'; }
    run_target_node_selector_check() { TRACE+=" targeted:$1"; return 0; }
    check_kyverno_compatibility() { TRACE+=' legacy-kyverno'; }
    detect_serverless_mode() { TRACE+=' legacy-mode'; SERVERLESS_MODE=Serverless; return 0; }
    print_mode_specific_plan() { :; }
    run_serverless_checks_inline() { TRACE+=' legacy-run'; }
    finalize_availability_check() { TRACE+=' legacy-finalize'; }

    main --node-selector "$TARGET_NODE_SELECTOR" >/dev/null 2>&1
    [[ "$TRACE" == *"targeted:$TARGET_NODE_SELECTOR"*summary* ]] || fail "targeted dispatcher did not use focused path: $TRACE"
    [[ "$TRACE" != *legacy-* ]] || fail "targeted dispatcher leaked into legacy path: $TRACE"

    TRACE=''
    main >/dev/null 2>&1
    [[ "$TRACE" == *legacy-kyverno*legacy-mode*legacy-run*legacy-finalize* ]] || fail "legacy path was changed by focused-mode dispatch: $TRACE"
    [[ "$TRACE" != *targeted:* ]] || fail 'unparameterized legacy path must never call focused checker'
)

echo 'PASS: target node-selector focused-check behavior'
