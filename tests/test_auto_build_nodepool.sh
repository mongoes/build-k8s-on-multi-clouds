#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/aws eks k8s/v1.36 eks v1.13 karpenter/01eks_build/auto_build_nodepool.sh}"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
source_copy="$tmp/auto_build_nodepool.functions.sh"
sed '$d' "$SCRIPT" > "$source_copy"
# macOS ships Bash 3.2, while the production script's associative map needs
# Bash 4+.  Keep the production map untouched; make only the temporary test
# copy use an equivalent portable lookup so the behavioral test can run here.
sed -i.bak \
  -e '/  declare -A INSTANCE_TYPE_MAP=(/,/^  )/c\
  get_instance_types() {\
    case "$1" in\
      2c4g) printf "%s\\n" "c5.large c5a.large" ;;\
      4c32g) printf "%s\\n" "r8a.xlarge r8i.xlarge r7i.xlarge r7a.xlarge r6i.xlarge r6a.xlarge" ;;\
      8c16g) printf "%s\\n" "c6a.2xlarge c7a.2xlarge c7i.2xlarge c8a.2xlarge c8i.2xlarge" ;;\
      8c32g) printf "%s\\n" "m8g.2xlarge m7i.2xlarge m7a.2xlarge m6i.2xlarge m6a.2xlarge" ;;\
      8c64g) printf "%s\\n" "r7i.2xlarge r6a.2xlarge r6i.2xlarge r7a.2xlarge" ;;\
      16c64g) printf "%s\\n" "m6a.4xlarge m6i.4xlarge m6in.4xlarge m7a.4xlarge m8g.4xlarge" ;;\
      32c128g) printf "%s\\n" "m6a.8xlarge m6i.8xlarge m6in.8xlarge m7a.8xlarge m8g.8xlarge" ;;\
      64c256g) printf "%s\\n" "m6a.16xlarge m6i.16xlarge m6in.16xlarge m7a.16xlarge m8g.16xlarge" ;;\
      *) return 1 ;;\
    esac\
  }' \
  -e 's/\[\[ -z "${INSTANCE_TYPE_MAP\[$size\]+x}" \]\]/! get_instance_types "$size" >\/dev\/null/' \
  -e 's/INSTANCE_TYPES="${INSTANCE_TYPE_MAP\[$SIZE\]}"/INSTANCE_TYPES="$(get_instance_types "$SIZE")"/' \
  "$source_copy"
rm -f "$source_copy.bak"

# Kubeconfig selection prefers a valid explicit file and falls back only to the default path.
env_context_dir="$tmp/environment-context"
mkdir -p "$env_context_dir/default/.kube"
touch "$env_context_dir/explicit-config" "$env_context_dir/default/.kube/config"
(
  source "$source_copy"
  KUBECONFIG="$env_context_dir/explicit-config"
  KUBECONFIG_DEFAULT_PATH="$env_context_dir/default/.kube/config"
  select_target_kubeconfig
  [[ "$KUBECONFIG" == "$env_context_dir/explicit-config" ]] || fail 'valid explicit KUBECONFIG must take precedence'
) || fail 'valid explicit kubeconfig selection must succeed'
(
  source "$source_copy"
  KUBECONFIG="$env_context_dir/missing-config"
  KUBECONFIG_DEFAULT_PATH="$env_context_dir/default/.kube/config"
  select_target_kubeconfig
  [[ "$KUBECONFIG" == "$env_context_dir/default/.kube/config" ]] || fail 'missing explicit KUBECONFIG must fall back to the default file'
) || fail 'default kubeconfig fallback must succeed'
(
  source "$source_copy"
  KUBECONFIG=''
  KUBECONFIG_DEFAULT_PATH="$env_context_dir/no-default"
  if select_target_kubeconfig; then
    fail 'missing explicit and default kubeconfig files must block'
  fi
)

# The current kubeconfig context is the only source of EKS cluster, region and account identity.
resolve_environment_fixture() {
  (
    source "$source_copy"
    KUBECONFIG="$env_context_dir/explicit-config"
    kubectl() {
      case "$*" in
      'config current-context') printf '%s\n' 'arn:aws:eks:us-east-1:867227370517:cluster/eks-public-only-20260827' ;;
      'config view --raw -o json') printf '%s' '{"contexts":[{"name":"arn:aws:eks:us-east-1:867227370517:cluster/eks-public-only-20260827","context":{"cluster":"arn:aws:eks:us-east-1:867227370517:cluster/eks-public-only-20260827"}}],"clusters":[{"name":"arn:aws:eks:us-east-1:867227370517:cluster/eks-public-only-20260827","cluster":{"server":"https://eks.example"}}]}' ;;
      *) return 1 ;;
      esac
    }
    resolve_target_eks_environment
    printf '%s|%s|%s|%s\n' "$TARGET_CLUSTER_NAME" "$TARGET_AWS_REGION" "$TARGET_AWS_ACCOUNT_ID" "$TARGET_API_SERVER"
  )
}
environment_output=$(resolve_environment_fixture) || fail 'standard EKS ARN environment resolution must succeed'
grep -q 'eks-public-only-20260827|us-east-1|867227370517|https://eks.example' <<<"$environment_output" || fail 'EKS environment fields must be resolved from the current kubeconfig context'

# Environment rejection must finish before any operation-menu or Karpenter action.
(
  source "$source_copy"
  TARGET_KUBECONFIG="$env_context_dir/explicit-config"
  TARGET_CURRENT_CONTEXT='arn:aws:eks:us-east-1:867227370517:cluster/eks-a'
  TARGET_CLUSTER_NAME=eks-a
  TARGET_AWS_REGION=us-east-1
  TARGET_AWS_ACCOUNT_ID=867227370517
  TARGET_API_SERVER=https://eks.example
  read_tty_input() { printf -v "$1" '%s' n; }
  check_eks_karpenter_status() { fail 'environment rejection must happen before Karpenter checks'; }
  confirm_target_eks_environment
) && fail 'environment confirmation n must return a non-success decision'

main_order_log="$env_context_dir/main-order.log"
(
  source "$source_copy"
  checkUser() { printf '%s\n' check-user >>"$main_order_log"; }
  test_k8s_connection() { printf '%s\n' connection >>"$main_order_log"; }
  resolve_target_eks_environment() { printf '%s\n' resolve-environment >>"$main_order_log"; }
  confirm_target_eks_environment() { printf '%s\n' confirm-environment >>"$main_order_log"; return 2; }
  check_eks_karpenter_status() { fail 'rejected environment must never reach operation execution'; }
  main_rc=0
  main || main_rc=$?
  [[ $main_rc -eq 10 ]] || fail "user environment rejection must return dedicated cancellation rc=10, got rc=${main_rc}"
) || fail 'user environment rejection must be a distinct clean cancellation'
[[ "$(tr '\n' ' ' <"$main_order_log")" == 'check-user connection resolve-environment confirm-environment ' ]] || fail 'environment confirmation must precede every operation branch'

# The standalone builder owns only target confirmation, NodePool creation and
# minimal object readiness.  Full scheduling/network/storage checks belong to
# k8sAvailCheck.sh after the child returns successfully.
creation_only_log="$env_context_dir/creation-only-main.log"
(
  source "$source_copy"
  checkUser() { printf '%s\n' check-user >>"$creation_only_log"; }
  test_k8s_connection() { printf '%s\n' connection >>"$creation_only_log"; }
  resolve_target_eks_environment() { printf '%s\n' resolve-environment >>"$creation_only_log"; }
  confirm_target_eks_environment() { printf '%s\n' confirm-environment >>"$creation_only_log"; return 0; }
  check_eks_karpenter_status() { printf '%s\n' karpenter-preflight >>"$creation_only_log"; }
  build_nodepool_for_business() {
    printf '%s\n' build-nodepools >>"$creation_only_log"
    NODEPOOL_NAMES=(od-4c32g spot-8c16g)
  }
  wait_nodepools_ready() {
    printf 'wait-ready:%s\n' "$*" >>"$creation_only_log"
  }
  test_all_nodepools() { fail 'creation-only main must not run duplicate Pod/network availability checks'; }
  taints_all_spot_nodepool() { fail 'creation-only main must not expose the old taint mutation branch'; }
  read() { fail 'creation-only main must not display a second operation menu'; }
  main
) || fail 'main must complete the creation-only handoff flow'
[[ "$(tr '\n' ' ' <"$creation_only_log")" == 'check-user connection resolve-environment confirm-environment karpenter-preflight build-nodepools wait-ready:od-4c32g spot-8c16g ' ]] ||
  fail 'main must validate only the NodePools created in this invocation, in the expected order'

# Minimal readiness follows each requested NodePool's actual nodeClassRef.  It
# must not inspect an unrelated legacy pool and must not assume the class name
# equals the NodePool name.
ready_query_log="$env_context_dir/ready-query.log"
(
  source "$source_copy"
  NODEPOOL_READY_TIMEOUT=5
  sleep() { :; }
  kubectl() {
    printf '%s\n' "$*" >>"$ready_query_log"
    case "$*" in
    'get nodepool new-pool -o jsonpath={.status.conditions[?(@.type=="Ready")].status}') printf '%s' True ;;
    'get nodepool new-pool -o jsonpath={.spec.template.spec.nodeClassRef.name}') printf '%s' shared-class ;;
    'get ec2nodeclass shared-class -o jsonpath={.status.conditions[?(@.type=="Ready")].status}') printf '%s' True ;;
    'get karpenter') printf '%s\n' 'NAME READY' 'new-pool True' ;;
    *) return 1 ;;
    esac
  }
  wait_nodepools_ready new-pool
) || fail 'a requested NodePool and its referenced EC2NodeClass Ready=True must pass'
grep -Fq 'get ec2nodeclass shared-class' "$ready_query_log" || fail 'readiness must verify the referenced EC2NodeClass'
! grep -q 'legacy-pool' "$ready_query_log" || fail 'readiness must not inspect unrelated existing NodePools'

# A failed readiness check is a normal function failure, not process
# termination; main/parent callers need its return code to report precisely.
ready_return_marker="$env_context_dir/ready-returned"
(
  source "$source_copy"
  NODEPOOL_READY_TIMEOUT=1
  sleep() { :; }
  kubectl() {
    case "$*" in
    'get nodepool broken-pool -o jsonpath={.status.conditions[?(@.type=="Ready")].status}') printf '%s' False ;;
    'get nodepool broken-pool -o jsonpath={.spec.template.spec.nodeClassRef.name}') printf '%s' broken-class ;;
    'get ec2nodeclass broken-class -o jsonpath={.status.conditions[?(@.type=="Ready")].status}') printf '%s' False ;;
    'get nodepool broken-pool -o jsonpath={.status.conditions[?(@.type=="Ready")].reason}') printf '%s' NotReady ;;
    'get nodepool broken-pool -o jsonpath={.status.conditions[?(@.type=="Ready")].message}') printf '%s' waiting ;;
    'get ec2nodeclass broken-class -o json') printf '%s' '{"status":{"conditions":[{"type":"Ready","status":"False","reason":"Waiting"}]}}' ;;
    'get karpenter') return 0 ;;
    *) return 1 ;;
    esac
  }
  if wait_nodepools_ready broken-pool; then
    fail 'a non-ready NodePool must fail readiness validation'
  fi
  : >"$ready_return_marker"
) >/dev/null 2>&1 || true
[[ -f "$ready_return_marker" ]] || fail 'readiness failure must return to its caller instead of exiting the process'

run_create() {
  local nodepool_state="$1" names="$2" sizes="$3" billing="$4"
  local work="$tmp/$nodepool_state-$(date +%s%N)"
  RUN_WORK="$work"
  mkdir -p "$work/configs"
  (
    cd "$work"
    source "$source_copy"
    OUTPUT_DIR="$work/configs"
    LOG_FILE="$work/nodepool.log"
    get_os_alias_version() { ALIAS_VERSION=v20260801; }
    get_cluster_name() { printf '%s\n' eks-test; }
    get_zone() { printf '%s\n' us-east-1a; }
    read_tty_input() {
      local variable_name=$1
      TTY_VALUE=${TTY_VALUE:-y}
      printf -v "$variable_name" '%s' "$TTY_VALUE"
    }
    kubectl() {
      case "$*" in
      'get nodepool')
        [[ "$nodepool_state" == existing ]] && printf '%s\n' 'NAME READY' 'existing-nodepool True'
        ;;
      'get nodepool -o json')
        if [[ "$nodepool_state" == existing ]]; then
          printf '%s' '{"items":[{"metadata":{"name":"existing-nodepool"}}]}'
        else
          printf '%s' '{"items":[]}'
        fi
        ;;
      'get nodepool existing-nodepool -o json')
        printf '%s' '{"spec":{"template":{"spec":{"requirements":[{"key":"topology.kubernetes.io/zone","values":["us-east-1a"]}]}}}}'
        ;;
      'get nodepool od-4c32g') [[ "$nodepool_state" == conflict ]] && return 0 || return 1 ;;
      'get nodepool '*'-o jsonpath='*) printf '%s' True ;;
      'get karpenter -oyaml') printf '%s\n' 'apiVersion: v1' ;;
      'get ec2nodeclass existing-nodepool -o json')
        printf '%s' '{"spec":{"subnetSelectorTerms":[{"tags":{"karpenter.sh/discovery-subnet":"legacy"}}],"securityGroupSelectorTerms":[{"tags":{"karpenter.sh/discovery-sg":"eks-test"}}]}}'
        ;;
      'apply -f '*) printf '%s\n' "$*" >> "$work/apply.log" ;;
      *) printf '%s\n' "$*" >> "$work/kubectl.log"; return 1 ;;
      esac
    }
    printf '%s\n%s\n%s\n' "$names" "$sizes" "$billing" | build_nodepool_for_business
  )
}

run_existing_config_decision() {
  local historical_subnet_value="$1" tty_values="$2" nodepool_count="${3:-1}"
  local work="$tmp/config-decision-${historical_subnet_value}-$(date +%s%N)"
  mkdir -p "$work"
  (
    cd "$work"
    source "$source_copy"
    CLUSTER_NAME=eks-test
    AvailabilityZone=us-east-1a
    subnetSelectorKey=karpenter.sh/discovery-subnet
    subnetSelectorValue='*'
    securityGroupSelectorKey=karpenter.sh/discovery-sg
    securityGroupSelectorValue=eks-test
    TTY_VALUES="$tty_values"
    TTY_CALLS=0
    read_tty_input() {
      local variable_name=$1 next_value
      TTY_CALLS=$((TTY_CALLS + 1))
      [[ -n "$TTY_VALUES" ]] || fail 'compliant historical config must not request a reuse decision'
      next_value=${TTY_VALUES%%,*}
      if [[ "$TTY_VALUES" == *,* ]]; then
        TTY_VALUES=${TTY_VALUES#*,}
      else
        TTY_VALUES=''
      fi
      printf -v "$variable_name" '%s' "$next_value"
    }
    kubectl() {
      case "$*" in
      'get nodepool -o json')
        if [[ "$nodepool_count" -eq 2 ]]; then
          printf '%s' '{"items":[{"metadata":{"name":"existing-nodepool"}},{"metadata":{"name":"second-nodepool"}}]}'
        else
          printf '%s' '{"items":[{"metadata":{"name":"existing-nodepool"}}]}'
        fi
        ;;
      'get nodepool existing-nodepool -o json'|'get nodepool second-nodepool -o json')
        printf '%s' '{"spec":{"template":{"spec":{"requirements":[{"key":"topology.kubernetes.io/zone","values":["us-east-1a"]}]}}}}'
        ;;
      'get ec2nodeclass existing-nodepool -o json'|'get ec2nodeclass second-nodepool -o json')
        printf '{"spec":{"subnetSelectorTerms":[{"tags":{"karpenter.sh/discovery-subnet":"%s"}}],"securityGroupSelectorTerms":[{"tags":{"karpenter.sh/discovery-sg":"eks-test"}}]}}' "$historical_subnet_value"
        ;;
      *) return 1 ;;
      esac
    }
    select_existing_nodepool_config
    printf 'TTY_CALLS=%s\n' "$TTY_CALLS"
    printf 'HISTORICAL_CONFIG_SELECTED=%s\n' "${HISTORICAL_CONFIG_SELECTED:-false}"
  )
}

# Fully compliant historical configuration is accepted without displaying details or asking for reuse.
compliant_output=$(run_existing_config_decision '*' '') || fail 'compliant historical config must pass without interaction'
grep -q '检测到存量节点池且确认其关键配置符合最佳规范！' <<<"$compliant_output" || fail 'compliant history must print the concise best-practice conclusion'
grep -q 'TTY_CALLS=0' <<<"$compliant_output" || fail 'compliant history must not call the TTY decision prompt'
! grep -q 'subnetSelectorTerms=' <<<"$compliant_output" || fail 'compliant history must not dump selector details'
multi_compliant_output=$(run_existing_config_decision '*' '' 2) || fail 'multiple compliant NodePools must pass without interaction'
grep -q 'TTY_CALLS=0' <<<"$multi_compliant_output" || fail 'multiple compliant NodePools must not call the TTY decision prompt'
! grep -q '来源 NodePool' <<<"$multi_compliant_output" || fail 'multiple compliant NodePools must not dump source details'

# Rejecting a non-compliant historical configuration selects the current best practice and continues.
recommended_output=$(run_existing_config_decision legacy n) || fail 'rejecting history must continue with the recommended configuration'
grep -q '已选择当前最佳规范' <<<"$recommended_output" || fail 'history rejection must disclose the recommended configuration choice'
grep -q 'HISTORICAL_CONFIG_SELECTED=false' <<<"$recommended_output" || fail 'history rejection must not mark historical configuration selected'

# The full creation flow must still write the requested new objects after choosing the recommendation.
TTY_VALUE=n run_create existing od-8c32g 8c32g od || fail 'recommended configuration choice must continue through creation'
grep -q 'nodepool-od-8c32g.yaml' "$RUN_WORK/apply.log" || fail 'recommended configuration choice must apply the requested NodePool'
grep -Fq 'subnetSelectorTerms: [{"tags":{"karpenter.sh/discovery-subnet":"*"}}]' "$RUN_WORK/configs/nodepool-od-8c32g.yaml" || fail 'recommended configuration must render the current subnet selector'
grep -Fq 'securityGroupSelectorTerms: [{"tags":{"karpenter.sh/discovery-sg":"eks-test"}}]' "$RUN_WORK/configs/nodepool-od-8c32g.yaml" || fail 'recommended configuration must render the current security-group selector'

# Multiple distinct configurations disclose their sources and retry invalid decisions/selections.
run_multi_config_decision() {
  (
    cd "$tmp"
    source "$source_copy"
    CLUSTER_NAME=eks-test
    AvailabilityZone=us-east-1a
    subnetSelectorKey=karpenter.sh/discovery-subnet
    subnetSelectorValue='*'
    securityGroupSelectorKey=karpenter.sh/discovery-sg
    securityGroupSelectorValue=eks-test
    TTY_VALUES='invalid,y,9,2'
    TTY_CALLS=0
    read_tty_input() {
      local variable_name=$1 next_value=${TTY_VALUES%%,*}
      TTY_CALLS=$((TTY_CALLS + 1))
      if [[ "$TTY_VALUES" == *,* ]]; then TTY_VALUES=${TTY_VALUES#*,}; else TTY_VALUES=''; fi
      printf -v "$variable_name" '%s' "$next_value"
    }
    kubectl() {
      case "$*" in
      'get nodepool -o json') printf '%s' '{"items":[{"metadata":{"name":"pool-a"}},{"metadata":{"name":"pool-b"}}]}' ;;
      'get nodepool pool-a -o json'|'get nodepool pool-b -o json') printf '%s' '{"spec":{"template":{"spec":{"requirements":[{"key":"topology.kubernetes.io/zone","values":["us-east-1a"]}]}}}}' ;;
      'get ec2nodeclass pool-a -o json') printf '%s' '{"spec":{"subnetSelectorTerms":[{"tags":{"karpenter.sh/discovery-subnet":"legacy-a"}}],"securityGroupSelectorTerms":[{"tags":{"karpenter.sh/discovery-sg":"eks-test"}}]}}' ;;
      'get ec2nodeclass pool-b -o json') printf '%s' '{"spec":{"subnetSelectorTerms":[{"tags":{"karpenter.sh/discovery-subnet":"legacy-b"}}],"securityGroupSelectorTerms":[{"tags":{"karpenter.sh/discovery-sg":"eks-test"}}]}}' ;;
      *) return 1 ;;
      esac
    }
    select_existing_nodepool_config
    printf 'TTY_CALLS=%s\n' "$TTY_CALLS"
    printf 'SELECTED_SUBNET=%s\n' "$HISTORICAL_SUBNET_SELECTOR_TERMS"
  )
}
multi_output=$(run_multi_config_decision) || fail 'multiple historical configurations must support repeated decisions'
grep -q '来源 NodePool: pool-a' <<<"$multi_output" || fail 'first historical candidate must disclose its source NodePool'
grep -q '来源 NodePool: pool-b' <<<"$multi_output" || fail 'second historical candidate must disclose its source NodePool'
grep -q '输入无效，只允许输入 y 或 n' <<<"$multi_output" || fail 'invalid reuse decision must be explained and retried'
grep -q '配置序号无效，只允许输入 1-2' <<<"$multi_output" || fail 'invalid candidate selection must be explained and retried'
grep -q 'TTY_CALLS=4' <<<"$multi_output" || fail 'invalid decision and selection must each re-prompt'
grep -q 'legacy-b' <<<"$multi_output" || fail 'valid second selection must choose the second historical configuration'

# A zero-NodePool EKS cluster must create only the explicitly requested business pool.
run_create zero od-4c32g 4c32g od || fail 'explicit business NodePool creation must succeed without a base NodePool'
[[ ! -e "$tmp/zero"*/configs/nodepool-base-nodepool.yaml ]] || fail 'zero-NodePool flow must not render base-nodepool'
! grep -q 'base-nodepool' "$tmp/zero"*/apply.log 2>/dev/null || fail 'zero-NodePool flow must not apply base-nodepool'
grep -q 'cpu: 3200' "$tmp/zero"*/configs/nodepool-od-4c32g.yaml || fail 'business template must set limits.cpu to 3200'

# Multiple explicit business pools retain the same CPU limit.
run_create zero 'od-4c32g spot-8c16g' '4c32g 8c16g' 'od spot' || fail 'multiple business NodePools must succeed'
grep -q '^  weight: 10$' "$RUN_WORK/configs/nodepool-od-4c32g.yaml" || fail 'on-demand NodePool must render spec.weight=10'
grep -q '^  weight: 100$' "$RUN_WORK/configs/nodepool-spot-8c16g.yaml" || fail 'spot NodePool must render the higher spec.weight=100'
[[ "$(grep -c '^  weight:' "$RUN_WORK/configs/nodepool-od-4c32g.yaml")" -eq 1 ]] || fail 'on-demand NodePool must render exactly one top-level weight'
[[ "$(grep -c '^  weight:' "$RUN_WORK/configs/nodepool-spot-8c16g.yaml")" -eq 1 ]] || fail 'spot NodePool must render exactly one top-level weight'
for config in "$tmp/zero"*/configs/nodepool-*.yaml; do
  grep -q 'cpu: 3200' "$config" || fail "business template missing cpu 3200: $config"
done

# Empty desired state is invalid and must not mutate the cluster.
if run_create zero '' '' ''; then
  fail 'empty business NodePool input must fail'
fi
[[ ! -s "$RUN_WORK/apply.log" ]] || fail 'invalid empty input must not apply resources'

# Parameter cardinality and invalid values must be rejected before apply.
if run_create zero 'od-4c32g spot-8c16g' 4c32g od; then
  fail 'mismatched business NodePool input must fail'
fi
[[ ! -s "$RUN_WORK/apply.log" ]] || fail 'mismatched input must not apply resources'
if run_create zero od-unknown unknown od; then
  fail 'invalid business NodePool size must fail'
fi
[[ ! -s "$RUN_WORK/apply.log" ]] || fail 'invalid size must not apply resources'
if run_create zero od-4c32g 4c32g reserved; then
  fail 'invalid business NodePool billing mode must fail'
fi
[[ ! -s "$RUN_WORK/apply.log" ]] || fail 'invalid billing mode must not apply resources'

# Existing NodePools are read-only context; the requested business pool is still created.
run_create existing od-4c32g 4c32g od || fail 'existing NodePool flow must still create the requested business NodePool'
grep -q 'nodepool-od-4c32g.yaml' "$tmp/existing"*/apply.log || fail 'existing NodePool flow must apply the requested business NodePool'
! grep -q 'base-nodepool' "$tmp/existing"*/apply.log || fail 'existing NodePool flow must not apply base-nodepool'

# A same-name object is not adopted: only the conflicting name is re-entered.
run_create conflict od-4c32g 4c32g od || fail 'same-name NodePool must allow re-entering this one name'
grep -q 'nodepool-y.yaml' "$RUN_WORK/apply.log" || fail 'same-name conflict must apply only the replacement name'
! grep -q 'nodepool-od-4c32g.yaml' "$RUN_WORK/apply.log" || fail 'same-name conflict must not apply the existing name'

# Cluster identity must never fall back to an arbitrary first result from ListClusters.
cluster_lookup_log="$tmp/cluster-lookup.log"
(
  KUBECONFIG=""
  source "$source_copy"
  aws() { printf '%s\n' "$*" >> "$cluster_lookup_log"; }
  [[ -z "$(get_cluster_name)" ]] || fail 'missing kubeconfig cluster name must not be guessed from AWS'
)
[[ ! -s "$cluster_lookup_log" ]] || fail 'missing kubeconfig cluster name must not call aws eks list-clusters'

# The builder must not retain an independent Pod/network/taint test suite.
# Those behaviors are owned by k8sAvailCheck.sh, which resumes after rc=0.
! grep -q '^test_nodepool()' "$SCRIPT" || fail 'builder must not duplicate Pod scheduling checks'
! grep -q '^test_all_nodepools()' "$SCRIPT" || fail 'builder must not duplicate the parent availability suite'
! grep -q '^test_pod_to_executor()' "$SCRIPT" || fail 'builder must not duplicate network connectivity checks'
! grep -q '^collect_nodepool_runtime_evidence()' "$SCRIPT" || fail 'builder must not maintain a second runtime evidence collector'
! grep -q '^taints_all_spot_nodepool()' "$SCRIPT" || fail 'builder must not expose unrelated workload/taint mutation flows'
! grep -q 'kind: Deployment' "$SCRIPT" || fail 'builder must not create availability-test Deployments'
! grep -q 'kubectl exec' "$SCRIPT" || fail 'builder must not run Pod-level connectivity tests'
! grep -q 'node.k8s.te/managed-by' "$SCRIPT" || fail 'NodePool template must not add ownership labels'
! grep -q 'node.k8s.te/config-hash' "$SCRIPT" || fail 'NodePool template must not add configuration hash labels'
grep -q '完整调度、网络、节点契约与存储检查由k8sAvailCheck.sh继续执行' "$SCRIPT" || fail 'standalone success must explain the full-check handoff'

# NodePool discovery has one fail-closed JSON boundary: only a valid empty items array means zero NodePools.
load_json_work="$tmp/load-nodepools"
mkdir -p "$load_json_work"
(
  cd "$load_json_work"
  source "$source_copy"
  kubectl() { printf '%s' '{"items":[]}'; }
  [[ "$(load_nodepools_json)" == '{"items":[]}' ]] || fail 'valid empty NodePool JSON must be accepted as zero NodePools'
)
(
  cd "$load_json_work"
  source "$source_copy"
  kubectl() { return 1; }
  if load_nodepools_json >/dev/null 2>&1; then
    fail 'NodePool API failure must not be treated as zero NodePools'
  fi
)

echo 'PASS: auto_build_nodepool explicit-business-only regression checks'
