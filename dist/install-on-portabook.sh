#!/usr/bin/env bash
# Install (or verify) the patched i915 module on the King Jim Portabook
# (Linux Mint 22.3 / kernel 6.14.0-37-generic).
#
# The fix is automatic: a DMI quirk matches this board and forces the DSI
# panel's pixel format to RGB666 (loosely packed), which is what the firmware
# GOP uses. No kernel boot parameter is needed.
#
# Usage:
#   ./install-on-portabook.sh          install the module
#   ./install-on-portabook.sh verify   (after reboot) check that it worked
#
# Run FROM the directory that contains i915.ko.zst.  Safe to re-run.
set -euo pipefail

KV=6.14.0-37-generic
DIR=/lib/modules/$KV/kernel/drivers/gpu/drm/i915
KO_ZST="$(dirname "$0")/i915.ko.zst"
FUNC_PRG_PORT_C=0x18b80c        # MIPI_DSI_FUNC_PRG, port C (CHT base 0x180000 + 0xb80c)
EXPECT_FUNC_PRG=0x00000184      # RGB666 loose (video format 3) + 4 lanes == what the GOP programs

warn_stale_override() {
  # A leftover i915.dsi_pixel_format_override= on the cmdline WINS over the
  # quirk (by design, for diagnostics) and will re-break the panel. Flag it.
  if grep -q 'i915.dsi_pixel_format_override=' /etc/default/grub 2>/dev/null; then
    echo "!! WARNING: /etc/default/grub still sets i915.dsi_pixel_format_override="
    echo "   Remove it from GRUB_CMDLINE_LINUX_DEFAULT and run 'sudo update-grub'."
    echo "   The quirk now sets the correct format automatically; a stale value"
    echo "   (especially =2) overrides it and brings the garble back."
  fi
}

# ---------------------------------------------------------------- verify mode
if [ "${1:-}" = "verify" ]; then
  echo "== running kernel =="; uname -r
  echo "== i915 loaded? =="
  if lsmod | grep -q '^i915'; then echo "   yes"; else
    echo "   NO - i915 is not loaded; you are on the firmware framebuffer."
    echo "   Try: sudo modprobe i915 ; sudo dmesg | tail -20"
  fi
  echo "== renderer (want 'Mesa Intel', not llvmpipe) =="
  if command -v glxinfo >/dev/null; then glxinfo -B 2>/dev/null | grep -i 'renderer' || echo "   (no GLX output)"; else
    echo "   glxinfo not installed (apt-get install mesa-utils)"; fi
  echo "== DSI programming (driver log) =="
  sudo dmesg | grep 'DSI prepare port' | tail -1 || echo "   (no 'DSI prepare port' line - patched i915 not active)"
  echo "== FUNC_PRG port C (want $EXPECT_FUNC_PRG) =="
  if command -v intel_reg >/dev/null; then
    got=$(sudo intel_reg read $FUNC_PRG_PORT_C 2>/dev/null | grep -oE '0x[0-9a-fA-F]{8}' | tail -1 || true)
    echo "   read $FUNC_PRG_PORT_C = ${got:-?}"
    [ "$got" = "$EXPECT_FUNC_PRG" ] && echo "   MATCH - format matches the GOP (fixed)." \
                                    || echo "   mismatch - format is NOT what the GOP uses."
  else
    echo "   intel_reg not installed (apt-get install intel-gpu-tools)"
  fi
  warn_stale_override
  exit 0
fi

# --------------------------------------------------------------- install mode
if [ "$(uname -r)" != "$KV" ]; then
  echo "!! Running kernel is $(uname -r), expected $KV."
  echo "   Boot the $KV kernel first, or this module won't match. Aborting."
  exit 1
fi

[ -f "$KO_ZST" ] || { echo "!! i915.ko.zst not found next to this script."; exit 1; }

echo "== vermagic check =="
modinfo "$KO_ZST" | grep -E '^vermagic'
echo "   (must read: $KV SMP preempt mod_unload modversions)"

echo "== backing up stock module (once) =="
if [ -f "$DIR/i915.ko.zst" ] && [ ! -f "$DIR/i915.ko.zst.orig" ]; then
  sudo cp -v "$DIR/i915.ko.zst" "$DIR/i915.ko.zst.orig"
else
  echo "   backup already exists or stock module missing; leaving it."
fi

SB="$(mokutil --sb-state 2>/dev/null || echo 'unknown')"
echo "== Secure Boot: $SB =="

INSTALL_SRC="$KO_ZST"
if echo "$SB" | grep -qi enabled; then
  echo "   Secure Boot is ENABLED -> signing the module with your MOK."
  MOKDIR=/var/lib/shim-signed/mok
  if [ ! -f "$MOKDIR/MOK.priv" ]; then
    echo "!! No MOK key at $MOKDIR/MOK.priv."
    echo "   Create + enrol one first (see docs/01), or disable Secure Boot, then re-run."
    exit 1
  fi
  tmp=$(mktemp /tmp/i915.XXXX.ko)
  zstd -d -f "$KO_ZST" -o "$tmp"
  sudo /usr/src/linux-headers-$KV/scripts/sign-file sha512 \
       "$MOKDIR/MOK.priv" "$MOKDIR/MOK.der" "$tmp"
  zstd -19 -f "$tmp" -o /tmp/i915.signed.ko.zst
  INSTALL_SRC=/tmp/i915.signed.ko.zst
fi

echo "== installing =="
sudo cp -v "$INSTALL_SRC" "$DIR/i915.ko.zst"
sudo depmod -a "$KV"
sudo update-initramfs -u -k "$KV"

echo
warn_stale_override
echo
echo "Done. Reboot - the DMI quirk applies the fix automatically (no boot param)."
echo "After reboot, check it worked with:"
echo "    $(basename "$0") verify"
echo
echo "To revert: sudo mv $DIR/i915.ko.zst.orig $DIR/i915.ko.zst && sudo depmod -a && sudo update-initramfs -u -k $KV"
