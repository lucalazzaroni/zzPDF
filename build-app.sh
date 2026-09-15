#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/work/build"
CACHE_DIR="$PROJECT_DIR/work/cache"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/zzPDF.app"
ZIP_PATH="$OUTPUT_DIR/zzPDF-macOS.zip"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

SDK_PATH="$("${0:A:h}/scripts/select-sdk.sh")"
[[ -n "$SDK_PATH" ]] || exit 1
if [[ -z "${ZZPDF_SDK_PATH:-}" && "$SDK_PATH" != "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" ]]; then
    echo "The default SDK cannot compile SwiftUI; building against $SDK_PATH instead."
fi

SDK_VERSION="$(SDKROOT="$SDK_PATH" xcrun --sdk "$SDK_PATH" --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR="${SDK_VERSION%%.*}"

mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$OUTPUT_DIR"

EXECUTABLE_PATH=""
if CLANG_MODULE_CACHE_PATH="$CACHE_DIR" SDKROOT="$SDK_PATH" \
    swift build -c release --disable-sandbox --scratch-path "$BUILD_DIR"; then
    EXECUTABLE_PATH="$(find "$BUILD_DIR" -type f -path '*/release/zzPDF' -perm +111 | head -n 1)"
fi

# Swift Package Manager itself can be broken by a half-applied Command Line Tools update,
# while the compiler still works. The target is one module with no dependencies, so
# compiling the sources directly produces the same binary.
if [[ -z "$EXECUTABLE_PATH" ]]; then
    echo "swift build is unavailable; compiling the sources directly."
    DIRECT_EXECUTABLE="$BUILD_DIR/zzPDF-direct"
    mkdir -p "$BUILD_DIR"
    CLANG_MODULE_CACHE_PATH="$CACHE_DIR" SDKROOT="$SDK_PATH" \
        xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
        "$PROJECT_DIR"/Sources/zzPDF/*.swift -o "$DIRECT_EXECUTABLE"
    EXECUTABLE_PATH="$DIRECT_EXECUTABLE"
fi

if [[ -z "$EXECUTABLE_PATH" || ! -x "$EXECUTABLE_PATH" ]]; then
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
