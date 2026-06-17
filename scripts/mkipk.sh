#!/bin/sh
# Assemble the legacy-format OpenWrt .ipk for the GL.iNet GL-X2000 NetBird
# integration: an outer tar.gz containing debian-binary, control.tar.gz and
# data.tar.gz (what opkg on 19.07 / GL.iNet QSDK firmware expects).
#
# This packages the INTEGRATION ONLY — the GL admin panel, the /usr/sbin/netbird
# wrapper, the init script and the self-updater. It does NOT contain a netbird
# binary: postinst downloads the official netbird client directly from
# netbirdio/netbird at install time, and the panel's "NetBird update" card keeps
# it current afterward. So the package version tracks the integration, not
# netbird.
#
# Runs INSIDE the build container so GNU tar is guaranteed (BSD tar on macOS
# produces archives opkg may choke on). Expects:
#   INTEGRATION_VERSION  - panel/integration version (default 1.0)
#   OPENWRT_ARCH         - opkg Architecture string (default for the GL-X2000)
#   FILES_DIR            - dir with the shipped files (default /work/files)
#   OUT_DIR              - where to write the .ipk (default /work/out)
set -eu

INTEGRATION_VERSION="${INTEGRATION_VERSION:-1.0}"
OPENWRT_ARCH="${OPENWRT_ARCH:-aarch64_cortex-a53_neon-vfpv4}"
FILES_DIR="${FILES_DIR:-/work/files}"
OUT_DIR="${OUT_DIR:-/work/out}"

VER="${INTEGRATION_VERSION#v}"
# Keep the version to a safe opkg charset (lands in the control file + filename).
echo "$VER" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z.+-]*$' \
    || { echo "error: invalid INTEGRATION_VERSION '$VER'" >&2; exit 1; }

if ! tar --version 2>/dev/null | grep -q "GNU tar"; then
    echo "error: GNU tar required (run this inside the build container)" >&2
    exit 1
fi

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
mkdir -p "$DATA/usr/sbin" "$DATA/etc/init.d" "$DATA/etc/netbird" \
         "$DATA/usr/libexec/netbird"

# /usr/sbin/netbird is the wrapper: it decompresses the netbird binary (stored
# at /usr/libexec/netbird/netbird.gz by the updater) to RAM-backed /tmp on first
# use. The ~36 MB binary can't live on the ~24 MB overlay, so it is never on
# flash uncompressed. @VERSION@ stamps the integration version.
sed "s/@VERSION@/${VER}/g" "$FILES_DIR/netbird-wrapper.in" > "$DATA/usr/sbin/netbird"
chmod 0755 "$DATA/usr/sbin/netbird"

install -m 0755 "$FILES_DIR/netbird.init" "$DATA/etc/init.d/netbird"

# Self-updater: downloads the OFFICIAL netbird binary directly from
# netbirdio/netbird, verifies the sha256 and swaps it under the wrapper. Used
# both by postinst (first install) and the panel's "NetBird update" card.
install -m 0755 "$FILES_DIR/netbird-self-update.sh" \
    "$DATA/usr/libexec/netbird/netbird-self-update.sh"

# Panel self-updater: downloads THIS integration's latest .ipk from our own
# GitHub Releases into /tmp, verifies its sha256, `opkg install`s it and removes
# the .ipk. Driven by the "Update now" button on the new-panel banner (RPC
# do_panel_update).
install -m 0755 "$FILES_DIR/panel-self-update.sh" \
    "$DATA/usr/libexec/netbird/panel-self-update.sh"

# No netbird binary or version file shipped — postinst fetches netbird and the
# updater writes /usr/libexec/netbird/netbird.version after the download.

# /etc/netbird/config.json is generated at runtime by netbird itself and is
# deliberately NOT shipped: opkg never deletes files it did not install, and
# shipping an empty JSON file would break netbird's config parser.

# sysupgrade persistence: paths listed under /lib/upgrade/keep.d/ survive a
# firmware flash with "keep settings" (enrollment config + downloaded binary,
# so the VPN reconnects without reinstalling). See files/netbird.keep.
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
# {{VERSION}} stamping shows the integration version in the page footer.
sed "s/{{VERSION}}/${VER}/g" "$FILES_DIR/ui/www/gl-sdk4-ui-netbird.common.js" \
    | gzip -9n > "$DATA/www/views/gl-sdk4-ui-netbird.common.js.gz"
chmod 0644 "$DATA/www/views/gl-sdk4-ui-netbird.common.js.gz"

INSTALLED_SIZE="$(du -sb "$DATA" | cut -f1)"

# ------------------------------------------------------------- control ----
CONTROL="$WORK/control"
mkdir -p "$CONTROL"

cat > "$CONTROL/control" <<EOF
Package: netbird
Version: ${VER}
Architecture: ${OPENWRT_ARCH}
Maintainer: Andrea Ferrario <andre.ferrario@icloud.com>
Section: net
Priority: optional
Depends: kmod-tun, ca-bundle
Installed-Size: ${INSTALLED_SIZE}
Description: NetBird VPN client + GL.iNet panel for the GL-X2000 (GL-X2000).
 GL.iNet admin-panel integration for the NetBird P2P WireGuard-based VPN.
 The netbird client itself is downloaded from the official netbird releases
 at install time and updated from the panel's "NetBird update" card, so this
 package versions the integration, not netbird. Uses kernel WireGuard when
 available and falls back to userspace wireguard-go (needs only /dev/net/tun).
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

IPK="$OUT_DIR/netbird_${VER}_${OPENWRT_ARCH}.ipk"
mkdir -p "$OUT_DIR"
tar_repro -czf "$IPK" -C "$WORK" ./debian-binary ./control.tar.gz ./data.tar.gz

echo "==> Wrote $IPK"
ls -lh "$IPK"
