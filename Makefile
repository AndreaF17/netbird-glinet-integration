# NetBird .ipk builder for the GL.iNet GL-X2000.
#
#   make ipk                          # compile + package (default)
#   make build                        # compile the static binary only
#   make clean                        # remove ./out
#   make ipk NETBIRD_VERSION=0.72.3   # pin a netbird version
#
# NETBIRD_VERSION defaults to the latest GitHub release (resolved in build.sh).

NETBIRD_VERSION ?=
OPENWRT_ARCH    ?= aarch64_cortex-a53_neon-vfpv4
COMPRESS_BINARY ?= 1
PKG_RELEASE     ?= 1

export NETBIRD_VERSION OPENWRT_ARCH COMPRESS_BINARY PKG_RELEASE

.PHONY: ipk build package clean

ipk:
	./build.sh all

build:
	./build.sh binary

package:
	./build.sh package

clean:
	rm -rf out
