#pragma once

#include <string>
#include <vector>

// The migration notes page a successor declares (FB2KReplacedBy "migration_url"), offered once after the switch.
struct MigrationNote {
    std::string from, to; // file names: the removed component and its successor
    std::string url;      // https page, validated by the parser
};

// Remembers the page of a switch that was just staged; foobar2000 applies it at the next start. Any thread.
void RememberMigrationNote(MigrationNote const& note);

// Main thread. The remembered notes whose switch foobar2000 applied (the successor is loaded and the old component is
// not). Notes of switches that did not happen are forgotten; applied ones stay until ForgetMigrationNote.
std::vector<MigrationNote> AppliedMigrationNotes();

// Once the note was offered; a quit before that keeps it for the next start.
void ForgetMigrationNote(MigrationNote const& note);
