#!/usr/bin/env bash
# Serverless Kubernetes deployment readiness check.
# This script deliberately validates scheduling-independent networking and storage only.

set -uo pipefail

RUN_TS="$(date +'%Y-%m-%d_%H%M%S')"
PROBE_ID_SUFFIX="$(date +'%H%M%S')-$$"
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
declare -a SERVERLESS_DOMAINS=()
declare -a READY_SERVERLESS_DOMAINS=()
CLOUD_PLATFORM="unknown"
CLUSTER_MODE="Unknown"
STANDARD_NODE_COUNT=0

# Kubernetes object names and label values must be RFC1123 and no longer than 63
# characters.  Virtual-node names can already be long, so never embed them directly.
make_probe_id() {
    local kind="$1" scope="$2" kind_safe scope_hash suffix
    kind_safe="$(printf '%s' "$kind" | tr -c 'a-z0-9-' '-')"
    scope_hash="$(printf '%s' "$scope" | cksum | awk '{print $1}')"
    suffix="${PROBE_ID_SUFFIX:-$(date +'%H%M%S')-$$}"
    printf 'sl-%s-%s-%s\n' "$kind_safe" "$scope_hash" "$suffix"
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }
record_result() { RESULT_ITEMS+=("$1|$2|$3"); log "[$2] $1: $3"; }

cleanup_on_exit() {
    local rc=$?
    kubectl delete deployment -n "$NAMESPACE" -l "app=${PROBE_LABEL}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete service -n "$NAMESPACE" -l "app=${PROBE_LABEL}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete pod -n "$NAMESPACE" -l "app=${PROBE_LABEL}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete pvc -n "$NAMESPACE" -l "app=${PROBE_LABEL}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
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

detect_cluster_mode() {
    local node meta tencent_zone tencent_nodes=0 alibaba_nodes=0 version sc_data tencent_signals=0 alibaba_signals=0
    local nodes
    SERVERLESS_DOMAINS=()
    STANDARD_NODE_COUNT=0
    nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || nodes=""
    [[ -n "$nodes" ]] || { record_result "K8S模式识别" "FAIL" "未发现Node，无法安全识别Standard/Serverless模式"; return 1; }
    for node in $nodes; do
        meta=$(kubectl get node "$node" -o yaml 2>/dev/null) || { record_result "K8S模式识别" "FAIL" "无法读取Node ${node} 元数据"; return 1; }
        if grep -qE 'node.kubernetes.io/instance-type: eklet|eks.tke.cloud.tencent.com/' <<<"$meta"; then
            ((tencent_nodes++))
            tencent_zone=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.eks\.tke\.cloud\.tencent\.com/zone-name}' 2>/dev/null)
            [[ -n "$tencent_zone" ]] || tencent_zone=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)
            SERVERLESS_DOMAINS+=("${node}|tencent|${tencent_zone}|$(kubectl get node "$node" -o jsonpath='{.metadata.labels.eks\.tke\.cloud\.tencent\.com/subnet-id}' 2>/dev/null)|eks.tke.cloud.tencent.com/eklet")
        elif grep -q 'type: virtual-kubelet' <<<"$meta" && grep -qE 'alibabacloud.com/|service.alibabacloud.com/|vk.alpha.alibabacloud.com/' <<<"$meta"; then
            ((alibaba_nodes++))
            SERVERLESS_DOMAINS+=("${node}|alibaba|$(kubectl get node "$node" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null)||virtual-kubelet.io/provider")
        else
            ((STANDARD_NODE_COUNT++))
        fi
    done
    if (( tencent_nodes > 0 && alibaba_nodes > 0 )); then
        record_result "K8S模式识别" "FAIL" "同时发现腾讯EKlet与阿里Virtual Kubelet强指纹，拒绝猜测"
        return 1
    fi
    if (( tencent_nodes > 0 )); then CLOUD_PLATFORM=tencent; elif (( alibaba_nodes > 0 )); then CLOUD_PLATFORM=alibaba; else
        version=$(kubectl version -o json 2>/dev/null || true); sc_data=$(kubectl get storageclass -o yaml 2>/dev/null || true)
        [[ "$version" == *aliyun* ]] && ((alibaba_signals++)); [[ "$sc_data" == *alibabacloud.com* ]] && ((alibaba_signals++))
        [[ "$version" == *tke* || "$version" == *tencent* ]] && ((tencent_signals++)); [[ "$sc_data" == *tencent.cloud* ]] && ((tencent_signals++))
        if (( alibaba_signals >= 2 && tencent_signals == 0 )); then CLOUD_PLATFORM=alibaba
        elif (( tencent_signals >= 2 && alibaba_signals == 0 )); then CLOUD_PLATFORM=tencent
        else record_result "K8S模式识别" "FAIL" "标准节点集群缺少一致的阿里/腾讯双重证据，拒绝猜测"; return 1; fi
    fi
    if (( ${#SERVERLESS_DOMAINS[@]} == 0 )); then CLUSTER_MODE="Standard"
    elif (( STANDARD_NODE_COUNT == 0 )); then CLUSTER_MODE="Serverless"
    else CLUSTER_MODE="Hybrid"; fi
    record_result "K8S模式识别" "PASS" "${CLOUD_PLATFORM}/${CLUSTER_MODE}; Serverless调度域:${#SERVERLESS_DOMAINS[@]}; 标准节点:${STANDARD_NODE_COUNT}"
}

discover_serverless_domains() { printf '%s\n' "${SERVERLESS_DOMAINS[@]}"; }

check_serverless_domain_health() {
    local record="$1" node vendor zone subnet taint state ready network unsched ips
    IFS='|' read -r node vendor zone subnet taint <<<"$record"
    state=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}|{.status.conditions[?(@.type=="NetworkUnavailable")].status}|{.spec.unschedulable}' 2>/dev/null)
    IFS='|' read -r ready network unsched <<<"$state"
    [[ "$ready" == True && "$network" == False && "$unsched" != true ]] || { record_result "Serverless调度域(${node})" "FAIL" "Ready/网络/Cordon门槛未通过"; return 1; }
    if [[ "$vendor" == tencent ]]; then
        ips=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.eks\.tke\.cloud\.tencent\.com/available-ip-count}' 2>/dev/null)
        [[ "$ips" =~ ^[1-9][0-9]*$ ]] || { record_result "Serverless调度域(${node})" "FAIL" "腾讯EKlet子网可用IP不足或缺失: ${ips:-空}"; return 1; }
    fi
    record_result "Serverless调度域(${node})" "PASS" "zone=${zone:-未知}; subnet=${subnet:-不适用}; 调度前置通过"
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

probe_clusterip_service() {
    local pod="$1" service_host="$2"
    kubectl exec -n "$NAMESPACE" "$pod" -- sh -c '
if command -v wget >/dev/null 2>&1; then
    exec wget -S -T 10 -O /dev/null "$1"
elif command -v curl >/dev/null 2>&1; then
    exec curl -fsS --connect-timeout 10 -o /dev/null "$1"
fi
printf "PROBE_CLIENT_MISSING: neither wget nor curl exists in probe image\\n" >&2
exit 127
' sh "http://${service_host}"
}

capture_clusterip_diagnostics() {
    local pod="$1" service_host="$2" probe_output="$3" diagnostic_file
    ensure_artifact_dir
    diagnostic_file="$ARTIFACT_DIR/clusterip-${PROBE_NAME}.diagnostics.txt"
    {
        printf '=== ClusterIP probe target ===\n%s\n\n' "$service_host"
        printf '=== Probe command output ===\n%s\n\n' "$probe_output"
        printf '=== Service ===\n'
        kubectl get service -n "$NAMESPACE" "$PROBE_NAME" -o yaml 2>&1
        printf '\n=== EndpointSlice ===\n'
        kubectl get endpointslice -n "$NAMESPACE" -l "kubernetes.io/service-name=${PROBE_NAME}" -o yaml 2>&1
        printf '\n=== Endpoints (compatibility API) ===\n'
        kubectl get endpoints -n "$NAMESPACE" "$PROBE_NAME" -o yaml 2>&1
        printf '\n=== Probe Pod ===\n'
        kubectl get pod -n "$NAMESPACE" "$pod" -o yaml 2>&1
    } >"$diagnostic_file"
    printf '%s' "$diagnostic_file"
}

apply_network_probe() {
    local domain_record="$1" node vendor zone subnet taint toleration_yaml manifest
    IFS='|' read -r node vendor zone subnet taint <<<"$domain_record"
    PROBE_NAME="$(make_probe_id net "$node")"
    manifest="$ARTIFACT_DIR/${PROBE_NAME}.yaml"
    toleration_yaml=""
    if [[ "$vendor" == tencent ]]; then
        toleration_yaml="      tolerations:\n      - key: eks.tke.cloud.tencent.com/eklet\n        operator: Exists\n        effect: NoSchedule"
    elif kubectl get node "$node" -o jsonpath='{.spec.taints[?(@.key=="virtual-kubelet.io/provider")].effect}' 2>/dev/null | grep -qx NoSchedule; then
        toleration_yaml="      tolerations:\n      - key: virtual-kubelet.io/provider\n        operator: Exists\n        effect: NoSchedule"
    fi
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
      nodeSelector:
        kubernetes.io/hostname: ${node}
$(printf '%b\n' "$toleration_yaml")
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
    local domain_record="$1" node vendor zone subnet taint pod service_host mysql_host target result service_probe_output diagnostic_file
    IFS='|' read -r node vendor zone subnet taint <<<"$domain_record"
    if ! apply_network_probe "$domain_record" || ! pod="$(wait_for_pod_ready "probe=${PROBE_NAME}")"; then
        record_result "Serverless Pod部署与网络探测(${node})" "FAIL" "固定调度域的探测 Pod 未就绪"
        return 1
    fi
    service_host="${PROBE_NAME}.${NAMESPACE}.svc"
    if service_probe_output="$(probe_clusterip_service "$pod" "$service_host" 2>&1)"; then
        record_result "Pod访问集群Service网络(${node})" "PASS" "Pod 可访问 ClusterIP Service"
    else
        diagnostic_file="$(capture_clusterip_diagnostics "$pod" "$service_host" "$service_probe_output")"
        if grep -qF 'PROBE_CLIENT_MISSING' <<<"$service_probe_output"; then
            record_result "Pod访问集群Service网络(${node})" "WARN" "探测镜像缺少 wget/curl，未对 ClusterIP 数据面作失败结论；诊断: ${diagnostic_file}"
        else
            record_result "Pod访问集群Service网络(${node})" "FAIL" "Pod 无法访问 ClusterIP Service；诊断: ${diagnostic_file}"
        fi
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
    local storage_class="$1" access_mode="$2" domain_record="$3" node vendor zone subnet taint toleration_yaml pvc_name pod_name manifest marker
    IFS='|' read -r node vendor zone subnet taint <<<"$domain_record"
    case "$storage_class" in
        te-disk) pvc_name="$DISK_PVC" ;;
        te-nfs) pvc_name="$NFS_PVC" ;;
        *) return 1 ;;
    esac
    pod_name="${pvc_name}-pod"
    manifest="$ARTIFACT_DIR/${pvc_name}.yaml"
    marker="serverless-ready-${RUN_TS}"
    toleration_yaml=""
    if [[ "$vendor" == tencent ]]; then
        toleration_yaml="  tolerations:\n  - key: eks.tke.cloud.tencent.com/eklet\n    operator: Exists\n    effect: NoSchedule"
    elif kubectl get node "$node" -o jsonpath='{.spec.taints[?(@.key=="virtual-kubelet.io/provider")].effect}' 2>/dev/null | grep -qx NoSchedule; then
        toleration_yaml="  tolerations:\n  - key: virtual-kubelet.io/provider\n    operator: Exists\n    effect: NoSchedule"
    fi
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
  nodeSelector:
    kubernetes.io/hostname: ${node}
$(printf '%b\n' "$toleration_yaml")
  containers:
  - name: storage-probe
    image: ${SERVERLESS_PROBE_IMAGE}
    command: ["sh", "-c", "echo ${marker} > /data/ready && test \"\$(cat /data/ready)\" = \"${marker}\" && sleep 3600"]
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: ${pvc_name}
EOF
    if ! kubectl apply -f "$manifest" >/dev/null || ! wait_for_pod_ready "storage-probe=${pvc_name}" >/dev/null; then
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

verify_rwx_same_domain() {
    local domain_record="$1" node vendor zone subnet taint toleration_yaml pvc_name writer_name reader_name manifest marker
    IFS='|' read -r node vendor zone subnet taint <<<"$domain_record"
    pvc_name="$(make_probe_id nfs-shared "$node")"
    writer_name="${pvc_name}-writer"
    reader_name="${pvc_name}-reader"
    manifest="$ARTIFACT_DIR/${pvc_name}.yaml"
    marker="serverless-same-domain-${RUN_TS}"
    toleration_yaml=""
    if [[ "$vendor" == tencent ]]; then
        toleration_yaml="  tolerations:\n  - key: eks.tke.cloud.tencent.com/eklet\n    operator: Exists\n    effect: NoSchedule"
    elif kubectl get node "$node" -o jsonpath='{.spec.taints[?(@.key=="virtual-kubelet.io/provider")].effect}' 2>/dev/null | grep -qx NoSchedule; then
        toleration_yaml="  tolerations:\n  - key: virtual-kubelet.io/provider\n    operator: Exists\n    effect: NoSchedule"
    fi
    ensure_artifact_dir
    cat >"$manifest" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  namespace: ${NAMESPACE}
  labels:
    app: ${PROBE_LABEL}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: te-nfs
  resources:
    requests:
      storage: 20Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: ${writer_name}
  namespace: ${NAMESPACE}
  labels:
    app: ${PROBE_LABEL}
    rwx-probe: ${pvc_name}
    role: writer
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${node}
$(printf '%b\n' "$toleration_yaml")
  containers:
  - name: writer
    image: ${SERVERLESS_PROBE_IMAGE}
    command: ["sh", "-c", "echo ${marker} > /data/marker && sleep 3600"]
    volumeMounts: [{name: storage, mountPath: /data}]
  volumes: [{name: storage, persistentVolumeClaim: {claimName: ${pvc_name}}}]
---
apiVersion: v1
kind: Pod
metadata:
  name: ${reader_name}
  namespace: ${NAMESPACE}
  labels:
    app: ${PROBE_LABEL}
    rwx-probe: ${pvc_name}
    role: reader
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: ${node}
$(printf '%b\n' "$toleration_yaml")
  containers:
  - name: reader
    image: ${SERVERLESS_PROBE_IMAGE}
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts: [{name: storage, mountPath: /data}]
  volumes: [{name: storage, persistentVolumeClaim: {claimName: ${pvc_name}}}]
EOF
    if kubectl apply -f "$manifest" >/dev/null && wait_for_pod_ready "rwx-probe=${pvc_name},role=writer" >/dev/null && wait_for_pod_ready "rwx-probe=${pvc_name},role=reader" >/dev/null && kubectl exec -n "$NAMESPACE" "$reader_name" -- cat /data/marker 2>/dev/null | grep -qx "$marker"; then
        record_result "同一Serverless调度域RWX共享(${node})" "PASS" "两个 Pod 已通过同一 te-nfs PVC 共享读写"
        return 0
    fi
    record_result "同一Serverless调度域RWX共享(${node})" "FAIL" "两个 Pod 未能通过同一 te-nfs PVC 共享读写"
    return 1
}

verify_rwx_cross_domain() {
    local writer_record="$1" reader_record="$2" writer writer_vendor _ reader reader_vendor cross_pvc manifest marker
    IFS='|' read -r writer writer_vendor _ <<<"$writer_record"
    IFS='|' read -r reader reader_vendor _ <<<"$reader_record"
    cross_pvc="$(make_probe_id nfs-cross "${writer}-${reader}")"
    manifest="$ARTIFACT_DIR/${cross_pvc}.yaml"; marker="serverless-cross-${RUN_TS}"
    ensure_artifact_dir
    cat >"$manifest" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${cross_pvc}
  namespace: ${NAMESPACE}
  labels: {app: ${PROBE_LABEL}}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: te-nfs
  resources: {requests: {storage: 20Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: ${cross_pvc}-writer, namespace: ${NAMESPACE}, labels: {app: ${PROBE_LABEL}, cross-probe: writer}}
spec:
  restartPolicy: Never
  nodeSelector: {kubernetes.io/hostname: ${writer}}
  tolerations:
  - {key: eks.tke.cloud.tencent.com/eklet, operator: Exists, effect: NoSchedule}
  - {key: virtual-kubelet.io/provider, operator: Exists, effect: NoSchedule}
  containers:
  - name: writer
    image: ${SERVERLESS_PROBE_IMAGE}
    command: ["sh", "-c", "echo ${marker} > /data/marker && sleep 3600"]
    volumeMounts: [{name: storage, mountPath: /data}]
  volumes: [{name: storage, persistentVolumeClaim: {claimName: ${cross_pvc}}}]
---
apiVersion: v1
kind: Pod
metadata: {name: ${cross_pvc}-reader, namespace: ${NAMESPACE}, labels: {app: ${PROBE_LABEL}, cross-probe: reader}}
spec:
  restartPolicy: Never
  nodeSelector: {kubernetes.io/hostname: ${reader}}
  tolerations:
  - {key: eks.tke.cloud.tencent.com/eklet, operator: Exists, effect: NoSchedule}
  - {key: virtual-kubelet.io/provider, operator: Exists, effect: NoSchedule}
  containers:
  - name: reader
    image: ${SERVERLESS_PROBE_IMAGE}
    command: ["sh", "-c", "sleep 3600"]
    volumeMounts: [{name: storage, mountPath: /data}]
  volumes: [{name: storage, persistentVolumeClaim: {claimName: ${cross_pvc}}}]
EOF
    if kubectl apply -f "$manifest" >/dev/null && wait_for_pod_ready "cross-probe=writer" >/dev/null && wait_for_pod_ready "cross-probe=reader" >/dev/null && kubectl exec -n "$NAMESPACE" "${cross_pvc}-reader" -- cat /data/marker 2>/dev/null | grep -qx "$marker"; then
        record_result "跨Serverless调度域RWX共享" "PASS" "${writer} -> ${reader} 共享读写成功"; return 0
    fi
    record_result "跨Serverless调度域RWX共享" "FAIL" "${writer} -> ${reader} RWX共享读写失败"; return 1
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
    local domain_record domain_node
    log "Serverless K8S 可用性检查开始；日志: ${LOG_FILE}；物料: ${ARTIFACT_DIR}"
    if ! check_kubectl_connection; then
        print_summary
        return 1
    fi
    if ! detect_cluster_mode; then
        print_summary
        return 1
    fi
    if [[ "$CLUSTER_MODE" == "Standard" ]]; then
        record_result "Serverless检查分流" "SKIP" "当前为标准节点模式，请使用 k8sAvailCheck.sh 执行节点池检查"
        print_summary
        SCRIPT_COMPLETED=true
        return 0
    fi
    check_platform_features
    for domain_record in "${SERVERLESS_DOMAINS[@]}"; do
        IFS='|' read -r domain_node _ <<<"$domain_record"
        check_serverless_domain_health "$domain_record" || continue
        READY_SERVERLESS_DOMAINS+=("$domain_record")
        check_network_readiness "$domain_record" || true
        DISK_PVC="$(make_probe_id disk "$domain_node")"
        NFS_PVC="$(make_probe_id nfs "$domain_node")"
        if ensure_storageclass te-disk; then verify_storage_e2e "te-disk" "ReadWriteOnce" "$domain_record" || true; fi
        if ensure_storageclass te-nfs; then
            if verify_storage_e2e "te-nfs" "ReadWriteMany" "$domain_record"; then
                verify_rwx_same_domain "$domain_record" || true
            fi
        fi
    done
    if (( ${#READY_SERVERLESS_DOMAINS[@]} >= 2 )); then
        if ensure_storageclass te-nfs; then verify_rwx_cross_domain "${READY_SERVERLESS_DOMAINS[0]}" "${READY_SERVERLESS_DOMAINS[1]}" || true; fi
    else
        record_result "跨Serverless调度域RWX共享" "SKIP" "少于两个通过健康门槛的Serverless调度域"
    fi
    if [[ "$CLUSTER_MODE" == Hybrid ]]; then
        record_result "标准节点检查分流" "SKIP" "混合集群的标准节点请另行执行 k8sAvailCheck.sh；本次已完成Serverless调度域检查"
    fi
    print_summary
    SCRIPT_COMPLETED=true
}

main "$@"
