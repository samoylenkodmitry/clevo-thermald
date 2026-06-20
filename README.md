# clevo-thermald

Quiet, load-aware thermal control for **Clevo** laptops on Linux — CPU boost gating,
manual fan curves through the embedded controller (EC), and idle clock management.

Born from taming a **Clevo NH5xAx** (desktop **AMD Ryzen 9 3950X** + **RTX 2070**, no
iGPU, dual monitors) that idled hot and loud under Linux: AMD turbo would spike a core
to ~4 GHz on any background task, and the stock EC ran the **GPU fan at 80–100 % while
the GPU sat at 67 °C**. This daemon fixes both.

> ⚠️ **Disclaimer.** This writes to your laptop's embedded controller via `acpi_call`
> (the same WMI methods Clevo's Windows Control Center uses) and changes CPU frequency
> limits. It is tuned for specific hardware. **Wrong fan settings can let your machine
> overheat.** It ships with safety fallbacks (revert to the EC's own curve on
> exit/crash, emergency 100 % overrides), but you run it **at your own risk**. Read the
> [tuning](#configuration--tuning) and [safety](#safety-design) sections before relying
> on it, and keep an eye on temps the first time.

## Results (reference hardware, at idle)

| Fan | Stock EC auto | clevo-thermald |
|-----|---------------|----------------|
| **GPU** | ~95–100 % · ~5000 RPM | **~20 % · ~1240 RPM** |
| **CPU** | ~46 % · ~4450 RPM | **~31 % · ~3200 RPM** |

GPU held a safe ~67 °C, CPU ~75–81 °C — both with large headroom to their throttle
points (88 °C / 95 °C). The machine went from constantly audible to near-silent at idle,
while still ramping to full cooling and full clocks the moment real load arrives.

## What it does

1. **Dynamic CPU boost gating.** On AMD `acpi-cpufreq`, a frequency cap does **not**
   stop Core Performance Boost — boost is what spikes cores to high voltage on tiny
   background tasks and heats the chip at "idle." The daemon toggles
   `/sys/devices/system/cpu/cpufreq/boost` by smoothed CPU load: **off** when idle
   (quiet), **on** within ~3 s of sustained load (full speed when you need it).

2. **Manual fan curves through the EC.** Clevo laptops expose no standard hwmon PWM on
   Linux; the EC runs its own (over-aggressive) curve. Using the reverse-engineered WMI
   `SetFanDuty` command (`0x68`) the daemon drives **its own quiet curves** — CPU fan
   off smoothed `k10temp`, GPU fan off `nvidia-smi` temp — ramping firmly to 100 %
   before each chip's throttle point. Reverts to the EC's auto curve on exit/crash.

3. **Load-aware CPU clock control.** When idle/light the CPU is held at a low P-state
   (no point running max clock when nothing needs it — keeps it cool/quiet); full speed
   returns the instant load arrives; an emergency cap kicks in only if it stays
   dangerously hot under load.

4. **Per-process attribution.** While warm it tracks which process dominates the CPU, so
   every fan/clock event (journal + desktop notification) names the culprit *with PID* —
   so you can see exactly what's making noise.

## Hardware & requirements

**Tested on:** Clevo NH5xAx / CachyOS (Arch), Ryzen 9 3950X, RTX 2070, kernel 7.x.

It should work on other Clevo/Tongfang units that use the same WMI fan interface
(`\_SB.WMI.WMBB`, object `BB`), and the CPU layers work on any AMD box using
`acpi-cpufreq` + `k10temp`. **The fan duty/curve values are hardware-specific — retune
them.** See [Adapting to other hardware](#adapting-to-other-hardware).

Dependencies:

- [`acpi_call-dkms`](https://github.com/nix-community/acpi_call) (AUR) — provides
  `/proc/acpi/call`. DKMS so it survives kernel updates.
- `cpupower` (CPU frequency control), `zsh`, `bash`, `util-linux` (`logger`), `gawk`
- `nvidia-smi` (optional — only for the GPU fan curve; without it the GPU fan uses a
  safe fallback duty, or set `GPU_POLL_SECS=0` to leave the GPU fan to the EC)
- `lm_sensors` recommended for sanity-checking temps

## Install

```sh
git clone https://github.com/samoylenkodmitry/clevo-thermald
cd clevo-thermald
sudo ./install.sh
```

The installer checks dependencies, copies the daemon to `/usr/local/bin`, the helper
tools to `/usr/local/lib/clevo-thermald`, installs and enables the systemd service, and
makes `acpi_call` load on boot.

Verify:

```sh
systemctl status clevo-thermald
journalctl -t clevo-thermald -f                                   # live events
sudo zsh /usr/local/lib/clevo-thermald/clevo-fan-read-summary.zsh # actual fan RPM/duty
```

## Configuration & tuning

Everything lives in plainly-commented variables at the top of
`/usr/local/bin/clevo-thermald`. After editing: `sudo systemctl restart clevo-thermald`.

Highlights:

| Variable | Meaning |
|----------|---------|
| `CPU_FAN_T` / `CPU_FAN_D` | CPU fan curve: temperature points (°C) → duty (0–255) |
| `GPU_FAN_T` / `GPU_FAN_D` | GPU fan curve (vs `nvidia-smi` temp) |
| `CPU_FAN_EMERG` / `GPU_FAN_EMERG` | temps that force that fan to 100 % immediately |
| `GPU_POLL_SECS` | how often to read GPU temp (`0` = don't manage the GPU fan) |
| `BOOST_ON_BUSY` / `BOOST_OFF_BUSY` | load thresholds that gate CPU boost |
| `IDLE_BUSY` | below this busy% the CPU is treated as idle (clocks held low) |
| `IDLE_HOT` / `IDLE_COOL` / `LOAD_*` | the load-aware clock ladder |

Want it even quieter? Lower the first entries of `*_FAN_D`. Want it cooler/safer? Raise
them or lower the `*_T` points. The curves are interpolated linearly between points.

## Manual tools

Standalone helpers (run as root) for inspection and one-off control:

```sh
zsh lib/clevo-fan-read-summary.zsh        # live RPM / duty / temps for CPU+GPU fans
zsh lib/clevo-fan-direct-duty.zsh all-max # force all fans 100%
zsh lib/clevo-fan-direct-duty.zsh auto-all# hand fans back to the EC auto curve
zsh lib/clevo-fan-mode-write.zsh auto     # EC fan mode: auto|max|silent|maxq
```

(Note: the EC "silent" mode is firmware-dependent and on the reference unit made the GPU
fan *louder*, not quieter — the manual curves are the reliable path.)

## How it works

The daemon polls once per second:

- **Temps:** hottest `k10temp` for the CPU (smoothed over 5 s); `nvidia-smi` for the GPU.
- **Load:** aggregate busy% from `/proc/stat` deltas (smoothed), to gate boost and decide
  idle vs loaded.
- **Fans:** interpolates each curve, and only rewrites the EC (`0x68`) when a duty moves
  by ≥ `DUTY_DELTA` (avoids hammering the EC). EC payload byte order is
  `0x{ch4}{ch3}{ch2}{ch1}` with ch1=CPU, ch2=GPU.
- **Clocks:** `cpupower frequency-set -u` for the P-state ceiling; the global `boost`
  flag for turbo.

The full reverse-engineering of the Clevo WMI/EC fan interface (how the commands,
packages and byte offsets were derived) is in
[`docs/REVERSE-ENGINEERING.md`](docs/REVERSE-ENGINEERING.md).

## Safety design

- **Reverts to the EC's own curve on exit:** an `EXIT` trap calls `auto-all` (`0x69`), and
  the systemd unit's `ExecStopPost` does the same even on `SIGKILL` — so the fans can
  never get stuck at a low manual duty if the daemon dies.
- **Emergency overrides:** either fan jumps to 100 % at its `*_FAN_EMERG` temp regardless
  of the curve.
- **Safe fallback:** if `nvidia-smi` can't be read, the GPU fan uses a safe-high duty.
- **Refuses to start** if `/proc/acpi/call` isn't available (acpi_call missing).

## Adapting to other hardware

- **Different fan duties:** read your EC's behaviour with `clevo-fan-read-summary.zsh`,
  then set conservative curves and watch temps before lowering them.
- **No Nvidia GPU / different GPU:** set `GPU_POLL_SECS=0` (GPU fan tracks the CPU duty),
  or adapt `read_gpu_temp` to your GPU's sysfs/`sensors` source.
- **Different CPU temp sensor:** edit `get_max_temp` (it looks for `k10temp`).
- **A unit where `0x68`/`0x79` differ:** confirm against your own ACPI dump first; see the
  reverse-engineering notes. **If unsure, don't run the fan layer** (`GPU_POLL_SECS=0` and
  comment out `manage_fans`) — the boost/clock layers are harmless.

## Uninstall

```sh
sudo ./uninstall.sh
```

Returns the fans to the EC auto curve, re-enables CPU boost and full clocks, and removes
all installed files.

## Credits

- [`acpi_call`](https://github.com/nix-community/acpi_call) — the kernel module that makes
  this possible.
- Clevo WMI/EC fan interface reverse-engineered from the vendor's Windows Control Center
  (findings documented; no proprietary code is redistributed here).

## License

[MIT](LICENSE) © Dmitry Samoylenko
