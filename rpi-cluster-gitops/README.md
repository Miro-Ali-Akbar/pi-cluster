# rpi-cluster-gitops

Kubernetes manifests, synced by Flux.

```
clusters/my-cluster/   Flux Kustomizations (apps, infrastructure) and controller patches
infrastructure/        seaweedfs (storage), mount-watchdog, coredns-phone - applied first
apps/                  home-assistant, bt-proxy, monitoring, nas, web-server, site-counters,
                       edge-proxy, otbr, matter-server, zigbee-bridge, mqtt, website-ssh, p2p-relay
```

`apps` depends on `infrastructure`. Both decrypt `*.sops.yaml` with the `sops-age` Secret.
The Flux controllers run on `phone-1` (`clusters/my-cluster/flux-system/on-phone-patch.yaml`).

## Scheduling

- Hardware-tied apps select `kubernetes.io/hostname: <node>` (`zigbee-bridge` on `pi3-1`; `otbr` on `pi4`, where the Thread dongle is now plugged in; `bt-proxy` on `pi4`; `website-ssh` (host port 2222, router 22) and `p2p-relay` (host port 47802, router TCP 47802) on `pi3-2`, next to the edge proxy).
- `phone-1` is tainted `node-type=phone:NoSchedule`. Apps there select it and tolerate the taint: Home Assistant, matter-server, Flux, monitoring, web-server, coredns-phone, the certbot and backup jobs.
- Home Assistant uses hostPaths on `phone-1` (`/var/lib/home-assistant/config`, `/etc/letsencrypt`), runs with `hostNetwork`, and reaches Zigbee (ser2net on `pi3-1`, port 6638), Matter (matter-server on `phone-1`, port 5580; it reaches the Thread devices through OTBR on `pi4` (which needs `net.ipv6.conf.all.forwarding=1`, set by `local.yml`), and has no Bluetooth, so new devices cannot be commissioned over BLE from it) and Bluetooth (bt-proxy on `pi4`, port 6053) over the network.
- `bt-proxy`'s API is unauthenticated: `pi4` drops port 6053 from all but `phone-1` (`bt-proxy-firewall.service`, from `local.yml`).

## Storage

SeaweedFS with one StorageClass, `seaweedfs-storage`: volume servers pinned per disk (3 on `pi4`, 2 on `pi3-1`), 2x replication with every disk its own rack (the two copies of a volume are always on two different disks), master on `pi4`, filer on `phone-1` (metadata in `/var/lib/seaweedfs-filer`, about 20 MB; the Pis ran out of memory and the OOM killer kept taking the filer down). `seaweedfs-stale-mounts.timer` on every node unmounts dead SeaweedFS FUSE mounts, so a filer restart does not leave pods stuck. The CSI driver runs on `pi4`, `pi3-2` and `phone-1`. A volume server refuses to start without `.real-disk-marker` in the `object_store` folder of its disk (`sudo touch /mnt/<disk>/object_store/.real-disk-marker`).

## Disaster recovery

1. Provision the nodes: the phone first with `phone-1/provision.sh` (it is the K3s server), then the Pis (`ansible-pull`; they join `phone-1`).
2. `flux bootstrap github --owner=Miro-Ali-Akbar --repository=pi-cluster --path=rpi-cluster-gitops/clusters/my-cluster` (needs a write-scoped `GITHUB_TOKEN`).
3. Create the decryption key: `kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=secrets/age.key`.
4. Restore HA's config on `phone-1` from backup; re-issue certificates with the one-time `certbot-issue*` jobs (deliberately in no kustomization).

Alternative to step 2: restore the K3s datastore from `/var/backups/cluster/phone-1` (or `pi4:/var/backups/cluster-standby`); see Failover in the root README.

## Host-level config (not managed by Flux, lost on reflash)

- **pi4: K3s container storage is on the SD card.** It used to be bind-mounted from the SanDisk SSD, and every USB drop of that SSD took the whole node down; now a drop only stops one volume server. The old copies on the SSD, and their `/etc/fstab` binds, are gone.
- **pi4: USB.** `/boot/firmware/cmdline.txt` has `usb-storage.quirks=7825:a2a4:u,0bda:9210:u` (no UAS for the SSD adapters: a UAS reset crashed the xHCI controller under load). Plug disks straight into pi4's ports; a 3-SSD USB hub reset every time load started and dropped the disks.
- **pi4: WireGuard** (`wg0`, 10.200.0.1/29, UDP 51820 forwarded by the router) is the only remote path into the cluster, and masquerades the VPN subnet onto the LAN. A peer whose allowed IPs include `192.168.0.0/24` reaches every node: the workstation's NetworkManager connection `nas` (10.200.0.2, keepalive 25, metric 700) does. The server config is SOPS-encrypted in `rpi-cluster-ansible/wireguard/pi4-wg0.sops.yaml`. Restore:
  ```
  SOPS_AGE_KEY_FILE=secrets/age.key sops --decrypt --input-type yaml --output-type binary rpi-cluster-ansible/wireguard/pi4-wg0.sops.yaml | ssh master@192.168.0.174 'sudo install -m 600 /dev/stdin /etc/wireguard/wg0.conf && sudo systemctl enable --now wg-quick@wg0'
  ```
- **pi3-1: the 2 TB HDD is switched off once every SeaweedFS volume has 2 copies** (it is audible). Its `/etc/fstab` line carries `x-systemd.automount,x-systemd.device-timeout=30s`, so it mounts by itself when its power returns. Home Assistant drives it with a restricted token (`hdd-power`, can only scale `seaweedfs-volume-pi3-1-hdd`): the automation `Harddrive off when replicated` (plug on 15 min and `sensor.seaweedfs_under_replicated` is 0) scales the volume server to 0, waits 3 min, then switches `switch.harddrive` (a Matter plug) off, retrying; `On leave` (away 15 min) switches it on with retries, waits 45 s and scales to 1. Its volumes have one copy meanwhile, and the replication alert is silenced while the StatefulSet is at 0. A Helm upgrade of the SeaweedFS release resets replicas to 1.
- **pi4: DuckDNS updater** (`duckdns-update.timer`).
- **pi4: `/usr/local/sbin/cluster-backup-export`** and the phone's restricted root key, installed by `local.yml`.
- **All Pis: `smart-metrics.timer`** writes SMART health of the USB disks for node-exporter (`/var/lib/node_exporter`), installed by `local.yml`. `local.yml` never partitions or formats a disk that already holds a filesystem.
