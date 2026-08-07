**System Architecture & Hardware Inventory**

| Component | Quantity | Role | Configuration Notes |
| --- | --- | --- | --- |
| **Raspberry Pi 4** | 1 | Control Plane (Master) & Fast Storage | 64-bit OS, USB 3.0 SSD attached for high-IOPS storage. |
| **Raspberry Pi 3** | 2 | Worker Nodes & Bulk Storage | 64-bit OS, USB HDDs attached for NAS storage. |
| **Teltonika TSF010** | 1 | Network Switch | 10/100 Mbps Ethernet connection connecting all Pis locally. |
| **Fast SSD** | 1 | High-Speed Cache / DB Storage | Mount path `/mnt/fast-storage` on Pi 4. |
| **USB HDDs** | 2+ | Mass Storage Pool | Mount path `/mnt/bulk-storage` on Pi 3 worker nodes. |

**Software Requirements & Repositories**

* **Operating System:** Raspberry Pi OS Lite (64-bit ARM64) on all nodes.
* **Orchestration:** K3s (lightweight Kubernetes) with default local-storage disabled.
* **Storage Engine:** Longhorn (provides block-level 2x replication RAID-like redundancy and drive-failure alerts).
* **GitOps & Automation:** `cloud-init` + `ansible-pull` for zero-touch system provisioning; Flux CD for Kubernetes cluster management.
* **Git Repositories Required:**
* `rpi-cluster-ansible`: Contains a single `local.yml` playbook executed by nodes on first boot.
* `rpi-cluster-gitops`: Contains Kubernetes manifests categorized into `/infrastructure` (Longhorn, monitoring) and `/apps` (Home Assistant, Web server, NAS).



---

**Order of Operations**

**1. Create the Ansible Automation Repository**
Build a public or private repository (`rpi-cluster-ansible`) containing a `local.yml` playbook that evaluates system hardware dynamically:

* **Cgroup Configuration:** On all nodes, check if `/boot/firmware/cmdline.txt` includes `cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory`. If missing, append the string and trigger an immediate reboot.
* **RPi 4 Role (`ansible_memtotal_mb > 2000`):**
* Format and mount SSD to `/mnt/fast-storage`.
* Install K3s control plane: `curl -sfL [https://get.k3s.io](https://get.k3s.io) | sh -s - --disable local-storage`.
* Expose `/var/lib/rancher/k3s/server/node-token` on the local LAN using a temporary HTTP service (e.g., `python3 -m http.server 8080 --directory /var/lib/rancher/k3s/server/`).


* **RPi 3 Role (`ansible_memtotal_mb < 2000`):**
* Format and mount USB HDDs to `/mnt/bulk-storage`.
* Fetch node token over the Teltonika local network: `curl http://<PI4_LOCAL_IP>:8080/node-token`.
* Join K3s cluster: `curl -sfL [https://get.k3s.io](https://get.k3s.io) | K3S_URL=https://<PI4_LOCAL_IP>:6443 K3S_TOKEN=<TOKEN> sh -`.



**2. Flash Drives & Inject Cloud-Init**

1. Use Raspberry Pi Imager to flash 64-bit Raspberry Pi OS Lite onto SD cards for each Pi.
2. Configure static IP addresses (or assign static DHCP reservations on your router) for all three nodes.
3. Paste the following first-boot automation script into the OS Customization script field (`user-data` file) before writing:

```bash
#!/bin/bash
exec > /var/log/firstrun-ansible.log 2>&1
apt update && apt install -y ansible git
ansible-pull -U https://github.com/<your-username>/rpi-cluster-ansible.git -i localhost, local.yml

```

**3. Automated Boot & Node Join**

1. Insert SD card into the **Pi 4** and power it on first. `cloud-init` runs Ansible, configures cgroups, reboots, installs the K3s control plane, and starts serving the cluster token locally.
2. Insert SD cards into the **Pi 3s** and power them on. They execute `ansible-pull`, fetch the join token directly from the Pi 4 across the Teltonika switch, configure cgroups, reboot, and register as worker nodes.

**4. Storage Engine & Alert Setup (Longhorn)**

1. Deploy Longhorn to the cluster via Helm manifest.
2. **StorageClasses:** Define two storage classes in Kubernetes:
* `fast-ssd`: Points to `/mnt/fast-storage` on the Pi 4 node for high-speed workloads.
* `bulk-hdd`: Points to `/mnt/bulk-storage` paths on worker nodes for bulk storage.


3. **RAID Replication:** Set the default `numberOfReplicas` to `2`. Longhorn will replicate every written block across two separate physical drives on different nodes.
4. **Alerting:** Configure Longhorn’s built-in AlertManager integration with an external webhook endpoint (Discord, Telegram, or Email SMTP) to trigger notifications immediately when a drive enters a `Faulted` or `Degraded` status.

**5. GitOps Bootstrap (Flux CD)**

1. Install Flux CLI locally and bootstrap the Pi 4 control plane:
`flux bootstrap github --owner=<your-username> --repository=rpi-cluster-gitops --path=clusters/my-cluster`
2. Flux will periodically sync the Git repository with the state of the cluster.

**6. Application Deployment**
Commit application manifests to the `rpi-cluster-gitops` repository:

* **Home Assistant & Web Server:** Configure manifests with Persistent Volume Claims (PVCs) requesting the `fast-ssd` StorageClass.
* **NAS Service (Samba / Nextcloud):** Configure manifests with PVCs requesting the `bulk-hdd` StorageClass.

---

**Critical Hardware Limitations & Operational Rules**

* **Network Throughput Bottleneck:** The Teltonika TSF010 switch runs at **10/100 Mbps**. Distributed block replication (Longhorn sync) and network storage access will cap out at roughly **11.5 MB/s**. Avoid intensive simultaneous read/writes across nodes during file backups.
* **RAM Optimization on Pi 3s:** The Pi 3 nodes have 1GB RAM. Ensure all non-essential k3s services are disabled and set strict CPU/Memory resource limits on Longhorn components running on worker nodes to prevent Out-Of-Memory (OOM) host crashes.
