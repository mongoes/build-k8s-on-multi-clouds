#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT_DIR/k8sAvailCheck.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# 只抽取真实生产函数；外部 Kubernetes API 在 kubectl 边界做可观测替身。
FUNCTIONS="$TMP_DIR/functions.sh"
awk '/^ack_te_nfs_list_references\(\)/ { capture=1 } capture && /^ensure_nfs_storageclass\(\)/ { exit } capture { print }' "$SCRIPT" >"$FUNCTIONS"
if [[ ! -s "$FUNCTIONS" ]]; then
    echo "RED: ACK te-nfs volumeAs 审计/修复函数尚未实现"
    exit 1
fi
# shellcheck disable=SC1090
source "$FUNCTIONS"

ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR"
ACK_TE_NFS_CONFIRM_TIMEOUT=300
ACK_TE_NFS_EXPECTED_PROVISIONER=nasplugin.csi.alibabacloud.com
ACK_TE_NFS_REBUILT=false
ACK_TE_NFS_REFERENCES=''
ACK_TE_NFS_CONFIRM_OUTPUT_PATH=/dev/null
LOG=''
log_info() { LOG+="INFO:$*\n"; }
log_warning() { LOG+="WARN:$*\n"; }
log_error() { LOG+="ERROR:$*\n"; }
log_success() { LOG+="PASS:$*\n"; }

SC_VOLUME_AS=subpath
SC_PROVISIONER=nasplugin.csi.alibabacloud.com
SC_SERVER='nas.example.com:/te-nfs'
SC_UID=uid-1
SC_RV=rv-1
DELETE_COUNT=0
APPLY_COUNT=0
APPLIED_FILE="$TMP_DIR/applied.json"

kubectl() {
    case "$*" in
    "get sc te-nfs -o jsonpath={.parameters.volumeAs}") printf '%s' "$SC_VOLUME_AS" ;;
    "get sc te-nfs -o jsonpath={.provisioner}") printf '%s' "$SC_PROVISIONER" ;;
    "get sc te-nfs -o jsonpath={.parameters.server}") printf '%s' "$SC_SERVER" ;;
    "get sc te-nfs -o jsonpath={.metadata.uid}") printf '%s' "$SC_UID" ;;
    "get sc te-nfs -o jsonpath={.metadata.resourceVersion}") printf '%s' "$SC_RV" ;;
    "get sc te-nfs -o json")
        printf '{"apiVersion":"storage.k8s.io/v1","kind":"StorageClass","metadata":{"name":"te-nfs","uid":"%s","resourceVersion":"%s","creationTimestamp":"2026-01-01T00:00:00Z","annotations":{"kubectl.kubernetes.io/last-applied-configuration":"stale","keep":"yes"}},"mountOptions":["nolock,tcp,noresvport","vers=3"],"parameters":{"server":"%s","volumeAs":"%s"},"provisioner":"%s","reclaimPolicy":"Retain","volumeBindingMode":"Immediate"}\n' "$SC_UID" "$SC_RV" "$SC_SERVER" "$SC_VOLUME_AS" "$SC_PROVISIONER"
        ;;
    "get pv -o json") printf '{"items":[]}' ;;
    "delete sc te-nfs") DELETE_COUNT=$((DELETE_COUNT + 1)) ;;
    "apply -f "*)
        APPLY_COUNT=$((APPLY_COUNT + 1))
        cp "${*: -1}" "$APPLIED_FILE"
        SC_VOLUME_AS=$(jq -r '.parameters.volumeAs' "$APPLIED_FILE")
        ;;
    *) fail "unexpected kubectl call: kubectl $*" ;;
    esac
}

# 回归点：合规SC必须是纯读路径，不能因为审计而重建。
ack_te_nfs_audit_and_repair || fail 'subpath SC should pass'
[[ $DELETE_COUNT -eq 0 && $APPLY_COUNT -eq 0 ]] || fail 'compliant SC must perform zero writes'

# 回归点：风险SC在管理员拒绝时必须失败且零写入。
SC_VOLUME_AS=sharepath
printf 'n\n' >"$TMP_DIR/no"
ACK_TE_NFS_CONFIRM_INPUT_PATH="$TMP_DIR/no"
LOG=''
rc=0
ack_te_nfs_audit_and_repair || rc=$?
[[ $rc -ne 0 ]] || fail 'sharepath rejection must fail the SC gate'
[[ $DELETE_COUNT -eq 0 && $APPLY_COUNT -eq 0 ]] || fail 'rejection must perform zero writes'
[[ "$LOG" == *'写入覆盖'* ]] || fail 'risk warning must explain overwrite risk'

# 回归点：未知provisioner不能套用ACK NAS模板，即使管理员输入Y也不得写。
SC_PROVISIONER=unknown.csi.example.com
printf 'y\n' >"$TMP_DIR/yes"
ACK_TE_NFS_CONFIRM_INPUT_PATH="$TMP_DIR/yes"
rc=0
ack_te_nfs_audit_and_repair || rc=$?
[[ $rc -ne 0 ]] || fail 'unknown provisioner must be blocked'
[[ $DELETE_COUNT -eq 0 && $APPLY_COUNT -eq 0 ]] || fail 'unknown provisioner must perform zero writes'

# 回归点：确认修复只能改变volumeAs，同时保留server、挂载参数和业务注解。
SC_PROVISIONER=nasplugin.csi.alibabacloud.com
SC_VOLUME_AS=sharepath
ACK_TE_NFS_CONFIRM_INPUT_PATH="$TMP_DIR/yes"
ack_te_nfs_audit_and_repair || fail 'confirmed repair should pass readback'
[[ $DELETE_COUNT -eq 1 && $APPLY_COUNT -eq 1 ]] || fail 'confirmed repair must rebuild exactly once'
[[ "$(jq -r '.parameters.volumeAs' "$APPLIED_FILE")" == subpath ]] || fail 'repair must set volumeAs=subpath'
[[ "$(jq -r '.parameters.server' "$APPLIED_FILE")" == "$SC_SERVER" ]] || fail 'repair must preserve NAS server'
[[ "$(jq -r '.metadata.annotations.keep' "$APPLIED_FILE")" == yes ]] || fail 'repair must preserve valid annotations'
[[ "$(jq -r '.metadata.uid // empty' "$APPLIED_FILE")" == '' ]] || fail 'repair manifest must remove UID'
[[ -f "$ARTIFACT_DIR/ack_te_nfs_before_rebuild.yaml" ]] || fail 'repair must retain a recovery artifact'

# 回归点：SC字段合规仍不够；双PVC若能看到彼此文件，专项验证必须失败。
ISO_FUNCTION="$TMP_DIR/isolation-function.sh"
awk '/^verify_ack_te_nfs_pvc_isolation\(\)/ { capture=1 } capture && /^verify_nfs_rwx_cross_node\(\)/ { exit } capture { print }' "$SCRIPT" >"$ISO_FUNCTION"
(
    # shellcheck disable=SC1090
    source "$ISO_FUNCTION"
    NAMESPACE=debug
    ARTIFACT_DIR="$TMP_DIR/isolation-artifacts"
    PROBE_ID_SUFFIX=unit-1
    PROBE_RUN_LABEL=unit-run
    RUN_TS=unit
    E2E_PVC_SIZE=1Gi
    NGINX_IMAGE=example/nginx:test
    RANDOM=7
    SHARED_MODE=true
    ISO_LOG=''
    CLEANUPS=0
    log_step() { :; }
    log_success() { :; }
    log_error() { ISO_LOG+="$*\n"; }
    ensure_namespace() { :; }
    _ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }
    _apply_csi_check_pod() { return 0; }
    _wait_for_storage_pod() { return 0; }
    _storage_e2e_capture_diagnostics() { :; }
    _storage_e2e_cleanup() { CLEANUPS=$((CLEANUPS + 1)); return 0; }
    kubectl() {
        case "$*" in
        "get pvc ack-nfs-iso-a-unit-1 -n debug"|"get pvc ack-nfs-iso-b-unit-1 -n debug") return 1 ;;
        create\ -f\ *) return 0 ;;
        "get pvc ack-nfs-iso-a-unit-1 -n debug -o jsonpath={.spec.volumeName}") printf 'pv-a' ;;
        "get pvc ack-nfs-iso-b-unit-1 -n debug -o jsonpath={.spec.volumeName}") printf 'pv-b' ;;
        *"exec ack-nfs-iso-b-unit-1"*"test ! -e /data/.ack-nfs-isolation-a"*)
            $SHARED_MODE && return 1 || return 0
            ;;
        exec\ *) return 0 ;;
        *) fail "unexpected isolation kubectl call: kubectl $*" ;;
        esac
    }
    rc=0
    verify_ack_te_nfs_pvc_isolation || rc=$?
    [[ $rc -ne 0 ]] || fail 'shared PVC directories must fail isolation verification'
    [[ "$ISO_LOG" == *'写入覆盖风险'* ]] || fail 'shared-directory failure must explain overwrite risk'
    [[ $CLEANUPS -eq 2 ]] || fail 'failed isolation verification must clean both run-owned PVCs'

    SHARED_MODE=false
    ISO_LOG=''
    CLEANUPS=0
    verify_ack_te_nfs_pvc_isolation || fail 'isolated PVC directories should pass'
    [[ $CLEANUPS -eq 2 ]] || fail 'successful isolation verification must clean both run-owned PVCs'
)

# 回归点：独立入口必须在公共连通性检查后直接进入ACK SC专项，不能执行Kyverno、节点或网络检查。
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
    checkUser() { TRACE+=' kubectl-user'; }
    install_kubectl() { TRACE+=' kubectl-check'; }
    test_k8s_connection() { TRACE+=' connection'; }
    detect_cloud_platform() { printf 'alibaba\n'; }
    ensure_namespace() { TRACE+=' namespace'; }
    ensure_nfs_storageclass() { TRACE+=' sc-audit'; return 0; }
    verify_ack_te_nfs_pvc_isolation() { TRACE+=' isolation'; return 0; }
    check_kyverno_compatibility() { fail 'standalone mode must skip Kyverno'; }
    detect_serverless_mode() { fail 'standalone mode must skip service-mode detection'; }
    select_nodepool_business_plan() { fail 'standalone mode must skip nodepool planning'; }
    print_summary() { TRACE+=' summary'; }
    record_result() { :; }
    main --ack-te-nfs-check >/dev/null 2>&1
    [[ "$TRACE" == *'kubectl-check'*connection*namespace*sc-audit*isolation*summary* ]] || fail "standalone mode missed required focused step: $TRACE"
)

echo 'PASS: ACK te-nfs volumeAs audit and repair behavior'
