#!/usr/bin/env bash
# Build the guardian-core static library (Release) into build/corecpp. Run as a Tuist pre-build script.
set -euo pipefail
cd "${SRCROOT:-$(dirname "$0")/..}"

# Xcode runs build phases with a minimal PATH; cmake and ninja come from Homebrew or mise.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/share/mise/shims:$PATH"

src=external/guardian-core
out=build/corecpp
if [[ ! -f "$src/CMakeLists.txt" ]]; then
  echo "error: $src is empty; run: git submodule update --init" >&2
  exit 1
fi

mkdir -p "$out"
cmake --preset macos -S "$src" -B "$out" -DGUARDIAN_BUILD_TESTS=OFF \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 >"$out.configure.log" 2>&1 \
  || { tail -n 40 "$out.configure.log"; exit 1; }
cmake --build "$out" --target guardian_core >"$out.build.log" 2>&1 || { tail -n 40 "$out.build.log"; exit 1; }
test -f "$out/libguardian_core.a"
