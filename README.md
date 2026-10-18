# hiisin-loota

Run Claude Code with permissions bypassed inside a Firecracker microVM. The
agent gets a copy of one project directory, an allowlisted network, and no
credentials. When it is done, the workspace is copied back next to the
project. Host files, host secrets, the host itself and the LAN are out of
reach.

## Requirements

- Linux x86_64 with `/dev/kvm` usable by your user (`kvm` group).
- docker with your user in the `docker` group (the image build runs without
  sudo), python3, socat, rsync, tar, curl, iptables, sudo.
- A systemd user session for plain mode's cgroup limits. Without one the VMM
  runs unlimited and the launcher says so; `--jail` limits it regardless.
- Claude Code logged in on the host with a subscription
  (`~/.claude/.credentials.json` exists). The guest uses that session through
  a host-side broker; it never receives the token.
- About 2 GB of disk under `artifacts/` and 4.5 GB of RAM per running VM.

## Quick start

```
./start.sh ~/some/project
```

First run downloads Firecracker and a guest kernel, builds the guest image
(a few minutes), and asks for sudo once to create the `hiisin-loota0` tap
with its firewall rules. Then the VM boots on your terminal and Claude Code
starts in a copy of the project. The project itself is not modified: the
guest's workspace comes back to `PROJECT_DIR.hiisin-loota-out` next to it
when you run `hiisin-loota-done`, and the launcher prints that path at start
and at exit. `--inplace` writes back into the project instead.

```
./start.sh PROJECT_DIR [--jail] [--inplace] [--shell]
```

| Flag | Effect |
|---|---|
| `--jail` | Run Firecracker under its jailer (chroot, cgroups, seccomp). Needs sudo for each run. Recommended when the project is not your own. |
| `--inplace` | Copy the workspace back over `PROJECT_DIR` itself instead of `PROJECT_DIR.hiisin-loota-out`. |
| `--shell` | Land in a guest shell instead of starting Claude Code. `cc` starts it. |

Inside the guest:

| Command | Effect |
|---|---|
| `cc` | Claude Code with permissions bypassed, in `~/workspace`. |
| `hiisin-loota-sync` | Copy the workspace back to the host now, keep working. |
| `hiisin-loota-done` | Copy the workspace back and end the VM. |

## Getting out

The terminal is handed to the VM's serial console in raw mode, so Ctrl-C,
Ctrl-D and Ctrl-Z go to the guest, not to your shell. The way out is from
inside:

1. Esc or Ctrl-C leaves Claude Code and drops you in the guest shell.
2. `hiisin-loota-done` copies the workspace back and ends the VM. Your
   terminal is restored and the launcher exits.

Exiting the guest shell with `exit` or Ctrl-D only logs you out; the
console logs in again. There is no `poweroff` for the agent user.

## What goes in and out

- In: everything under `PROJECT_DIR`, including dotfiles and `.env*`, as the
  `agent` user's `~/workspace`.
- Out: everything under `~/workspace` at sync time, into
  `PROJECT_DIR.hiisin-loota-out` (or the project with `--inplace`). Files you
  deleted in the guest are not deleted on the host.
- `.hiisin-lootaignore` in the project root filters both directions. It uses
  `tar --exclude-from` syntax, one pattern per line, for example:

```
node_modules
.next
.git
.env.local
```

The guest writes to a 2 GB RAM overlay (`UPPER_SIZE`); the pushed tree
counts against it, so exclude build trees.

## Network

The guest has no route to the internet, no DNS, and cannot reach host ports
or the LAN. Its only exits are two services on the host side of the tap:

- An egress proxy on port 3128, set in the guest's `HTTP(S)_PROXY`, that
  allows the hostnames in `configs/egress-allow.txt`. Default: npm, PyPI,
  GitHub. IP literals and names that resolve to private ranges are refused.
  Denied requests get HTTP 403; TLS tunnels fail at connect. Edit the file
  and send the proxy SIGHUP, or restart the VM.
- A credential broker on port 3129, set as the guest's `ANTHROPIC_BASE_URL`.
  It attaches your subscription token to API requests. Anthropic hosts are
  not in the allowlist; the broker is the only API path.

To see what a new workload needs, run once with everything allowed and read
the log:

```
bin/run-vm.sh ~/some/project --egress-log-only
grep DENY /run/user/$(id -u)/hiisin-loota-*/egress.log
```

Per-run logs live in the run directory printed at start: `egress.log`
(every ALLOW/DENY with hostname), `broker.log` (status, path, bytes, no
headers), `console.log` in headless mode.

## Credentials

The guest holds no credentials. Claude Code inside sees a placeholder
`ANTHROPIC_AUTH_TOKEN`; the host broker replaces it per request with the
access token from `~/.claude/.credentials.json`, which it re-reads every
time. The broker does not refresh the token. If the host token expires while
no Claude Code runs on the host, guest requests fail with 401 and
`broker.log` says so; run `claude` on the host once to refresh.

What a hostile agent can still do: use your subscription's rate limit while
the VM lives, and put anything it likes into the synced-back workspace.
Treat that tree as untrusted input.

## Headless use

```
r=$(bin/run-vm.sh DIR --headless [--jail] | tail -1)   # prints RUN_DIR
bin/exec.sh "$r" 'command'                              # runs as agent in ~/workspace
bin/exec.sh "$r" --timeout 60 < script.sh               # kill after 60 s (exit 124)
bin/stop-vm.sh "$r"                                     # sync-out, then end; --kill skips sync
```

One tap means one VM at a time; a second start is refused until the first
is stopped.

## Configuration

All knobs are in `configs/versions.env`:

| Variable | Default | Meaning |
|---|---|---|
| `VCPUS`, `MEM_MIB` | 4, 4096 | Guest size. The VMM is capped at `MEM_MIB + CG_MEM_OVERHEAD_MIB` of RAM and `VCPUS` cores. |
| `UPPER_SIZE` | 2G | RAM overlay for all guest writes. |
| `PROXY_PORT`, `BROKER_PORT` | 3128, 3129 | Host-side services on the tap address. |
| `HOST_IP`, `GUEST_IP`, `TAP_DEV` | 172.16.0.1, .2, hiisin-loota0 | Tap network. Change, then `sudo bin/net-setup.sh --teardown` and start again. |
| `CLAUDE_CODE_VERSION`, `NODE_VERSION`, `UBUNTU_IMAGE` | pinned | Guest contents. Rebuild after changing: `bin/build-rootfs.sh`. |
| `FC_VERSION`, `KERNEL_VERSION` | pinned | Firecracker release and CI kernel, each with a sha256 pin. Re-run the fetch scripts after changing. |

Guest image: Ubuntu 24.04, Node 24 with npm, npx and corepack (pnpm, yarn
via `corepack enable`), Claude Code, git, curl, python3 with pip and venv,
ripgrep, jq, nano, openssh-client. No compiler, so packages that need a
native build (`gcc`) fail; prebuilt wheels and npm binaries work. For extra
packages edit
`guest/Dockerfile` and rebuild with no VM running. Anything installed at
runtime is lost at exit.

The sandbox tells Claude Code where it is through `guest/claude/CLAUDE.md`,
installed as the agent's `~/.claude/CLAUDE.md`.

## Teardown

```
sudo bin/net-setup.sh --teardown     # remove tap and firewall rules
rm -rf artifacts                     # downloads and the guest image
```

The jailer chroot base is `/var/lib/hiisin-loota/jail`; it is emptied per
run and can be deleted.

## Limits and known issues

- The guest kernel is a Firecracker CI build; there is no in-guest seccomp
  profile. Use `--jail` so the VMM itself runs confined.
- Plain mode (the default) runs Firecracker as your user with cgroup limits
  from a systemd user scope and no chroot. `--jail` is the hardened mode.
- No GPU, no multi-tenant or remote use, one VM per host at a time.

## License

MIT, see LICENSE. The software is provided as is, without warranty; you run
an agent with permissions bypassed at your own risk.
