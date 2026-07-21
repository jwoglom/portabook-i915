# Fix 3 — make the fix permanent, gated by DMI (upstreamable shape)

Once doc 02 identifies the field the GOP programs differently, hard-code that
value for **this board only**, matched by DMI so other Cherry Trail devices are
unaffected. This mirrors the existing Hans de Goede BYT/CHT panel quirks.

## Step 1 — get the exact DMI strings from the Portabook
```bash
cat /sys/class/dmi/id/sys_vendor
cat /sys/class/dmi/id/product_name
cat /sys/class/dmi/id/board_name
# or: sudo dmidecode -t system -t baseboard
```
Fill the matched strings into `DMI_MATCH(...)` below. (Expected vendor is
"KING JIM"; confirm the exact casing/spacing on the device — DMI matches are
literal.)

## Step 2 — the quirk

Add to `drivers/gpu/drm/i915/display/intel_dsi_vbt.c`. This example forces the
pixel format; adapt the forced field to whatever the diff found.

```c
#include <linux/dmi.h>

/*
 * Some boards ship a VBT whose DSI color format disagrees with the format the
 * firmware GOP actually programs, producing a garbled internal panel under
 * i915. Force the known-good format on the affected board only.
 */
static const struct dmi_system_id dsi_pixel_format_quirk[] = {
	{
		/* King Jim Portabook — VBT says <X>, GOP programs <Y> */
		.matches = {
			DMI_MATCH(DMI_SYS_VENDOR, "KING JIM"),
			DMI_MATCH(DMI_PRODUCT_NAME, "<PRODUCT_NAME_FROM_DMI>"),
		},
		/* store the correct enum mipi_dsi_pixel_format in driver_data */
		.driver_data = (void *)(uintptr_t)MIPI_DSI_FMT_RGB666_PACKED,
	},
	{ }
};
```

In `intel_dsi_vbt_init()`, right after the existing
`intel_dsi->pixel_format = vbt_to_dsi_pixel_format(...)` assignment and the
module-param override block, apply the quirk:

```c
	{
		const struct dmi_system_id *id =
			dmi_first_match(dsi_pixel_format_quirk);

		if (id && display->params.dsi_pixel_format_override < 0) {
			intel_dsi->pixel_format =
				(enum mipi_dsi_pixel_format)(uintptr_t)id->driver_data;
			drm_info(&dev_priv->drm,
				 "DSI: applying board pixel-format quirk (%d)\n",
				 intel_dsi->pixel_format);
		}
	}
```

Note the `< 0` guard: a manual `i915.dsi_pixel_format_override=` on the cmdline
still wins over the quirk, which keeps the diagnostic parameters useful for
testing even after the quirk lands.

## If the differing field is dual-link or DPHY/CTRL timing instead
Same pattern, different target:
- **dual-link**: force `intel_dsi->dual_link` next to the assignment in
  `intel_dsi_vbt_init()` (values `DSI_DUAL_LINK_NONE/FRONT_BACK/PIXEL_ALT`).
- **DPHY/CTRL timing**: the value is programmed in `vlv_dsi.c`
  (`intel_dsi->dphy_reg` for `MIPI_DPHY_PARAM`, and `MIPI_CTRL` in
  `intel_dsi_prepare()`). Gate the forced write behind the same
  `dmi_first_match()` there.

## Step 3 — (optional, cosmetic) silence the phantom 0x7e / bus-2 tail writes
The `Failed to xfer payload of size (2) to reg (248)` spam is a VBT init-sequence
write to an unpopulated chip (`0x7e` on bus 2), the classic Surface-3 pattern.
It is harmless. If you want it gone, add a DMI-gated skip of the MIPI I2C
element in the VBT sequence executor (same place i915 handles the Surface 3
`MIPI_SEQ_ELEM_I2C` skip). Purely cosmetic — does not affect the garble.

## Rebuild & test
```bash
make -j$(nproc) M=drivers/gpu/drm/i915 LOCALVERSION=-37-generic modules
```
Reinstall/sign per doc 01, reboot, confirm the internal panel is clean at
1280x768 and HDMI + acceleration still work.
