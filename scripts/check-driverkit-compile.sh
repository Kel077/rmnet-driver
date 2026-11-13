#!/bin/sh
# Syntax-checks every Core source file against the installed DriverKit SDK.
set -u

cd "$(dirname "$0")/.." || exit 1

sdk_path=$(xcrun --sdk driverkit --show-sdk-path) || { echo "driverkit check: SDK not found" >&2; exit 1; }
sdk_version=$(xcrun --sdk driverkit --show-sdk-version) || { echo "driverkit check: SDK version unknown" >&2; exit 1; }

ok=0
failed=0
for src in core/src/*.cpp; do
  [ -e "$src" ] || continue
  if xcrun --sdk driverkit clang++ \
      -target "arm64-apple-driverkit${sdk_version}" -isysroot "$sdk_path" \
      -std=c++17 -Wall -Wextra -Werror -fno-exceptions -fno-rtti \
      -Icore/include -fsyntax-only "$src"; then
    ok=$((ok + 1))
  else
    echo "driverkit check: $src failed" >&2
    failed=$((failed + 1))
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "driverkit check: $failed files failed, $ok files ok"
  exit 1
fi
echo "driverkit check: $ok files ok"
