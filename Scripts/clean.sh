#!/bin/bash
#
# clean.sh - Clean foo_component_updater_mac build artifacts
#
# Usage:
#   ./Scripts/clean.sh

set -e

# Component configuration
PROJECT_NAME="foo_component_updater_mac"

# Load library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

# Run clean
do_clean
