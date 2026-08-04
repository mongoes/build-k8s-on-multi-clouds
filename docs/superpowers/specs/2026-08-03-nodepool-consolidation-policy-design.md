# NodePool Consolidation Policy Guard Design

## Goal

Provide a standalone, interactive Bash utility for EKS clusters that changes only Karpenter NodePools whose live `spec.disruption.consolidationPolicy` is `WhenEmptyOrUnderutilized` to `WhenEmpty`.

## Scope and boundaries

- Create `aws eks k8s/v1.35 eks v1.11 karpenter/set_nodepool_consolidation_policy.sh`.
- Do not modify or invoke `auto_build_nodepool.sh`.
- The utility reads only live `karpenter.sh/v1` NodePool resources from the currently selected kubectl context.
- It performs no action until the operator types the exact confirmation `yes`.
- It never restarts, deletes, drains, cordons, or modifies Nodes, NodeClaims, Pods, EC2NodeClasses, or any NodePool field other than the target policy.

## Workflow

1. Verify `kubectl` is installed and that `kubectl get nodepool -o json` succeeds.
2. Enumerate every NodePool and print its name plus current policy. An absent policy is printed as `<unset>`.
3. Select only NodePools whose policy is exactly `WhenEmptyOrUnderutilized`.
4. If the selection is empty, print a no-change result and exit successfully.
5. Print the proposed changes, then prompt once. Only `yes` authorizes execution; EOF or every other response cancels without changing the cluster.
6. Patch each selected NodePool using a merge patch containing only `spec.disruption.consolidationPolicy: WhenEmpty`.
7. Immediately read back each patched NodePool. A nodepool is successful only when its live policy equals `WhenEmpty`.
8. Print modified, failed, and skipped/cancelled outcomes. Return nonzero if an attempted patch or read-back verification fails.

## Interface

```bash
bash set_nodepool_consolidation_policy.sh
```

The script needs a working kubeconfig and RBAC permissions for `get` and `patch` on `nodepools.karpenter.sh`. It uses `kubectl` only; no `jq`, AWS CLI, or credentials are parsed or stored.

## Error handling

- Missing `kubectl`, unreadable NodePool API, malformed API output, and a failed patch/read-back end with a nonzero status and a named error.
- NodePools with `WhenEmpty`, another policy, or no policy are reported but never patched.
- The script uses `--type=merge` with a narrow JSON payload so concurrent updates to budgets, `consolidateAfter`, template, limits, and metadata are not overwritten.

## Verification matrix

| Scenario | Mock state/input | Expected result |
| --- | --- | --- |
| No eligible object | `WhenEmpty` plus `<unset>` | no patch; exit 0 |
| Operator cancellation | eligible object, input `no` | no patch; exit 0 |
| Confirmed update | eligible and noneligible objects, input `yes` | patch only eligible object; read-back `WhenEmpty`; exit 0 |
| Failed verification | patch command succeeds but read-back remains old value | named failure; nonzero exit |
