#!/usr/bin/env zsh
# Clevo direct fan-duty control via acpi_call WMI (ZEVT command 0x68 / 0x69).
#   all-max  : force all four fan channels to 100% duty   (0x68 0xffffffff)
#   auto-all : return all channels to the EC auto curve   (0x69 0x0000000f)
# Used by clevo-thermald's ExecStopPost as a safety fallback. Run as root.
set -eu

mode_name="${1:-}"
case "$mode_name" in
  all-max)  cmd="0x68"; payload="0xffffffff"; desc="all channels 100% duty" ;;
  auto-all) cmd="0x69"; payload="0x0000000f"; desc="all channels back to EC auto duty" ;;
  *) print -u2 -r -- "usage: $0 {all-max|auto-all}"; exit 2 ;;
esac

loaded_by_script=0
cleanup() { local rc=$?; (( loaded_by_script )) && rmmod acpi_call 2>/dev/null; exit $rc; }
trap cleanup EXIT INT TERM

if ! lsmod | awk '{print $1}' | grep -qx acpi_call; then
  modprobe acpi_call || { print -u2 -r -- "error: cannot load acpi_call (install acpi_call-dkms)"; exit 1; }
  loaded_by_script=1
fi
[[ -w /proc/acpi/call ]] || { print -u2 -r -- "error: /proc/acpi/call not writable"; exit 1; }

print -r -- "[clevo-fan] $desc"
print -r -- "\\_SB.WMI.WMBB 0x0 $cmd $payload" > /proc/acpi/call
print -r -- "[clevo-fan] result: $(tr -d '\000' < /proc/acpi/call)"
