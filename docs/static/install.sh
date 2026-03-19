#!/bin/sh
# Install zigcli binaries to ~/.local/bin (or custom dir).
# Usage:
#   curl -fsSL https://zigcli.liujiacai.net/install.sh | sh
#   curl -fsSL ... | sh -s -- --install-dir /usr/local/bin
#   curl -fsSL ... | sh -s -- --bins "loc zfetch tree cowsay"

set -eu

VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BINS="${BINS:-loc zfetch timeout repeat tree cowsay}"
CHINA=0
REPO="jiacai2050/zigcli"
BASE_URL="https://github.com/${REPO}/releases/download"

# Parse arguments.
while [ $# -gt 0 ]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --version)     VERSION="$2"; shift 2 ;;
        --bins)        BINS="$2"; shift 2 ;;
        --china)       CHINA=1; shift ;;
        *)             echo "Unknown option: $1"; exit 1 ;;
    esac
done

detect_platform() {
    OS="$(uname -s)"
    ARCH="$(uname -m)"

    case "$OS" in
        Linux*)  OS="linux" ;;
        Darwin*) OS="macos" ;;
        FreeBSD) OS="freebsd" ;;
        *)       echo "Unsupported OS: $OS"; exit 1 ;;
    esac

    case "$ARCH" in
        x86_64|amd64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="aarch64" ;;
        *)             echo "Unsupported arch: $ARCH"; exit 1 ;;
    esac
}

main() {
    detect_platform

    if [ "$VERSION" = "latest" ]; then
        VERSION=$(curl -sL https://api.github.com/repos/${REPO}/releases/latest \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
        if [ -z "$VERSION" ]; then
            echo "Failed to fetch latest version"; exit 1
        fi
        echo "Latest version: ${VERSION}"
    fi

    FILENAME="zigcli-${VERSION}-${ARCH}-${OS}.zip"
    URL="${BASE_URL}/${VERSION}/${FILENAME}"
    if [ "$CHINA" = 1 ]; then
        URL="https://api.liujiacai.net/proxy/${URL}"
    fi
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    echo "Downloading ${URL}..."
    curl -fSL -o "${TMPDIR}/${FILENAME}" "$URL"

    echo "Extracting..."
    unzip -q "${TMPDIR}/${FILENAME}" -d "${TMPDIR}/zigcli"

    # Find bin dir (zip may or may not have a top-level directory).
    SRCDIR=$(find "${TMPDIR}/zigcli" -type d -name bin | head -1)
    if [ -z "$SRCDIR" ]; then
        echo "Error: bin directory not found in archive"; exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    echo ""
    echo "Installed to ${INSTALL_DIR}:"
    for bin in $BINS; do
        if [ -f "${SRCDIR}/${bin}" ]; then
            cp "${SRCDIR}/${bin}" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/${bin}"
            echo "  ${bin}"
        else
            echo "  ${bin} (not found, skipping)"
        fi
    done
    echo ""

    # Check if install dir is in PATH.
    case ":$PATH:" in
        *":${INSTALL_DIR}:"*) ;;
        *) echo "NOTE: Add ${INSTALL_DIR} to your PATH:"
           echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
           echo "" ;;
    esac

    echo "Done!"
}

main
