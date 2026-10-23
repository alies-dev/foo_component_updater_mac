#import "PreferencesController.h"

#include "../fb2k_sdk.h"
#include "../Core/mapping_validation.h"
#include "../Core/triggers.h"
#include "../Integration/Settings.h"
#include "../upstream/automatic_check.h"
#include "../upstream/repository_mapping.h"
#include "../upstream/update_check.h"
#include "ResultsWindow.h"

#import <objc/runtime.h>

namespace {

const CGFloat kPageWidth = 480;
const CGFloat kMargin = 20;
const CGFloat kContentWidth = kPageWidth - 2 * kMargin;
const CGFloat kIndent = 18;

NSString *const kSummary = @"Finds newer versions of components you added, which foobar2000\u2019s own update check does not cover, and installs the ones you choose.";

NSString *const kSourcesPlaceholder =
    @"[{ \"dll\": \"foo_example\", \"source\": \"github\",\n   \"owner\": \"author\", \"repo\": \"foo_example\" }]";

NSArray<NSArray<NSString *> *> *helpRows() {
    return @[
        @[@"Purpose", @"Reports newer versions of the components you added to foobar2000 and lists them in a window. Nothing is installed until you tick an update there and click Install; the replaced version is kept for Restore Previous and the change applies after a restart."],
        @[@"Why", @"foobar2000\u2019s Check For New Versions covers foobar2000 only, not components you added. Built in components update with foobar2000 and are not checked here."],
        @[@"Schedule", @"Shortly after foobar2000 starts, then every 6 hours while it is open, once the last check is at least the chosen number of days old. A window opens only when an update is found."],
        @[@"Manual", @"Check Now, or Help > Check for Component Updates..."],
        @[@"Needed if", @"You added components and want to know when they have newer versions."],
        @[@"Not needed if", @"You added none, or you prefer to check yourself. Turn off automatic checks, or remove this component in Preferences > Components."],
        @[@"Network", @"Contacts GitHub, foobar2000.org and a shared list of component sources on raw.githubusercontent.com. No personal data is sent."],
    ];
}

// Starter text of "Insert Example"; the full format is in docs/custom-sources.md.
NSString *const kRepositoryExample =
    @"[{ \"dll\": \"foo_example\", \"source\": \"github\",\n   \"owner\": \"author\", \"repo\": \"foo_example\" }]";
NSString *const kSourcesDocUrl = @"https://github.com/alies-dev/foo_component_updater_mac/blob/main/docs/custom-sources.md";

NSArray<NSArray<NSString *> *> *sourcesHelpRows() {
    return @[
        @[@"About", @"For components marked \u201CNo source\u201D in the results. Each entry tells the updater where that component\u2019s author publishes releases."],
        @[@"Name", @"dll is the name in brackets in the Component column."],
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

} // namespace

// Target of the "Format and examples" link button.
@interface FCUDocLink : NSObject
- (void)open:(id)sender;
@end
@implementation FCUDocLink
- (void)open:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kSourcesDocUrl]];
}
@end

namespace {

// The short custom sources help: two rows and a link to the full format and examples.
NSView *makeSourcesHelpView() {
    NSView *info = makeInfoView(sourcesHelpRows());
    info.translatesAutoresizingMaskIntoConstraints = NO;

    FCUDocLink *target = [FCUDocLink new];
    NSButton *link = [NSButton buttonWithTitle:@"" target:target action:@selector(open:)];
    link.bordered = NO;
    link.attributedTitle = [[NSAttributedString alloc] initWithString:@"Format and examples\u2026" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)}];
    link.toolTip = kSourcesDocUrl;
    link.translatesAutoresizingMaskIntoConstraints = NO;
    objc_setAssociatedObject(link, "fcu.docLink", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC); // the button only holds its target weakly

    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    [content addSubview:info];
    [content addSubview:link];
    [NSLayoutConstraint activateConstraints:@[
        [info.topAnchor constraintEqualToAnchor:content.topAnchor],
        [info.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [info.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [link.topAnchor constraintEqualToAnchor:info.bottomAnchor constant:-4],
        [link.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:14],
        [link.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-12],
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

// Opens (or closes) the help popover below `anchor`. Free function so another window can reuse it.
void FCUShowHelpPopover(NSView *anchor) {
    togglePopover(anchor, ^{ return makeInfoView(helpRows()); }, &g_helpPopover);
}

NSView *FCUMakeHelpContentView(void) { return makeInfoView(helpRows()); }
NSView *FCUMakeSourcesHelpContentView(void) { return makeSourcesHelpView(); }

@interface FCUFlippedView : NSView
@end
@implementation FCUFlippedView
- (BOOL)isFlipped { return YES; }
@end

// Grey example shown while the sources box is empty; never takes the mouse.
@interface FCUPlaceholderLabel : NSTextField
@end
@implementation FCUPlaceholderLabel
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface FCUPreferencesController () <NSTextViewDelegate, NSTextFieldDelegate>
@end

@implementation FCUPreferencesController {
    NSStackView *_page;
    NSButton *_autoCheck, *_prereleases, *_disclosure, *_save, *_insertExample;
    NSStepper *_stepper;
    NSTextField *_interval, *_days, *_lastCheck, *_message;
    NSTextView *_sources;
    FCUPlaceholderLabel *_placeholder;
    NSStackView *_advanced;
    NSPopover *_fieldsPopover;
    NSString *_savedSources;
    NSInteger _messageToken;
    NSInteger _stepperValue; // the stepper's value after the last commit, to read the direction of a click
}

- (NSString *)preferencesTitle { return @"Component Updates"; }

- (void)loadView {
    self.view = [[FCUFlippedView alloc] initWithFrame:NSMakeRect(0, 0, kPageWidth, 300)];
    [self buildUI];
    [self loadSettings];
    [self sizeViewOnce];
}

- (void)viewWillAppear {
    [super viewWillAppear];
    [self refreshLastCheck];
    // The page stays open while a check finishes: the time it shows would otherwise go stale.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshLastCheck)
                                                 name:FCUUpdateCheckCompletedNotification object:nil];
}

- (void)viewDidDisappear {
    [super viewDidDisappear];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:FCUUpdateCheckCompletedNotification object:nil];
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
    NSTextField *title = [NSTextField labelWithString:@"Component Updates"];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightRegular];
    NSTextField *summary = [self paragraph:kSummary small:YES];

    // Automatic check row: toggle and interval on the left, Check Now on the right.
    _autoCheck = [NSButton checkboxWithTitle:@"Check automatically every" target:self action:@selector(autoCheckChanged:)];
    _autoCheck.toolTip = @"Runs shortly after foobar2000 starts and every 6 hours while it is open, once enough days have passed since the last check. A window opens only when an update is found.";

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
    checkNow.toolTip = @"Checks all added components now. Also in Help > Check for Component Updates...";

    NSStackView *autoRow = [NSStackView stackViewWithViews:@[_autoCheck, _interval, _stepper, _days, [self spacer], checkNow]];
    autoRow.spacing = 4;
    autoRow.translatesAutoresizingMaskIntoConstraints = NO;
    [autoRow.widthAnchor constraintEqualToConstant:kContentWidth].active = YES;

    _lastCheck = [self paragraph:@"" small:YES];
    NSStackView *lastRow = [NSStackView stackViewWithViews:@[_lastCheck]];
    lastRow.edgeInsets = NSEdgeInsetsMake(0, kIndent, 0, 0);

    _prereleases = [NSButton checkboxWithTitle:@"Include prereleases" target:self action:@selector(prereleasesChanged:)];
    _prereleases.toolTip = @"Also reports versions the author marks as not final. They may be less stable.";

    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [separator.widthAnchor constraintEqualToConstant:kContentWidth].active = YES;

    // Disclosure: triangle button plus a label that toggles as well.
    NSString *disclosureTip = @"Tells the updater where to find components that show \u201CNo source\u201D in the results.";
    _disclosure = [[NSButton alloc] initWithFrame:NSZeroRect];
    _disclosure.bezelStyle = NSBezelStyleDisclosure;
    [_disclosure setButtonType:NSButtonTypePushOnPushOff];
    _disclosure.title = @"";
    _disclosure.target = self;
    _disclosure.action = @selector(toggleAdvanced:);
    _disclosure.toolTip = disclosureTip;
    _disclosure.accessibilityLabel = @"Custom sources";
    NSTextField *disclosureLabel = [NSTextField labelWithString:@"Custom sources"];
    disclosureLabel.toolTip = disclosureTip;
    [disclosureLabel addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(toggleAdvanced:)]];
    NSStackView *disclosureRow = [NSStackView stackViewWithViews:@[_disclosure, disclosureLabel]];
    disclosureRow.spacing = 4;

    // Custom sources block, hidden until expanded.
    NSTextField *caption = [NSTextField labelWithString:@"For components that show \u201CNo source\u201D in the results."];
    caption.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    caption.textColor = NSColor.secondaryLabelColor;
    NSButton *fieldsHelp = makeHelpButton(self, @selector(showFieldsHelp:), @"How to add a source", @"Custom sources help");
    NSStackView *captionRow = [NSStackView stackViewWithViews:@[caption, [self spacer], fieldsHelp]];
    captionRow.translatesAutoresizingMaskIntoConstraints = NO;
    [captionRow.widthAnchor constraintEqualToConstant:kContentWidth - kIndent].active = YES;

    const CGFloat sourcesWidth = kContentWidth - kIndent;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, sourcesWidth, 88)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.toolTip = @"A JSON array of entries. Use the help button for the fields.";
    [scroll.widthAnchor constraintEqualToConstant:sourcesWidth].active = YES;
    [scroll.heightAnchor constraintEqualToConstant:88].active = YES;
    _sources = [[NSTextView alloc] initWithFrame:scroll.bounds];
    _sources.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _sources.textColor = NSColor.textColor;
    _sources.backgroundColor = NSColor.textBackgroundColor;
    _sources.automaticQuoteSubstitutionEnabled = NO;
    _sources.automaticDashSubstitutionEnabled = NO;
    _sources.automaticTextReplacementEnabled = NO;
    _sources.richText = NO;
    _sources.verticallyResizable = YES;
    _sources.autoresizingMask = NSViewWidthSizable;
    _sources.delegate = self;
    scroll.documentView = _sources;

    _placeholder = [FCUPlaceholderLabel labelWithString:kSourcesPlaceholder];
    _placeholder.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _placeholder.textColor = NSColor.placeholderTextColor;
    _placeholder.frame = NSMakeRect(7, 0, sourcesWidth - 14, 32);
    [_sources addSubview:_placeholder];

    _save = [NSButton buttonWithTitle:@"Save Sources" target:self action:@selector(saveSources:)];
    _save.toolTip = @"Applies the sources above. Other settings on this page save immediately.";
    _message = [NSTextField wrappingLabelWithString:@""];
    _message.preferredMaxLayoutWidth = kContentWidth - kIndent - 230;
    _message.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _message.lineBreakMode = NSLineBreakByTruncatingTail;
    _message.maximumNumberOfLines = 2;
    _insertExample = [NSButton buttonWithTitle:@"Insert Example" target:self action:@selector(insertExample:)];
    _insertExample.bezelStyle = NSBezelStyleInline;
    _insertExample.controlSize = NSControlSizeSmall;
    _insertExample.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    _insertExample.toolTip = @"Inserts a GitHub entry to edit";
    NSStackView *saveRow = [NSStackView stackViewWithViews:@[_save, _insertExample, _message]];
    saveRow.spacing = 10;
    saveRow.alignment = NSLayoutAttributeCenterY;

    _advanced = [self vertical:@[captionRow, scroll, saveRow] spacing:6];
    [_advanced setCustomSpacing:8 afterView:scroll];
    _advanced.edgeInsets = NSEdgeInsetsMake(0, kIndent, 0, 0);
    _advanced.hidden = YES;

    _page = [self vertical:@[title, summary, autoRow, lastRow, _prereleases, separator, disclosureRow, _advanced] spacing:6];
    [_page setCustomSpacing:4 afterView:title];
    [_page setCustomSpacing:16 afterView:summary];
    [_page setCustomSpacing:2 afterView:autoRow];
    [_page setCustomSpacing:10 afterView:lastRow];
    [_page setCustomSpacing:16 afterView:_prereleases];
    [_page setCustomSpacing:16 afterView:separator];
    [_page setCustomSpacing:8 afterView:disclosureRow];
    _page.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_page];

    NSButton *help = makeHelpButton(self, @selector(showHelp:), @"About Component Updates", @"About Component Updates");
    [self.view addSubview:help];
    [NSLayoutConstraint activateConstraints:@[
        [_page.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:kMargin],
        [_page.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:kMargin],
        [_page.widthAnchor constraintEqualToConstant:kContentWidth],
        [help.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-kMargin],
        [help.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
    ]];
}

// One fixed frame for the page, set once: the expanded height (Custom sources open, a two
// line message). The host repositions a page whose frame changes, so expanding or collapsing
// only hides or shows the section and never touches the frame; the space below the content
// stays empty when collapsed. The page is pinned to the top of this flipped view. Never ask
// the host to resize its window (no preferred content size).
- (void)sizeViewOnce {
    BOOL wasHidden = _advanced.hidden;
    _advanced.hidden = NO;
    [self.view layoutSubtreeIfNeeded];
    CGFloat height = _page.fittingSize.height + 2 * kMargin + 16;
    _advanced.hidden = wasHidden;
    [self.view setFrameSize:NSMakeSize(kPageWidth, height)];
    [self.view layoutSubtreeIfNeeded];
}

- (void)toggleAdvanced:(id)sender {
    BOOL show = _advanced.hidden;
    _advanced.hidden = !show;
    _disclosure.state = show ? NSControlStateValueOn : NSControlStateValueOff;
    [self.view layoutSubtreeIfNeeded];
}

- (void)showHelp:(NSButton *)sender { FCUShowHelpPopover(sender); }

- (void)showFieldsHelp:(NSButton *)sender { togglePopover(sender, ^{ return makeSourcesHelpView(); }, &_fieldsPopover); }

- (void)insertExample:(id)sender {
    if (_sources.string.length > 0) return;
    _sources.string = kRepositoryExample;
    [self updatePlaceholderAndSave];
    [self clearMessage];
}

#ifdef FCU_DEBUG_HOOKS
// Autotest: the page's top left corner and the view's size, to prove the toggle does not move them.
- (NSString *)debugGeometry {
    return [NSString stringWithFormat:@"page y=%.0f x=%.0f, view %.0fx%.0f", _page.frame.origin.y, _page.frame.origin.x,
            self.view.frame.size.width, self.view.frame.size.height];
}

- (NSString *)debugLastCheckText { return _lastCheck.stringValue; }

- (void)debugExpandAdvanced {
    if (_advanced.hidden) [self toggleAdvanced:nil];
}
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

- (void)updatePlaceholderAndSave {
    _placeholder.hidden = _sources.string.length > 0;
    _save.enabled = ![_sources.string isEqualToString:_savedSources];
    _insertExample.enabled = _sources.string.length == 0;
}

- (void)loadSettings {
    _autoCheck.state = GetAutomaticCheckEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    _stepper.integerValue = GetAutomaticCheckIntervalDays();
    _stepperValue = _stepper.integerValue;
    _interval.integerValue = _stepper.integerValue;
    [self updateIntervalControls];
    _prereleases.state = GetIncludePrereleases() ? NSControlStateValueOn : NSControlStateValueOff;
    [self showSavedSources];
    [self refreshLastCheck];
}

// An empty list shows the grey example, not "[]".
- (void)showSavedSources {
    auto entries = loadRepositoryMapping();
    _savedSources = entries.empty() ? @"" : [NSString stringWithUTF8String:fcu::formatUserMappings(entries).c_str()];
    _sources.string = _savedSources;
    [self updatePlaceholderAndSave];
}

- (void)textDidChange:(NSNotification *)notification {
    [self updatePlaceholderAndSave];
    [self clearMessage];
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

// Autotest: clicks Insert Example on an empty box; returns the box text, "" when the button was disabled.
// A second click must do nothing (the box is not empty any more).
- (NSString *)debugInsertExample:(BOOL *)enabledWhenEmpty enabledWhenFilled:(BOOL *)enabledWhenFilled {
    _sources.string = @"";
    [self updatePlaceholderAndSave];
    *enabledWhenEmpty = _insertExample.enabled;
    [self insertExample:nil];
    NSString *text = [_sources.string copy]; // the text view hands out its live backing string
    *enabledWhenFilled = _insertExample.enabled;
    _sources.string = @"";
    [self updatePlaceholderAndSave];
    return text;
}

- (NSString *)debugIntervalFieldText { return _interval.stringValue; }
#endif

- (void)prereleasesChanged:(id)sender {
    SetIncludePrereleases(_prereleases.state == NSControlStateValueOn);
}

- (BOOL)applySourcesText:(NSString *)text message:(NSString **)message {
    std::vector<RepositoryMappingEntry> entries;
    std::string error;
    if (!fcu::parseUserMappings(text.UTF8String, entries, error)) {
        if (message) *message = [NSString stringWithUTF8String:error.c_str()];
        return NO;
    }
    saveRepositoryMapping(entries);
    if (message) *message = @"Saved";
    return YES;
}

- (void)clearMessage {
    ++_messageToken;
    _message.stringValue = @"";
    _message.toolTip = nil;
}

- (void)saveSources:(id)sender {
    NSString *message = nil;
    BOOL ok = [self applySourcesText:_sources.string message:&message];
    NSInteger token = ++_messageToken;
    if (ok) {
        [self showSavedSources];
        _message.textColor = NSColor.secondaryLabelColor;
        _message.stringValue = @"Saved";
        _message.toolTip = nil;
        __weak FCUPreferencesController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            FCUPreferencesController *strongSelf = weakSelf;
            if (strongSelf && strongSelf->_messageToken == token) [strongSelf clearMessage];
        });
    } else {
        NSString *full = [@"Not saved. " stringByAppendingString:message ?: @""];
        _message.textColor = NSColor.systemRedColor;
        _message.stringValue = full;
        _message.toolTip = full;
    }
}

- (void)checkNow:(id)sender {
    ShowUpdateResultWindow();
}

@end
