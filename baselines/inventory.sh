#!/usr/bin/env bash
# Security-posture inventory, run INSIDE the guest as the agent (bin/exec.sh "$r" < baselines/inventory.sh).
# Run it after every image or network change and diff against the previous output.
h() { printf '\n## %s\n' "$1"; }
h "mounts";            findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null | grep -v -E '^/(proc|sys|dev)/' 
h "setuid/setgid";     find / -xdev -perm /6000 -type f 2>/dev/null | sort
h "listening sockets"; ss -lntup 2>/dev/null | tail -n +2
h "pid 1 capabilities"; grep -E '^Cap' /proc/1/status
h "agent capabilities"; grep -E '^Cap' /proc/self/status
h "ulimit";            ulimit -a
h "sudo";              command -v sudo >/dev/null && { sudo -n true 2>&1 && echo "sudo -n true: OK" || echo "sudo present, no grant"; } || echo "sudo: missing"
h "sudoers.d";         ls -l /etc/sudoers.d 2>&1
h "resolv.conf";       cat /etc/resolv.conf 2>&1
h "sandbox marker";    cat /run/hiisin-loota/sandbox 2>&1
h "agent env";         env | sort | grep -v -E '^(LS_COLORS|_)='
h "kernel filesystems"; grep -E 'overlay|tmpfs|ext4' /proc/filesystems
