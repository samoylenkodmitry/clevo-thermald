#!/usr/bin/env bash
# clevo-thermald installer. Run as root:  sudo ./install.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo ./install.sh"; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

echo ">> checking dependencies"
miss=0
for c in zsh cpupower awk logger modprobe; do
    command -v "$c" >/dev/null || { echo "   MISSING: $c"; miss=1; }
done
command -v nvidia-smi >/dev/null || echo "   note: nvidia-smi not found — GPU fan control will use the safe fallback duty (set GPU_POLL_SECS=0 to disable it)"
if ! modprobe acpi_call 2>/dev/null || [ ! -e /proc/acpi/call ]; then
    echo "   MISSING: acpi_call kernel module (install 'acpi_call-dkms' from the AUR)"
    miss=1
fi
[ "$miss" -eq 0 ] || { echo ">> install the missing dependencies and re-run"; exit 1; }

echo ">> installing files"
install -Dm755 "$SRC/bin/clevo-thermald" /usr/local/bin/clevo-thermald
install -d /usr/local/lib/clevo-thermald
install -m755 "$SRC"/lib/*.zsh /usr/local/lib/clevo-thermald/
install -Dm644 "$SRC/systemd/clevo-thermald.service" /etc/systemd/system/clevo-thermald.service

echo ">> ensuring acpi_call loads on boot"
echo acpi_call > /etc/modules-load.d/clevo-thermald.conf

echo ">> enabling service"
systemctl daemon-reload
systemctl enable --now clevo-thermald.service

echo ">> done. Verify with:"
echo "     systemctl status clevo-thermald"
echo "     journalctl -t clevo-thermald -f"
echo "     sudo zsh /usr/local/lib/clevo-thermald/clevo-fan-read-summary.zsh"
echo
echo "   Tune the curves/thresholds at the top of /usr/local/bin/clevo-thermald,"
echo "   then: sudo systemctl restart clevo-thermald"
