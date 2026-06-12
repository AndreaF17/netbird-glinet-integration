# NetBird .ipk for GL.iNet GL-X2000

Builds the [NetBird](https://github.com/netbirdio/netbird) VPN client from
source and packages it as an installable `.ipk` for the **GL.iNet GL-X2000**
(firmware 4.7.x, QSDK-based OpenWrt 19.07 fork, `ipq50xx`, kernel 5.4, musl).

Maintained by @me
— bug reports and feature requests are welcome on the
[issue tracker](https://github.com/AndreaF17/netbird-glinet-integration/issues).

## Why not the OpenWrt SDK?

Upstream OpenWrt 19.07 has no `ipq50xx` target — it only exists in GL.iNet's
QSDK, which is not publicly buildable. Instead, the NetBird client is
cross-compiled as a **fully static Go binary** (`CGO_ENABLED=0 GOOS=linux
GOARCH=arm64`). A static Go binary has zero libc dependency, so the router's
old musl userland and QSDK quirks are irrelevant. The `.ipk` is assembled
with plain GNU tar in the legacy format opkg 19.07 expects
(`debian-binary` + `control.tar.gz` + `data.tar.gz`).

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
- **Router flash:** ~14 MB free overlay. The GL-X2000 has 128 MB flash with
  only ~24 MB free, which cannot hold the ~36 MB static binary — so by
  default the package ships the binary gzip-compressed (~13 MB on flash)
  and a small `/usr/sbin/netbird` wrapper extracts it to RAM-backed `/tmp`
  on first use after each boot. Check free space with `df -h /overlay`.
- **Router RAM:** ~36 MB of `/tmp` (tmpfs) for the extracted binary while
  netbird is installed, plus netbird's own working memory. Check `free`.
- Build with `COMPRESS_BINARY=0` to get the classic layout (plain binary at
  `/usr/sbin/netbird`, ~36 MB on flash, no RAM overhead) for devices with
  more flash. UPX is deliberately not used — it's unreliable on arm64,
  slows startup, and ends up in RAM anyway, so the gzip-to-tmpfs scheme
  strictly dominates it.

## Building (macOS or Linux)

```sh
./build.sh                          # latest netbird release
NETBIRD_VERSION=0.72.3 ./build.sh   # pinned version
# or via make:
make ipk
make ipk NETBIRD_VERSION=0.72.3
```

Output: `./out/netbird_<version>-<release>_aarch64_cortex-a53_neon-vfpv4.ipk`

For packaging-only changes (init script, panel UI, scripts) bump the
release: `make ipk PKG_RELEASE=2`. opkg upgrades `0.72.3-2` over `0.72.3-1`
but **skips** installing the same version again ("up to date"), so without
a bump a rebuilt same-version ipk never lands on the router.

Other targets: `make build` (binary only), `make package` (re-package an
existing binary), `make clean`. Go module/build caches persist in Docker
named volumes, so rebuilds are fast.

## Installing on the router

```sh
# from your computer
scp ./out/netbird_*_aarch64_cortex-a53_neon-vfpv4.ipk root@192.168.8.1:/tmp/

# on the router (ssh root@192.168.8.1)
opkg update || true
opkg install /tmp/netbird_*.ipk
```

The package installs `/usr/sbin/netbird` (a wrapper that extracts the
gzipped binary from `/usr/libexec/netbird/netbird.gz` to `/tmp` on first
use) and a procd init script at `/etc/init.d/netbird` (config in
`/etc/netbird`, runtime state in `/var/lib/netbird` — volatile by design to
spare flash; the device identity lives in the persistent config).
`postinst` enables and starts the service automatically. The first
`netbird` invocation after each boot takes a few extra seconds while the
binary is decompressed.

Then enroll the device:

```sh
netbird up --setup-key <YOUR-SETUP-KEY>
# or interactively / SSO:
netbird up
netbird status
```

## Upgrading

On the GL-X2000, **remove the old version first**:

```sh
scp ./out/netbird_<newver>_*.ipk root@192.168.8.1:/tmp/
ssh root@192.168.8.1 "opkg remove netbird && opkg install /tmp/netbird_<newver>_*.ipk"
```

A direct `opkg install` of the new ipk fails with *"Only have NNNNkb
available on filesystem /overlay"*: opkg demands the new package's full
~13 MB while the old copy still occupies its ~13 MB, and it does not credit
the space freed by replacing it — two copies never fit in the ~24 MB
overlay. Removing first sidesteps this. (`--force-space` skips the check
but risks a half-written install if space truly runs out.)

`/etc/netbird/config.json` is generated at runtime and never shipped in the
package, so opkg leaves it alone on remove/upgrade — your enrollment
survives and the daemon reconnects automatically after install. (It is
deliberately not listed as a conffile: opkg errors trying to checksum a
conffile that isn't installed yet.)

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
- `/usr/sbin/netbird` (wrapper) and `/usr/libexec/netbird/netbird.gz`
  (gzipped binary; with `COMPRESS_BINARY=0` builds the plain binary is
  `/usr/sbin/netbird` and the missing `.gz` path is skipped)
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
The default package needs ~14 MB of overlay (`df -h /overlay`) and ~36 MB
of RAM in `/tmp` (`free`). If `/tmp` fills up the wrapper prints
"failed to decompress"; free RAM or reboot. With `COMPRESS_BINARY=0`
builds you need ~37 MB of overlay instead.

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

`.github/workflows/build.yml` — release-driven, no scheduled builds. The
repo tag versions the *integration*; the upstream netbird version is
resolved to the latest release at build time. Tag `v0.1` + upstream
`0.72.3` ⇒ asset `netbird_0.72.3-0.1_aarch64_cortex-a53_neon-vfpv4.ipk`
(the tag, minus the `v`, becomes the opkg package-release suffix).

- **Tag push** (`git tag v0.1 && git push origin v0.1`) → builds the
  latest upstream netbird, creates GitHub release `v0.1`, attaches the
  `.ipk` + `sha256sums.txt`.
- **Release published from the GitHub UI** → same result; the workflow
  detects the release's tag and uploads the assets to it. (Both triggers
  can fire for one tag — runs are serialized per tag and idempotent.)
- **Manual run** (`workflow_dispatch`) → test builds only: optional
  `netbird_version` and `pkg_release` inputs, produces a workflow
  artifact, publishes nothing.

## Repo layout

```
Makefile                     # make build | ipk | package | clean
build.sh                     # one-shot: docker build + compile + package -> ./out/
docker/Dockerfile            # build environment (golang:1.25-bookworm)
scripts/compile.sh           # static Go cross-compile (runs in container)
scripts/mkipk.sh             # legacy-format ipk assembly (runs in container)
files/netbird.init           # procd init script -> /etc/init.d/netbird
files/netbird-wrapper.in     # /usr/sbin/netbird wrapper (compressed layout)
files/netbird.keep           # sysupgrade keep list -> /lib/upgrade/keep.d/netbird
files/postinst, files/prerm, files/postrm  # opkg maintainer scripts
files/ui/rpc/netbird         # GL admin panel: Lua RPC backend
files/ui/menu/netbird.json   # GL admin panel: sidebar menu entry (oui menu.d)
files/ui/www/gl-sdk4-ui-netbird.common.js  # GL admin panel: native OUI Vue 2 view
.github/workflows/build.yml  # CI: tag / manual / scheduled builds + releases
```
