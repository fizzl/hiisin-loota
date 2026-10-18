#!/usr/bin/env bash
# Host-side listener for guest-initiated workspace sync-out (guest -> CID 2 port 5002).
# Firecracker connects to "<uds_path>_5002" on the host whenever the guest connects,
# where uds_path is as Firecracker sees it (inside the chroot when jailed).
# Each connection delivers a tar of /home/agent/workspace; sync-out-recv.sh
# lands it in OUT_DIR safely (staging dir + rsync, see there). Any guest
# process can open this port, so the receiver treats the stream as hostile.
# Usage: sync-out.sh UDS_PATH OUT_DIR   (runs until killed)
source "$(dirname "$0")/lib.sh"
need rsync
uds="$1"; out="$2"; mkdir -p "$out"
exec socat -u "UNIX-LISTEN:${uds}_5002,fork,unlink-early" EXEC:"$ROOT/bin/sync-out-recv.sh $out",stderr
