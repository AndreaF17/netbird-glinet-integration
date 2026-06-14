# Build environment for the NetBird GL-X2000 integration .ipk.
#
# The build only assembles the package (panel + wrapper + init + self-updater) —
# no netbird binary is fetched or compiled here (the router downloads netbird at
# install time). So all this needs is GNU tar + gzip for reproducible archives,
# both already in debian:bookworm-slim. The image is host-independent (arm64 or
# amd64), so artifacts are identical on macOS Docker Desktop or GitHub Actions.
FROM debian:bookworm-slim

# Fail fast if tar is not GNU tar (mkipk.sh relies on --sort/--owner/--mtime).
RUN tar --version | grep -q "GNU tar"

WORKDIR /work
