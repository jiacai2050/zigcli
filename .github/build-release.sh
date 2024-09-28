#!/usr/bin/env bash

out_dir="/tmp/zigcli-release/"
version=${RELEASE_VERSION:-unknown}

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT
cleanup() {
 trap - SIGINT SIGTERM ERR EXIT
 ls -ltrh "${out_dir}"
 rm -rf "${out_dir}/*"
}

mkdir -p "${out_dir}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

cd "${script_dir}/.."

targets=(
  "aarch64-linux"
  "x86_64-linux"
  "x86-linux"
  "aarch64-macos"
  "x86_64-macos"
  "x86_64-windows"
)

export BUILD_DATE=$(date +'%Y-%m-%dT%H:%M:%S%z')
export GIT_COMMIT=$(git rev-parse --short HEAD)

for target in "${targets[@]}"; do
  echo "Building for ${target}..."
  zig build -Doptimize=ReleaseSafe -Dtarget="${target}" \
      -Dgit_commit=${GIT_COMMIT} -Dbuild_date=${BUILD_DATE} -Dis_ci=true
  pushd zig-out
  zip -r zigcli-${version}-${target}.zip bin ../LICENSE ../README.org
  popd
done
