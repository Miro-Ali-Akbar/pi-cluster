# rpi-cluster-gitops

Kubernetes manifests for the cluster, synced by Flux.

## Layout

```
clusters/my-cluster/   Flux's own Kustomizations
infrastructure/        seaweedfs (storage) + mount-watchdog - synced first
apps/                  home-assistant, nas, web-server, site-counters,
                       edge-proxy, otbr, matter-server, zigbee-bridge
```

Flux reconciles `infrastructure/` then `apps/`. Push a change, Flux picks it
up — no manual apply needed.

## Node scheduling

- **`nodeSelector: {node-role: control-plane|worker}`** — labels:
  `pi4=control-plane`, `pi3-1`/`pi3-2=worker`.
- **`nodeSelector: {kubernetes.io/hostname: <node>}`** — for apps tied to
  hardware on one specific node (Bluetooth/Zigbee/Thread dongles): `otbr/`,
  `matter-server/`, `zigbee-bridge/`.

Storage: SeaweedFS, one StorageClass (`seaweedfs-storage`), volume servers
pinned per-disk across pi4 (3 disks) and pi3-1/pi3-2 (1 disk each), 2x
rack-diverse replication.

## Bootstrap (disaster recovery only)

```
flux bootstrap github --owner=Miro-Ali-Akbar --repository=pi-cluster --path=rpi-cluster-gitops/clusters/my-cluster
```

Needs a write-scoped `GITHUB_TOKEN`, run once from a workstation. Ongoing
reconciliation only needs Flux's own deploy key.

## Host-level config (not managed by Flux, lost on reflash)

- **I/O throttle**, all 3 nodes, caps `kubepods.slice` to 20MB/s on `/dev/sda`:
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

- **`.real-disk-marker`** required at the root of every physical disk a
  SeaweedFS volume server uses; pods refuse to start without it
  (`infrastructure/seaweedfs/helm-release.yaml`):
  ```
  sudo touch /mnt/<disk-path>/.real-disk-marker
  ```

- **pi4: k3s datastore** bind-mounted from SSD:
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

- **pi4: containerd images/snapshots** bind-mounted from SSD:
  ```
  sudo systemctl stop k3s
  sudo mkdir -p /mnt/longhorn-disk1/k3s-agent-containerd
  sudo rsync -a /var/lib/rancher/k3s/agent/containerd/ /mnt/longhorn-disk1/k3s-agent-containerd/
  sudo mv /var/lib/rancher/k3s/agent/containerd /var/lib/rancher/k3s/agent/containerd.bak-sdcard
  sudo mkdir /var/lib/rancher/k3s/agent/containerd
  echo "/mnt/longhorn-disk1/k3s-agent-containerd /var/lib/rancher/k3s/agent/containerd none bind 0 0" | sudo tee -a /etc/fstab
  sudo mount -a
  sudo systemctl start k3s
  ```

- **WireGuard on pi4** (`/etc/wireguard/wg0.conf`,
  `thearmorassistant.duckdns.org:51820`) — the only remote path into the
  cluster off the home LAN. Config lives in the `guide-to-my-life` repo
  (`linux_enviorment/`), not here.

## Known gaps

- No cluster monitoring/alerting stack installed.
- `bulk-hdd`-tier storage not yet set up.
