#include "Settings.h"

#include "../fb2k_sdk.h"

namespace {
// {5876B420-1282-464E-9CB9-7CF32156F4F5}
const GUID guid_cfg_include_prereleases =
{ 0x5876b420, 0x1282, 0x464e, { 0x9c, 0xb9, 0x7c, 0xf3, 0x21, 0x56, 0xf4, 0xf5 } };

// {03396D36-9ED8-4F2E-9DC8-B1A16C75EE5D}
const GUID guid_cfg_show_built_in =
{ 0x03396d36, 0x9ed8, 0x4f2e, { 0x9d, 0xc8, 0xb1, 0xa1, 0x6c, 0x75, 0xee, 0x5d } };

cfg_bool g_cfgIncludePrereleases(guid_cfg_include_prereleases, false);
cfg_bool g_cfgShowBuiltIn(guid_cfg_show_built_in, false);
}

bool GetIncludePrereleases() { return g_cfgIncludePrereleases.get(); }
void SetIncludePrereleases(bool enabled) { g_cfgIncludePrereleases = enabled; }
bool GetShowBuiltInComponents() { return g_cfgShowBuiltIn.get(); }
void SetShowBuiltInComponents(bool enabled) { g_cfgShowBuiltIn = enabled; }
