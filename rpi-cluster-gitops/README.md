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

- **pi4's k3s datastore moved off the SD card, onto SSD** - k3s's own
  SQLite-backed datastore (`/var/lib/rancher/k3s/server/db`) lived on
  pi4's SD card by default. That card's write latency degrades badly
  under load (a recurring root cause: leader-election sidecars on the
  CSI driver would fail to renew their lease in time - "context deadline
  exceeded" - and crash-loop, which in turn left long-running pods like
  nas-samba with stale mount references, requiring a manual pod recreate
  each time). Neither the I/O throttle above (a different device,
  `/dev/sda`) nor `kube-reserved`/`system-reserved` (CPU/memory only)
  protected against this, since it's specifically SD-card I/O latency
  hurting k3s's own critical path. Fixed by relocating the real data to
  `/mnt/longhorn-disk1/k3s-server-db` (SSD, lightly used) and bind-mounting
  it back over the original path via `/etc/fstab`, so k3s's own
  config/systemd unit needed no changes. The pre-move SD-card copy is kept
  at `/var/lib/rancher/k3s/server/db.bak-sdcard` as a rollback safety net -
  safe to delete once this has proven stable for a while. To reproduce on
  a reflashed pi4:
  ```
  sudo systemctl stop k3s
  sudo mkdir -p /mnt/longhorn-disk1/k3s-server-db
  sudo rsync -a /var/lib/rancher/k3s/server/db/ /mnt/longhorn-disk1/k3s-server-db/
  sudo chmod 0700 /mnt/longhorn-disk1/k3s-server-db
  sudo mv /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/db.bak-sdcard
  sudo mkdir /var/lib/rancher/k3s/server/db && sudo chmod 0700 /var/lib/rancher/k3s/server/db
  echo "/mnt/longhorn-disk1/k3s-server-db /var/lib/rancher/k3s/server/db none bind 0 0" | sudo tee -a /etc/fstab
  sudo mount -a
  sudo systemctl start k3s
  ```

- **pi4's containerd images/snapshots moved off the SD card, onto SSD** -
  `/var/lib/rancher/k3s/agent/containerd` (pulled images, overlayfs
  snapshots, per-container writable layers) grew to ~5GB and, combined
  with everything else on a 29GB SD card, pushed the root filesystem to
  94% full. That triggered kubelet's `FreeDiskSpaceFailed` node condition
  repeatedly, which killed running pods (including nas-samba) under disk
  pressure - a second, independent way this SD card was undersized for
  the cluster's actual state, on top of the datastore I/O-latency issue
  above. Same fix pattern: relocated to `/mnt/longhorn-disk1/k3s-agent-containerd`
  (SSD) and bind-mounted back via `/etc/fstab`. Unlike the datastore move,
  the pre-move SD-card copy was deleted immediately rather than kept as a
  rollback safety net, since the whole point was reclaiming space - the
  data is just pulled container images and container layers, trivially
  re-creatable by k3s/containerd from scratch if ever needed. To reproduce
  on a reflashed pi4:
  ```
  sudo systemctl stop k3s
  sudo mkdir -p /mnt/longhorn-disk1/k3s-agent-containerd
  sudo rsync -a /var/lib/rancher/k3s/agent/containerd/ /mnt/longhorn-disk1/k3s-agent-containerd/
  sudo mv /var/lib/rancher/k3s/agent/containerd /var/lib/rancher/k3s/agent/containerd.bak-sdcard
  sudo mkdir /var/lib/rancher/k3s/agent/containerd
  echo "/mnt/longhorn-disk1/k3s-agent-containerd /var/lib/rancher/k3s/agent/containerd none bind 0 0" | sudo tee -a /etc/fstab
  sudo mount -a
  sudo systemctl start k3s
  # once confirmed healthy:
  sudo rm -rf /var/lib/rancher/k3s/agent/containerd.bak-sdcard
  ```

- **pi4 also runs a WireGuard server** (`/etc/wireguard/wg0.conf`,
  `thearmorassistant.duckdns.org:51820`) for remote access when off the
  home LAN - unrelated to k3s, but worth knowing about since it's the
  only remote path into the cluster when away from home, and it was
  found to be silently down (no handshake, 100% packet loss) during an
  otherwise-unrelated pi3-1 instability incident. Originally scoped to
  NAS-only access (`10.200.0.0/24`, no LAN routing); being widened to
  route the full `192.168.0.0/24` LAN (so remote SSH to any node works,
  not just reaching the NAS share) and shrunk to a `10.200.0.0/29` to
  avoid colliding with other VPNs. Setup, the widening script, and the
  client config live in the separate `guide-to-my-life` repo
  (`linux_enviorment/setup_wireguard.sh`, `enable_wireguard_lan_access.sh`,
  `wireguard_nas.md`) since it's personal remote-access tooling, not
  cluster config - documented here only as a pointer, since "is my
  remote access to this cluster currently working" is directly relevant
  to anyone debugging this repo remotely.

## Known gaps

- No Prometheus Operator/Alertmanager installed — Longhorn's alerting
  manifest (`infrastructure/monitoring/longhorn-alerting.yaml`) is inert
  until one exists with a webhook receiver configured.
