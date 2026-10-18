#!/usr/bin/env bash
# Push a project directory into the running guest's /home/agent/workspace.
# The tar is staged on host disk (needs its size up front) and streamed as the
# data phase of one exec.sh call, extracted as agent so ownership is right.
# Usage: sync-in.sh RUN_DIR PROJECT_DIR
source "$(dirname "$0")/lib.sh"
run="$1"; proj="$2"
excl=(); [ -f "$proj/.hiisin-lootaignore" ] && excl=(--exclude-from="$proj/.hiisin-lootaignore")
# /var/tmp: on disk, not a RAM tmpfs like /tmp and $XDG_RUNTIME_DIR; a workspace can be large.
tmp="$(mktemp -p /var/tmp hiisin-loota-sync.XXXXXX)"; trap 'rm -f "$tmp"' EXIT
tar -c -C "$proj" "${excl[@]}" . > "$tmp"
mb=$(( ($(stat -c %s "$tmp") + 524287) / 1048576 ))
[ "$mb" -gt 200 ] && log "workspace is ${mb} MB; the guest overlay holds $UPPER_SIZE. Exclude build trees with $proj/.hiisin-lootaignore (tar --exclude-from syntax)"
t0=$(date +%s.%N)
"$ROOT/bin/exec.sh" "$run" --stdin "$tmp" 'head -c "$HIISIN_LOOTA_STDIN" | tar -x -C /home/agent/workspace'
log "workspace pushed from $proj (${mb} MB in $(python3 -c "import time,sys; print(round(time.time()-float(sys.argv[1]),1))" "$t0")s)"
