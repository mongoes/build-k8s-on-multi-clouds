#!/usr/bin/env bash
# Recover an orphaned EFS CSI CSIDriver on an existing EKS cluster.
# Default mode is read-only. --apply requires two independent TTY confirmations.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}"
VPC_ID="${VPC_ID:-}"
EFS_FILE_SYSTEM_ID="${EFS_FILE_SYSTEM_ID:-}"
AWS_PARTITION="${AWS_PARTITION:-aws}"
ADDON_NAME="aws-efs-csi-driver"
CONTROLLER_SA="efs-csi-controller-sa"
EFS_POLICY_ARN="arn:${AWS_PARTITION}:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}"
RUN_MODE="audit"
STATE_DIR="${STATE_DIR:-./.efs_csi_recovery_state}"
RUN_ID="efs-csi-recovery-$(date +%Y%m%d%H%M%S)-$$"
RESULT_FILE=""

green() { printf '%s\n' "$*"; }
red() { printf 'ERROR: %s\n' "$*" >&2; }
die() { red "$*"; return 1; }

usage() {
  cat <<'EOF'
Usage:
  CLUSTER_NAME=<cluster> AWS_DEFAULT_REGION=<region> VPC_ID=<vpc-id> \
  EFS_FILE_SYSTEM_ID=<fs-id> ./recover_orphaned_efs_csi.sh [--audit|--apply]

--audit (default) proves that the only EFS CSI object is a safe orphan.
--apply creates only the aws-efs-csi-driver addon and its Pod Identity after
two exact confirmations. It never deletes or changes EFS, mount targets,
StorageClasses, PVs, PVCs, or EBS CSI resources.
EOF
}

require_config() {
  local key
  for key in CLUSTER_NAME AWS_DEFAULT_REGION VPC_ID EFS_FILE_SYSTEM_ID; do
    [[ -n "${!key}" ]] || die "缺少必填运行参数: ${key}。"
  done
}

require_commands() {
  local command
  for command in aws kubectl helm eksctl jq; do
    command -v "${command}" >/dev/null 2>&1 || die "缺少命令: ${command}。"
  done
}

addon_status() {
  aws eks describe-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name "${ADDON_NAME}" \
    --region "${AWS_DEFAULT_REGION}" \
    --query 'addon.status' --output text 2>/dev/null || printf 'NONE\n'
}

pod_identity_count() {
  aws eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace kube-system \
    --service-account "${CONTROLLER_SA}" \
    --region "${AWS_DEFAULT_REGION}" \
    --output json | jq '[.associations[]?] | length'
}

has_efs_helm_owner() {
  local release manifest
  while IFS= read -r release; do
    [[ -n "${release}" ]] || continue
    manifest="$(helm -n kube-system get manifest "${release}" 2>/dev/null || true)"
    grep -q 'efs.csi.aws.com' <<<"${manifest}" && return 0
  done < <(helm -n kube-system list -q 2>/dev/null || true)
  return 1
}

efs_pv_pvc_count() {
  kubectl get pv,pvc -A -o json | jq '
    [ .items[]?
      | select(
          (.kind == "PersistentVolume" and .spec.csi.driver == "efs.csi.aws.com")
          or (.kind == "PersistentVolumeClaim" and .spec.storageClassName == "te-nfs")
        )
    ] | length'
}

verify_cluster_and_efs() {
  local cluster_status cluster_vpc cluster_endpoint kube_endpoint fs_state enis vpcs
  cluster_status="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" --query 'cluster.status' --output text)"
  [[ "${cluster_status}" == ACTIVE ]] || die "EKS 集群状态不是 ACTIVE: ${cluster_status}。"
  cluster_vpc="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
  [[ "${cluster_vpc}" == "${VPC_ID}" ]] || die "EKS VPC 不匹配: 期望 ${VPC_ID}，实际 ${cluster_vpc}。"
  cluster_endpoint="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" --query 'cluster.endpoint' --output text)"
  kube_endpoint="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  cluster_endpoint="${cluster_endpoint%/}"
  kube_endpoint="${kube_endpoint%/}"
  [[ -n "${kube_endpoint}" && "${kube_endpoint}" == "${cluster_endpoint}" ]] || die "当前 kubeconfig 未指向目标集群 ${CLUSTER_NAME}；拒绝对错误集群执行 Kubernetes 检查。"
  fs_state="$(aws efs describe-file-systems --file-system-id "${EFS_FILE_SYSTEM_ID}" --region "${AWS_DEFAULT_REGION}" --query 'FileSystems[0].LifeCycleState' --output text)"
  [[ "${fs_state}" == available ]] || die "EFS ${EFS_FILE_SYSTEM_ID} 状态不是 available: ${fs_state}。"
  enis="$(aws efs describe-mount-targets --file-system-id "${EFS_FILE_SYSTEM_ID}" --region "${AWS_DEFAULT_REGION}" --query 'MountTargets[].NetworkInterfaceId' --output text)"
  [[ -n "${enis}" && "${enis}" != None ]] || die "EFS ${EFS_FILE_SYSTEM_ID} 没有 Mount Target。"
  vpcs="$(aws ec2 describe-network-interfaces --network-interface-ids ${enis} --region "${AWS_DEFAULT_REGION}" --query 'NetworkInterfaces[].VpcId' --output text)"
  [[ -n "${vpcs}" ]] || die "无法读取 EFS Mount Target 的 VPC。"
  local vpc
  for vpc in ${vpcs}; do
    [[ "${vpc}" == "${VPC_ID}" ]] || die "EFS Mount Target VPC 不匹配: ${vpc}。"
  done
}

assert_orphan_invariants() {
  local addon identities efs_objects
  verify_cluster_and_efs
  addon="$(addon_status)"
  [[ "${addon}" == NONE ]] || die "EFS Add-on 当前状态=${addon}，不属于孤儿接管范围。"
  kubectl get csidriver efs.csi.aws.com >/dev/null 2>&1 || die '未发现 efs.csi.aws.com CSIDriver，不属于本恢复脚本场景。'
  ! kubectl -n kube-system get deployment efs-csi-controller >/dev/null 2>&1 || die 'efs-csi-controller 已存在，不属于孤儿接管范围。'
  ! kubectl -n kube-system get daemonset efs-csi-node >/dev/null 2>&1 || die 'efs-csi-node 已存在，不属于孤儿接管范围。'
  ! has_efs_helm_owner || die '发现 EFS CSI Helm owner，拒绝接管自管驱动。'
  efs_objects="$(efs_pv_pvc_count)"
  [[ "${efs_objects}" == 0 ]] || die "发现 ${efs_objects} 个 EFS PV/PVC，拒绝接管。"
  identities="$(pod_identity_count)"
  [[ "${identities}" == 0 ]] || die "发现 ${identities} 个 EFS CSI Pod Identity Association，拒绝接管。"
}

assert_pod_identity_agent() {
  local status
  status="$(aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent --region "${AWS_DEFAULT_REGION}" --query 'addon.status' --output text 2>/dev/null || printf 'NONE')"
  [[ "${status}" == ACTIVE ]] || die "eks-pod-identity-agent 状态=${status}；无法安全创建 EFS CSI Pod Identity。"
}

tty_available() { [[ -r /dev/tty && -w /dev/tty ]]; }

read_apply_confirmation() {
  local expected="APPLY EFS CSI TAKEOVER ${CLUSTER_NAME} ${AWS_DEFAULT_REGION}" answer
  tty_available || return 1
  printf '输入精确确认串以继续: %s\n' "${expected}" >/dev/tty
  read -r -t 300 answer </dev/tty || return 1
  printf '%s\n' "${answer}"
}

read_takeover_confirmation() {
  local expected="TAKE OVER EFS CSI ${CLUSTER_NAME} ${EFS_FILE_SYSTEM_ID}" answer
  tty_available || return 1
  printf '确认受控接管范围后输入精确确认串: %s\n' "${expected}" >/dev/tty
  read -r -t 300 answer </dev/tty || return 1
  printf '%s\n' "${answer}"
}

confirm_apply() {
  local expected="APPLY EFS CSI TAKEOVER ${CLUSTER_NAME} ${AWS_DEFAULT_REGION}"
  [[ "$(read_apply_confirmation)" == "${expected}" ]] || die '全局 Apply 确认失败、超时或无 TTY；未执行写操作。'
}

confirm_takeover() {
  local expected="TAKE OVER EFS CSI ${CLUSTER_NAME} ${EFS_FILE_SYSTEM_ID}"
  [[ "$(read_takeover_confirmation)" == "${expected}" ]] || die 'EFS 孤儿接管确认失败、超时或无 TTY；未执行写操作。'
}

install_addon() {
  eksctl create addon -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
addons:
  - name: ${ADDON_NAME}
    podIdentityAssociations:
      - namespace: kube-system
        serviceAccountName: ${CONTROLLER_SA}
        permissionPolicyARNs:
          - ${EFS_POLICY_ARN}
EOF
}

wait_for_addon_and_runtime() {
  local elapsed=0 status identities
  while (( elapsed < WAIT_TIMEOUT_SECONDS )); do
    status="$(addon_status)"
    [[ "${status}" == ACTIVE ]] && break
    [[ "${status}" != CREATE_FAILED && "${status}" != DEGRADED ]] || die "EFS Add-on 状态异常: ${status}。"
    sleep 10
    elapsed=$((elapsed + 10))
  done
  [[ "${status:-NONE}" == ACTIVE ]] || die "EFS Add-on 未在 ${WAIT_TIMEOUT_SECONDS}s 内变为 ACTIVE。"
  kubectl -n kube-system rollout status deployment/efs-csi-controller --timeout="${WAIT_TIMEOUT_SECONDS}s"
  kubectl -n kube-system rollout status daemonset/efs-csi-node --timeout="${WAIT_TIMEOUT_SECONDS}s"
  identities="$(pod_identity_count)"
  [[ "${identities}" -gt 0 ]] || die 'EFS Add-on 已 Active，但未读到 efs-csi-controller-sa 的 Pod Identity Association。'
}

audit() {
  assert_pod_identity_agent
  assert_orphan_invariants
  green "TAKEOVER_ELIGIBLE: ${CLUSTER_NAME}/${EFS_FILE_SYSTEM_ID} 是可受控接管的孤儿 EFS CSI。"
  green '审计通过：--apply 将仅创建 EFS CSI Add-on 及 Pod Identity；不会删除或修改既有资源。'
}

apply() {
  audit
  confirm_apply
  confirm_takeover
  # Confirmation is deliberately followed by a full re-read to reject drift.
  audit
  install_addon
  wait_for_addon_and_runtime
  green 'RECOVERY_COMPLETE: EFS CSI Add-on、Pod Identity、controller 与 node 均已就绪。'
}

main() {
  case "${1:---audit}" in
    --audit) RUN_MODE=audit ;;
    --apply) RUN_MODE=apply ;;
    -h|--help) usage; return 0 ;;
    *) usage >&2; return 2 ;;
  esac
  require_config
  require_commands
  mkdir -p "${STATE_DIR}"
  RESULT_FILE="${STATE_DIR}/${RUN_ID}.log"
  if [[ "${RECOVERY_TEST_MODE:-false}" != true ]]; then
    exec > >(tee -a "${RESULT_FILE}") 2>&1
  fi
  "${RUN_MODE}"
}

main "$@"
