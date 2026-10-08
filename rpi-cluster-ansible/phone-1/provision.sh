#!/bin/bash
# Host setup for phone-1 (OnePlus 7 Pro running the Nethunter Pro port). Run as root on the phone,
# after the Wi-Fi profile exists (see README.md).
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

# Desktop user services (audio, MMS, cell broadcast) burn CPU on a headless node
systemctl --global mask pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service \
  wireplumber.service mmsd-tng.service cellbroadcastd.service filter-chain.service mpris-proxy.service gvfs-daemon.service

# The power key must never shut the node down (it toggles the screen instead, see power-screen)
mkdir -p /etc/systemd/logind.conf.d
install -m 644 10-power-key.conf /etc/systemd/logind.conf.d/
systemctl kill -s HUP systemd-logind

# Battery limiter, OLED off, power button screen toggle, Wi-Fi soak logger
install -m 755 battery-limiter screen-off power-screen wifi-soak cluster-backup /usr/local/sbin/
install -m 644 battery-limiter.service screen-off.service power-screen.service wifi-soak.service cluster-backup.service cluster-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now battery-limiter screen-off power-screen wifi-soak cluster-backup.timer

# K3s server (the cluster's control plane). For a rebuild, restore the datastore first:
# extract the newest /var/backups/cluster/pi4-or-phone archive's k3s/{state.db,tls,cred,token} into
# /var/lib/rancher/k3s/server/{db/state.db,tls,cred,token}; K3S_START=true starts it.
# Tainted so only tolerating workloads land here; zram swap kept.
NODE_IP=$(ip -4 -o addr show wlan0 | awk '{print $4}' | cut -d/ -f1)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.5+k3s1" INSTALL_K3S_SKIP_START="$([ "${K3S_START:-}" = true ] && echo false || echo true)" \
  INSTALL_K3S_EXEC="server --node-name phone-1 --node-ip $NODE_IP --advertise-address $NODE_IP --tls-san $NODE_IP --flannel-iface wlan0 --node-label node-type=phone --node-taint node-type=phone:NoSchedule --kubelet-arg=fail-swap-on=false --kubelet-arg=eviction-hard=memory.available<600Mi --kubelet-arg=system-reserved=memory=400Mi --disable traefik --disable metrics-server --disable local-storage --write-kubeconfig-mode 600" sh -s -

# New Pis fetch the join token over SSH with the cluster deploy key; allow only that one command.
if [ -n "${CLUSTER_PUBKEY:-}" ]; then
  install -d -m 700 /root/.ssh
  grep -qF "$CLUSTER_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || \
    echo "command=\"cat /var/lib/rancher/k3s/server/node-token\",no-port-forwarding,no-agent-forwarding,no-X11-forwarding $CLUSTER_PUBKEY" >> /root/.ssh/authorized_keys
fi

# Login user: master with passwordless sudo, like the Pis (the image ships user kali).
# Run the rename from a transient unit: it kills the user's sessions, including this one.
echo "master ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-master
chmod 440 /etc/sudoers.d/90-master
visudo -c -q
if id kali >/dev/null 2>&1; then
  systemd-run --no-block --unit=rename-kali bash -c 'sleep 4; pkill -KILL -u kali; sleep 2; usermod -l master -d /home/master -m kali && groupmod -n master kali'
fi
