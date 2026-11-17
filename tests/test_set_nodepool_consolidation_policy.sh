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

# AWS NodePool创建/检查双入口已由test_k8s_avail_check.sh覆盖；本文件仅保留
# consolidationPolicy审计、确认、精确patch和读回的专项回归，避免再次固化旧门禁语义。

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
