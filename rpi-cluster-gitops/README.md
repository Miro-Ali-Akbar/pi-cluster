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

## Host-level configuration (not managed by Flux)

Flux only manages what's inside Kubernetes - some fixes live on the node's
own OS instead and would be silently lost if a node were reflashed:

- **Container I/O bandwidth cap** - all three nodes (pi4, pi3-1, pi3-2) have
  a systemd drop-in at `/etc/systemd/system/kubepods.slice.d/90-io-throttle.conf`
  capping `kubepods.slice` (every container's cgroup) to 20MB/s read+write on
  `/dev/sda`. Added after a bulk NAS transfer repeatedly drove a node's load
  average past 30 and crashed the SeaweedFS mount process (backend writes
  were timing out under I/O contention) - this caps throughput at the
  cluster level so no single transfer can saturate a node's disk bus,
  regardless of which pod is doing the writing or what app-level throttling
  (concurrentWriters, resource limits) is or isn't in place. To reproduce on
  a reflashed node:
  ```
  sudo mkdir -p /etc/systemd/system/kubepods.slice.d
  cat <<EOF | sudo tee /etc/systemd/system/kubepods.slice.d/90-io-throttle.conf
  [Slice]
  IOReadBandwidthMax=/dev/sda 20M
  IOWriteBandwidthMax=/dev/sda 20M
  EOF
  sudo systemctl daemon-reload
  sudo systemctl set-property kubepods.slice IOReadBandwidthMax="/dev/sda 20M" IOWriteBandwidthMax="/dev/sda 20M" --runtime
  ```

- **`.real-disk-marker` files** - a `.real-disk-marker` file must exist at
  the root of every physical disk SeaweedFS's volume servers use
  (`/mnt/longhorn-disk1`, `/mnt/longhorn-disk2`, `/mnt/fast-storage` on
  whichever nodes have them). Added after a USB SSD disconnected from pi4
  at runtime and Kubernetes' hostPath silently created an empty directory
  on the SD card in its place - the volume server kept running and wrote
  real NAS/web-server data there for hours with nothing visibly wrong,
  until the SD card itself buckled under the unexpected load and took
  down the node's own k3s API server. Every volume server pod now has a
  `verify-real-disk` initContainer (`infrastructure/seaweedfs/helm-release.yaml`)
  that refuses to start if this marker is missing, on the theory that a
  freshly-created fallback directory won't have it. To reproduce on a
  reflashed node or a newly-added disk:
  ```
  sudo touch /mnt/<disk-path>/.real-disk-marker
  ```

## Known gaps

- No Prometheus Operator/Alertmanager installed — Longhorn's alerting
  manifest (`infrastructure/monitoring/longhorn-alerting.yaml`) is inert
  until one exists with a webhook receiver configured.
