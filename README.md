# Home Cluster

A K3s cluster of three Raspberry Pis and one phone, running home automation and
Zigbee/Matter/Thread bridging. The Pis are provisioned hands-off via `ansible-pull`
on each node's own boot, the phone via `rpi-cluster-ansible/phone-1/`, and apps are
deployed via Flux GitOps.

## Hardware

| Node | Model | RAM | Role | Storage |
| --- | --- | --- | --- | --- |
| `pi4` (192.168.0.174) | Raspberry Pi 4 | 2 GB | control plane | 220 GB USB SSD → `/mnt/fast-storage` |
| `pi3-1` (192.168.0.104) | Raspberry Pi 3 | 1 GB | worker (Zigbee/Thread hardware) | SD card only |
| `pi3-2` (192.168.0.176) | Raspberry Pi 3+ | 1 GB | worker | SD card only |
| `phone-1` (192.168.0.179) | OnePlus 7 Pro, Wi-Fi | 8 GB | worker, tainted `node-type=phone` | 224 GB UFS |

`pi4` is chronically near its 2 GB memory limit (Longhorn + k3s + Flux +
Home Assistant) — expect occasional probe-timeout warnings under load; it
recovers on its own. If it worsens, move Home Assistant to a worker before
adding anything else to `pi4`. Neither Pi 3 has a bulk-storage HDD attached.

## Repo layout

```
rpi-cluster-ansible/   local.yml - runs on every node's own boot via ansible-pull
rpi-cluster-gitops/    Kubernetes manifests, synced by Flux
  infrastructure/      Longhorn, monitoring
  apps/                everything in "What's running" below
```

There's no central control host or shared inventory — each node pulls and
applies `local.yml` against itself. Hardware-specific tasks (USB
device paths) are gated on `ansible_hostname`, not a generic role, since two
nodes can share a role but not the same physical peripherals.

## What's running

| App | Where | Notes |
| --- | --- | --- |
| Home Assistant | `pi4` | |
| Matter server, OTBR (Thread border router) | `pi3-1` | pinned to the node with the Thread dongle |
| Zigbee bridge (ser2net) | `pi3-1` | |
| NAS (Samba), web server | mixed | |

## Operating

- **Node provisioning**: `ansible-pull` runs on every boot (systemd unit
  installed by `local.yml` itself). To apply a change without waiting for a
  reboot: `ssh <node> sudo systemctl start ansible-pull`.
- **App deployment**: commit manifests under `rpi-cluster-gitops/apps/`,
  push — Flux reconciles automatically.
- **kubectl**: `export KUBECONFIG=kubeconfig-pi4.yaml` from this directory.
- **Secrets** (never committed - created out-of-band, once): the cluster's
  own join-token key at `/etc/rpi-cluster/id_ed25519` on each Pi.

