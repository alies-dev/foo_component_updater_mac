//
//  MenuTrigger.mm
//  foo_component_updater_mac
//
//  Runs our check when the user chooses foobar2000's own "Check For New Versions".
//  foobar2000 has no SDK hook for its core update check, so this observes
//  NSMenuDidSendActionNotification and matches the menu item title (see
//  docs/sdk-quirks.md). It stops working silently if foobar2000 renames the items.
//

#include "../fb2k_sdk.h"
#include "../Core/triggers.h"
#include "../UI/ResultsWindow.h"
#include "../upstream/update_check.h"
#include "MenuTrigger.h"

#include <atomic>

namespace {

id g_observer = nil;
#ifdef FCU_DEBUG_HOOKS
std::atomic<int> g_handled{0};
#endif

class initquit_menu_trigger : public initquit {
public:
    void on_init() override {
        g_observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSMenuDidSendActionNotification object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                NSMenuItem *item = note.userInfo[@"MenuItem"];
                if (![item isKindOfClass:[NSMenuItem class]] || !item.title) return;
                if (!fcu::isCoreUpdateMenuTitle(item.title.UTF8String)) return;
                if (fb2k::mainAborter().is_aborting()) return;
#ifdef FCU_DEBUG_HOOKS
                ++g_handled;
#endif
                // Same as Help > Check for Component Updates...; a running check only brings the window forward.
                ShowUpdateResultWindow();
            }];
    }

    void on_quit() override {
        if (g_observer) [[NSNotificationCenter defaultCenter] removeObserver:g_observer];
        g_observer = nil;
    }
};

FB2K_SERVICE_FACTORY(initquit_menu_trigger);

} // namespace

#ifdef FCU_DEBUG_HOOKS
int DebugMenuTriggersHandled() { return g_handled.load(); }
#endif
