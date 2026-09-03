#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/work/build"
CACHE_DIR="$PROJECT_DIR/work/cache"
TEMP_HOME="$PROJECT_DIR/work/home"
OUTPUT_DIR="$PROJECT_DIR/outputs"
APP_DIR="$OUTPUT_DIR/zzPDF.app"
ZIP_PATH="$OUTPUT_DIR/zzPDF-macOS.zip"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if [[ -n "${ZZPDF_SDK_PATH:-}" ]]; then
    SDK_PATH="$ZZPDF_SDK_PATH"
elif [[ "$(xcode-select -p 2>/dev/null || true)" == "/Library/Developer/CommandLineTools" && -d "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk" ]]; then
    # Compatibilità con alcune installazioni delle sole Command Line Tools.
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
fi

mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$TEMP_HOME" "$OUTPUT_DIR"

HOME="$TEMP_HOME" \
CLANG_MODULE_CACHE_PATH="$CACHE_DIR" \
SDKROOT="$SDK_PATH" \
swift build -c release --disable-sandbox --scratch-path "$BUILD_DIR"

EXECUTABLE_PATH="$(find "$BUILD_DIR" -type f -path '*/release/zzPDF' -perm +111 | head -n 1)"
if [[ -z "$EXECUTABLE_PATH" ]]; then
    echo "Eseguibile zzPDF non trovato dopo la compilazione." >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE_PATH" "$APP_DIR/Contents/MacOS/zzPDF"
cp "$PROJECT_DIR/AppResources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/AppResources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
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
echo "Archivio: $ZIP_PATH"
