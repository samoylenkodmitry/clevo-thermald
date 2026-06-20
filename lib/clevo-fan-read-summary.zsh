#!/usr/bin/env zsh
# Clevo live fan telemetry via acpi_call WMI package 12 (DEVT, EC cmd 0xC0).
# Prints CPU / GPU1 / GPU2 fan RPM estimate, duty %, and EC-reported temps. Run as root.
set -eu

loaded_by_script=0
cleanup() { local rc=$?; (( loaded_by_script )) && rmmod acpi_call 2>/dev/null; exit $rc; }
trap cleanup EXIT INT TERM

if ! lsmod | awk '{print $1}' | grep -qx acpi_call; then
  modprobe acpi_call || { print -u2 -- "error: cannot load acpi_call (install acpi_call-dkms)"; exit 1; }
  loaded_by_script=1
fi
[[ -w /proc/acpi/call ]] || { print -u2 -- "error: /proc/acpi/call not writable"; exit 1; }

print -r -- '\_SB.WMI.WMBB 0x0 0x0c 0x0' > /proc/acpi/call
raw="$(tr -d '\000' < /proc/acpi/call)"

print -r -- "$raw" | awk '
function rpm_est(r){ return r ? int(((60/(0.00005565217391304348*r))*2)+0.5) : 0 }
function pct(r){ return int(((r/255)*100)+0.5) }
{
  n=0; s=$0
  while (match(s,/0x[0-9a-fA-F]+/)){ b[n]=strtonum(substr(s,RSTART,RLENGTH)); n++; s=substr(s,RSTART+RLENGTH) }
  if (n<25){ printf("not enough bytes to decode: %d\n", n); exit 1 }
  cpu=b[3]+(b[2]*256); g1=b[5]+(b[4]*256); g2=b[7]+(b[6]*256)
  printf("CPU fan:  %5d RPM est, duty %3d%% (%d/255), temp %d C\n", rpm_est(cpu), pct(b[16]), b[16], b[18])
  printf("GPU1 fan: %5d RPM est, duty %3d%% (%d/255), temp %d C\n", rpm_est(g1),  pct(b[19]), b[19], b[21])
  printf("GPU2 fan: %5d RPM est, duty %3d%% (%d/255), temp %d C\n", rpm_est(g2),  pct(b[22]), b[22], b[24])
}'
