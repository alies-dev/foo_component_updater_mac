#!/bin/bash
#
# ci_sdk.sh - Fetch and build the foobar2000 SDK for CI (and clean machines)
#
# Usage:
#   FB2K_SDK_PATH=/path/to/SDK-2026-10-01 ./Scripts/ci_sdk.sh
#
# Downloads SDK-2026-10-01.7z, verifies its SHA256, extracts it to FB2K_SDK_PATH
# (default: ../SDK-2026-10-01, the location Scripts/sdk_config.rb expects) and builds the
# five static libraries in Release as universal arm64 + x86_64 for macOS 12.0.
# Idempotent: a missing SDK is downloaded and extracted (atomically), a library that already
# exists is not rebuilt. Needs curl, shasum, bsdtar (macOS ships all three) and Xcode.

set -euo pipefail

SDK_NAME="SDK-2026-10-01"
SDK_URL="https://www.foobar2000.org/downloads/$SDK_NAME.7z"
SDK_SHA256="d4c55077336fae81bf8df0259b5b2748fa45ea84132c656ead93eb123cbcdc26"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_PATH="${FB2K_SDK_PATH:-$SCRIPT_DIR/../$SDK_NAME}"
mkdir -p "$(dirname "$SDK_PATH")"
SDK_PATH="$(cd "$(dirname "$SDK_PATH")" && pwd)/$(basename "$SDK_PATH")"

# project (relative to the SDK root) : library it produces (under <project dir>/build/Release)
LIBRARIES=(
    "pfc/pfc.xcodeproj:libpfc.a"
    "foobar2000/SDK/foobar2000_SDK.xcodeproj:libfoobar2000_SDK.a"
    "foobar2000/shared/shared.xcodeproj:libshared.a"
    "foobar2000/helpers/foobar2000_SDK_helpers.xcodeproj:libfoobar2000_SDK_helpers.a"
    "foobar2000/foobar2000_component_client/foobar2000_component_client.xcodeproj:libfoobar2000_component_client.a"
)

if [ ! -f "$SDK_PATH/pfc/pfc.xcodeproj/project.pbxproj" ]; then
    if [ -d "$SDK_PATH" ] && [ -n "$(ls -A "$SDK_PATH")" ]; then
        echo "ERROR: $SDK_PATH exists but holds no complete SDK; remove it and rerun" >&2
        exit 1
    fi
    # Extract into a staging directory beside the target and move it into place only
    # after a successful extract, so an interrupted run never leaves a half-extracted SDK.
    WORK="$(mktemp -d "$(dirname "$SDK_PATH")/.$SDK_NAME.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
    echo "==> Downloading $SDK_URL"
    curl --fail --silent --show-error --location --retry 3 -o "$WORK/sdk.7z" "$SDK_URL"
    ACTUAL="$(shasum -a 256 "$WORK/sdk.7z" | cut -d' ' -f1)"
    if [ "$ACTUAL" != "$SDK_SHA256" ]; then
        echo "ERROR: SDK checksum mismatch: expected $SDK_SHA256, got $ACTUAL" >&2
        exit 1
    fi
    echo "==> Extracting to $SDK_PATH"
    mkdir "$WORK/extract"
    bsdtar -xf "$WORK/sdk.7z" -C "$WORK/extract"
    [ -f "$WORK/extract/pfc/pfc.xcodeproj/project.pbxproj" ] || { echo "ERROR: unexpected SDK archive layout" >&2; exit 1; }
    rmdir "$SDK_PATH" 2>/dev/null || true
    mv "$WORK/extract" "$SDK_PATH"
fi

for entry in "${LIBRARIES[@]}"; do
    project="${entry%%:*}"
    library="${entry##*:}"
    project_dir="$SDK_PATH/$(dirname "$project")"
    if [ -f "$project_dir/build/Release/$library" ]; then
        echo "==> $library already built"
        continue
    fi
    echo "==> Building $library"
    mkdir -p "$project_dir/build"
    (cd "$project_dir" && xcodebuild -project "$(basename "$project")" -configuration Release \
        MACOSX_DEPLOYMENT_TARGET=12.0 ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
        SYMROOT="$project_dir/build" build > "$project_dir/build/xcodebuild.log" 2>&1) || {
        tail -30 "$project_dir/build/xcodebuild.log" >&2
        echo "ERROR: building $library failed" >&2
        exit 1
    }
    [ -f "$project_dir/build/Release/$library" ] || { echo "ERROR: $library not produced" >&2; exit 1; }
done
echo "==> SDK ready at $SDK_PATH"
