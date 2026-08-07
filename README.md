# Cluster

Raspberry Pi K3s home cluster. Start with [`plan.md`](plan.md) for the full
design (hardware, software choices, and the numbered order of operations) —
this README just maps those steps onto the repos in this checkout.

| plan.md step | Where it lives |
| --- | --- |
| 1. Ansible automation repo | [`rpi-cluster-ansible/`](rpi-cluster-ansible/) — `local.yml` |
| 2. Flash drives & inject cloud-init | [`rpi-cluster-ansible/cloud-init/user-data.yml.example`](rpi-cluster-ansible/cloud-init/user-data.yml.example) |
| 3. Automated boot & node join | handled by `local.yml` via `ansible-pull` on first boot |
| 4. Storage engine & alerting (Longhorn) | [`rpi-cluster-gitops/infrastructure/longhorn/`](rpi-cluster-gitops/infrastructure/longhorn/), [`.../monitoring/`](rpi-cluster-gitops/infrastructure/monitoring/) |
| 5. GitOps bootstrap (Flux) | [`rpi-cluster-gitops/clusters/my-cluster/`](rpi-cluster-gitops/clusters/my-cluster/) |
| 6. Application deployment | [`rpi-cluster-gitops/apps/`](rpi-cluster-gitops/apps/) |

## Before you touch hardware

1. Read `rpi-cluster-ansible/README.md` — you need a reserved DHCP IP for the
   Pi 4 and a dedicated cluster SSH keypair generated (and never committed)
   before flashing any SD cards.
2. Read `rpi-cluster-gitops/README.md` — after nodes join the cluster you must
   label them (`node-role=control-plane|worker`) before Flux's app
   Kustomization will schedule anything successfully.

## Status

`plan.md` has been reviewed (hardware/networking, K3s/Longhorn, and
GitOps/security) and revised to fix the issues that review surfaced —
insecure plain-HTTP token distribution, a possible cgroup-reboot loop, the
missing `open-iscsi` prerequisite, RAM/SKU sizing, and the DHCP/static-IP
conflict. `rpi-cluster-ansible/` and `rpi-cluster-gitops/` are scaffolded
against the revised plan; both READMEs list the environment-specific values
(IPs, keys, webhook credentials) still needed before a real first boot.
