> **Historical design doc.** This was written before any hardware was
> provisioned. The cluster is live now and deviated in places (2 GB Pi 4
> instead of 8 GB, no bulk-storage HDDs attached, hardware-specific apps
> pinned by hostname instead of role). See the top-level [`README.md`](README.md)
> for what's actually running — kept here for the original rationale only.

**System Architecture & Hardware Inventory**

| Component | Quantity | Role | Configuration Notes |
| --- | --- | --- | --- |
| **Raspberry Pi 4 (8 GB)** | 1 | Control Plane (Master) & Fast Storage | 64-bit OS. Boots from an attached **USB 3.0 SSD** (not the SD card) to avoid write-wear and to get full USB3 throughput; official 5V/3A (15W) PSU; heatsink + fan required (this node runs etcd/K3s server plus the Longhorn engine/manager, both CPU- and I/O-active). 8 GB SKU specifically — a 2 GB unit is not safe for control-plane + Longhorn duty. |
| **Raspberry Pi 3 (1 GB)** | 2 | Worker Nodes & Bulk Storage (compute + storage, no quorum role) | 64-bit OS on a high-endurance (A2/high-TBW) microSD card — RPi3 cannot USB-boot. USB 2.0 HDD attached per node for NAS storage (realistic ceiling ~35–40 MB/s over USB2, well below the HDD's own ~100–160 MB/s sequential spec, and far lower for random I/O). Official 5V/2.5A PSU per unit. **Not used for etcd, K3s server, or any quorum/control-plane role** — 1 GB RAM has no margin for that. |
| **Teltonika TSF010** | 1 | Network Switch | 10/100 Mbps Fast Ethernet per port. Confirm actual negotiated link speed on every port (cheap/old CAT5 patch cables silently renegotiate down to 10 Mbps) before relying on the numbers below. |
| **Fast SSD** | 1 | High-Speed Cache / DB Storage + OS boot device | USB3, attached to the Pi 4. Mount path `/mnt/fast-storage`. Also serves as the Pi 4's boot medium (see above). |
| **USB HDDs** | 2 | Mass Storage Pool | One HDD per Pi 3, USB2, mount path `/mnt/bulk-storage`. Do not attach more than one USB storage device per Pi 3 — USB2 on that SoC has essentially no spare bandwidth to share. |

**Power & thermal budget:** total sustained draw is roughly 1×15 W (Pi 4 + SSD) + 2×7 W (Pi 3 + HDD, HDDs are separately/self-powered where possible) — size any shared power strip/UPS with headroom above the nominal sum, and use one quality PSU per Pi rather than a multi-port USB hub charger (undervoltage under simultaneous boot/I/O load is a common cause of SD corruption and random reboots).

**Software Requirements & Repositories**

* **Operating System:** Raspberry Pi OS Lite (64-bit ARM64) on all nodes.
* **Orchestration:** K3s (lightweight Kubernetes) with default local-storage disabled.
* **Storage Engine:** Longhorn (provides block-level 2x replication RAID-like redundancy and drive-failure alerts). Requires `open-iscsi` on every node — see Order of Operations.
* **GitOps & Automation:** `cloud-init` + `ansible-pull` for zero-touch system provisioning; Flux CD for Kubernetes cluster management.
* **Networking:** DHCP reservations only (see step 2) — do not also hardcode static IPs on the Pis themselves.
* **Git Repositories Required:**
* `rpi-cluster-ansible`: Contains a single `local.yml` playbook executed by nodes on first boot.
* `rpi-cluster-gitops`: Contains Kubernetes manifests categorized into `/infrastructure` (Longhorn, monitoring) and `/apps` (Home Assistant, Web server, NAS).
* **Actual layout used:** committed as one monorepo, `github.com/Miro-Ali-Akbar/pi-cluster`, with `rpi-cluster-ansible/` and `rpi-cluster-gitops/` as subdirectories rather than two separate repos — `ansible-pull` uses `-d rpi-cluster-ansible` and `flux bootstrap` uses `--path=rpi-cluster-gitops/clusters/my-cluster` to point into the right subdirectory (see each subdirectory's README for the exact commands).



---

**Order of Operations**

**1. Create the Ansible Automation Repository**
Build a public or private repository (`rpi-cluster-ansible`) containing a `local.yml` playbook that evaluates system hardware dynamically:

* **Cgroup Configuration (idempotent — avoid reboot loops):** On all nodes, first check whether `/boot/firmware/cmdline.txt` already contains the exact string `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory` (a single space-separated line, appended to existing content — never on a new line, never comma-separated). Use a check task (e.g. `command: grep -q "cgroup_memory=1" /boot/firmware/cmdline.txt`, `register: cgroup_check`, `failed_when: false`) and only append + notify the reboot handler `when: cgroup_check.rc != 0`. Additionally guard the reboot handler with a sentinel file (e.g. `/etc/ansible_cgroup_rebooted`) so the reboot can fire at most once per boot generation even if the grep logic has an edge case — this matters because `ansible-pull` runs on every boot in this design. After reboot, verify with `stat -fc %T /sys/fs/cgroup` (expect `cgroup2fs`) and confirm `memory` and `cpuset` appear in `/sys/fs/cgroup/cgroup.controllers`.
* **Longhorn Prerequisite (all nodes):** Install and enable `open-iscsi` before Longhorn is ever deployed: `apt-get update && apt-get install -y open-iscsi && systemctl enable --now iscsid`. Without this, Longhorn's manager/instance-manager pods fail their environment checks and volumes cannot attach.
* **RPi 4 Role (`ansible_memtotal_mb > 2000`):**
* Format and mount SSD to `/mnt/fast-storage`.
* Install K3s control plane: `curl -sfL https://get.k3s.io | sh -s - --disable local-storage`.
* Do **not** expose `/var/lib/rancher/k3s/server/node-token` over HTTP. It is a bearer credential that lets any host on the LAN join the cluster as a trusted node. Instead, have the control-plane play read the token (`ansible.builtin.slurp`) and push it directly to the Pi 3 nodes over SSH in the same Ansible run (`copy`/`template`), or store it as an Ansible Vault / SOPS-encrypted variable that the worker play decrypts locally. The token never touches the network as a plaintext file.


* **RPi 3 Role (`ansible_memtotal_mb < 2000`):**
* Format and mount USB HDD to `/mnt/bulk-storage`.
* Consume the node token delivered via the SSH-based push above (no `curl`/HTTP fetch of the token).
* Join K3s cluster as an **agent only**: `curl -sfL https://get.k3s.io | K3S_URL=https://<PI4_LOCAL_IP>:6443 K3S_TOKEN=<TOKEN> sh -s - agent`.
* Set conservative resource requests/limits (e.g. 128–256 MB per pod) on anything scheduled here, and label/taint the node so K3s and Longhorn treat it as compute + bulk-storage only, never as a scheduling target for etcd or other quorum workloads.



**2. Flash Drives & Inject Cloud-Init**

1. Use Raspberry Pi Imager to flash 64-bit Raspberry Pi OS Lite onto the SD card for the Pi 4 (initial boot only, before switching it to USB-SSD boot) and onto the SD cards for the two Pi 3 nodes.
2. Use **one IP-assignment mechanism only**: configure DHCP reservations keyed on each Pi's MAC address on the router (or on the Teltonika switch if it performs DHCP). Leave every Pi itself in DHCP client mode — do not also set a static IP in the Pi's own network config. This avoids the two classic failure modes: a statically-configured Pi colliding with the DHCP pool, and a cloned SD card (all Pi 3 workers are imaged from the same base) silently booting multiple nodes with the same hardcoded static IP. Record the MAC-to-IP mapping for all three nodes here:

   | Node | MAC Address | Reserved IP |
   | --- | --- | --- |
   | Pi 4 (control plane) | `<fill in>` | `<fill in>` |
   | Pi 3 worker #1 | `<fill in>` | `<fill in>` |
   | Pi 3 worker #2 | `<fill in>` | `<fill in>` |

3. Paste the following first-boot automation script into the OS Customization script field (`user-data` file) before writing:

```bash
#!/bin/bash
exec > /var/log/firstrun-ansible.log 2>&1
apt update && apt install -y ansible git
ansible-pull -U https://github.com/<your-username>/rpi-cluster-ansible.git -i localhost, local.yml

```

**3. Automated Boot & Node Join**

1. Insert the SD card into the **Pi 4** and power it on first. `cloud-init` runs Ansible, installs `open-iscsi`, configures cgroups (idempotently — see step 1), reboots once, then installs the K3s control plane. Once stable, migrate its boot device to the USB SSD per the Raspberry Pi bootloader's USB mass-storage boot config, so the SD card is no longer the active root device.
2. Insert SD cards into the **Pi 3s** and power them on. They execute `ansible-pull`, install `open-iscsi`, configure cgroups, reboot once, receive the join token via the SSH-based push from step 1 (not over HTTP), and register as K3s **agent** nodes only.

**4. Storage Engine & Alert Setup (Longhorn)**

1. Before installing Longhorn, run its environment-check DaemonSet (`longhorn/deploy/prerequisite/longhorn-iscsi-installation.yaml` or `environment_check.sh`) against all three nodes and confirm every node passes (this re-validates the `open-iscsi`/`iscsid` prerequisite from step 1).
2. Deploy Longhorn to the cluster via Helm manifest.
3. **StorageClasses:** Define two storage classes in Kubernetes:
* `fast-ssd`: Points to `/mnt/fast-storage` on the Pi 4 node for high-speed workloads.
* `bulk-hdd`: Points to `/mnt/bulk-storage` paths on worker nodes for bulk storage.


4. **RAM ceiling on Pi 3 storage nodes:** Longhorn's own guidance assumes ≥4 GB RAM per storage node; the Pi 3 workers have 1 GB. Set explicit CPU/memory `requests`/`limits` on the Longhorn engine and replica processes scheduled to these nodes, disable non-essential K3s services (metrics-server, traefik, servicelb) on them, and treat OOM-killer events on these nodes as an expected operational risk to monitor for, not an edge case. If instability persists in practice, exclude the Pi 3 nodes from Longhorn's default disk scheduling (`node.longhorn.io/create-default-disk=false`) and run them compute-only, moving `bulk-hdd` duty elsewhere or accepting a smaller storage footprint.
5. **RAID Replication:** With only two storage-eligible nodes (the two Pi 3 workers) plus the Pi 4, `numberOfReplicas: 2` is the practical ceiling — Longhorn will place one replica per Pi 3. Understand this gives **no spare redundancy**: the moment either Pi 3 reboots, is drained, or fails, every `bulk-hdd` volume runs on a single healthy replica with no third node to rebuild onto until that node returns. Document this explicitly as an accepted risk window, enable Longhorn's `replica-auto-balance`, and pair in-cluster replication with an off-cluster backup target (S3, NFS, or similar) so total-volume-loss during that window is recoverable. If a third always-on node ever becomes available, add it as a storage-eligible worker and raise `numberOfReplicas` to `3` for real fault tolerance.
6. **Alerting:** Configure Longhorn's built-in AlertManager integration with an external webhook endpoint (Discord, Telegram, or Email SMTP) to trigger notifications immediately when a drive enters a `Faulted` or `Degraded` status.

**5. GitOps Bootstrap (Flux CD)**

1. Run `flux bootstrap` from an **operator's workstation**, not from unattended cloud-init/ansible-pull on any Pi — bootstrap needs a GitHub Personal Access Token with `repo` scope (classic) or `contents:write` + `administration:write` (fine-grained) on the target repository, and that write-scoped credential should never be baked into an image cloned across multiple SD cards. Source the token from an environment variable (`GITHUB_TOKEN`) populated from a local `.env` that is never committed, or from an Ansible Vault secret used only for this one-time step:
`flux bootstrap github --owner=<your-username> --repository=rpi-cluster-gitops --path=clusters/my-cluster`
2. After bootstrap, Flux only needs its own deploy key / read-only credential for ongoing reconciliation — the write-scoped PAT is not needed on the cluster afterward and should not be left stored on any node.
3. Flux will periodically sync the Git repository with the state of the cluster.

**6. Application Deployment**
Commit application manifests to the `rpi-cluster-gitops` repository:

* **Home Assistant & Web Server:** Configure manifests with Persistent Volume Claims (PVCs) requesting the `fast-ssd` StorageClass.
* **NAS Service (Samba / Nextcloud):** Configure manifests with PVCs requesting the `bulk-hdd` StorageClass.

---

**Critical Hardware Limitations & Operational Rules**

* **Network Throughput Bottleneck:** The Teltonika TSF010 switch runs at **10/100 Mbps** per port. This yields roughly **11.5 MB/s** of full-duplex TCP goodput — label this figure explicitly as a **per-node uplink ceiling**, not an aggregate cluster bandwidth number; the switch's internal backplane is not the constraint, each node's own 100 Mbps link is. Distributed block replication (Longhorn sync) and network storage access will be capped at this per-link rate. Before finalizing, confirm the TSF010's actual port speed and that no cable is auto-negotiating down further (cheap/old CAT5 is a common silent cause). Avoid intensive simultaneous read/writes across nodes during file backups, and if any ports on the switch are gigabit-capable, route storage/replication traffic over those in preference to the 100 Mbps ones.
* **RAM Optimization on Pi 3s:** The Pi 3 nodes have 1 GB RAM and no hardware acceleration beyond basic ARMv8 — they must never run etcd, the K3s server role, or any other quorum/stateful service. Ensure all non-essential K3s services are disabled and set strict CPU/Memory resource limits on Longhorn components running on worker nodes to prevent Out-Of-Memory (OOM) host crashes; treat sustained memory pressure on these nodes (e.g. during volume rebuilds or snapshotting) as an expected risk to monitor, not a rare edge case.
* **Storage Interface & Throughput:** Pi 4's USB3 SSD can sustain roughly 300–400 MB/s but shares a single root-hub controller across all four USB ports — do not attach a second USB3 device to the Pi 4 and assume additive bandwidth. Pi 3's USB2 HDDs are realistically capped around 35–40 MB/s sequential (bus-limited, below the HDD's own spec) and far lower for random I/O — acceptable for NAS/bulk storage, not suitable for database-style workloads.
* **Boot Media Wear:** Any node with sustained write activity (etcd, container logs, Longhorn engine/replica data) will wear out a consumer microSD card within months. The Pi 4 boots from USB SSD specifically to avoid this. The Pi 3 nodes cannot USB-boot, so use high-endurance (A2/high-TBW) SD cards for them and keep their write-heavy paths (logs, Longhorn replica data) on the attached USB HDD via bind-mount rather than the SD card where possible.
* **IP Addressing:** DHCP reservations by MAC address are the single source of truth for node IPs (see step 2). Do not layer static IP configuration on top of this on any Pi, and re-verify the MAC-to-IP table above whenever a node's SD card is re-flashed (re-flashing can occasionally regenerate a different MAC on some USB-Ethernet adapters, though onboard NICs retain their MAC).
