# Portabook Cherry Trail DSI panel fix — deliverables

Build host: this Coder instance (x86_64 Ubuntu 24.04). Target device: King Jim
Portabook, Linux Mint 22.3 (Ubuntu 24.04 base), kernel **6.14.0-37-generic**.

## What's here
```
dist/i915.ko           patched module, debug-stripped (9.3 MB)
dist/i915.ko.zst       same, zstd-compressed as Ubuntu ships it (1.6 MB)
dist/portabook-dsi.patch   the source patch (4 files, applies -p1 to the tree)
docs/01-build-install-sign.md    build + install + MOK signing
docs/02-register-diff-runbook.md Fix 2: GOP-vs-i915 register diff (run on device)
docs/03-fix3-dmi-quirk-template.md Fix 3: permanent DMI-gated fix template
linux-hwe-6.14-6.14.0/  full prepared kernel source tree (for fast re-iteration)
```

## Status of the build (verified here)
- Source is the **exact** target: `linux-hwe-6.14` `6.14.0-37.37~24.04.1`.
- Built with gcc-13.3.0 (matches the kernel's `CONFIG_CC_VERSION_TEXT`).
- Compiles clean (no warnings on the changed files).
- **vermagic = `6.14.0-37-generic SMP preempt mod_unload modversions`** —
  byte-for-byte what the stock module requires (checked with `modinfo`).
- Built against the target's own `Module.symvers`, so MODVERSIONS symbol CRCs
  match. Final load acceptance is validated on the device (`insmod`/boot).
- Both new params show in `modinfo`: `dsi_pixel_format_override`,
  `dsi_dual_link_override`.

## What I could NOT do here
There is no Portabook attached to this build host, so I could not boot the
module, look at the panel, or read MMIO registers. The diagnosis loop
(register diff, trying each override, confirming a clean 1280x768 image) must be
run on the device — docs 02 and 03 are the runbooks for that.

## Recommended order on the Portabook
1. Install the patched module (doc 01), reboot normally. No behaviour change yet
   (all overrides default off); confirm HDMI + accel still fine and grab the new
   `DSI prepare port ...` line from `dmesg`.
2. **Fastest shot first (Fix 1):** try each pixel format without recompiling —
   boot with `i915.dsi_pixel_format_override=0` … `=3` (or set at runtime via
   `/sys/module/i915/parameters/` then re-trigger a modeset). If one yields a
   clean image, that's the fix.
3. If pixel format doesn't fix it, run the **register diff** (doc 02) to see
   exactly which field i915 programs differently from the GOP; if it's dual-link,
   try `i915.dsi_dual_link_override`.
4. Once the correct value is known, make it permanent and board-specific with the
   **DMI quirk** (doc 03), rebuild the module, reinstall.

## Iterating on a new candidate (on this build host)
```bash
cd linux-hwe-6.14-6.14.0
# edit files under drivers/gpu/drm/i915/display/ ...
make -j$(nproc) M=drivers/gpu/drm/i915 modules
strip --strip-debug drivers/gpu/drm/i915/i915.ko -o /tmp/i915.ko
zstd -19 -f /tmp/i915.ko -o /tmp/i915.ko.zst    # copy to device
```
`utsrelease.h` is already pinned to `6.14.0-37-generic`, so rebuilds keep the
correct vermagic. Only re-run `modules_prepare` if you `make clean`; if you do,
re-pin it: `cp hdr-extract/usr/src/linux-headers-6.14.0-37-generic/include/generated/utsrelease.h linux-hwe-6.14-6.14.0/include/generated/`.

## Safety
- Never add `noapic`/`noacpi`/`irqpoll` to any cmdline (breaks eMMC/boot).
- The original module is backed up (`i915.ko.zst.orig`) and the stock kernel
  remains a bootable fallback; HDMI and `i915.modeset=0` are always available.
