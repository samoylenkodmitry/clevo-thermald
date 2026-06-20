#!/usr/bin/env bash
# clevo-thermald uninstaller. Run as root:  sudo ./uninstall.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./uninstall.sh"; exit 1; }

echo ">> stopping service (ExecStopPost returns fans to EC auto)"
systemctl disable --now clevo-thermald.service 2>/dev/null || true
/usr/bin/zsh /usr/local/lib/clevo-thermald/clevo-fan-direct-duty.zsh auto-all 2>/dev/null || true

echo ">> restoring CPU boost and full clocks"
echo 1 > /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || true
maxf=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || true)
if [ -n "${maxf:-}" ]; then
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo "$maxf" > "$f" 2>/dev/null || true; done
fi

echo ">> removing files"
rm -f /usr/local/bin/clevo-thermald
rm -f /etc/systemd/system/clevo-thermald.service
rm -f /etc/modules-load.d/clevo-thermald.conf
rm -rf /usr/local/lib/clevo-thermald
systemctl daemon-reload

echo ">> done. Fans are back under the EC firmware curve."
