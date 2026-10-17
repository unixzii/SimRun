#!/bin/sh
# fetch-webrtc.sh <version> <zip> <sha256> <framework>: Google's WebRTC for macOS, prebuilt by github.com/stasel/WebRTC
# (from the official source, unmodified): downloads the release's <zip> into dl/ next to <framework> (unless it is
# there already), checks it against <sha256>, and puts its macOS framework, thinned to arm64, at <framework>.
set -e
version=$1 zip=$2 sha256=$3 framework=$4
dl=$(dirname "$framework")/dl
mkdir -p "$dl"
test -f "$dl/$zip" || curl -fL --retry 3 -o "$dl/$zip" "https://github.com/stasel/WebRTC/releases/download/$version/$zip"
echo "$sha256  $dl/$zip" | shasum -a 256 -c - >/dev/null || { echo "$zip: checksum mismatch" >&2; rm -f "$dl/$zip"; exit 1; }
rm -rf "$dl/WebRTC.xcframework" "$framework"
unzip -q "$dl/$zip" -d "$dl"
ditto --arch arm64 "$dl/WebRTC.xcframework/macos-x86_64_arm64/WebRTC.framework" "$framework"
rm -rf "$dl/WebRTC.xcframework"
echo "fetched WebRTC $version into $framework"
