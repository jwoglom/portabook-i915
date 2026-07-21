# Fix 2 — GOP-vs-i915 MIPI register diff (run ON the Portabook)

Goal: capture the DSI link registers in the **known-good GOP state** and in the
**broken i915 state**, then diff them. The differing field is the bug.

All offsets below are **absolute MMIO byte offsets** for Cherry Trail
(`cherryview`), where the MIPI block base is `VLV_DISPLAY_BASE = 0x180000`
and the per-port register offsets are added to it. Port A = MIPIA, Port C =
MIPIC. `intel_reg` reads MMIO through the PCI BAR and works whether or not
i915 is bound.

## Register map (Cherry Trail, base 0x180000)

| Register (per port)          | Port A (MIPIA) | Port C (MIPIC) | What it holds |
|------------------------------|----------------|----------------|---------------|
| MIPI_DEVICE_READY            | `0x18b000`     | `0x18b800`     | block enabled / device ready |
| **MIPI_DSI_FUNC_PRG**        | `0x18b00c`     | `0x18b80c`     | **pixel format [10:7] + lane count [2:0]** |
| MIPI_DPI_RESOLUTION          | `0x18b020`     | `0x18b820`     | vactive<<16 \| hactive |
| MIPI_HIGH_LOW_SWITCH_COUNT   | `0x18b044`     | `0x18b844`     | HS/LP switch timing |
| MIPI_INIT_COUNT              | `0x18b050`     | `0x18b850`     | init counter |
| MIPI_VIDEO_MODE_FORMAT       | `0x18b058`     | `0x18b858`     | burst/non-burst + sync-events |
| **MIPI_DPHY_PARAM**          | `0x18b080`     | `0x18b880`     | D-PHY prep/clk/hs timing |
| MIPI_CLK_LANE_SWITCH_TIME_CNT| `0x18b088`     | `0x18b888`     | clock-lane switch timing |
| **MIPI_CTRL**                | `0x18b104`     | `0x18b904`     | escape clk div, RGB order, clock-stop |
| **MIPI_PORT_CTRL (A)**       | `0x1e1190`     | —              | DPI_ENABLE[31], **DUAL_LINK[26]** |
| **MIPI_PORT_CTRL (C)**       | —              | `0x1e1700`     | port C enable → **dual-link tell** |

### How to decode MIPI_DSI_FUNC_PRG (the prime suspect)
Bits `[10:7]` = video pixel format:
- `1` (`0x080`) = RGB565
- `2` (`0x100`) = RGB666 **packed**
- `3` (`0x180`) = RGB666 loosely packed
- `4` (`0x200`) = RGB888

Bits `[2:0]` = programmed data-lane count (4 for this panel → `0x4`).

So a correct 4-lane RGB888, channel 0, video-mode value is `0x204`. If the GOP
programs `0x104` (RGB666 packed) while i915 programs `0x204` (RGB888) — or vice
versa — that single-nibble difference is very likely the entire garble bug, and
`i915.dsi_pixel_format_override` (Fix 1) fixes it without a code change.

### How to read dual-link (the center-band suspect)
`MIPI_PORT_CTRL` bit `[31]` = DPI_ENABLE. Read **both** port A (`0x1e1190`) and
port C (`0x1e1700`):
- Only port A enabled in **both** states → single link; center band is not dual-link.
- Port C enabled in one state but not the other → dual-link handling differs.
  Bit `[26]` distinguishes front/back vs pixel-alternate. Test with
  `i915.dsi_dual_link_override`.

## Procedure

Install tools (on the Portabook):
```bash
sudo apt-get install intel-gpu-tools
```

### A. Capture the known-good GOP state
Boot with i915 KMS disabled so the DSI block keeps the firmware programming:
add `i915.modeset=0` to the kernel cmdline for one boot (GRUB: press `e`, append
to the `linux` line, Ctrl-X). **Do not** add noapic/noacpi/irqpoll.

```bash
sudo tee /tmp/gop.txt >/dev/null <<'EOF'
EOF
for off in 0x18b000 0x18b00c 0x18b020 0x18b044 0x18b050 0x18b058 \
           0x18b080 0x18b088 0x18b104 \
           0x18b800 0x18b80c 0x18b820 0x18b880 0x18b888 0x18b904 \
           0x1e1190 0x1e1700; do
  printf "%s " "$off" | sudo tee -a /tmp/gop.txt
  sudo intel_reg read $off | tee -a /tmp/gop.txt
done
```

### B. Capture the broken i915 state
Reboot normally (garbled panel, i915 bound). Re-run the same loop writing to
`/tmp/i915.txt`.

### C. Diff
```bash
diff -u /tmp/gop.txt /tmp/i915.txt
```
Any differing line is a candidate. In priority order the field most likely to
differ is **FUNC_PRG (0x18b00c / 0x18b80c)** pixel format, then **PORT_CTRL C
(0x1e1700)** enable (dual-link), then **DPHY_PARAM / CTRL** timing.

### D. Confirm with the driver's own log
With the patched module loaded (normal boot), the driver prints exactly what it
programs — grep for it:
```bash
sudo dmesg | grep -iE 'DSI prepare port|overriding pixel format|overriding dual_link'
```
The `FUNC_PRG=0x...` value logged here should equal what you read from
`0x18b00c`. Compare it against the GOP capture from step A.

## Turning a finding into a fix
- **FUNC_PRG pixel format differs** → boot with `i915.dsi_pixel_format_override=N`
  set to whichever value matches the GOP (`0`=RGB888, `1`=RGB666 loose,
  `2`=RGB666 packed, `3`=RGB565). If it renders cleanly, that is the fix — make
  it permanent via the DMI quirk (Fix 3, see doc 03).
- **PORT_CTRL C enable differs** → test `i915.dsi_dual_link_override` (`0`=single,
  `1`=front-back, `2`=pixel-alternate).
- **DPHY/CTRL timing differs** → note the exact good value; this needs a small
  DMI-gated patch to force it (Fix 3).
