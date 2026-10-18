# Guest rootfs for the hiisin-loota microVM. Built by bin/build-rootfs.sh, which
# passes the pinned versions as build args and exports the result to ext4.
ARG UBUNTU_IMAGE=ubuntu:24.04
FROM ${UBUNTU_IMAGE}
ARG NODE_VERSION
ARG CLAUDE_CODE_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus udev kmod iproute2 iputils-ping \
      ca-certificates curl git socat less nano python3 python3-pip python3-venv ripgrep jq \
      xz-utils openssh-client procps \
    && rm -rf /var/lib/apt/lists/*
# Node from the official tarball, verified against nodejs.org SHASUMS256.txt
RUN cd /tmp && f="node-${NODE_VERSION}-linux-x64.tar.xz" \
    && curl -fsSLO "https://nodejs.org/dist/${NODE_VERSION}/$f" \
    && curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" | grep " $f\$" | sha256sum -c - \
    && tar -xJf "$f" -C /usr/local --strip-components=1 && rm -f "$f"
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force
# Unprivileged agent user, no sudo (the ctl socket is the only root path). claude refuses --dangerously-skip-permissions as root.
RUN userdel -r ubuntu 2>/dev/null; useradd -m -u 1000 -s /bin/bash agent && mkdir -p /home/agent/workspace /home/agent/.claude \
    && chown -R agent:agent /home/agent && passwd -d agent && passwd -l root \
    # Root is locked ("!" in shadow): PAM's nullok would otherwise let `su root` in with no password.
    # No setuid/setgid binaries at all: nothing in the guest may change identity.
    && find / -xdev -perm /6000 -type f -exec chmod u-s,g-s {} +
# Guest-side plumbing
COPY sbin/ /usr/local/sbin/
COPY systemd/*.service systemd/*.socket /etc/systemd/system/
COPY systemd/autologin.conf /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf
COPY etc/fstab /etc/fstab
COPY etc/bashrc-agent /home/agent/.bashrc
COPY etc/profile.d-hiisin-loota.sh /etc/profile.d/hiisin-loota.sh
COPY etc/tmpfiles.d-hiisin-loota.conf /etc/tmpfiles.d/hiisin-loota.conf
COPY etc/udev-hiisin-loota.rules /etc/udev/rules.d/90-hiisin-loota.rules
COPY claude/CLAUDE.md /opt/hiisin-loota/CLAUDE.md
RUN chmod +x /usr/local/sbin/hiisin-loota-* \
    && systemctl enable hiisin-loota-net hiisin-loota-agent hiisin-loota-syncout hiisin-loota-ctl.socket \
    && systemctl mask systemd-timesyncd systemd-resolved apt-daily.timer apt-daily-upgrade.timer \
         e2scrub_all.timer fstrim.timer man-db.timer \
    && rm -f /etc/machine-id && touch /etc/machine-id
