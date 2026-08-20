# rpi-cluster-gitops

Kubernetes manifests for the cluster, synced by Flux.

## Layout

```
clusters/my-cluster/   Flux's own Kustomizations
infrastructure/        Longhorn + monitoring - synced first, apps depend on it
apps/                  Home Assistant, web server, NAS, and the Zigbee/Matter/Thread bridges
```

Flux reconciles `infrastructure/` then `apps/` per the `dependsOn` chain in
`clusters/my-cluster/apps.yaml`. Push a change, Flux picks it up — no manual
apply needed for anything under here.

## Node scheduling

Two different pinning strategies are in use, and it matters which one a new
manifest needs:

- **`nodeSelector: {node-role: control-plane|worker}`** — for apps that just
  need "the beefier node" or "a worker," not a specific physical device.
  Labels are already set (`pi4=control-plane`, `pi3-1`/`pi3-2=worker`).
- **`nodeSelector: {kubernetes.io/hostname: <node>}`** — for apps tied to
  hardware physically plugged into one specific node (Bluetooth/Zigbee/Thread
  dongles). Two nodes can share a role without sharing peripherals, so a
  role-based selector isn't specific enough for these — see `otbr/`,
  `matter-server/`, `zigbee-bridge/` for the pattern.

StorageClasses (`fast-ssd`, `bulk-hdd`) are tagged onto Longhorn disks the
same way — `fast-ssd` is the SSD on `pi4`; `bulk-hdd` currently has no disk
tagged for it, since neither Pi 3 has a USB HDD attached yet. The `nas` app's
PVC will stay `Pending` (`unbound immediate PersistentVolumeClaims`) until
one is added and tagged.

## Bootstrap (already done — for reference / disaster recovery)

```
flux bootstrap github --owner=Miro-Ali-Akbar --repository=pi-cluster --path=rpi-cluster-gitops/clusters/my-cluster
```

Needs a write-scoped GitHub token (`GITHUB_TOKEN` env var) only for this
one-time command, run from an operator's workstation — never from
unattended cloud-init/ansible-pull on a node. Not needed again unless
re-bootstrapping from scratch; ongoing reconciliation only needs Flux's own
read-only deploy key.

## Known gaps

- No Prometheus Operator/Alertmanager installed — Longhorn's alerting
  manifest (`infrastructure/monitoring/longhorn-alerting.yaml`) is inert
  until one exists with a webhook receiver configured.
