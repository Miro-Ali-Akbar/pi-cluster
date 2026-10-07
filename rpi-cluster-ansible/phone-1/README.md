# phone-1

OnePlus 7 Pro (GM1913, 8 GB) running the Kali Nethunter Pro port (kernel 6.17.0-sm8150) as a
K3s agent over Wi-Fi. It does not run `ansible-pull`: `provision.sh` sets it up once, as root.

## Boot image

Built from https://github.com/Miro-Ali-Akbar/nethunter-pro-guacamole (branch `gm1913-ufs-hs-g3`).
Patch `0010` caps the SM8150 UFS link at HS-G3; without it the root filesystem never mounts
(the controller reports hardware 4.x, and HS-G4 lanes fail to train on this unit).
Flash with `fastboot erase dtbo` then `fastboot flash boot <image>` to the active slot.

## Recovery

- Never run `reboot bootloader` from Linux: it lands in Qualcomm EDL. Use the buttons.
- Never enable a hardware watchdog: a Qualcomm watchdog bite drops into crash-dump mode
  (USB `05c6:900e`); hold Power and Volume Up for about 15 s to leave it.
- The IMEI and radio partition backups are on the workstation (`phone-cluster/backup/`), not in git.

## Host config (provision.sh)

- Hostname `phone-1`, `multi-user.target`, `chrony`, console log level 3, zram swap kept.
- SSH key only, no root login. Login user `master` with passwordless sudo
  (`/etc/sudoers.d/90-master`), like the Pis; the image's `kali` user is renamed to it.
- `battery-limiter`: keeps the battery between 40 and 65% by suspending the USB input (write
  `Unknown` to `/sys/class/power_supply/pm8150b-charger/status`), stops charging at 42 C or
  above, always charges below 15%. It must run whenever the phone is on a charger.
- `screen-off`: the panel has no power control, so the console is black on black with no
  cursor and the framebuffer zeroed; `getty@tty1` is masked. Check with
  `dd if=/dev/fb0 bs=1M | tr -d '\000' | wc -c` (0 means every pixel is dark).
- `power-screen`: the power button toggles a status page (addresses, Wi-Fi signal, battery,
  temperatures, k3s state) that switches itself off after 120 s. logind ignores the power key,
  so the button cannot shut the node down. `systemctl kill -s USR1 power-screen` toggles it.
- Desktop user services (pipewire, wireplumber, mmsd-tng and others) are masked. Idle draw is
  about 310 mA.
- `cluster-backup.timer` (every 6 hours at :10 past 00, 06, 12 and 18): pulls the K3s datastore, TLS keys and token from
  `pi4` and the SeaweedFS metadata from `pi3-1` into `/var/backups/cluster/<node>/`, mode 700,
  28 kept, with the key `/root/.ssh/cluster-backup`.
- `wifi-soak`: one CSV line per minute to `/var/log/wifi-soak.csv` (signal, loss and latency to pi4).
- `linux-image-6.17.0-sm8150` and `phoc` are held. The GPU driver (`msm`) is not loaded.
- K3s agent v1.36.3, node IP on `wlan0`, label `node-type=phone`, taint `node-type=phone:NoSchedule`,
  `fail-swap-on=false`, eviction below 600 MiB available.
- Home Assistant's config is `/var/lib/home-assistant/config`, its certificates are
  `/etc/letsencrypt`, and matter-server's fabric data is `/var/lib/matterjs-server/data`; all are hostPaths here.

## Not in git

- Wi-Fi: NetworkManager profile `cluster-wifi` (WPA-PSK) with `cloned-mac-address=26:be:5a:27:89:85`
  and `powersave=2` (off). The router reserves 192.168.0.179 for that MAC.
- The join token (fetched from `pi4` with the cluster key), the `master` password and the authorised SSH key.
