# Shared helpers. Source, do not execute.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="$ROOT/artifacts"
# shellcheck source=../configs/versions.env
source "$ROOT/configs/versions.env"
FC_BIN="$ART/bin/firecracker"
JAILER_BIN="$ART/bin/jailer"
KERNEL="$ART/vmlinux-$KERNEL_VERSION"
ROOTFS="$ART/rootfs-ubuntu2404.ext4"
log() { printf '\e[1;34m[hiisin-loota]\e[0m %s\n' "$*" >&2; }
die() { printf '\e[1;31m[hiisin-loota]\e[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing tool: $1"; }
