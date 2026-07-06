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
# The pre-update binary is parked here during the post-restart health check
# so a failed update can be rolled back. It must live OUTSIDE RUNTIME_DIR:
# the init's stop_service wipes that dir on every restart.
PREV_DIR="/tmp/netbird-prev"

LOG="/tmp/netbird-update.log"
CACHE="/tmp/netbird-update-check.json"
CACHE_TTL=1800                          # cache `check` 30 min; page loads are cheap
DL_DIR="/tmp/netbird-update"
UA="netbird-glx2000-updater"

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# ---- HTTP (curl preferred; uclient-fetch / wget fallback) -----------------
http_get() {        # url -> stdout
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 60 -A "$UA" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -qO - --timeout=60 "$1"
    else
        wget -qO - -T 60 "$1"
    fi
}
http_download() {   # url dest  (follows the redirect to objects.githubusercontent.com)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 300 -A "$UA" -o "$2" "$1"
    elif command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -qO "$2" --timeout=300 "$1"
    else
        wget -qO "$2" -T 300 "$1"
    fi
}
http_redirect() {   # url -> its Location header (no redirect following, no body)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --connect-timeout 15 --max-time 30 -A "$UA" "$1" 2>/dev/null \
            | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r' | head -n1
    else
        wget -S --spider -T 30 "$1" 2>&1 \
            | sed -n 's/^ *[Ll]ocation: *//p' | tr -d '\r' | head -n1
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
# Primary source is the API; when that fails (the unauthenticated GitHub API
# allows 60 req/h per IP -- easily exhausted behind CGNAT LTE), fall back to
# the /releases/latest web URL, whose 302 Location carries the tag and has no
# such quota.
resolve_latest() {
    ver=""; html=""
    if json="$(http_get "$API")" && [ -n "$json" ]; then
        ver="$(printf '%s' "$json" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1)"
        html="$(printf '%s' "$json" | sed -n 's/.*"html_url": *"\([^"]*releases\/tag[^"]*\)".*/\1/p' | head -n1)"
    fi
    if [ -z "$ver" ] || [ "$ver" = "null" ]; then
        html="$(http_redirect "https://github.com/${REPO}/releases/latest")" || html=""
        ver="$(printf '%s' "$html" | sed -n 's/.*\/releases\/tag\/v\{0,1\}\([^/]*\)$/\1/p')"
    fi
    [ -n "$ver" ] && [ "$ver" != "null" ] || return 1
    printf '%s\t%s\n' "$ver" "$html"
}

# ---- post-restart health check ---------------------------------------------
# A remote site must never be stranded by an update: after the daemon restart
# the updater waits for the process (and, if there was one before the update,
# the management session) to come back, and rolls back otherwise.
HEALTH_WAIT="${NETBIRD_HEALTH_WAIT:-90}"    # seconds to wait for recovery
HEALTH_POLL="${NETBIRD_HEALTH_POLL:-5}"

daemon_running_now() { pgrep -f 'netbird[^ ]* service' >/dev/null 2>&1; }
mgmt_connected_now() {
    timeout 15 "$PLAIN_BIN" status 2>/dev/null | grep -qi 'management: *connected'
}
health_ok() {   # $1 = "connected" to also require the management session
    waited=0
    while [ "$waited" -lt "$HEALTH_WAIT" ]; do
        if daemon_running_now; then
            [ "$1" = "connected" ] || return 0
            mgmt_connected_now && return 0
        fi
        sleep "$HEALTH_POLL"
        waited=$((waited + HEALTH_POLL))
    done
    return 1
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

# Failure fallback for the compressed layout. The small overlay forces the old
# netbird.gz to be deleted before the new one is written, so an aborted install
# would otherwise leave NO payload on flash: the running daemon survives (its
# binary is open in RAM) but the next restart/reboot has nothing to extract.
# The old UNCOMPRESSED binary normally still sits at $RUNTIME_DIR/netbird, so
# recompress that back onto the flash. Always returns 0: the caller is already
# on its failure path and must reach its own logging/return.
restore_payload() {
    if [ -f "$BIN_GZ" ]; then return 0; fi
    if [ -x "$RUNTIME_DIR/netbird" ]; then
        log "Restoring the previous netbird payload from RAM ..."
        if gzip -9n < "$RUNTIME_DIR/netbird" > "${BIN_GZ}.part" 2>/dev/null \
                && mv "${BIN_GZ}.part" "$BIN_GZ"; then
            log "Previous payload restored; netbird keeps running the old version."
            return 0
        fi
        rm -f "${BIN_GZ}.part"
    fi
    log "WARNING: no netbird payload left on flash. netbird keeps running until"
    log "WARNING: the next restart/reboot -- retry the update before rebooting."
    return 0
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

    # Health target for the post-restart check: only demand a management
    # session if there is one to lose right now (a deliberately-disconnected
    # client must not trigger a rollback loop).
    health_want=daemon
    if mgmt_connected_now; then health_want=connected; fi

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

    # Install, matching the layout already on disk. Layout is decided by whether
    # /usr/sbin/netbird is the wrapper (a shell script) rather than by netbird.gz
    # existing — on a fresh install the .gz is not there yet, but the wrapper is,
    # so we must write the .gz (not clobber the wrapper).
    mkdir -p "$LIBEXEC"
    if [ -f "$BIN_GZ" ] || head -n1 "$PLAIN_BIN" 2>/dev/null | grep -q '^#!'; then
        log "Installing (compressed layout) ..."
        # The ~24 MB overlay cannot hold two ~13 MB .gz copies, so the old
        # payload must be removed before the new one is written. But NEVER
        # stream into the final path: the wrapper re-extracts whenever it sees
        # netbird.gz newer than the extracted binary, so a half-written .gz
        # makes every netbird invocation (panel status polls, procd respawn)
        # fail for the whole multi-minute recompression. netbird.gz must be
        # either absent (wrapper keeps using the extracted binary) or complete:
        # write to a .part on the same filesystem, mv into place once valid.
        # The source tarball is already sha256-verified, so we trust the stream
        # and validate the result below.
        PART="${BIN_GZ}.part"
        rm -f "$BIN_GZ" "$PART"
        # Stream the binary straight from the verified tarball into gzip -9 --
        # never materialising the ~37 MB uncompressed binary in RAM-backed /tmp.
        # gzip -9 (vs -1) saves ~1.4 MB on the tiny overlay for a one-time CPU
        # cost; decompression speed is unaffected by the level.
        if ! tar -xzOf "$DL_DIR/$tarball" netbird 2>/dev/null | gzip -9n > "$PART"; then
            log "ERROR: extract/recompress pipeline failed (overlay full?). Aborting."
            rm -f "$PART"
            restore_payload
            return 1
        fi
        # Validate: a plausibly-sized binary must decompress out (guards a
        # truncated extract that still produced a structurally-valid .gz).
        nbytes="$(gunzip -c "$PART" 2>/dev/null | wc -c)"
        if [ ! -s "$PART" ] || [ "${nbytes:-0}" -lt 20000000 ]; then
            log "ERROR: recompressed binary failed validation (${nbytes:-0} bytes). Aborting."
            rm -f "$PART"
            restore_payload
            return 1
        fi
        if ! mv "$PART" "$BIN_GZ"; then
            log "ERROR: could not move the new payload into place. Aborting."
            rm -f "$PART"
            restore_payload
            return 1
        fi
        compressed=1
    else
        log "Installing (plain layout) ..."
        if ! tar -xzf "$DL_DIR/$tarball" -C "$DL_DIR" netbird; then
            log "ERROR: could not extract 'netbird' from the archive. Aborting."
            return 1
        fi
        chmod 0755 "$DL_DIR/netbird"
        install -m 0755 "$DL_DIR/netbird" "${PLAIN_BIN}.new"
        mv "${PLAIN_BIN}.new" "$PLAIN_BIN"
        compressed=0
    fi

    printf '%s\n' "$latest" > "$VERSION_FILE"
    rm -rf "$DL_DIR"
    # The cached `check` result still claims an update is available; drop it
    # so the panel's next check shows "Up to date" immediately.
    rm -f "$CACHE"

    # Park the old extracted binary for a possible rollback (compressed layout
    # only; the plain layout has no spare copy to keep). The running daemon is
    # unaffected by the rename -- its inode stays open until the restart.
    rollback_ready=0
    if [ "$compressed" = 1 ]; then
        rm -rf "$PREV_DIR"
        if [ -x "$RUNTIME_DIR/netbird" ]; then
            mkdir -p "$PREV_DIR"
            mv "$RUNTIME_DIR/netbird" "$PREV_DIR/netbird" 2>/dev/null && rollback_ready=1
        fi
        rm -rf "$RUNTIME_DIR"      # force the wrapper to re-extract the new binary
    fi

    log "Restarting netbird daemon ..."
    "$INIT" restart >> "$LOG" 2>&1 || log "WARNING: daemon restart returned non-zero."

    if health_ok "$health_want"; then
        rm -rf "$PREV_DIR"
        log "Health check OK (${health_want})."
        log "DONE: netbird updated to ${latest}."
        return 0
    fi
    log "ERROR: netbird ${latest} did not come back healthy (wanted: ${health_want})."
    if [ "$rollback_ready" != 1 ]; then
        log "No previous binary kept; leaving ${latest} in place -- inspect manually."
        return 1
    fi

    log "Rolling back to ${cur:-the previous version} ..."
    "$INIT" stop >> "$LOG" 2>&1 || true
    mkdir -p "$RUNTIME_DIR"
    if ! mv "$PREV_DIR/netbird" "$RUNTIME_DIR/netbird"; then
        log "ERROR: could not restore the previous binary; inspect manually."
        return 1
    fi
    # Newer than the (new-version) netbird.gz, so the wrapper runs it as-is
    # instead of re-extracting the failed payload.
    touch "$RUNTIME_DIR/netbird"
    if [ -n "$cur" ]; then printf '%s\n' "$cur" > "$VERSION_FILE"; fi
    "$INIT" start >> "$LOG" 2>&1 || log "WARNING: daemon start returned non-zero."
    # Persist the old payload back to flash so the rollback survives a reboot.
    # Slow (gzip -9), but the daemon is already back up while this runs.
    rm -f "$BIN_GZ"
    if gzip -9n < "$RUNTIME_DIR/netbird" > "${BIN_GZ}.part" 2>/dev/null \
            && mv "${BIN_GZ}.part" "$BIN_GZ"; then
        log "Previous payload persisted back to flash."
    else
        rm -f "${BIN_GZ}.part"
        log "WARNING: could not persist the previous payload to flash; avoid"
        log "WARNING: rebooting until an update succeeds -- the daemon itself is fine."
    fi
    rm -rf "$PREV_DIR"
    rm -f "$CACHE"
    if health_ok "$health_want"; then
        log "Rollback complete: netbird ${cur:-previous} is healthy again."
    else
        log "WARNING: rollback finished but the health check still fails; inspect manually."
    fi
    log "ERROR: update to ${latest} was rolled back."
    return 1
}

case "${1:-check}" in
    check) cmd_check ;;
    run)   cmd_run ;;
    *) echo "usage: $0 [check|run]" >&2; exit 2 ;;
esac
