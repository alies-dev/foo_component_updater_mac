#pragma once

#include "../fb2k_sdk.h"

namespace fcu {

// {A644A9BE-C195-4FCE-B137-9E11115D093B}
inline const GUID guid_check_command =
{ 0xa644a9be, 0xc195, 0x4fce, { 0xb1, 0x37, 0x9e, 0x11, 0x11, 0x5d, 0x9, 0x3b } };

// {72BEC33E-ADF8-40D7-8EA2-BDCEF7A8E2A3}
inline const GUID guid_preferences_page =
{ 0x72bec33e, 0xadf8, 0x40d7, { 0x8e, 0xa2, 0xbd, 0xce, 0xf7, 0xa8, 0xe2, 0xa3 } };

inline const char* const k_checkCommandName = "Check for Component Updates...";
inline const char* const k_preferencesPageName = "Component Updates";

} // namespace fcu
