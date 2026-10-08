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

- Hardware-tied apps select `kubernetes.io/hostname: <node>` (`otbr`, `zigbee-bridge` on `pi3-1`; `bt-proxy` on `pi4`).
- `phone-1` is tainted `node-type=phone:NoSchedule`. Apps there select it and tolerate the taint: Home Assistant, matter-server, Flux, monitoring, web-server, coredns-phone, the certbot and backup jobs.
- Home Assistant uses hostPaths on `phone-1` (`/var/lib/home-assistant/config`, `/etc/letsencrypt`), runs with `hostNetwork`, and reaches Zigbee (ser2net on `pi3-1`, port 6638), Matter (matter-server on `phone-1`, port 5580; it reaches the Thread devices through OTBR on `pi3-1`, and has no Bluetooth, so new devices cannot be commissioned over BLE from it) and Bluetooth (bt-proxy on `pi4`, port 6053) over the network.
- `bt-proxy`'s API is unauthenticated: `pi4` drops port 6053 from all but `phone-1` (`bt-proxy-firewall.service`, from `local.yml`).

## Storage

SeaweedFS with one StorageClass, `seaweedfs-storage`: volume servers pinned per disk (3 on `pi4`, 1 each on `pi3-1` and `pi3-2`), 2x rack-diverse replication, master on `pi3-1`, filer on `pi3-2` (metadata in `/mnt/longhorn-disk1/seaweedfs-filer`). The CSI driver runs on `pi4`, `pi3-2` and `phone-1`. A volume server refuses to start without `.real-disk-marker` at the root of its disk (`sudo touch /mnt/<disk>/.real-disk-marker`).

## Disaster recovery

1. Provision the nodes (`ansible-pull`; the phone with `phone-1/provision.sh`).
2. `flux bootstrap github --owner=Miro-Ali-Akbar --repository=pi-cluster --path=rpi-cluster-gitops/clusters/my-cluster` (needs a write-scoped `GITHUB_TOKEN`).
3. Create the decryption key: `kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=secrets/age.key`.
4. Restore HA's config on `phone-1` from backup; re-issue certificates with the one-time `certbot-issue*` jobs (deliberately in no kustomization).

Alternative to step 2: restore the K3s datastore from `/var/backups/cluster/pi4` on the phone.

## Host-level config (not managed by Flux, lost on reflash)

- **I/O throttle**, SSD nodes: cap `kubepods.slice` to 20 MB/s on `/dev/sda`.
  ```
  sudo mkdir -p /etc/systemd/system/kubepods.slice.d
  printf '[Slice]\nIOReadBandwidthMax=/dev/sda 20M\nIOWriteBandwidthMax=/dev/sda 20M\n' | sudo tee /etc/systemd/system/kubepods.slice.d/90-io-throttle.conf
  sudo systemctl daemon-reload
  ```
- **pi4: K3s datastore and containerd** are bind-mounted from the SSD (`/mnt/longhorn-disk1/k3s-server-db` onto `/var/lib/rancher/k3s/server/db`, `/mnt/longhorn-disk1/k3s-agent-containerd` onto `/var/lib/rancher/k3s/agent/containerd`) through `/etc/fstab`. The pre-move copies are `db.bak-sdcard` and `containerd.bak-sdcard`.
- **pi4: DuckDNS updater** (`duckdns-update.timer`).
- **pi4: WireGuard** (`/etc/wireguard/wg0.conf`, `thearmorassistant.duckdns.org:51820`) is the only remote path into the cluster. `wg0` is 10.200.0.1/29 and masquerades the VPN subnet onto the LAN, so a peer whose allowed IPs include `192.168.0.0/24` reaches every node. The workstation's NetworkManager connection `nas` (10.200.0.2) does: it autoconnects, keepalive 25, with routes at metric 700, so the LAN is used directly at home and the tunnel only when away. Its config is in the `guide-to-my-life` repo, not here.
- **pi4 and pi3-1: `/usr/local/sbin/cluster-backup-export`** and the phone's restricted root key, installed by `local.yml`.
