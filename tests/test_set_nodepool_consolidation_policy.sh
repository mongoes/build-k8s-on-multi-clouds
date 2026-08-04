#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/aws eks k8s/v1.36 eks v1.13 karpenter/01eks_build/set_nodepool_consolidation_policy.sh"
tmp_dir="$(mktemp -d)"
mock_bin="$tmp_dir/bin"
calls="$tmp_dir/kubectl.calls"
state="$tmp_dir/nodepools.state"
readback_override="$tmp_dir/readback.override"
mkdir -p "$mock_bin"
trap 'rm -rf "$tmp_dir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain: $needle"
}

write_state() {
  printf '%s\n' \
    'risky-pool=WhenEmptyOrUnderutilized' \
    'safe-pool=WhenEmpty' \
    'custom-pool=Never' \
    'unset-pool=' >"$state"
  : >"$calls"
  : >"$readback_override"
}

cat >"$mock_bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$MOCK_CALLS"

get_policy() {
  local name="$1"
  local source="$MOCK_READBACK_OVERRIDE"
  local value
  value="$(awk -F= -v name="$name" '$1 == name {print $2; exit}' "$source")"
  if [[ -z "$value" ]] && ! grep -q "^${name}=$" "$source"; then
    value="$(awk -F= -v name="$name" '$1 == name {print $2; exit}' "$MOCK_STATE")"
  fi
  printf '%s' "$value"
}

if [[ "$1 $2" == 'get nodepool' ]]; then
  if [[ $# -ge 4 && "$3" == '-o' ]]; then
    while IFS='=' read -r name policy; do
      printf '%s\t%s\n' "$name" "$policy"
    done <"$MOCK_STATE"
    exit 0
  fi

  if [[ $# -ge 5 && "$4" == '-o' ]]; then
    get_policy "$3"
    exit 0
  fi
fi

if [[ "$1 $2" == 'patch nodepool' ]]; then
  name="$3"
  grep -q -- '--type=merge' <<<"$*"
  grep -q -- '"consolidationPolicy":"WhenEmpty"' <<<"$*"
  awk -F= -v name="$name" 'BEGIN {OFS="="} $1 == name {$2="WhenEmpty"} {print}' "$MOCK_STATE" >"$MOCK_STATE.next"
  mv "$MOCK_STATE.next" "$MOCK_STATE"
  exit 0
fi

echo "unexpected kubectl invocation: $*" >&2
exit 99
MOCK
chmod +x "$mock_bin/kubectl"

run_script() {
  local input="$1"
  printf '%s\n' "$input" | \
    MOCK_CALLS="$calls" MOCK_STATE="$state" MOCK_READBACK_OVERRIDE="$readback_override" \
    PATH="$mock_bin:$PATH" bash "$script"
}

[[ -f "$script" ]] || fail "nodepool consolidation policy script must exist"

printf '%s\n' 'safe-pool=WhenEmpty' 'custom-pool=Never' >"$state"
: >"$calls"
no_match_output="$(run_script '')"
assert_contains "$no_match_output" 'No NodePool uses WhenEmptyOrUnderutilized. No changes made.'
assert_not_contains "$(cat "$calls")" 'patch nodepool'

write_state
cancel_output="$(run_script 'no')"
assert_contains "$cancel_output" 'will change: risky-pool'
assert_contains "$cancel_output" 'Cancelled. No NodePool was modified.'
assert_not_contains "$(cat "$calls")" 'patch nodepool'

write_state
confirmed_output="$(run_script 'yes')"
assert_contains "$confirmed_output" 'Modified: risky-pool'
assert_contains "$(cat "$calls")" 'patch nodepool risky-pool --type=merge'
assert_not_contains "$(cat "$calls")" 'patch nodepool safe-pool'
assert_not_contains "$(cat "$calls")" 'patch nodepool custom-pool'

write_state
printf '%s\n' 'risky-pool=WhenEmptyOrUnderutilized' >"$readback_override"
if run_script 'yes' >/dev/null 2>&1; then
  fail 'script must fail when read-back policy remains WhenEmptyOrUnderutilized'
fi

echo 'PASS: nodepool consolidation policy regression assertions'
