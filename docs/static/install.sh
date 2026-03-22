#!/bin/sh
# Install zigcli binaries to ~/.local/bin, or another chosen directory.
# Usage:
#   curl -fsSL https://zigcli.liujiacai.net/install.sh | sh
#   curl -fsSL ... | sh -s -- --install-dir /usr/local/bin
#   curl -fsSL ... | sh -s -- --bins "loc zfetch tree cowsay"
#   curl -fsSL ... | sh -s -- --bins all

set -eu

VERSION="${VERSION:-latest}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BINS="${BINS:-all}"
CHINA=0
REPO="jiacai2050/zigcli"
BASE_URL="https://github.com/${REPO}/releases/download"

# Parse command-line arguments.
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

resolve_bins() {
    src_dir=$1

    if [ "$BINS" = "all" ]; then
        find "$src_dir" -type f -exec basename {} \; | sort
        return
    fi

    printf '%s\n' "$BINS"
}

fetch_latest_version() {
    latest_version=$(curl -sL "https://api.github.com/repos/${REPO}/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
    if [ -z "$latest_version" ]; then
        echo "Failed to fetch latest version"
        exit 1
    fi

    printf '%s\n' "$latest_version"
}

find_source_bin_dir() {
    extracted_dir=$1
    src_dir=$(find "$extracted_dir" -type d -name bin | head -1)
    if [ -z "$src_dir" ]; then
        echo "Error: bin directory not found in archive"
        exit 1
    fi

    printf '%s\n' "$src_dir"
}

main() {
    detect_platform

    if [ "$VERSION" = "latest" ]; then
        VERSION=$(fetch_latest_version)
        echo "Latest version: ${VERSION}"
    fi

    filename="zigcli-${VERSION}-${ARCH}-${OS}.zip"
    url="${BASE_URL}/${VERSION}/${filename}"
    if [ "$CHINA" = 1 ]; then
        url="https://api.liujiacai.net/proxy/${url}"
    fi
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT

    echo "Downloading ${url}..."
    curl -fSL -o "${tmp_dir}/${filename}" "$url"

    echo "Extracting..."
    unzip -q "${tmp_dir}/${filename}" -d "${tmp_dir}/zigcli"

    # The archive may or may not contain a top-level directory.
    src_dir=$(find_source_bin_dir "${tmp_dir}/zigcli")

    mkdir -p "$INSTALL_DIR"
    resolved_bins=$(resolve_bins "$src_dir")
    if [ -z "$resolved_bins" ]; then
        echo "Error: no binaries selected for installation"
        exit 1
    fi
    echo ""
    echo "Installed to ${INSTALL_DIR}:"
    for bin in $resolved_bins; do
        if [ -f "${src_dir}/${bin}" ]; then
            cp "${src_dir}/${bin}" "$INSTALL_DIR/"
            chmod +x "$INSTALL_DIR/${bin}"
            echo "  ${bin}"
        else
            echo "  ${bin} (not found, skipping)"
        fi
    done
    echo ""

    # Check whether the install directory is already in PATH.
    case ":$PATH:" in
        *":${INSTALL_DIR}:"*) ;;
        *) echo "NOTE: Add ${INSTALL_DIR} to your PATH:"
           echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
           echo "" ;;
    esac

    echo "Done!"
}

main
