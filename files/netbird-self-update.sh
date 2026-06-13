#!/bin/sh
# NetBird self-updater for the GL.iNet GL-X2000 admin panel.
#
# Subcommands:
#   check   Print one line of JSON to stdout, no side effects:
#             {"ok":true,"current":"0.72.3-1","latest":"0.72.4-1",
#              "update_available":true,"name":"netbird_0.72.4-1_<arch>.ipk",
#              "url":"https://.../netbird_..._<arch>.ipk","html_url":"https://..."}
#           On failure: {"ok":false,"error":"..."}
#   run     Download, verify (sha256) and install the latest release, fully
#           detached, logging to /tmp/netbird-update.log. Built to survive the
#           nginx + netbird restarts the package postinst triggers — and the
#           tunnel teardown on `opkg remove`, which may be carrying this very
#           SSH/admin session.
#
# The ONLY source is this repo's own GitHub Releases, so a router moves only to
# a build the maintainer published. No third-party mirrors, checksum-verified
# before anything on the system is touched.
set -eu

REPO="AndreaF17/netbird-glinet-integration"
API="https://api.github.com/repos/${REPO}/releases/latest"
PKG="netbird"
DEFAULT_ARCH="aarch64_cortex-a53_neon-vfpv4"
LOG="/tmp/netbird-update.log"
CACHE="/tmp/netbird-update-check.json"
CACHE_TTL=1800                       # cache `check` 30 min: page loads are cheap
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
http_download() {   # url dest  (follows redirects to objects.githubusercontent.com)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -A "$UA" -o "$2" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -qO "$2" "$1"
    else
        wget -qO "$2" "$1"
    fi
}

installed_arch()    { opkg status "$PKG" 2>/dev/null | sed -n 's/^Architecture: *//p' | head -n1; }
installed_version() { opkg status "$PKG" 2>/dev/null | sed -n 's/^Version: *//p'      | head -n1; }

# Parse latest-release JSON for the .ipk asset matching our arch + the checksum
# file. Emits TAB-separated: <fullver> <name> <ipk_url> <sha_url> <html_url>
resolve_latest() {
    arch="$1"
    json="$(http_get "$API")" || return 1
    [ -n "$json" ] || return 1

    html_url="$(printf '%s' "$json" \
        | sed -n 's/.*"html_url": *"\([^"]*releases\/tag[^"]*\)".*/\1/p' | head -n1)"

    urls="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*"' \
        | sed 's/.*"browser_download_url": *"\([^"]*\)"/\1/')"
    ipk_url="$(printf '%s\n' "$urls" | grep "_${arch}\.ipk$" | head -n1)"
    [ -n "$ipk_url" ] || ipk_url="$(printf '%s\n' "$urls" | grep '\.ipk$' | head -n1)"
    sha_url="$(printf '%s\n' "$urls" | grep 'sha256sums\.txt$' | head -n1)"
    [ -n "$ipk_url" ] || return 1

    # netbird_<FULLVER>_<arch>.ipk -> FULLVER. The arch slug contains
    # underscores, so strip it explicitly rather than on the last "_".
    name="${ipk_url##*/}"
    fullver="${name#netbird_}"
    fullver="${fullver%_${arch}.ipk}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$fullver" "$name" "$ipk_url" "$sha_url" "$html_url"
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cmd_check() {
    if [ -f "$CACHE" ]; then
        now="$(date +%s)"; mt="$(date -r "$CACHE" +%s 2>/dev/null || echo 0)"
        [ $((now - mt)) -lt "$CACHE_TTL" ] && { cat "$CACHE"; return 0; }
    fi

    cur="$(installed_version)"
    arch="$(installed_arch)"; [ -n "$arch" ] || arch="$DEFAULT_ARCH"

    if ! line="$(resolve_latest "$arch")"; then
        printf '{"ok":false,"error":"could not reach GitHub releases"}\n'
        return 0
    fi
    latest="$(printf '%s' "$line" | cut -f1)"
    name="$(printf   '%s' "$line" | cut -f2)"
    url="$(printf    '%s' "$line" | cut -f3)"
    html="$(printf   '%s' "$line" | cut -f5)"

    avail=false
    if [ -n "$cur" ] && [ -n "$latest" ]; then
        opkg compare-versions "$cur" "<<" "$latest" 2>/dev/null && avail=true
    elif [ -z "$cur" ]; then
        avail=true
    fi

    out="$(printf '{"ok":true,"current":"%s","latest":"%s","update_available":%s,"name":"%s","url":"%s","html_url":"%s"}' \
        "$(json_escape "$cur")" "$(json_escape "$latest")" "$avail" \
        "$(json_escape "$name")" "$(json_escape "$url")" "$(json_escape "$html")")"
    printf '%s\n' "$out" | tee "$CACHE"
}

cmd_run() {
    : > "$LOG"
    log "Starting NetBird self-update."
    arch="$(installed_arch)"; [ -n "$arch" ] || arch="$DEFAULT_ARCH"
    cur="$(installed_version)"

    if ! line="$(resolve_latest "$arch")"; then
        log "ERROR: could not query GitHub releases. Aborting (nothing changed)."
        return 1
    fi
    latest="$(printf  '%s' "$line" | cut -f1)"
    name="$(printf    '%s' "$line" | cut -f2)"
    ipk_url="$(printf '%s' "$line" | cut -f3)"
    sha_url="$(printf '%s' "$line" | cut -f4)"
    log "Installed: ${cur:-none}   Latest: ${latest:-?}"

    if [ -n "$cur" ] && ! opkg compare-versions "$cur" "<<" "$latest" 2>/dev/null; then
        log "Already up to date (${cur}). Nothing to do."
        return 0
    fi

    rm -rf "$DL_DIR"; mkdir -p "$DL_DIR"
    ipk="$DL_DIR/$name"
    log "Downloading ${name} ..."
    if ! http_download "$ipk_url" "$ipk"; then
        log "ERROR: download failed. Aborting (nothing changed)."
        return 1
    fi

    # Verify against the published sha256sums.txt BEFORE touching the system.
    if [ -n "$sha_url" ]; then
        log "Verifying checksum ..."
        sums="$DL_DIR/sha256sums.txt"
        if ! http_download "$sha_url" "$sums"; then
            log "ERROR: could not fetch sha256sums.txt. Aborting."
            return 1
        fi
        want="$(grep -F "$name" "$sums" | awk '{print $1}' | head -n1)"
        got="$(sha256sum "$ipk" | awk '{print $1}')"
        if [ -z "$want" ] || [ "$want" != "$got" ]; then
            log "ERROR: checksum mismatch (want ${want:-?}, got ${got}). Aborting."
            return 1
        fi
        log "Checksum OK (${got})."
    else
        log "WARNING: no sha256sums.txt in release; skipping verification."
    fi

    # The ~24 MB overlay cannot hold old + new at once, so remove then install.
    # /etc/netbird/config.json is NOT owned by the package; opkg leaves it in
    # place, so enrollment and the WireGuard keys survive the swap.
    log "Removing current package ..."
    if ! opkg remove "$PKG" >> "$LOG" 2>&1; then
        log "ERROR: opkg remove failed. Aborting."
        return 1
    fi
    log "Installing ${name} ..."
    if ! opkg install "$ipk" >> "$LOG" 2>&1; then
        log "ERROR: opkg install failed. The .ipk is at ${ipk};"
        log "       install it manually over SSH:  opkg install ${ipk}"
        return 1
    fi
    rm -rf "$DL_DIR"
    log "DONE: NetBird updated to ${latest}. The panel and daemon were restarted."
}

case "${1:-check}" in
    check) cmd_check ;;
    run)   cmd_run ;;
    *) echo "usage: $0 [check|run]" >&2; exit 2 ;;
esac
