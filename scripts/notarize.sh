#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_PATH="$PROJECT_DIR/outputs/zzPDF.app"
ZIP_PATH="$PROJECT_DIR/outputs/zzPDF-macOS.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-zzPDF-notary}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "Build non trovata: eseguire prima ./build-app.sh con SIGN_IDENTITY." >&2
    exit 1
fi

SIGN_INFO="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 || true)"
if [[ "$SIGN_INFO" != *"flags=0x10000(runtime)"* ]]; then
    echo "La build non usa Hardened Runtime. Ricompilare con SIGN_IDENTITY." >&2
    exit 1
fi

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Pacchetto notarizzato: $ZIP_PATH"
