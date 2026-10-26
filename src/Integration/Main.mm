//
//  Main.mm
//  foo_component_updater_mac
//
//  Component registration: version, menu command, preferences page.
//

#include "../fb2k_sdk.h"
#include "../version.h"
#include "ComponentIds.h"
#include "../upstream/update_check.h"
#import "../UI/PreferencesController.h"
#include "../UI/UpdatesPage.h"

DECLARE_COMPONENT_VERSION(
    "Component Updater",
    FCU_VERSION,
    "Checks installed third party components for newer versions and shows the results. "
    "You choose which updates to install: each package is verified, the replaced version is kept for Restore Previous, "
    "and the change applies after a restart.\n"
    "\n"
    "Update logic ported from foo_component_update_checker by p2ashiura (MIT).\n"
    "(C) 2026 alies-dev\n"
    "Released under the MIT License.\n"
    "https://github.com/alies-dev/foo_component_updater_mac"
);

VALIDATE_COMPONENT_FILENAME("foo_component_updater_mac.component");

namespace {

class check_for_updates_command : public mainmenu_commands {
public:
    t_uint32 get_command_count() override { return 1; }

    GUID get_command(t_uint32) override { return fcu::guid_check_command; }

    void get_name(t_uint32, pfc::string_base& out) override { out = fcu::k_checkCommandName; }

    bool get_description(t_uint32, pfc::string_base& out) override {
        out = "Checks the third-party components you added for newer versions and installs the updates you choose. foobar2000 and its built in components update with foobar2000.";
        return true;
    }

    GUID get_parent() override { return mainmenu_groups::help; }

    void execute(t_uint32, service_ptr_t<service_base>) override {
        ShowUpdatesPage();
    }
};

FB2K_SERVICE_FACTORY(check_for_updates_command);

class component_updates_preferences_page : public preferences_page {
public:
    service_ptr instantiate() override {
        return fb2k::wrapNSObject([[FCUPreferencesController alloc] init]);
    }
    const char* get_name() override { return fcu::k_preferencesPageName; }
    GUID get_guid() override { return fcu::guid_preferences_page; }
    GUID get_parent_guid() override { return preferences_page::guid_tools; }
};

FB2K_SERVICE_FACTORY(component_updates_preferences_page);

} // namespace
