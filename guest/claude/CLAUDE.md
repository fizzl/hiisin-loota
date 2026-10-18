# You are running inside a hiisin-loota microVM

This is a disposable Firecracker virtual machine, not the user's computer.
Nothing here persists after the VM ends except the workspace below.

- Workspace: `/home/agent/workspace`. This is the only directory that is copied
  back to the user when the session ends. Work there; put deliverables there.
- Everything else (installed packages, files outside the workspace, caches)
  is lost when the VM ends. The root filesystem is a throwaway overlay.
- No one can answer an interactive prompt. Tools are already configured to
  never prompt; if something still blocks waiting for input, kill it.
- There is no `sudo` and no `apt`. To finish and send the workspace back, run
  `hiisin-loota-done`. To send a snapshot without finishing, run `hiisin-loota-sync`.
- Installed: node 24 with npm, npx and corepack (`corepack enable` for pnpm
  and yarn); python3 with pip and venv; git, curl, ripgrep, jq, nano, ssh
  client. No compiler, no make, no headers.
- Installing more: `pip install` into a venv or with `--user`, `npm install`,
  `npx`, or a static binary from a GitHub release (`curl -L`, unpack into
  `~/.local/bin`). Only prebuilt packages work: anything that compiles a native
  extension or addon fails, and there is no way to add system packages. Check
  for a wheel or a static build before trying. Everything installed outside
  the workspace is gone when the VM ends, so a venv or node_modules inside the
  workspace is what survives, and it comes back to the user with the rest.
- Network: only an allowlist of hosts is reachable, through the proxy already
  set in `HTTPS_PROXY`. Allowed: the Claude API, npm, PyPI, GitHub. Anything
  else returns HTTP 403 from the proxy, and name lookups fail on purpose.
  Do not try to work around this; tell the user what you needed.
- There are no API credentials in this VM. Claude Code talks to a broker on
  the host that attaches the user's token; the `ANTHROPIC_AUTH_TOKEN` you see
  is a placeholder.
- `IS_SANDBOX=1` and the file `/run/hiisin-loota/sandbox` mark this environment.
