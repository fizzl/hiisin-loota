#!/usr/bin/env bash
# Download the pinned Firecracker release, verify sha256, extract firecracker + jailer.
source "$(dirname "$0")/lib.sh"
need curl; need tar; need sha256sum
mkdir -p "$ART/bin" "$ART/dl"
tgz="firecracker-$FC_VERSION-x86_64.tgz"
url="https://github.com/firecracker-microvm/firecracker/releases/download/$FC_VERSION/$tgz"
if [ ! -f "$ART/dl/$tgz" ]; then log "downloading $url"; curl -fL -o "$ART/dl/$tgz" "$url"; fi
echo "$FC_SHA256  $ART/dl/$tgz" | sha256sum -c - || die "checksum mismatch for $tgz"
tar -xzf "$ART/dl/$tgz" -C "$ART/dl"
cp "$ART/dl/release-$FC_VERSION-x86_64/firecracker-$FC_VERSION-x86_64" "$FC_BIN"
cp "$ART/dl/release-$FC_VERSION-x86_64/jailer-$FC_VERSION-x86_64" "$JAILER_BIN"
chmod +x "$FC_BIN" "$JAILER_BIN"
log "installed $("$FC_BIN" --version | head -1) and jailer to $ART/bin"
