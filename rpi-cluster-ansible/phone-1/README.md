# phone-1

OnePlus 7 Pro (GM1913, 8 GB), Kali Nethunter Pro port (kernel 6.17.0-sm8150), the cluster's K3s server over Wi-Fi.
`provision.sh` sets it up once, as root (no `ansible-pull`).

## Boot image

Source: https://github.com/Miro-Ali-Akbar/nethunter-pro-guacamole, branch `gm1913-ufs-hs-g3`.
Patch `0010` caps the SM8150 UFS link at HS-G3; without it the root filesystem never mounts.
Flash: `fastboot erase dtbo`, then `fastboot flash boot <image>` to the active slot. Fastboot: power off, hold **Volume Down + Power** (Volume Up + Power boots Linux). One-off test of another image without flashing: `fastboot boot <image>`; a normal reboot returns to the flashed one.

The USB-C port is a device/sink port (`dr_mode = "peripheral"`): a hub does not work on it. The variant `sm8150-oneplus-guacamole-pd.dts` (PD stack and role switching, built into the kernel but not enabled in the device tree) lets the phone act as host, but it cannot charge through a hub that has no PD controller, and it is not flashed.

## Never

- `reboot bootloader` from Linux: lands in Qualcomm EDL.
- Enable a hardware watchdog: a bite enters crash-dump mode (USB `05c6:900e`); hold Power + Volume Up about 15 s to leave.
- Run on a charger without `battery-limiter`.

## Host config

- `master` user, passwordless sudo, SSH key only, no root login. Hostname `phone-1`, `multi-user.target`, `chrony`, zram swap.
- `battery-limiter`: holds the battery at 40-65% by writing `Unknown` to `/sys/class/power_supply/pm8150b-charger/status`; stops charging at 42 C; always charges below 15%.
- `screen-off`: panel has no power control, so console is black on black and the framebuffer zeroed (`dd if=/dev/fb0 bs=1M | tr -d '\000' | wc -c` is 0 when dark).
- `power-screen`: power button toggles a status page, off after 120 s. logind ignores the key and its long press (`/etc/systemd/logind.conf.d/zz-power-key.conf` sorts after the image's `mobile-tweaks.conf`, which would otherwise power the phone off after 5 s). `systemctl kill -s USR1 power-screen` toggles it.
- The clock is wrong at boot: `k3s` starts after `chrony-wait.service` (at most 180 s). `k3s-agent.service` from earlier K3s installs stays disabled.
- `cluster-backup.timer` (00, 06, 12, 18 at :10): archives its own K3s datastore, TLS keys and token to `/var/backups/cluster/phone-1/` and pushes that archive to `pi4` (`/root/.ssh/standby-push`); pulls SeaweedFS master metadata from `pi4` (`/root/.ssh/cluster-backup`). Mode 700, 28 kept. Needs `sqlite3`.
- `phone-metrics.timer` (every minute): battery voltage, current, status, charger enabled and input limit for node-exporter (`/var/lib/node_exporter/phone.prom`). Battery capacity and temperature and the SoC thermal zones come from node-exporter itself. Prometheus keeps 90 days (10 GB cap).
- `wifi-soak`: per-minute CSV in `/var/log/wifi-soak.csv`.
- Desktop user services masked (idle draw about 310 mA). `linux-image-6.17.0-sm8150` and `phoc` held; `msm` GPU driver not loaded.
- K3s server v1.36.5 (SQLite datastore in `/var/lib/rancher/k3s/server`; traefik, metrics-server and local-storage disabled), also the node `phone-1`: node IP on `wlan0`, label `node-type=phone`, taint `node-type=phone:NoSchedule`, `fail-swap-on=false`, eviction below 600 MiB. If it is down the API is down, but running pods keep running.
- hostPaths: `/var/lib/home-assistant/config`, `/etc/letsencrypt`, `/var/lib/matterjs-server/data`.

## Not in git

- Wi-Fi: NetworkManager profile `cluster-wifi` (WPA-PSK), `cloned-mac-address=26:be:5a:27:89:85`, `powersave=2`; router reserves 192.168.0.179 for that MAC.
- `master` password and authorized SSH key. The join token is `/var/lib/rancher/k3s/server/node-token` here.
- IMEI and radio partition backups: workstation `phone-cluster/backup/`.
