# Home Cluster

K3s on three Raspberry Pis and one phone: home automation and Zigbee/Matter/Thread bridging. Pis provision themselves with `ansible-pull` on boot, the phone with `rpi-cluster-ansible/phone-1/`, apps deploy through Flux.

| Node | Hardware | RAM | Runs |
| --- | --- | --- | --- |
| `pi4` 192.168.0.174 | Pi 4, 220 GB USB SSD | 2 GB | K3s server, SeaweedFS volumes and S3, NAS (Samba), bt-proxy; host: WireGuard, DuckDNS updater |
| `pi3-1` 192.168.0.104 | Pi 3, SD | 1 GB | SeaweedFS master and a volume, OTBR, Zigbee bridge (dongles here) |
| `pi3-2` 192.168.0.176 | Pi 3+, SD | 1 GB | edge proxy (80/443 forwarded here), site-counters, SeaweedFS filer and a volume |
| `phone-1` 192.168.0.179 | OnePlus 7 Pro, Wi-Fi, 224 GB | 8 GB | Home Assistant, Matter server, Flux, Prometheus, Alertmanager, web server, CoreDNS replica |

The Pis are memory-tight; put new workloads on `phone-1` (tainted `node-type=phone:NoSchedule`).

## Layout

```
rpi-cluster-ansible/   local.yml (Pis), phone-1/ (phone)
rpi-cluster-gitops/    Flux manifests
secrets/               age private key (gitignored, workstation only)
```

## Operating

- **App change:** commit under `rpi-cluster-gitops/`, push to `main`.
- **Node change:** edit `local.yml`; apply now with `ssh master@<node> sudo systemctl start ansible-pull`.
- **kubectl:** `export KUBECONFIG=kubeconfig-pi4.yaml`. **SSH:** `master`, passwordless sudo, every node.
- **Alerts:** Prometheus rules (node down or not Ready, low memory, full disk, crash loops, phone battery) -> Alertmanager -> Home Assistant webhook -> phone notification.
- **Backups:** `phone-1` pulls the K3s datastore, TLS keys and token (`pi4`) and SeaweedFS master/filer metadata (`pi3-1`) every 6 h into `/var/backups/cluster` (28 kept). HA's own backups mirror to SeaweedFS every 6 h.

## Secrets

Cluster Secrets are SOPS/age-encrypted `*.sops.yaml` in git; Flux decrypts with the `sops-age` Secret. The age key is in `secrets/age.key`, the password manager and the cluster. Rotate: `sops <file>`, commit, restart pods that read it.

Not in git: `flux-system` deploy key (`flux bootstrap`), `/etc/rpi-cluster/id_ed25519` on each Pi, phone Wi-Fi profile and SSH keys.
