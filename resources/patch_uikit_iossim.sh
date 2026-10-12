#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

DEVICE="booted"
INSTALL_APP=1
LAUNCH_APP=1
CONSOLE_PTY=0
SKIP_VERIFY=0
IN_PLACE=0
OUT_PATH=""
# overridable via environment (workers inherit these through xargs)
MIN_OS="${MIN_OS:-16.0}"
SDK_VERSION="${SDK_VERSION:-16.0}"
SOURCE=""

usage() {
    cat <<'EOF'
Usage:
  patch_uikit_iossim.sh [options] <app-or-ipa>

Options:
  --device <id|booted>   Simulator target. Default: booted
  --output <path>        Output .app path.
                         Default: <source-dir>/iossim-work/<name>.app
  --in-place             Patch the given .app directly.
                         Refused for Xcode DerivedData / Build/Products apps.
  --min-os <version>     LC_BUILD_VERSION min OS. Default: 16.0
  --sdk <version>        LC_BUILD_VERSION / Info.plist SDK. Default: 16.0
  --no-install           Patch and sign only
  --no-launch            Install and grant permissions, skip launch
  --console-pty          Launch with simctl --console-pty (blocks, prints stdout/stderr)
  --skip-verify          Skip the codesign verify passes (faster)
  -h, --help             Show this help

Examples:
  patch_uikit_iossim.sh MyApp.app
  patch_uikit_iossim.sh --device booted --output /tmp/MyApp-iossim.app MyApp.ipa
  patch_uikit_iossim.sh --device booted --sdk 27.0 ~/Library/Developer/Xcode/DerivedData/App-xxx/Build/Products/Debug-iphoneos/App.app
EOF
}

log() {
    printf '[*] %s\n' "$*"
}

warn() {
    printf '[!] %s\n' "$*" >&2
}

die() {
    printf '[E] %s\n' "$*" >&2
    exit 1
}

require_tool() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)
                DEVICE="${2:-}"
                [[ -n "$DEVICE" ]] || die "--device needs a value"
                shift 2
                ;;
            --output)
                OUT_PATH="${2:-}"
                [[ -n "$OUT_PATH" ]] || die "--output needs a value"
                shift 2
                ;;
            --in-place)
                IN_PLACE=1
                shift
                ;;
            --min-os)
                MIN_OS="${2:-}"
                [[ -n "$MIN_OS" ]] || die "--min-os needs a value"
                shift 2
                ;;
            --sdk)
                SDK_VERSION="${2:-}"
                [[ -n "$SDK_VERSION" ]] || die "--sdk needs a value"
                shift 2
                ;;
            --no-install)
                INSTALL_APP=0
                LAUNCH_APP=0
                shift
                ;;
            --no-launch)
                LAUNCH_APP=0
                shift
                ;;
            --console-pty)
                CONSOLE_PTY=1
                shift
                ;;
            --skip-verify)
                SKIP_VERIFY=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "unknown option: $1"
                ;;
            *)
                [[ -z "$SOURCE" ]] || die "only one app or ipa path is supported"
                SOURCE="$1"
                shift
                ;;
        esac
    done

    [[ -n "$SOURCE" ]] || {
        usage
        exit 1
    }
}

is_xcode_build_product() {
    case "$1" in
        */DerivedData/*|*/Build/Products/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

default_work_app() {
    local source_abs="$1"
    local parent
    local name
    parent="$(dirname "$source_abs")"
    name="$(basename "$source_abs")"

    if [[ "$(basename "$parent")" == "iossim-work" ]]; then
        printf '%s' "$source_abs"
        return
    fi

    if [[ "$name" == *.ipa ]]; then
        name="${name%.ipa}.app"
    fi

    printf '%s/iossim-work/%s' "$parent" "$name"
}

copy_app_tree() {
    local src="$1"
    local dst="$2"

    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    # APFS clonefile: near-instant CoW copy; only the files later modified by
    # vtool/codesign cost real I/O. Fall back to rsync/cp on other filesystems.
    if cp -Rc "$src" "$dst" 2>/dev/null; then
        log "cloned app (APFS clonefile): $src -> $dst"
    elif command -v rsync >/dev/null 2>&1; then
        rm -rf "$dst"
        log "copying app with rsync: $src -> $dst"
        rsync -a "$src/" "$dst/"
    else
        rm -rf "$dst"
        log "copying app: $src -> $dst"
        cp -R "$src" "$dst"
    fi
}

plist_set_simulator_platform() {
    local plist="$1"

    # single PlistBuddy invocation; Delete+Add is an idempotent upsert
    # (PlistBuddy keeps executing the remaining -c commands if one fails)
    "$PLIST_BUDDY" \
        -c "Delete :CFBundleSupportedPlatforms" \
        -c "Add :CFBundleSupportedPlatforms array" \
        -c "Add :CFBundleSupportedPlatforms:0 string iPhoneSimulator" \
        -c "Delete :DTPlatformName" \
        -c "Add :DTPlatformName string iphonesimulator" \
        -c "Delete :DTSDKName" \
        -c "Add :DTSDKName string iphonesimulator$SDK_VERSION" \
        -c "Delete :DTPlatformVersion" \
        -c "Add :DTPlatformVersion string $SDK_VERSION" \
        "$plist" >/dev/null 2>&1 || true
}

prepare_source_app() {
    local source_abs
    source_abs="$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")"

    [[ -e "$source_abs" ]] || die "source path does not exist: $source_abs"

    if [[ "$source_abs" == *.ipa ]]; then
        local temp_dir
        temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/iossim-ipa.XXXXXX")"
        log "extracting ipa: $source_abs"
        unzip -qq "$source_abs" -d "$temp_dir"

        local found_app
        found_app="$(find "$temp_dir/Payload" -maxdepth 1 -type d -name '*.app' -print -quit 2>/dev/null || true)"
        [[ -n "$found_app" ]] || die "ipa has no Payload/*.app"

        if [[ -z "$OUT_PATH" ]]; then
            OUT_PATH="$(default_work_app "$source_abs")"
        fi

        copy_app_tree "$found_app" "$OUT_PATH"
        rm -rf "$temp_dir"
    else
        [[ -d "$source_abs" && "$source_abs" == *.app ]] || die "source must be a .app directory or .ipa file"

        if [[ "$IN_PLACE" -eq 1 ]] && is_xcode_build_product "$source_abs"; then
            warn "--in-place ignored for Xcode build products; patching a sibling iossim-work copy"
            IN_PLACE=0
        fi

        if [[ "$IN_PLACE" -eq 1 ]]; then
            OUT_PATH="$source_abs"
        else
            if [[ -z "$OUT_PATH" ]]; then
                OUT_PATH="$(default_work_app "$source_abs")"
            fi

            if [[ "$OUT_PATH" == "$source_abs" ]]; then
                warn "source is already in iossim-work; patching that copy"
            else
                copy_app_tree "$source_abs" "$OUT_PATH"
            fi
        fi
    fi

    OUT_PATH="$(cd "$(dirname "$OUT_PATH")" && pwd)/$(basename "$OUT_PATH")"
    [[ -d "$OUT_PATH" ]] || die "output app was not created: $OUT_PATH"
}

# Mach-O detection by magic number (first 4 bytes) instead of `file`:
# zero process spawns per file, and LC_ALL=C makes 1 char == 1 byte.
#   cffaedfe  MH_MAGIC_64 (LE)    cefaedfe  MH_MAGIC (LE)
#   feedfacf  MH_CIGAM_64 (BE)    feedface  MH_CIGAM (BE)
#   cafebabe  FAT_CIGAM           cafebabf  FAT_CIGAM_64
is_macho() {
    local m
    LC_ALL=C IFS= read -r -n 4 m < "$1" 2>/dev/null || true
    case "$m" in
        $'\xcf\xfa\xed\xfe' | $'\xce\xfa\xed\xfe' | \
        $'\xfe\xed\xfa\xcf' | $'\xfe\xed\xfa\xce' | \
        $'\xca\xfe\xba\xbe' | $'\xca\xfe\xba\xbf') return 0 ;;
    esac
    return 1
}

is_fat_binary() {
    local m
    LC_ALL=C IFS= read -r -n 4 m < "$1" 2>/dev/null || true
    case "$m" in
        $'\xca\xfe\xba\xbe' | $'\xca\xfe\xba\xbf') return 0 ;;
    esac
    return 1
}

patch_macho() {
    local file_path="$1"
    local tmp_path
    local mode

    [[ -w "$file_path" ]] || chmod u+w "$file_path" 2>/dev/null || true

    thin_fat_macho "$file_path"

    mode="$(stat -f '%Lp' "$file_path" 2>/dev/null || echo 755)"
    tmp_path="$(mktemp "${file_path}.vtool.XXXXXX")"
    if vtool -arch arm64 -set-build-version iossim "$MIN_OS" "$SDK_VERSION" -replace -output "$tmp_path" "$file_path" >/dev/null 2>&1; then
        mv "$tmp_path" "$file_path"
        chmod "$mode" "$file_path" 2>/dev/null || chmod u+rx "$file_path"
    else
        rm -f "$tmp_path"
        warn "vtool skipped: $file_path"
    fi

    # rewrite only binaries that actually carry __RESTRICT (usually just the main executable)
    if LC_ALL=C grep -aq -e '__RESTRICT' -e '__restrict' "$file_path"; then
        perl -0pi -e 's/__RESTRICT/__RSTRICT_/g; s/__restrict/__rstrict_/g' "$file_path"
        chmod "$mode" "$file_path" 2>/dev/null || chmod u+rx "$file_path"
    fi
}

patch_plists() {
    local count=0

    log "patching Info.plist platform fields"
    while IFS= read -r -d '' plist; do
        chmod u+w "$plist" 2>/dev/null || true
        plist_set_simulator_platform "$plist"
        count=$((count + 1))
    done < "$PLIST_LIST"

    log "patched $count Info.plist files"
}

# one tree walk to build the plist + Mach-O manifests, reused by the
# patch and sign phases (instead of re-detecting with `file` twice)
scan_app_tree() {
    local f

    log "scanning app tree: $OUT_PATH"
    while IFS= read -r -d '' f; do
        case "${f##*/}" in
            Info.plist) printf '%s\0' "$f" >> "$PLIST_LIST" ;;
        esac
        if is_macho "$f"; then
            printf '%s\0' "$f" >> "$MACHO_LIST"
            MACHO_COUNT=$((MACHO_COUNT + 1))
        fi
    done < <(find "$OUT_PATH" -type f -print0)
    log "found $MACHO_COUNT Mach-O files"
}

patch_machos() {
    [[ "$MACHO_COUNT" -gt 0 ]] || die "no Mach-O files found"

    log "patching $MACHO_COUNT Mach-O files for iOS Simulator ($JOBS workers)"
    MIN_OS="$MIN_OS" SDK_VERSION="$SDK_VERSION" \
        xargs -0 -P "$JOBS" -n 16 bash "$SELF" --__worker patch < "$MACHO_LIST"
    log "patched $MACHO_COUNT Mach-O files"
}

remove_old_signatures() {
    log "removing old signatures and provisioning files"
    xattr -r -d com.apple.quarantine "$OUT_PATH" 2>/dev/null || true
    find "$OUT_PATH" -name _CodeSignature -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "$OUT_PATH" -name embedded.mobileprovision -type f -delete 2>/dev/null || true
}

sign_one() {
    local target="$1"

    chmod u+w "$target" 2>/dev/null || true
    codesign --force --sign - --timestamp=none "$target" >/dev/null 2>&1 || return 1
}

thin_fat_macho() {
    local file_path="$1"
    local tmp_path
    local mode

    is_fat_binary "$file_path" || return 0

    mode="$(stat -f '%Lp' "$file_path" 2>/dev/null || echo 755)"
    [[ -w "$file_path" ]] || chmod u+w "$file_path" 2>/dev/null || true
    tmp_path="$(mktemp "${file_path}.lipo.XXXXXX")"
    if lipo -thin arm64 "$file_path" -output "$tmp_path" 2>/dev/null; then
        mv "$tmp_path" "$file_path"
        chmod "$mode" "$file_path" 2>/dev/null || chmod u+rx "$file_path"
    else
        rm -f "$tmp_path"
    fi
}

sign_macho_worker() {
    local file_path="$1"

    [[ -w "$file_path" ]] || chmod u+w "$file_path" 2>/dev/null || true
    thin_fat_macho "$file_path"
    if ! codesign --force --sign - --timestamp=none "$file_path" >/dev/null 2>&1; then
        warn "codesign failed: $file_path"
    fi
}

sign_all_machos() {
    log "ad-hoc signing $MACHO_COUNT Mach-O files ($JOBS workers)"
    xargs -0 -P "$JOBS" -n 16 bash "$SELF" --__worker sign < "$MACHO_LIST"
    log "signed $MACHO_COUNT Mach-O files"
}

# count slashes in a path (pure bash, no process spawn)
slash_count() {
    local s="${1//[^\/]}"
    printf '%s' "${#s}"
}

sign_nested_bundles() {
    local bundle
    local -a bundles=()
    local d nd max=0 base

    while IFS= read -r -d '' bundle; do
        [[ "$bundle" == "$OUT_PATH" ]] && continue
        bundles+=("$bundle")
        nd="$(slash_count "$bundle")"
        if (( nd > max )); then max=$nd; fi
    done < <(find "$OUT_PATH" \( -name '*.framework' -o -name '*.appex' -o -name '*.app' -o -name '*.xpc' \) -type d -print0)

    if [[ "${#bundles[@]}" -eq 0 ]]; then
        log "no nested bundles"
        return 0
    fi

    log "ad-hoc signing ${#bundles[@]} nested bundles ($JOBS workers)"
    # sign deepest bundles first: a parent's resource seal covers its children,
    # so children must be signed before the parent hashes them. Bundles at the
    # same depth never nest, so each depth level is safe to sign in parallel.
    base="$(slash_count "$OUT_PATH")"
    local level_list
    level_list="$(mktemp)"
    for (( d = max; d > base; d-- )); do
        : > "$level_list"
        for bundle in "${bundles[@]}"; do
            if [[ "$(slash_count "$bundle")" -eq "$d" ]]; then
                printf '%s\0' "$bundle" >> "$level_list"
            fi
        done
        if [[ -s "$level_list" ]]; then
            xargs -0 -P "$JOBS" -n 1 bash "$SELF" --__worker sign_bundle < "$level_list"
        fi
    done
    rm -f "$level_list"
    log "signed ${#bundles[@]} nested bundles"
}

verify_worker() {
    if ! codesign --verify "$1" >/dev/null 2>&1; then
        warn "invalid signature: $1"
        exit 1
    fi
}

verify_embedded_frameworks() {
    [[ -d "$OUT_PATH/Frameworks" ]] || return 0

    log "verifying embedded Frameworks ($JOBS workers)"
    local fw_list
    fw_list="$(mktemp)"
    local fw
    for fw in "$OUT_PATH/Frameworks"/*.framework; do
        [[ -d "$fw" ]] && printf '%s\0' "$fw" >> "$fw_list"
    done
    if [[ -s "$fw_list" ]]; then
        xargs -0 -P "$JOBS" -n 1 bash "$SELF" --__worker verify < "$fw_list" \
            || die "embedded framework(s) still have invalid signatures"
    fi
    rm -f "$fw_list"
}

sign_app() {
    sign_all_machos
    sign_nested_bundles

    log "ad-hoc signing main app"
    sign_one "$OUT_PATH"

    if [[ "$SKIP_VERIFY" -eq 0 ]]; then
        verify_embedded_frameworks
    fi

    log "verifying main app signature"
    if [[ "$SKIP_VERIFY" -eq 0 ]] && ! codesign --verify "$OUT_PATH" >/dev/null 2>&1; then
        warn "main app verify failed; simulator may still launch"
    fi
}

bundle_id() {
    "$PLIST_BUDDY" -c "Print :CFBundleIdentifier" "$OUT_PATH/Info.plist"
}

install_and_grant() {
    local bid="$1"

    ensure_simulator_ready

    log "installing on simulator: $DEVICE"
    xcrun simctl install "$DEVICE" "$OUT_PATH"

    log "granting simulator privacy permissions to $bid"
    xcrun simctl privacy "$DEVICE" grant all "$bid"
}

launch_app() {
    local bid="$1"

    if [[ "$CONSOLE_PTY" -eq 1 ]]; then
        log "launching $bid with --console-pty (blocks until the app exits)"
        xcrun simctl launch --console-pty "$DEVICE" "$bid"
    else
        log "launching $bid"
        xcrun simctl launch "$DEVICE" "$bid"
    fi
}

ensure_simulator_ready() {
    if [[ "$DEVICE" == "booted" ]] && ! xcrun simctl list devices booted | grep -qE '\([0-9A-F-]{36}\) \(Booted\)'; then
        DEVICE="$(xcrun simctl list devices available \
            | awk '/^-- iOS / { ios=1; next } /^-- / { ios=0 } ios && /\([0-9A-F-]{36}\)/ { print; exit }' \
            | sed -nE 's/.*\(([0-9A-F-]{36})\).*/\1/p')"
        [[ -n "$DEVICE" ]] || die "no available iOS simulator found"
        log "selected simulator: $DEVICE"
    fi

    if ! xcrun simctl list devices booted | grep -q "$DEVICE"; then
        log "booting simulator: $DEVICE"
        xcrun simctl boot "$DEVICE" 2>/dev/null || true
        xcrun simctl bootstatus "$DEVICE" -b
    fi
}

main() {
    # internal worker mode, used by the parallel xargs pools
    if [[ "${1:-}" == "--__worker" ]]; then
        shift
        local mode="$1"
        shift
        local f
        for f in "$@"; do
            case "$mode" in
                patch) patch_macho "$f" || warn "patch failed: $f" ;;
                sign)  sign_macho_worker "$f" || warn "sign worker failed: $f" ;;
                sign_bundle) sign_one "$f" || warn "codesign bundle skipped: $f" ;;
                verify) verify_worker "$f" ;;
            esac
        done
        exit 0
    fi

    parse_args "$@"

    require_tool find
    require_tool perl
    require_tool plutil
    require_tool awk
    require_tool sed
    require_tool unzip
    require_tool vtool
    require_tool lipo
    require_tool codesign
    require_tool xcrun
    require_tool xargs
    [[ -x "$PLIST_BUDDY" ]] || die "$PLIST_BUDDY is required"

    prepare_source_app
    log "working app: $OUT_PATH"

    JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    [[ "$JOBS" =~ ^[0-9]+$ ]] || JOBS=4
    if (( JOBS > 8 )); then JOBS=8; fi

    MACHO_LIST="$(mktemp)"
    PLIST_LIST="$(mktemp)"
    MACHO_COUNT=0
    trap 'rm -f "$MACHO_LIST" "$PLIST_LIST"' EXIT

    remove_old_signatures
    scan_app_tree
    patch_plists
    patch_machos
    sign_app

    local bid
    bid="$(bundle_id)"
    log "bundle id: $bid"

    if [[ "$INSTALL_APP" -eq 1 ]]; then
        install_and_grant "$bid"
    fi

    if [[ "$LAUNCH_APP" -eq 1 ]]; then
        launch_app "$bid"
    fi

    log "done: $OUT_PATH"
}

main "$@"
