#pragma once

#include <string>

#include "../fb2k_sdk.h"

namespace fcu {

struct InstallOutcome {
    bool ok = false;
    std::string message; // user readable reason when !ok
};

// Both block (network, ditto, code signature checks): worker thread only. They never throw,
// touch only <profile>/foo_component_updater_mac/{work,backup/<name>} and
// user-components/pending/<name>, and leave the installed bundle alone: on success the new
// version waits in pending/<name> for the next start of foobar2000.
// `name` is the component file name (componentversion::get_file_name), `installedVersion`
// the version string it reports now (kept with the backup).
InstallOutcome installUpdate(std::string const& name, std::string const& installedVersion, std::string const& url,
                             abort_callback& abort);

// Stages backup/<name> (the version the last install replaced); the installed version becomes the backup.
InstallOutcome restorePrevious(std::string const& name, std::string const& installedVersion, abort_callback& abort);

// Replaces component `name` with the different component `replacement` at the next start: the package at `url`
// goes to pending/<replacement> (signature checked, no identity to compare with) and pending/<name> becomes an
// uninstall marker. With an empty `url` (the replacement is installed or staged already) only the marker is written.
// No backup is kept: once removed, `name` is no longer listed. Same rules as installUpdate otherwise.
InstallOutcome switchComponent(std::string const& name, std::string const& replacement, std::string const& url,
                               abort_callback& abort);

// pending/<name>/<name>.component exists: an install that waits for a restart.
bool isStaged(std::string const& name);

// pending/<name> is an uninstall marker (an empty file): the component goes at the next start.
bool isRemovalStaged(std::string const& name);

// The version string of backup/<name>; false when there is no usable backup.
bool backupVersion(std::string const& name, std::string& version);

} // namespace fcu
