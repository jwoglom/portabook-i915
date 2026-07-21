# Portabook i915 DSI fix — build, install, and sign

## What was built
A patched `i915.ko` for **kernel 6.14.0-37-generic** (Ubuntu 24.04 / Mint 22.3
HWE), containing:

- **Fix 1** — two diagnostic module parameters (default off, no behaviour change
  unless set):
  - `i915.dsi_pixel_format_override=N` — override the VBT-parsed MIPI-DSI pixel
    format. `0`=RGB888, `1`=RGB666 loosely packed, `2`=RGB666 packed, `3`=RGB565.
    `-1` (default) = use VBT.
  - `i915.dsi_dual_link_override=N` — override VBT dual-link mode. `0`=single,
    `1`=dual front-back, `2`=dual pixel-alternate. `-1` (default) = use VBT.
- A one-line `drm_info` log at DSI enable time printing the exact
  `MIPI_DSI_FUNC_PRG` value, lane count, pixel format, bpp, dual_link and DPHY
  it programs — for the register diff (doc 02).

Source changed (all under `drivers/gpu/drm/i915/`):
`display/intel_display_params.[ch]`, `display/intel_dsi_vbt.c`, `display/vlv_dsi.c`.

## How it was built (on this build host, reproducible)
```bash
# exact-match source + headers
sudo sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources  # or add a deb-src stanza
sudo apt-get update
sudo apt-get install build-essential flex bison bc libssl-dev libelf-dev libdw-dev dpkg-dev dwarves
# NB: dwarves (pahole) is REQUIRED. Without it, olddefconfig silently drops
# CONFIG_DEBUG_INFO_BTF_MODULES, which shrinks struct module and makes the
# built module fail to load with ".gnu.linkonce.this_module section size must
# match the kernel's built struct module size" (even though vermagic matches).
apt-get source linux-image-unsigned-6.14.0-37-generic
apt-get download linux-headers-6.14.0-37-generic     # for .config + Module.symvers

cd linux-hwe-6.14-6.14.0
cp <headers>/.config .config
cp <headers>/Module.symvers Module.symvers
# Ubuntu pins the release string to 6.14.0 though the stable base is 6.14.11:
sed -i 's/^SUBLEVEL = .*/SUBLEVEL = 0/' Makefile
make olddefconfig
make -j$(nproc) modules_prepare
make -j$(nproc) M=drivers/gpu/drm/i915 LOCALVERSION=-37-generic modules
# => drivers/gpu/drm/i915/i915.ko  (vermagic: 6.14.0-37-generic SMP preempt mod_unload modversions)
```
Iterating on a candidate is just the last `make M=...` line (minutes), then
copy the `.ko` to the device.

## Install on the Portabook

**Keep the stock kernel/module as a fallback.** Back up the shipped module first:

```bash
# on the Portabook, as root
KV=6.14.0-37-generic
sudo cp -v /lib/modules/$KV/kernel/drivers/gpu/drm/i915/i915.ko.zst \
           /lib/modules/$KV/kernel/drivers/gpu/drm/i915/i915.ko.zst.orig
```
(Ubuntu ships modules zstd-compressed as `i915.ko.zst`.)

Copy the patched module over and install it compressed:
```bash
zstd -19 -f i915.ko -o i915.ko.zst
sudo cp i915.ko.zst /lib/modules/$KV/kernel/drivers/gpu/drm/i915/i915.ko.zst
sudo depmod -a $KV
sudo update-initramfs -u -k $KV     # i915 is usually in the initramfs for KMS
```

Verify the module matches the running kernel before rebooting:
```bash
modinfo /lib/modules/$KV/kernel/drivers/gpu/drm/i915/i915.ko.zst | grep -E 'vermagic|filename'
# vermagic must read exactly: 6.14.0-37-generic SMP preempt mod_unload modversions
```

## Secure Boot / module signing

Check firmware state:
```bash
mokutil --sb-state
```

### If Secure Boot is **disabled**
Nothing to do — unsigned modules load. (Confirm with `mokutil --sb-state`.)

### If Secure Boot is **enabled** (self-built modules must be signed)
Ubuntu's build key is private, so sign with your own MOK.

1. Create a MOK key pair (once), on the Portabook:
```bash
sudo mkdir -p /var/lib/shim-signed/mok
cd /var/lib/shim-signed/mok
sudo openssl req -new -x509 -newkey rsa:2048 -nodes -days 36500 \
     -keyout MOK.priv -outform DER -out MOK.der \
     -subj "/CN=Portabook i915 local module signing/"
```
2. Enrol it (prompts for a one-time password, entered again in the blue MOK
   Manager screen on next reboot):
```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
sudo reboot   # choose "Enroll MOK" -> Continue -> enter the password
```
3. Sign the module (the hash must match `CONFIG_MODULE_SIG_HASH`, which is
   **sha512** for this kernel):
```bash
KV=6.14.0-37-generic
KDIR=/usr/src/linux-headers-$KV       # provides scripts/sign-file
sudo zstd -d /lib/modules/$KV/kernel/drivers/gpu/drm/i915/i915.ko.zst -o /tmp/i915.ko
sudo "$KDIR/scripts/sign-file" sha512 \
     /var/lib/shim-signed/mok/MOK.priv \
     /var/lib/shim-signed/mok/MOK.der \
     /tmp/i915.ko
sudo zstd -19 -f /tmp/i915.ko -o /lib/modules/$KV/kernel/drivers/gpu/drm/i915/i915.ko.zst
sudo depmod -a $KV && sudo update-initramfs -u -k $KV
```
   (Note: `CONFIG_MODULE_SIG_FORCE` is **not** set on this kernel, so an unsigned
   module still loads even under Secure Boot unless you have separately enabled
   lockdown; signing is the clean path and avoids tainting/lockdown surprises.)

## Recovery if the internal panel is worse / no display
You always have HDMI, and two fallbacks:
- Restore the original module:
  `sudo mv i915.ko.zst.orig i915.ko.zst && sudo depmod -a && sudo update-initramfs -u`
- Or boot the previous/stock kernel from the GRUB "Advanced options" menu.
- Or one-shot `i915.modeset=0` for a legible (1024x768 stretched) internal panel.

Never add `noapic`, `noacpi`, or `irqpoll` — that breaks eMMC detection/boot.
