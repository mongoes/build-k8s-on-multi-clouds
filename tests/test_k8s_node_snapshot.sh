#!/usr/bin/env bash
set -euo pipefail

if ((BASH_VERSINFO[0] < 4)); then
    echo "SKIP: node snapshot behavior requires the production baseline Bash>=4; current Bash=${BASH_VERSION}"
    exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/k8sAvailCheck.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Production mutation caught by this test:
# - removing the shared snapshot, or reintroducing any per-node kubectl read in either
#   node inspection stage, makes the API call count exceed one or hits the unexpected-call guard.
functions="$tmp_dir/node-snapshot-functions.sh"
sed -n '/^# ==================== 节点快照与节点池自动发现/,/^# ==================== Pod部署启动检查/p' "$script" |
    sed '$d' >"$functions"

grep -q '^refresh_node_snapshot()' "$functions" || fail 'shared node snapshot implementation is missing'

LOG_FILE="$tmp_dir/check.log"
ARTIFACT_DIR="$tmp_dir/artifacts"
mkdir -p "$ARTIFACT_DIR"
API_CALL_LOG="$tmp_dir/kubectl-calls.log"
UNEXPECTED_CALL_LOG="$tmp_dir/unexpected-kubectl.log"
RESULTS=""
GREEN="" YELLOW="" RED="" BOLD="" NC=""
SPEC_TOLERANCE="0.10"
STANDARD_NODES=()

log_step() { :; }
log_info() { printf '%s\n' "$*" >>"$LOG_FILE"; }
log_warning() { printf 'WARN %s\n' "$*" >>"$LOG_FILE"; }
log_error() { printf 'ERROR %s\n' "$*" >>"$LOG_FILE"; }
log_success() { printf 'PASS %s\n' "$*" >>"$LOG_FILE"; }
record_result() { RESULTS="${RESULTS}$1|$2|${3:-}"$'\n'; }
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }
_disp_width() { printf '%s\n' "${#1}"; }
_pad_disp() { printf '%-*s' "$2" "$1"; }
format_cpu() { printf '%s' "$1"; }
format_memory_for_platform() { printf '%s' "$2"; }
format_resource() { printf '%s' "$1"; }
get_expected_nodepools() { printf '%s\n' 'od-4c32g'; }

kubectl() {
    if [[ "$*" == 'get nodes -o json' ]]; then
        printf 'get nodes -o json\n' >>"$API_CALL_LOG"
        cat <<'EOF_NODES'
{
  "apiVersion": "v1",
  "items": [
    {
      "metadata": {
        "name": "node-a",
        "labels": {
          "node.k8s.te/nodepool-name": "od-4c32g",
          "node.k8s.te/billing-mode": "od",
          "kubernetes.io/arch": "amd64"
        }
      },
      "spec": {"taints": []},
      "status": {
        "capacity": {"cpu": "4", "memory": "33554432Ki", "ephemeral-storage": "100Gi"},
        "allocatable": {"cpu": "3900m", "memory": "32505856Ki", "ephemeral-storage": "90Gi"},
        "conditions": [{"type": "Ready", "status": "True"}]
      }
    },
    {
      "metadata": {
        "name": "node-b",
        "labels": {
          "node.k8s.te/nodepool-name": "od-4c32g",
          "node.k8s.te/billing-mode": "od",
          "kubernetes.io/arch": "amd64"
        }
      },
      "spec": {"taints": []},
      "status": {
        "capacity": {"cpu": "4", "memory": "33554432Ki", "ephemeral-storage": "100Gi"},
        "allocatable": {"cpu": "3900m", "memory": "32505856Ki", "ephemeral-storage": "90Gi"},
        "conditions": [{"type": "Ready", "status": "True"}]
      }
    },
    {
      "metadata": {
        "name": "virtual-node",
        "labels": {
          "node.kubernetes.io/instance-type": "eklet",
          "eks.tke.cloud.tencent.com/zone-name": "zone-a",
          "kubernetes.io/arch": "amd64"
        }
      },
      "spec": {"taints": [{"key": "eks.tke.cloud.tencent.com/eklet", "effect": "NoSchedule"}]},
      "status": {
        "capacity": {"cpu": "1000", "memory": "1Ti", "ephemeral-storage": "1Ti"},
        "allocatable": {"cpu": "1000", "memory": "1Ti", "ephemeral-storage": "1Ti"},
        "conditions": [{"type": "Ready", "status": "True"}]
      }
    }
  ]
}
EOF_NODES
        return 0
    fi
    printf '%s\n' "$*" >>"$UNEXPECTED_CALL_LOG"
    return 1
}

# shellcheck disable=SC1090
source "$functions"

refresh_node_snapshot || fail 'valid Nodes response must produce a reusable snapshot'
discover_and_check_nodes aws || fail 'homogeneous nodes from the snapshot must pass pool consistency checks'
check_nodepool_contract aws || fail 'matching pool labels and resources must pass contract checks'

[[ "$(wc -l <"$API_CALL_LOG" | tr -d ' ')" == 1 ]] || fail 'the two node stages must share exactly one Kubernetes Nodes API read'
[[ ! -s "$UNEXPECTED_CALL_LOG" ]] || {
    cat "$UNEXPECTED_CALL_LOG" >&2
    fail 'node stages must not issue per-node or secondary Nodes API reads'
}
[[ "${#NODE_SNAPSHOT_NAMES[@]}" == 3 ]] || fail 'snapshot must retain every node, including virtual nodes for evidence'
[[ "${NODE_SNAPSHOT_NODEPOOL[node-a]}" == 'od-4c32g' ]] || fail 'snapshot must retain the node pool label'
[[ "${NODE_SNAPSHOT_CAPACITY_CPU[node-b]}" == 4 ]] || fail 'snapshot must retain node capacity'
grep -q '节点快照采集完成: 节点=3, Kubernetes API调用=1' "$LOG_FILE" || fail 'snapshot metrics must disclose node count and API calls'
! grep -q 'virtual-node' "$LOG_FILE" || fail 'standard node inspection must exclude Serverless virtual nodes from the fresh snapshot'
grep -q '节点组契约校验性能: 节点快照复用=是, 新增Nodes API调用=0' "$LOG_FILE" || fail 'contract stage must disclose snapshot reuse'

echo 'PASS: shared node snapshot and API-call regression assertions'
