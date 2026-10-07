# Home Cluster

K3s cluster of three Raspberry Pis and one phone running home automation and
Zigbee/Matter/Thread bridging. The Pis provision themselves with `ansible-pull` on
each boot, the phone with `rpi-cluster-ansible/phone-1/`, and apps deploy through Flux.

## Nodes

| Node | Hardware | RAM | Runs |
| --- | --- | --- | --- |
| `pi4` 192.168.0.174 | Raspberry Pi 4, 220 GB USB SSD | 2 GB | K3s server, SeaweedFS volumes and S3 gateway, NAS (Samba), bt-proxy; host: WireGuard VPN, DuckDNS updater |
| `pi3-1` 192.168.0.104 | Raspberry Pi 3, SD card | 1 GB | SeaweedFS master and a volume, OTBR, Zigbee bridge (the dongles are plugged in here) |
| `pi3-2` 192.168.0.176 | Raspberry Pi 3+, SD card | 1 GB | edge proxy (ports 80/443 are forwarded here), site-counters, SeaweedFS filer and a volume |
| `phone-1` 192.168.0.179 | OnePlus 7 Pro, Wi-Fi, 224 GB | 8 GB | Home Assistant, Matter server, Flux controllers, Prometheus and Alertmanager, web server, CoreDNS replica |

`phone-1` is tainted `node-type=phone:NoSchedule`; see `rpi-cluster-ansible/phone-1/README.md`.
The Pis have little memory: `pi4` runs near its limit, `pi3-2` has the most free of the three.
Put new workloads on `phone-1` first.

## Layout

```
rpi-cluster-ansible/   local.yml (Pis) and phone-1/ (phone)
rpi-cluster-gitops/    manifests synced by Flux, see its README
secrets/               age private key for SOPS (gitignored, workstation only)
```

## Operating

- **Change an app:** commit under `rpi-cluster-gitops/`, push to `main`; Flux applies it.
- **Change a node:** edit `local.yml`; apply without a reboot with `ssh master@<node> sudo systemctl start ansible-pull`.
- **kubectl:** `export KUBECONFIG=kubeconfig-pi4.yaml`.
- **SSH:** user `master` with passwordless sudo on every node.
- **Alerts:** Prometheus rules (node down or not Ready, low memory, full disk, crash loops, phone battery) go through Alertmanager to a Home Assistant webhook, which notifies the phone app.
- **Backups:** `phone-1` pulls the K3s datastore, TLS material and token from `pi4`, and the SeaweedFS master and filer metadata from `pi3-1`, every 6 hours into `/var/backups/cluster` (28 kept, 7 days). Home Assistant's own backups are mirrored to SeaweedFS every 6 hours.

## Secrets

Cluster Secrets are SOPS-encrypted (`*.sops.yaml`, age) in git and decrypted by Flux with
the `sops-age` Secret. The age private key is not in git: it is at `secrets/age.key` on the
workstation, in the password manager, and in the cluster. Edit one with `sops <file>`,
commit, and restart the pods that read it.

Not in git: the `flux-system` deploy key (made by `flux bootstrap`), the cluster join key
`/etc/rpi-cluster/id_ed25519` on each Pi, the phone's Wi-Fi profile and SSH keys.
