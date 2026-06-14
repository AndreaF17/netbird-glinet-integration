# NetBird GL.iNet GL-X2000 integration .ipk builder.
#
#   make ipk                          # build ./out/netbird_<version>_<arch>.ipk
#   make ipk INTEGRATION_VERSION=1.1  # set the panel version
#   make clean                        # remove ./out
#
# The package contains the GL panel + wrapper + self-updater only; the netbird
# binary is downloaded on the router at install time, so there is no netbird
# version to pin here.

INTEGRATION_VERSION ?= 1.0
OPENWRT_ARCH        ?= aarch64_cortex-a53_neon-vfpv4

export INTEGRATION_VERSION OPENWRT_ARCH

.PHONY: ipk clean

ipk:
	./build.sh

clean:
	rm -rf out
