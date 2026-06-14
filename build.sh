#!/bin/sh
# One-shot build of the GL-X2000 NetBird integration .ipk (panel + wrapper +
# init + self-updater). It packages the integration ONLY — no netbird binary is
# bundled; the router downloads the official netbird client at install time and
# the panel keeps it updated. Everything runs inside Docker, so the only host
# requirement (macOS or Linux, arm64 or amd64) is Docker itself.
#
# Usage:
#   ./build.sh                          # -> ./out/netbird_<version>_<arch>.ipk
#   INTEGRATION_VERSION=1.1 ./build.sh  # set the panel version
#
# Environment:
#   INTEGRATION_VERSION  panel/integration version (default 1.0)
#   OPENWRT_ARCH         opkg architecture (default aarch64_cortex-a53_neon-vfpv4)
set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
IMAGE="netbird-glx2000-builder"
INTEGRATION_VERSION="${INTEGRATION_VERSION:-1.0}"
OPENWRT_ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53_neon-vfpv4}"

echo "==> Building integration package ${INTEGRATION_VERSION} for ${OPENWRT_ARCH}"

echo "==> Building docker image ${IMAGE}"
docker build -q -t "$IMAGE" "$ROOT/docker" >/dev/null

mkdir -p "$ROOT/out"
docker run --rm \
    -v "$ROOT:/work" \
    -e INTEGRATION_VERSION="$INTEGRATION_VERSION" \
    -e OPENWRT_ARCH="$OPENWRT_ARCH" \
    -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}" \
    "$IMAGE" sh -c "sh /work/scripts/mkipk.sh"

echo "==> Done. Artifacts in $ROOT/out:"
ls -lh "$ROOT/out"
