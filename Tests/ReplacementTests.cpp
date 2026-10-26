// TEST_DEPS: src/Core/replacement.cpp src/Core/mapping_validation.cpp src/upstream/update_parse.cpp
#include "TestHarness.h"
#include "Fixtures.h"
#include "../src/Core/replacement.h"

using namespace fcu;

static void rejects(char const* json, char const* messagePart) {
    Replacement out;
    out.name = "keep";
    std::string err;
    CHECK(!parseReplacedBy(json, out, err), json);
    CHECK(err.rfind("Invalid FB2KReplacedBy: ", 0) == 0 && err.find(messagePart) != std::string::npos, (std::string(json) + " -> " + err).c_str());
    CHECK(out.name == "keep", "previous value untouched on failure");
}

int main() {
    Replacement r;
    std::string err;

    g_context = "FB2KReplacedBy";
    CHECK(parseReplacedBy("{\"component\":\"Foo_New.dll\"}", r, err) && r.name == "Foo_New" && !r.hasSource && r.migration.empty() && r.team.empty(),
          "name only: case kept (it names the package and folders), \".dll\" dropped");
    CHECK(parseReplacedBy("{\"component\":\"foo_new\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\"}", r, err), "with a source");
    CHECK(r.hasSource && r.source.dllName == "foo_new" && r.source.source == "github" && r.source.owner == "o" && r.source.repo == "r", "source belongs to the successor");
    CHECK(parseReplacedBy("{\"component\":\"foo_new\",\"source\":\"hyv\",\"url\":\"https://foobar.hyv.fi/?view=foo_new\"}", r, err) && r.source.url.size(), "url source");
    CHECK(parseReplacedBy("{\"component\":\"foo_new\",\"migration_url\":\"https://github.com/o/r#migrating\",\"team\":\"ABCDE12345\"}", r, err)
          && r.migration == "https://github.com/o/r#migrating" && r.team == "ABCDE12345" && !r.hasSource, "migration_url and team are not source fields");
    rejects("{", "Invalid");
    rejects("null", "must be a dictionary");
    rejects("{}", "\"component\"");
    rejects("{\"component\":7}", "\"component\"");
    rejects("{\"component\":\"\"}", "\"component\"");
    rejects("{\"component\":\"../foo\"}", "\"component\"");
    rejects("{\"component\":\".hidden\"}", "\"component\"");
    rejects("{\"component\":\"pending\"}", "\"component\"");
    rejects("{\"component\":\"Core\"}", "\"component\"");
    rejects("{\"component\":\"foo_\\u00e9\"}", "\"component\"");
    rejects("{\"dll\":\"foo_new\"}", "unknown field \"dll\"");
    rejects("{\"component\":\"foo_new\",\"why\":\"x\"}", "unknown field \"why\"");
    rejects("{\"component\":\"foo_new\",\"owner\":\"o\",\"repo\":\"r\"}", "\"source\" is required");
    rejects("{\"component\":\"foo_new\",\"source\":\"github\",\"owner\":\"o\"}", "\"owner\" and \"repo\" are required");
    rejects("{\"component\":\"foo_new\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\",\"url\":\"https://x.y/\"}", "not \"url\"");
    rejects("{\"component\":\"foo_new\",\"migration_url\":\"http://x.y/\"}", "\"migration_url\"");
    rejects("{\"component\":\"foo_new\",\"migration_url\":\"https://github.com@evil.example/\"}", "\"migration_url\"");
    rejects("{\"component\":\"foo_new\",\"migration_url\":\"https://xn--gthub.com/\\u00e9\"}", "\"migration_url\"");
    rejects("{\"component\":\"foo_new\",\"migration_url\":7}", "\"migration_url\"");
    rejects("{\"component\":\"foo_new\",\"migration\":\"https://x.y/\"}", "unknown field \"migration\"");
    rejects("{\"component\":\"foo_new\",\"team\":\"abcde12345\"}", "\"team\"");
    rejects("{\"component\":\"foo_new\",\"team\":\"ABCDE1234\"}", "\"team\"");
    CHECK(parseReplacedBy("{\"component\":\"foo_new\",\"migration_url\":\"https://x.y/a?b=c@d\"}", r, err), "an @ after the host is fine");

    g_context = "FB2KReplacedBy foobar2000";
    CHECK(parseReplacedBy("{\"foobar2000\":\"2.27\"}", r, err) && r.name == "foobar2000" && r.foobar2000 == "2.27" && !r.hasSource && r.migration.empty() && r.team.empty(),
          "foobar2000 version alone");
    CHECK(parseReplacedBy("{\"foobar2000\":\"2.27\",\"migration_url\":\"https://example.org/foo_x#built-in\"}", r, err)
          && r.name == kFoobar2000 && r.foobar2000 == "2.27" && r.migration == "https://example.org/foo_x#built-in", "migration_url is allowed");
    CHECK(parseReplacedBy("{\"component\":\"foo_new\"}", r, err) && r.foobar2000.empty(), "a component successor has no foobar2000 version");
    rejects("{\"component\":\"foo_new\",\"foobar2000\":\"2.27\"}", "use either \"component\" or \"foobar2000\"");
    rejects("{\"migration_url\":\"https://example.org/\"}", "\"component\" or \"foobar2000\" is required");
    rejects("{\"foobar2000\":\"two\"}", "\"foobar2000\" must be a version such as 2.27");
    rejects("{\"foobar2000\":\"\"}", "\"foobar2000\" must be a version");
    rejects("{\"foobar2000\":2.27}", "\"foobar2000\" must be a version");
    rejects("{\"foobar2000\":\"2.27\",\"source\":\"github\"}", "\"foobar2000\" takes no source or team");
    rejects("{\"foobar2000\":\"2.27\",\"owner\":\"o\"}", "\"foobar2000\" takes no source or team");
    rejects("{\"foobar2000\":\"2.27\",\"repo\":\"r\"}", "\"foobar2000\" takes no source or team");
    rejects("{\"foobar2000\":\"2.27\",\"url\":\"https://x.y/\"}", "\"foobar2000\" takes no source or team");
    rejects("{\"foobar2000\":\"2.27\",\"team\":\"ABCDE12345\"}", "\"foobar2000\" takes no source or team");
    rejects("{\"foobar2000\":\"2.27\",\"why\":\"x\"}", "unknown field \"why\"");
    rejects("{\"foobar2000\":\"2.27\",\"migration_url\":\"http://x.y/\"}", "\"migration_url\"");
    rejects("{\"component\":\"foobar2000\"}", "\"component\"");
    rejects("{\"component\":\"FooBar2000.dll\"}", "\"component\"");
    CHECK(foobar2000Includes("2.26.0.0", "2.0"), "a newer foobar2000 includes it");
    CHECK(foobar2000Includes("2.26", "2.26"), "the same version includes it");
    CHECK(!foobar2000Includes("2.26", "2.27"), "an older foobar2000 does not");
    CHECK(!foobar2000Includes("2.26", "x"), "an unreadable declared version includes nothing");
    CHECK(!foobar2000Includes("x", "2.26"), "an unreadable running version includes nothing");

    g_context = "lookup";
    std::map<std::string, Replacement> builtIn;
    Replacement listed;
    listed.name = "foo_listed";
    builtIn["foo_old"] = listed;
    ReplacementLookup l = findReplacement("foo_old", true, "{\"component\":\"foo_declared\"}", builtIn);
    CHECK(l.origin == ReplacementOrigin::InfoPlist && l.replacement.name == "foo_declared", "the component's own key wins over the built in list");
    l = findReplacement("FOO_OLD", false, "", builtIn);
    CHECK(l.origin == ReplacementOrigin::BuiltIn && l.replacement.name == "foo_listed", "built in list, names compared normalized");
    l = findReplacement("foo_old", true, "{\"component\":\"foo_declared\",\"extra\":1}", builtIn);
    CHECK(l.origin == ReplacementOrigin::BuiltIn && l.note.find("unknown field") != std::string::npos, "an invalid key is noted and the list is used");
    l = findReplacement("foo_x", true, "{\"component\":\"FOO_X\"}", builtIn);
    CHECK(l.origin == ReplacementOrigin::None && l.note.find("itself") != std::string::npos, "a component is not its own replacement");
    l = findReplacement("foo_x", true, "{\"foobar2000\":\"2.27\"}", builtIn);
    CHECK(l.origin == ReplacementOrigin::InfoPlist && l.replacement.name == kFoobar2000 && l.replacement.foobar2000 == "2.27", "foobar2000 as the replacement");
    l = findReplacement("foo_other", false, "", builtIn);
    CHECK(l.origin == ReplacementOrigin::None && l.note.empty(), "nothing declared");
    l = findReplacement("Core", true, "{\"component\":\"foo_new\"}", builtIn);
    CHECK(l.origin == ReplacementOrigin::None, "built in components are never replaced");
    g_context = "built in list extras";
    std::vector<ComponentGroup> groups;
    parseBuiltInExtras(R"({"components":[
        {"dll":"foo_a","source":"github","owner":"o","repo":"r"},
        {"dll":"foo_b","replaced_by":{"component":"foo_c","source":"github","owner":"o","repo":"c"}},
        {"dll":"foo_d","replaced_by":{"component":"foo_e","source":"github"}},
        {"dll":"foo_f","replaced_by":{"component":"foo_f"}},
        {"dll":"../x","replaced_by":{"component":"foo_g"}},
        {"dll":"foo_h","replaced_by":{"foobar2000":"2.27"}},
        {"dll":"foo_i","replaced_by":{"foobar2000":"two"}}],
      "groups":[{"title":"Scrobbler","members":["foo_s1","FOO_S2.dll"]},
                {"title":"Alone","members":["foo_s1"]},
                {"title":"","members":["foo_s1","foo_s2"]},
                {"title":"Bad","members":"foo_s1"}]})", builtIn, groups);
    CHECK(builtIn.size() == 2 && builtIn.count("foo_b") && builtIn["foo_b"].source.repo == "c", "only valid replacements are kept");
    CHECK(builtIn.count("foo_h") && builtIn["foo_h"].name == kFoobar2000 && builtIn["foo_h"].foobar2000 == "2.27" && !builtIn["foo_h"].hasSource, "replaced by foobar2000 in the list");
    CHECK(groups.size() == 1 && groups[0].title == "Scrobbler" && groups[0].members.size() == 2 && groups[0].members[1] == "foo_s2", "only groups with a title and two members");
    parseBuiltInExtras("not json", builtIn, groups);
    CHECK(builtIn.empty() && groups.empty(), "unreadable list gives nothing");

    g_context = "overlap";
    std::vector<ComponentGroup> scrobblers = {{"Last.fm scrobbler", {"foo_a", "foo_b", "foo_c"}}};
    auto notes = overlapNotes({"foo_a", "FOO_B", "foo_x"}, scrobblers);
    CHECK(notes.size() == 2, "both installed members, nothing else");
    CHECK(notes["foo_a"] == "Same job as foo_b (Last.fm scrobbler). Keep only one.", notes["foo_a"].c_str());
    CHECK(notes["foo_b"] == "Same job as foo_a (Last.fm scrobbler). Keep only one.", notes["foo_b"].c_str());
    notes = overlapNotes({"foo_a", "foo_b", "foo_c"}, scrobblers);
    CHECK(notes["foo_c"] == "Same job as foo_a, foo_b (Last.fm scrobbler). Keep only one.", notes["foo_c"].c_str());
    CHECK(overlapNotes({"foo_a", "foo_x"}, scrobblers).empty(), "one member installed is fine");

    g_context = "built in list file";
    // Invariants only, so editing the list needs no test change.
    std::string extra = fixture("../../Resources/extra_components.json");
    parseBuiltInExtras(extra, builtIn, groups);
    size_t declared = 0, listedGroups = 0;
    {
        auto count = [&](char const* key) {
            size_t n = 0;
            for (size_t at = extra.find(key); at != std::string::npos; at = extra.find(key, at + 1)) ++n;
            return n;
        };
        declared = count("\"replaced_by\"");
        listedGroups = count("\"title\"");
    }
    CHECK_EQ(builtIn.size(), declared, "every replaced_by entry is valid");
    CHECK_EQ(groups.size(), listedGroups, "every group is valid");

    TEST_MAIN_END();
}
