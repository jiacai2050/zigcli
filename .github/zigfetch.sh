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

check_hash "https://github.com/karlseguin/websocket.zig/archive/7c3f1149bffcde1dec98dea88a442e2b580d750a.tar.gz" \
           "websocket-0.1.0-ZPISdXNIAwCXG7oHBj4zc1CfmZcDeyR6hfTEOo8_YI4r"

check_hash "https://github.com/jiacai2050/zig-curl/archive/refs/tags/v0.1.1.tar.gz" \
           "curl-0.1.1-P4tT4WzAAAD0MGbSfsyGV1hPdooNwZ5odcQYUB9iYlHe"
