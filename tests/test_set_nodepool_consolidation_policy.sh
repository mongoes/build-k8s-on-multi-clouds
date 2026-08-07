#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/k8sAvailCheck.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
functions="$tmp_dir/aws-functions.sh"
sed -n '/^_aws_mark_storage_repair_needed()/,/^# ==================== 主执行流程/p' "$script" >"$functions"

RESULTS=""
LOGS=""
record_result() { RESULTS="${RESULTS}$1|$2|${3:-}\n"; }
log_info() { LOGS="${LOGS}$*\n"; }
log_warning() { LOGS="${LOGS}$*\n"; }
log_error() { LOGS="${LOGS}$*\n"; }
log_success() { LOGS="${LOGS}$*\n"; }
# shellcheck disable=SC1090
source "$functions"
AWS_STORAGE_REPAIR_NEEDED=false
AWS_STORAGE_REPAIR_REASONS=""
AWS_CONSOLIDATION_CANDIDATES=""
AWS_SPECIAL_ACTION_TIMEOUT=30
AWS_TOOL_BASE_URL="https://example.invalid"
YELLOW="" BOLD="" NC=""

kubectl() {
    local cmd="$*"
    case "$cmd" in
    "get crd nodepools.karpenter.sh -o name")
        case "${MOCK_CRD:-ok}" in
        notfound) echo 'Error from server (NotFound): customresourcedefinitions.apiextensions.k8s.io "nodepools.karpenter.sh" not found' >&2; return 1 ;;
        forbidden) echo 'Error from server (Forbidden): cannot get resource customresourcedefinitions' >&2; return 1 ;;
        *) printf 'customresourcedefinition.apiextensions.k8s.io/nodepools.karpenter.sh\n' ;;
        esac
        ;;
    "get nodepools.karpenter.sh -o jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
        [[ "${MOCK_LIST_FAIL:-0}" != 1 ]] || { echo 'Forbidden' >&2; return 1; }
        printf '%b' "${MOCK_NODEPOOLS:-}"
        ;;
    "get nodepools.karpenter.sh -o jsonpath="*)
        printf '%b' "${MOCK_LINES:-}"
        ;;
    "get nodepools.karpenter.sh risky-pool -o jsonpath="*)
        if [[ "${MOCK_PATCHED:-0}" == 1 && "${MOCK_READBACK_BAD:-0}" != 1 ]]; then
            printf 'WhenEmpty'
        else
            printf '%s' "${MOCK_CURRENT:-WhenEmptyOrUnderutilized}"
        fi
        ;;
    "patch nodepools.karpenter.sh risky-pool --type=merge "*)
        [[ "${MOCK_PATCH_FAIL:-0}" != 1 ]] || return 1
        MOCK_PATCHED=1
        ;;
    *)
        return 1
        ;;
    esac
}

# AWS NodePool前置门禁必须区分CRD缺失、查询失败、零对象和已有对象。
MOCK_CRD=notfound RESULTS=""
if check_aws_nodepool_gate; then fail 'missing CRD must stop the AWS standard flow'; fi
[[ "$RESULTS" == *'缺少nodepools.karpenter.sh CRD'* ]] || fail 'missing CRD must have a precise failure'

MOCK_CRD=forbidden RESULTS=""
if check_aws_nodepool_gate; then fail 'Forbidden CRD query must not be treated as zero NodePools'; fi
[[ "$RESULTS" == *'CRD查询失败'* ]] || fail 'Forbidden CRD query must retain the permission diagnosis'

MOCK_CRD=ok MOCK_LIST_FAIL=0 MOCK_NODEPOOLS=$'base-pool\n' RESULTS=""
check_aws_nodepool_gate || fail 'an existing NodePool must continue the standard flow'
[[ "$RESULTS" == *'已存在NodePool，继续标准可用性检查'* ]] || fail 'existing NodePool must record PASS'

MOCK_NODEPOOLS="" RESULTS="" MOCK_TOOL_RUN=0
_aws_interactive_tty_available() { return 1; }
_download_and_run_aws_tool() { MOCK_TOOL_RUN=1; }
if check_aws_nodepool_gate; then fail 'zero NodePools without consent must stop'; fi
[[ "$MOCK_TOOL_RUN" == 0 ]] || fail 'non-interactive zero-NodePool gate must not run a privileged tool'

MOCK_TOOL_RUN=0 RESULTS=""
_aws_interactive_tty_available() { return 0; }
_aws_confirm_short_yes() { return 0; }
set +e
check_aws_nodepool_gate
gate_rc=$?
set -e
[[ $gate_rc -eq 10 ]] || fail 'authorized zero-NodePool flow must request a rerun after tool success'
[[ "$MOCK_TOOL_RUN" == 1 ]] || fail 'authorized zero-NodePool flow must run auto_build_nodepool.sh once'

MOCK_LINES=$'safe-pool\tWhenEmpty\ncustom-pool\tNever\nunset-pool\t\n'
AWS_CONSOLIDATION_CANDIDATES=""
check_aws_consolidation_policy
[[ -z "$AWS_CONSOLIDATION_CANDIDATES" ]] || fail 'safe/custom/unset policies must not become repair candidates'
[[ "$RESULTS" == *'AWS NodePool驱逐策略检查|PASS|'* ]] || fail 'no risky policy must record PASS'

RESULTS="" LOGS=""
MOCK_LINES=$'risky-pool\tWhenEmptyOrUnderutilized\nsafe-pool\tWhenEmpty\n'
check_aws_consolidation_policy
[[ "$AWS_CONSOLIDATION_CANDIDATES" == 'risky-pool' ]] || fail 'only WhenEmptyOrUnderutilized must be selected'
[[ "$RESULTS" == *'AWS NodePool驱逐策略检查|WARN|'* ]] || fail 'risky policy must record WARN'

# 非TTY测试环境不得修改集群。
MOCK_PATCHED=0
_aws_interactive_tty_available() { return 1; }
run_aws_postcheck_actions
[[ "$MOCK_PATCHED" == 0 ]] || fail 'non-interactive run must not patch NodePools'

AWS_CONSOLIDATION_CANDIDATES="risky-pool"
MOCK_PATCHED=0 MOCK_READBACK_BAD=0
_aws_confirm_full_yes() { return 0; }
run_aws_postcheck_actions || fail 'confirmed safe patch with successful readback must pass'
[[ "$MOCK_PATCHED" == 1 ]] || fail 'full yes must patch the precise risky NodePool'

MOCK_PATCHED=0 MOCK_READBACK_BAD=1
if run_aws_postcheck_actions; then fail 'unchanged readback after patch must fail'; fi

grep -qF '_aws_confirm_full_yes' "$script" || fail 'repair must require full yes confirmation'
grep -qF "current=\$(kubectl get nodepools.karpenter.sh" "$script" || fail 'repair must re-read each candidate before patch'
grep -qF "actual=\$(kubectl get nodepools.karpenter.sh" "$script" || fail 'repair must read back the patched policy'

echo 'PASS: integrated nodepool consolidation policy regression assertions'
