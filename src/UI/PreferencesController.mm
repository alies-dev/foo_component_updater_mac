#import "PreferencesController.h"

#include "../fb2k_sdk.h"
#include "../Core/triggers.h"
#include "../Integration/Settings.h"
#include "../upstream/automatic_check.h"
#include "../upstream/update_check.h"
#include "UpdatesPage.h"

namespace {

const CGFloat kMargin = 20;
const CGFloat kContentWidth = 440; // the settings block; the table below it takes the rest of the page
const CGFloat kGap = 16;
const CGFloat kIndent = 18;

NSString *const kSummary = @"Checks the third-party components you added for newer versions and installs the ones you choose. foobar2000 and its built in components are updated with foobar2000 itself, through its own update check.";

NSArray<NSArray<NSString *> *> *helpRows() {
    return @[
        @[@"Purpose", @"Reports newer versions of the third-party components you added to foobar2000 and lists them on this page. Nothing is installed until you tick an update in the list and click Install; the replaced version is kept for Restore Previous and the change applies after a restart."],
        @[@"Why", @"foobar2000\u2019s Check For New Versions covers foobar2000 and its built in components only, not the third-party components you added. Built in components update with foobar2000 and are not checked here."],
        @[@"Schedule", @"Shortly after foobar2000 starts, then every 6 hours while it is open, once the last check is at least the chosen number of days old. This page opens only when an update is found."],
        @[@"Manual", @"Check Now, or Help > Check for Third-Party Component Updates..."],
        @[@"Needed if", @"You added third-party components and want to know when they have newer versions."],
        @[@"Not needed if", @"You added none, or you prefer to check yourself. Turn off automatic checks, or remove this component in Preferences > Components."],
        @[@"Network", @"Contacts GitHub, foobar2000.org and a shared list of component sources on raw.githubusercontent.com. No personal data is sent."],
    ];
}

// Label/value grid like the suite's component info popover, with 14 and 12 point insets.
NSView *makeInfoView(NSArray<NSArray<NSString *> *> *rows) {
    NSMutableArray<NSArray<NSView *> *> *cells = [NSMutableArray array];
    for (NSArray<NSString *> *row in rows) {
        NSTextField *label = [NSTextField labelWithString:row[0]];
        label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        label.textColor = NSColor.secondaryLabelColor;
        NSTextField *value = [NSTextField wrappingLabelWithString:row[1]];
        value.font = [NSFont systemFontOfSize:12];
        value.textColor = NSColor.labelColor;
        value.selectable = YES;
        value.preferredMaxLayoutWidth = 280;
        [cells addObject:@[label, value]];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:cells];
    grid.rowSpacing = 8;
    grid.columnSpacing = 12;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    [content addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:content.topAnchor constant:12],
        [grid.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
        [grid.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [grid.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-14],
    ]];
    [content setFrameSize:content.fittingSize];
    return content;
}

// Transient popover; a second click on the same anchor closes it (keyed by the anchor).
void togglePopover(NSView *anchor, NSView *(^makeContent)(void), NSPopover *__strong *slot) {
    if (*slot && (*slot).shown) {
        [*slot close];
        return;
    }
    NSViewController *controller = [[NSViewController alloc] init];
    controller.view = makeContent();
    NSPopover *popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorTransient;
    popover.contentViewController = controller;
    *slot = popover;
    [popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSRectEdgeMaxY];
}

NSPopover *g_helpPopover = nil;

NSButton *makeHelpButton(id target, SEL action, NSString *tooltip, NSString *accessibility) {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.bezelStyle = NSBezelStyleHelpButton;
    button.title = @"";
    button.controlSize = NSControlSizeSmall;
    button.toolTip = tooltip;
    button.target = target;
    button.action = action;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = accessibility;
    return button;
}

} // namespace

// Opens (or closes) the help popover below `anchor`. Free function so another view can reuse it.
void FCUShowHelpPopover(NSView *anchor) {
    togglePopover(anchor, ^{ return makeInfoView(helpRows()); }, &g_helpPopover);
}

NSView *FCUMakeHelpContentView(void) { return makeInfoView(helpRows()); }

#ifdef FCU_DEBUG_HOOKS
// The controller whose view is on screen (weak: foobar2000 owns the controllers).
static __weak FCUPreferencesController *g_shownPage = nil;
#endif

@interface FCUFlippedView : NSView
@end
@implementation FCUFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface FCUPreferencesController () <NSTextFieldDelegate>
@end

@implementation FCUPreferencesController {
    NSStackView *_page;
    FCUUpdatesView *_updates;
    NSButton *_autoCheck, *_prereleases;
    NSStepper *_stepper;
    NSTextField *_interval, *_days, *_lastCheck;
    NSInteger _stepperValue; // the stepper's value after the last commit, to read the direction of a click
}

- (NSString *)preferencesTitle { return @"Component Updates"; }

- (void)loadView {
    // foobar2000 sizes the page; the settings block stays at the top left and the table takes the rest.
    self.view = [[FCUFlippedView alloc] initWithFrame:NSMakeRect(0, 0, 720, 560)];
    self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self buildUI];
    [self loadSettings];
    [self.view layoutSubtreeIfNeeded];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshLastCheck];
    // The page stays open while a check finishes: the time it shows would otherwise go stale.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshLastCheck)
                                                 name:FCUUpdateCheckCompletedNotification object:nil];
}

- (void)viewDidAppear {
    [super viewDidAppear];
#ifdef FCU_DEBUG_HOOKS
    g_shownPage = self;
#endif
    UpdatesPageVisibilityChanged(true);
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
#ifdef FCU_DEBUG_HOOKS
    if (g_shownPage == self) g_shownPage = nil;
#endif
    [[NSNotificationCenter defaultCenter] removeObserver:self name:FCUUpdateCheckCompletedNotification object:nil];
    UpdatesPageVisibilityChanged(false);
}

#pragma mark - Building blocks

- (NSTextField *)paragraph:(NSString *)text small:(BOOL)small {
    NSTextField *l = [NSTextField wrappingLabelWithString:text];
    l.preferredMaxLayoutWidth = kContentWidth;
    l.font = small ? [NSFont systemFontOfSize:NSFont.smallSystemFontSize] : [NSFont systemFontOfSize:NSFont.systemFontSize];
    l.textColor = small ? NSColor.secondaryLabelColor : NSColor.labelColor;
    l.selectable = NO;
    return l;
}

- (NSStackView *)vertical:(NSArray<NSView *> *)views spacing:(CGFloat)spacing {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = spacing;
    return s;
}

- (NSView *)spacer {
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    [v setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [v setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return v;
}

#pragma mark - Page

- (void)buildUI {
    NSTextField *title = [NSTextField labelWithString:@"Third-Party Component Updates"];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightRegular];
    NSTextField *summary = [self paragraph:kSummary small:YES];

    // Automatic check row: toggle and interval on the left, Check Now on the right.
    _autoCheck = [NSButton checkboxWithTitle:@"Check automatically every" target:self action:@selector(autoCheckChanged:)];
    _autoCheck.toolTip = @"Runs shortly after foobar2000 starts and every 6 hours while it is open, once enough days have passed since the last check. This page opens only when an update is found.";

    // No number formatter: the text is read by fcu::parseIntervalInput when editing ends
    // (clamped to 1 to 30, or reverted when it is not a number), never by a formatter alert.
    _interval = [NSTextField textFieldWithString:@"7"];
    _interval.alignment = NSTextAlignmentRight;
    _interval.delegate = self;
    _interval.target = self;
    _interval.action = @selector(intervalFieldChanged:);
    ((NSTextFieldCell *)_interval.cell).sendsActionOnEndEditing = YES;
    _interval.toolTip = @"Days between automatic checks (1 to 30)";
    _interval.translatesAutoresizingMaskIntoConstraints = NO;
    [_interval.widthAnchor constraintEqualToConstant:36].active = YES;

    _stepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    _stepper.minValue = 1;
    _stepper.maxValue = 30;
    _stepper.increment = 1;
    _stepper.valueWraps = NO;
    _stepper.target = self;
    _stepper.action = @selector(intervalChanged:);
    _stepper.toolTip = @"Days between automatic checks (1 to 30)";
    _stepper.accessibilityLabel = @"Days between automatic checks";

    _days = [NSTextField labelWithString:@"days"];
    NSButton *checkNow = [NSButton buttonWithTitle:@"Check Now" target:self action:@selector(checkNow:)];
    checkNow.toolTip = @"Checks all added third-party components now. Also in Help > Check for Third-Party Component Updates...";

    NSStackView *autoRow = [NSStackView stackViewWithViews:@[_autoCheck, _interval, _stepper, _days, [self spacer], checkNow]];
    autoRow.spacing = 4;
    autoRow.translatesAutoresizingMaskIntoConstraints = NO;
    [autoRow.widthAnchor constraintEqualToConstant:kContentWidth].active = YES;

    _lastCheck = [self paragraph:@"" small:YES];
    NSStackView *lastRow = [NSStackView stackViewWithViews:@[_lastCheck]];
    lastRow.edgeInsets = NSEdgeInsetsMake(0, kIndent, 0, 0);

    _prereleases = [NSButton checkboxWithTitle:@"Include prereleases" target:self action:@selector(prereleasesChanged:)];
    NSTextField *prereleasesHelp = [self paragraph:@"Also offers beta and test versions, which may be less stable." small:YES];
    prereleasesHelp.preferredMaxLayoutWidth = kContentWidth - kIndent;
    NSStackView *prereleasesRow = [NSStackView stackViewWithViews:@[prereleasesHelp]];
    prereleasesRow.edgeInsets = NSEdgeInsetsMake(0, kIndent, 0, 0);

    NSTextField *listLabel = [self paragraph:@"Installed third-party components" small:YES];

    _page = [self vertical:@[title, summary, autoRow, lastRow, _prereleases, prereleasesRow, listLabel] spacing:6];
    [_page setCustomSpacing:4 afterView:title];
    [_page setCustomSpacing:16 afterView:summary];
    [_page setCustomSpacing:2 afterView:autoRow];
    [_page setCustomSpacing:10 afterView:lastRow];
    [_page setCustomSpacing:2 afterView:_prereleases];
    [_page setCustomSpacing:kGap afterView:prereleasesRow];
    _page.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_page];

    _updates = [[FCUUpdatesView alloc] initWithFrame:NSZeroRect];
    _updates.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_updates];

    NSButton *help = makeHelpButton(self, @selector(showHelp:), @"About Third-Party Component Updates", @"About Third-Party Component Updates");
    [self.view addSubview:help];
    NSLayoutConstraint *minHeight = [_updates.heightAnchor constraintGreaterThanOrEqualToConstant:160];
    minHeight.priority = 750; // a very short pane squeezes the table rather than breaking the layout
    [NSLayoutConstraint activateConstraints:@[
        [_page.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kMargin],
        [_page.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kMargin],
        [_page.widthAnchor constraintEqualToConstant:kContentWidth],
        [_updates.topAnchor constraintEqualToAnchor:_page.bottomAnchor constant:6],
        [_updates.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kMargin],
        [_updates.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kMargin],
        [_updates.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-kMargin],
        minHeight,
        [help.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kMargin],
        [help.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
    ]];
}

- (void)showHelp:(NSButton *)sender { FCUShowHelpPopover(sender); }

#ifdef FCU_DEBUG_HOOKS
// Autotest: the page's top left corner and the view's size.
- (NSString *)debugGeometry {
    return [NSString stringWithFormat:@"page y=%.0f x=%.0f, view %.0fx%.0f", _page.frame.origin.y, _page.frame.origin.x,
            self.view.frame.size.width, self.view.frame.size.height];
}

- (NSView *)debugUpdatesView { return _updates; }

- (NSString *)debugLastCheckText { return _lastCheck.stringValue; }

- (NSString *)debugShownGeometry {
    NSView *page = self.view;
    NSSize super_ = page.superview.frame.size;
    NSSize updates = _updates.frame.size;
    return [NSString stringWithFormat:@"page %.0fx%.0f in superview %.0fx%.0f, updates %.0fx%.0f", page.frame.size.width,
            page.frame.size.height, super_.width, super_.height, updates.width, updates.height];
}

- (NSString *)debugShownGeometryNumbers {
    NSSize page = self.view.frame.size;
    NSSize super_ = self.view.superview.frame.size;
    return [NSString stringWithFormat:@"%.2f %.2f %.2f %.2f %.2f", page.width, page.height, super_.width, super_.height,
            _updates.frame.size.height];
}

- (void)debugClosePreferencesWindow { [self.view.window performClose:nil]; }

NSString *FCUDebugShownPreferencesGeometry(void) {
    FCUPreferencesController *shown = g_shownPage;
    return shown ? [shown debugShownGeometry] : @"";
}

NSString *FCUDebugShownPreferencesNumbers(void) {
    FCUPreferencesController *shown = g_shownPage;
    return shown ? [shown debugShownGeometryNumbers] : @"";
}

void FCUDebugClosePreferencesWindow(void) { [g_shownPage debugClosePreferencesWindow]; }
#endif

#pragma mark - Settings

- (void)refreshLastCheck {
    int64_t last = GetAutomaticCheckLastRun();
    if (last <= 0) {
        _lastCheck.stringValue = @"Last check: never";
        _lastCheck.toolTip = nil;
        return;
    }
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)last];
    NSDateFormatter *relative = [NSDateFormatter new];
    relative.dateStyle = NSDateFormatterMediumStyle;
    relative.timeStyle = NSDateFormatterShortStyle;
    relative.doesRelativeDateFormatting = YES;
    NSDateFormatter *absolute = [NSDateFormatter new];
    absolute.dateStyle = NSDateFormatterMediumStyle;
    absolute.timeStyle = NSDateFormatterShortStyle;
    _lastCheck.stringValue = [@"Last check: " stringByAppendingString:[relative stringFromDate:date]];
    _lastCheck.toolTip = [absolute stringFromDate:date];
}

- (void)updateIntervalControls {
    BOOL on = _autoCheck.state == NSControlStateValueOn;
    _interval.enabled = on;
    _stepper.enabled = on;
    _days.textColor = on ? NSColor.labelColor : NSColor.disabledControlTextColor;
}

- (void)loadSettings {
    _autoCheck.state = GetAutomaticCheckEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    _stepper.integerValue = GetAutomaticCheckIntervalDays();
    _stepperValue = _stepper.integerValue;
    _interval.integerValue = _stepper.integerValue;
    [self updateIntervalControls];
    _prereleases.state = GetIncludePrereleases() ? NSControlStateValueOn : NSControlStateValueOff;
    [self refreshLastCheck];
}

- (void)autoCheckChanged:(id)sender {
    SetAutomaticCheckEnabled(_autoCheck.state == NSControlStateValueOn);
    [self updateIntervalControls];
}

- (void)applyInterval:(NSInteger)days {
    days = MAX(1, MIN(30, days));
    SetAutomaticCheckIntervalDays((int)days);
    _stepper.integerValue = days;
    _stepperValue = days;
    _interval.integerValue = days;
}

// What is typed in the field, as a valid interval (the saved value when it is not a number).
- (NSInteger)typedInterval {
    return fcu::parseIntervalInput(_interval.stringValue.UTF8String, GetAutomaticCheckIntervalDays());
}

// A stepper click moves the typed value, not the stepper's own: pending valid input is
// committed first, so typing 12 and clicking up gives 13.
- (void)intervalChanged:(id)sender {
    NSInteger delta = _stepper.integerValue - _stepperValue;
    [self applyInterval:[self typedInterval] + delta];
}

- (void)intervalFieldChanged:(id)sender {
    [self applyInterval:[self typedInterval]];
}

// Valid pending text moves the stepper too, so a click always starts from the typed value
// (at 30 a click up after typing 12 must give 13, not stay at the stepper's own 30).
- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object != _interval) return;
    int typed = fcu::parseIntervalInput(_interval.stringValue.UTF8String, -1);
    if (typed < 1) return;
    _stepper.integerValue = typed;
    _stepperValue = typed;
}

// Tabbing away or clicking elsewhere commits as well as Return does.
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object == _interval) [self applyInterval:[self typedInterval]];
}

#ifdef FCU_DEBUG_HOOKS
// Autotest: types `text` and ends editing; returns the saved interval and leaves the field text readable.
- (NSInteger)debugTypeInterval:(NSString *)text {
    _interval.stringValue = text;
    [self controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:_interval]];
    return GetAutomaticCheckIntervalDays();
}

// Autotest: types `text` without committing, then clicks the stepper up (+1) or down (-1).
- (NSInteger)debugTypeThenStep:(NSString *)text direction:(NSInteger)direction {
    _interval.stringValue = text;
    [self controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:_interval]];
    _stepper.integerValue = MAX(1, MIN(30, _stepper.integerValue + direction));
    [self intervalChanged:_stepper];
    return GetAutomaticCheckIntervalDays();
}

- (NSString *)debugIntervalFieldText { return _interval.stringValue; }
#endif

- (void)prereleasesChanged:(id)sender {
    SetIncludePrereleases(_prereleases.state == NSControlStateValueOn);
}

- (void)checkNow:(id)sender {
    ShowUpdatesPage();
}

@end
