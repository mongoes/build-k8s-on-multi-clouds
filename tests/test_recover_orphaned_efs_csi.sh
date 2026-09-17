#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/aws eks k8s/v1.36 eks v1.13 karpenter/05eks_bestpractice/add_storage/recover_orphaned_efs_csi.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
bin="$tmp/bin"
mkdir -p "$bin"
write_log="$tmp/write.log"
addon_state="$tmp/addon-state"

cat >"$bin/aws" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" eks describe-cluster "*)
    if [[ "$*" == *resourcesVpcConfig.vpcId* ]]; then echo vpc-test
    elif [[ "$*" == *cluster.endpoint* ]]; then echo https://eks-test.example
    else echo ACTIVE; fi ;;
  *" eks describe-addon "*" aws-efs-csi-driver "*)
    [[ -f "${RECOVERY_TEST_ADDON_STATE:-}" ]] && echo ACTIVE || echo NONE ;;
  *" eks describe-addon "*" eks-pod-identity-agent "*) echo ACTIVE ;;
  *" eks list-pod-identity-associations "*)
    [[ -f "${RECOVERY_TEST_ADDON_STATE:-}" ]] && echo '{"associations":[{"associationId":"a-test"}]}' || echo '{"associations":[]}' ;;
  *" efs describe-file-systems "*) echo available ;;
  *" efs describe-mount-targets "*) echo eni-a ;;
  *" ec2 describe-network-interfaces "*) echo vpc-test ;;
  *) echo "unexpected aws: $*" >&2; exit 98 ;;
esac
EOF

cat >"$bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" config view --minify "*)
    [[ "${RECOVERY_TEST_WRONG_CONTEXT:-false}" == true ]] && echo https://wrong-cluster.example || echo https://eks-test.example ;;
  *" get csidriver efs.csi.aws.com "*) echo efs.csi.aws.com ;;
  *" get deployment efs-csi-controller "*|*" get daemonset efs-csi-node "*) exit 1 ;;
  *" get pv,pvc "*)
    if [[ "${RECOVERY_TEST_EFS_PV:-false}" == true ]]; then
      echo '{"items":[{"kind":"PersistentVolume","spec":{"csi":{"driver":"efs.csi.aws.com"}}}]}'
    else
      echo '{"items":[]}'
    fi ;;
  *" rollout status "*) exit 0 ;;
  *) echo "unexpected kubectl: $*" >&2; exit 98 ;;
esac
EOF

cat >"$bin/helm" <<'EOF'
#!/usr/bin/env bash
[[ " $* " == *" list -q "* ]] && exit 0
echo "unexpected helm: $*" >&2
exit 98
EOF

cat >"$bin/eksctl" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *" create addon "* ]]; then
  cat >/dev/null
  echo "eksctl create addon" >>"$RECOVERY_TEST_WRITE_LOG"
  : >"$RECOVERY_TEST_ADDON_STATE"
  exit 0
fi
echo "unexpected eksctl: $*" >&2
exit 98
EOF

chmod +x "$bin"/*

base_env=(
  PATH="$bin:$PATH"
  RECOVERY_TEST_WRITE_LOG="$write_log"
  RECOVERY_TEST_ADDON_STATE="$addon_state"
  CLUSTER_NAME=eks-test
  AWS_DEFAULT_REGION=us-test-1
  VPC_ID=vpc-test
  EFS_FILE_SYSTEM_ID=fs-test
  RECOVERY_TEST_MODE=true
)

set +e
audit_out="$(env "${base_env[@]}" bash "$SCRIPT" --audit 2>&1)"
audit_rc=$?
set -e
[[ "$audit_rc" -eq 0 ]] || fail "eligible orphan audit must pass: $audit_out"
grep -q 'TAKEOVER_ELIGIBLE' <<<"$audit_out" || fail 'audit must identify an eligible orphan takeover'
[[ ! -s "$write_log" ]] || fail "audit issued a write: $(cat "$write_log")"

set +e
wrong_context_out="$(env "${base_env[@]}" RECOVERY_TEST_WRONG_CONTEXT=true bash "$SCRIPT" --audit 2>&1)"
wrong_context_rc=$?
set -e
[[ "$wrong_context_rc" -ne 0 ]] || fail 'a kubeconfig context for another cluster must block audit'
grep -q 'kubeconfig' <<<"$wrong_context_out" || fail 'wrong kubeconfig context must explain the blocker'
[[ ! -s "$write_log" ]] || fail "wrong kubeconfig context issued a write: $(cat "$write_log")"

apply_lib="$tmp/recovery-lib.sh"
sed '/^main "\$@"$/d' "$SCRIPT" >"$apply_lib"

set +e
apply_out="$(env "${base_env[@]}" bash -c '
  source "$0"
  read_apply_confirmation() { printf "%s\\n" "APPLY EFS CSI TAKEOVER eks-test us-test-1"; }
  read_takeover_confirmation() { printf "%s\\n" "TAKE OVER EFS CSI eks-test fs-test"; }
  main --apply
' "$apply_lib" 2>&1)"
apply_rc=$?
set -e
[[ "$apply_rc" -eq 0 ]] || fail "exact confirmations must create the addon: $apply_out"
grep -q 'eksctl create addon' "$write_log" || fail 'apply must create EKS addon only after both confirmations'

: >"$write_log"
rm -f "$addon_state"
set +e
drift_out="$(env "${base_env[@]}" RECOVERY_TEST_EFS_PV=true bash -c '
  source "$0"
  read_apply_confirmation() { printf "%s\\n" "APPLY EFS CSI TAKEOVER eks-test us-test-1"; }
  read_takeover_confirmation() { printf "%s\\n" "TAKE OVER EFS CSI eks-test fs-test"; }
  main --apply
' "$apply_lib" 2>&1)"
drift_rc=$?
set -e
[[ "$drift_rc" -ne 0 ]] || fail 'EFS PV/PVC drift must block apply'
grep -q 'EFS PV/PVC' <<<"$drift_out" || fail 'drift refusal must explain the EFS PV/PVC blocker'
[[ ! -s "$write_log" ]] || fail "drift issued a write: $(cat "$write_log")"

echo 'PASS: orphan EFS CSI recovery safety checks'
