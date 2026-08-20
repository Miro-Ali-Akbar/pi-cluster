# Home Cluster

A 3-node Raspberry Pi K3s cluster running home automation, Zigbee/Matter/Thread
bridging, and multi-room Bluetooth audio casting. Provisioned hands-off via
`ansible-pull` on each node's own boot, apps deployed via Flux GitOps.

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
| Multi-room audio casting | `pi3-2` + native services | see below |
| NAS (Samba), web server | mixed | |

### Multi-room audio casting

A Bluetooth speaker ("The_Arms") gets audio from four sources — AirPlay,
Spotify Connect, DLNA (VLC etc.), and PC system audio (Windows/Linux) — that
auto-switch via a Snapcast "meta" stream: whichever source is actively
playing wins, by priority order, no manual switching needed.

```
AirPlay (shairport-sync) ─┐
Spotify (raspotify)       ├─→ snapserver meta stream ─→ snapclient ─→ bluealsa ─→ speaker
DLNA (gmediarender)       │
PC audio (your computer) ─┘
```

Runs natively on `pi3-2` (via Ansible), not as k8s pods — `bluealsa` needs to
own its D-Bus name on the host's real system bus, which the host's D-Bus
security policy correctly denies to a container process even running as
root. Music Assistant was tried first and dropped: it pulled in a full
media-library app and an ffmpeg-heavy DSP chain just to reach one speaker.

**Casting from your phone/PC:**

- **iPhone/Mac**: AirPlay, native.
- **Spotify** (any platform, Premium required): pick "Big Speaker Sound In"
  in the Spotify app's device picker.
- **Android, or any DLNA-capable app (VLC, etc.)**: tap VLC's renderer icon,
  or any app's DLNA "cast" button, select "The_Arms_DLNA". Needs the phone on
  the same WiFi with multicast/AP-isolation not blocking discovery, and (on
  Android 12+) VLC's local-network permission granted.
- **PC audio** — see below.

The speaker holds only one connection at a time, so casting and pairing a
phone to it directly are mutually exclusive. HA's **"Speaker Cast Stack"**
switch toggles the whole stack off to free it for direct pairing (root-only
forced-command SSH key on `pi3-2`, never committed — see `ha-cast-toggle`
in `local.yml`).

**Known limits:** ~0.5–1s total latency (Snapcast's 400ms sync buffer +
the speaker's SBC codec) — the cost of auto-switching between four shared
inputs. A watchdog restarts `snapclient` if it misses a `snapserver`
restart (known flaky reconnect).

#### PC audio setup

Point your PC's system audio at `pi3-2`, port `4955` (Linux) or `4954`
(Windows). Both are just another input to the same auto-switching meta
stream — play something and it takes over automatically.

**Linux** — one-off:

```bash
pactl list sources short                      # find "<sink>.monitor" for your output
parec -d <sink>.monitor --channels=2 --rate=48000 --format=s16le --latency-msec=50 \
  | nc 192.168.0.176 4955
```

For a persistent, selectable "Cast to Speaker" device instead: see
[`rpi-cluster-ansible/pc-cast-client/`](rpi-cluster-ansible/pc-cast-client/).

**Windows** (needs a virtual audio cable, since Windows has no built-in
loopback capture):

1. Install [VB-Audio Virtual Cable](https://vb-audio.com/Cable/) (free).
2. Set "CABLE Input" as your default playback device, or route specific
   apps to it.
3. Capture "CABLE Output" and stream it with `ffmpeg`:
   ```
   ffmpeg -f dshow -i audio="CABLE Output" -ar 48000 -ac 2 -f s16le tcp://192.168.0.176:4954
   ```

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

