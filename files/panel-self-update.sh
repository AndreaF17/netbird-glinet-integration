#!/bin/sh
# Panel/integration self-update for the GL.iNet GL-X2000 NetBird panel.
#
# Downloads the latest integration .ipk from THIS repo's GitHub Releases into
# /tmp, verifies its sha256 against the release's sha256sums.txt, installs it
# with `opkg install`, then removes the .ipk from /tmp. Driven by the panel's
# update banner (RPC do_panel_update); safe to run by hand too.
#
# Self-replacement note: this script lives INSIDE the package it installs, so
# opkg would overwrite it mid-run. It therefore stages a copy in /tmp and runs
# that (the RPC already invokes the /tmp copy; the guard below also protects
# manual runs). The RPC also runs us detached via setsid so the `kill nginx`
# in our own postinst can't reach the install.
set -eu

# ---- run from a /tmp copy, never from the package path ---------------------
case "$0" in
    /tmp/*) : ;;                                   # already staged
    *)
        STAGE=/tmp/netbird-panel-update.run.sh
        cp -f "$0" "$STAGE" 2>/dev/null && exec sh "$STAGE" "$@"
        ;;                                         # (falls through if cp failed)
esac

REPO="AndreaF17/netbird-glinet-integration"
API="https://api.github.com/repos/${REPO}/releases/latest"
UA="netbird-glx2000-panel-updater"

LOG="/tmp/netbird-panel-update.log"
DL_DIR="/tmp/netbird-panel-update"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# ---- HTTP (curl preferred; uclient-fetch / wget fallback) -----------------
http_get() {        # url -> stdout
    if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 15 --max-time 60 -A "$UA" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -qO - --timeout=60 "$1"
    else wget -qO - -T 60 "$1"; fi
}
http_download() {   # url dest
    if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 15 --max-time 300 -A "$UA" -o "$2" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -qO "$2" --timeout=300 "$1"
    else wget -qO "$2" -T 300 "$1"; fi
}

# Installed package architecture (the .ipk filename embeds it). Fall back to
# the only arch this repo builds.
pkg_arch() {
    a="$(opkg status netbird 2>/dev/null | sed -n 's/^Architecture: *//p' | head -n1)"
    [ -n "$a" ] && printf '%s' "$a" || printf '%s' "aarch64_cortex-a53_neon-vfpv4"
}

# Latest release tag (without a leading v). API first; on failure (the
# unauthenticated GitHub API is 60 req/h per IP -- easily exhausted behind
# CGNAT LTE) fall back to the /releases/latest redirect, which has no quota.
resolve_latest() {
    ver=""
    if json="$(http_get "$API")" && [ -n "$json" ]; then
        ver="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1)"
    fi
    if [ -z "$ver" ] || [ "$ver" = "null" ]; then
        if command -v curl >/dev/null 2>&1; then
            loc="$(curl -fsSI --connect-timeout 15 --max-time 30 -A "$UA" \
                "https://github.com/${REPO}/releases/latest" 2>/dev/null \
                | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r' | head -n1)"
        else
            loc="$(wget -S --spider -T 30 "https://github.com/${REPO}/releases/latest" 2>&1 \
                | sed -n 's/^ *[Ll]ocation: *//p' | tr -d '\r' | head -n1)"
        fi
        ver="$(printf '%s' "$loc" | sed -n 's/.*\/releases\/tag\/v\{0,1\}\([^/]*\)$/\1/p')"
    fi
    [ -n "$ver" ] && [ "$ver" != "null" ] || return 1
    printf '%s\n' "$ver"
}

# Free space (KB) on the filesystem opkg unpacks into. Empty when unparsable.
overlay_free_kb() {
    df -k /usr/lib 2>/dev/null | awk 'NR==2 {print $4}' | grep -E '^[0-9]+$' || true
}

cmd_run() {
    : > "$LOG"
    log "Starting panel self-update."

    if ! ver="$(resolve_latest)" || [ -z "$ver" ]; then
        log "ERROR: could not resolve the latest panel release. Aborting."
        return 1
    fi
    # Keep the version to a safe charset (it lands in a URL and a filename).
    if ! printf '%s' "$ver" | grep -Eq '^[0-9A-Za-z][0-9A-Za-z.+-]*$'; then
        log "ERROR: refusing suspicious release tag '${ver}'. Aborting."
        return 1
    fi

    arch="$(pkg_arch)"
    ipk="netbird_${ver}_${arch}.ipk"
    base="https://github.com/${REPO}/releases/download/v${ver}"
    log "Latest panel: v${ver} (${arch})"

    # Pre-flight: a full overlay aborts opkg halfway through the transaction
    # (observed in the field: package left "deinstall user installed") -- far
    # worse than not starting. Only a conservative floor; skip if df output
    # is unparsable.
    free="$(overlay_free_kb)"
    if [ -n "$free" ] && [ "$free" -lt 2048 ]; then
        log "ERROR: only ${free} KB free on the overlay; ~2 MB is needed to"
        log "ERROR: install safely. Free some space and retry. Aborting."
        return 1
    fi

    rm -rf "$DL_DIR"; mkdir -p "$DL_DIR"
    log "Downloading ${ipk} into /tmp ..."
    if ! http_download "${base}/${ipk}" "$DL_DIR/$ipk"; then
        log "ERROR: download failed. Aborting (nothing changed)."
        rm -rf "$DL_DIR"
        return 1
    fi

    # Verify sha256 against the release's sha256sums.txt. If that file is
    # missing we still proceed (GitHub served the .ipk over TLS), but a present
    # sums file with a mismatch is fatal.
    if http_download "${base}/sha256sums.txt" "$DL_DIR/sha256sums.txt"; then
        want="$(awk -v f="$ipk" '$2 == f {print $1}' "$DL_DIR/sha256sums.txt" | head -n1)"
        got="$(sha256sum "$DL_DIR/$ipk" | awk '{print $1}')"
        if [ -n "$want" ] && [ "$want" != "$got" ]; then
            log "ERROR: checksum mismatch (want ${want}, got ${got}). Aborting."
            rm -rf "$DL_DIR"
            return 1
        fi
        log "Checksum OK (${got})."
    else
        log "WARNING: sha256sums.txt not found; proceeding (TLS-only check)."
    fi

    log "Installing ${ipk} with opkg ..."
    # GL's own background opkg runs can hold the lock; that is transient, so
    # retry a couple of times. Any other opkg failure is final.
    RETRY_DELAY="${NETBIRD_OPKG_RETRY_DELAY:-15}"
    tries=0
    while :; do
        if opkg install "$DL_DIR/$ipk" >> "$LOG" 2>&1; then
            log "DONE: panel updated to v${ver}. Reload the panel page to load it."
            break
        fi
        tries=$((tries + 1))
        if [ "$tries" -lt 3 ] && tail -n 5 "$LOG" | grep -qi 'lock'; then
            log "opkg lock is busy; retrying in ${RETRY_DELAY}s (attempt $((tries + 1))/3) ..."
            sleep "$RETRY_DELAY"
            continue
        fi
        log "ERROR: opkg install failed (see the lines above)."
        rm -rf "$DL_DIR"
        return 1
    done

    # Remove the downloaded .ipk from /tmp.
    rm -rf "$DL_DIR"
}

case "${1:-run}" in
    run) cmd_run ;;
    *) echo "usage: $0 run" >&2; exit 2 ;;
esac
