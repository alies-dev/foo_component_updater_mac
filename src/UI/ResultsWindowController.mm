#include "ResultsWindow.h"

#include "../fb2k_sdk.h"

#include <algorithm>

#include "../Integration/Settings.h"
#include "../upstream/automatic_check.h"
#include "DebugSnapshot.h"
#include "../Core/package_layout.h"
#include "../Platform/fcu_install.h"

NSNotificationName const FCUUpdateCheckCompletedNotification = @"FCUUpdateCheckCompleted";

namespace {

NSString *ns(std::string const& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

NSDate *releasedDate(std::string const& iso) {
    static NSISO8601DateFormatter *parser = [NSISO8601DateFormatter new];
    return iso.empty() ? nil : [parser dateFromString:ns(iso)];
}

// "2 Oct 2026" style in the user's locale; "" when GitHub gave no usable date.
NSString *releasedText(std::string const& iso) {
    static NSDateFormatter *formatter = [] {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateStyle = NSDateFormatterMediumStyle;
        f.timeStyle = NSDateFormatterNoStyle;
        return f;
    }();
    NSDate *date = releasedDate(iso);
    return date ? [formatter stringFromDate:date] : @"";
}

int statusRank(UpdateStatus s) {
    switch (s) {
    case UpdateStatus::UpdateAvailable: return 0;
    case UpdateStatus::Error: return 1;
    case UpdateStatus::ComparisonUnsupported: return 2;
    case UpdateStatus::UpToDate: return 3;
    case UpdateStatus::NoSource: return 4;
    }
    return 5;
}

NSString *statusText(UpdateStatus s) {
    switch (s) {
    case UpdateStatus::UpdateAvailable: return @"Update available";
    case UpdateStatus::UpToDate: return @"Up to date";
    case UpdateStatus::ComparisonUnsupported: return @"Unable to compare";
    case UpdateStatus::Error: return @"Error";
    case UpdateStatus::NoSource: return @"No source";
    }
    return @"";
}

}

@interface FCUResultRow : NSObject
@property (copy) NSString *component, *installed, *latest, *released, *status, *source, *tooltip, *releaseUrl, *releaseNotes, *about;
@property BOOL prerelease;
@property (copy) NSDate *releasedDate; // nil when unknown; sort key of the Released column
@property NSInteger statusOrder;       // statusRank; sort key of the Status column
@property (copy) NSString *name, *blockReason, *backupVersion; // file name, why not installable ("" when it is), backup version ("" when none)
@property UpdateStatus statusCode;
@property BOOL staged, failed;
@end
@implementation FCUResultRow
@end

@interface FCUResultsWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate>
@property (nonatomic) int64_t checkId; // the check this window runs or waits for (CurrentUpdateCheckId)
@property (nonatomic) BOOL checking;
- (instancetype)initWithEmptyMessage:(NSString *)message;
- (void)runCheck;
- (void)showResults:(std::vector<CheckResult> const &)results;
- (BOOL)isAttached;
- (void)operationFinished:(NSString *)summary failures:(NSDictionary<NSString *, NSString *> *)failures;
- (void)finishCheckWithResults:(std::vector<CheckResult> const &)results;
#ifdef FCU_DEBUG_HOOKS
- (size_t)realiseAllCells;
- (size_t)visibleRowCount;
- (NSString *)debugLayout;
- (NSString *)debugStatus;
- (void)debugToggleBuiltIn;
- (void)debugCheckFirstInstallable;
- (NSMenuItem *)debugRestoreItemForName:(NSString *)name;
#endif
@end

namespace {
// Main thread only; cleared when the window closes so late worker callbacks are dropped.
FCUResultsWindowController *g_controller = nil;
#ifdef FCU_DEBUG_HOOKS
std::string g_lastLayout;
// The autotest builds windows but never orders them onto the screen or saves their state.
bool g_offscreen = false;
#endif
bool keepsWindowState() {
#ifdef FCU_DEBUG_HOOKS
    return !g_offscreen;
#else
    return true;
#endif
}
// The check whose window the user closed while it was still running: its completion must
// not open a window again (automatic checks open one when an update is found).
int64_t g_dismissedCheckId = 0;

bool g_installing = false; // an install or restore runs; it holds the update check slot

struct Operation {
    std::string name, installedVersion, url; // url empty: restore the backup
};

// Main thread, once the worker is done. The window (if any is open) shows the outcome;
// anything staged is offered a restart whether or not a window is still there.
void finishOperation(std::vector<Operation> const& jobs, std::vector<fcu::InstallOutcome> const& outcomes) {
    EndUpdateCheck();
    g_installing = false;
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
    [g_controller operationFinished:summary failures:failures];

    if (staged == 0) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Restart foobar2000 now to finish installing?";
    alert.informativeText = @"The new versions are applied when foobar2000 starts.";
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) standard_commands::main_restart();
}
}

@implementation FCUResultsWindowController {
    NSTableView *_table;
    NSTextField *_statusLine;
    NSButton *_install;
    NSMutableSet<NSString *> *_checked;                          // names of the rows ticked for install
    NSMutableDictionary<NSString *, NSString *> *_failures;      // last install error per component
    NSButton *_checkAgain, *_showBuiltIn;
    std::vector<CheckResult> _results;
    NSArray<FCUResultRow *> *_rows;
    NSString *_emptyMessage;
    BOOL _attached; // waiting for a check that started elsewhere (the automatic one)
}

- (instancetype)initWithEmptyMessage:(NSString *)message {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 920, 460)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Component Updates";
    window.releasedWhenClosed = NO;
    window.minSize = NSMakeSize(720, 280);
    if ((self = [super initWithWindow:window])) {
        _emptyMessage = [message copy];
        _rows = @[];
        _checked = [NSMutableSet set];
        _failures = [NSMutableDictionary dictionary];
        window.delegate = self;
        // Saved size and position win over the default; set before the first show.
        BOOL restored = keepsWindowState() && [window setFrameUsingName:@"FCUResultsWindow"];
        if (keepsWindowState()) [window setFrameAutosaveName:@"FCUResultsWindow"];
        [self buildContent];
        if (!restored) [window center];
    }
    return self;
}

- (void)buildContent {
    NSView *content = self.window.contentView;
    NSRect bounds = content.bounds;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 44, bounds.size.width, bounds.size.height - 44)];
    scroll.hasVerticalScroller = YES;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    struct Col { NSString *ident, *title; CGFloat width; };
    for (Col c : {Col{@"update", @"Update", 56}, Col{@"component", @"Component", 230}, Col{@"installed", @"Installed", 80},
                  Col{@"latest", @"Latest", 100}, Col{@"released", @"Released", 96}, Col{@"status", @"Status", 120},
                  Col{@"notes", @"Notes", 112}}) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c.ident];
        col.title = c.title;
        col.width = c.width;
        col.minWidth = 40;
        // Component takes the spare width; the other columns keep theirs, so
        // "Release notes" is never squeezed at the default window width.
        bool flexible = [c.ident isEqualToString:@"component"];
        col.resizingMask = flexible ? (NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask) : NSTableColumnUserResizingMask;
        // Clicking a title sorts by it; versions compare numerically ("1.10" after "1.9").
        if ([c.ident isEqualToString:@"released"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"releasedDate" ascending:NO];
        } else if ([c.ident isEqualToString:@"status"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"statusOrder" ascending:YES];
        } else if (![c.ident isEqualToString:@"update"] && ![c.ident isEqualToString:@"notes"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c.ident ascending:YES selector:@selector(localizedStandardCompare:)];
        }
        [_table addTableColumn:col];
    }
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    if (keepsWindowState()) {
        _table.autosaveName = @"FCUResultsTable2"; // new name: the saved layout had a Source column
        _table.autosaveTableColumns = YES;
    }
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(openReleasePage:);
    _table.usesAlternatingRowBackgroundColors = YES;
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    _table.menu = menu;
    scroll.documentView = _table;
    [content addSubview:scroll];
    // Fit the columns to the visible width now (the window may never be shown before it is drawn).
    [scroll layoutSubtreeIfNeeded];
    [_table sizeToFit];

    _statusLine = [NSTextField labelWithString:@""];
    _statusLine.frame = NSMakeRect(230, 14, bounds.size.width - 556, 18);
    _statusLine.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _statusLine.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:_statusLine];

    _checkAgain = [NSButton buttonWithTitle:@"Check Again" target:self action:@selector(checkAgain:)];
    _checkAgain.frame = NSMakeRect(bounds.size.width - 224, 8, 110, 28);
    _checkAgain.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:_checkAgain];

    _install = [NSButton buttonWithTitle:@"Install" target:self action:@selector(installChecked:)];
    _install.frame = NSMakeRect(bounds.size.width - 322, 8, 90, 28);
    _install.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    _install.toolTip = @"Install the ticked updates";
    [content addSubview:_install];

    _showBuiltIn = [NSButton checkboxWithTitle:@"Show built in components" target:self action:@selector(showBuiltInChanged:)];
    _showBuiltIn.frame = NSMakeRect(16, 10, 200, 20);
    _showBuiltIn.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    _showBuiltIn.state = GetShowBuiltInComponents() ? NSControlStateValueOn : NSControlStateValueOff;
    [content addSubview:_showBuiltIn];

    NSButton *close = [NSButton buttonWithTitle:@"Close" target:self.window action:@selector(performClose:)];
    close.frame = NSMakeRect(bounds.size.width - 106, 8, 90, 28);
    close.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    close.keyEquivalent = @"\e";
    [content addSubview:close];
}

- (void)setStatus:(NSString *)text {
    _statusLine.stringValue = text;
    _statusLine.toolTip = text;
}

- (void)runCheck {
    if (g_installing) {
        [self setStatus:@"An install is running. Check again when it has finished."];
        return;
    }
    // One check at a time for the whole process (the automatic check shares the flag).
    if (!TryBeginUpdateCheck()) {
        // Attach to the check that is running, manual or automatic: DeliverCheckResults hands
        // its results to the window attached to its id, so nothing is started twice.
        _attached = YES;
        self.checkId = CurrentUpdateCheckId();
        self.checking = YES;
        [self updateControls];
        [self setStatus:@"A check is already running in the background. Its results will appear here when it finishes."];
        return;
    }
    _attached = NO;
    self.checking = YES;
    [self updateControls];
    [self setStatus:@"Starting..."];
    const int64_t checkId = self.checkId = CurrentUpdateCheckId();
    // Enumerated here, on the main thread, once this window owns the check slot.
    std::vector<InstalledComponentInfo> installed = GetInstalledComponents();

    fb2k::splitTask([installed, checkId] {
      try {
        abort_callback& abort = fb2k::mainAborter();
        std::vector<CheckResult> results = RunUpdateCheck(installed, abort, [checkId](std::string const& message) {
            fb2k::inMainThread([message, checkId] {
                if (fb2k::mainAborter().is_aborting() || !g_controller || g_controller.checkId != checkId || !g_controller.checking) return;
                [g_controller setStatus:ns(message)];
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

- (BOOL)isAttached { return _attached; }

- (void)finishCheckWithResults:(std::vector<CheckResult> const &)results {
    _attached = NO;
    self.checking = NO;
    [self showResults:results];
}

- (void)showResults:(std::vector<CheckResult> const &)results {
    _results = results;
    [_checked removeAllObjects];
    [_failures removeAllObjects];
    [self rebuildRows];
}

- (void)showBuiltInChanged:(id)sender {
    SetShowBuiltInComponents(_showBuiltIn.state == NSControlStateValueOn);
    [self rebuildRows];
}

// Rows are rebuilt from the stored results; built in components (file name "Core") only when asked for.
- (void)rebuildRows {
    std::vector<CheckResult> const &results = _results;
    bool showBuiltIn = _showBuiltIn.state == NSControlStateValueOn;
    std::vector<CheckResult const *> sorted;
    for (auto const &r : results) {
        if (r.dllName == "Core" && !showBuiltIn) continue;
        sorted.push_back(&r);
    }
    std::stable_sort(sorted.begin(), sorted.end(), [](CheckResult const *a, CheckResult const *b) {
        return statusRank(a->status) < statusRank(b->status);
    });

    NSMutableArray<FCUResultRow *> *rows = [NSMutableArray array];
    int updates = 0, errors = 0;
    NSString *rateLimit = nil;
    for (CheckResult const *r : sorted) {
        FCUResultRow *row = [FCUResultRow new];
        row.component = r->dllName.empty() ? ns(r->displayName)
            : [NSString stringWithFormat:@"%@ (%@)", ns(r->displayName), r->dllName == "Core" ? @"built in" : ns(r->dllName)];
        row.installed = ns(r->installedVersion);
        // A version like "2.0.0-beta" already says so; only a plain number gets the mark.
        bool marked = r->prerelease && r->latestVersion.find('-') == std::string::npos;
        row.latest = marked ? [NSString stringWithFormat:@"%@ (beta)", ns(r->latestVersion)] : ns(r->latestVersion);
        row.prerelease = r->prerelease;
        row.releaseNotes = ns(r->releaseNotes);
        row.released = releasedText(r->releasedAt);
        row.releasedDate = releasedDate(r->releasedAt);
        row.statusOrder = statusRank(r->status);
        row.about = ns(r->about);
        row.status = statusText(r->status);
        row.statusCode = r->status;
        row.source = r->sourceOrigin.empty() ? @"" : [NSString stringWithFormat:@"%@ (%@)", ns(r->sourceLabel), ns(r->sourceOrigin)];
        row.tooltip = r->status != UpdateStatus::Error ? ns(r->note)
            : r->note.empty() ? ns(r->errorMessage) : [NSString stringWithFormat:@"%@\n%@", ns(r->errorMessage), ns(r->note)];
        row.releaseUrl = [ns(r->releaseUrl) hasPrefix:@"https://"] ? ns(r->releaseUrl) : @"";
        row.name = ns(r->dllName);
        row.staged = fcu::isStaged(r->dllName);
        row.blockReason = ns(fcu::installBlockReason(r->status == UpdateStatus::UpdateAvailable, r->dllName, r->downloadUrl, r->assetName, row.staged));
        std::string backup;
        row.backupVersion = r->dllName != "Core" && fcu::backupVersion(r->dllName, backup) ? ns(backup) : @"";
        if (row.staged) {
            row.status = @"Restart to finish";
        } else if (NSString *why = _failures[row.name]) {
            row.status = @"Install failed";
            row.tooltip = why;
            row.failed = YES;
        }
        if (r->status == UpdateStatus::UpdateAvailable) ++updates;
        if (r->status == UpdateStatus::Error) {
            ++errors;
            if (!rateLimit && r->errorMessage.rfind("GitHub rate limit reached", 0) == 0) rateLimit = ns(r->errorMessage);
        }
        [rows addObject:row];
    }
    _rows = [rows sortedArrayUsingDescriptors:_table.sortDescriptors]; // keeps the order the user clicked
    [_table reloadData];
    [self updateControls];

    // While a check or an install runs the status line shows its progress; toggling the checkbox only rebuilds the rows.
    if (self.checking || g_installing) return;

    if (results.empty()) {
        [self setStatus:_emptyMessage];
    } else if (rateLimit) {
        [self setStatus:rateLimit];
    } else {
        [self setStatus:[NSString stringWithFormat:@"%d update%s available, %d error%s", updates, updates == 1 ? "" : "s", errors, errors == 1 ? "" : "s"]];
    }
}

- (void)checkAgain:(id)sender {
    [self runCheck];
}

- (void)updateControls {
    bool idle = !self.checking && !g_installing;
    _checkAgain.enabled = idle;
    _install.enabled = idle && _checked.count > 0;
}

- (void)toggleUpdate:(NSButton *)sender {
    NSInteger index = [_table rowForView:sender];
    if (index < 0 || index >= (NSInteger)_rows.count) return;
    FCUResultRow *row = _rows[index];
    if (sender.state == NSControlStateValueOn) [_checked addObject:row.name]; else [_checked removeObject:row.name];
    [self updateControls];
}

- (void)installChecked:(id)sender {
    std::vector<Operation> jobs;
    for (CheckResult const &r : _results) {
        if ([_checked containsObject:ns(r.dllName)]) jobs.push_back({r.dllName, r.installedVersion, r.downloadUrl});
    }
    [self runOperations:jobs];
}

- (void)restorePrevious:(NSMenuItem *)item {
    FCUResultRow *row = item.representedObject;
    [self runOperations:{{row.name.UTF8String, row.installed.UTF8String, ""}}];
}

// Takes the update check slot, so a check and an install never run together.
- (void)runOperations:(std::vector<Operation> const &)jobs {
    if (jobs.empty() || !TryBeginUpdateCheck()) return;
    g_installing = true;
    [self updateControls];
    fb2k::splitTask([jobs] {
        abort_callback &abort = fb2k::mainAborter();
        std::vector<fcu::InstallOutcome> outcomes;
        for (size_t i = 0; i < jobs.size() && !abort.is_aborting(); ++i) {
            Operation const &op = jobs[i];
            fb2k::inMainThread([name = op.name, i, count = jobs.size(), restoring = op.url.empty()] {
                if (!g_controller || fb2k::mainAborter().is_aborting()) return;
                [g_controller setStatus:[NSString stringWithFormat:@"%@ %@ (%zu of %zu)...", restoring ? @"Restoring" : @"Installing", ns(name), i + 1, count]];
            });
            outcomes.push_back(op.url.empty() ? fcu::restorePrevious(op.name, op.installedVersion, abort)
                                              : fcu::installUpdate(op.name, op.installedVersion, op.url, abort));
        }
        outcomes.resize(jobs.size());
        fb2k::inMainThread([jobs, outcomes] { finishOperation(jobs, outcomes); });
    });
}

- (void)operationFinished:(NSString *)summary failures:(NSDictionary<NSString *, NSString *> *)failures {
    [_checked removeAllObjects];
    _failures = [failures mutableCopy];
    [self rebuildRows];
    [self setStatus:summary];
}

- (NSMenuItem *)restoreItemForRow:(FCUResultRow *)row {
    BOOL hasBackup = row.backupVersion.length > 0;
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:hasBackup ? [NSString stringWithFormat:@"Restore Previous (%@)", row.backupVersion] : @"Restore Previous"
                                                  action:@selector(restorePrevious:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = row;
    item.enabled = hasBackup && !row.staged && !self.checking && !g_installing;
    return item;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger index = _table.clickedRow;
    [menu addItem:[self restoreItemForRow:index >= 0 && index < (NSInteger)_rows.count ? _rows[index] : nil]];
}

- (void)openReleasePage:(id)sender {
    NSInteger row = _table.clickedRow;
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    NSString *url = _rows[row].releaseUrl;
    if (url.length) [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (g_controller == self) {
        // Closing a window that still waits for a check dismisses that check's popup.
        if (self.checking) g_dismissedCheckId = self.checkId;
        g_controller = nil;
    }
}

#ifdef FCU_DEBUG_HOOKS
- (NSString *)debugStatus { return _statusLine.stringValue; }

- (void)debugToggleBuiltIn {
    _showBuiltIn.state = _showBuiltIn.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
    [self showBuiltInChanged:_showBuiltIn];
}

- (NSMenuItem *)debugRestoreItemForName:(NSString *)name {
    for (FCUResultRow *row in _rows) {
        if ([row.name isEqualToString:name]) return [self restoreItemForRow:row];
    }
    return nil;
}

- (void)debugCheckFirstInstallable {
    for (FCUResultRow *row in _rows) {
        if (row.blockReason.length != 0) continue;
        [_checked addObject:row.name];
        [_table reloadData];
        [self updateControls];
        return;
    }
}

- (NSString *)debugLayout {
    NSMutableString *s = [NSMutableString string];
    NSScrollView *scroll = _table.enclosingScrollView;
    [s appendFormat:@"window %.0f, scroll %.0f, content %.0f, table %.0f; ", self.window.contentView.bounds.size.width,
        scroll.frame.size.width, scroll.contentSize.width, _table.frame.size.width];
    for (NSTableColumn *c in _table.tableColumns) [s appendFormat:@"%@=%.0f ", c.identifier, c.width];
    return s;
}

- (size_t)visibleRowCount {
    return _rows.count;
}

- (size_t)realiseAllCells {
    (void)self.window;
    size_t cells = 0;
    for (NSInteger row = 0; row < _table.numberOfRows; ++row) {
        for (NSInteger col = 0; col < _table.numberOfColumns; ++col) {
            if ([_table viewAtColumn:col row:row makeIfNecessary:YES]) ++cells;
        }
    }
    return cells;
}
#endif

#pragma mark - Table

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    _rows = [_rows sortedArrayUsingDescriptors:tableView.sortDescriptors];
    [tableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return _rows.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)rowIndex {
    FCUResultRow *row = _rows[rowIndex];
    NSString *ident = column.identifier;

    if ([ident isEqualToString:@"update"]) {
        NSButton *box = [tableView makeViewWithIdentifier:ident owner:self];
        if (!box) {
            box = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleUpdate:)];
            box.identifier = ident;
        }
        BOOL installable = row.blockReason.length == 0;
        box.enabled = installable;
        box.state = installable && [_checked containsObject:row.name] ? NSControlStateValueOn : NSControlStateValueOff;
        box.toolTip = row.blockReason.length ? row.blockReason : @"Install this update";
        return box;
    }

    NSTextField *field = [tableView makeViewWithIdentifier:ident owner:self];
    if (!field) {
        field = [NSTextField labelWithString:@""];
        field.identifier = ident;
        field.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    NSString *cellTip = nil; // what this cell adds; the row's note or error follows it
    field.textColor = (row.statusCode == UpdateStatus::Error || row.failed) && [ident isEqualToString:@"status"] ? NSColor.systemRedColor : NSColor.labelColor;
    field.font = [ident isEqualToString:@"status"] && row.statusCode == UpdateStatus::UpdateAvailable
        ? [NSFont boldSystemFontOfSize:NSFont.systemFontSize] : [NSFont systemFontOfSize:NSFont.systemFontSize];

    if ([ident isEqualToString:@"component"]) {
        field.stringValue = row.component;
        if (row.about.length) cellTip = row.about;
    }
    else if ([ident isEqualToString:@"released"]) field.stringValue = row.released;
    else if ([ident isEqualToString:@"installed"]) field.stringValue = row.installed;
    else if ([ident isEqualToString:@"latest"]) {
        field.stringValue = row.latest;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        if (row.source.length) [lines addObject:[@"From " stringByAppendingString:row.source]];
        if (row.prerelease) [lines addObject:@"The author marked this release as a prerelease. It may be less stable."];
        if (lines.count) cellTip = [lines componentsJoinedByString:@"\n"];
    }
    else if ([ident isEqualToString:@"status"]) field.stringValue = row.status;
    else {
        field.stringValue = row.releaseUrl.length ? @"Release notes" : @"";
        if (row.releaseNotes.length) cellTip = row.releaseNotes;
    }
    field.toolTip = cellTip.length && row.tooltip.length ? [NSString stringWithFormat:@"%@\n\n%@", cellTip, row.tooltip]
        : cellTip.length ? cellTip : row.tooltip;
    return field;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    return YES;
}

@end

#ifdef FCU_DEBUG_HOOKS
std::string DebugLastResultsLayout() { return g_lastLayout; }
void DebugSetResultsWindowOffscreen(bool offscreen) { g_offscreen = offscreen; }
void DebugCloseResultsWindow() {
    if (g_controller) [g_controller.window close];
}
#endif

namespace {
// Windows are brought forward unless the Debug autotest asked for off screen windows.
void bringForward(FCUResultsWindowController *controller, bool makeKey) {
#ifdef FCU_DEBUG_HOOKS
    if (g_offscreen) return;
#endif
    if (makeKey) [controller.window makeKeyAndOrderFront:nil];
    else [controller.window orderFront:nil];
}
}

bool IsResultsWindowOpen() {
    return g_controller != nil;
}

void ShowUpdateResultWindow() {
    if (g_controller) {
        bringForward(g_controller, true);
        // A running check: only bring the window forward.
        if (!g_controller.checking) [g_controller runCheck];
        return;
    }
    g_controller = [[FCUResultsWindowController alloc] initWithEmptyMessage:@"No installed components were found."];
    bringForward(g_controller, true);
    [g_controller runCheck];
}

#ifdef FCU_DEBUG_HOOKS
size_t DebugRealiseResultsWindow(std::vector<CheckResult> const& results, size_t* visibleRows) {
    FCUResultsWindowController *controller = [[FCUResultsWindowController alloc] initWithEmptyMessage:@""];
    [controller showResults:results];
    if (visibleRows) *visibleRows = [controller visibleRowCount];
    return [controller realiseAllCells];
}

// Autotest: rows shown by the open window (-1 when closed) and whether it waits for a background check.
long DebugResultsWindowRows(bool* attached) {
    if (!g_controller) return -1;
    if (attached) *attached = [g_controller isAttached];
    return (long)[g_controller visibleRowCount];
}

std::string DebugResultsStatus() {
    return g_controller ? std::string([g_controller debugStatus].UTF8String) : std::string();
}

void DebugToggleBuiltIn() {
    if (g_controller) [g_controller debugToggleBuiltIn];
}

std::string DebugRestoreMenuItem(std::vector<CheckResult> const& results, std::string const& name, bool* enabled) {
    FCUResultsWindowController *controller = [[FCUResultsWindowController alloc] initWithEmptyMessage:@""];
    [controller showResults:results];
    NSMenuItem *item = [controller debugRestoreItemForName:ns(name)];
    if (enabled) *enabled = item.enabled;
    return item ? item.title.UTF8String : "";
}

long DebugSnapshotResultsWindow(std::vector<CheckResult> const& results, bool showBuiltIn, const char* pngPath) {
    bool saved = GetShowBuiltInComponents();
    SetShowBuiltInComponents(showBuiltIn);
    FCUResultsWindowController *controller = [[FCUResultsWindowController alloc] initWithEmptyMessage:@""];
    [controller showResults:results];
    [controller debugCheckFirstInstallable];
    [controller realiseAllCells];
    bool ok = DebugWriteSnapshot(controller.window.contentView, NSAppearanceNameAqua, [NSString stringWithUTF8String:pngPath]);
    SetShowBuiltInComponents(saved);
    g_lastLayout = [controller debugLayout].UTF8String;
    return ok ? (long)[controller visibleRowCount] : -1;
}
#endif

void DeliverCheckResults(int64_t checkId, std::vector<CheckResult> const& results, const char* emptyMessage, bool openIfClosed) {
    // Delivery ends the check (exactly once, on the main thread): until now no other check
    // could begin, so a later check can never replace the dismissal marker of this one.
    struct Release {
        ~Release() {
            EndUpdateCheck();
            [[NSNotificationCenter defaultCenter] postNotificationName:FCUUpdateCheckCompletedNotification object:nil];
        }
    } release;

    if (g_controller) {
        // The window attached to this check shows the results; a window of another check is left alone.
        if (g_controller.checkId == checkId && g_controller.checking) [g_controller finishCheckWithResults:results];
        return;
    }
    if (!openIfClosed || g_dismissedCheckId == checkId || checkId != CurrentUpdateCheckId()) return;
    g_controller = [[FCUResultsWindowController alloc] initWithEmptyMessage:[NSString stringWithUTF8String:emptyMessage]];
    g_controller.checkId = checkId;
    bringForward(g_controller, false);
    [g_controller showResults:results];
}
