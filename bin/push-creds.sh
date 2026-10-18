#!/usr/bin/env bash
# Push a minimal ~/.claude.json into the guest's tmpfs home: onboarding done,
# bypass-permissions accepted. No credentials travel: the guest's Claude Code
# talks to the host credential broker (bin/cred-broker.py) with a placeholder
# token. Travels as an inline base64 tar over the exec channel.
source "$(dirname "$0")/lib.sh"
run="$1"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/.claude.json" <<JSON
{"hasCompletedOnboarding":true,"bypassPermissionsModeAccepted":true,"theme":"dark","numStartups":1}
JSON
{ echo "base64 -d <<'__B64__' | tar -x -C /home/agent"
  tar -c -C "$tmp" . | base64 -w0; echo; echo "__B64__"; } | "$ROOT/bin/exec.sh" "$run"
log "claude config pushed (no credentials; the broker holds the token)"
