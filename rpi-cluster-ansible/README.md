# rpi-cluster-ansible

`local.yml` provisions the K3s cluster nodes. There's no central control host
or shared inventory — each node runs this playbook against itself via
`ansible-pull`, triggered by a systemd unit the playbook installs on its own
first run (and re-runs on every boot after).

## What it does

- Installs `open-iscsi` (Longhorn dependency) on every node.
- Idempotently appends the K3s cgroup kernel flags to `cmdline.txt` and
  reboots at most once per boot generation (sentinel-file guarded, since
  `ansible-pull` re-runs on every boot).
- **Control plane** (`node_role: control-plane`, passed via `--extra-vars`):
  formats/mounts the SSD (matched by stable `/dev/disk/by-id/ata-*` path —
  never `/dev/sdX`, which has collided with a Longhorn iSCSI volume enumerated
  on the same device name), installs the K3s server, restricts the node-token
  file to root reachable only via a forced-command SSH key.
- **Worker** (`node_role: worker`): formats/mounts a USB HDD if one's attached
  (matched by `/dev/disk/by-id/usb-*`, same reasoning as above — most workers
  don't currently have one), joins K3s as an agent only.
- **Hardware-specific tasks are gated on `ansible_hostname`, not role** —
  Bluetooth/Zigbee/Thread dongles are physically plugged into specific nodes,
  and two nodes sharing a role doesn't mean they share peripherals. See the
  `pi3-1`/`pi3-2`-scoped blocks near the end of the playbook.

## Triggering a run without waiting for reboot

```
ssh <node> sudo systemctl start ansible-pull
```

## Adding a new node

1. Reserve its IP via DHCP (MAC-based), flash Raspberry Pi OS Lite.
2. Provision the cluster SSH keypair at `/etc/rpi-cluster/id_ed25519` (workers
   need it to fetch the join token from the control plane over SSH, never
   over plain HTTP) — this repo intentionally ships no keys.
3. First boot runs `ansible-pull` via the cloud-init `user-data.yml` in this
   repo, passing `pi4_local_ip` and `node_role` as extra-vars.
