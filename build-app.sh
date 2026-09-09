#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/work/build"
CACHE_DIR="$PROJECT_DIR/work/cache"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/zzPDF.app"
ZIP_PATH="$OUTPUT_DIR/zzPDF-macOS.zip"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
USES_COMPATIBILITY_SDK=false

if [[ -n "${ZZPDF_SDK_PATH:-}" ]]; then
    SDK_PATH="$ZZPDF_SDK_PATH"
elif [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    # Compatibility fallback for some Command Line Tools-only installations.
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    USES_COMPATIBILITY_SDK=true
else
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

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

# The local Command Line Tools currently pair a newer Swift compiler with an
# incompatible macOS 26 SDK, so compilation falls back to the macOS 15.4 SDK.
# Marking that binary as linked for macOS 26 opts into the current native window
# chrome while retaining the macOS 14 deployment target and API compatibility.
if [[ "$USES_COMPATIBILITY_SDK" == true && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk" ]]; then
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
