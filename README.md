# Home Cluster

K3s on three Raspberry Pis and one phone: home automation and Zigbee/Matter/Thread bridging. Pis provision themselves with `ansible-pull` on boot, the phone with `rpi-cluster-ansible/phone-1/`, apps deploy through Flux.

| Node | Hardware | RAM | Runs |
| --- | --- | --- | --- |
| `pi4` 192.168.0.174 | Pi 4, 220 GB USB SSD | 2 GB | K3s agent (old server data kept as the standby), SeaweedFS volumes and S3, NAS (Samba), bt-proxy, OTBR (Thread dongle); host: WireGuard, DuckDNS updater |
| `pi3-1` 192.168.0.104 | Pi 3, SD | 1 GB | SeaweedFS master and a volume, Zigbee bridge (Zigbee dongle here) |
| `pi3-2` 192.168.0.176 | Pi 3+, SD | 1 GB | edge proxy (80/443 forwarded here), site-counters, SeaweedFS filer and a volume |
| `phone-1` 192.168.0.179 | OnePlus 7 Pro, Wi-Fi, 224 GB | 8 GB | K3s server, Home Assistant, Matter server, MQTT broker (Mosquitto, port 1883), Flux, Prometheus, Alertmanager, web server, CoreDNS replica |

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
- **kubectl:** `export KUBECONFIG=kubeconfig.yaml` (admin credentials, gitignored; copy of `/etc/rancher/k3s/k3s.yaml` on `phone-1` with the server set to `https://192.168.0.179:6443`). **SSH:** `master`, passwordless sudo, every node.
- **Alerts:** Prometheus rules (node down or not Ready, low memory, full disk, crash loops, phone battery) -> Alertmanager -> Home Assistant webhook -> phone notification.
- **Backups** (every 6 h, 28 kept, in `/var/backups/cluster/<node>` on `phone-1`): its own K3s datastore, TLS keys and token; SeaweedFS master metadata from `pi3-1` and filer metadata from `pi3-2`. The K3s archive is also pushed to `pi4` (`/var/backups/cluster-standby`, 14 kept). HA's own backups mirror to SeaweedFS every 6 h.
- **Failover** (`phone-1` dead): on `pi4`, `sudo systemctl disable --now k3s-agent`; unpack the newest `/var/backups/cluster-standby` archive into `/var/lib/rancher/k3s/server/` (`k3s/state.db` to `db/state.db`, plus `tls`, `cred`, `token`); `sudo mv /etc/rancher/k3s/config.yaml.server-standby /etc/rancher/k3s/config.yaml`; `sudo systemctl enable --now k3s`; on `pi3-1` and `pi3-2` set `K3S_URL` in `/etc/systemd/system/k3s-agent.service.env` to `https://192.168.0.174:6443` and restart `k3s-agent`. Home Assistant and the other `phone-1` workloads stay down until `phone-1` is back.

## Secrets

Cluster Secrets are SOPS/age-encrypted `*.sops.yaml` in git; Flux decrypts with the `sops-age` Secret. The age key is in `secrets/age.key`, the password manager and the cluster. Rotate: `sops <file>`, commit, restart pods that read it. Read a login: `SOPS_AGE_KEY_FILE=secrets/age.key sops -d secrets-encrypted/<file>.sops.yaml`.

MQTT users `homeassistant` and `pc` (passwords in `secrets-encrypted/mqtt-credentials.sops.yaml`, hashed in `rpi-cluster-gitops/apps/mqtt/passwd.sops.yaml`). Not in git: `flux-system` deploy key (`flux bootstrap`), `/etc/rpi-cluster/id_ed25519` on each Pi, phone Wi-Fi profile and SSH keys.
