#include "MigrationNotes.h"

#include <algorithm>
#include <mutex>
#include <set>

#include "../fb2k_sdk.h"
#include "../Core/mapping_validation.h"
#include "../UI/DebugSnapshot.h"
#include "../upstream/update_check.h"

namespace {

// {FD5423CC-F021-4C2B-A7E9-B0A211B85D27}
const GUID guid_cfg_migration_notes =
{ 0xfd5423cc, 0xf021, 0x4c2b, { 0xa7, 0xe9, 0xb0, 0xa2, 0x11, 0xb8, 0x5d, 0x27 } };

cfg_string g_cfgMigrationNotes(guid_cfg_migration_notes, ""); // one "from\tto\turl" line per staged switch
std::mutex g_notesMutex; // the read, change, write of the list

bool storable(std::string const& s) { return !s.empty() && s.find_first_of("\t\n") == std::string::npos; }

std::string lineOf(MigrationNote const& n) { return n.from + "\t" + n.to + "\t" + n.url + "\n"; }

std::vector<MigrationNote> stored() {
    std::string const all = g_cfgMigrationNotes.get().c_str();
    std::vector<MigrationNote> notes;
    size_t start = 0;
    for (size_t end; (end = all.find('\n', start)) != std::string::npos; start = end + 1) {
        std::string const line = all.substr(start, end - start);
        size_t const a = line.find('\t'), b = a == std::string::npos ? a : line.find('\t', a + 1);
        if (b != std::string::npos) notes.push_back({line.substr(0, a), line.substr(a + 1, b - a - 1), line.substr(b + 1)});
    }
    return notes;
}

void store(std::vector<MigrationNote> const& notes) {
    std::string all;
    for (auto const& n : notes) all += lineOf(n);
    g_cfgMigrationNotes = all.c_str();
}

NSString *ns(std::string const& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

// The alert offered after the restart; nil when the URL has no host.
NSAlert *noteAlert(MigrationNote const& note) {
    NSURL *url = [NSURL URLWithString:ns(note.url)];
    if (!url.host.length) return nil;
    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"%@ replaced %@", ns(note.to), ns(note.from)];
    alert.informativeText = [NSString stringWithFormat:@"Its author wrote migration notes on %@: what to set up again after the switch.", url.host];
    [alert addButtonWithTitle:@"Open Notes"];
    [alert addButtonWithTitle:@"Close"];
    return alert;
}

// One alert per note, one after the other; the page opens only on a click. A note is forgotten once shown.
void offer(std::vector<MigrationNote> notes, size_t index) {
    if (index >= notes.size() || fb2k::mainAborter().is_aborting()) return;
    MigrationNote const& note = notes[index];
    if (NSAlert *alert = noteAlert(note); alert && [alert runModal] == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:ns(note.url)]];
    }
    ForgetMigrationNote(note);
    offer(std::move(notes), index + 1);
}

class initquit_migration_notes : public initquit {
public:
    void on_init() override {
#ifdef FCU_DEBUG_HOOKS
        // The autotest takes the notes itself and shows nothing.
        if (fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.autotest")->length() > 0) return;
#endif
        std::vector<MigrationNote> notes = AppliedMigrationNotes();
        if (notes.empty()) return;
        // After the main window is up, so the alert does not open in front of an empty screen.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ offer(notes, 0); });
    }
};

FB2K_SERVICE_FACTORY(initquit_migration_notes);

} // namespace

void RememberMigrationNote(MigrationNote const& note) {
    if (!storable(note.from) || !storable(note.to) || !storable(note.url)) return;
    std::lock_guard<std::mutex> lock(g_notesMutex);
    std::vector<MigrationNote> notes = stored();
    notes.push_back(note);
    store(notes);
}

std::vector<MigrationNote> AppliedMigrationNotes() {
    std::set<std::string> loaded;
    for (auto const& c : GetInstalledComponents()) loaded.insert(fcu::normalizeComponentName(c.fileName));

    std::lock_guard<std::mutex> lock(g_notesMutex);
    std::vector<MigrationNote> applied;
    for (auto& note : stored()) {
        bool const done = loaded.count(fcu::normalizeComponentName(note.to)) && !loaded.count(fcu::normalizeComponentName(note.from));
        bool const seen = std::any_of(applied.begin(), applied.end(), [&](MigrationNote const& n) { return lineOf(n) == lineOf(note); });
        if (done && !seen) applied.push_back(std::move(note));
    }
    store(applied);
    return applied;
}

void ForgetMigrationNote(MigrationNote const& note) {
    std::lock_guard<std::mutex> lock(g_notesMutex);
    std::vector<MigrationNote> notes = stored();
    notes.erase(std::remove_if(notes.begin(), notes.end(), [&](MigrationNote const& n) { return lineOf(n) == lineOf(note); }), notes.end());
    store(notes);
}

#ifdef FCU_DEBUG_HOOKS
std::string DebugSnapshotMigrationAlert(MigrationNote const& note, const char* pngPath) {
    NSAlert *alert = noteAlert(note);
    if (!alert) return "";
    [alert layout];
    DebugWriteSnapshot(alert.window.contentView, NSAppearanceNameAqua, [NSString stringWithUTF8String:pngPath]);
    return std::string(alert.messageText.UTF8String) + "\n" + alert.informativeText.UTF8String;
}
#endif
