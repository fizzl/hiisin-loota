#!/usr/bin/env bash
# Fetch the prebuilt guest kernel from the Firecracker CI bucket and verify it
# against KERNEL_SHA256 (the bucket publishes no checksum; the pin lives in
# configs/versions.env).
source "$(dirname "$0")/lib.sh"
need curl; need sha256sum
mkdir -p "$ART"
url="https://s3.amazonaws.com/spec.ccfc.min/$KERNEL_CI_PREFIX/vmlinux-$KERNEL_VERSION"
if [ ! -f "$KERNEL" ]; then log "downloading $url"; curl -fL -o "$KERNEL" "$url"; fi
echo "$KERNEL_SHA256  $KERNEL" | sha256sum -c - >/dev/null || { rm -f "$KERNEL"; die "kernel checksum mismatch for vmlinux-$KERNEL_VERSION (file removed)"; }
log "kernel ready: $KERNEL"
