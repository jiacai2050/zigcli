#!/usr/bin/env bash

OUT_DIR=${OUT_DIR:-/tmp/zigcli}
VERSION=${RELEASE_VERSION:-unknown}

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
  "x86-linux"
  # This target is built on CI directly.
  # "aarch64-macos"
  "x86_64-macos"
  "x86_64-windows"
)

export BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%S%z')
export GIT_COMMIT=$(git rev-parse --short HEAD)

for target in "${targets[@]}"; do
  echo "Building for ${target}..."
  filename=zigcli-${VERSION}-${target}
  dst_dir=zig-out/${filename}

  # 1. Build
  if [[ "${target}" = "x86_64-linux" ]];then
    zig build -Doptimize=ReleaseSafe -p ${dst_dir} \
        -Dgit_commit=${GIT_COMMIT} -Dbuild_date=${BUILD_DATE}
  else
    zig build -Dskip-zigfetch=true -Doptimize=ReleaseSafe -Dtarget="${target}" -p ${dst_dir} \
        -Dgit_commit=${GIT_COMMIT} -Dbuild_date=${BUILD_DATE}
  fi

  # 2. Prepare files
  rm -f ${dst_dir}/bin/*demo
  cp LICENSE README.org ${dst_dir}

  find zig-out

  # 3. Zip final file
  pushd zig-out
  zip -r ${OUT_DIR}/${filename}.zip "${filename}"
  popd
done
