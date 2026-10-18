#!/usr/bin/env bash
# Receive one workspace tar on stdin (guest-controlled, hostile) into OUT_DIR.
# Usage: sync-out-recv.sh OUT_DIR
# GNU tar refuses "..", strips "/" and delays symlinks within one archive, but a
# symlink planted by an earlier sync already exists on disk and a later tar
# would write straight through it. So: extract into a fresh empty staging dir
# (nothing to follow), then rsync into OUT_DIR, which replaces a destination
# symlink instead of following it. Files deleted in the guest stay in OUT_DIR
# (no --delete: with --inplace OUT_DIR is the project itself and the
# ignored files must survive).
source "$(dirname "$0")/lib.sh"
out="$1"; mkdir -p "$out"
stage="$(mktemp -d "$(dirname "$out")/.hiisin-loota-sync.XXXXXX")"; trap 'rm -rf "$stage"' EXIT
tar -x -C "$stage" || log "tar reported errors (members refused?), continuing with what extracted"
rsync -a "$stage/" "$out/"
log "$(date +%T) workspace synced to $out"
