#pragma once

// Single source of truth for the component version; read by
// Scripts/generate_xcode_project.rb for MARKETING_VERSION.
#define FCU_VERSION "0.1.0"

// FCU_DEBUG_HOOKS is defined by the Debug configuration only (see
// Scripts/generate_xcode_project.rb); Release builds compile the test hooks out.
