#!/usr/bin/env bash
# Install the patched i915 module on the Portabook (Linux Mint 22.3 / kernel 6.14.0-37-generic).
# Run FROM the directory that contains i915.ko.zst.  Safe to re-run.
set -euo pipefail

KV=6.14.0-37-generic
DIR=/lib/modules/$KV/kernel/drivers/gpu/drm/i915
KO_ZST="$(dirname "$0")/i915.ko.zst"

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
echo "Done. Reboot, then to test a fix without recompiling, boot with e.g.:"
echo "    i915.dsi_pixel_format_override=2"
echo "To revert: sudo mv $DIR/i915.ko.zst.orig $DIR/i915.ko.zst && sudo depmod -a && sudo update-initramfs -u -k $KV"
