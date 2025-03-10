#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

check_hash() {
  local pkg="$1"
  local expected="$2"

  # zig fetch --debug-hash "${pkg}"
  # "${script_dir}/../zig-out/bin/zigfetch" "${pkg}"
  local actual=$("${script_dir}/../zig-out/bin/zigfetch" "${pkg}" 2>&1 | tail -1)

  if [ "${actual}" != "${expected}" ]; then
    echo "Wrong case: ${pkg}.\nExpected: ${expected}, actual: ${actual}"
    return 1
  fi

  return 0
}

# For zig 0.13.0
check_hash "https://github.com/jiacai2050/zig-curl/archive/c8e2f43f8f042f52373c86043ec16b0f2c3388a2.tar.gz" 1220e9b279355ce92cd217684a2449bd8024274eb3fc09a576deb33ca1733b9f0a1f

# For zig 0.14.0
check_hash "https://github.com/jiacai2050/zig-curl/archive/refs/tags/v0.1.0.tar.gz" 122057495ccd5029387615e6786a56626a88cd39614b4ebeb0bf559989c16fe47a3f
