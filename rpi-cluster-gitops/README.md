# rpi-cluster-gitops

Kubernetes manifests for the Raspberry Pi K3s cluster described in
[`../plan.md`](../plan.md), synced by Flux CD (plan.md step 5).

## Layout

```
clusters/my-cluster/   # Flux Kustomizations created by `flux bootstrap` (step 5)
infrastructure/        # Longhorn + monitoring (synced first — apps depend on it)
apps/                  # Home Assistant, web server, NAS (fast-ssd / bulk-hdd)
```

## Bootstrap

Run once, from an operator's workstation — never from unattended cloud-init
(see plan.md step 5 for why the write-scoped GitHub token must not live on
any node):

```
flux bootstrap github --owner=<your-username> --repository=rpi-cluster-gitops --path=clusters/my-cluster
```

This populates `clusters/my-cluster/flux-system/` (Flux's own manifests) and
starts reconciling `infrastructure/` then `apps/` per the `dependsOn` chain in
`clusters/my-cluster/apps.yaml`.

## Node labeling required before first sync

The app manifests use `nodeSelector: {node-role: control-plane|worker}` and the
StorageClasses use `nodeSelector`/`diskSelector` of `fast-ssd`/`bulk-hdd`.
Label nodes accordingly right after they join the cluster:

```
kubectl label node <pi4-node-name> node-role=control-plane
kubectl label node <pi3-node-1> node-role=worker
kubectl label node <pi3-node-2> node-role=worker
```

And tag Longhorn disks with matching labels via `kubectl label node ...
node.longhorn.io/create-default-disk=true` plus the Longhorn UI/CRDs for the
`fast-ssd` / `bulk-hdd` disk tags referenced in
`infrastructure/longhorn/storage-classes.yaml`.

## Known gaps to fill in for your environment

- Longhorn alerting (`infrastructure/monitoring/longhorn-alerting.yaml`) needs
  a Prometheus Operator install and an Alertmanager receiver
  (Discord/Telegram/SMTP webhook) — not included here, add as a
  SOPS/sealed-secret when you have the webhook credentials.
- Chart/image versions (`longhorn: 1.7.x`, `nginx:stable`, etc.) are pinned
  loosely — pin exact versions once you've validated the stack.
