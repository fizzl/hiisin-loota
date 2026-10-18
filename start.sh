#!/usr/bin/env bash
# One-shot launcher: make sure the artifacts and the tap exist, then boot a VM
# on this terminal with Claude Code already running in the project workspace.
#   ./start.sh PROJECT_DIR [--jail] [--inplace] [--shell]
# --shell drops into the guest shell instead of starting claude.
# Privileged step: bin/net-setup.sh (tap + iptables) via sudo when the tap is
# missing; --jail adds the jailer's sudo. Nothing else runs as root.
set -euo pipefail
cd "$(dirname "$0")"
source bin/lib.sh
proj="${1:?usage: ./start.sh PROJECT_DIR [--jail] [--inplace] [--shell]}"; shift
[ -d "$proj" ] || die "$proj is not a directory"
mode=(--claude); args=()
for a in "$@"; do case "$a" in --shell) mode=();; *) args+=("$a");; esac; done
[ -x "$FC_BIN" ] || bin/fetch-firecracker.sh
[ -f "$KERNEL" ] || bin/fetch-kernel.sh
[ -f "$ROOTFS" ] || bin/build-rootfs.sh
if ! ip link show "$TAP_DEV" >/dev/null 2>&1; then
  log "setting up $TAP_DEV (sudo)"; sudo bin/net-setup.sh --uid "$(id -u)"
fi
[ -f "$HOME/.claude/.credentials.json" ] || die "host Claude Code is not logged in (no ~/.claude/.credentials.json)"
exec bin/run-vm.sh "$proj" "${mode[@]}" "${args[@]}"
