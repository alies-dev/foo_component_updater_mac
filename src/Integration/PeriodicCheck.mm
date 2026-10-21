//
//  PeriodicCheck.mm
//  foo_component_updater_mac
//

#include "../fb2k_sdk.h"
#include "../upstream/automatic_check.h"
#include "PeriodicCheck.h"

#include <atomic>

namespace {

const NSTimeInterval kPeriodSeconds = 6 * 60 * 60;

NSTimer *g_timer = nil;
#ifdef FCU_DEBUG_HOOKS
std::atomic<int> g_ticks{0};
#endif

NSTimeInterval period() {
#ifdef FCU_DEBUG_HOOKS
    // Debug builds: a shorter period for the test batch.
    pfc::string8 value = fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.recheck_seconds")->c_str();
    double seconds = atof(value.c_str());
    if (seconds > 0) return seconds;
#endif
    return kPeriodSeconds;
}

void start() {
    if (g_timer) return;
    g_timer = [NSTimer scheduledTimerWithTimeInterval:period() repeats:YES block:^(NSTimer *) {
#ifdef FCU_DEBUG_HOOKS
        ++g_ticks;
#endif
        // Same rules as the startup evaluation: enabled, interval elapsed, no running check, no open window.
        EvaluateAutomaticCheck();
    }];
    g_timer.tolerance = period() * 0.1;
}

class initquit_periodic_check : public initquit {
public:
    void on_init() override {
#ifdef FCU_DEBUG_HOOKS
        // The autotest starts the timer itself, at the point of its scenario.
        if (fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.autotest")->length() > 0) return;
#endif
        start();
    }

    void on_quit() override {
        [g_timer invalidate];
        g_timer = nil;
    }
};

FB2K_SERVICE_FACTORY(initquit_periodic_check);

} // namespace

#ifdef FCU_DEBUG_HOOKS
void DebugStartPeriodicCheck() { start(); }
int DebugPeriodicTicks() { return g_ticks.load(); }
#endif
