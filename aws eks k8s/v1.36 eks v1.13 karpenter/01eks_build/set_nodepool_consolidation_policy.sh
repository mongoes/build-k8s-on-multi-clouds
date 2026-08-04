#!/usr/bin/env bash
# 将 Karpenter NodePool 的 WhenEmptyOrUnderutilized 收敛策略安全改为 WhenEmpty。
# 仅在操作者输入完整 yes 后执行字段级 patch，不重启或删除任何 Kubernetes 资源。

set -u -o pipefail

TARGET_POLICY='WhenEmptyOrUnderutilized'
REPLACEMENT_POLICY='WhenEmpty'

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

main() {
  command -v kubectl >/dev/null 2>&1 || fail 'kubectl is not installed or not in PATH.'

  local nodepool_lines
  if ! nodepool_lines="$(kubectl get nodepool -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.disruption.consolidationPolicy}{"\n"}{end}')"; then
    fail 'Unable to list NodePool resources. Check the current kubeconfig and RBAC get permission for nodepools.karpenter.sh.'
  fi

  if [[ -z "$nodepool_lines" ]]; then
    echo 'No NodePool resources found. No changes made.'
    return 0
  fi

  local -a candidates=()
  local name policy display_policy
  echo 'Current NodePool consolidation policies:'
  while IFS=$'\t' read -r name policy; do
    [[ -n "$name" ]] || continue
    display_policy="${policy:-<unset>}"
    printf '%s: %s\n' "$name" "$display_policy"
    if [[ "$policy" == "$TARGET_POLICY" ]]; then
      candidates+=("$name")
    fi
  done <<<"$nodepool_lines"

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "No NodePool uses $TARGET_POLICY. No changes made."
    return 0
  fi

  echo
  echo "The following NodePools will change from $TARGET_POLICY to $REPLACEMENT_POLICY:"
  for name in "${candidates[@]}"; do
    echo "will change: $name"
  done

  local confirmation=''
  read -r -p 'Type yes to apply these changes: ' confirmation || confirmation=''
  if [[ "$confirmation" != 'yes' ]]; then
    echo 'Cancelled. No NodePool was modified.'
    return 0
  fi

  local modified=0
  local failed=0
  local actual_policy
  echo
  for name in "${candidates[@]}"; do
    if ! kubectl patch nodepool "$name" --type=merge \
      -p '{"spec":{"disruption":{"consolidationPolicy":"WhenEmpty"}}}'; then
      echo "Failed: $name (patch command failed)" >&2
      failed=$((failed + 1))
      continue
    fi

    if ! actual_policy="$(kubectl get nodepool "$name" -o jsonpath='{.spec.disruption.consolidationPolicy}')"; then
      echo "Failed: $name (unable to read back consolidationPolicy)" >&2
      failed=$((failed + 1))
      continue
    fi

    if [[ "$actual_policy" == "$REPLACEMENT_POLICY" ]]; then
      echo "Modified: $name ($TARGET_POLICY -> $REPLACEMENT_POLICY)"
      modified=$((modified + 1))
    else
      echo "Failed: $name (read-back value: ${actual_policy:-<unset>})" >&2
      failed=$((failed + 1))
    fi
  done

  echo
  echo "Summary: modified=$modified failed=$failed skipped=0"
  [[ "$failed" -eq 0 ]]
}

main "$@"
