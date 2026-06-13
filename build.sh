#!/bin/sh
# One-shot build: docker image + fetch official netbird binary + .ipk packaging.
# Everything runs inside Docker, so the only host requirement (macOS or
# Linux, arm64 or amd64) is Docker itself.
#
# Usage:
#   ./build.sh           # fetch + package -> ./out/netbird_<ver>_<arch>.ipk
#   ./build.sh binary    # fetch binary only -> ./out/netbird
#   ./build.sh package   # package only (binary must already be in ./out)
#
# Environment:
#   NETBIRD_VERSION  netbird version to build (default: latest GitHub release)
#   OPENWRT_ARCH     opkg architecture (default: aarch64_cortex-a53_neon-vfpv4)
#   COMPRESS_BINARY  1 (default): ship binary gzipped, extract to /tmp at use
#                    0: plain binary at /usr/sbin/netbird (~36 MB on flash)
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGE="${1:-all}"
IMAGE="netbird-glx2000-builder"
OPENWRT_ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53_neon-vfpv4}"

# Resolve NETBIRD_VERSION to the latest release tag if not pinned.
if [ -z "${NETBIRD_VERSION:-}" ]; then
    echo "==> NETBIRD_VERSION not set, querying latest GitHub release"
    NETBIRD_VERSION="$(curl -fsSL https://api.github.com/repos/netbirdio/netbird/releases/latest \
        | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p')"
    [ -n "$NETBIRD_VERSION" ] || { echo "error: could not resolve latest netbird version" >&2; exit 1; }
fi
NETBIRD_VERSION="${NETBIRD_VERSION#v}"
echo "==> Building netbird ${NETBIRD_VERSION} for ${OPENWRT_ARCH}"

echo "==> Building docker image ${IMAGE}"
docker build -q -t "$IMAGE" "$ROOT/docker" >/dev/null

run_in_container() {
    docker run --rm \
        -v "$ROOT:/work" \
        -e NETBIRD_VERSION="$NETBIRD_VERSION" \
        -e NETBIRD_ASSET_ARCH="${NETBIRD_ASSET_ARCH:-linux_arm64}" \
        -e OPENWRT_ARCH="$OPENWRT_ARCH" \
        -e COMPRESS_BINARY="${COMPRESS_BINARY:-1}" \
        -e PKG_RELEASE="${PKG_RELEASE:-1}" \
        -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}" \
        "$IMAGE" sh -c "$1"
}

mkdir -p "$ROOT/out"
case "$STAGE" in
    binary)  run_in_container "sh /work/scripts/compile.sh" ;;
    package) run_in_container "sh /work/scripts/mkipk.sh" ;;
    all)     run_in_container "sh /work/scripts/compile.sh && sh /work/scripts/mkipk.sh" ;;
    *) echo "usage: $0 [binary|package|all]" >&2; exit 2 ;;
esac

echo "==> Done. Artifacts in $ROOT/out:"
ls -lh "$ROOT/out"
