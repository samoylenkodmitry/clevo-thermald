#!/usr/bin/env zsh
# Clevo fan-MODE control via acpi_call WMI (ZEVT command 0x79).
#   auto | max | silent | maxq
# NOTE: on the reference unit "silent" (mode 3) did NOT reduce fan speed (it went to
# 100%); behaviour is firmware-dependent. clevo-thermald's manual fan curves are the
# reliable way to get quiet. Run as root.
set -eu

case "${1:-}" in
  auto)   mode_hex="0x01000000" ;;
  max)    mode_hex="0x01000001" ;;
  silent) mode_hex="0x01000003" ;;
  maxq)   mode_hex="0x01000005" ;;
  *) print -u2 "usage: $0 {auto|max|silent|maxq}"; exit 2 ;;
esac

loaded_by_script=0
cleanup() { local rc=$?; (( loaded_by_script )) && rmmod acpi_call 2>/dev/null; exit $rc; }
trap cleanup EXIT INT TERM

if ! lsmod | awk '{print $1}' | grep -qx acpi_call; then
  modprobe acpi_call || { print -u2 "error: cannot load acpi_call (install acpi_call-dkms)"; exit 1; }
  loaded_by_script=1
fi
[[ -w /proc/acpi/call ]] || { print -u2 "error: /proc/acpi/call not writable"; exit 1; }

print -r -- "[clevo-fan] mode ${1}"
print -r -- "\\_SB.WMI.WMBB 0x0 0x79 $mode_hex" > /proc/acpi/call
print -r -- "[clevo-fan] result: $(tr -d '\000' < /proc/acpi/call)"
