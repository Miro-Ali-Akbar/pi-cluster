# phone-1

OnePlus 7 Pro (GM1913, 8 GB) running the Kali Nethunter Pro port as a K3s agent over Wi-Fi.
Unlike the Pis it does not run `ansible-pull`: host setup is `provision.sh`, run once as root.

## Boot image

Kernel 6.17.0-sm8150 built from https://github.com/Miro-Ali-Akbar/nethunter-pro-guacamole
(branch `gm1913-ufs-hs-g3`; patch `0010` caps the SM8150 UFS link at HS-G3, without it the root
filesystem never mounts). Flash with `fastboot flash boot <image>` to the active slot after
`fastboot erase dtbo`. Never run `reboot bootloader` from Linux: it lands in Qualcomm EDL.

## Host config (provision.sh)

- Hostname `phone-1`, `multi-user.target`, `chrony`, console log level 3.
- SSH key only, no root login.
- `battery-limiter`: keeps the battery between 40 and 65% by suspending the USB input (write
  `Unknown` to `/sys/class/power_supply/pm8150b-charger/status`), stops charging at 42 C or above,
  always charges below 15%.
- `screen-off`: the panel has no power control, so the console is set black on black, no cursor,
  framebuffer zeroed, and `getty@tty1` is masked. Check with
  `dd if=/dev/fb0 bs=1M | tr -d '\000' | wc -c` (0 means every pixel is dark).
- `wifi-soak`: one CSV line per minute to `/var/log/wifi-soak.csv` (signal, loss and latency to pi4).
- `linux-image-6.17.0-sm8150` and `phoc` are held. The GPU driver (`msm`) is not loaded at boot.
- K3s agent v1.36.3, node IP on `wlan0`, label `node-type=phone`, taint `node-type=phone:NoSchedule`,
  zram swap kept (`fail-swap-on=false`), eviction below 600 MiB available.

## Not in git

- Wi-Fi: NetworkManager profile `cluster-wifi` (WPA-PSK) with `cloned-mac-address=26:be:5a:27:89:85`
  and `powersave=2` (off). The router reserves 192.168.0.179 for that MAC.
- The join token: fetched from pi4 with the cluster key (`ssh -i <key> root@192.168.0.174 true`).
- The kali password and the authorised SSH key.

## Do not

- Enable a hardware watchdog: a Qualcomm watchdog bite can drop into crash-dump mode (`05c6:900e`)
  that needs a manual button hold.
- Leave the phone on a charger without `battery-limiter` running.
