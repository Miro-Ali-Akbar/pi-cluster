# rpi-cluster-ansible

`local.yml` provisions the Pis. There is no central control host or inventory: each node
runs the playbook against itself with `ansible-pull`, from a systemd unit the playbook
installs and that re-runs on every boot. The phone is set up by `phone-1/` instead.

## What local.yml does

- Appends the K3s cgroup flags to `cmdline.txt` and reboots at most once per boot
  generation (sentinel-file guarded).
- **Control plane** (`node_role: control-plane`, `pi4`): receives the K3s standby archive from `phone-1`. The SeaweedFS disks are mounted by hand-kept `/etc/fstab` lines (by-id, `nofail`); the playbook never partitions or formats a disk that already holds a filesystem. `phone-1` (the K3s server) is set up by `phone-1/provision.sh`, not by this playbook.
- **Worker** (`node_role: worker`): formats and mounts a USB HDD if one is attached (matched by
  `/dev/disk/by-id/usb-*`).
- **pi4:** `bt-proxy-firewall.service` allows only `phone-1` to reach port 6053.
- **Every Pi:** joins K3s as an agent of `k3s_server_ip` (pinned `k3s_version`), once, and installs the SMART metrics timer.
- **pi4:** installs `cluster-backup-export` and authorizes `phone-1`'s key for root, restricted to that one command (it streams a tar.gz of the SeaweedFS master metadata).
- **Every Pi:** installs `seaweedfs-stale-mounts.timer`, which lazily unmounts dead SeaweedFS FUSE mounts.
- **pi3-1:** enables IPv6 forwarding (`/etc/sysctl.d/90-otbr-forwarding.conf`): the Thread border router running there routes between the LAN and the Thread mesh.
- **pi4:** installs `cluster-standby-receive` and authorizes `phone-1`'s push key, restricted to it.
- Hardware-specific tasks are gated on `ansible_hostname`, not role: the dongles are plugged
  into specific nodes.

## Adding a node

1. Reserve its IP in the router by MAC and flash Raspberry Pi OS Lite.
2. Put the cluster key at `/etc/rpi-cluster/id_ed25519` (nodes fetch the join token from `phone-1` with it; `provision.sh` authorizes it there when given `CLUSTER_PUBKEY`).
   This repo ships no private keys.
3. First boot runs `ansible-pull` from the cloud-init `user-data.yml` (see
   `cloud-init/user-data.yml.example`), passing `node_role`.
