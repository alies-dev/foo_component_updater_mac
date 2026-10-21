#!/bin/bash
#
# build.sh - Build foo_component_updater_mac component
#
# Usage:
#   ./Scripts/build.sh [OPTIONS]
#
# Options:
#   --debug       Build Debug configuration (default: Release)
#   --release     Build Release configuration
#   --clean       Clean before building
#   --regenerate  Accepted for compatibility (the project is always regenerated)
#   --install     Install to foobar2000 after building
#   --help        Show this help message

set -e

# Component configuration
PROJECT_NAME="foo_component_updater_mac"

# Load library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

show_help() {
    head -16 "$0" | tail -12
    exit 0
}

# Parse arguments
if ! parse_build_args "$@"; then
    show_help
fi

# Unit tests gate the build: the pure logic (src/Core, src/upstream/update_parse)
# must pass before compiling the component. Fast, no SDK, no Xcode.
if ! "$SCRIPT_DIR/run_tests.sh"; then
    echo ""
    echo "==> ========================================="
    echo "==>   TESTS FAILED - build aborted"
    echo "==> ========================================="
    exit 1
fi

# Run build
if do_build; then
    # Install if requested
    if [ "$INSTALL_AFTER" = true ]; then
        do_install
    fi
else
    exit 1
fi
