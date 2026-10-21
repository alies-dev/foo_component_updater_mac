//
//  AutoTest.mm
//  foo_component_updater_mac
//
//  Debug builds only. With the config key foo_component_updater_mac.debug.autotest
//  set to a file path, runs one check at startup without any UI and writes a JSON
//  log there (see Scripts/test_batch.sh). Compiled out of Release builds.
//

#include "../version.h"

#ifdef FCU_DEBUG_HOOKS

#include <algorithm>

#include "../fb2k_sdk.h"
#include "ComponentIds.h"
#include "Settings.h"
#include "../Platform/fcu_http.h"
#include "../UI/PreferencesController.h"
#include "../UI/ResultsWindow.h"
#include "../UI/DebugSnapshot.h"
#include "MenuTrigger.h"
#include "../Core/mapping_validation.h"
#include "../Core/package_layout.h"
#include "PeriodicCheck.h"
#include "../upstream/automatic_check.h"
#include "../upstream/repository_mapping.h"
#include "../upstream/update_check.h"
#include "../Platform/fcu_install.h"
#include "../upstream/third_party/nlohmann/json.hpp"

namespace {

using json = nlohmann::json;

const char* statusName(UpdateStatus s) {
    switch (s) {
    case UpdateStatus::UpdateAvailable: return "update_available";
    case UpdateStatus::UpToDate: return "up_to_date";
    case UpdateStatus::ComparisonUnsupported: return "unable_to_compare";
    case UpdateStatus::Error: return "error";
    case UpdateStatus::NoSource: return "no_source";
    }
    return "";
}

json settingsSnapshot() {
    json j;
    j["auto_check"] = GetAutomaticCheckEnabled();
    j["interval_days"] = GetAutomaticCheckIntervalDays();
    j["include_prereleases"] = GetIncludePrereleases();
    j["sources"] = loadRepositoryMapping().size();
    return j;
}

json registrations() {
    json j;
    j["menu"] = json::array();
    for (auto cmd : service_enum_t<mainmenu_commands>()) {
        for (t_uint32 i = 0; i < cmd->get_command_count(); ++i) {
            if (cmd->get_command(i) != fcu::guid_check_command) continue;
            pfc::string8 name;
            cmd->get_name(i, name);
            j["menu"].push_back({{"name", name.c_str()}, {"in_help_menu", cmd->get_parent() == mainmenu_groups::help}});
        }
    }
    j["preferences"] = json::array();
    for (auto page : service_enum_t<preferences_page>()) {
        if (page->get_guid() != fcu::guid_preferences_page) continue;
        j["preferences"].push_back({{"name", page->get_name()}, {"under_tools", page->get_parent_guid() == preferences_page::guid_tools}});
    }
    return j;
}

// Exercises the Apply path of the preferences page without showing it.
json applyChecks() {
    FCUPreferencesController *prefs = [[FCUPreferencesController alloc] init];
    (void)prefs.view;

    NSString *message = nil;
    BOOL validOk = [prefs applySourcesText:@"[{\"dll\": \"foo_autotest\", \"source\": \"github\", \"owner\": \"alies-dev\", \"repo\": \"foo_autotest\"}]" message:&message];
    size_t afterValid = loadRepositoryMapping().size();

    NSString *error = nil;
    BOOL invalidOk = [prefs applySourcesText:@"[{\"dll\": \"foo_autotest\", \"source\": \"nowhere\"}]" message:&error];
    size_t afterInvalid = loadRepositoryMapping().size();

    // The interval field: typed text commits when editing ends, invalid text is clamped or reverted,
    // and typed text is not lost to a stepper click.
    int savedDays = GetAutomaticCheckIntervalDays();
    json interval;
    interval["type_12"] = (int)[prefs debugTypeInterval:@"12"];
    interval["type_0"] = (int)[prefs debugTypeInterval:@"0"];
    interval["type_31"] = (int)[prefs debugTypeInterval:@"31"];
    interval["type_12_again"] = (int)[prefs debugTypeInterval:@"12"];
    interval["type_empty"] = (int)[prefs debugTypeInterval:@""];
    interval["empty_field_text"] = [prefs debugIntervalFieldText].UTF8String;
    interval["type_text"] = (int)[prefs debugTypeInterval:@"abc"];
    interval["type_12_step_up"] = (int)[prefs debugTypeThenStep:@"12" direction:1];
    [prefs debugTypeInterval:@"30"];
    interval["at_30_type_12_up"] = (int)[prefs debugTypeThenStep:@"12" direction:1];
    [prefs debugTypeInterval:@"1"];
    interval["at_1_type_12_down"] = (int)[prefs debugTypeThenStep:@"12" direction:-1];
    [prefs debugTypeInterval:@"30"];
    interval["at_30_type_junk_up"] = (int)[prefs debugTypeThenStep:@"x" direction:1];
    SetAutomaticCheckIntervalDays(savedDays);

    json j;
    j["interval"] = interval;
    j["valid_accepted"] = validOk == YES;
    j["entries_after_valid"] = afterValid;
    j["invalid_rejected"] = invalidOk == NO;
    j["invalid_message"] = error ? error.UTF8String : "";
    j["entries_after_invalid"] = afterInvalid;
    return j;
}

// Off screen renders of the preferences page and the results window (see Scripts/test_batch.sh).
json snapshots(std::vector<CheckResult> const& results) {
    json j;
    // Render the defaults, whatever earlier runs of the batch left in the profile; restored below.
    auto savedSources = loadRepositoryMapping();
    int savedDays = GetAutomaticCheckIntervalDays();
    bool savedPre = GetIncludePrereleases(), savedAuto = GetAutomaticCheckEnabled();
    saveRepositoryMapping({});
    SetAutomaticCheckIntervalDays(7);
    SetIncludePrereleases(false);
    SetAutomaticCheckEnabled(true);
    NSString *dir = @"/tmp/fcu-ui";
    FCUPreferencesController *prefs = [[FCUPreferencesController alloc] init];
    NSView *view = prefs.view;
    auto path = [&](char const* name) { return [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]]; };
    {
        BOOL emptyEnabled = NO, filledEnabled = YES;
        NSString *inserted = [prefs debugInsertExample:&emptyEnabled enabledWhenFilled:&filledEnabled];
        std::vector<RepositoryMappingEntry> parsed;
        std::string err;
        j["insert_example"] = {{"enabled_when_empty", emptyEnabled == YES}, {"disabled_when_filled", filledEnabled == NO},
                               {"parses", fcu::parseUserMappings(inserted.UTF8String, parsed, err) && parsed.size() == 1 && parsed[0].dllName == "foo_example"}};
    }
    j["prefs_geometry_collapsed"] = [prefs debugGeometry].UTF8String;
    j["prefs_light"] = DebugWriteSnapshot(view, NSAppearanceNameAqua, path("prefs-light.png"));
    j["prefs_dark"] = DebugWriteSnapshot(view, NSAppearanceNameDarkAqua, path("prefs-dark.png"));
    [prefs debugExpandAdvanced];
    j["prefs_geometry_expanded"] = [prefs debugGeometry].UTF8String;
    j["prefs_expanded"] = DebugWriteSnapshot(view, NSAppearanceNameAqua, path("prefs-expanded.png"));
    j["prefs_help_popover"] = DebugWriteSnapshot(FCUMakeHelpContentView(), NSAppearanceNameAqua, path("prefs-help-popover.png"));
    j["prefs_sources_popover"] = DebugWriteSnapshot(FCUMakeSourcesHelpContentView(), NSAppearanceNameAqua, path("prefs-sources-popover.png"));
    j["prefs_size"] = {view.frame.size.width, view.frame.size.height};
    j["results_default_rows"] = DebugSnapshotResultsWindow(results, false, path("results-default.png").UTF8String);
    j["results_layout"] = DebugLastResultsLayout();
    j["results_core_shown_rows"] = DebugSnapshotResultsWindow(results, true, path("results-core-shown.png").UTF8String);
    saveRepositoryMapping(savedSources);
    SetAutomaticCheckIntervalDays(savedDays);
    SetIncludePrereleases(savedPre);
    SetAutomaticCheckEnabled(savedAuto);
    return j;
}

void postMenuAction(char const* title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithUTF8String:title] action:nil keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Autotest"];
    [menu addItem:item];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSMenuDidSendActionNotification object:menu userInfo:@{@"MenuItem": item}];
}

void afterSeconds(double seconds, std::function<void()> next) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ next(); });
}

// Calls next once no check is running (bounded), then a moment later so window callbacks have landed.
void whenIdle(std::function<void()> next, int polls = 150) {
    if (IsUpdateCheckRunning() && polls > 0) {
        afterSeconds(0.2, [next, polls] { whenIdle(next, polls - 1); });
        return;
    }
    afterSeconds(0.3, next);
}

// The menu trigger and the periodic evaluation, with counters (see Scripts/test_batch_check.py, run "triggers").
// Runs only when foo_component_updater_mac.debug.recheck_seconds is set; restores the settings it touches.
void runTriggerScenario(std::shared_ptr<json> log, std::function<void()> done) {
    pfc::string8 recheck = fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.recheck_seconds")->c_str();
    double period = atof(recheck.c_str());
    if (period <= 0) { done(); return; }

    auto state = std::make_shared<json>();
    auto begun0 = std::make_shared<int>(0);
    auto handled0 = std::make_shared<int>(0);
    auto ticks0 = std::make_shared<int>(0);
    bool savedAuto = GetAutomaticCheckEnabled();
    int savedDays = GetAutomaticCheckIntervalDays();

    auto finish = [=] {
        SetAutomaticCheckEnabled(savedAuto);
        SetAutomaticCheckIntervalDays(savedDays);
        (*log)["triggers"] = *state;
        done();
    };

    // 4. Two evaluations back to back with a due check: the second must not start a concurrent check.
    auto concurrent = [=] {
        DebugCloseResultsWindow();
        DebugSetAutomaticCheckLastRun((int64_t)time(nullptr) - 3 * 86400);
        *begun0 = DebugChecksBegun();
        bool first = EvaluateAutomaticCheck();
        bool second = EvaluateAutomaticCheck();
        (*state)["concurrent"] = {{"first_started", first}, {"second_started", second}, {"running_after", IsUpdateCheckRunning()}};
        whenIdle([=] {
            (*state)["concurrent"]["begun_delta"] = DebugChecksBegun() - *begun0;
            DebugCloseResultsWindow();
            finish();
        });
    };

    // 4d. A window attached to an automatic check and then closed must not be recreated when that check completes.
    auto dismiss = [=] {
        DebugCloseResultsWindow();
        DebugSetAutomaticCheckLastRun((int64_t)time(nullptr) - 3 * 86400);
        *begun0 = DebugChecksBegun();
        bool started = EvaluateAutomaticCheck();
        postMenuAction("Check For New Versions");
        afterSeconds(0.02, [=] {
            bool attachedBefore = false;
            long rowsBefore = DebugResultsWindowRows(&attachedBefore);
            DebugCloseResultsWindow();
            bool runningAfterClose = IsUpdateCheckRunning();
            // Reopen and close again while the same check still runs: it attaches to that check (no second
            // one can begin until it is delivered), and the second close dismisses it again.
            postMenuAction("Check For New Versions");
            afterSeconds(0.02, [=] {
            bool reopenedAttached = false;
            long reopenedRows = DebugResultsWindowRows(&reopenedAttached);
            DebugCloseResultsWindow();
            whenIdle([=] {
                bool a = false;
                long rowsAfter = DebugResultsWindowRows(&a);
                (*state)["dismiss"] = {{"reopened_attached_to_same_check", reopenedRows >= 0 && reopenedAttached},{"auto_started", started}, {"window_attached_before_close", rowsBefore >= 0 && attachedBefore},
                                       {"running_after_close", runningAfterClose}, {"window_open_after_completion", rowsAfter >= 0},
                                       {"begun_delta", DebugChecksBegun() - *begun0}};
                concurrent();
            });
            });
        });
    };

    // 4c. A manual check whose window is closed and reopened: the new window gets the results.
    auto reopen = [=] {
        DebugCloseResultsWindow();
        *begun0 = DebugChecksBegun();
        postMenuAction("Check For New Versions");
        afterSeconds(0.02, [=] {
            bool ownerAttached = true;
            long ownerRows = DebugResultsWindowRows(&ownerAttached);
            DebugCloseResultsWindow();
            postMenuAction("Check For New Versions");
            afterSeconds(0.02, [=] {
                bool attachedWhileRunning = false;
                long rowsWhileRunning = DebugResultsWindowRows(&attachedWhileRunning);
                bool running = IsUpdateCheckRunning();
                whenIdle([=] {
                    bool attachedAfter = true;
                    long rowsAfter = DebugResultsWindowRows(&attachedAfter);
                    (*state)["reopen"] = {{"first_window_owned_check", ownerRows >= 0 && !ownerAttached}, {"running_when_reopened", running},
                                          {"reopened_attached", rowsWhileRunning >= 0 && attachedWhileRunning},
                                          {"rows_after", rowsAfter}, {"attached_after", attachedAfter},
                                          {"begun_delta", DebugChecksBegun() - *begun0}};
                    dismiss();
                });
            });
        });
    };

    // 4b. A window opened while an automatic check runs attaches to it: no second check, results appear when it ends.
    auto attach = [=] {
        DebugCloseResultsWindow();
        DebugSetAutomaticCheckLastRun((int64_t)time(nullptr) - 3 * 86400);
        *begun0 = DebugChecksBegun();
        bool started = EvaluateAutomaticCheck();
        postMenuAction("Check For New Versions");
        afterSeconds(0.05, [=] {
            bool attachedWhileRunning = false;
            long rowsWhileRunning = DebugResultsWindowRows(&attachedWhileRunning);
            bool runningThen = IsUpdateCheckRunning();
            // Toggling "Show built in components" must not replace the waiting message.
            std::string statusBefore = DebugResultsStatus();
            DebugToggleBuiltIn();
            std::string statusAfter = DebugResultsStatus();
            DebugToggleBuiltIn();
            bool statusKept = !statusBefore.empty() && statusBefore == statusAfter && DebugResultsStatus() == statusBefore;
            whenIdle([=] {
                bool attachedAfter = true;
                long rowsAfter = DebugResultsWindowRows(&attachedAfter);
                (*state)["attach"] = {{"status_kept_on_toggle", statusKept}, {"waiting_status", statusBefore},{"auto_started", started}, {"running_when_window_opened", runningThen},
                                      {"window_open_while_running", rowsWhileRunning >= 0}, {"attached_while_running", attachedWhileRunning},
                                      {"rows_after", rowsAfter}, {"attached_after", attachedAfter},
                                      {"begun_delta", DebugChecksBegun() - *begun0}};
                reopen();
            });
        });
    };

    // 3. The periodic timer with the interval elapsed: exactly one more check, ticks keep firing.
    auto periodic = [=] {
        DebugCloseResultsWindow();
        SetAutomaticCheckEnabled(true);
        SetAutomaticCheckIntervalDays(1);
        DebugSetAutomaticCheckLastRun((int64_t)time(nullptr) - 3 * 86400);
        *begun0 = DebugChecksBegun();
        *ticks0 = DebugPeriodicTicks();
        DebugStartPeriodicCheck();
        afterSeconds(period * 2 + 1.5, [=] {
            whenIdle([=] {
                (*state)["periodic"] = {{"begun_delta", DebugChecksBegun() - *begun0}, {"ticks_delta", DebugPeriodicTicks() - *ticks0},
                                        {"window_open", IsResultsWindowOpen()}};
                attach();
            });
        });
    };

    // 2. The Help menu title, with the window already open but idle.
    auto helpTitle = [=] {
        *begun0 = DebugChecksBegun();
        *handled0 = DebugMenuTriggersHandled();
        postMenuAction("Check for new foobar2000 versions");
        afterSeconds(0.5, [=] {
            whenIdle([=] {
                (*state)["menu_help"] = {{"begun_delta", DebugChecksBegun() - *begun0}, {"handled_delta", DebugMenuTriggersHandled() - *handled0}};
                periodic();
            });
        });
    };

    // 1. The app menu title twice in a row plus an unrelated title: one check, two handled, one ignored.
    *begun0 = DebugChecksBegun();
    *handled0 = DebugMenuTriggersHandled();
    DebugSetAutomaticCheckLastRun(1); // a manual check must record its completion time
    postMenuAction("Check For New Versions");
    postMenuAction("Check For New Versions");
    postMenuAction("Check for Component Updates...");
    afterSeconds(0.5, [=] {
        whenIdle([=] {
            (*state)["menu_app"] = {{"begun_delta", DebugChecksBegun() - *begun0}, {"handled_delta", DebugMenuTriggersHandled() - *handled0},
                                    {"last_check_recorded", GetAutomaticCheckLastRun() > (int64_t)time(nullptr) - 120}};
            helpTitle();
        });
    });
}

void writeLog(std::string const& path, json const& log) {
    @autoreleasepool {
        std::string text = log.dump(2);
        NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
        [data writeToFile:[NSString stringWithUTF8String:path.c_str()] atomically:YES];
    }
}

json stateOf(std::string const& name, std::string* version = nullptr) {
    std::string backup;
    json j = {{"pid", getpid()}, {"installed_version", ""}, {"staged", fcu::isStaged(name)}};
    j["backup_version"] = fcu::backupVersion(name, backup) ? backup : "";
    for (auto const& c : GetInstalledComponents()) {
        if (c.fileName != name) continue;
        j["installed_version"] = c.installedVersion;
        if (version) *version = c.installedVersion;
    }
    return j;
}

// The install scenarios of `test_batch.sh m2`, one foobar2000 run each (config key foo_component_updater_mac.debug.m2).
// Packages come from the stub (/pkg/<name>). install and restore end in main_restart(): they set the scenario
// of the next run and its log path (this one with the scenario name swapped) before restarting.
void runInstallScenario(std::string const& path, std::string const& scenario) {
    auto log = std::make_shared<json>();
    auto version = std::make_shared<std::string>();
    (*log)["scenario"] = scenario;
    (*log)["before"] = stateOf("foo_abx", version.get());
    auto installed = GetInstalledComponents();
    auto results = std::make_shared<std::vector<CheckResult>>();

    fb2k::splitTask([=] {
      try {
        abort_callback& abort = fb2k::mainAborter();
        auto attempt = [&](std::string const& what, std::string const& url) {
            fcu::InstallOutcome o = url.empty() ? fcu::restorePrevious("foo_abx", *version, abort) : fcu::installUpdate("foo_abx", *version, url, abort);
            (*log)["outcomes"][what] = {{"ok", o.ok}, {"message", o.message}};
        };
        auto pkg = [](char const* name) { return fcu::endpoint("", std::string("/pkg/") + name); };
        std::string next;
        if (scenario == "install") {
            for (auto const& r : RunUpdateCheck(installed, abort)) {
                if (r.dllName != "foo_abx") continue;
                (*log)["row"] = {{"status", statusName(r.status)}, {"installed", r.installedVersion}, {"latest", r.latestVersion},
                                 {"block_reason", fcu::installBlockReason(r.status == UpdateStatus::UpdateAvailable, r.dllName, r.downloadUrl, r.assetName, fcu::isStaged(r.dllName))}};
                attempt("install", r.downloadUrl);
            }
            next = "restore";
        } else if (scenario == "restore") {
            attempt("restore", "");
            next = "refuse";
        } else if (scenario == "refuse") {
            for (char const* name : {"tampered", "wrongid", "zipslip", "nomac", "notzip", "missing"}) attempt(name, pkg(name));
            *results = RunUpdateCheck(installed, abort);
        } else {
            attempt("other_developer", pkg("good"));
            attempt("same_developer", pkg("devid"));
        }
        fb2k::inMainThread([=] {
            (*log)["after"] = stateOf("foo_abx");
            if (scenario == "refuse") {
                bool withBackup = false, without = true;
                std::string title = DebugRestoreMenuItem(*results, "foo_abx", &withBackup);
                (*log)["restore_menu"] = {{"title", title}, {"enabled", withBackup}, {"title_without_backup", DebugRestoreMenuItem(*results, "foo_jl_spectrum", &without)}, {"enabled_without_backup", without}};
            }
            writeLog(path, *log);
            if (next.empty()) return;
            std::string nextPath = path;
            nextPath.replace(nextPath.rfind(scenario), scenario.size(), next);
            fb2k::configStore::get()->setConfigString("foo_component_updater_mac.debug.m2", next.c_str());
            fb2k::configStore::get()->setConfigString("foo_component_updater_mac.debug.autotest", nextPath.c_str());
            // Long enough for the batch to look at what the process has mapped.
            afterSeconds(5, [] { standard_commands::main_restart(); });
        });
      } catch (std::exception const&) {
        // Nothing may escape into foobar2000; the batch reports the missing log.
      }
    });
}

class initquit_autotest : public initquit {
public:
    void on_init() override {
        pfc::string8 pathValue = fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.autotest")->c_str();
        if (pathValue.length() == 0) return;
        std::string path = pathValue.c_str();
        pfc::string8 scenario = fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.m2")->c_str();
        if (scenario.length() > 0) {
            runInstallScenario(path, scenario.c_str());
            return;
        }

        DebugSetResultsWindowOffscreen(true);
        auto log = std::make_shared<json>();
        (*log)["version"] = FCU_VERSION;
        (*log)["registered"] = registrations();
        (*log)["settings_at_start"] = settingsSnapshot();
        auto installed = GetInstalledComponents();

        fb2k::splitTask([log, installed, path] {
          try {
            std::vector<CheckResult> results = RunUpdateCheck(installed, fb2k::mainAborter());

            json rows = json::array();
            for (auto const& r : results) {
                rows.push_back({
                    {"component", r.dllName}, {"name", r.displayName}, {"installed", r.installedVersion},
                    {"latest", r.latestVersion}, {"status", statusName(r.status)}, {"origin", r.sourceOrigin},
                    {"source", r.sourceLabel}, {"release_url", r.releaseUrl}, {"download_url", r.downloadUrl},
                    {"error", r.errorMessage}, {"note", r.note}});
            }
            (*log)["rows"] = rows;
            (*log)["requests"] = fcu::requestLog();

            // A rate limit must hold across "Check Again": repeat the check and log what it requested.
            bool limited = std::any_of(results.begin(), results.end(), [](CheckResult const& r) {
                return r.errorMessage.rfind("GitHub rate limit reached", 0) == 0;
            });
            if (limited) {
                size_t before = fcu::requestLog().size();
                std::vector<CheckResult> again = RunUpdateCheck(installed, fb2k::mainAborter());
                std::vector<std::string> all = fcu::requestLog();
                (*log)["second_check_requests"] = std::vector<std::string>(all.begin() + before, all.end());
                (*log)["second_check_limited_rows"] = std::count_if(again.begin(), again.end(), [](CheckResult const& r) {
                    return r.errorMessage.rfind("GitHub rate limit reached", 0) == 0;
                });
            }

            fb2k::inMainThread([log, path, results] {
              auto finish = [log, path, results] {
                // Measure both states explicitly, whatever the user saved for "Show built in components".
                bool savedShowBuiltIn = GetShowBuiltInComponents();
                size_t visible = 0, visibleShown = 0;
                SetShowBuiltInComponents(false);
                size_t cells = DebugRealiseResultsWindow(results, &visible);
                SetShowBuiltInComponents(true);
                size_t cellsShown = DebugRealiseResultsWindow(results, &visibleShown);
                SetShowBuiltInComponents(savedShowBuiltIn);
                (*log)["results_window"] = {{"rows", results.size()}, {"visible_rows", visible}, {"cells", cells},
                    {"visible_rows_shown", visibleShown}, {"cells_shown", cellsShown},
                    {"built_in_rows", std::count_if(results.begin(), results.end(), [](CheckResult const& r) { return r.dllName == "Core"; })}};
                (*log)["snapshots"] = snapshots(results);
                (*log)["apply"] = applyChecks();
                SetAutomaticCheckIntervalDays(11);
                SetIncludePrereleases(true);
                (*log)["settings_set"] = settingsSnapshot();
                writeLog(path, *log);
              };
              runTriggerScenario(log, finish);
            });
          } catch (std::exception const&) {
            // Nothing may escape into foobar2000; the batch reports the missing log.
          }
        });
    }
};

FB2K_SERVICE_FACTORY(initquit_autotest);

} // namespace

#endif // FCU_DEBUG_HOOKS
