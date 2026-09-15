#!/bin/zsh
# Picks a macOS SDK that can actually compile SwiftUI and prints its path.
#
# Some Command Line Tools releases ship an SDK whose SwiftUI needs a macro plugin the
# toolchain does not install, which makes every `@State` fail to compile. Rather than
# hard-coding a known-good SDK, compile a one-line SwiftUI probe against each installed
# SDK, newest first, and keep the first one that actually builds.

if [[ -n "${ZZPDF_SDK_PATH:-}" ]]; then
    echo "$ZZPDF_SDK_PATH"
    return 0 2>/dev/null || exit 0
fi

ZZPDF_PROBE_DIR="$(mktemp -d)"
ZZPDF_PROBE_FILE="$ZZPDF_PROBE_DIR/SDKProbe.swift"
cat > "$ZZPDF_PROBE_FILE" <<'SWIFT'
import SwiftUI

struct SDKProbe: View {
    @State private var value = 0
    var body: some View { Text("\(value)") }
}
SWIFT

ZZPDF_CANDIDATES=()
ZZPDF_DEFAULT_SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[[ -n "$ZZPDF_DEFAULT_SDK" ]] && ZZPDF_CANDIDATES+=("$ZZPDF_DEFAULT_SDK")
for directory in "$(xcode-select -p 2>/dev/null)/SDKs" \
                 "$(xcrun --sdk macosx --show-sdk-platform-path 2>/dev/null)/Developer/SDKs"; do
    [[ -d "$directory" ]] || continue
    while IFS= read -r sdk; do
        [[ -n "$sdk" ]] && ZZPDF_CANDIDATES+=("$directory/$sdk")
    done < <(ls "$directory" 2>/dev/null | grep '^MacOSX.*\.sdk$' | sort -rV)
done

ZZPDF_CHOSEN=""
for sdk in "${ZZPDF_CANDIDATES[@]}"; do
    [[ -d "$sdk" ]] || continue
    if SDKROOT="$sdk" xcrun swiftc -parse-as-library -typecheck "$ZZPDF_PROBE_FILE" >/dev/null 2>&1; then
        ZZPDF_CHOSEN="$sdk"
        break
    fi
done
rm -rf "$ZZPDF_PROBE_DIR"

if [[ -z "$ZZPDF_CHOSEN" ]]; then
    echo "No installed macOS SDK can compile SwiftUI. Install or update Xcode, or set ZZPDF_SDK_PATH." >&2
    return 1 2>/dev/null || exit 1
fi

echo "$ZZPDF_CHOSEN"
