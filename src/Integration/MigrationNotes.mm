#include "MigrationNotes.h"

#include <algorithm>
#include <set>

#include "../fb2k_sdk.h"
#include "../Core/mapping_validation.h"
#include "../upstream/update_check.h"

namespace {

// {FD5423CC-F021-4C2B-A7E9-B0A211B85D27}
const GUID guid_cfg_migration_notes =
{ 0xfd5423cc, 0xf021, 0x4c2b, { 0xa7, 0xe9, 0xb0, 0xa2, 0x11, 0xb8, 0x5d, 0x27 } };

cfg_string g_cfgMigrationNotes(guid_cfg_migration_notes, ""); // one "from\tto\turl" line per staged switch

bool storable(std::string const& s) { return !s.empty() && s.find_first_of("\t\n") == std::string::npos; }

NSString *ns(std::string const& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

// One alert per note, one after the other; the page opens only on a click.
void offer(std::vector<MigrationNote> notes, size_t index) {
    if (index >= notes.size() || fb2k::mainAborter().is_aborting()) return;
    MigrationNote const& note = notes[index];
    NSURL *url = [NSURL URLWithString:ns(note.url)];
    if (url.host.length) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"%@ replaced %@", ns(note.to), ns(note.from)];
        alert.informativeText = [NSString stringWithFormat:@"Its author wrote migration notes on %@: what to set up again after the switch.", url.host];
        [alert addButtonWithTitle:@"Open Notes"];
        [alert addButtonWithTitle:@"Close"];
        if ([alert runModal] == NSAlertFirstButtonReturn) [[NSWorkspace sharedWorkspace] openURL:url];
    }
    offer(std::move(notes), index + 1);
}

class initquit_migration_notes : public initquit {
public:
    void on_init() override {
#ifdef FCU_DEBUG_HOOKS
        // The autotest takes the notes itself and shows nothing.
        if (fb2k::configStore::get()->getConfigString("foo_component_updater_mac.debug.autotest")->length() > 0) return;
#endif
        std::vector<MigrationNote> notes = TakeAppliedMigrationNotes();
        if (notes.empty()) return;
        // After the main window is up, so the alert does not open in front of an empty screen.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ offer(notes, 0); });
    }
};

FB2K_SERVICE_FACTORY(initquit_migration_notes);

} // namespace

void RememberMigrationNote(MigrationNote const& note) {
    if (!storable(note.from) || !storable(note.to) || !storable(note.url)) return;
    std::string all = g_cfgMigrationNotes.get().c_str();
    all += note.from + "\t" + note.to + "\t" + note.url + "\n";
    g_cfgMigrationNotes = all.c_str();
}

std::vector<MigrationNote> TakeAppliedMigrationNotes() {
    std::string const all = g_cfgMigrationNotes.get().c_str();
    if (all.empty()) return {};
    g_cfgMigrationNotes = "";

    std::set<std::string> loaded;
    for (auto const& c : GetInstalledComponents()) loaded.insert(fcu::normalizeComponentName(c.fileName));

    std::vector<MigrationNote> applied;
    size_t start = 0;
    for (size_t end; (end = all.find('\n', start)) != std::string::npos; start = end + 1) {
        std::string const line = all.substr(start, end - start);
        size_t const a = line.find('\t'), b = a == std::string::npos ? a : line.find('\t', a + 1);
        if (b == std::string::npos) continue;
        MigrationNote note{line.substr(0, a), line.substr(a + 1, b - a - 1), line.substr(b + 1)};
        bool const done = loaded.count(fcu::normalizeComponentName(note.to)) && !loaded.count(fcu::normalizeComponentName(note.from));
        bool const seen = std::any_of(applied.begin(), applied.end(), [&](MigrationNote const& n) { return n.to == note.to && n.url == note.url; });
        if (done && !seen) applied.push_back(std::move(note));
    }
    return applied;
}
