#!/bin/sh
# Assemble a legacy-format OpenWrt .ipk: an outer tar.gz containing
# debian-binary, control.tar.gz and data.tar.gz (what opkg on 19.07 /
# GL.iNet QSDK firmware expects).
#
# Runs INSIDE the build container so GNU tar is guaranteed (BSD tar on
# macOS produces archives opkg may choke on). Expects:
#   NETBIRD_VERSION  - package version, with or without leading "v"
#   OPENWRT_ARCH     - opkg Architecture string (default for the GL-X2000)
#   COMPRESS_BINARY  - 1 (default): ship the binary gzip-compressed and
#                      decompress to RAM-backed /tmp on first use; the
#                      GL-X2000's free overlay flash (~24 MB) cannot hold
#                      the ~36 MB uncompressed binary. 0: classic layout
#                      with the plain binary at /usr/sbin/netbird.
#   BIN              - path to the compiled netbird binary (default /work/out/netbird)
#   FILES_DIR        - dir with netbird.init, postinst, prerm (default /work/files)
#   OUT_DIR          - where to write the .ipk (default /work/out)
set -eu

: "${NETBIRD_VERSION:?NETBIRD_VERSION must be set (e.g. 0.72.3)}"
OPENWRT_ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53_neon-vfpv4}"
COMPRESS_BINARY="${COMPRESS_BINARY:-1}"
PKG_RELEASE="${PKG_RELEASE:-1}"
BIN="${BIN:-/work/out/netbird}"
FILES_DIR="${FILES_DIR:-/work/files}"
OUT_DIR="${OUT_DIR:-/work/out}"

VER="${NETBIRD_VERSION#v}"
# Package version = upstream netbird version + packaging release. Bump
# PKG_RELEASE for packaging-only changes (init/UI/scripts): opkg treats
# 0.72.3-2 > 0.72.3-1 and upgrades, instead of skipping a same-version
# install ("up to date"), which would silently drop the changes.
FULLVER="${VER}-${PKG_RELEASE}"

if ! tar --version 2>/dev/null | grep -q "GNU tar"; then
    echo "error: GNU tar required (run this inside the build container)" >&2
    exit 1
fi
[ -f "$BIN" ] || { echo "error: binary not found at $BIN (run compile first)" >&2; exit 1; }

# Reproducibility: fixed mtimes, numeric root ownership, sorted entries,
# gzip without timestamps.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
tar_repro() {
    tar --format=gnu --numeric-owner --owner=0 --group=0 \
        --sort=name --mtime="@${SOURCE_DATE_EPOCH}" "$@"
}

WORK="$(mktemp -d /tmp/mkipk.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- data ----
DATA="$WORK/data"
mkdir -p "$DATA/usr/sbin" "$DATA/etc/init.d" "$DATA/etc/netbird"
if [ "$COMPRESS_BINARY" = 1 ]; then
    # Compressed payload + /usr/sbin/netbird wrapper that extracts it to
    # /tmp (RAM) on first use. Saves ~23 MB of overlay flash at the cost of
    # ~36 MB of RAM while netbird is installed.
    mkdir -p "$DATA/usr/libexec/netbird"
    gzip -9n -c "$BIN" > "$DATA/usr/libexec/netbird/netbird.gz"
    sed "s/@VERSION@/${FULLVER}/g" "$FILES_DIR/netbird-wrapper.in" > "$DATA/usr/sbin/netbird"
    chmod 0755 "$DATA/usr/sbin/netbird"
else
    install -m 0755 "$BIN" "$DATA/usr/sbin/netbird"
fi
install -m 0755 "$FILES_DIR/netbird.init" "$DATA/etc/init.d/netbird"

# Panel self-updater: pulls the latest release from this repo, verifies the
# sha256 and swaps the package in place. Installed regardless of binary layout
# (the compressed-binary path above also uses /usr/libexec/netbird).
mkdir -p "$DATA/usr/libexec/netbird"
install -m 0755 "$FILES_DIR/netbird-self-update.sh" \
    "$DATA/usr/libexec/netbird/netbird-self-update.sh"

# /etc/netbird/config.json is generated at runtime by netbird itself and is
# deliberately NOT shipped: opkg never deletes files it did not install, and
# shipping an empty JSON file would break netbird's config parser.

# sysupgrade persistence: paths listed under /lib/upgrade/keep.d/ survive a
# firmware flash with "keep settings" (enrollment config + runtime, so the
# VPN reconnects without reinstalling the ipk). See files/netbird.keep.
mkdir -p "$DATA/lib/upgrade/keep.d"
install -m 0644 "$FILES_DIR/netbird.keep" "$DATA/lib/upgrade/keep.d/netbird"

# ---- GL.iNet admin panel UI (Applications → NetBird) ----
# Native OUI integration — the same mechanism GL.iNet uses for its own
# panels (no nginx filters, no DOM injection):
#   /usr/lib/oui-httpd/rpc/netbird                  Lua RPC backend
#   /www/views/gl-sdk4-ui-netbird.common.js.gz     Vue 2 view (must be gzipped)
#   /usr/share/oui/menu.d/netbird.json             sidebar menu entry
# postinst patches the menu entry's parent_* fields from an existing
# Applications entry on the device, so the group metadata always matches
# the installed firmware. Harmless on non-GL systems: these paths are
# simply never loaded.
mkdir -p "$DATA/usr/lib/oui-httpd/rpc" \
         "$DATA/usr/share/oui/menu.d" \
         "$DATA/www/views"
install -m 0644 "$FILES_DIR/ui/rpc/netbird" "$DATA/usr/lib/oui-httpd/rpc/netbird"
install -m 0644 "$FILES_DIR/ui/menu/netbird.json" "$DATA/usr/share/oui/menu.d/netbird.json"
# {{VERSION}} stamping shows the package version in the page footer.
sed "s/{{VERSION}}/${FULLVER}/g" "$FILES_DIR/ui/www/gl-sdk4-ui-netbird.common.js" \
    | gzip -9n > "$DATA/www/views/gl-sdk4-ui-netbird.common.js.gz"
chmod 0644 "$DATA/www/views/gl-sdk4-ui-netbird.common.js.gz"

INSTALLED_SIZE="$(du -sb "$DATA" | cut -f1)"

# ------------------------------------------------------------- control ----
CONTROL="$WORK/control"
mkdir -p "$CONTROL"

cat > "$CONTROL/control" <<EOF
Package: netbird
Version: ${FULLVER}
Architecture: ${OPENWRT_ARCH}
Maintainer: Andrea Ferrario <andre.ferrario@icloud.com>
Section: net
Priority: optional
Depends: kmod-tun, ca-bundle
Installed-Size: ${INSTALLED_SIZE}
Description: NetBird P2P WireGuard-based VPN client (static build).
 Connects this device to a NetBird network. Uses the kernel WireGuard
 module when available and transparently falls back to the embedded
 userspace wireguard-go implementation (requires only /dev/net/tun),
 so kmod-wireguard is not a dependency.
 Maintained at https://github.com/AndreaF17/netbird-glinet-integration
 (issues and PRs welcome).
EOF

# No conffiles entry: /etc/netbird/config.json is generated at runtime, so
# listing it makes opkg error trying to checksum a missing file at install.
# It is preserved across upgrades/removal anyway — opkg only deletes files
# it installed itself.

install -m 0755 "$FILES_DIR/postinst" "$CONTROL/postinst"
install -m 0755 "$FILES_DIR/prerm" "$CONTROL/prerm"
install -m 0755 "$FILES_DIR/postrm" "$CONTROL/postrm"

# ------------------------------------------------------------ assemble ----
echo "2.0" > "$WORK/debian-binary"

tar_repro -czf "$WORK/control.tar.gz" -C "$CONTROL" .
tar_repro -czf "$WORK/data.tar.gz" -C "$DATA" .

IPK="$OUT_DIR/netbird_${FULLVER}_${OPENWRT_ARCH}.ipk"
mkdir -p "$OUT_DIR"
tar_repro -czf "$IPK" -C "$WORK" ./debian-binary ./control.tar.gz ./data.tar.gz

echo "==> Wrote $IPK"
ls -lh "$IPK"
