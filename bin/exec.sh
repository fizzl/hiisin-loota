#!/usr/bin/env bash
# Run a bash script (stdin or args) inside the guest as the agent user.
# Usage: exec.sh RUN_DIR [--timeout N] [--stdin FILE] 'command'
#        exec.sh RUN_DIR [--timeout N] [--stdin FILE] < script.sh
# --timeout N: the guest kills the script's process group after N seconds (exit 124).
# --stdin FILE: after the script, FILE's bytes follow on the channel and become the
#   script's stdin (data phase). The script must consume exactly that many bytes,
#   e.g. `head -c N | tar -x`; N is in $HIISIN_LOOTA_STDIN. This is how
#   sync-in.sh streams a workspace without inlining it in the script.
source "$(dirname "$0")/lib.sh"
run="$1"; shift
to=0; data=""
while :; do case "${1:-}" in --timeout) to="$2"; shift 2;; --stdin) data="$2"; shift 2;; *) break;; esac; done
[ -z "$data" ] || [ -f "$data" ] || die "no such file $data"
# Output is streamed; the guest's final "__HIISIN_LOOTA_EXIT__=N" line becomes our exit status.
{ [ "$to" -gt 0 ] && echo "__HIISIN_LOOTA_TIMEOUT__=$to"
  [ -n "$data" ] && echo "__HIISIN_LOOTA_STDIN__=$(stat -c %s "$data")"
  if [ $# -gt 0 ]; then printf '%s\n' "$*"; else cat; fi
  echo "__HIISIN_LOOTA_EOF__"
  [ -n "$data" ] && cat "$data"; true; } \
  | python3 "$ROOT/bin/vsock.py" "$run/v.sock" 5003 raw \
  | { rc=1; while IFS= read -r l; do case "$l" in __HIISIN_LOOTA_EXIT__=*) rc="${l#*=}";; *) printf '%s\n' "$l";; esac; done; exit "$rc"; }
