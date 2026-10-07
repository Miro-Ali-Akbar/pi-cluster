# rpi-cluster-gitops

Kubernetes manifests, synced by Flux.

```
clusters/my-cluster/   Flux Kustomizations (apps, infrastructure) and controller patches
infrastructure/        seaweedfs (storage), mount-watchdog, coredns-phone - applied first
apps/                  home-assistant, bt-proxy, monitoring, nas, web-server, site-counters,
                       edge-proxy, otbr, matter-server, zigbee-bridge
```

`apps` depends on `infrastructure`. Both decrypt `*.sops.yaml` with the `sops-age` Secret.
The Flux controllers run on `phone-1` (`clusters/my-cluster/flux-system/on-phone-patch.yaml`).

## Scheduling

- Hardware-tied apps select `kubernetes.io/hostname: <node>` (`otbr`, `matter-server`, `zigbee-bridge` on `pi3-1`; `bt-proxy` on `pi4`).
- `phone-1` is tainted `node-type=phone:NoSchedule`. Apps there select it and tolerate the taint: Home Assistant, Flux, monitoring, web-server, coredns-phone, the certbot and backup jobs.
- Home Assistant uses hostPaths on `phone-1` (`/var/lib/home-assistant/config`, `/etc/letsencrypt`), runs with `hostNetwork`, and reaches Zigbee (ser2net on `pi3-1`, port 6638), Matter (`pi3-1`, port 5580) and Bluetooth (bt-proxy on `pi4`, port 6053) over the network.
- `bt-proxy`'s API has no authentication: `pi4` drops connections to port 6053 from any address but `phone-1` (`bt-proxy-firewall.service`, installed by `local.yml`).

## Storage

SeaweedFS with one StorageClass, `seaweedfs-storage`: volume servers pinned per disk (3 on `pi4`, 1 each on `pi3-1` and `pi3-2`), 2x rack-diverse replication, master and filer on `pi3-1`. The CSI driver runs on `pi4`, `pi3-2` and `phone-1`. A volume server refuses to start without `.real-disk-marker` at the root of its disk (`sudo touch /mnt/<disk>/.real-disk-marker`).

## Disaster recovery

1. Provision the nodes (`ansible-pull`; the phone with `phone-1/provision.sh`).
2. `flux bootstrap github --owner=Miro-Ali-Akbar --repository=pi-cluster --path=rpi-cluster-gitops/clusters/my-cluster` (needs a write-scoped `GITHUB_TOKEN`).
3. Create the decryption key: `kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=secrets/age.key`.
4. Restore Home Assistant's config on `phone-1` from its backup, and re-issue certificates with the one-time `certbot-issue*` jobs (not in a kustomization on purpose).

The K3s datastore can instead be restored from the phone's backup in `/var/backups/cluster/pi4`.

## Host-level config (not managed by Flux, lost on reflash)

- **I/O throttle**, SSD nodes: cap `kubepods.slice` to 20 MB/s on `/dev/sda`.
  ```
  sudo mkdir -p /etc/systemd/system/kubepods.slice.d
  printf '[Slice]\nIOReadBandwidthMax=/dev/sda 20M\nIOWriteBandwidthMax=/dev/sda 20M\n' | sudo tee /etc/systemd/system/kubepods.slice.d/90-io-throttle.conf
  sudo systemctl daemon-reload
  ```
- **pi4: K3s datastore and containerd** are bind-mounted from the SSD (`/mnt/longhorn-disk1/k3s-server-db` onto `/var/lib/rancher/k3s/server/db`, `/mnt/longhorn-disk1/k3s-agent-containerd` onto `/var/lib/rancher/k3s/agent/containerd`) through `/etc/fstab`. The pre-move copies are `db.bak-sdcard` and `containerd.bak-sdcard`.
- **pi4: WireGuard** (`/etc/wireguard/wg0.conf`, `thearmorassistant.duckdns.org:51820`) is the only remote path into the cluster. Its config is in the `guide-to-my-life` repo, not here.
- **pi4 and pi3-1: `/usr/local/sbin/cluster-backup-export`** and the phone's restricted root key, installed by `local.yml`.
