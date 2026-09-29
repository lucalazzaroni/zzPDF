#!/bin/zsh
set -euo pipefail

# Builds and runs every standalone smoke test under Tests/.
#
# Each test is its own `main.swift` compiled together with the application sources, minus
# ZZPDFApp.swift, which carries the app's own entry point. Pass test names to run only
# some of them: ./scripts/run-tests.sh RedactionSmoke TextEditSmoke

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/work/tests"
mkdir -p "$BUILD_DIR"

TOOLCHAIN=("${(@f)$("$PROJECT_DIR/scripts/select-sdk.sh")}")
SWIFTC="${TOOLCHAIN[1]}"
SDK_PATH="${TOOLCHAIN[2]}"
[[ -n "$SWIFTC" && -n "$SDK_PATH" ]] || exit 1

SOURCES=("$PROJECT_DIR"/Sources/zzPDF/*.swift)
SOURCES=("${(@)SOURCES:#*/ZZPDFApp.swift}")

if (( $# > 0 )); then
    SUITES=("$@")
else
    SUITES=()
    for directory in "$PROJECT_DIR"/Tests/*/; do
        [[ -f "$directory/main.swift" ]] || continue
        SUITES+=("${${directory%/}:t}")
    done
fi

# The app's own entry point is left out of every suite, since it carries @main. Nothing
# else type-checks it, so a change that breaks it used to surface only as an app that
# quietly went on running the previous build.
echo "Checking the application sources"
if ! SDKROOT="$SDK_PATH" "$SWIFTC" -typecheck -sdk "$SDK_PATH" -parse-as-library \
    "$PROJECT_DIR"/Sources/zzPDF/*.swift 2>"$BUILD_DIR/typecheck.log"; then
    grep -E "error:" "$BUILD_DIR/typecheck.log" | head -20 >&2
    echo "The application sources do not compile." >&2
    exit 1
fi

FAILED=()
for suite in "${SUITES[@]}"; do
    main="$PROJECT_DIR/Tests/$suite/main.swift"
    if [[ ! -f "$main" ]]; then
        echo "No such test: $suite" >&2
        FAILED+=("$suite")
        continue
    fi

    binary="$BUILD_DIR/$suite"
    # A test that declares @main needs -parse-as-library; one written as top-level code
    # must not have it, or its statements are rejected.
    MODE=()
    grep -q '^@main' "$main" && MODE=(-parse-as-library)
    if ! SDKROOT="$SDK_PATH" "$SWIFTC" -O -sdk "$SDK_PATH" "${MODE[@]}" "${SOURCES[@]}" "$main" -o "$binary"; then
        echo "  $suite: did not compile"
        FAILED+=("$suite")
        continue
    fi

    if "$binary" 2>/dev/null; then
        continue
    fi
    "$binary" >/dev/null 2>"$BUILD_DIR/$suite.log" || true
    # All of it, not the last line: a failure that spans lines says the most in the ones
    # before the last, and on CI the log is the only thing there is to go on.
    echo "  $suite failed:"
    sed 's/^/    /' "$BUILD_DIR/$suite.log"
    FAILED+=("$suite")
done

# Each suite gives itself a UserDefaults domain of its own and removes it when it is
# done, but the preferences daemon writes the file back out empty, so a run leaves one
# behind per suite — hundreds of them over time. They are ours and nobody else's, named
# after this app's test prefix, so the run tidies them up.
/usr/bin/find "$HOME/Library/Preferences" -maxdepth 1 -name 'it.lucalazzaroni.zzpdf.tests.*.plist' -delete 2>/dev/null || true

if (( ${#FAILED} > 0 )); then
    echo
    echo "${#FAILED} of ${#SUITES} suites failed: ${FAILED[*]}" >&2
    exit 1
fi
echo
echo "${#SUITES} suites passed."
