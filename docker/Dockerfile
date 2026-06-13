# Build environment for the NetBird GL-X2000 .ipk.
#
# We no longer compile netbird from source — compile.sh downloads the official
# prebuilt static linux/arm64 binary — so the heavy Go toolchain is gone. All
# the scripts need now is curl (download), ca-certificates (HTTPS) and GNU tar
# (reproducible .ipk packaging). debian:bookworm-slim provides GNU tar + gzip +
# sha256sum; we add curl and CA certs. The image is host-independent (arm64 or
# amd64), so artifacts are identical on macOS Docker Desktop or GitHub Actions.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    # Fail fast if tar is not GNU tar (mkipk.sh relies on --sort/--owner/--mtime).
    && tar --version | grep -q "GNU tar"

WORKDIR /work
