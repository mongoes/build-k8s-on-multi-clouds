# MySQL Probe Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve nginx-based MySQL probing while making failures diagnosable and preventing tool errors from masquerading as network failures.

**Architecture:** Add a generic FAIL-summary writer at `record_result`, plus a MySQL-specific diagnostic capture helper that runs only after a failed nginx-Pod TCP probe. The existing nginx image and target extraction remain unchanged; TCP probing uses curl `telnet://`, and latency uses curl `%{time_connect}` only after connectivity succeeds.

**Tech Stack:** Bash, kubectl exec, existing shell regression harness.

## Global Constraints

- Do not add a container, image, service, external tool, cloud API, or JDBC port validation.
- Keep nginx as the probe container; use curl `telnet://` for TCP probing and curl `%{time_connect}` for latency.
- All FAIL results write a summary under `ARTIFACT_DIR`; K8s failures retain generated YAML and diagnostics.
- MySQL failure evidence includes command, exit code, stdout/stderr, curl availability, DNS configuration, and target lookup.
- Latency is not executed after a TCP connectivity failure for the same Pod/target.

---

### Task 1: Add red regression coverage

**Files:**
- Modify: `tests/test_k8s_avail_check.sh`
- Test: `tests/test_k8s_avail_check.sh`

- [ ] Add assertions requiring `capture_mysql_probe_diagnostics`, `write_failure_artifact`, and the diagnostic fields `command -v curl`, `/etc/resolv.conf`, `stdout`, `stderr`, and `exit_code`.
- [ ] Mock a failed MySQL exec, invoke the diagnostic helper, and assert an artifact file is created with the target and command failure output.
- [ ] Run `bash tests/test_k8s_avail_check.sh`; expect failure because the helpers do not yet exist.

### Task 2: Implement diagnostic capture and no-false-cause reporting

**Files:**
- Modify: `k8sAvailCheck.sh:201-230,1795-1850`
- Modify: `tests/test_k8s_avail_check.sh`

- [ ] Implement `write_failure_artifact(check_name, detail)` using a sanitized filename under `ARTIFACT_DIR`; call it from `record_result` only for `FAIL`.
- [ ] Implement `capture_mysql_probe_diagnostics(pool, target)` to write one text file before cleanup. It must run unredirected `kubectl exec` commands, capture each output and exit status, and include Pod metadata, target, raw curl command, curl availability, resolv.conf, hosts, optional `getent hosts`, and curl TCP result.
- [ ] Change MySQL connectivity failure text to point to the captured artifact and distinguish missing `curl` from DNS/TCP failure where evidence proves it.
- [ ] Run `bash tests/test_k8s_avail_check.sh`; expect PASS.

### Task 3: Gate latency and final verification

**Files:**
- Modify: `k8sAvailCheck.sh:1908-1928`
- Modify: `tests/test_k8s_avail_check.sh`
- Modify: `docs/superpowers/specs/2026-07-16-mysql-probe-diagnostics-design.md`
- Modify: `docs/superpowers/plans/2026-07-16-mysql-probe-diagnostics.md`

- [x] In the per-pool target loop, run latency only when TCP connectivity succeeded; otherwise record `未执行（复用连通性失败诊断）` for that pool/target without issuing a latency exec.
- [x] Add a mock counter test proving failed TCP does not call the latency helper.
- [x] Run `bash -n k8sAvailCheck.sh`, `bash tests/test_k8s_avail_check.sh`, and `git diff --check`; expect exit 0 and `PASS: availability-check regression assertions`.
- [ ] Stage only the script, test, specification, and plan; commit `fix: capture mysql probe diagnostics`. Do not push without explicit authorization.


### Follow-up: executor hosts inheritance (completed)

- [x] Generate `np-probe` `spec.hostAliases` from valid non-loopback executor `/etc/hosts` entries; filter localhost and loopback mappings, retain first hostname mapping, and warn on conflicts.
- [x] Strictly validate IPv4/IPv6 and hostname fields before YAML output; reject malformed or injection-shaped values.
- [x] Inline precomputed aliases in the Deployment manifest and verify the generated YAML contains aliases rather than command-substitution text.
- [x] Preserve original JDBC hostnames for TCP/latency and capture Pod hosts/DNS evidence in MySQL diagnostics.


MySQL TCP 与延迟均使用 curl `telnet://`；延迟样本通过 `%{time_connect}` 返回秒值并在脚本端转换为毫秒。
