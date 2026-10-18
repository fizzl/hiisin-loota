#!/usr/bin/env bash
# Stop a headless VM: ask the guest to sync out and power off, then clean up.
# Usage: stop-vm.sh RUN_DIR [--kill]
source "$(dirname "$0")/lib.sh"
run="$1"; pid="$(cat "$run/fc.pid")"
if [ "${2:-}" != "--kill" ]; then
  # Guest OOM kills this session, via the ctl socket (the agent cannot read the kernel log).
  oom=$("$ROOT/bin/exec.sh" "$run" --timeout 10 "printf 'oom\n' | socat -t 5 - UNIX-CONNECT:/run/hiisin-loota/ctl.sock" 2>/dev/null | tail -1)
  [ "${oom:-0}" -gt 0 ] 2>/dev/null && log "guest OOM kills this run: $oom"
  "$ROOT/bin/exec.sh" "$run" 'hiisin-loota-done' || true
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
fi
kill "$pid" 2>/dev/null || true
# Wait for the VMM to exit so the tap is free for the next run (one tap, one VM).
for _ in $(seq 1 25); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
kill -KILL "$pid" 2>/dev/null || true
[ -f "$run/helper.pids" ] && xargs -r kill < "$run/helper.pids" 2>/dev/null || true
if [ -s "$run/egress.log" ] && grep -q ' DENY ' "$run/egress.log"; then log "egress denials this run:"; grep ' DENY ' "$run/egress.log" | awk '{print $4}' | sort | uniq -c >&2; fi
pkill -f "^socat -u UNIX-LISTEN:$(readlink -f "$run/v.sock" | sed 's/v.sock$//')" || true
if [ -L "$run/jail" ]; then sudo rm -rf "$(readlink "$run/jail")/firecracker/$(basename "$run")"; fi; rm -rf "$run"
log "stopped and cleaned $run"
