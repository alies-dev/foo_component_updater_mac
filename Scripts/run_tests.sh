#!/bin/bash
#
# run_tests.sh - Compile and run unit tests for pure-logic Core models.
#
# The modules under test are plain C++ (no foobar2000 SDK), so they compile
# standalone with clang in a few seconds: no Xcode target or SDK needed.
# Invoked as a gating phase by build.sh; exits non-zero on any failure.
#
# Tests are auto-discovered: every Tests/*Tests.cpp becomes one binary. The sources
# it needs are declared in the test file itself with a comment line (header-only
# modules need none):
#   // TEST_DEPS: src/Core/github_releases.cpp src/upstream/update_parse.cpp
#
# Tests run under ASan+UBSan (tests only — never the component build).
# UBSan findings abort (-fno-sanitize-recover) so they gate like any failure.
#
# Usage: run_tests.sh [--coverage]
#   --coverage  Recompile with llvm source coverage instead of sanitizers and
#               print a per-Core-file line coverage report after the run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/build/tests"

mkdir -p "$TEST_BUILD_DIR"

COVERAGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --coverage) COVERAGE=1 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            echo "Usage: run_tests.sh [--coverage]" >&2
            exit 1
            ;;
    esac
    shift
done

if [ "$COVERAGE" = "1" ]; then
    INSTRUMENT_FLAGS=(-fprofile-instr-generate -fcoverage-mapping)
    # -O0 for coverage: at -O1 the header-only modules the report is most
    # useful for get inlined, which distorts per-line counts.
    OPT_FLAG=-O0
else
    INSTRUMENT_FLAGS=(-fsanitize=address,undefined -fno-sanitize-recover=undefined -fno-omit-frame-pointer)
    OPT_FLAG=-O1
fi

BINARIES=()

for test_file in "$PROJECT_DIR"/Tests/*Tests.cpp; do
    [ -e "$test_file" ] || continue
    base="$(basename "$test_file")"
    name="${base%.*}"          # FooTests
    module="${base%Tests.*}"   # Foo

    sources=("$test_file")

    # Per-test extra deps: "// TEST_DEPS: <path> [<path>...]" (project-relative).
    # Paths are whitespace-split, so they must not contain spaces. Globbing is
    # disabled for the split so a literal * in a path cannot expand to the
    # working directory's contents.
    deps="$(grep -h '^// TEST_DEPS:' "$test_file" | sed 's|^// TEST_DEPS:||' || true)"
    set -f
    for dep in $deps; do
        if [ ! -f "$PROJECT_DIR/$dep" ]; then
            set +f
            echo "ERROR: $base declares missing TEST_DEPS file: $dep" >&2
            exit 1
        fi
        sources+=("$PROJECT_DIR/$dep")
    done
    set +f

    out="$TEST_BUILD_DIR/$name"
    echo "==> Compiling unit tests ($module)..."
    clang++ -std=c++20 "$OPT_FLAG" -Wall "${INSTRUMENT_FLAGS[@]}" \
        "${sources[@]}" \
        -o "$out"
    BINARIES+=("$out")
done

if [ "${#BINARIES[@]}" -eq 0 ]; then
    echo "ERROR: no tests discovered in $PROJECT_DIR/Tests" >&2
    exit 1
fi

echo "==> Running unit tests..."
for bin in "${BINARIES[@]}"; do
    if [ "$COVERAGE" = "1" ]; then
        LLVM_PROFILE_FILE="$bin.profraw" "$bin"
    else
        "$bin"
    fi
done

if [ "$COVERAGE" = "1" ]; then
    echo "==> Coverage report (src/Core)..."
    profdata="$TEST_BUILD_DIR/tests.profdata"
    xcrun llvm-profdata merge -sparse "${BINARIES[@]/%/.profraw}" -o "$profdata"
    # First binary positional, the rest as -object; trailing source paths
    # restrict the report to the Core modules. The count guard is for bash 3.2
    # (macOS): "${BINARIES[@]:1}" on a single-element array trips set -u there.
    object_args=("${BINARIES[0]}")
    if [ "${#BINARIES[@]}" -gt 1 ]; then
        for bin in "${BINARIES[@]:1}"; do
            object_args+=(-object "$bin")
        done
    fi
    xcrun llvm-cov report "${object_args[@]}" -instr-profile="$profdata" \
        "$PROJECT_DIR"/src/Core/*.h "$PROJECT_DIR"/src/Core/*.mm "$PROJECT_DIR"/src/Core/*.cpp
fi
