#!/usr/bin/env bash
# Serverless Kubernetes deployment readiness check.
# This script deliberately validates scheduling-independent networking and storage only.

set -uo pipefail

RUN_TS="$(date +'%Y-%m-%d_%H%M%S')"
NAMESPACE="${NAMESPACE:-debug}"
PROBE_LABEL="serverless-avail-probe"
PROBE_NAME="serverless-avail-probe-${RUN_TS}"
DISK_PVC="serverless-avail-disk-${RUN_TS}"
NFS_PVC="serverless-avail-nfs-${RUN_TS}"
LOG_FILE="serverlessK8sAvailCheckResult_${RUN_TS}.log"
ARTIFACT_DIR="$(pwd)/serverlessK8sAvailCheckArtifacts_${RUN_TS}"
SERVERLESS_PROBE_IMAGE="${SERVERLESS_PROBE_IMAGE:-docker-ta.thinkingdata.cn/te/nginx:1.20}"
APP_CONFIG_FILE="${APP_CONFIG_FILE:-/data/home/ta/base_server_ta/application.yml}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-180}"
SCRIPT_COMPLETED=false

declare -a RESULT_ITEMS=()

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
record_result() { RESULT_ITEMS+=("$1|$2|$3"); log "[$2] $1: $3"; }

cleanup_on_exit() {
    local rc=$?
    kubectl delete deployment -n "$NAMESPACE" -l "app=${PROBE_LABEL}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete service -n "$NAMESPACE" -l "app=${PROBE_LABEL}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete pod -n "$NAMESPACE" -l "app=${PROBE_LABEL}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete pvc -n "$NAMESPACE" "$DISK_PVC" "$NFS_PVC" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    if ! $SCRIPT_COMPLETED; then
        log "脚本未正常完成，已请求清理临时探测资源。"
    fi
    exit "$rc"
}
trap cleanup_on_exit EXIT INT TERM

ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }

check_kubectl_connection() {
    if ! command -v kubectl >/dev/null 2>&1; then
        record_result "kubectl检查" "FAIL" "未找到 kubectl"
        return 1
    fi
    if kubectl version --request-timeout=15s >/dev/null 2>&1 && kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        record_result "K8S集群连通性检查" "PASS" "Kubernetes API 与命名空间 ${NAMESPACE} 可访问"
        return 0
    fi
    record_result "K8S集群连通性检查" "FAIL" "无法访问 Kubernetes API 或命名空间 ${NAMESPACE}"
    return 1
}

detect_cloud_platform() {
    local context cluster_info
    context="$(kubectl config current-context 2>/dev/null || true)"
    cluster_info="$(kubectl cluster-info 2>/dev/null || true)"
    case "${context} ${cluster_info}" in
        *tke*|*tencent*) CLOUD_PLATFORM="tencent" ;;
        *ack*|*alibaba*|*aliyun*) CLOUD_PLATFORM="alibaba" ;;
        *cce*|*huawei*) CLOUD_PLATFORM="huawei" ;;
        *eks*|*amazonaws*) CLOUD_PLATFORM="aws" ;;
        *gke*|*googleapis*) CLOUD_PLATFORM="google" ;;
        *vke*|*volc*) CLOUD_PLATFORM="volcengine" ;;
        *) CLOUD_PLATFORM="unknown" ;;
    esac
    record_result "K8S所属环境检查" "PASS" "识别到环境: ${CLOUD_PLATFORM}"
}

check_platform_features() {
    case "$CLOUD_PLATFORM" in
        tencent)
            if kubectl get deployment -A 2>/dev/null | grep -qi 'imc-operator'; then
                record_result "腾讯云平台特性检查" "PASS" "检测到 imc-operator"
            else
                record_result "腾讯云平台特性检查" "WARN" "未检测到 imc-operator，按实际业务需求确认"
            fi
            ;;
        aws)
            record_result "AWS平台特性检查" "SKIP" "Serverless 模式不执行节点组创建或检查流程"
            ;;
        *) record_result "平台特性检查" "SKIP" "${CLOUD_PLATFORM} 无额外 Serverless 平台检查项" ;;
    esac
}

wait_for_pod_ready() {
    local selector="$1" pod phase deadline=$((SECONDS + PROBE_TIMEOUT))
    while (( SECONDS < deadline )); do
        pod="$(kubectl get pod -n "$NAMESPACE" -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
        phase="$(kubectl get pod -n "$NAMESPACE" -l "$selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
        if [[ -n "$pod" ]] && kubectl get pod -n "$NAMESPACE" "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -qx true; then
            printf '%s' "$pod"
            return 0
        fi
        sleep 3
    done
    ensure_artifact_dir
    kubectl get pod -n "$NAMESPACE" -l "$selector" -o yaml >"$ARTIFACT_DIR/${selector//[=,]/_}-pods.yaml" 2>/dev/null || true
    [[ -n "${pod:-}" ]] && kubectl describe pod -n "$NAMESPACE" "$pod" >"$ARTIFACT_DIR/${pod}.describe.txt" 2>&1 || true
    log "等待探测 Pod 就绪超时（最后状态: ${phase:-未创建}）"
    return 1
}

apply_network_probe() {
    local manifest="$ARTIFACT_DIR/${PROBE_NAME}.yaml"
    ensure_artifact_dir
    cat >"$manifest" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROBE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: serverless-avail-probe
spec:
  replicas: 1
  selector:
    matchLabels:
      app: serverless-avail-probe
      probe: ${PROBE_NAME}
  template:
    metadata:
      labels:
        app: serverless-avail-probe
        probe: ${PROBE_NAME}
    spec:
      containers:
      - name: nginx-probe
        image: ${SERVERLESS_PROBE_IMAGE}
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 3
          periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: ${PROBE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: serverless-avail-probe
spec:
  type: ClusterIP
  selector:
    app: serverless-avail-probe
    probe: ${PROBE_NAME}
  ports:
  - port: 80
    targetPort: 80
EOF
    kubectl apply -f "$manifest" >/dev/null
}

check_network_readiness() {
    local pod service_host mysql_host target result
    if ! apply_network_probe || ! pod="$(wait_for_pod_ready "probe=${PROBE_NAME}")"; then
        record_result "Serverless Pod部署与网络探测" "FAIL" "无调度约束的探测 Pod 未就绪"
        return 1
    fi
    service_host="${PROBE_NAME}.${NAMESPACE}.svc"
    if kubectl exec -n "$NAMESPACE" "$pod" -- sh -c "wget -q -T 10 -O /dev/null http://${service_host}" >/dev/null 2>&1; then
        record_result "Pod访问集群Service网络" "PASS" "Pod 可访问 ClusterIP Service"
    else
        record_result "Pod访问集群Service网络" "FAIL" "Pod 无法访问 ClusterIP Service，详见物料目录"
    fi
    target="${SERVERLESS_NETWORK_TARGET:-}"
    if [[ -n "$target" ]]; then
        if kubectl exec -n "$NAMESPACE" "$pod" -- sh -c "wget -q -T 10 -O /dev/null http://${target}" >/dev/null 2>&1; then
            record_result "Pod访问指定业务地址网络" "PASS" "Pod 可访问 ${target}"
        else
            record_result "Pod访问指定业务地址网络" "FAIL" "Pod 无法访问 ${target}"
        fi
    else
        record_result "Pod访问指定业务地址网络" "SKIP" "未设置 SERVERLESS_NETWORK_TARGET"
    fi
    mysql_host="$(grep -E '^[[:space:]]*(url|jdbc-url):[[:space:]]*jdbc:mysql://' "$APP_CONFIG_FILE" 2>/dev/null | head -1 | sed -E 's#.*jdbc:mysql://([^/:?]+).*#\1#' || true)"
    if [[ -n "$mysql_host" ]]; then
        result="$(kubectl exec -n "$NAMESPACE" "$pod" -- sh -c "wget -T 10 -q -O /dev/null http://${mysql_host}:3306" 2>&1 || true)"
        if [[ -z "$result" ]]; then
            record_result "Pod访问MySQL网络" "PASS" "Pod 已建立到 ${mysql_host}:3306 的连接"
        else
            record_result "Pod访问MySQL网络" "WARN" "无法以 HTTP 探测 ${mysql_host}:3306；请用业务凭据复核 TCP 可达性"
        fi
    else
        record_result "Pod访问MySQL网络" "SKIP" "未从 ${APP_CONFIG_FILE} 发现 MySQL JDBC 地址"
    fi
}

ensure_storageclass() {
    local storage_class="$1"
    if kubectl get storageclass "$storage_class" >/dev/null 2>&1; then
        record_result "StorageClass就绪检查(${storage_class})" "PASS" "已发现 ${storage_class}"
        return 0
    fi
    record_result "StorageClass就绪检查(${storage_class})" "FAIL" "未发现指定 StorageClass ${storage_class}"
    return 1
}

verify_storage_e2e() {
    local storage_class="$1" access_mode="$2" pvc_name pod_name manifest marker
    case "$storage_class" in
        te-disk) pvc_name="$DISK_PVC" ;;
        te-nfs) pvc_name="$NFS_PVC" ;;
        *) return 1 ;;
    esac
    pod_name="${pvc_name}-pod"
    manifest="$ARTIFACT_DIR/${pvc_name}.yaml"
    marker="serverless-ready-${RUN_TS}"
    ensure_artifact_dir
    cat >"$manifest" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${NAMESPACE}
  labels:
    app: serverless-avail-probe
spec:
  accessModes:
  - ${access_mode}
  storageClassName: ${storage_class}
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${NAMESPACE}
  labels:
    app: serverless-avail-probe
    storage-probe: ${pvc_name}
spec:
  restartPolicy: Never
  containers:
  - name: storage-probe
    image: ${SERVERLESS_PROBE_IMAGE}
    command: ["sh", "-c", "echo ${marker} > /data/ready && test \"$(cat /data/ready)\" = \"${marker}\" && sleep 3600"]
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: ${pvc_name}
EOF
    if ! kubectl apply -f "$manifest" >/dev/null || ! wait_for_pod_ready "storage-probe=${pvc_name}"; then
        record_result "端到端存储验证(${storage_class}, ${access_mode})" "FAIL" "PVC 供给、挂载或 Pod 就绪失败"
        return 1
    fi
    if kubectl exec -n "$NAMESPACE" "$pod_name" -- cat /data/ready 2>/dev/null | grep -qx "$marker"; then
        record_result "端到端存储验证(${storage_class}, ${access_mode})" "PASS" "PVC 动态供给、挂载和读写成功"
        return 0
    fi
    record_result "端到端存储验证(${storage_class}, ${access_mode})" "FAIL" "挂载目录读写校验失败"
    return 1
}

print_summary() {
    local item name status detail
    log "========== Serverless K8S 可用性检查汇总 =========="
    for item in "${RESULT_ITEMS[@]}"; do
        IFS='|' read -r name status detail <<<"$item"
        log "${status}: ${name} - ${detail}"
    done
}

main() {
    log "Serverless K8S 可用性检查开始；日志: ${LOG_FILE}；物料: ${ARTIFACT_DIR}"
    if ! check_kubectl_connection; then
        print_summary
        return 1
    fi
    detect_cloud_platform
    check_platform_features
    check_network_readiness || true
    if ensure_storageclass te-disk; then
        verify_storage_e2e "te-disk" "ReadWriteOnce" || true
    fi
    if ensure_storageclass te-nfs; then
        verify_storage_e2e "te-nfs" "ReadWriteMany" || true
    fi
    print_summary
    SCRIPT_COMPLETED=true
}

main "$@"
