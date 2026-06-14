#!/bin/sh
# Direct NetBird binary updater for the GL.iNet GL-X2000 admin panel.
#
# This does NOT install a package. It pulls the OFFICIAL netbird binary
# straight from netbirdio/netbird releases and swaps it under the wrapper —
# the same artifact pkgs.netbird.io/install.sh ships. The GL panel/integration
# is a separate package and is left untouched; only the netbird executable
# moves. That means new netbird versions never require a rebuild on our side.
#
# Subcommands:
#   check  Print one line of JSON to stdout, no side effects:
#            {"ok":true,"current":"0.72.3","latest":"0.72.4",
#             "update_available":true,"html_url":"https://github.com/netbirdio/..."}
#          On failure: {"ok":false,"error":"..."}
#   run    Download + verify (sha256) + install the latest netbird binary,
#          fully detached, logging to /tmp/netbird-update.log. Built to survive
#          the daemon restart (and the brief tunnel drop) at the end.
#
# Flash note: the GL-X2000 overlay (~24 MB) cannot hold the ~36 MB binary, so
# in the default layout it is stored gzip-compressed at /usr/libexec/netbird/
# netbird.gz and extracted to RAM by the wrapper. This updater replaces that
# .gz; with the plain layout it replaces /usr/sbin/netbird directly.
set -eu

REPO="netbirdio/netbird"
API="https://api.github.com/repos/${REPO}/releases/latest"
ASSET_ARCH="${NETBIRD_ASSET_ARCH:-linux_arm64}"

INIT="/etc/init.d/netbird"
LIBEXEC="/usr/libexec/netbird"
BIN_GZ="${LIBEXEC}/netbird.gz"          # present in the compressed (default) layout
PLAIN_BIN="/usr/sbin/netbird"           # the wrapper in compressed layout; the binary in plain
VERSION_FILE="${LIBEXEC}/netbird.version"
RUNTIME_DIR="/tmp/netbird-runtime"

LOG="/tmp/netbird-update.log"
CACHE="/tmp/netbird-update-check.json"
CACHE_TTL=1800                          # cache `check` 30 min; page loads are cheap
DL_DIR="/tmp/netbird-update"
UA="netbird-glx2000-updater"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# ---- HTTP (curl preferred; uclient-fetch / wget fallback) -----------------
http_get() {        # url -> stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -A "$UA" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -qO - "$1"
    else
        wget -qO - "$1"
    fi
}
http_download() {   # url dest  (follows the redirect to objects.githubusercontent.com)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -A "$UA" -o "$2" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -qO "$2" "$1"
    else
        wget -qO "$2" "$1"
    fi
}

# Installed netbird version. Prefer the state file (fast); fall back to asking
# the binary (slow with the compressed layout — it must extract first).
installed_version() {
    if [ -r "$VERSION_FILE" ]; then
        v="$(head -n1 "$VERSION_FILE" 2>/dev/null)"
    else
        v="$("$PLAIN_BIN" version 2>/dev/null | head -n1)"
    fi
    v="${v#v}"
    printf '%s' "$v" | awk '{print $1}'
}

# Latest netbird version + release page. Emits: <version>\t<html_url>
resolve_latest() {
    json="$(http_get "$API")" || return 1
    [ -n "$json" ] || return 1
    ver="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1)"
    html="$(printf '%s' "$json" | sed -n 's/.*"html_url": *"\([^"]*releases\/tag[^"]*\)".*/\1/p' | head -n1)"
    [ -n "$ver" ] && [ "$ver" != "null" ] || return 1
    printf '%s\t%s\n' "$ver" "$html"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Compare dotted versions: 0 (true) if $1 < $2. Uses opkg when available
# (handles every quirk); otherwise a portable sort -V fallback.
older_than() {  # a b -> rc 0 if a < b
    [ "$1" = "$2" ] && return 1
    if command -v opkg >/dev/null 2>&1; then
        opkg compare-versions "$1" "<<" "$2" 2>/dev/null && return 0 || return 1
    fi
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

cmd_check() {
    if [ -f "$CACHE" ]; then
        now="$(date +%s)"; mt="$(date -r "$CACHE" +%s 2>/dev/null || echo 0)"
        [ $((now - mt)) -lt "$CACHE_TTL" ] && { cat "$CACHE"; return 0; }
    fi

    cur="$(installed_version)"
    if ! line="$(resolve_latest)"; then
        printf '{"ok":false,"error":"could not reach netbird releases"}\n'
        return 0
    fi
    latest="$(printf '%s' "$line" | cut -f1)"
    html="$(printf  '%s' "$line" | cut -f2)"

    avail=false
    if [ -z "$cur" ]; then
        avail=true
    elif older_than "$cur" "$latest"; then
        avail=true
    fi

    out="$(printf '{"ok":true,"current":"%s","latest":"%s","update_available":%s,"html_url":"%s"}' \
        "$(json_escape "$cur")" "$(json_escape "$latest")" "$avail" "$(json_escape "$html")")"
    printf '%s\n' "$out" | tee "$CACHE"
}

cmd_run() {
    : > "$LOG"
    log "Starting direct NetBird binary update."
    cur="$(installed_version)"
    if ! line="$(resolve_latest)"; then
        log "ERROR: could not query netbird releases. Aborting (nothing changed)."
        return 1
    fi
    latest="$(printf '%s' "$line" | cut -f1)"
    log "Installed: ${cur:-unknown}   Latest netbird: ${latest}"

    if [ -n "$cur" ] && ! older_than "$cur" "$latest"; then
        log "Already up to date (${cur}). Nothing to do."
        return 0
    fi

    tarball="netbird_${latest}_${ASSET_ARCH}.tar.gz"
    sums="netbird_${latest}_checksums.txt"
    base="https://github.com/${REPO}/releases/download/v${latest}"

    rm -rf "$DL_DIR"; mkdir -p "$DL_DIR"
    log "Downloading ${tarball} ..."
    if ! http_download "${base}/${tarball}" "$DL_DIR/$tarball"; then
        log "ERROR: download failed. Aborting (nothing changed)."
        return 1
    fi

    log "Verifying checksum ..."
    if ! http_download "${base}/${sums}" "$DL_DIR/$sums"; then
        log "ERROR: could not fetch ${sums}. Aborting."
        return 1
    fi
    want="$(awk -v f="$tarball" '$2 == f {print $1}' "$DL_DIR/$sums" | head -n1)"
    got="$(sha256sum "$DL_DIR/$tarball" | awk '{print $1}')"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
        log "ERROR: checksum mismatch (want ${want:-?}, got ${got}). Aborting."
        return 1
    fi
    log "Checksum OK (${got})."

    log "Extracting netbird binary ..."
    if ! tar -xzf "$DL_DIR/$tarball" -C "$DL_DIR" netbird; then
        log "ERROR: could not extract 'netbird' from the archive. Aborting."
        return 1
    fi
    chmod 0755 "$DL_DIR/netbird"

    # Swap the binary in place (atomic rename), matching the installed layout.
    # Layout is decided by whether /usr/sbin/netbird is the wrapper (a shell
    # script) rather than by netbird.gz existing — on a fresh install the .gz
    # is not there yet, but the wrapper is, so we must write the .gz (not
    # clobber the wrapper).
    mkdir -p "$LIBEXEC"
    if [ -f "$BIN_GZ" ] || head -n1 "$PLAIN_BIN" 2>/dev/null | grep -q '^#!'; then
        log "Installing (compressed layout) ..."
        gzip -9n -c "$DL_DIR/netbird" > "${BIN_GZ}.new"
        mv "${BIN_GZ}.new" "$BIN_GZ"
        rm -rf "$RUNTIME_DIR"          # force the wrapper to re-extract the new binary
    else
        log "Installing (plain layout) ..."
        install -m 0755 "$DL_DIR/netbird" "${PLAIN_BIN}.new"
        mv "${PLAIN_BIN}.new" "$PLAIN_BIN"
    fi

    printf '%s\n' "$latest" > "$VERSION_FILE"
    rm -rf "$DL_DIR"

    log "Restarting netbird daemon ..."
    "$INIT" restart >> "$LOG" 2>&1 || log "WARNING: daemon restart returned non-zero."
    log "DONE: netbird updated to ${latest}."
}

case "${1:-check}" in
    check) cmd_check ;;
    run)   cmd_run ;;
    *) echo "usage: $0 [check|run]" >&2; exit 2 ;;
esac
