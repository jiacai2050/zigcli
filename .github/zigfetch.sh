#!/usr/bin/env bash

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

pkg=https://github.com/jiacai2050/zig-curl/archive/c8e2f43f8f042f52373c86043ec16b0f2c3388a2.tar.gz

zig fetch --debug-hash  "${pkg}"

actual=$("${script_dir}/../zig-out/bin/zigfetch" "${pkg}" 2>&1 | tail -1)
expected="1220e9b279355ce92cd217684a2449bd8024274eb3fc09a576deb33ca1733b9f0a1f"
if [ "${actual}" != "${expected}" ];then
  echo "Expected: ${expected}, actual:${actual}"
  exit 1
fi
