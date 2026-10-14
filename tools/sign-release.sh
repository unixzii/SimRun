#!/bin/bash
# Sign an assembled bundle, without changing local development's ad-hoc signing.
set -euo pipefail

APP=${1:?Usage: sign-release.sh path/to/SimRun.app}
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIGN=(/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime)
if [[ -n ${SIGNING_KEYCHAIN:-} ]]; then
    SIGN+=(--keychain "$SIGNING_KEYCHAIN")
fi

# Explicitly sign the Simulator payload too: --deep signing is not a substitute
# for enumerating code in Contents/Resources, or for per-executable entitlements.
for lib in lib lib/watchos; do
    for file in xpcservices.dylib app.dylib SimFramebuffer simpair wcd.dylib; do
        "${SIGN[@]}" "$APP/Contents/Resources/$lib/$file"
    done
    "${SIGN[@]}" --entitlements "$ROOT/resources/release-simns.entitlements" "$APP/Contents/Resources/$lib/simns"
done
"${SIGN[@]}" "$APP/Contents/Helpers/simrun"
"${SIGN[@]}" --entitlements "$ROOT/resources/release-host.entitlements" "$APP"

# Verify every Mach-O, including code outside standard nested-code locations.
# Fail on newly added payloads that were not signed above.
while IFS= read -r -d '' file; do
    if /usr/bin/file -b "$file" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --verify --strict --verbose=2 "$file"
        details=$(/usr/bin/codesign -dvv "$file" 2>&1)
        if ! /usr/bin/grep -q 'Authority=Developer ID Application:' <<< "$details" ||
           ! /usr/bin/grep -q 'flags=.*runtime' <<< "$details" ||
           ! /usr/bin/grep -q '^Timestamp=' <<< "$details"; then
            echo "Missing Developer ID, hardened runtime, or secure timestamp: $file" >&2
            exit 1
        fi
    fi
done < <(find "$APP" -type f -print0)
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
