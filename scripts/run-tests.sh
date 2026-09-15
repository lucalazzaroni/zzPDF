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

SDK_PATH="$("$PROJECT_DIR/scripts/select-sdk.sh")"
[[ -n "$SDK_PATH" ]] || exit 1

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
    # must not have it, so try the common case first and fall back.
    if ! SDKROOT="$SDK_PATH" xcrun swiftc -O -parse-as-library "${SOURCES[@]}" "$main" -o "$binary" 2>/dev/null; then
        if ! SDKROOT="$SDK_PATH" xcrun swiftc -O "${SOURCES[@]}" "$main" -o "$binary"; then
            echo "  $suite: did not compile"
            FAILED+=("$suite")
            continue
        fi
    fi

    if "$binary" 2>/dev/null; then
        continue
    fi
    "$binary" >/dev/null 2>"$BUILD_DIR/$suite.log" || true
    echo "  $suite: $(tail -n 1 "$BUILD_DIR/$suite.log")"
    FAILED+=("$suite")
done

if (( ${#FAILED} > 0 )); then
    echo
    echo "${#FAILED} of ${#SUITES} suites failed: ${FAILED[*]}" >&2
    exit 1
fi
echo
echo "${#SUITES} suites passed."
