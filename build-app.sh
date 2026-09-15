#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/work/build"
CACHE_DIR="$PROJECT_DIR/work/cache"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/zzPDF.app"
ZIP_PATH="$OUTPUT_DIR/zzPDF-macOS.zip"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# Some Command Line Tools releases ship an SDK whose SwiftUI needs a macro plugin the
# toolchain does not install, which makes every `@State` fail to compile. Rather than
# hard-coding a known-good SDK, compile a one-line SwiftUI probe against each installed
# SDK, newest first, and keep the first one that actually builds.
probe_sdk() {
    local sdk="$1"
    [[ -d "$sdk" ]] || return 1
    SDKROOT="$sdk" xcrun swiftc -parse-as-library -typecheck "$PROBE_FILE" >/dev/null 2>&1
}

PROBE_DIR="$(mktemp -d)"
PROBE_FILE="$PROBE_DIR/SDKProbe.swift"
trap 'rm -rf "$PROBE_DIR"' EXIT
cat > "$PROBE_FILE" <<'SWIFT'
import SwiftUI

struct SDKProbe: View {
    @State private var value = 0
    var body: some View { Text("\(value)") }
}
SWIFT

SDK_PATH=""
if [[ -n "${ZZPDF_SDK_PATH:-}" ]]; then
    SDK_PATH="$ZZPDF_SDK_PATH"
else
    CANDIDATES=()
    DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    [[ -n "$DEFAULT_SDK" ]] && CANDIDATES+=("$DEFAULT_SDK")
    for directory in "$(xcode-select -p 2>/dev/null)/SDKs" \
                     "$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)/Developer/SDKs"; do
        [[ -d "$directory" ]] || continue
        while IFS= read -r sdk; do
            [[ -n "$sdk" ]] && CANDIDATES+=("$directory/$sdk")
        done < <(ls "$directory" 2>/dev/null | grep '^MacOSX.*\.sdk$' | sort -rV)
    done
    for sdk in "${CANDIDATES[@]}"; do
        if probe_sdk "$sdk"; then
            SDK_PATH="$sdk"
            break
        fi
    done
    if [[ -z "$SDK_PATH" ]]; then
        echo "No installed macOS SDK can compile SwiftUI. Install or update Xcode, or set ZZPDF_SDK_PATH." >&2
        exit 1
    fi
    if [[ "$SDK_PATH" != "$DEFAULT_SDK" ]]; then
        echo "The default SDK cannot compile SwiftUI; building against $SDK_PATH instead."
    fi
fi

SDK_VERSION="$(SDKROOT="$SDK_PATH" xcrun --sdk "$SDK_PATH" --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR="${SDK_VERSION%%.*}"

mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$OUTPUT_DIR"

CLANG_MODULE_CACHE_PATH="$CACHE_DIR" \
SDKROOT="$SDK_PATH" \
swift build -c release --disable-sandbox --scratch-path "$BUILD_DIR"

EXECUTABLE_PATH="$(find "$BUILD_DIR" -type f -path '*/release/zzPDF' -perm +111 | head -n 1)"
if [[ -z "$EXECUTABLE_PATH" ]]; then
    echo "zzPDF executable not found after compilation." >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/zzPDF"
cp "$PROJECT_DIR/AppResources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/AppResources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Building against an SDK older than macOS 26 leaves the binary on the previous window
# chrome. Marking it as linked for macOS 26 opts into the current native chrome while
# keeping the macOS 14 deployment target and API compatibility.
if [[ -n "$SDK_MAJOR" && "$SDK_MAJOR" -lt 26 ]]; then
    MODERN_EXECUTABLE="$BUILD_DIR/zzPDF-modern"
    xcrun vtool \
        -set-build-version macos 14.0 26.0 \
        -replace \
        -output "$MODERN_EXECUTABLE" \
        "$APP_DIR/Contents/MacOS/zzPDF"
    mv "$MODERN_EXECUTABLE" "$APP_DIR/Contents/MacOS/zzPDF"
fi

chmod +x "$APP_DIR/Contents/MacOS/zzPDF"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --deep --sign - "$APP_DIR"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "App: $APP_DIR"
echo "Archive: $ZIP_PATH"
