# i915 / Cherry Trail DSI: King Jim Portabook XMC10 internal panel garbled under KMS

**Status: DRAFT for maintainer review before filing (drm/intel gitlab or intel-gfx).**
Prepared from a hands-on debugging session; register values are from the actual device.
Serial numbers / UUIDs deliberately omitted.

## Summary

On the King Jim Portabook XMC10 (Intel Atom x5 "Cherry Trail" / cherryview),
the internal MIPI-DSI panel (`DSI-1`, native 1280x768) renders a garbled image
under i915 KMS, while the firmware GOP drives it correctly (visible under
`i915.modeset=0`). HDMI output and GPU acceleration work fine simultaneously.

Investigation found **two independent board-specific defects** that i915 can be
made to work around (patches below), but even with both applied the panel is
**still not fully correct** — it reaches a checkerboard/BIST-like state at native
1280x768. The residual cause is not yet isolated; this report documents
everything found so a CHV-DSI maintainer can take it further.

## Hardware / environment

- Device: **King Jim Portabook XMC10** (Japanese subnotebook).
- SoC: Intel Atom x5-E8000 class, **Cherry Trail (cherryview)**.
- GPU: `00:02.0 [8086:22b0] (rev 20)`, subsystem **Pegatron `[1b0a:01bc]`**.
- Internal display: **MIPI-DSI**, connector `DSI-1`, on **port C**, single link,
  4 data lanes.
- Panel is driven through a **TI DSI bridge/TCON at I2C address `0x6c`**
  (Linux `i2c-4`); the register block begins with the ASCII id `TI!`.
- Kernel: **6.14.0-37-generic** (Ubuntu 24.04 HWE base; distro Linux Mint 22.3).
- Firmware: 64-bit UEFI, American Megatrends, BIOS **R25**, date 2016-01-22.
- DMI (for a quirk match; `sys_vendor`/`product_name` are unset = "Default string"):
  - `board_vendor` = **AMI Corporation**
  - `board_name`   = **Cherry Trail FFD**
  - `board_version`= **Station17**

## Symptom

- **Normal i915 KMS boot:** internal panel garbled. The exact artifact depends on
  the DSI pixel format programmed (see Finding 1):
  - VBT default (RGB888): fine, uniform **vertical striping**, image otherwise
    coherent, with a brighter vertical band left of centre.
  - RGB666 packed: full **rainbow vertical scramble**.
  - RGB666 loose + working TCON init: **white checkerboard with lines**
    (looks like a bridge test pattern / no-lock).
- HDMI is perfect and i915 acceleration works throughout.
- **`i915.modeset=0` boot:** firmware GOP framebuffer via `simpledrm`, image is
  **clean** (locked to the GOP's 1024x768, stretched). This is the known-good
  reference: the firmware programs a working panel; i915 does not reproduce it.

## Panel / VBT parameters

- VBT signature `$VBT CHERRYVIEW`, BDB version 195, panel type 0.
- LFP mode: `1280x768`, VBT pixel clock **79500 kHz**
  (`60 79500 1280 1472 1536 1664 768 788 791 798`).
- i915 reads the GOP's current mode clock as **80000 kHz** and adopts it via
  `intel_fuzzy_clock_check()` ("Using GOP pclk").
- 4 lanes, video mode "non-burst with sync events", `MIPI_DPHY_PARAM = 0x24113f0c`.

## Findings

### 1. VBT pixel format is wrong (RGB888 vs actual RGB666 loosely packed)

The VBT advertises RGB888. The firmware GOP programs `MIPI_DSI_FUNC_PRG` (port C,
MMIO `0x18b80c`) with video format field 3 = **RGB666 loosely packed**
(`FUNC_PRG = 0x00000184`). Trusting the VBT (RGB888) yields the vertical
striping. Overriding `intel_dsi->pixel_format = MIPI_DSI_FMT_RGB666` makes i915
program `0x184`, byte-identical to the GOP. **Necessary, not sufficient.**

### 2. Panel-init MIPI I2C sequence is routed to the wrong (dead) i2c bus

The VBT MIPI init sequence issues ~35 I2C writes to the TCON at `0x6c` (regs
`0x05`, `0x0c`, `0x11`, `0xc0`-`0xc4`, ...). With default routing
(`intel_dsi->i2c_bus_num < 0` → VBT bus number / ACPI lookup) these are sent to
an i2c adapter that **times out** (`i2c_designware ...: controller timed out`),
so the TCON is never configured. The TCON actually lives on **Linux `i2c-4`**
(confirmed with `i2cdetect`; `0x6c` responds only on bus 4). Forcing
`intel_dsi->i2c_bus_num = 4` makes all 35 writes succeed. This is the same class
of bug already handled for the Lenovo Yoga Tab 2/3 in `vlv_dsi.c`.

There is also a separate set of 5 writes to `0x7e` reg `0xf8` (VBT bus 2) that
fail on every bus — `0x7e` is present on no bus (phantom, Surface-3-like).
Harmless; can be skipped cosmetically.

### 3. DSI link MMIO registers are identical between firmware and i915

Dumped via `intel_reg` on port C in the clean (`i915.modeset=0`) and garbled
(i915) states — **byte-for-byte identical**:

| register (port C)              | offset     | value      |
|--------------------------------|------------|------------|
| MIPI_DSI_FUNC_PRG              | `0x18b80c` | `0x00000184` |
| MIPI_DPI_RESOLUTION           | `0x18b820` | `0x03000500` (1280x768) |
| MIPI_HIGH_LOW_SWITCH_COUNT    | `0x18b844` | `0x0000001d` |
| MIPI_INIT_COUNT               | `0x18b850` | `0x000007d0` |
| MIPI_VIDEO_MODE_FORMAT        | `0x18b858` | `0x0000001e` |
| MIPI_DPHY_PARAM               | `0x18b880` | `0x24113f0c` |
| MIPI_CLK_LANE_SWITCH_TIME_CNT | `0x18b888` | `0x0022000f` |
| MIPI_CTRL                     | `0x18b904` | `0x00000018` |
| MIPI_PORT_CTRL (C)            | `0x1e1700` | `0x00000000` |

So the DSI **link** programming is not the differentiator.
(Caveat: the `i915.modeset=0` captures were warm reboots and may reflect i915's
leftover programming; a cold-boot capture of the true GOP state is still TODO.)

### 4. Pixel clock is achievable exactly; adoption works

`vlv_dsi_pll.c`: target `dsi_clk = pclk*bpp/lanes = 80000*24/4 = 480000 kHz`.
On CHV (`ref_clk=100000, n=4, m∈[70,96], p∈[2,6]`), `m=96, p=5` gives exactly
`96*100000/(5*4) = 480000` — delta 0. So the clock is exactly hittable and i915
adopts the GOP value, making a pure clock-rounding explanation unlikely.

### 5. Bridge (`0x6c`) register comparison — inconclusive

`i2cdump` of the TCON in clean vs garbled states differed in only 3 bytes
(`0x34`, `0x36`, `0x93`). These proved **volatile/status** (`0x93` returned three
different values on successive reads; writes did not stick), so the comparison is
inconclusive — the bridge's persistent configuration appears the same in both
states.

## Two partial fixes (proposed quirk — does NOT fully resolve)

A DMI-matched quirk in `vlv_dsi.c` (same shape as the existing BYT/CHT entries)
that applies both workarounds:

```c
static void vlv_dsi_kingjim_portabook_fixup(struct intel_dsi *intel_dsi)
{
	intel_dsi->pixel_format = MIPI_DSI_FMT_RGB666;   /* Finding 1 */
	intel_dsi->i2c_bus_num = 4;                      /* Finding 2 */
}
/* matched on DMI_BOARD_VENDOR "AMI Corporation" +
 * DMI_BOARD_NAME "Cherry Trail FFD" + DMI_BOARD_VERSION "Station17" */
```

With this applied: the pixel format matches the GOP and the TCON init writes
succeed — but the panel reaches the **checkerboard** state at native 1280x768
rather than a correct image.

## Current unresolved state

With format correct, TCON init succeeding, DSI link regs matching the firmware,
and the clock exactly hittable, the panel is still wrong at native 1280x768,
while the firmware renders cleanly at **1024x768**. The largest un-eliminated
variable is the **mode/resolution / full DSI video timing** (firmware 1024x768
vs i915 native 1280x768). The bridge's checkerboard output is consistent with a
PLL-not-locked / no-valid-input BIST pattern.

## Reproduction

1. King Jim Portabook XMC10, kernel 6.14.0-37-generic, i915 KMS.
2. Normal boot → internal `DSI-1` panel garbled; HDMI + accel fine.
3. Boot `i915.modeset=0` → internal panel clean (1024x768 stretched), no accel.

## Open questions for maintainers

1. Is there a known reason CHV DSI fails to lock this TI bridge at the VBT's
   native 1280x768 while the GOP drives 1024x768? Is the VBT LFP mode
   effectively wrong for this panel?
2. Should i915 be inheriting/forcing the GOP's exact DSI PLL divisors rather than
   recomputing (even when the target is exactly hittable)?
3. Is the full DSI DPI timing (HACTIVE/HFP/HSYNC/HBP/VFP/VSYNC/VBP) that i915
   programs identical to the GOP's? (Not yet dumped — needs `set_dsi_timings`
   register comparison, ideally from a cold `i915.modeset=0` boot.)

## Appendix: diagnostic instrumentation used

- Added `drm_info` in `intel_dsi_prepare()` logging the programmed
  `MIPI_DSI_FUNC_PRG`, lane count, pixel format, bpp, dual_link, dphy, hdisplay.
- `mipi_exec_i2c()` already logs each element at `drm_dbg_kms` level
  (`bus N target-addr 0x.. reg 0x.. data ..`) — captured with `drm.debug=0x4`
  and `journalctl -k` (kernel ring buffer wraps under heavier masks).
- `intel_reg read <offset>` for the port-C MMIO table above.
- `i2cdetect -l` / `i2cdetect -y <bus>` / `i2cdump -y 4 0x6c b` for the bridge.
