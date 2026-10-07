# rpi-cluster-ansible

`local.yml` provisions the Pis. There is no central control host or inventory: each node
runs the playbook against itself with `ansible-pull`, from a systemd unit the playbook
installs and that re-runs on every boot. The phone is set up by `phone-1/` instead.

## What local.yml does

- Appends the K3s cgroup flags to `cmdline.txt` and reboots at most once per boot
  generation (sentinel-file guarded).
- **Control plane** (`node_role: control-plane`, passed as an extra-var): formats and mounts
  the SSD (matched by `/dev/disk/by-id/ata-*`, never `/dev/sdX`), installs the K3s server
  with traefik, metrics-server and local-storage disabled, and restricts the node token to
  root, readable only through the cluster key's forced command.
- **Worker** (`node_role: worker`): formats and mounts a USB HDD if one is attached (matched by
  `/dev/disk/by-id/usb-*`), joins K3s as an agent.
- **pi4:** `bt-proxy-firewall.service` allows only `phone-1` to reach port 6053.
- **pi4 and pi3-1:** installs `cluster-backup-export` and authorizes `phone-1`'s key for root,
  restricted to that one command (it streams a tar.gz of the K3s datastore, TLS keys and
  token on `pi4`, or the SeaweedFS master and filer metadata on `pi3-1`).
- Hardware-specific tasks are gated on `ansible_hostname`, not role: the dongles are plugged
  into specific nodes.

## Adding a node

1. Reserve its IP in the router by MAC and flash Raspberry Pi OS Lite.
2. Put the cluster key at `/etc/rpi-cluster/id_ed25519` (workers fetch the join token with it).
   This repo ships no keys.
3. First boot runs `ansible-pull` from the cloud-init `user-data.yml` (see
   `cloud-init/user-data.yml.example`), passing `pi4_local_ip` and `node_role`.
