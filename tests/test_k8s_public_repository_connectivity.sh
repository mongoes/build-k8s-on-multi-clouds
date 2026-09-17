#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/k8sAvailCheck.sh"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -qF 'PUBLIC_REPOSITORY_URLS=(' "$script" || fail 'public repository URL list is missing'
grep -qF 'https://ta-repository.oss-accelerate.aliyuncs.com/' "$script" || fail 'TA package repository URL is missing'
grep -qF 'https://docker-ta.thinkingdata.cn/' "$script" || fail 'TA image repository URL is missing'
grep -qF -- '--proto "=https"' "$script" || fail 'curl probe must restrict the initial protocol to HTTPS'
grep -qF -- '--proto-redir "=https"' "$script" || fail 'curl probe must forbid redirect downgrade to HTTP'
! grep -qF 'http://ta-repository.oss-accelerate.aliyuncs.com/' "$script" || fail 'package repository must never fall back to HTTP'
! grep -qF 'http://docker-ta.thinkingdata.cn/' "$script" || fail 'image repository must never fall back to HTTP'

functions="$test_tmp/public-repository-functions.sh"
awk '
    /^# ==================== Pod访问数数公网仓库连通性检查/ { capture=1 }
    capture && /^# ==================== iptables放行Pod网段/ { exit }
    capture { print }
' "$script" >"$functions"
[[ -s "$functions" ]] || fail 'public repository probe functions are missing'

NAMESPACE=debug
ARTIFACT_DIR="$test_tmp/artifacts"
PUBLIC_REPOSITORY_URLS=(
    'https://ta-repository.oss-accelerate.aliyuncs.com/'
    'https://docker-ta.thinkingdata.cn/'
)
PUBLIC_REPOSITORY_CONNECT_TIMEOUT=5
PUBLIC_REPOSITORY_MAX_TIME=15
mkdir -p "$ARTIFACT_DIR"
RESULT_NAMES=()
RESULT_STATUS=()
RESULT_DETAIL=()
log_step() { :; }
log_info() { :; }
log_success() { :; }
log_warning() { :; }
log_error() { :; }
record_result() {
    RESULT_NAMES+=("$1")
    RESULT_STATUS+=("$2")
    RESULT_DETAIL+=("${3:-}")
}
serverless_record_result() { record_result "$@"; }
_ensure_artifact_dir() { mkdir -p "$ARTIFACT_DIR"; }

# shellcheck disable=SC1090
source "$functions"

classify_case() {
    local expected="$1" rc="$2" output="$3"
    if _classify_https_repository_probe "$output" "$rc"; then
        [[ "$expected" == PASS ]] || fail "classification unexpectedly passed: $output"
    else
        [[ "$expected" == FAIL ]] || fail "classification unexpectedly failed: $output"
    fi
}

classify_case PASS 0 'probe_client=curl;exit_code=0;http_code=200;url_effective=https://example.test/'
classify_case PASS 0 'probe_client=curl;exit_code=0;http_code=401;url_effective=https://example.test/v2/'
classify_case PASS 0 'probe_client=curl;exit_code=0;http_code=403;url_effective=https://example.test/'
classify_case PASS 0 'probe_client=wget;exit_code=8;http_code=404;url_effective=https://example.test/'
classify_case PASS 8 'probe_client=wget;exit_code=8;http_code=302;url_effective=https://example.test/;redirect_location=https://example.test/login'
classify_case PASS 8 'probe_client=wget;exit_code=8;http_code=302;url_effective=https://example.test/;redirect_location=/login'
classify_case FAIL 8 'probe_client=wget;exit_code=8;http_code=302;url_effective=https://example.test/;redirect_location=http://example.test/login'
classify_case FAIL 0 'probe_client=curl;exit_code=0;http_code=500;url_effective=https://example.test/'
classify_case FAIL 1 'probe_client=curl;exit_code=1;http_code=301;url_effective=http://example.test/'
classify_case FAIL 6 'probe_client=curl;exit_code=6;http_code=000;url_effective=https://example.test/'
classify_case FAIL 60 'probe_client=curl;exit_code=60;http_code=000;url_effective=https://example.test/'
classify_case FAIL 127 'probe_client=missing;exit_code=127;http_code=000;url_effective=https://example.test/'

MOCK_FAIL_POOL=''
MOCK_FAIL_REPOSITORY=''
_run_pod_https_repository_probe() {
    local pod="$1" url="$2"
    if [[ "$pod" == "$MOCK_FAIL_POOL" && "$url" == *"$MOCK_FAIL_REPOSITORY"* ]]; then
        printf 'probe_client=curl;exit_code=6;http_code=000;url_effective=%s\nDNS failure\n' "$url"
        return 6
    fi
    if [[ "$url" == *docker-ta* ]]; then
        printf 'probe_client=curl;exit_code=0;http_code=401;url_effective=%s\n' "$url"
    else
        printf 'probe_client=curl;exit_code=0;http_code=403;url_effective=%s\n' "$url"
    fi
}

PROBE_POD_NAME=()
PROBE_POD_IP=()
PROBE_READY_POOLS='1 2'
PROBE_POD_NAME[1]='pod-a'
PROBE_POD_NAME[2]='pod-b'
PROBE_POD_IP[1]='10.0.0.1'
PROBE_POD_IP[2]='10.0.0.2'

MOCK_FAIL_POOL='pod-b'
MOCK_FAIL_REPOSITORY='docker-ta'
run_standard_public_repository_checks || true
last_index=$((${#RESULT_DETAIL[@]} - 1))
[[ "${RESULT_STATUS[$last_index]}" == FAIL ]] || fail 'one failed repository in one ready pool must fail the Standard aggregate check'
[[ "${RESULT_DETAIL[$last_index]}" == *'2'* && "${RESULT_DETAIL[$last_index]}" == *'docker-ta.thinkingdata.cn'* ]] || fail 'Standard failure detail must identify the pool and repository'

RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
MOCK_FAIL_POOL=''
MOCK_FAIL_REPOSITORY=''
run_standard_public_repository_checks
last_index=$((${#RESULT_DETAIL[@]} - 1))
[[ "${RESULT_STATUS[$last_index]}" == PASS ]] || fail 'all repositories from all ready pools must pass'
[[ "${RESULT_DETAIL[$last_index]}" == *'2个就绪节点池'* && "${RESULT_DETAIL[$last_index]}" == *'2个HTTPS仓库'* ]] || fail 'Standard success must summarize pools and repositories'

RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
MOCK_FAIL_POOL='serverless-pod'
MOCK_FAIL_REPOSITORY='ta-repository'
run_serverless_public_repository_checks 'serverless-pod' 'eklet-a' || true
last_index=$((${#RESULT_DETAIL[@]} - 1))
[[ "${RESULT_STATUS[$last_index]}" == FAIL ]] || fail 'a failed repository must fail the Serverless-domain check'
[[ "${RESULT_NAMES[$last_index]}" == *'Serverless/Pod访问数数公网仓库连通性(eklet-a)'* ]] || fail 'Serverless result name must identify the virtual node'

find "$ARTIFACT_DIR" -type f -name 'https-repository-*.txt' | grep -q . || fail 'repository probes must preserve diagnostic artifacts'

echo 'PASS: K8S public repository connectivity regression assertions'
