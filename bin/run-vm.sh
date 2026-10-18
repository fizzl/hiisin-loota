#!/usr/bin/env bash
# Boot a hiisin-loota microVM for one project directory.
#   run-vm.sh PROJECT_DIR [--out DIR] [--inplace] [--jail] [--claude]
# Flow: ensure tap (sudo net-setup.sh if missing) -> start the host helpers
# (sync-out listener, egress proxy, credential broker) -> start firecracker on
# this terminal (serial console) -> once the guest listens on vsock, push the
# claude config and the workspace -> you work in the guest -> on
# hiisin-loota-done the guest streams its workspace back to --out (default:
# PROJECT_DIR.hiisin-loota-out next to the project; --inplace extracts over the
# project itself). The rootfs is shared read-only; guest writes go to a tmpfs
# overlay set up by guest/sbin/hiisin-loota-init.
# --jail runs firecracker under jailer (needs sudo; chroot+cgroup+seccomp).
# --claude: the guest's console login starts claude (permissions bypassed) in the
#   workspace once provisioning is done, instead of a shell. See ./start.sh.
# --headless boots in the background (console -> RUN_DIR/console.log), waits for
#   provisioning, prints RUN_DIR and returns. Use bin/exec.sh and bin/stop-vm.sh.
# Egress: a per-run proxy (bin/egress-proxy.py) listens on HOST_IP:PROXY_PORT and
#   is the guest's only way out. A per-run credential broker (bin/cred-broker.py)
#   on HOST_IP:BROKER_PORT is the guest's ANTHROPIC_BASE_URL; the host's
#   subscription token is attached there, the guest holds only a placeholder. Verdicts go to RUN_DIR/egress.log (gone with the
#   run dir). --egress-allow FILE replaces configs/egress-allow.txt;
#   --egress-log-only allows everything and just logs, for measuring a workload.
source "$(dirname "$0")/lib.sh"
need python3; need socat
proj="$(realpath "${1:?project dir}")"; shift
out="$(dirname "$proj")/$(basename "$proj").hiisin-loota-out"; jail=0; headless=0
allow="$ROOT/configs/egress-allow.txt"; logonly=(); ready=shell
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2;; --inplace) out="$proj"; shift;; --jail) jail=1; shift;; --headless) headless=1; shift;;
  --egress-allow) allow="$(realpath "$2")"; shift 2;; --egress-log-only) logonly=(--log-only); shift;; --claude) ready=claude; shift;; *) die "unknown arg $1";; esac; done
[ -f "$allow" ] || die "egress allowlist $allow not found"
[ -x "$FC_BIN" ] || die "run bin/fetch-firecracker.sh first"
[ -f "$KERNEL" ] || die "run bin/fetch-kernel.sh first"
[ -f "$ROOTFS" ] || die "run bin/build-rootfs.sh first"
# One tap, one VM: a second Firecracker fails with "TapOpen ... Resource busy" and leaves a run dir behind.
if pgrep -f "^(sudo )?($FC_BIN|$JAILER_BIN) |^firecracker --id " >/dev/null; then die "a hiisin-loota VM is already running (one tap); stop it first"; fi
id="hiisin-loota-$(date +%s)-$$"
run="${XDG_RUNTIME_DIR:-/tmp}/$id"; mkdir -p "$run"
log "run dir $run, sync-out target $out"
if ! ip link show "$TAP_DEV" >/dev/null 2>&1; then
  log "tap $TAP_DEV missing, creating it (sudo)"; sudo "$ROOT/bin/net-setup.sh" --uid "$(id -u)"
fi
prefix="${NET_CIDR#*/}"
render() { sed -e "s#@KERNEL@#$1#g" -e "s#@ROOTFS@#$2#g" -e "s#@VSOCK@#$3#g" -e "s#@TAP_DEV@#$TAP_DEV#g" \
  -e "s#@GUEST_IP@#$GUEST_IP#g" -e "s#@PREFIX@#$prefix#g" -e "s#@HOST_IP@#$HOST_IP#g" \
  -e "s#@VCPUS@#$VCPUS#g" -e "s#@MEM_MIB@#$MEM_MIB#g" -e "s#@PROXY_PORT@#$PROXY_PORT#g" -e "s#@BROKER_PORT@#$BROKER_PORT#g" -e "s#@UPPER_SIZE@#$UPPER_SIZE#g" "$ROOT/configs/vm-config.template.json"; }
pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; stty sane 2>/dev/null || true
  if [ "$jail" = 1 ]; then sudo rm -rf "$jbase/firecracker/$id"; fi; rm -rf "$run"; }
trap cleanup EXIT
if [ "$jail" = 1 ]; then
  # jailer chroots to $run/jail/firecracker/$id/root; paths in config are chroot-relative
  # The chroot must not live on a nodev tmpfs (/run/user, /tmp): jailer mknods
  # /dev/net/tun and /dev/kvm inside it. Use a dir on the root filesystem.
  juid=$(id -u); jgid=$(id -g); jbase="${JAIL_BASE:-/var/lib/hiisin-loota/jail}"; croot="$jbase/firecracker/$id/root"
  [ -d "$jbase" ] || sudo install -d -o "$juid" -g "$jgid" "$jbase"
  ln -sfn "$jbase" "$run/jail"
  # Jailer needs the image inside the chroot; a reflink copy is free on btrfs and stays read-only to the guest.
  mkdir -p "$croot"; cp "$KERNEL" "$croot/vmlinux"; cp --reflink=auto "$ROOTFS" "$croot/rootfs.ext4"
  render /vmlinux /rootfs.ext4 /v.sock > "$croot/config.json"
  vsock="$croot/v.sock"
  ln -sfn "$croot/v.sock" "$run/v.sock"
  # Jailer applies the cgroup limits itself (needs root anyway). Firecracker's built-in seccomp stays on.
  fc_cmd=(sudo "$JAILER_BIN" --id "$id" --exec-file "$FC_BIN" --uid "$juid" --gid "$jgid"
          --chroot-base-dir "$jbase" --cgroup-version 2
          --cgroup "memory.max=$(( (MEM_MIB + CG_MEM_OVERHEAD_MIB) * 1024 * 1024 ))"
          --cgroup "cpu.max=$(( VCPUS * 100000 )) 100000"
          --resource-limit no-file=4096
          -- --config-file /config.json)
else
  vsock="$run/v.sock"
  render "$KERNEL" "$ROOTFS" "$vsock" > "$run/config.json"
  fc_cmd=("$FC_BIN" --api-sock "$run/fc.sock" --config-file "$run/config.json" --log-path "$run/fc.log" --level Info)
  # Plain mode: same limits via a transient user scope (cgroup v2 delegation to the user slice; no root).
  if command -v systemd-run >/dev/null && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    fc_cmd=(systemd-run --user --scope -q --unit "$id" -p "MemoryMax=$(( MEM_MIB + CG_MEM_OVERHEAD_MIB ))M" -p "CPUQuota=$(( VCPUS * 100 ))%" -- "${fc_cmd[@]}")
  else log "no systemd-run/user session: VMM runs without cgroup limits"; fi
fi
"$ROOT/bin/sync-out.sh" "$vsock" "$out" >"$run/syncout.log" 2>&1 & pids+=($!)
python3 "$ROOT/bin/egress-proxy.py" --bind "$HOST_IP" --port "$PROXY_PORT" --allow "$allow" --log "$run/egress.log" "${logonly[@]}" >"$run/egress-proxy.err" 2>&1 & pids+=($!)
# Credential broker: the guest's ANTHROPIC_BASE_URL. Reads the host token per request; nothing secret goes into the VM.
python3 "$ROOT/bin/cred-broker.py" --bind "$HOST_IP" --port "$BROKER_PORT" --peer "$GUEST_IP" --creds "$HOME/.claude/.credentials.json" --log "$run/broker.log" >"$run/broker.err" 2>&1 & pids+=($!)
[ ${#logonly[@]} -gt 0 ] && log "egress proxy in LOG-ONLY mode: everything allowed, see $run/egress.log"
provision() {
  # Serial consoles have no size negotiation: push the host terminal size into
  # the guest console once it is up (interactive mode only).

  for _ in $(seq 1 300); do sleep 0.2; python3 "$ROOT/bin/vsock.py" "$run/v.sock" 5003 ping 2>/dev/null && break; done
  # Record the VMM seccomp state (2 = filter mode; Firecracker default filter).
  fcpid=$(pgrep -n -f "firecracker (--id $id|--api-sock $run/fc.sock)" || true); [ -n "$fcpid" ] && grep -E '^Seccomp' "/proc/$fcpid/status" > "$run/seccomp.status" 2>/dev/null || true
  python3 "$ROOT/bin/vsock.py" "$run/v.sock" 5003 ping 2>/dev/null || { log "guest never came up; see $run/console.log"; return 1; }
  "$ROOT/bin/push-creds.sh" "$run" && "$ROOT/bin/sync-in.sh" "$run" "$proj"
  [ -n "${TTY_ROWS:-}" ] && "$ROOT/bin/exec.sh" "$run" "stty rows $TTY_ROWS cols $TTY_COLS -F /dev/ttyS0" >/dev/null 2>&1 || true
  # The console login shell waits for this file (guest/etc/bashrc-agent): "shell" gives a prompt, "claude" execs claude.
  "$ROOT/bin/exec.sh" "$run" "echo $ready > /home/agent/.hiisin-loota-ready" >/dev/null 2>&1 || true
}
t0=$(date +%s.%N)
if [ "$headless" = 1 ]; then
  trap - EXIT
  "${fc_cmd[@]}" </dev/null >"$run/console.log" 2>&1 & echo $! > "$run/fc.pid"
  printf '%s\n' "${pids[@]}" > "$run/helper.pids"
  provision || exit 1
  python3 -c "import time,sys; print(round(time.time()-float(sys.argv[1]),2))" "$t0" > "$run/boot-to-provisioned.sec"
  log "ready in $(cat "$run/boot-to-provisioned.sec")s. RUN_DIR=$run"
  echo "$run"
else
  if [ -t 0 ]; then TTY_ROWS=$(tput lines) TTY_COLS=$(tput cols); export TTY_ROWS TTY_COLS; fi
  provision & pids+=($!)
  log "booting $id (${VCPUS} vcpu, ${MEM_MIB} MiB). Serial console follows; 'hiisin-loota-done' in the guest syncs and ends the VM."
  if [ "$out" = "$proj" ]; then log "workspace: $proj (--inplace: the guest's changes are written back into it)"
  else log "workspace: copy of $proj; results land in $out, the project itself is not touched (--inplace to write back)"; fi
  # Firecracker leaves icrnl on, so Enter would reach the guest as LF and TUI
  # apps (Claude Code) never see a carriage return. Go fully raw ourselves and
  # restore afterwards (cleanup also runs stty sane).
  saved_tty=""; if [ -t 0 ]; then saved_tty=$(stty -g); stty raw -echo; fi
  "${fc_cmd[@]}"; rc=$?
  [ -n "$saved_tty" ] && stty "$saved_tty"
  n=$(grep -c 'workspace synced to' "$run/syncout.log" 2>/dev/null || true)
  if [ "${n:-0}" -gt 0 ]; then log "workspace copied back to $out; treat it as untrusted input"
  else log "no sync happened: nothing was copied back (hiisin-loota-done or hiisin-loota-sync in the guest does that)"; fi
  exit $rc
fi
