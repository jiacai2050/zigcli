#!/usr/bin/env bash

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
  local log_file
  local failure_file
  cpu=$(zig_cpu "${target}")
  filename=zigcli-${VERSION}-${target}
  dst_dir=zig-out/${filename}
  log_file=${OUT_DIR}/${filename}.log
  failure_file=${OUT_DIR}/${filename}.failed

  rm -f "${failure_file}"
  echo "Building for ${target}..."

  if ! (
    zig build -Doptimize=ReleaseSafe -Dtarget="${target}" -p "${dst_dir}" \
        -Dcpu="${cpu}" -Dversion="${VERSION}" -Dgit_commit="${GIT_COMMIT}" -Dbuild_date="${BUILD_DATE}"

    rm -f "${dst_dir}"/bin/*demo
    cp LICENSE README.org "${dst_dir}"

    pushd zig-out >/dev/null
    zip -r "${OUT_DIR}/${filename}.zip" "${filename}"
    popd >/dev/null
  ) >"${log_file}" 2>&1; then
    : > "${failure_file}"
    return 1
  fi
}

build_target "$TARGET"
