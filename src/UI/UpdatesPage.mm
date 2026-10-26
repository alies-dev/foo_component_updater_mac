#include "UpdatesPage.h"

#include "../fb2k_sdk.h"

#include <algorithm>

#include "../Integration/ComponentIds.h"
#include "../Integration/MigrationNotes.h"
#include "../Integration/Settings.h"
#include "../upstream/automatic_check.h"
#include "DebugSnapshot.h"
#include "PreferencesController.h"
#include "../Core/package_layout.h"
#include "../Core/replacement.h"
#include "../Platform/fcu_install.h"

NSNotificationName const FCUUpdateCheckCompletedNotification = @"FCUUpdateCheckCompleted";

namespace {

NSNotificationName const kRowsChanged = @"FCUUpdatesRowsChanged";   // the rows were rebuilt or re-sorted
NSNotificationName const kStateChanged = @"FCUUpdatesStateChanged"; // status line, ticks or running state changed

NSString *const kNoCheckYet = @"Click Check Now to look for updates.";
NSString *const kNoComponents = @"No installed components were found.";

NSString *ns(std::string const& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

// Text from a remote source in a dialog that asks for consent: printable ASCII only (no line or direction
// controls that could fake a line), cut at `limit` characters.
NSString *plain(std::string const& s, size_t limit = 40) {
    std::string out;
    for (char c : s) {
        if (c >= 0x20 && c < 0x7f) out += c;
    }
    if (out.size() > limit) out = out.substr(0, limit) + "...";
    return ns(out);
}

// "2 Oct 2026" style in the user's locale; "" when GitHub gave no usable date.
NSString *releasedText(std::string const& iso) {
    static NSISO8601DateFormatter *parser = [NSISO8601DateFormatter new];
    static NSDateFormatter *formatter = [] {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateStyle = NSDateFormatterMediumStyle;
        f.timeStyle = NSDateFormatterNoStyle;
        return f;
    }();
    NSDate *date = iso.empty() ? nil : [parser dateFromString:ns(iso)];
    return date ? [formatter stringFromDate:date] : @"";
}

int statusRank(UpdateStatus s) {
    switch (s) {
    case UpdateStatus::UpdateAvailable: return 0;
    case UpdateStatus::Replaced: return 1;
    case UpdateStatus::Error: return 2;
    case UpdateStatus::ComparisonUnsupported: return 3;
    case UpdateStatus::UpToDate: return 4;
    case UpdateStatus::NoSource: return 5;
    }
    return 6;
}

// The Status column, like foobar2000's own list: what the check found, with the version when there is one.
NSString *statusText(CheckResult const& r) {
    NSString *latest = ns(r.latestVersion);
    switch (r.status) {
    case UpdateStatus::UpdateAvailable: {
        // A version like "2.0.0-beta" already says so; only a plain number gets the mark.
        bool marked = r.prerelease && r.latestVersion.find('-') == std::string::npos;
        return [NSString stringWithFormat:@"%@ available%@", latest, marked ? @" (beta)" : @""];
    }
    case UpdateStatus::UpToDate: return @"Up to date";
    case UpdateStatus::ComparisonUnsupported:
        return latest.length ? [NSString stringWithFormat:@"Unable to compare (%@)", latest] : @"Unable to compare";
    case UpdateStatus::Error: return @"Error";
    case UpdateStatus::NoSource: return @"No source";
    case UpdateStatus::Replaced:
        if (r.replacementInstalled && !r.replacedByFoobar2000) return [NSString stringWithFormat:@"Replaced by %@ (installed)", ns(r.replacedBy)];
        return [[NSString stringWithFormat:@"Replaced by %@ %@", ns(r.replacedBy), latest] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return @"";
}

// foobar2000 itself is no component: it is never staged, so it is never looked up as one.
bool successorIsFoobar2000(CheckResult const& r) {
    return r.replacedBy == fcu::kFoobar2000;
}

// The successor of a Replaced row is installed, or staged by an earlier switch or by foobar2000: switching only removes.
bool successorPresent(CheckResult const& r) {
    if (successorIsFoobar2000(r)) return r.replacedByFoobar2000;
    return r.replacementInstalled || fcu::isStaged(r.replacedBy);
}

bool successorRemovalStaged(CheckResult const& r) {
    return !successorIsFoobar2000(r) && fcu::isRemovalStaged(r.replacedBy);
}

struct Operation {
    std::string name, installedVersion, url; // url empty: restore the backup (unless replacement is set)
    std::string replacement;                 // set: switch to that component (url may be empty when it is installed)
    std::string team, migration;             // of a switch: declared Team ID and migration notes page, "" when none
    bool removeOnly = false;                 // foobar2000 replaced the component: stage the removal, replacement is "foobar2000"
};

#ifdef FCU_DEBUG_HOOKS
std::string g_lastLayout;
// The autotest never opens Preferences and never runs a modal dialog.
bool g_offscreen = false;
#endif
bool confirmsModally() {
#ifdef FCU_DEBUG_HOOKS
    return !g_offscreen;
#else
    return true;
#endif
}

} // namespace

@interface FCUUpdateRow : NSObject
@property (copy) NSString *displayName, *installed, *module, *status, *statusTip, *releaseUrl, *about;
@property (copy) NSString *file, *blockReason, *backupVersion; // file name (the row's key), why not installable ("" when it is), backup version ("" when none)
@property (copy) NSString *latest, *replacedBy, *overlap;      // see CheckResult; "" when none
@property NSInteger statusOrder;                               // statusRank; sort key of the Status column
@property UpdateStatus statusCode;
@property BOOL builtIn, staged, failed, replacementInstalled, kept, replacedByFoobar2000;
@end
@implementation FCUUpdateRow
@end

// The update list of the whole process, on the main thread. Preferences page view controllers come and go as the
// user navigates, so the results, ticks, running check and install live here, not in them.
@interface FCUUpdatesModel : NSObject
@property (nonatomic) int64_t checkId;          // the check this page runs or waits for (CurrentUpdateCheckId)
@property (nonatomic) int64_t dismissedCheckId; // the check running when the user left the page: its completion must not show it again
@property (nonatomic) BOOL checking, attached, visible, installing;
@property (nonatomic, copy) NSString *status;
@property (nonatomic, copy) NSArray<FCUUpdateRow *> *rows;
@property (nonatomic, copy) NSArray<NSSortDescriptor *> *sortDescriptors;
@property (nonatomic, readonly) NSMutableSet<NSString *> *checked; // file names of the rows ticked for install
@property (nonatomic, readonly) BOOL canInstall;
- (void)showResults:(std::vector<CheckResult> const &)results emptyMessage:(NSString *)message;
- (void)finishCheckWithResults:(std::vector<CheckResult> const &)results emptyMessage:(NSString *)message;
- (void)runCheck;
- (void)setShowBuiltIn:(BOOL)show;
- (void)setChecked:(BOOL)checked forFile:(NSString *)file;
- (void)resort;
- (void)pageDidHide;
- (void)installChecked;
- (NSAlert *)switchConfirmation;
- (NSMenuItem *)restoreItemForRow:(FCUUpdateRow *)row;
- (NSMenuItem *)keepItemForRow:(FCUUpdateRow *)row;
#ifdef FCU_DEBUG_HOOKS
- (NSMenuItem *)debugRestoreItemForName:(NSString *)name;
- (void)debugCheckFirstInstallable;
#endif
@end

@implementation FCUUpdatesModel {
    std::vector<CheckResult> _results;
    NSMutableDictionary<NSString *, NSString *> *_failures; // last install error per component
    NSString *_emptyMessage;
    NSArray<NSURL *> *_migrationLinks; // links of the open switch confirmation, by button tag
}

- (instancetype)init {
    if ((self = [super init])) {
        _rows = @[];
        _sortDescriptors = @[];
        _checked = [NSMutableSet set];
        _failures = [NSMutableDictionary dictionary];
        _emptyMessage = kNoCheckYet;
        [self rebuildRows];
    }
    return self;
}

- (BOOL)canInstall {
    return !_checking && !_installing && _checked.count > 0;
}

- (void)stateChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:kStateChanged object:self];
}

- (void)setStatus:(NSString *)text {
    _status = [text copy];
    [self stateChanged];
}

// Waits for the check that holds the slot; DeliverCheckResults hands its results to the model.
- (void)attachToRunningCheck {
    _attached = YES;
    _checkId = CurrentUpdateCheckId();
    _checking = YES;
    [self setStatus:@"A check is already running in the background. Its results will appear here when it finishes."];
}

// The page became visible. A check that started while it was away (e.g. the automatic one) is attached to,
// never restarted. An install also holds the check slot, but the page already shows it.
- (void)pageDidShow {
    _visible = YES;
    if (_installing || !IsUpdateCheckRunning()) return;
    if (_checking && _checkId == CurrentUpdateCheckId()) return;
    [self attachToRunningCheck];
}

- (void)runCheck {
    if (_installing) {
        [self setStatus:@"An install is running. Check again when it has finished."];
        return;
    }
    // One check at a time for the whole process (the automatic check shares the flag).
    if (!TryBeginUpdateCheck()) {
        // Attach to the check that is running, manual or automatic: DeliverCheckResults hands
        // its results to the model, so nothing is started twice.
        [self attachToRunningCheck];
        return;
    }
    _attached = NO;
    _checking = YES;
    const int64_t checkId = _checkId = CurrentUpdateCheckId();
    [self setStatus:@"Starting..."];
    // Enumerated here, on the main thread, once this page owns the check slot.
    std::vector<InstalledComponentInfo> installed = GetInstalledComponents();

    fb2k::splitTask([installed, checkId, model = self] {
      try {
        abort_callback& abort = fb2k::mainAborter();
        std::vector<CheckResult> results = RunUpdateCheck(installed, abort, [checkId, model](std::string const& message) {
            fb2k::inMainThread([message, checkId, model] {
                if (fb2k::mainAborter().is_aborting() || model.checkId != checkId || !model.checking) return;
                [model setStatus:ns(message)];
            });
        });
        // The check stays active until the main thread delivered its results.
        fb2k::inMainThread([results, checkId] {
            if (fb2k::mainAborter().is_aborting()) { EndUpdateCheck(); return; }
            MarkCheckCompletedNow();
            DeliverCheckResults(checkId, results, "", false);
        });
      } catch (std::exception const&) {
        // RunUpdateCheck reports its own failures; nothing may escape into foobar2000.
        fb2k::inMainThread([checkId] { DeliverCheckResults(checkId, {}, "", false); });
      }
    });
}

- (void)finishCheckWithResults:(std::vector<CheckResult> const &)results emptyMessage:(NSString *)message {
    _attached = NO;
    _checking = NO;
    [self showResults:results emptyMessage:message];
}

- (void)showResults:(std::vector<CheckResult> const &)results emptyMessage:(NSString *)message {
    _results = results;
    _emptyMessage = [message copy];
    [_checked removeAllObjects];
    [_failures removeAllObjects];
    [self rebuildRows];
}

- (void)setShowBuiltIn:(BOOL)show {
    SetShowBuiltInComponents(show);
    [self rebuildRows];
}

// The user left the page while a check ran: that check's completion must not show it again.
- (void)pageDidHide {
    if (!_visible) return;
    _visible = NO;
    if (IsUpdateCheckRunning()) _dismissedCheckId = CurrentUpdateCheckId();
}

// Rows are rebuilt from the stored results; built in components (file name "Core") only when asked for.
- (void)rebuildRows {
    bool showBuiltIn = GetShowBuiltInComponents();
    std::vector<CheckResult const *> sorted;
    for (auto const &r : _results) {
        if (r.dllName == "Core" && !showBuiltIn) continue;
        sorted.push_back(&r);
    }
    std::stable_sort(sorted.begin(), sorted.end(), [](CheckResult const *a, CheckResult const *b) {
        return statusRank(a->status) < statusRank(b->status);
    });

    NSMutableArray<FCUUpdateRow *> *rows = [NSMutableArray array];
    int updates = 0, replaced = 0, errors = 0;
    NSString *rateLimit = nil;
    for (CheckResult const *r : sorted) {
        FCUUpdateRow *row = [FCUUpdateRow new];
        row.displayName = ns(r->displayName);
        row.installed = ns(r->installedVersion);
        row.file = row.module = ns(r->dllName);
        row.builtIn = r->dllName == "Core";
        row.latest = ns(r->latestVersion);
        row.statusOrder = statusRank(r->status);
        row.about = ns(r->about);
        row.status = statusText(*r);
        row.statusCode = r->status;
        // What the status adds, one item per line: release facts first, then the row's note or error.
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSString *released = releasedText(r->releasedAt);
        if (released.length) [lines addObject:[@"Released " stringByAppendingString:released]];
        if (!r->sourceOrigin.empty()) [lines addObject:[NSString stringWithFormat:@"From %@ (%@)", ns(r->sourceLabel), ns(r->sourceOrigin)]];
        if (r->prerelease) [lines addObject:@"The author marked this release as a prerelease. It may be less stable."];
        if (!r->releaseNotes.empty()) [lines addObject:ns(r->releaseNotes)];
        NSString *detail = r->status != UpdateStatus::Error ? ns(r->note)
            : r->note.empty() ? ns(r->errorMessage) : [NSString stringWithFormat:@"%@\n%@", ns(r->errorMessage), ns(r->note)];
        row.overlap = ns(r->overlap);
        if (row.overlap.length) detail = detail.length ? [NSString stringWithFormat:@"%@\n%@", row.overlap, detail] : row.overlap;
        row.releaseUrl = [ns(r->releaseUrl) hasPrefix:@"https://"] ? ns(r->releaseUrl) : @"";
        row.replacedBy = ns(r->replacedBy);
        row.replacementInstalled = successorPresent(*r);
        row.replacedByFoobar2000 = r->replacedByFoobar2000;
        row.kept = r->kept;
        row.staged = fcu::isStaged(r->dllName) || fcu::isRemovalStaged(r->dllName);
        bool const switching = r->status == UpdateStatus::Replaced;
        // With the successor installed or staged, switching only removes this component: nothing to download.
        row.blockReason = switching && successorRemovalStaged(*r) ? [NSString stringWithFormat:@"%@ is being removed; restart foobar2000 first", ns(r->replacedBy)]
            : switching && row.replacementInstalled ? (row.staged ? @"Restart foobar2000 to finish" : @"")
            : ns(fcu::installBlockReason(r->status == UpdateStatus::UpdateAvailable || switching, r->dllName, r->downloadUrl, r->assetName, row.staged));
        std::string backup;
        row.backupVersion = r->dllName != "Core" && fcu::backupVersion(r->dllName, backup) ? ns(backup) : @"";
        if (row.staged) {
            row.status = @"Restart to finish";
        } else if (NSString *why = _failures[row.file]) {
            row.status = @"Install failed";
            detail = why;
            row.failed = YES;
        }
        if (detail.length) [lines addObject:detail];
        row.statusTip = [lines componentsJoinedByString:@"\n"];
        if (row.overlap.length) row.status = [@"⚠ " stringByAppendingString:row.status];
        // Like the native list, built in components show nothing in Status; the tooltip still carries the note.
        if (row.builtIn) row.status = @"";
        if (r->status == UpdateStatus::UpdateAvailable) ++updates;
        if (r->status == UpdateStatus::Replaced) ++replaced;
        if (r->status == UpdateStatus::Error) {
            ++errors;
            if (!rateLimit && r->errorMessage.rfind("GitHub rate limit reached", 0) == 0) rateLimit = ns(r->errorMessage);
        }
        [rows addObject:row];
    }
    _rows = [rows sortedArrayUsingDescriptors:_sortDescriptors]; // keeps the order the user clicked

    // While a check or an install runs the status line shows its progress; toggling the checkbox only rebuilds the rows.
    if (!_checking && !_installing) {
        if (_results.empty()) {
            _status = _emptyMessage;
        } else if (rateLimit) {
            _status = rateLimit;
        } else {
            NSString *text = [NSString stringWithFormat:@"%d update%s available, %d error%s", updates, updates == 1 ? "" : "s", errors, errors == 1 ? "" : "s"];
            if (replaced) text = [text stringByAppendingFormat:@", %d replaced", replaced];
            _status = text;
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kRowsChanged object:self];
}

- (void)resort {
    _rows = [_rows sortedArrayUsingDescriptors:_sortDescriptors];
    [[NSNotificationCenter defaultCenter] postNotificationName:kRowsChanged object:self];
}

- (void)setChecked:(BOOL)checked forFile:(NSString *)file {
    if (checked) [_checked addObject:file]; else [_checked removeObject:file];
    [self stateChanged];
}

- (void)installChecked {
    std::vector<Operation> jobs;
    for (CheckResult const &r : _results) {
        if (![_checked containsObject:ns(r.dllName)]) continue;
        if (r.status != UpdateStatus::Replaced) {
            jobs.push_back({r.dllName, r.installedVersion, r.downloadUrl, "", "", ""});
        } else {
            jobs.push_back({r.dllName, r.installedVersion, successorPresent(r) ? "" : r.downloadUrl, r.replacedBy, r.replacementTeam, r.migration, r.replacedByFoobar2000});
        }
    }
    // A switch removes a component, so it is confirmed; plain updates are not.
    NSAlert *alert = [self switchConfirmation];
    if (alert && confirmsModally()) {
        NSModalResponse answer = [alert runModal];
        _migrationLinks = nil;
        if (answer != NSAlertFirstButtonReturn) return;
    }
    [self runOperations:jobs];
}

// The confirmation for the ticked Replaced rows, nil when there are none. Its migration links stay valid until
// _migrationLinks is cleared.
- (NSAlert *)switchConfirmation {
    NSMutableArray<NSString *> *switches = [NSMutableArray array];
    NSMutableArray<NSURL *> *notes = [NSMutableArray array];
    NSMutableArray<NSString *> *noteTitles = [NSMutableArray array];
    CheckResult const *only = nullptr;
    for (CheckResult const &r : _results) {
        if (![_checked containsObject:ns(r.dllName)] || r.status != UpdateStatus::Replaced) continue;
        only = &r;
        // One fact per line, the source on its own: a remote version string cannot run into it.
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
            [NSString stringWithFormat:@"%@ %@ will be removed.", ns(r.dllName), plain(r.installedVersion)]];
        if (r.replacedByFoobar2000) {
            [lines addObject:[NSString stringWithFormat:@"foobar2000 %@ already includes it.", plain(r.latestVersion)]];
        } else if (successorPresent(r)) {
            [lines addObject:[NSString stringWithFormat:@"%@ is already installed.", ns(r.replacedBy)]];
        } else {
            [lines addObject:[NSString stringWithFormat:@"%@ %@ will be installed.", ns(r.replacedBy), plain(r.latestVersion)]];
            [lines addObject:[NSString stringWithFormat:@"From: %@", plain(r.sourceLabel, 80)]];
        }
        [lines addObject:r.replacementOrigin == "Info.plist" ? [NSString stringWithFormat:@"Declared by %@ itself.", ns(r.dllName)]
            : @"Declared by the built in list of this updater."];
        [switches addObject:[lines componentsJoinedByString:@"\n"]];
        NSURL *note = r.migration.empty() ? nil : [NSURL URLWithString:ns(r.migration)];
        if (note.host.length) {
            [notes addObject:note];
            [noteTitles addObject:[NSString stringWithFormat:@"Migration notes for %@ (%@)", ns(r.replacedBy), note.host]];
        }
    }
    if (!only) return nil;

    NSAlert *alert = [NSAlert new];
    alert.messageText = switches.count > 1 ? [NSString stringWithFormat:@"Switch %lu components?", (unsigned long)switches.count]
        : only->replacedByFoobar2000 ? [NSString stringWithFormat:@"Remove %@?", ns(only->dllName)]
        : [NSString stringWithFormat:@"Switch %@ to %@?", ns(only->dllName), ns(only->replacedBy)];
    alert.informativeText = [[switches componentsJoinedByString:@"\n\n"]
        stringByAppendingString:@"\n\nSettings are not carried over. The changes apply when foobar2000 restarts."];
    // Links read before deciding; each opens in the browser only when clicked.
    _migrationLinks = notes;
    if (notes.count) {
        NSStackView *stack = [NSStackView stackViewWithViews:@[]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        for (NSUInteger i = 0; i < notes.count; ++i) {
            NSButton *link = [NSButton buttonWithTitle:noteTitles[i] target:self action:@selector(openMigrationLink:)];
            link.bordered = NO;
            link.tag = (NSInteger)i;
            link.toolTip = notes[i].absoluteString;
            link.attributedTitle = [[NSAttributedString alloc] initWithString:noteTitles[i] attributes:@{
                NSForegroundColorAttributeName: NSColor.linkColor, NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)}];
            [stack addArrangedSubview:link];
        }
        [stack layoutSubtreeIfNeeded];
        stack.frame = NSMakeRect(0, 0, 300, stack.fittingSize.height);
        alert.accessoryView = stack;
    }
    [alert addButtonWithTitle:@"Switch"];
    [alert addButtonWithTitle:@"Cancel"];
    return alert;
}

- (void)openMigrationLink:(NSButton *)sender {
    if (sender.tag >= 0 && sender.tag < (NSInteger)_migrationLinks.count) [[NSWorkspace sharedWorkspace] openURL:_migrationLinks[sender.tag]];
}

- (void)restorePrevious:(NSMenuItem *)item {
    FCUUpdateRow *row = item.representedObject;
    [self runOperations:{{row.file.UTF8String, row.installed.UTF8String, "", "", "", ""}}];
}

// Keeping a replaced component (or no longer keeping it) changes what its row checks, so the check runs again.
- (void)toggleKeep:(NSMenuItem *)item {
    FCUUpdateRow *row = item.representedObject;
    SetReplacementKept(row.file.UTF8String, row.replacedBy.UTF8String, !row.kept);
    [self runCheck];
}

// Takes the update check slot, so a check and an install never run together.
- (void)runOperations:(std::vector<Operation> const &)jobs {
    if (jobs.empty() || !TryBeginUpdateCheck()) return;
    _installing = YES;
    [self stateChanged];
    fb2k::splitTask([jobs, model = self] {
        abort_callback &abort = fb2k::mainAborter();
        std::vector<fcu::InstallOutcome> outcomes;
        for (size_t i = 0; i < jobs.size() && !abort.is_aborting(); ++i) {
            Operation const &op = jobs[i];
            fb2k::inMainThread([op, i, count = jobs.size(), model] {
                if (fb2k::mainAborter().is_aborting()) return;
                NSString *what = op.removeOnly ? [NSString stringWithFormat:@"Removing %@", ns(op.name)]
                    : !op.replacement.empty() ? [NSString stringWithFormat:@"Switching %@ to %@", ns(op.name), ns(op.replacement)]
                    : [NSString stringWithFormat:@"%@ %@", op.url.empty() ? @"Restoring" : @"Installing", ns(op.name)];
                [model setStatus:[NSString stringWithFormat:@"%@ (%zu of %zu)...", what, i + 1, count]];
            });
            outcomes.push_back(op.removeOnly ? fcu::stageRemoval(op.name, abort)
                               : !op.replacement.empty() ? fcu::switchComponent(op.name, op.replacement, op.url, op.team, abort)
                               : op.url.empty() ? fcu::restorePrevious(op.name, op.installedVersion, abort)
                                                : fcu::installUpdate(op.name, op.installedVersion, op.url, abort));
            // Right away, not in finishOperation: quitting during a later download must not lose the note of a staged switch.
            if (outcomes.back().ok && !op.replacement.empty() && !op.migration.empty()) RememberMigrationNote({op.name, op.replacement, op.migration});
        }
        outcomes.resize(jobs.size());
        fb2k::inMainThread([jobs, outcomes, model] { [model finishOperation:jobs outcomes:outcomes]; });
    });
}

// Main thread, once the worker is done. The page shows the outcome whether or not it is on screen;
// anything staged is offered a restart either way.
- (void)finishOperation:(std::vector<Operation> const &)jobs outcomes:(std::vector<fcu::InstallOutcome> const &)outcomes {
    EndUpdateCheck();
    _installing = NO;
    if (fb2k::mainAborter().is_aborting()) return;

    NSMutableDictionary<NSString *, NSString *> *failures = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *failed = [NSMutableArray array];
    int staged = 0;
    for (size_t i = 0; i < jobs.size(); ++i) {
        if (outcomes[i].ok) { ++staged; continue; }
        failures[ns(jobs[i].name)] = ns(outcomes[i].message);
        [failed addObject:[NSString stringWithFormat:@"%@: %@", ns(jobs[i].name), ns(outcomes[i].message)]];
    }
    NSString *summary = staged ? [NSString stringWithFormat:@"Staged %d of %zu. Restart foobar2000 to finish.", staged, jobs.size()] : @"Nothing was installed.";
    if (failed.count) summary = [summary stringByAppendingFormat:@" Failed: %@", [failed componentsJoinedByString:@"; "]];
    [_checked removeAllObjects];
    _failures = [failures mutableCopy];
    [self rebuildRows];
    [self setStatus:summary];

    if (staged == 0) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Restart foobar2000 now to finish installing?";
    alert.informativeText = @"The new versions are applied when foobar2000 starts.";
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) standard_commands::main_restart();
}

- (NSMenuItem *)restoreItemForRow:(FCUUpdateRow *)row {
    BOOL hasBackup = row.backupVersion.length > 0;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:hasBackup ? [NSString stringWithFormat:@"Restore Previous (%@)", row.backupVersion] : @"Restore Previous"
                                                  action:@selector(restorePrevious:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = row;
    item.enabled = hasBackup && !row.staged && !_checking && !_installing;
    return item;
}

- (NSMenuItem *)keepItemForRow:(FCUUpdateRow *)row {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Keep %@ (do not switch to %@)", row.file, row.replacedBy]
                                                  action:@selector(toggleKeep:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = row;
    item.state = row.kept ? NSControlStateValueOn : NSControlStateValueOff;
    item.enabled = !row.staged && !_checking && !_installing;
    return item;
}

#ifdef FCU_DEBUG_HOOKS
- (NSMenuItem *)debugRestoreItemForName:(NSString *)name {
    for (FCUUpdateRow *row in _rows) {
        if ([row.file isEqualToString:name]) return [self restoreItemForRow:row];
    }
    return nil;
}

- (void)debugCheckFirstInstallable {
    for (FCUUpdateRow *row in _rows) {
        if (row.blockReason.length != 0) continue;
        [_checked addObject:row.file];
        [[NSNotificationCenter defaultCenter] postNotificationName:kRowsChanged object:self];
        return;
    }
}
#endif

@end

namespace {

// Main thread only.
FCUUpdatesModel *g_model = nil;

FCUUpdatesModel *model() {
    if (!g_model) g_model = [FCUUpdatesModel new];
    return g_model;
}

// Brings Preferences forward at our page. The autotest only marks the page visible.
void openPage(FCUUpdatesModel *m) {
#ifdef FCU_DEBUG_HOOKS
    if (g_offscreen) {
        m.visible = YES;
        return;
    }
#endif
    ui_control::get()->show_preferences(fcu::guid_preferences_page);
}

#ifdef FCU_DEBUG_HOOKS
// Debug functions build their own model and page; the page takes the current model when it is created.
struct ScopedModel {
    FCUUpdatesModel *saved;
    explicit ScopedModel(FCUUpdatesModel *scratch) : saved(g_model) { g_model = scratch; }
    ~ScopedModel() { g_model = saved; }
};

FCUUpdatesModel *scratchModel(std::vector<CheckResult> const& results) {
    FCUUpdatesModel *scratch = [FCUUpdatesModel new];
    [scratch showResults:results emptyMessage:@""];
    return scratch;
}
#endif

} // namespace

@interface FCUUpdatesView () <NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate>
@end

@implementation FCUUpdatesView {
    FCUUpdatesModel *_model;
    NSScrollView *_scroll;
    NSTableView *_table;
    NSTextField *_statusLine;
    NSButton *_install, *_showBuiltIn;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _model = model();
        [self buildContent];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(rowsChanged:) name:kRowsChanged object:_model];
        [center addObserver:self selector:@selector(stateChanged:) name:kStateChanged object:_model];
        [_table reloadData];
        [self stateChanged:nil];
    }
    return self;
}

- (void)buildContent {
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.hasVerticalScroller = YES;
    _scroll.borderType = NSBezelBorder;
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;

    // Like foobar2000's own Components list: tick, name, version, file name and what the check found.
    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    struct Col { NSString *ident, *title; CGFloat width; };
    for (Col c : {Col{@"update", @"", 24}, Col{@"name", @"Name", 200}, Col{@"version", @"Version", 80},
                  Col{@"module", @"Module", 170}, Col{@"status", @"Status", 190}}) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c.ident];
        col.title = c.title;
        col.width = c.width;
        if ([c.ident isEqualToString:@"update"]) {
            col.minWidth = col.maxWidth = c.width;
            col.resizingMask = NSTableColumnNoResizing;
        } else {
            col.minWidth = 40;
            // Status takes the spare width so the columns fill the table; the others keep theirs.
            col.resizingMask = [c.ident isEqualToString:@"status"] ? (NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask) : NSTableColumnUserResizingMask;
            // Clicking a title sorts by it; versions compare numerically ("1.10" after "1.9").
            if ([c.ident isEqualToString:@"status"]) {
                col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"statusOrder" ascending:YES];
            } else {
                NSString *key = [c.ident isEqualToString:@"name"] ? @"displayName" : [c.ident isEqualToString:@"version"] ? @"installed" : @"module";
                col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:key ascending:YES selector:@selector(localizedStandardCompare:)];
            }
        }
        [_table addTableColumn:col];
    }
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.style = NSTableViewStylePlain;
    _table.usesAlternatingRowBackgroundColors = NO;
    _table.allowsColumnReordering = NO;
    _table.sortDescriptors = _model.sortDescriptors; // before the delegate: restoring the order is no click
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(openReleasePage:);
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    _table.menu = menu;
    _scroll.documentView = _table;
    [self addSubview:_scroll];

    _showBuiltIn = [NSButton checkboxWithTitle:@"Show built in components (updated with foobar2000)" target:self action:@selector(showBuiltInChanged:)];
    _showBuiltIn.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_showBuiltIn];

    // Takes the width between the checkbox and the Install button and wraps to two lines; the full text is its tooltip.
    _statusLine = [NSTextField wrappingLabelWithString:@""];
    _statusLine.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLine.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _statusLine.textColor = NSColor.secondaryLabelColor;
    _statusLine.maximumNumberOfLines = 2;
    _statusLine.lineBreakMode = NSLineBreakByTruncatingTail;
    [_statusLine setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_statusLine setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_statusLine];

    _install = [NSButton buttonWithTitle:@"Install" target:self action:@selector(installChecked:)];
    _install.translatesAutoresizingMaskIntoConstraints = NO;
    _install.toolTip = @"Install the ticked updates";
    [self addSubview:_install];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:_install.topAnchor constant:-10],
        [_install.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_install.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_showBuiltIn.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_showBuiltIn.centerYAnchor constraintEqualToAnchor:_install.centerYAnchor],
        [_statusLine.leadingAnchor constraintEqualToAnchor:_showBuiltIn.trailingAnchor constant:16],
        [_statusLine.trailingAnchor constraintEqualToAnchor:_install.leadingAnchor constant:-16],
        [_statusLine.centerYAnchor constraintEqualToAnchor:_install.centerYAnchor],
    ]];
}

- (void)rowsChanged:(NSNotification *)note {
    [_table reloadData];
    [self stateChanged:nil];
}

- (void)stateChanged:(NSNotification *)note {
    _statusLine.stringValue = _model.status;
    _statusLine.toolTip = _model.status;
    _install.enabled = _model.canInstall;
    _showBuiltIn.state = GetShowBuiltInComponents() ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)showBuiltInChanged:(id)sender {
    [_model setShowBuiltIn:_showBuiltIn.state == NSControlStateValueOn];
}

- (void)installChecked:(id)sender {
    [_model installChecked];
}

- (void)toggleUpdate:(NSButton *)sender {
    NSInteger index = [_table rowForView:sender];
    if (index < 0 || index >= (NSInteger)_model.rows.count) return;
    [_model setChecked:sender.state == NSControlStateValueOn forFile:_model.rows[index].file];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger index = _table.clickedRow;
    FCUUpdateRow *row = index >= 0 && index < (NSInteger)_model.rows.count ? _model.rows[index] : nil;
    [menu addItem:[_model restoreItemForRow:row]];
    if (row.replacedBy.length) [menu addItem:[_model keepItemForRow:row]];
}

- (void)openReleasePage:(id)sender {
    NSInteger row = _table.clickedRow;
    if (row < 0 || row >= (NSInteger)_model.rows.count) return;
    NSString *url = _model.rows[row].releaseUrl;
    if (url.length) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

#pragma mark - Table

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    _model.sortDescriptors = tableView.sortDescriptors;
    [_model resort];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _model.rows.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)rowIndex {
    FCUUpdateRow *row = _model.rows[rowIndex];
    NSString *ident = column.identifier;

    if ([ident isEqualToString:@"update"]) {
        NSButton *box = [tableView makeViewWithIdentifier:ident owner:self];
        if (!box) {
            box = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleUpdate:)];
            box.identifier = ident;
        }
        BOOL installable = row.blockReason.length == 0 && !row.builtIn;
        // Built in components are never installed: no checkbox (hidden, so the row still has its cell).
        box.hidden = row.builtIn;
        box.enabled = installable;
        box.state = installable && [_model.checked containsObject:row.file] ? NSControlStateValueOn : NSControlStateValueOff;
        NSString *action = row.statusCode != UpdateStatus::Replaced ? @"Install this update"
            : row.replacedByFoobar2000 ? [NSString stringWithFormat:@"Remove this component (foobar2000 %@ includes it)", row.latest]
            : row.replacementInstalled ? [NSString stringWithFormat:@"Remove this component (%@ is installed)", row.replacedBy]
            : [NSString stringWithFormat:@"Switch to %@", row.replacedBy];
        box.toolTip = row.builtIn ? nil : row.blockReason.length ? row.blockReason : action;
        return box;
    }

    NSTextField *field = [tableView makeViewWithIdentifier:ident owner:self];
    if (!field) {
        field = [NSTextField labelWithString:@""];
        field.identifier = ident;
        field.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    bool const status = [ident isEqualToString:@"status"];
    // Regular text like the native list, built in components dimmed; a row with something to install stands out in bold.
    bool const bold = !row.builtIn && (row.statusCode == UpdateStatus::UpdateAvailable || row.statusCode == UpdateStatus::Replaced);
    field.font = bold ? [NSFont boldSystemFontOfSize:NSFont.systemFontSize] : [NSFont systemFontOfSize:NSFont.systemFontSize];
    field.textColor = status && (row.statusCode == UpdateStatus::Error || row.failed) ? NSColor.systemRedColor
        : status && row.overlap.length ? NSColor.systemOrangeColor
        : row.builtIn ? NSColor.secondaryLabelColor : NSColor.labelColor;

    if ([ident isEqualToString:@"name"]) {
        field.stringValue = row.displayName;
        field.toolTip = row.about.length ? row.about : nil;
    } else if ([ident isEqualToString:@"version"]) {
        field.stringValue = row.installed;
        field.toolTip = nil;
    } else if ([ident isEqualToString:@"module"]) {
        field.stringValue = row.module;
        field.toolTip = nil;
    } else {
        field.stringValue = row.status;
        field.toolTip = row.statusTip.length ? row.statusTip : nil;
    }
    return field;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return YES;
}

#ifdef FCU_DEBUG_HOOKS
- (size_t)visibleRowCount {
    return _model.rows.count;
}

- (size_t)realiseAllCells {
    [self layoutSubtreeIfNeeded];
    // Fit the columns to the visible width now (the page may never be shown before it is drawn).
    [_table sizeToFit];
    size_t cells = 0;
    for (NSInteger row = 0; row < _table.numberOfRows; ++row) {
        for (NSInteger col = 0; col < _table.numberOfColumns; ++col) {
            if ([_table viewAtColumn:col row:row makeIfNecessary:YES]) ++cells;
        }
    }
    return cells;
}

- (NSString *)debugLayout {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"view %.0f, scroll %.0f, content %.0f, table %.0f; ", self.frame.size.width,
        _scroll.frame.size.width, _scroll.contentSize.width, _table.frame.size.width];
    for (NSTableColumn *c in _table.tableColumns) [s appendFormat:@"%@=%.0f ", c.identifier, c.width];
    return s;
}
#endif

@end

bool IsUpdatesPageVisible() {
    return model().visible;
}

void UpdatesPageVisibilityChanged(bool visible) {
    FCUUpdatesModel *m = model();
    if (visible) [m pageDidShow]; else [m pageDidHide];
}

void ShowUpdatesPage() {
    FCUUpdatesModel *m = model();
    bool const wasVisible = m.visible;
    openPage(m);
    // A check this page already shows runs on; one that ran while the page was away is attached to again.
    if (wasVisible && m.checking) return;
    [m runCheck];
}

void DeliverCheckResults(int64_t checkId, std::vector<CheckResult> const& results, const char* emptyMessage, bool openIfClosed) {
    // Delivery ends the check (exactly once, on the main thread): until now no other check
    // could begin, so a later check can never replace the dismissal marker of this one.
    struct Release {
        ~Release() {
            EndUpdateCheck();
            [[NSNotificationCenter defaultCenter] postNotificationName:FCUUpdateCheckCompletedNotification object:nil];
        }
    } release;

    FCUUpdatesModel *m = model();
    [m finishCheckWithResults:results emptyMessage:emptyMessage && *emptyMessage ? ns(emptyMessage) : kNoComponents];
    if (!openIfClosed || m.visible || m.dismissedCheckId == checkId || checkId != CurrentUpdateCheckId()) return;
    openPage(m);
}

#ifdef FCU_DEBUG_HOOKS
void DebugSetUpdatesPageOffscreen(bool offscreen) { g_offscreen = offscreen; }

void DebugHideUpdatesPage() { [model() pageDidHide]; }

long DebugUpdatesPageRows(bool* attached) {
    FCUUpdatesModel *m = model();
    if (!m.visible) return -1;
    if (attached) *attached = m.attached;
    return (long)m.rows.count;
}

std::string DebugUpdatesStatus() {
    FCUUpdatesModel *m = model();
    return m.visible ? std::string(m.status.UTF8String) : std::string();
}

void DebugToggleBuiltIn() {
    FCUUpdatesModel *m = model();
    if (m.visible) [m setShowBuiltIn:!GetShowBuiltInComponents()];
}

std::string DebugRestoreMenuItem(std::vector<CheckResult> const& results, std::string const& name, bool* enabled) {
    NSMenuItem *item = [scratchModel(results) debugRestoreItemForName:ns(name)];
    if (enabled) *enabled = item.enabled;
    return item ? item.title.UTF8String : "";
}

std::string DebugLastUpdatesLayout() { return g_lastLayout; }

size_t DebugRealiseUpdatesTable(std::vector<CheckResult> const& results, size_t* visibleRows) {
    FCUUpdatesModel *scratch = scratchModel(results);
    FCUUpdatesView *view = nil;
    {
        ScopedModel scope(scratch);
        view = [[FCUUpdatesView alloc] initWithFrame:NSMakeRect(0, 0, 680, 400)];
    }
    if (visibleRows) *visibleRows = [view visibleRowCount];
    return [view realiseAllCells];
}

long DebugSnapshotUpdatesPage(std::vector<CheckResult> const& results, bool showBuiltIn, const char* pngPath) {
    bool saved = GetShowBuiltInComponents();
    SetShowBuiltInComponents(showBuiltIn);
    FCUUpdatesModel *scratch = scratchModel(results);
    [scratch debugCheckFirstInstallable];
    FCUPreferencesController *prefs = [[FCUPreferencesController alloc] init];
    {
        ScopedModel scope(scratch);
        (void)prefs.view; // loadView builds the table on the current model
    }
    NSView *page = prefs.view;
    page.frame = NSMakeRect(0, 0, 720, 560);
    [page layoutSubtreeIfNeeded];
    FCUUpdatesView *updates = (FCUUpdatesView *)[prefs debugUpdatesView];
    [updates realiseAllCells];
    bool ok = DebugWriteSnapshot(page, NSAppearanceNameAqua, [NSString stringWithUTF8String:pngPath]);
    SetShowBuiltInComponents(saved);
    g_lastLayout = [NSString stringWithFormat:@"page %.0f, %@", page.frame.size.width, [updates debugLayout]].UTF8String;
    return ok ? (long)[updates visibleRowCount] : -1;
}

std::string DebugSnapshotSwitchConfirmation(std::vector<CheckResult> const& results, const char* pngPath) {
    FCUUpdatesModel *scratch = scratchModel(results);
    [scratch debugCheckFirstInstallable];
    NSAlert *alert = [scratch switchConfirmation];
    if (!alert) return "";
    [alert layout];
    DebugWriteSnapshot(alert.window.contentView, NSAppearanceNameAqua, [NSString stringWithUTF8String:pngPath]);
    NSMutableString *text = [NSMutableString stringWithFormat:@"%@\n%@", alert.messageText, alert.informativeText];
    for (NSView *v in alert.accessoryView.subviews) {
        if ([v isKindOfClass:NSButton.class]) [text appendFormat:@"\n[link] %@ -> %@", ((NSButton *)v).title, v.toolTip];
    }
    return text.UTF8String;
}
#endif
