#!/usr/bin/env bash
# Baseline: Claude Code's own bubblewrap sandbox, with the settings in this dir.
# Needs bwrap and socat on the host.
# Usage: baselines/bwrap/run.sh PROJECT_DIR [claude args...]
# Verify inside the session with /sandbox, or ask Claude to run
#   touch ~/sandbox-probe   (expect: Read-only file system)
#   curl --noproxy '*' https://example.com   (expect: Could not resolve host)
# Note: no --dangerously-skip-permissions here on purpose. That flag belongs
# inside a VM. With autoAllowBashIfSandboxed, sandboxed commands do not prompt.
proj="$(realpath "${1:?project dir}")"; shift
cd "$proj" && exec claude --settings "$(dirname "$(realpath "$0")")/settings.json" "$@"
