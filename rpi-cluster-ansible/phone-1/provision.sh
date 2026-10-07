#!/bin/bash
# Host setup for phone-1 (OnePlus 7 Pro running the Nethunter Pro port). Run as root on the phone,
# after the Wi-Fi profile exists (see README.md) and with the cluster join token in $K3S_TOKEN.
set -euo pipefail
cd "$(dirname "$0")"

# Hostname, time, console
hostnamectl set-hostname phone-1
apt-get install -y chrony curl
systemctl enable --now chrony
timedatectl set-timezone Europe/Stockholm
systemctl set-default multi-user.target
echo "kernel.printk = 3 4 1 3" > /etc/sysctl.d/10-console-loglevel.conf

# SSH: key only
mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication no\nPermitRootLogin no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/10-hardening.conf
sshd -t && systemctl reload ssh

# Keep the port's kernel modules and patched phoc, no unattended upgrades
apt-mark hold linux-image-6.17.0-sm8150 phoc
systemctl disable --now apt-daily-upgrade.timer
systemctl mask qcom-modem-setup.service phosh.service
# No GPU driver at boot (headless), no login prompt on the OLED
[ -e /etc/modules-load.d/guacamole-gpu.conf ] && mv /etc/modules-load.d/guacamole-gpu.conf /etc/modules-load.d/guacamole-gpu.conf.disabled
systemctl mask getty@tty1.service

# Battery limiter, OLED off, Wi-Fi soak logger
install -m 755 battery-limiter screen-off wifi-soak /usr/local/sbin/
install -m 644 battery-limiter.service screen-off.service wifi-soak.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now battery-limiter screen-off wifi-soak

# K3s agent: tainted so only tolerating workloads land here; zram swap kept
: "${K3S_TOKEN:?set K3S_TOKEN}"
NODE_IP=$(ip -4 -o addr show wlan0 | awk '{print $4}' | cut -d/ -f1)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.3+k3s1" K3S_URL="https://192.168.0.174:6443" K3S_TOKEN="$K3S_TOKEN" \
  INSTALL_K3S_EXEC="agent --node-name phone-1 --node-ip $NODE_IP --flannel-iface wlan0 --node-label node-type=phone --node-taint node-type=phone:NoSchedule --kubelet-arg=fail-swap-on=false --kubelet-arg=eviction-hard=memory.available<600Mi --kubelet-arg=system-reserved=memory=400Mi" sh -s -
