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

`pi4` is memory-tight for a control plane (Longhorn + k3s + Flux + Home
Assistant all competing for 2 GB) — it's chronically near its limit
(typically ~1.5 GB used, several hundred MB swapped) and probe timeouts
across Longhorn/Flux/CoreDNS during load spikes are expected, not a sign of
something broken; it recovers on its own once load drops. If this gets
worse, moving Home Assistant to a worker node is the next lever, not adding
more to pi4. Neither Pi 3 has a bulk-storage USB HDD attached currently.

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

**Direct phone pairing instead of casting:** the Bluetooth speaker can only
hold one connection at a time, so casting via `pi3-2` and pairing a phone
directly to it are mutually exclusive. A Home Assistant switch,
**"Speaker Cast Stack"**, toggles the whole cast stack off (frees the
speaker to pair directly) and back on. It works via a root-only,
forced-command-restricted SSH key on `pi3-2` — see the `ha-cast-toggle`
tasks near the end of `rpi-cluster-ansible/local.yml`. The private key is
never committed; it's a k8s Secret created out-of-band, same as the
cluster's own join-token key.

**Known limits:** total latency is ~0.5–1s (Snapcast enforces a 400ms
minimum buffer for sync, plus the speaker's own SBC Bluetooth codec adds
~100–250ms) — this is a deliberate tradeoff for automatic source-switching
across all four inputs sharing one speaker connection. A direct low-latency
path is possible but would lose that auto-switching and can conflict with
the Snapcast-fed audio, since Bluetooth only allows one audio consumer at a
time. Also, `snapclient` doesn't always notice on its own when `snapserver`
restarts (stale TCP connection) — a watchdog timer checks every 2 minutes
and restarts it if it's not actually registered.

#### PC audio setup

Point your PC's system audio at `pi3-2`, port `4955` (Linux) or `4954`
(Windows). Both are just another input to the same auto-switching meta
stream — play something and it takes over automatically.

**Linux** (works on both PulseAudio and PipeWire, via its compat layer):

```bash
sudo apt install pulseaudio-utils netcat-openbsd   # already present on most desktop distros

# find your output device's monitor source once:
pactl list sources short   # look for "...monitor" next to your default sink

parec -d <your-sink>.monitor --channels=2 --rate=48000 --format=s16le --latency-msec=50 \
  | nc 192.168.0.176 4955
```

For a persistent, selectable "Cast to Speaker" output device instead of a
one-off command, create two systemd `--user` services:

```ini
# ~/.config/systemd/user/cast-to-speaker-sink.service
[Unit]
Description=Virtual "Cast to Speaker" audio output device
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/pactl load-module module-null-sink sink_name=CastToSpeaker sink_properties=device.description=Cast-to-Speaker
ExecStop=/bin/sh -c 'pactl list short modules | awk "\$2==\"module-null-sink\" && /CastToSpeaker/ {print \$1}" | xargs -r -n1 pactl unload-module'

[Install]
WantedBy=default.target
```

```ini
# ~/.config/systemd/user/cast-to-speaker-stream.service
[Unit]
Description=Stream "Cast to Speaker" virtual sink to the Bluetooth speaker
After=cast-to-speaker-sink.service
Requires=cast-to-speaker-sink.service

[Service]
ExecStart=/bin/sh -c 'parec -d CastToSpeaker.monitor --channels=2 --rate=48000 --format=s16le --latency-msec=50 | nc 192.168.0.176 4955'
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now cast-to-speaker-sink cast-to-speaker-stream
```

"Cast-to-Speaker" now shows up as a normal selectable output device.

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

