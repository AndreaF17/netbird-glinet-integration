#!/bin/sh
# Fetch NetBird's OFFICIAL prebuilt static linux/arm64 binary and place it in
# OUT_DIR. We repackage the upstream release artifact — the very same binary
# the official installer (pkgs.netbird.io/install.sh) ships — instead of
# compiling from source: it is faster, needs no Go toolchain, and is
# byte-for-byte the maintainers' build. The .ipk packaging (compression,
# wrapper, GL.iNet panel) is what this project adds on top.
#
# Runs INSIDE the build container (see docker/Dockerfile); expects:
#   NETBIRD_VERSION     version to fetch, with or without leading "v"
#   OUT_DIR             output dir (default /work/out)
#   NETBIRD_ASSET_ARCH  upstream release arch slug (default linux_arm64)
set -eu

: "${NETBIRD_VERSION:?NETBIRD_VERSION must be set (e.g. 0.72.3)}"
OUT_DIR="${OUT_DIR:-/work/out}"
ASSET_ARCH="${NETBIRD_ASSET_ARCH:-linux_arm64}"

VER="${NETBIRD_VERSION#v}"
TAG="v${VER}"
BASE="https://github.com/netbirdio/netbird/releases/download/${TAG}"
TARBALL="netbird_${VER}_${ASSET_ARCH}.tar.gz"
SUMS="netbird_${VER}_checksums.txt"

WORK="$(mktemp -d /tmp/netbird-dl.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Downloading ${TARBALL}"
curl -fsSL -o "$WORK/$TARBALL" "${BASE}/${TARBALL}"

# Verify the upstream sha256 BEFORE we trust the binary.
echo "==> Verifying checksum against ${SUMS}"
curl -fsSL -o "$WORK/$SUMS" "${BASE}/${SUMS}"
WANT="$(awk -v f="$TARBALL" '$2 == f {print $1}' "$WORK/$SUMS" | head -n1)"
[ -n "$WANT" ] || { echo "error: no checksum entry for ${TARBALL} in ${SUMS}" >&2; exit 1; }
GOT="$(sha256sum "$WORK/$TARBALL" | awk '{print $1}')"
[ "$WANT" = "$GOT" ] || { echo "error: checksum mismatch (want $WANT, got $GOT)" >&2; exit 1; }
echo "    OK ${GOT}"

echo "==> Extracting netbird binary"
mkdir -p "$OUT_DIR"
# The archive carries the binary as ./netbird at the root.
tar -xzf "$WORK/$TARBALL" -C "$WORK" netbird
install -m 0755 "$WORK/netbird" "$OUT_DIR/netbird"

echo "==> Ready: $OUT_DIR/netbird (netbird ${VER}, official ${ASSET_ARCH})"
ls -lh "$OUT_DIR/netbird"
