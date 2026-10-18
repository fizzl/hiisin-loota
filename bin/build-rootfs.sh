#!/usr/bin/env bash
# Build the Ubuntu 24.04 guest rootfs as an ext4 image, using Docker only
# (no host root needed). Steps: docker build -> docker export -> mkfs.ext4 -d
# inside a throwaway container so file ownership is preserved.
source "$(dirname "$0")/lib.sh"
need docker
img=hiisin-loota-guest:local
log "building guest image"
docker build --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" --build-arg NODE_VERSION="$NODE_VERSION" \
  --build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" -t "$img" "$ROOT/guest"
docker image inspect --format 'base image digest hint: {{index .RepoDigests}}' "$UBUNTU_IMAGE" >&2 || true
cid="$(docker create "$img" /bin/true)"
trap 'docker rm -f "$cid" >/dev/null' EXIT
mkdir -p "$ART"; rm -f "$ROOTFS"
log "exporting to $ROOTFS (${ROOTFS_SIZE_GB}G sparse)"
docker export "$cid" | docker run --rm -i -v "$ART:/out" "$img" bash -ec '
  mkdir /rootfs && tar -x -C /rootfs
  echo hiisin-loota > /rootfs/etc/hostname
  printf "127.0.0.1 localhost\n127.0.1.1 hiisin-loota\n" > /rootfs/etc/hosts
  rm -f /rootfs/.dockerenv
  truncate -s '"$ROOTFS_SIZE_GB"'G /out/'"$(basename "$ROOTFS")"'
  mkfs.ext4 -q -F -L hiisin-loota -d /rootfs /out/'"$(basename "$ROOTFS")"'
  # The guest mounts it read-only under an overlay, so shrink to the contents.
  e2fsck -fy /out/'"$(basename "$ROOTFS")"' >/dev/null && resize2fs -M /out/'"$(basename "$ROOTFS")"' 2>&1 | tail -1
  truncate -s $(( $(dumpe2fs -h /out/'"$(basename "$ROOTFS")"' 2>/dev/null | awk -F: "/^Block count/{c=\$2} /^Block size/{b=\$2} END{print c*b}") )) /out/'"$(basename "$ROOTFS")"'
  chown '"$(id -u):$(id -g)"' /out/'"$(basename "$ROOTFS")"''
log "rootfs ready: $ROOTFS ($(du -h --apparent-size "$ROOTFS" | cut -f1) image, $(du -h "$ROOTFS" | cut -f1) used); sha256 $(sha256sum "$ROOTFS" | cut -c1-16)"
