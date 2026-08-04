# GKE `te-nfs` 128Gi Multishare Design

## Goal

Keep one GKE StorageClass named `te-nfs`, configured as Filestore Enterprise Multishare with a 128Gi maximum share size and automatic VPC discovery from the GCE execution host.

## Final StorageClass contract

```yaml
metadata:
  name: te-nfs
parameters:
  tier: enterprise
  multishare: "true"
  instance-storageclass-label: te-nfs
  max-volume-size: "128Gi"
  network: "projects/<PROJECT_ID>/networks/<NETWORK_NAME>"
```

`te-nfs-128` is not created or maintained. The 128Gi limit permits up to 80 shares per Enterprise Multishare instance, while keeping the public StorageClass name and reuse label `te-nfs`.

## Network source and failure behavior

The script obtains only `instance/network-interfaces/0/network` from the GCE metadata server. It validates the returned resource path against `projects/<project>/networks/<network>` and injects that value into the GKE manifest.

If metadata is unavailable or invalid, the script records the `te-nfs` readiness check as `FAIL`, prints a red error asking the operator to confirm the network in Google Cloud Console, and prints a complete manual YAML template whose `network` value is an explicit placeholder. It does not fall back to `default` and does not call `kubectl apply`.

## Scope

Keep the existing Enterprise tier, Retain policy, Immediate binding, expansion setting, and NFS mount options. Update the repository YAML, script-rendered YAML, regression test, GKE documentation, project status, decision log, and availability-check ledger together.
