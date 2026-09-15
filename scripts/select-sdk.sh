#!/bin/zsh
# Finds a Swift compiler and a macOS SDK that can actually compile SwiftUI, and prints
# them on two lines: the compiler first, the SDK second.
#
# Two things go wrong on real machines, and both are silent:
#
#   * Some Command Line Tools releases ship an SDK whose SwiftUI needs a macro plugin the
#     toolchain does not install, so every `@State` fails to compile.
#   * An Xcode newer than the running macOS can break `xcrun` outright once it is selected,
#     which takes `swift` and `swiftc` down with it.
#
# So rather than trusting the active toolchain, this compiles a one-line SwiftUI probe with
# each compiler and SDK it can find, and keeps the first pair that works.

if [[ -n "${ZZPDF_SWIFTC:-}" && -n "${ZZPDF_SDK_PATH:-}" ]]; then
    echo "$ZZPDF_SWIFTC"
    echo "$ZZPDF_SDK_PATH"
    exit 0
fi

probe_dir="$(mktemp -d)"
probe_file="$probe_dir/SDKProbe.swift"
trap 'rm -rf "$probe_dir"' EXIT
cat > "$probe_file" <<'SWIFT'
import SwiftUI

struct SDKProbe: View {
    @State private var value = 0
    var body: some View { Text("\(value)") }
}
SWIFT

developer_dir="$(xcode-select -p 2>/dev/null || true)"

compilers=()
[[ -n "${ZZPDF_SWIFTC:-}" ]] && compilers+=("$ZZPDF_SWIFTC")
for candidate in "$(xcrun --find swiftc 2>/dev/null || true)" \
                 "$developer_dir/usr/bin/swiftc" \
                 "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
                 "/Library/Developer/CommandLineTools/usr/bin/swiftc" \
                 "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" \
                 "/usr/bin/swiftc"; do
    [[ -x "$candidate" ]] && compilers+=("$candidate")
done

sdks=()
[[ -n "${ZZPDF_SDK_PATH:-}" ]] && sdks+=("$ZZPDF_SDK_PATH")
default_sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
[[ -d "$default_sdk" ]] && sdks+=("$default_sdk")
# Platform SDKs come first: an SDK sitting next to its own toolchain is the one whose
# macro plugins the compiler can find.
for directory in "$developer_dir/Platforms/MacOSX.platform/Developer/SDKs" \
                 "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs" \
                 "$developer_dir/SDKs" \
                 "/Library/Developer/CommandLineTools/SDKs"; do
    [[ -d "$directory" ]] || continue
    while IFS= read -r sdk; do
        [[ -n "$sdk" ]] && sdks+=("$directory/$sdk")
    done < <(ls "$directory" 2>/dev/null | grep '^MacOSX.*\.sdk$' | sort -rV)
done

for compiler in "${compilers[@]}"; do
    for sdk in "${sdks[@]}"; do
        [[ -d "$sdk" ]] || continue
        if SDKROOT="$sdk" "$compiler" -sdk "$sdk" -parse-as-library -typecheck "$probe_file" >/dev/null 2>&1; then
            echo "$compiler"
            echo "$sdk"
            exit 0
        fi
    done
done

echo "No Swift compiler and macOS SDK on this machine can compile SwiftUI." >&2
echo "Install or repair the Command Line Tools, or set ZZPDF_SWIFTC and ZZPDF_SDK_PATH." >&2
exit 1
