#!/usr/bin/env bash

set -e
OUT_DIR=${OUT_DIR:-/tmp/zigcli}
VERSION=${RELEASE_VERSION:-unknown}
MAX_JOBS=${MAX_JOBS:-}
BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%S%z')
GIT_COMMIT=$(git rev-parse --short HEAD)

if [ x"$TARGET" = x ];then
   echo "No target set, exit..."
   exit 1
fi

echo "Building zigcli ${VERSION} to ${OUT_DIR}..."
mkdir -p "${OUT_DIR}" || true

# https://github.com/oven-sh/bun/blob/db2156e46204e43497c9dc4c49744beed91421b2/scripts/build/zig.ts#L83-L98
zig_cpu() {
  local target=$1

  case "${target}" in
    aarch64-macos)
      printf 'apple_m1\n'
      ;;
    aarch64-windows)
      printf 'cortex_a76\n'
      ;;
    aarch64-*)
      printf 'generic\n'
      ;;
    x86_64-*)
      printf 'haswell\n'
      ;;
    *)
      echo "Unsupported target for CPU selection: ${target}" >&2
      return 1
      ;;
  esac
}

build_target() {
  local target=$1
  local cpu
  local filename
  local dst_dir
  cpu=$(zig_cpu "${target}")
  filename=zigcli-${VERSION}-${target}
  dst_dir=zig-out/${filename}

  echo "Building for ${target}..."

  zig build -Doptimize=ReleaseSafe -Dtarget="${target}" -p "${dst_dir}" \
        -Dcpu="${cpu}" -Dversion="${VERSION}" -Dgit_commit="${GIT_COMMIT}" -Dbuild_date="${BUILD_DATE}"

  rm -f "${dst_dir}"/bin/*demo
  cp LICENSE README.org "${dst_dir}"

  find zig-out

  pushd zig-out
  zip -r "${OUT_DIR}/${filename}.zip" "${filename}"
  popd
}

build_target "$TARGET"
