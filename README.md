# Home Cluster

A 3-node Raspberry Pi K3s cluster running home automation, Zigbee/Matter/Thread
bridging, and Spotify casting to a Bluetooth speaker. Provisioned hands-off
via `ansible-pull` on each node's own boot, apps deployed via Flux GitOps.

## Hardware

| Node | Model | RAM | Role | Storage |
| --- | --- | --- | --- | --- |
| `pi4` (192.168.0.174) | Raspberry Pi 4 | 2 GB | control plane | 220 GB USB SSD → `/mnt/fast-storage` |
| `pi3-1` (192.168.0.104) | Raspberry Pi 3 | 1 GB | worker (Zigbee/Thread hardware) | SD card only |
| `pi3-2` (192.168.0.176) | Raspberry Pi 3+ | 1 GB | worker (Bluetooth audio hardware) | SD card only |

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
applies `local.yml` against itself. Hardware-specific tasks (Bluetooth, USB
device paths) are gated on `ansible_hostname`, not a generic role, since two
nodes can share a role but not the same physical peripherals.

## What's running

| App | Where | Notes |
| --- | --- | --- |
| Home Assistant | `pi4` | |
| Matter server, OTBR (Thread border router) | `pi3-1` | pinned to the node with the Bluetooth/Thread dongle |
| Zigbee bridge (ser2net) | `pi3-1` | |
| Spotify casting | `pi3-2` + native services | see below |
| NAS (Samba), web server | mixed | |

### Spotify casting to the Bluetooth speaker

```
raspotify (librespot) ─→ bluealsa ─→ speaker ("The_Arms")
```

Runs natively on `pi3-2` (via Ansible), not as a k8s pod — `bluealsa` needs
to own its D-Bus name on the host's real system bus, which the host's D-Bus
security policy correctly denies to a container process even running as
root.

**Off by default** — the speaker is a normal Bluetooth device (free for a
phone to pair directly) until explicitly turned on. HA's
**"Speaker Cast Stack"** switch connects it and starts `raspotify`; turning
it off disconnects and stops it again. Works via a root-only,
forced-command-restricted SSH key on `pi3-2` (never committed — see
`ha-cast-toggle` in `local.yml`); once on, pick "Big Speaker Sound In" in
Spotify's device picker.

An earlier version ran AirPlay + DLNA + PC audio too, all auto-switching
through a Snapcast meta-stream. Cut back to Spotify-only: Snapcast's 400ms
sync buffer was pure overhead once there was only ever one source to
arbitrate.

**Known issue:** `pi3-2`'s onboard Bluetooth chip has hardware-faulted
twice (`hardware error 0x00` in `dmesg`, even the reset command times out —
only a reboot has cleared it). Traced to undervoltage. A `bluetooth-watchdog`
timer checks every 2 minutes and reboots the node if a soft recovery fails,
but the real fix is a proper PSU/cable for `pi3-2`. `/var/log/journal` is
persisted specifically so a reboot doesn't destroy the evidence of whether
the watchdog fired.

**Tried and reverted: two speakers playing simultaneously.** An ALSA
`multi`+`route` config duplicated raspotify's output to two paired
speakers ("The_Arms" + "Buddy") over independent Bluetooth links. Each
speaker played fine, but the two had a noticeable (~50ms) sync offset with
no shared clock to correct it (that's exactly the problem Snapcast solves,
which was removed above) — and then a Bluetooth hardware fault took both
down. Not worth it for one speaker's worth of practical benefit; reverted
to single-speaker.

## Operating

- **Node provisioning**: `ansible-pull` runs on every boot (systemd unit
  installed by `local.yml` itself). To apply a change without waiting for a
  reboot: `ssh <node> sudo systemctl start ansible-pull`.
- **App deployment**: commit manifests under `rpi-cluster-gitops/apps/`,
  push — Flux reconciles automatically.
- **kubectl**: `export KUBECONFIG=kubeconfig-pi4.yaml` from this directory.
- **Secrets** (never committed - created out-of-band, once): the
  `ha-cast-toggle-key` k8s Secret in the `home-assistant` namespace, and the
  matching `ha_cast_toggle_pubkey` var in `local.yml` if the key ever needs
  rotating. Same pattern as the cluster's own join-token key.

