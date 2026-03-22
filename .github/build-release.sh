#!/usr/bin/env bash

OUT_DIR=${OUT_DIR:-/tmp/zigcli}
VERSION=${RELEASE_VERSION:-unknown}
MAX_JOBS=${MAX_JOBS:-}

echo "Building zigcli ${VERSION} to ${OUT_DIR}..."

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
cleanup() {
 trap - SIGINT SIGTERM ERR EXIT
  ls -ltrh "${OUT_DIR}"
}

mkdir -p "${OUT_DIR}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

cd "${script_dir}/.."

targets=(
  "aarch64-linux"
  "x86_64-linux"
  # This target is built on CI directly.
  # "aarch64-macos"
  "x86_64-macos"
  "x86_64-windows"
  "aarch64-windows"
  "x86_64-freebsd"
  "aarch64-freebsd"
)

export BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%S%z')
export GIT_COMMIT=$(git rev-parse --short HEAD)

detect_max_jobs() {
  if [[ -n "${MAX_JOBS}" ]]; then
    printf '%s\n' "${MAX_JOBS}"
    return
  fi
  printf '%s\n' "${#targets[@]}"
}

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

max_jobs=$(detect_max_jobs)
echo "Max jobs is ${max_jobs}."

export OUT_DIR VERSION BUILD_DATE GIT_COMMIT
export -f zig_cpu build_target

if ! printf '%s\n' "${targets[@]}" | xargs -P "${max_jobs}" -n 1 bash -c 'build_target "$1"' _; then
  for target in "${targets[@]}"; do
    filename=zigcli-${VERSION}-${target}
    if [[ -f "${OUT_DIR}/${filename}.failed" ]]; then
      echo "Build failed for ${target}. Showing ${OUT_DIR}/${filename}.log:"
      cat "${OUT_DIR}/${filename}.log"
    fi
  done
  exit 1
fi
