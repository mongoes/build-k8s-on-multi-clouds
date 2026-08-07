# Serverless K8S 模式识别与逐调度域检查 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely identify Alibaba/Tencent Standard-only, Serverless-only, and Hybrid clusters, then validate every Serverless scheduling domain without treating virtual capacity as production capacity.

**Architecture:** Add a JSON-backed mode detector to `k8sServerlessAvailCheck.sh`, with vendor-specific virtual-node classifiers and a refusal-to-guess outcome. Refactor probes to run per discovered virtual node using hostname selectors and platform-specific tolerations; isolate RWO/RWX volumes per domain and add optional cross-domain RWX verification. Keep standard-node behavior out of the Serverless script and return explicit dispatch data for the common entrypoint integration.

**Tech Stack:** Bash, kubectl JSONPath, existing shell regression harness.

## Global Constraints

- Never use virtual Node CPU, memory, Pod capacity, allocation percentages, InternalIP, or Lease as a capacity/health decision.
- Tencent and Alibaba vendor evidence conflicts, missing Nodes, and unknown standard-cloud identity return FAIL and perform no mode-specific mutation.
- Serverless temporary Pod is pinned with `kubernetes.io/hostname`; Tencent uses only the EKlet toleration and Alibaba tolerates only an observed Alibaba Virtual Kubelet taint.
- Serverless execution does not use NodePort, host networking, standard node-pool plans, or autoscaler conclusions.
- GPU/specification validation is opt-in and not part of default CPU health probes.

---

### Task 1: JSON-backed cloud and mode classifier

**Files:**
- Modify: `k8sServerlessAvailCheck.sh`
- Modify: `tests/test_k8s_serverless_avail_check.sh`

**Interfaces:**
- Produces `CLOUD_PLATFORM`, `CLUSTER_MODE`, `SERVERLESS_NODE_NAMES`, and `STANDARD_NODE_COUNT`.
- Adds `detect_cluster_mode()` returning non-zero for Unknown/Conflict.

- [ ] Write mock-node JSON fixtures for Tencent EKlet-only, Alibaba Virtual-Kubelet-only, each vendor Hybrid, Standard-only with two matching cloud signals, unknown Standard-only, and conflicting vendor signals.
- [ ] Add failing assertions for the exact classifications and assert no later probe function runs for Unknown/Conflict.
- [ ] Run `bash tests/test_k8s_serverless_avail_check.sh`; expect failure because the classifier is absent.
- [ ] Implement virtual-node predicates using only the strong labels/annotations from the approved design. Count all remaining nodes as standard. For Standard-only, require two matching auxiliary cloud signals; log all classification evidence.
- [ ] Re-run the regression; expect the classifier scenarios to pass.

### Task 2: Per-domain health gate and CPU probe

**Files:**
- Modify: `k8sServerlessAvailCheck.sh`
- Modify: `tests/test_k8s_serverless_avail_check.sh`

**Interfaces:**
- Adds `discover_serverless_domains()` returning records `name|vendor|zone|subnet|toleration`.
- Adds `check_serverless_domain_health(record)` and `apply_network_probe(record)`.

- [ ] Write failing fixture assertions: Tencent requires EKlet toleration and records subnet/AZ/IP count; Alibaba is recognized without a Lease and does not add toleration when none exists; both use hostname nodeSelector; virtual capacity is never inspected.
- [ ] Run the regression; expect the per-domain assertions to fail.
- [ ] Implement health gates for Ready, NetworkUnavailable, Unschedulable, Tencent available IP count, and exact platform taints. Generate one Deployment and ClusterIP Service per domain with unique labels and hostname selector.
- [ ] Refactor network checks to run inside each ready domain Probe and record one result per domain.
- [ ] Re-run the regression; expect all per-domain scenarios to pass.

### Task 3: Per-domain storage and cross-domain RWX

**Files:**
- Modify: `k8sServerlessAvailCheck.sh`
- Modify: `tests/test_k8s_serverless_avail_check.sh`

**Interfaces:**
- Extends `verify_storage_e2e(storage_class, access_mode, domain_record)`.
- Adds `verify_rwx_cross_domain(writer_record, reader_record)`.

- [ ] Write failing assertions requiring separate `te-disk` RWO PVC/Pod names per domain, separate RWX base checks, and a shared Writer/Reader RWX PVC only when two domains pass.
- [ ] Run the regression; expect failure because storage resources are globally named and no cross-domain path exists.
- [ ] Implement per-domain storage manifests pinned to each virtual node. Use a separate shared RWX PVC with Writer/Reader Pods pinned to different domains; verify a marker written by Writer is read by Reader.
- [ ] For a single ready domain, record cross-domain RWX as SKIP. On one domain failure, continue validating other domains and include failures in the summary.
- [ ] Re-run the regression; expect all storage scope and cross-domain assertions to pass.

### Task 4: Mode dispatch, docs, and verification

**Files:**
- Modify: `k8sServerlessAvailCheck.sh`
- Modify: `tests/test_k8s_serverless_avail_check.sh`
- Modify: `STATUS.md`
- Modify: `docs/decisions.md`

- [ ] Add failing tests for `Serverless-only`, `Hybrid`, and `Standard-only` dispatch summaries; unknown/conflict must terminate before resource creation.
- [ ] Implement dispatch output. Serverless-only uses only the Serverless path; Hybrid reports standard and Serverless branches separately and must not merge their pass/fail states; Standard-only exits this script with an explicit handoff to the standard checker.
- [ ] Update STATUS and decisions with recognition rules, virtual capacity exclusions, and required real-cloud regression cases.
- [ ] Run:

```bash
bash -n k8sServerlessAvailCheck.sh
bash -n tests/test_k8s_serverless_avail_check.sh
bash tests/test_k8s_serverless_avail_check.sh
git diff --check
```

Expected: every command exits 0.
- [ ] Inspect only this feature's changed lines before staging. Do not stage/commit if shared pre-existing changes overlap.
