#!/bin/bash
#
# package.sh - Package the component as foo_component_updater_mac.fb2k-component
#
# Usage:
#   ./Scripts/package.sh
#
# Builds the Release configuration when needed (unit tests gate that build), then zips
# mac/foo_component_updater_mac.component/ into build/foo_component_updater_mac.fb2k-component,
# the layout foobar2000 installs from. Prints the SHA256 and checks the archive layout.

set -euo pipefail

PROJECT_NAME="foo_component_updater_mac"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
COMPONENT="$BUILD_DIR/Release/$PROJECT_NAME.component"
OUTPUT="$BUILD_DIR/$PROJECT_NAME.fb2k-component"

if [ ! -d "$COMPONENT" ]; then
    echo "==> Release build not found, building it"
    "$SCRIPT_DIR/build.sh" --release
fi
[ -d "$COMPONENT" ] || { echo "ERROR: build did not produce $COMPONENT" >&2; exit 1; }

# The signature must be intact: foobar2000 refuses unsigned bundles (docs/sdk-quirks.md).
codesign --verify --strict "$COMPONENT" || { echo "ERROR: $COMPONENT does not verify" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/mac"
ditto --norsrc --noextattr --noqtn "$COMPONENT" "$STAGE/mac/$PROJECT_NAME.component"

rm -f "$OUTPUT"
# --keepParent keeps the mac/ prefix: the archive root must be the mac directory.
(cd "$STAGE" && ditto -c -k --keepParent --norsrc --noextattr --noqtn mac "$OUTPUT")

LISTING="$(unzip -Z1 "$OUTPUT")"
for required in "mac/$PROJECT_NAME.component/Contents/MacOS/$PROJECT_NAME" "mac/$PROJECT_NAME.component/Contents/Info.plist"; do
    echo "$LISTING" | grep -qx "$required" || { echo "ERROR: $required missing from the package" >&2; exit 1; }
done
if echo "$LISTING" | grep -v '^mac/' | grep -q .; then
    echo "ERROR: entries outside mac/ in the package:" >&2
    echo "$LISTING" | grep -v '^mac/' >&2
    exit 1
fi

unzip -l "$OUTPUT"
echo ""
echo "Created: $OUTPUT"
echo "Size:    $(du -h "$OUTPUT" | cut -f1)"
echo "SHA256:  $(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
