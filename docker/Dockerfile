# Build environment for the NetBird GL-X2000 .ipk.
# golang:1.25-bookworm ships git, ca-certificates and GNU tar, which is all
# the compile and packaging scripts need. The image works on both arm64
# (macOS Docker Desktop) and amd64 (GitHub Actions) hosts, and the Go
# cross-compile to linux/arm64 is host-independent, so artifacts are
# identical either way.
FROM golang:1.25-bookworm

# Fail fast at image build time if tar is not GNU tar (mkipk.sh relies on
# --sort/--owner/--mtime for reproducible archives).
RUN tar --version | grep -q "GNU tar"

WORKDIR /work
