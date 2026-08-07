# rpi-cluster-ansible

Zero-touch first-boot provisioning for the Raspberry Pi K3s cluster described in
[`../plan.md`](../plan.md). Each node runs this playbook against itself via
`ansible-pull` (see `cloud-init/user-data.yml` in this repo) — there is no central
control host and no shared inventory of the other nodes.

## Before flashing any SD cards

1. **Reserve DHCP addresses** for all three nodes by MAC address (plan.md step 2)
   and fill in `pi4_local_ip` in `local.yml` (or pass
   `--extra-vars pi4_local_ip=<ip>` via the `ansible-pull` invocation in
   `user-data.yml`).
2. **Generate a dedicated cluster SSH keypair** (do not reuse a personal key):
   ```
   ssh-keygen -t ed25519 -f id_ed25519 -N "" -C "rpi-cluster-token-pull"
   ```
   Place the *private* key at `/etc/rpi-cluster/id_ed25519` on every node (worker
   nodes need it to fetch the token; the control plane needs the matching
   `.pub` to authorize it) via your cloud-init `user-data.yml`'s `write_files`
   section — **never commit either key to this git repository**. A forced
   command (`command="cat /var/lib/rancher/k3s/server/node-token"`) restricts
   what that key can do on the control plane even if it leaked.

## What the playbook does

- Installs and enables `open-iscsi` (required by Longhorn) on every node.
- Idempotently appends the K3s cgroup kernel flags to `cmdline.txt` and reboots
  at most once per boot generation (sentinel-file guarded, since `ansible-pull`
  re-runs this playbook on every boot).
- **Pi 4 (`ansible_memtotal_mb > 2000`):** formats/mounts the SSD, installs the
  K3s server with `--disable local-storage`, and restricts the node-token file
  to root, reachable only via the forced-command SSH key — never served over
  plain HTTP.
- **Pi 3 (`ansible_memtotal_mb < 2000`):** formats/mounts the USB HDD, fetches
  the join token over the restricted SSH key, and joins as a K3s **agent only**
  (never as a second server/quorum member — see plan.md's hardware limits).

## Known gaps to fill in for your environment

- `pi4_local_ip` is a placeholder — set it before use.
- The cluster SSH keypair must be provisioned out-of-band (cloud-init
  `write_files` or a secrets manager); this repo intentionally ships no keys.
- `/dev/sda1` is assumed for the attached SSD/HDD; adjust if your device nodes
  differ.
