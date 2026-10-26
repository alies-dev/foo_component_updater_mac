#include "Settings.h"

#include "../fb2k_sdk.h"
#include "../Core/mapping_validation.h"

namespace {
// {5876B420-1282-464E-9CB9-7CF32156F4F5}
const GUID guid_cfg_include_prereleases =
{ 0x5876b420, 0x1282, 0x464e, { 0x9c, 0xb9, 0x7c, 0xf3, 0x21, 0x56, 0xf4, 0xf5 } };

// {03396D36-9ED8-4F2E-9DC8-B1A16C75EE5D}
const GUID guid_cfg_show_built_in =
{ 0x03396d36, 0x9ed8, 0x4f2e, { 0x9d, 0xc8, 0xb1, 0xa1, 0x6c, 0x75, 0xee, 0x5d } };

// {141C795E-24E0-45FE-ABC2-15AA49E4766B}
const GUID guid_cfg_kept_replacements =
{ 0x141c795e, 0x24e0, 0x45fe, { 0xab, 0xc2, 0x15, 0xaa, 0x49, 0xe4, 0x76, 0x6b } };

cfg_bool g_cfgIncludePrereleases(guid_cfg_include_prereleases, false);
cfg_bool g_cfgShowBuiltIn(guid_cfg_show_built_in, false);
cfg_string g_cfgKeptReplacements(guid_cfg_kept_replacements, ""); // one "old>new" line per kept component

std::string keptLine(std::string const& oldName, std::string const& newName) {
    return fcu::normalizeComponentName(oldName) + ">" + fcu::normalizeComponentName(newName) + "\n";
}
}

bool GetIncludePrereleases() { return g_cfgIncludePrereleases.get(); }
void SetIncludePrereleases(bool enabled) { g_cfgIncludePrereleases = enabled; }
bool GetShowBuiltInComponents() { return g_cfgShowBuiltIn.get(); }
void SetShowBuiltInComponents(bool enabled) { g_cfgShowBuiltIn = enabled; }

bool IsReplacementKept(std::string const& oldName, std::string const& newName) {
    std::string all = g_cfgKeptReplacements.get().c_str(), line = keptLine(oldName, newName);
    return all.rfind(line, 0) == 0 || all.find("\n" + line) != std::string::npos;
}

void SetReplacementKept(std::string const& oldName, std::string const& newName, bool kept) {
    std::string all = g_cfgKeptReplacements.get().c_str(), line = keptLine(oldName, newName);
    if (IsReplacementKept(oldName, newName) == kept) return;
    if (kept) {
        all += line;
    } else {
        size_t at = all.rfind(line, 0) == 0 ? 0 : all.find("\n" + line) + 1;
        all.erase(at, line.size());
    }
    g_cfgKeptReplacements = all.c_str();
}
