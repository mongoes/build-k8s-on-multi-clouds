# Serverless K8S Availability Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an independent Serverless Kubernetes availability checker that validates platform-aware network reachability and `te-disk`/`te-nfs` storage without node or node-pool assumptions.

**Architecture:** `k8sServerlessAvailCheck.sh` is a standalone Bash executable that creates labelled, selector-free probe resources in `debug`, records timestamped logs/artifacts, and cleans those resources on all exits. It preserves cloud-platform detection and feature entry points, but limits storage to the two named StorageClasses and eliminates node topology checks.

**Tech Stack:** Bash, kubectl, curl, Kubernetes Deployment/Service/PVC resources.

## Global Constraints

- Do not modify `k8sAvailCheck.sh`.
- Do not query nodes/node pools or reference `node.k8s.te/nodepool-name`.
- Generated Pod manifests must contain no `nodeSelector`, affinity, or topology-dependent assertions.
- Validate only `te-disk` (RWO) and `te-nfs` (RWX); do not run cross-node RWX checks.
- Keep cloud-platform identification and platform-feature-check entry points; AWS must not invoke `auto_build_nodepool.sh`.

---

### Task 1: Add executable contract regression test

**Files:**
- Create: `tests/test_k8s_serverless_avail_check.sh`
- Create later: `k8sServerlessAvailCheck.sh`

**Interfaces:**
- Consumes: `k8sServerlessAvailCheck.sh` as a text fixture.
- Produces: `bash tests/test_k8s_serverless_avail_check.sh` exits zero and prints `PASS: serverless availability-check regression assertions`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/k8sServerlessAvailCheck.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
[[ -f "$script" ]] || fail "serverless script must exist"
grep -qF 'detect_cloud_platform()' "$script" || fail "must detect cloud platform"
grep -qF 'check_platform_features()' "$script" || fail "must retain platform feature checks"
grep -qF 'verify_storage_e2e "te-disk"' "$script" || fail "must verify te-disk"
grep -qF 'verify_storage_e2e "te-nfs"' "$script" || fail "must verify te-nfs"
! grep -qE 'nodeSelector|kubectl get nodes|nodepool-name|auto_build_nodepool' "$script" || fail "must not depend on nodes or node pools"
echo 'PASS: serverless availability-check regression assertions'
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_k8s_serverless_avail_check.sh`

Expected: FAIL with `serverless script must exist`.

- [ ] **Step 3: Implement no production code in this task**

Leave the test failing until Task 2 introduces the executable.

- [ ] **Step 4: Commit the test with the implementation task**

Stage it with Task 2 because it intentionally fails in isolation.

### Task 2: Implement the selector-free Serverless checker

**Files:**
- Create: `k8sServerlessAvailCheck.sh`
- Modify: `tests/test_k8s_serverless_avail_check.sh`

**Interfaces:**
- Consumes: environment variables `NAMESPACE` (default `debug`), `APP_CONFIG_FILE` (default `/data/home/ta/base_server_ta/application.yml`), and `SERVERLESS_PROBE_IMAGE` (default ThinkData nginx image).
- Produces: `main()` that records a summary for platform checks, selector-free network probe checks, `te-disk` RWO, and `te-nfs` RWX, then cleans temporary resources.

- [ ] **Step 1: Extend the failing test with required manifests and cleanup checks**

Add these assertions before the success echo:

```bash
grep -qF 'kind: Deployment' "$script" || fail "must create a network probe deployment"
grep -qF 'kind: Service' "$script" || fail "must create a ClusterIP service"
grep -qF 'app: serverless-avail-probe' "$script" || fail "probe resources need an exclusive label"
grep -qF 'kubectl delete deployment' "$script" || fail "must clean deployments"
grep -qF 'kubectl delete service' "$script" || fail "must clean services"
grep -qF 'kubectl delete pvc' "$script" || fail "must clean PVCs"
grep -qF 'ReadWriteOnce' "$script" || fail "te-disk must use RWO"
grep -qF 'ReadWriteMany' "$script" || fail "te-nfs must use RWX"
! grep -qF 'verify_nfs_rwx_cross_node' "$script" || fail "must not assert cross-node RWX"
```

- [ ] **Step 2: Run the test to verify it fails because the script is absent**

Run: `bash tests/test_k8s_serverless_avail_check.sh`

Expected: FAIL with `serverless script must exist`.

- [ ] **Step 3: Write the minimal standalone implementation**

Implement these exact public functions and flow:

```bash
detect_cloud_platform() { kubectl version -o json 2>/dev/null; }
check_platform_features() { :; }
apply_network_probe() { kubectl apply -f "$network_manifest"; }
verify_storage_e2e() { local storage_class="$1" access_mode="$2"; :; }
cleanup_on_exit() { :; }
main() { detect_cloud_platform; check_platform_features; apply_network_probe; verify_storage_e2e "te-disk" "ReadWriteOnce"; verify_storage_e2e "te-nfs" "ReadWriteMany"; }
```

Replace the placeholder bodies with platform-safe commands: platform detection must use Kubernetes version and `kubectl cluster-info`, not node reads; `check_platform_features` may inspect namespaced platform controllers but must not invoke node-pool tooling. `apply_network_probe` writes Deployment and ClusterIP Service manifests with only labels, containers, readiness probe, and no scheduling stanza. `verify_storage_e2e` writes a PVC and a single mounted test Pod, waits for Bound/Ready, and uses `kubectl exec` to write/read a marker. `cleanup_on_exit` deletes only resources bearing the exclusive `app=serverless-avail-probe` label and the two exact test PVC names.

- [ ] **Step 4: Run syntax and regression tests to verify green**

Run: `bash -n k8sServerlessAvailCheck.sh && bash tests/test_k8s_serverless_avail_check.sh`

Expected: exit 0 and `PASS: serverless availability-check regression assertions`.

- [ ] **Step 5: Commit implementation and test**

```bash
git add k8sServerlessAvailCheck.sh tests/test_k8s_serverless_avail_check.sh docs/superpowers/plans/2026-07-17-serverless-k8s-availability.md
git commit -m "feat: add serverless k8s availability check"
```

### Task 3: Verify repository-safe deliverable

**Files:**
- Verify: `k8sServerlessAvailCheck.sh`
- Verify: `tests/test_k8s_serverless_avail_check.sh`

**Interfaces:**
- Consumes: completed script and regression test.
- Produces: evidence that the deliverable parses, satisfies the static Serverless contract, and does not introduce whitespace errors.

- [ ] **Step 1: Run complete static verification**

Run: `bash -n k8sServerlessAvailCheck.sh && bash tests/test_k8s_serverless_avail_check.sh && git diff --check HEAD^ HEAD`

Expected: exit 0 and `PASS: serverless availability-check regression assertions`.

- [ ] **Step 2: Inspect changed-file status**

Run: `git status --short`

Expected: only the new script, test, plan, and pre-existing unrelated untracked files are reported; `k8sAvailCheck.sh` remains unchanged.
