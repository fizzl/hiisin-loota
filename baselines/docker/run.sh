#!/usr/bin/env bash
# Run Claude Code in a hardened-ish Docker container against PROJECT_DIR.
# Usage: baselines/docker/run.sh PROJECT_DIR [claude args...]
# Hardening applied: non-root user, all capabilities dropped, no-new-privileges,
# read-only rootfs with tmpfs /tmp and home, pids limit, memory limit.
# The project dir is bind-mounted read-write (that is the whole point of the
# comparison: Docker shares the filesystem live, the microVM does not).
# Credentials: the host ~/.claude/.credentials.json is mounted into a tmpfs home,
# Credentials: unlike the microVM, the host ~/.claude/.credentials.json is copied in (a weaker trust model: the container holds the real token).
source "$(dirname "$0")/../../bin/lib.sh"
need docker
proj="$(realpath "${1:?project dir}")"; shift
img=hiisin-loota-docker-baseline:local
docker image inspect "$img" >/dev/null 2>&1 || docker build \
  --build-arg UBUNTU_IMAGE="$UBUNTU_IMAGE" --build-arg NODE_VERSION="$NODE_VERSION" \
  --build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" -t "$img" "$ROOT/baselines/docker"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
install -m 600 "$HOME/.claude/.credentials.json" "$tmp/.credentials.json"
printf '{"hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"theme":"dark","numStartups":1}' > "$tmp/claude.json"
exec docker run --rm -it \
  --cap-drop=ALL --security-opt=no-new-privileges --read-only \
  --tmpfs /tmp:rw,size=512m --tmpfs /home/agent:rw,uid=1000,gid=1000,size=512m \
  --pids-limit 512 --memory 4g --cpus "$VCPUS" \
  -v "$proj:/workspace" \
  -v "$tmp/.credentials.json:/run/secrets/credentials.json:ro" \
  -v "$tmp/claude.json:/run/secrets/claude.json:ro" \
  -e HOME=/home/agent \
  "$img" bash -c 'mkdir -p ~/.claude && cp /run/secrets/credentials.json ~/.claude/.credentials.json && cp /run/secrets/claude.json ~/.claude.json && exec claude --dangerously-skip-permissions "$@"' -- "$@"
