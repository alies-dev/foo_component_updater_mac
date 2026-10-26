#pragma once

#include <string>
#include <vector>

// The migration notes page a successor declares (FB2KReplacedBy "migration"), offered once after the switch.
struct MigrationNote {
    std::string from, to; // file names: the removed component and its successor
    std::string url;      // https page, validated by the parser
};

// Remembers the page of a switch that was just staged; foobar2000 applies it at the next start. Any thread.
void RememberMigrationNote(MigrationNote const& note);

// Main thread. The remembered notes whose switch foobar2000 applied at this start (the successor is loaded and the old
// component is not); every remembered note is forgotten, so each page is offered at most once.
std::vector<MigrationNote> TakeAppliedMigrationNotes();
