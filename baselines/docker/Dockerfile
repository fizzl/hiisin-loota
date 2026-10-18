# Baseline for comparison: Claude Code in a plain Docker container.
# Same Ubuntu base, Node and Claude Code pins as the microVM guest.
ARG UBUNTU_IMAGE=ubuntu:24.04
FROM ${UBUNTU_IMAGE}
ARG NODE_VERSION
ARG CLAUDE_CODE_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git less nano python3 ripgrep jq xz-utils procps \
    && rm -rf /var/lib/apt/lists/*
RUN cd /tmp && f="node-${NODE_VERSION}-linux-x64.tar.xz" \
    && curl -fsSLO "https://nodejs.org/dist/${NODE_VERSION}/$f" \
    && curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/SHASUMS256.txt" | grep " $f\$" | sha256sum -c - \
    && tar -xJf "$f" -C /usr/local --strip-components=1 && rm -f "$f"
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" && npm cache clean --force
RUN userdel -r ubuntu 2>/dev/null; useradd -m -u 1000 -s /bin/bash agent
USER agent
WORKDIR /workspace
