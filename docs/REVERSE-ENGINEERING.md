# Clevo NH5xAx Fan Control Notes

> These are the working notes from reverse-engineering the Clevo WMI/EC fan interface
> (the basis for `clevo-thermald`). They document **findings** for interoperability.
> The referenced artifacts — decompiled vendor binaries (`*.il`), the Windows app
> bundle, and raw ACPI table dumps (`*.dsl`/`*.dat`) — are **not** included in this
> repository (proprietary and/or machine-specific). Paths below are from the original
> analysis machine, kept for context only.

Scope so far: static/read-only analysis only. No EC registers were written, no WMI
methods were called, no kernel modules were loaded, and no fan settings were
changed.

## Local artifacts

- `dchu.il`: IL disassembly of the installed Windows `DCHUService.exe`.
- `fanspeed.il`: IL disassembly of the extracted Windows `FanSpeedSetting.exe`.
- `fanspeed-appxbundle/`: extracted `FanSpeedSetting.appxbundle`.
- `fanspeed-x64/`: extracted x64 app package.
- `*.dat`: ACPI table dumps from `acpidump -b`.
- `*.dsl`: disassembled ACPI tables from `iasl -d *.dat`.
- `ssdt4.dsl`: main Clevo ACPI/WMI table for fan control.

## Windows driver/app stack

- Main package: `/media/winsys/Program Files (x86)/ControlCenter`
- Fan UI bundle:
  `/media/winsys/Program Files (x86)/ControlCenter/AppInstall/FanSpeedSetting/FanSpeedSetting.appxbundle`
- Kernel bridge driver: `AcpiBridge.sys`
- Native userspace DLL: `InsydeDCHU.dll`
- Windows service: `DCHUService.exe`
- Fan UI app: `FanSpeedSetting.exe`

`AcpiBridge.inf` installs an ACPI bridge for `ACPI\CLV0001` and exposes device
interface GUID:

```text
86994c74-ad43-4812-b7e7-0c420b5c5fd7
```

That GUID exists in `AcpiBridge.sys` and both observed `InsydeDCHU.dll` copies,
so the native DLL likely opens that device interface and sends IOCTLs to the
bridge driver.

## Native DLL and driver bridge

All findings in this section are from static PE/disassembly work only.

File hashes:

```text
5bc9d882b9e01eed07aacc8400bf70affdb829f60e22b1b7cd818dec9d2cb632  installed InsydeDCHU.dll
cb3b03f38d4f3b98709a2e395acec0e958841e67627855874268e418b990f106  app-bundle InsydeDCHU.dll
58e24c053b87cd4a8b76565bd7f5830cd946faa5dd9e4691f9348e1453c8df96  AcpiBridge.sys
23d777993c8d20cde79912dba9e07024c1c63986989d69a6dde7ac5764ac19d8  AcpiBridge1.sys
```

Installed `InsydeDCHU.dll` exports:

```text
ordinal 1 RVA 0x2B60  GetDCHU_Data_Buffer
ordinal 2 RVA 0x26F0  GetDCHU_Data_Integer
ordinal 3 RVA 0x2D90  ReadAppSettings
ordinal 4 RVA 0x2920  SetDCHU_Data
ordinal 5 RVA 0x2EA0  WriteAppSettings
```

The extracted fan app bundle contains a newer/debug-looking `InsydeDCHU.dll`
with the same core exports plus:

```text
ordinal 5 RVA 0x3DE9C7  SetDCHU_DataEx
```

`InsydeDCHU.dll` imports `CM_Get_Device_Interface_List_SizeW`,
`CM_Get_Device_Interface_ListW`, `CreateFileW`, `DeviceIoControl`, and
`CloseHandle`. The open path enumerates the bridge interface GUID
`86994c74-ad43-4812-b7e7-0c420b5c5fd7`, then calls `CreateFileW` with
read/write access and share mode `3`.

The installed DLL contains both important GUIDs in `.rdata`:

```text
18021d238: e424f293 dcfbbf4b add6db71 bdc0afad
  -> 93f224e4-fbdc-4bbf-add6-db71bdc0afad, ACPI _DSM UUID

18021d248: 744c9986 43ad1248 b7e70c42 0b5c5fd7
  -> 86994c74-ad43-4812-b7e7-0c420b5c5fd7, AcpiBridge device interface
```

`GetDCHU_Data_Integer`, `SetDCHU_Data`, and `GetDCHU_Data_Buffer` all send
IOCTL `0x322400` to `AcpiBridge.sys`. The DLL builds a request containing:

```text
dword 0
dword 0x4d53445f        # "_DSM" in little-endian storage
dword command
word  0x0104
dword 0x01000002        # ACPI package element marker
two 256-byte buffers
```

`GetDCHU_Data_Integer` passes a zeroed data buffer and parses ACPI package
integer elements. `GetDCHU_Data_Buffer` parses ACPI package buffer elements and
copies the returned buffer to the caller. `SetDCHU_Data` copies the caller's
buffer into the request before sending the same IOCTL.

`ReadAppSettings` and `WriteAppSettings` use IOCTL `0x32240c`, not the fan
telemetry `_DSM` path. `WriteAppSettings` builds a settings block shaped like:

```text
[0]    dword = 1
[4]    word  = page * 0x100 + offset
[6]    word  = length
[8..]  payload bytes
```

`AcpiBridge.sys` is a KMDF driver. Its PDB path is:

```text
D:\Projects\Clevo\AcpiBridge\x64\Release\AcpiBridge.pdb
```

It exposes the same device interface GUID at `.rdata` `0x140003140`. Its IOCTL
dispatcher subtracts `0x322400` and dispatches these private controls:

```text
0x322400 -> handler 0x1400064d0, ACPI _DSM eval path used by fan commands
0x322404 -> handler 0x1400067a0, secondary/non-fan control path
0x322408 -> handler 0x140006660, secondary/non-fan control path
0x32240c -> handler 0x14000693c, AppSettings path
```

The `0x322400` handler requires an input buffer of `0x14` and an output buffer
of `0x420`, then calls the core evaluator at `0x140006000`. The evaluator
builds an ACPI method-eval buffer for `_DSM`, allocates a response buffer, calls
through the WDF/ACPI interface, and accepts the result only when the returned
buffer magic is `0x426f6541` (`"AeoB"` in little-endian storage).

The fan telemetry path is therefore:

```text
FanSpeedSetting.Read_FanSpeed()
  -> InsydeDCHU.GetDCHU_Data_Buffer(12)
  -> CreateFileW("\\?\...{86994c74-ad43-4812-b7e7-0c420b5c5fd7}...")
  -> DeviceIoControl(0x322400)
  -> AcpiBridge.sys handler 0x1400064d0
  -> ACPI _DSM UUID 93f224e4-fbdc-4bbf-add6-db71bdc0afad, Arg2 12
  -> DCHU.DEVT
  -> EC command 0xC0
  -> 256-byte telemetry buffer
```

This confirms that the Windows binary does not talk to the EC directly from
userspace. It relies on the signed AcpiBridge KMDF driver to evaluate Clevo's
ACPI `_DSM` method.

## DCHUService WMI interface

`DCHUService.exe` is a .NET assembly. It talks to:

```text
root\WMI
CLEVO_GET.InstanceName='ACPI\PNP0C14\0_0'
```

Getter methods are called with no input and return output property `Data`.
Setter methods receive a `UInt32` input property named `Data`.

Important fan-related service command mappings:

```text
53  -> GetCPUFANDuty
54  -> GetVGA1FANDuty
55  -> GetVGA2FANDuty
56  -> GetFANCount
97  -> GetFanStatus
99  -> Fan1Info
100 -> Fan2Info
104 -> SetFanDuty
105 -> SetFanAutoDuty
110 -> Fan3Info
111 -> Fan4Info
112 -> GetFan12RPM
113 -> GetFan34RPM
```

Commands `104` and `105` are setters. Avoid them until read-only WMI probing is
working and temperature monitoring/revert logic is ready.

ACPI confirms these setters:

```text
0x68 / 104 -> writes four fan duty bytes through EC command 0xC1
0x69 / 105 -> returns selected fan channels to auto duty through EC command 0xC1
```

## FanSpeedSetting app behavior

The fan UI also uses `InsydeDCHU.dll` directly.

Live fan package:

```text
GetWMIPackage(12)
```

Known byte layout from `Read_FanSpeed()`:

```text
CPU RPM  = data[3] + (data[2] << 8)
CPU duty = data[16]
CPU temp = data[18] after app-side TDP calibration

GPU1 RPM  = data[5] + (data[4] << 8)
GPU1 duty = data[19]
GPU1 temp = data[21]

GPU2 RPM  = data[7] + (data[6] << 8)
GPU2 duty = data[22]
GPU2 temp = data[24]
```

Fan table/status package:

```text
GetWMIPackage(13)
```

Known offsets from `Read_WMI13()`:

```text
data[12] -> fan count
data[14] -> initial fan mode
data[43] -> feature/status bits used for multi-fan and Max-Q logic
```

Custom fan table write:

```text
SetWMIPackage(14, buffer[256])
```

This writes custom fan table data and sets app-side fan mode to `6` (custom).
Treat this as a write path and do not test it in the low-risk phase.

Fan mode/offset writes:

```text
SetWMI(121, 1, mode)
SetWMI(121, 14, offset_scaled_0_to_255)
SetWMI(121, 34, 1)   # load defaults
```

Mode values seen in UI:

```text
0 -> automatic
1 -> max
3 -> silent
5 -> Max-Q
6 -> custom
```

These are write paths and should not be called yet.

### Custom fan curve behavior

The Windows fan curve editor is real. It is not just a UI preset layer: saving
the curve writes a custom table to the EC runtime fan table through package 14.

`Read_WMI13()` reads package 13 as the default/current firmware table. Duties in
this package are firmware bytes from `0..255`; the app displays them as percent
with:

```text
round(raw_duty / 255 * 100)
```

The package 13 curve points used by the app are:

```text
CPU:
  0x10 T1, 0x11 D1
  0x12 T2, 0x13 D2
  0x14 T3, 0x15 D3
  T4 = 100, D4 = 100

GPU1:
  0x18 T1, 0x19 D1
  0x1A T2, 0x1B D2
  0x1C T3, 0x1D D3
  T4 = 100, D4 = 100

GPU2:
  0x20 T1, 0x21 D1
  0x22 T2, 0x23 D2
  0x24 T3, 0x25 D3
  T4 = 100, D4 = 100
```

Before displaying the table, the app enforces increasing duties by decrementing
`D3` if it is greater than or equal to `D4`, and decrementing `D2` if it is
greater than or equal to `D3`.

`Write_WMI14()` converts displayed percent duties back to firmware bytes with:

```text
round(percent / 100 * 255)
```

Then it sends this 256-byte package 14 payload:

```text
0x02 CPU.T2,  0x03 CPU.D2_raw
0x04 CPU.T3,  0x05 CPU.D3_raw
0x06 GPU1.T2, 0x07 GPU1.D2_raw
0x08 GPU1.T3, 0x09 GPU1.D3_raw
0x0A GPU2.T2, 0x0B GPU2.D2_raw
0x0C GPU2.T3, 0x0D GPU2.D3_raw

0x0E..0x13 CPU R12/R23/R34, high byte then low byte
0x14..0x19 GPU1 R12/R23/R34, high byte then low byte
0x1A..0x1F GPU2 R12/R23/R34, high byte then low byte
```

The slope fields are computed by `Load_Rxx()`:

```text
R12 = round(((D2 - D1) / (T2 - T1)) * 2.55 * 16)
R23 = round(((D3 - D2) / (T3 - T2)) * 2.55 * 16)
R34 = round(((D4 - D3) / (T4 - T3)) * 2.55 * 16)
```

After package 14 succeeds, the app sets its in-memory mode to `6` (custom) and
calls `SetFanInfo()`. Separately, selecting the custom radio button calls
`SetFanMode(6)`, which is a `SetWMI(121, 1, 6)` hardware write plus an
AppSettings write.

`SetFanInfo()` persists the UI curve to driver-backed AppSettings page 4, offset
0, length 256. This uses `WriteAppSettings` / IOCTL `0x32240c`, not a normal
file or registry value observed from the .NET app. The app-settings layout is:

```text
0x00..0x03 fan app version
0x04       InitFanMode
0x05       FanMode
0x06       FanCount
0x07       FanOffset

CPU  at 0x10..0x21:
  D1,D2,D3,D4=100,D2_default,D3_default,
  T1,T2,T3,T4=100,T2_default,T3_default,
  R12 low/high, R23 low/high, R34 low/high

GPU1 at 0x22..0x33: same shape
GPU2 at 0x34..0x45: same shape
```

Persistence conclusion: Windows definitely saves the selected curve for Windows
and can reapply it through the service/app stack. Static analysis does not prove
that the package 14 EC runtime table survives into Linux. It may survive a warm
reboot or sleep if the EC state is not reset, but Linux will not run Clevo
Control Center to reapply package 14 or custom mode 6. Louder fans on Windows
are therefore consistent with Windows actively applying a custom/aggressive
curve, while quieter Linux behavior is consistent with firmware automatic mode
or an EC state reset.

## ACPI/WMI map

`pkexec` successfully produced a desktop privilege prompt for the read-only ACPI
dump. No terminal sudo password entry was needed.

The important devices are in `ssdt4.dsl`:

```text
\_SB.DCHU  HID CLV0001
\_SB.DCHP  HID CLV0002
\_SB.WMI   HID PNP0C14
```

Linux exposes the relevant WMI method device as:

```text
/sys/bus/wmi/devices/ABBC0F6D-8EA1-11D1-00A0-C90629100000-31
guid      ABBC0F6D-8EA1-11D1-00A0-C90629100000
object_id BB
```

The `PNP0C14` WMI device dispatches object `BB` through `WMBB(Arg0, Arg1,
Arg2)`. `Arg1` selects the command/package:

```text
0x0C / 12 -> DEVT, live fan telemetry package
0x0D / 13 -> EEVT, fan table/status package
0x0E / 14 -> FEVT, custom fan table write package
0x11 / 17 -> AMVT, unknown/empty package
else      -> ZEVT, scalar command dispatcher
```

`DCHU` exposes the same core methods through `_DSM` for the Windows
`AcpiBridge.sys` / `InsydeDCHU.dll` path.

### Package 12, live fan telemetry

`DEVT` reads EC command `0xC0` and returns a 256-byte buffer. The app's decoded
fan offsets match this package:

```text
0x02..0x03 -> CPU RPM
0x04..0x05 -> GPU1 RPM
0x06..0x07 -> GPU2 RPM
0x10       -> CPU fan duty
0x13       -> GPU1 fan duty
0x16       -> GPU2 fan duty
```

Calling this package would still execute ACPI that writes EC command registers
as part of the read transaction, so it is not the same risk category as passive
sysfs reads.

### Package 13, fan table/status

`DCHU.EEVT` returns fan count and the firmware fan table:

```text
0x0C -> EC.FANC, fan count
0x10 -> P1F1, 0x11 -> P1D1
0x12 -> P2F1, 0x13 -> P2D1
0x14 -> P3F1, 0x15 -> P3D1
0x16 -> P4F1, 0x17 -> P4D1
0x18 -> P1F2, 0x19 -> P1D2
0x1A -> P2F2, 0x1B -> P2D2
0x1C -> P3F2, 0x1D -> P3D2
0x1E -> P4F2, 0x1F -> P4D2
0x20 -> P1F3, 0x21 -> P1D3
0x22 -> P2F3, 0x23 -> P2D3
0x24 -> P3F3, 0x25 -> P3D3
0x26 -> P4F3, 0x27 -> P4D3
0x2B -> EC.KPCR
```

`WMI.EEVT` mostly returns cached/global table data and updates `0x2B`; the
Windows fan app appears to use the `DCHU`/bridge path for this package.

### Confirmed write paths to avoid

```text
Package 14 / FEVT:
  writes custom fan table thresholds/duties into EC fields P2F*, P2D*, P3F*,
  P3D*, SH**, SL**.

ZEVT command 0x68 / 104:
  SetFanDuty, writes per-fan duty bytes through EC command 0xC1.

ZEVT command 0x69 / 105:
  SetFanAutoDuty, writes auto-duty selectors through EC command 0xC1.

ZEVT command 0x79 / 121:
  SetFanMode, fan offset, defaults, and related thermal/fan feature writes.
```

## Linux observations

Linux exposes many WMI GUIDs under `/sys/bus/wmi/devices`, including standard
BMOF GUIDs and vendor-specific GUIDs. The Clevo method GUID/object is present as
`ABBC0F6D...` / `BB`.

No standard hwmon fan RPM or PWM controls are exposed under `/sys/class/hwmon`.
`nbfc_service` is installed but inactive, and there is no exact NBFC config for
`Notebook NH5xAx`.

## Safest next step

Remain in static analysis unless explicitly deciding to run an ACPI/WMI getter.
The lowest-risk runtime probe would be package `12` telemetry only, but it is
not purely passive: ACPI writes EC command/data registers to perform the read.
Do not run it until the caller accepts that risk.

## Runtime one-shot read

On 2026-05-19, one logged runtime telemetry read was performed:

```text
Log file: /home/s/Desktop/clevo-acpi-re/fan-read-20260519-200158.log
ACPI call: \_SB.WMI.WMBB 0x0 0x0c 0x0
```

Reason for using `WMBB` instead of `_DSM`: `WMBB` is the exposed WMI method
entry point, acquires the same EC mutex, selects package `12`, and only needs
integer arguments. This avoids `acpi_call`'s lack of ACPI package argument
support for `_DSM` Arg3.

The call succeeded once. No setters were called. `acpi_call` was loaded from a
locally built module, then unloaded afterward. `/proc/acpi/call` was absent
again after cleanup.

Raw result prefix captured by `acpi_call`:

```text
{0x00, 0x00, 0x01, 0xe7, 0x01, 0xe3, 0x00, 0x00,
 0x00, 0x75, 0x89, 0x30, 0x00, 0x00, 0x00, 0x00,
 0x75, 0x3c, 0x58, 0xd8, 0x01, 0x41, 0x00, 0x01,
 0x00, 0x01, ...}
```

Decoded with the package-12 offsets:

```text
CPU fan speed field:  487
GPU1 fan speed field: 483
GPU2 fan speed field: 0
CPU temp byte:        88
GPU1 temp byte:       65
```

The temperature bytes line up with concurrent Linux readings. The speed fields
are not literal RPM. `FanSpeedSetting` stores the package-12 fields as `rpm`,
then displays:

```text
display_rpm = round((60 / (0.00005565217391304348 * raw_field)) * 2)
```

So lower raw fields mean higher displayed RPM. The duty bytes from the `WMBB`
entry point should not be treated as reliable yet because `WMI.DEVT` differs
slightly from `DCHU.DEVT` at the duty offset used by the Windows fan app.

## Runtime max-mode write

On 2026-05-19, one narrow fan-mode write was performed:

```text
Helper: /home/s/Desktop/clevo-acpi-re/clevo-fan-mode-write.zsh
Log:    /home/s/Desktop/clevo-acpi-re/fan-mode-max-20260519-192555.log
Write:  \_SB.WMI.WMBB 0x0 0x79 0x01000001
Meaning: command 121 / 0x79, subcommand 1, mode 1 = max fan
Result: 0x0
```

No package 14 fan-table write, direct duty write, auto-duty write, or fan-offset
write was performed. The user immediately reported hearing the fans, confirming
the mode write took effect.

Telemetry immediately after the write:

```text
CPU fan speed field:  354
GPU1 fan speed field: 424
GPU2 fan speed field: 0
CPU duty-ish byte:    204
CPU temp-ish byte:    84
GPU1 duty byte:       255
GPU1 temp byte:       64
```

A follow-up read was performed while max mode was active:

```text
Log: /home/s/Desktop/clevo-acpi-re/fan-read-after-max-20260519-202644.log

CPU fan speed field:  314
GPU1 fan speed field: 423
GPU2 fan speed field: 0
CPU duty-ish byte:    204
CPU temp-ish byte:    87
GPU1 duty byte:       255
GPU1 temp byte:       62
```

The `acpi_call` module was unloaded after the follow-up read.

## Runtime auto-mode rollback

On 2026-05-19, the fan mode was switched back to automatic:

```text
Helper: /home/s/Desktop/clevo-acpi-re/clevo-fan-mode-write.zsh
Log:    /home/s/Desktop/clevo-acpi-re/fan-mode-auto-20260519-192801.log
Write:  \_SB.WMI.WMBB 0x0 0x79 0x01000000
Meaning: command 121 / 0x79, subcommand 1, mode 0 = automatic fan
Result: 0x0
```

Telemetry before the rollback write:

```text
CPU fan speed field:  315
GPU1 fan speed field: 424
GPU2 fan speed field: 0
CPU duty-ish byte:    204
CPU temp-ish byte:    85
GPU1 duty byte:       255
GPU1 temp byte:       63
```

Telemetry three seconds after the rollback write:

```text
CPU fan speed field:  394
GPU1 fan speed field: 528
GPU2 fan speed field: 0
CPU duty-ish byte:    117
CPU temp-ish byte:    86
GPU1 duty byte:       195
GPU1 temp byte:       62
```

The duty bytes dropped from max-mode values, while the speed fields can lag or
continue changing as the fans spin down/up physically. The `acpi_call` module was
unloaded after the rollback helper completed.

## Per-fan direct duty path

The tested `fan_max.sh` / `fan_auto.sh` path uses the Windows app's preset mode
write:

```text
SetFanMode(mode) -> SetWMI(121, 1, mode)
```

That path is global and does not expose a separate CPU/GPU fan selector.

Windows also exposes a lower-level per-channel duty path through
`DCHUService.exe` method `SetFanDuty`, mapped to WMI/ACPI command `104` /
`0x68`. ACPI shows this command writes four manual duty bytes through EC command
`0xC1`:

```text
Arg2 byte 0 -> fan channel 1 duty, EC FDAT=1
Arg2 byte 1 -> fan channel 2 duty, EC FDAT=2
Arg2 byte 2 -> fan channel 3 duty, EC FDAT=3
Arg2 byte 3 -> fan channel 4 duty, EC FDAT=4
```

There is a matching auto-duty rollback method, `SetFanAutoDuty`, mapped to
command `105` / `0x69`. Its bitmask selects fan channels to return to automatic:

```text
Arg2 bit 0 -> channel 1 auto
Arg2 bit 1 -> channel 2 auto
Arg2 bit 2 -> channel 3 auto
Arg2 bit 3 -> channel 4 auto
```

This is more direct and riskier than preset mode. A command-104 payload writes
all four channels in one call, so setting only "fan 2" safely would require
knowing what to write for the other channels as well. If this path is ever
tested, the safest high-duty experiment would be all channels max first, with
`SetFanAutoDuty(0x0F)` and/or preset auto mode ready as rollback.

## Runtime direct all-channel max duty write

On 2026-05-19, one direct duty write was performed:

```text
Helper: /home/s/Desktop/clevo-acpi-re/clevo-fan-direct-duty.zsh
Log:    /home/s/Desktop/clevo-acpi-re/fan-direct-all-max-20260519-193721.log
Write:  \_SB.WMI.WMBB 0x0 0x68 0xffffffff
Meaning: command 104 / 0x68, channels 1..4 duty 0xff
Result: 0x68
```

Telemetry before the direct duty write:

```text
CPU raw speed field:  493, display RPM estimate: 4374
GPU1 raw speed field: 483, display RPM estimate: 4464
GPU2 raw speed field: 0
CPU duty-ish byte:    117
CPU temp-ish byte:    80
GPU1 duty byte:       216
GPU1 temp byte:       66
```

Telemetry three seconds after the direct duty write:

```text
CPU raw speed field:  335, display RPM estimate: 6437
GPU1 raw speed field: 426, display RPM estimate: 5062
GPU2 raw speed field: 0
CPU duty-ish byte:    204
CPU temp-ish byte:    79
GPU1 duty byte:       255
GPU1 temp byte:       66
```

The matching rollback command for this direct-duty path is:

```text
\_SB.WMI.WMBB 0x0 0x69 0x0000000f
```

The helper exposes that as:

```text
/home/s/Desktop/clevo-acpi-re/clevo-fan-direct-duty.zsh auto-all
```

The `acpi_call` module was unloaded after the direct all-channel max run.

## Runtime direct all-channel auto-duty rollback

On 2026-05-19, the matching direct-duty rollback was performed:

```text
Helper: /home/s/Desktop/clevo-acpi-re/clevo-fan-direct-duty.zsh
Log:    /home/s/Desktop/clevo-acpi-re/fan-direct-auto-all-20260519-193833.log
Write:  \_SB.WMI.WMBB 0x0 0x69 0x0000000f
Meaning: command 105 / 0x69, return channels 1..4 to auto-duty
Result: 0x69
```

Telemetry before the rollback:

```text
CPU raw speed field:  315, display RPM estimate: 6845
GPU1 raw speed field: 425, display RPM estimate: 5074
GPU2 raw speed field: 0
CPU duty-ish byte:    204
CPU temp-ish byte:    83
GPU1 duty byte:       255
GPU1 temp byte:       63
```

Telemetry three seconds after the rollback:

```text
CPU raw speed field:  398, display RPM estimate: 5418
GPU1 raw speed field: 528, display RPM estimate: 4084
GPU2 raw speed field: 0
CPU duty-ish byte:    117
CPU temp-ish byte:    90
GPU1 duty byte:       193
GPU1 temp byte:       63
```

The duty bytes returned to auto-managed values. The `acpi_call` module was
unloaded after the rollback run.

## Thermal-throttle fan hysteresis

`/usr/local/bin/thermal-throttle` now includes automatic fan escalation through
the tested direct-duty helper:

```text
Fan max:
  temp > 90 C for 3 seconds
  temp >= 95 C for 1 second

Fan auto:
  temp <= 85 C for 10 seconds
  temp <= 75 C for 3 seconds
  temp <= 70 C for 1 second
```

On service startup the fan state is treated as `unknown`, so either the hot-side
or cool-side hysteresis can resolve the actual EC state. The installed update
was backed up at:

```text
/usr/local/bin/thermal-throttle.backup-20260526-212017
```

After the restart on 2026-05-26, the new cool hysteresis resolved startup state
by returning all fans to auto at 79 C:

```text
/home/s/Desktop/clevo-acpi-re/fan-direct-auto-all-20260526-212026.log
```
