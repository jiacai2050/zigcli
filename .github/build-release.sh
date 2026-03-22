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

  if command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN
    return
  fi

  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
    return
  fi

  printf '4\n'
}

build_target() {
  local target=$1
  local filename
  local dst_dir
  local log_file
  filename=zigcli-${VERSION}-${target}
  dst_dir=zig-out/${filename}
  log_file=${OUT_DIR}/${filename}.log

  echo "Building for ${target}..."

  # 1. Build
  # The '-Dcpu=baseline' flag ensures compatibility with a baseline CPU architecture,
  # which is necessary for certain build targets. For more details, see:
  # https://github.com/jiacai2050/zigcli/issues/43
  zig build -Doptimize=ReleaseSafe -Dtarget="${target}" -p "${dst_dir}" \
      -Dcpu=baseline -Dgit_commit="${GIT_COMMIT}" -Dbuild_date="${BUILD_DATE}" \
      >"${log_file}" 2>&1

  # 2. Prepare files
  rm -f "${dst_dir}"/bin/*demo
  cp LICENSE README.org "${dst_dir}"

  # 3. Zip final file
  pushd zig-out >/dev/null
  zip -r "${OUT_DIR}/${filename}.zip" "${filename}" >>"${log_file}" 2>&1
  popd >/dev/null
}

max_jobs=$(detect_max_jobs)
echo "Max jobs is ${max_jobs}."

declare -A pid_to_target=()
declare -a failed_targets=()

for target in "${targets[@]}"; do
  build_target "${target}" &
  pid_to_target[$!]="${target}"

  while (( $(jobs -pr | wc -l) >= max_jobs )); do
    pid=$(jobs -pr | head -n 1)
    if [[ -z "${pid}" ]]; then
      break
    fi
    if ! wait "${pid}"; then
      failed_targets+=("${pid_to_target[${pid}]}")
    fi
    unset 'pid_to_target[$pid]'
  done
done

for pid in "${!pid_to_target[@]}"; do
  if ! wait "${pid}"; then
    failed_targets+=("${pid_to_target[${pid}]}")
  fi
done

if (( ${#failed_targets[@]} > 0 )); then
  for target in "${failed_targets[@]}"; do
    filename=zigcli-${VERSION}-${target}
    echo "Build failed for ${target}. Showing ${OUT_DIR}/${filename}.log:"
    cat "${OUT_DIR}/${filename}.log"
  done
  exit 1
fi
