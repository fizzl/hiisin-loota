#!/usr/bin/env bash
# PRIVILEGED. Everything here needs root. Actions performed:
#   1. create tap device $TAP_DEV owned by the given uid (default: invoking user)
#   2. assign $HOST_IP/24 to it and bring it up
#   3. iptables INPUT from the tap: ACCEPT tcp to $HOST_IP:$PROXY_PORT (the
#      egress proxy) and $HOST_IP:$BROKER_PORT (the credential broker),
#      REJECT port 53 (so guest DNS fails fast), DROP the rest
#   4. iptables FORWARD: DROP everything to and from the tap. There is no NAT
#      and ip_forward is not touched: the proxy is the only way out.
# Usage: sudo bin/net-setup.sh [--uid N] [--teardown]
source "$(dirname "$0")/lib.sh"
[ "$(id -u)" = 0 ] || die "run with sudo"
need ip; need iptables
uid="${SUDO_UID:-0}"; teardown=0
while [ $# -gt 0 ]; do case "$1" in --uid) uid="$2"; shift 2;; --teardown) teardown=1; shift;; *) die "unknown arg $1";; esac; done
prefix="${NET_CIDR#*/}"
rules=( "-A INPUT -i $TAP_DEV -p tcp -d $HOST_IP --dport $PROXY_PORT -j ACCEPT"
        "-A INPUT -i $TAP_DEV -p tcp -d $HOST_IP --dport $BROKER_PORT -j ACCEPT"
        "-A INPUT -i $TAP_DEV -p udp --dport 53 -j REJECT --reject-with icmp-port-unreachable"
        "-A INPUT -i $TAP_DEV -p tcp --dport 53 -j REJECT --reject-with tcp-reset"
        "-A INPUT -i $TAP_DEV -j DROP"
        "-A FORWARD -i $TAP_DEV -j DROP"
        "-A FORWARD -o $TAP_DEV -j DROP" )
if [ "$teardown" = 1 ]; then
  for r in "${rules[@]}"; do iptables ${r/-A/-D} 2>/dev/null || true; done
  ip link del "$TAP_DEV" 2>/dev/null || true
  log "torn down $TAP_DEV and its rules"; exit 0
fi
if ! ip link show "$TAP_DEV" >/dev/null 2>&1; then
  ip tuntap add dev "$TAP_DEV" mode tap user "$uid"
  ip addr add "$HOST_IP/$prefix" dev "$TAP_DEV"
fi
ip link set "$TAP_DEV" up
# Insert in reverse so the ACCEPT ends up first; -C keeps this idempotent.
for ((i=${#rules[@]}-1; i>=0; i--)); do r="${rules[$i]}"; iptables ${r/-A/-C} 2>/dev/null || iptables ${r/-A/-I}; done
log "tap $TAP_DEV up at $HOST_IP (owner uid $uid); guest egress only via proxy port $PROXY_PORT, API via broker port $BROKER_PORT"
