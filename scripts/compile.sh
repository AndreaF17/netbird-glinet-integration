#!/bin/sh
# Compile the NetBird client as a fully static linux/arm64 binary.
# Runs INSIDE the build container (see docker/Dockerfile); expects:
#   NETBIRD_VERSION  - netbird version to build, with or without leading "v"
#   OUT_DIR          - where to place the resulting binary (default /work/out)
set -eu

: "${NETBIRD_VERSION:?NETBIRD_VERSION must be set (e.g. 0.72.3)}"
OUT_DIR="${OUT_DIR:-/work/out}"

VER="${NETBIRD_VERSION#v}"
TAG="v${VER}"
SRC="$(mktemp -d /tmp/netbird-src.XXXXXX)"
trap 'rm -rf "$SRC"' EXIT

echo "==> Cloning netbird ${TAG}"
git clone --quiet --depth 1 --branch "$TAG" \
    https://github.com/netbirdio/netbird.git "$SRC"

cd "$SRC"

# Static cross-compile: CGO off means zero libc dependency, so the QSDK
# musl userland on the router is irrelevant. ldflags -X path verified
# against netbird's .goreleaser.yaml.
export CGO_ENABLED=0
export GOOS=linux
export GOARCH=arm64
export GOFLAGS=-trimpath

echo "==> Building netbird client ${VER} (linux/arm64, static)"
mkdir -p "$OUT_DIR"
go build \
    -ldflags "-s -w -X github.com/netbirdio/netbird/version.version=${VER}" \
    -o "$OUT_DIR/netbird" \
    ./client

echo "==> Built $OUT_DIR/netbird"
ls -lh "$OUT_DIR/netbird"
