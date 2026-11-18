#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/build/metal-library-overrides"
name=SimRunMetalLibraryOverrides.dylib
if [ "${1:-}" = "--output-name" ] && [ "$#" -eq 2 ]; then name="$2"; shift 2; fi
if [ "$#" -ne 0 ] || [[ ! "$name" =~ ^[A-Za-z0-9_-]+\.dylib$ ]]; then
  echo "Usage: $0 [--output-name Name.dylib]" >&2; exit 2
fi
mkdir -p "$out"
xcrun --sdk iphonesimulator clang -arch arm64 -target arm64-apple-ios17.0-simulator \
  -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-deprecated-declarations -dynamiclib \
  "$repo/extras/metal-library-overrides/overrides.m" -framework Foundation -framework Metal \
  -install_name "@rpath/$name" \
  -o "$out/$name"
cp "$repo/extras/metal-library-overrides/LICENSE" "$out/LICENSE"
codesign --force --sign - "$out/$name"
codesign --verify --strict "$out/$name"
