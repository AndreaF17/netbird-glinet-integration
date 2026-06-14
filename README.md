# NetBird .ipk for GL.iNet GL-X2000

Packages the official [NetBird](https://github.com/netbirdio/netbird) VPN
client as an installable `.ipk` for the **GL.iNet GL-X2000** (firmware 4.7.x,
QSDK-based OpenWrt 19.07 fork, `ipq50xx`, kernel 5.4, musl). The netbird binary
is **not** built or bundled here — the router downloads the official release at
install time and the in-panel updater keeps it current; this package versions
the *integration* (panel + wrapper + init + self-updater).

Maintained by [@AndreaF17](https://github.com/AndreaF17)
— bug reports and feature requests are welcome on the
[issue tracker](https://github.com/AndreaF17/netbird-glinet-integration/issues).

## Why not the OpenWrt SDK?

Upstream OpenWrt 19.07 has no `ipq50xx` target — it only exists in GL.iNet's
QSDK, which is not publicly buildable, so there is no SDK to build a netbird
package against. Instead this integration uses netbird's own official
`linux_arm64` release binary, which upstream ships as a **fully static Go
binary** (`CGO_ENABLED=0 GOOS=linux GOARCH=arm64`). A static Go binary has zero
libc dependency, so the router's old musl userland and QSDK quirks are
irrelevant — the same binary `pkgs.netbird.io` installs runs here unchanged.
The `.ipk` itself is assembled with plain GNU tar in the legacy format opkg
19.07 expects (`debian-binary` + `control.tar.gz` + `data.tar.gz`) and carries
only the integration; the binary is fetched on the router at install time.

WireGuard: NetBird uses the kernel WireGuard module when present and
transparently falls back to its embedded userspace `wireguard-go` (which
only needs `/dev/net/tun`). That's why the package depends on `kmod-tun`
and `ca-bundle` only — **not** `kmod-wireguard`.

## Why not the official OpenWrt package?

[openwrt/packages/net/netbird](https://github.com/openwrt/packages/tree/master/net/netbird)
exists, but it targets current OpenWrt releases: its prebuilt ipks use
modern arch labels (`aarch64_cortex-a53`, not the 19.07-era
`aarch64_cortex-a53_neon-vfpv4` this firmware expects), it hard-depends on
`kmod-wireguard`, and it lags upstream (0.66.x vs 0.72.x). It is not
installable on the GL.iNet QSDK firmware. This repo does borrow its init
environment (`NB_STATE_DIR`, `NB_DISABLE_SSH_CONFIG` — both verified
present in netbird 0.72.3).

## Requirements

- **Build host (your Mac or CI):** Docker. Nothing else — no Go toolchain.
  The build only assembles the panel package; it does not fetch or compile
  netbird.
- **Router internet at install:** the netbird client is downloaded from the
  official netbird releases during install. If the router is offline at
  install time the package still installs — use the panel's *NetBird update*
  card to download netbird once it's online.
- **Router flash:** ~14 MB free overlay. The GL-X2000 has 128 MB flash with
  only ~24 MB free, which cannot hold the ~36 MB netbird binary — so it is
  stored gzip-compressed (~13 MB on flash) at `/usr/libexec/netbird/netbird.gz`
  and a small `/usr/sbin/netbird` wrapper extracts it to RAM-backed `/tmp` on
  first use after each boot. Check free space with `df -h /overlay`.
- **Router RAM:** ~36 MB of `/tmp` (tmpfs) for the extracted binary while
  netbird is installed, plus netbird's own working memory. Check `free`.

## Building (macOS or Linux)

The package contains the **integration only** — the GL panel, the
`/usr/sbin/netbird` wrapper, the init script and the self-updater. No netbird
binary is bundled; the router downloads it at install. So you version the
*integration*, and rebuild only when the panel changes.

```sh
./build.sh                          # -> ./out/netbird_1.0_<arch>.ipk
INTEGRATION_VERSION=1.1 ./build.sh  # set the panel version
# or via make:
make ipk
make ipk INTEGRATION_VERSION=1.1
```

Output: `./out/netbird_<version>_aarch64_cortex-a53_neon-vfpv4.ipk`. Bump
`INTEGRATION_VERSION` for each panel change so opkg sees the new package as
newer and upgrades instead of reporting "up to date". `make clean` removes
`./out`.

## Installing on the router

```sh
# from your computer
scp ./out/netbird_*_aarch64_cortex-a53_neon-vfpv4.ipk root@192.168.8.1:/tmp/

# on the router (ssh root@192.168.8.1)
opkg update || true
opkg install /tmp/netbird_*.ipk
```

The package installs `/usr/sbin/netbird` (a wrapper that extracts the gzipped
binary from `/usr/libexec/netbird/netbird.gz` to `/tmp` on first use), the
self-updater, and a procd init script at `/etc/init.d/netbird` (config in
`/etc/netbird`, runtime state in `/var/lib/netbird` — volatile by design to
spare flash; the device identity lives in the persistent config). During
install, `postinst` downloads the official netbird client (verified against
netbird's `sha256sums`) into `/usr/libexec/netbird/netbird.gz`, then enables
and starts the service. The first `netbird` invocation after each boot takes a
few extra seconds while the binary is decompressed.

Then enroll the device:

```sh
netbird up --setup-key <YOUR-SETUP-KEY>
# or interactively / SSO:
netbird up
netbird status
```

## Upgrading

**Easiest: from the admin panel.** Applications → NetBird shows a *NetBird
update* card that checks **netbird's own GitHub releases** on load. When a
newer netbird exists, click **Update now** — the router downloads netbird's
official `linux_arm64` binary straight from `netbirdio/netbird`, verifies it
against netbird's `sha256sums`, gzips it onto flash (replacing
`/usr/libexec/netbird/netbird.gz`) and restarts the daemon, which reconnects
automatically. No package, no opkg, no rebuild — the netbird binary is updated
directly and independently of this integration package. Backed by
`files/netbird-self-update.sh`; the running version is tracked in
`/usr/libexec/netbird/netbird.version`.

This means you only ever rebuild/reinstall the `.ipk` when the **panel itself**
changes — netbird version bumps are handled entirely by the in-panel updater.

To update netbird manually instead of via the panel, run the updater on the
router (same script the panel calls):

```sh
ssh root@192.168.8.1 "sh /usr/libexec/netbird/netbird-self-update.sh run; \
  cat /tmp/netbird-update.log"
```

**Updating the panel** (rare — only when this integration changes) is a normal
opkg upgrade of a new `.ipk`. Because the package no longer carries the netbird
binary it's tiny, so the old "remove first / Only have NNNNkb" flash dance no
longer applies — a straight `opkg install` of a newer `INTEGRATION_VERSION`
upgrades in place:

```sh
scp ./out/netbird_<newver>_*.ipk root@192.168.8.1:/tmp/
ssh root@192.168.8.1 "opkg install /tmp/netbird_<newver>_*.ipk"
```

The downloaded netbird binary (`/usr/libexec/netbird/netbird.gz`) and
`/etc/netbird/config.json` are not owned by the package, so opkg leaves them
alone across a panel upgrade — your netbird version and enrollment both
survive, and the daemon reconnects automatically.

## Firmware upgrades (sysupgrade)

The package installs `/lib/upgrade/keep.d/netbird` (same mechanism
[gl-tailscale-fix](https://github.com/RemoteToHome-io/gl-tailscale-fix)
uses): every path it lists is backed up by a firmware upgrade with **"keep
settings"** enabled and restored onto the fresh overlay after the flash.
Without it, a GL firmware upgrade silently wipes the package *and* the
enrollment — the VPN just disappears.

The list keeps the **full runtime**, not just the config:

- `/etc/netbird/` — enrollment config / device identity (`config.json`)
- `/etc/init.d/netbird` + the `/etc/rc.d/S99netbird` / `K10netbird`
  symlinks, so the service autostarts on first boot after the flash
- `/usr/sbin/netbird` (wrapper), `/usr/libexec/netbird/netbird.gz` (the
  downloaded gzipped binary) and `/usr/libexec/netbird/netbird.version` (the
  netbird version that binary is), so the netbird version installed via the
  panel travels across the flash
- the keep list itself, so persistence survives the *next* upgrade too

So netbird reconnects right after a "keep settings" firmware flash, with
no reinstall needed. Trade-off: the gzipped binary adds ~13 MB to the
sysupgrade backup archive — fine on this device, since the fresh overlay
has at least as much free space as the package occupied before the flash.

Two things are deliberately **not** kept, and come back when you reinstall
the ipk:

- **The GL admin panel page** (nginx injection + RPC files). A firmware
  upgrade may ship a different panel; reinstalling re-applies the
  integration cleanly against whatever the new firmware provides.
- **opkg's package database** — after a sysupgrade, `opkg list-installed`
  no longer shows netbird even though it is running. Reinstall the ipk at
  your convenience to restore opkg tracking (and the panel page); the
  install simply overwrites the kept files.

Firmware upgrades with "keep settings" **disabled** wipe everything,
including the enrollment — that's a factory reset, reinstall and re-enroll.

## Uninstalling

```sh
opkg remove netbird          # prerm stops + disables the service
rm -rf /etc/netbird          # only if you also want to drop the enrollment
```

## Troubleshooting

**`opkg: incompatible with the architectures configured`**
The ipk's `Architecture` must appear in the router's arch list. Verify:
`grep arch /etc/opkg.conf` — it must contain
`aarch64_cortex-a53_neon-vfpv4`. This repo hardcodes that exact string; if
you changed `OPENWRT_ARCH`, change it back.

**`netbird up` fails / no tunnel interface**
Check the TUN device: `ls /dev/net/tun` and `opkg install kmod-tun` (it is
a declared dependency, but GL.iNet firmware repos must be reachable for
opkg to pull it — run `opkg update` first). Kernel WireGuard is optional;
netbird falls back to userspace automatically.

**Service logs**
```sh
logread -e netbird           # procd forwards stdout/stderr to syslog
/etc/init.d/netbird restart
netbird status -d            # detailed peer/connection state
```

**Not enough space**
The downloaded netbird binary needs ~14 MB of overlay (`df -h /overlay`) and
~36 MB of RAM in `/tmp` (`free`) when running. If `/tmp` fills up the wrapper
prints "failed to decompress"; free RAM or reboot.

## GL.iNet admin panel page (Applications → NetBird)

The package ships a settings page for the GL admin panel. After install,
refresh the panel (Ctrl/Cmd+Shift+R) and a **NetBird** entry appears in the
**Applications** menu group with:

- daemon status, start/stop and start-on-boot controls
- management connection state, NetBird IP, FQDN, peer list
- connect via **setup key** (headless) or **SSO** (a login URL is shown —
  open it in your browser to authorize the router)
- disconnect (`netbird down`)

How it works — **native OUI integration**, the same mechanism GL.iNet uses
for its own panels (no nginx filters, no DOM injection, no GL files
modified). The page is a real route in the GL SPA, so sidebar, topbar,
routing and theming are handled by the panel itself:

```
/usr/lib/oui-httpd/rpc/netbird                Lua RPC backend (GL OpenResty dispatcher)
/www/views/gl-sdk4-ui-netbird.common.js.gz    Vue 2 view loaded natively by the panel
/usr/share/oui/menu.d/netbird.json            sidebar menu entry (Applications group)
```

postinst patches the menu entry's `parent`/`parent_icon`/`parent_index`
from an existing Applications entry found on the device (Tailscale,
ZeroTier, DDNS…), so the item lands in the correct group on any GL 4.x
firmware, then restarts nginx so OpenResty workers pick up the new RPC
module. Format reference:
[gl-mt3000-starlink-panel](https://github.com/bigmalloy/gl-mt3000-starlink-panel).

The view talks to the backend via the panel's own `$rpcRequest` helper
(falling back to a raw `/rpc` call with the `Admin-Token` cookie on older
panels); inputs (setup key, management URL) are charset-validated before
reaching a shell. On plain (non-GL) OpenWrt these files are inert.

If the page doesn't appear: confirm the mechanism exists on your firmware
(`ls /usr/share/oui/menu.d /www/views | head`), check the menu entry was
patched (`cat /usr/share/oui/menu.d/netbird.json`), restart nginx
(`/etc/init.d/nginx restart`), then hard-refresh the browser. RPC errors
are visible in the browser dev tools network tab on calls to `/rpc`, and
in `logread` on the router.

## Maintainer & contributing

This is a community package, not affiliated with GL.iNet or NetBird.
Maintained by [Andrea (@AndreaF17)](https://github.com/AndreaF17).

- Found a bug or have a request?
  [Open an issue](https://github.com/AndreaF17/netbird-glinet-integration/issues)
  — please include your firmware version and `logread -e netbird` output.
- Pull requests are welcome. The panel UI also links here from its footer.

## CI

CI builds the **integration package only** — the GL.iNet panel, the
`/usr/sbin/netbird` wrapper, the init script and the self-updater. No netbird
binary is built or bundled; the router downloads netbird at install and the
panel keeps it current (see [Upgrading](#upgrading)). So you build only when the
panel changes, and there is no scheduled/automatic build.

It's **manual, no tags required**. The build steps live once in
`.github/workflows/_build.yml` (a reusable `workflow_call`), driven by
`.github/workflows/build.yml`:

- **Run workflow** (Actions tab → *build* → Run workflow) → enter an
  `integration_version` (e.g. `1.0`); with *publish* ticked (default) it builds
  `netbird_1.0_aarch64_cortex-a53_neon-vfpv4.ipk` and publishes GitHub release
  `v1.0` with the `.ipk` + `sha256sums.txt`. Untick *publish* for a test build
  (workflow artifact only).
- **Tag push** (`git tag v1.0 && git push origin v1.0`) → same, as a
  convenience, with the tag as the version.

Or build locally with `./build.sh` and attach the `.ipk` from `./out/` to a
release yourself.

## Repo layout

```
Makefile                     # make ipk | clean
build.sh                     # one-shot: docker build + package -> ./out/
docker/Dockerfile            # build environment (debian:bookworm-slim, GNU tar)
scripts/mkipk.sh             # legacy-format ipk assembly (runs in container)
files/netbird.init           # procd init script -> /etc/init.d/netbird
files/netbird-wrapper.in     # /usr/sbin/netbird wrapper (extracts netbird.gz)
files/netbird-self-update.sh # downloads netbird binary direct from upstream (install + panel)
files/netbird.keep           # sysupgrade keep list -> /lib/upgrade/keep.d/netbird
files/postinst, files/prerm, files/postrm  # opkg maintainer scripts (postinst fetches netbird)
files/ui/rpc/netbird         # GL admin panel: Lua RPC backend
files/ui/menu/netbird.json   # GL admin panel: sidebar menu entry (oui menu.d)
files/ui/www/gl-sdk4-ui-netbird.common.js  # GL admin panel: native OUI Vue 2 view
.github/workflows/_build.yml # CI: reusable build+publish (workflow_call)
.github/workflows/build.yml  # CI: manual "Run workflow" entry point (panel package)
```
