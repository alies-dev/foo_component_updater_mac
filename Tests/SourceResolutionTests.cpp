// TEST_DEPS: src/Core/source_resolution.cpp src/Core/mapping_validation.cpp
#include "TestHarness.h"
#include "Fixtures.h"
#include "../src/Core/source_resolution.h"
#include "../src/Core/mapping_validation.h"
#include "../src/Core/github_releases.h"

#include <set>

using namespace fcu;

static RepositoryMappingEntry gh(char const* dll, char const* owner, char const* repo) {
    return {dll, "github", owner, repo, ""};
}

int main() {
    const char* plist = "{\"source\":\"github\",\"owner\":\"plist\",\"repo\":\"p\"}";
    SourceLists lists;
    lists.registry = {gh("foo_a", "registry", "r"), gh("foo_b", "registry", "r"), gh("foo_c", "registry", "r")};
    lists.builtIn = {gh("foo_c", "builtin", "b"), gh("foo_d", "builtin", "b")};

    g_context = "order";
    ResolvedSource r = resolveSource("foo_a", {true, plist}, lists);
    CHECK(r.origin == SourceOrigin::InfoPlist && r.entry.owner == "plist" && r.entry.dllName == "foo_a", "Info.plist before registry");
    r = resolveSource("foo_a", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::Registry && r.entry.owner == "registry", "registry before the built in list");
    r = resolveSource("foo_c", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::Registry, "registry beats built in for foo_c");
    r = resolveSource("foo_d", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::BuiltIn && r.entry.owner == "builtin", "built in list");
    r = resolveSource("foo_unknown", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::Catalog && r.entry.source == "catalog" && r.entry.dllName == "foo_unknown", "catalog is the last resort");

    g_context = "names";
    r = resolveSource("FOO_D", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::BuiltIn, "case insensitive");
    r = resolveSource("foo_d.dll", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::BuiltIn, ".dll ignored");

    g_context = "Core";
    r = resolveSource("Core", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::None, "built in components get no source");
    r = resolveSource("", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::None, "empty name");

    g_context = "invalid Info.plist";
    r = resolveSource("foo_b", {true, "{\"source\":\"nowhere\"}"}, lists);
    CHECK(r.origin == SourceOrigin::Registry, "invalid key ignored, resolution continues");
    CHECK(r.note.find("Invalid FB2KUpdateSource") != std::string::npos, "row tooltip says so");
    r = resolveSource("foo_unknown", {true, "null"}, lists);
    CHECK(r.origin == SourceOrigin::Catalog && !r.note.empty(), "falls through to the catalog with a note");

    g_context = "unsupported sources";
    lists.registry = {{"foo_e", "svn", "o", "r", ""}, gh("foo_e", "second", "s")};
    r = resolveSource("foo_e", {false, ""}, lists);
    CHECK(r.origin == SourceOrigin::Registry && r.entry.owner == "second", "unknown source skipped");

    g_context = "unvalidated list entries";
    {
        SourceLists bad;
        bad.registry = {gh("foo_r", "o/../x", "r"), {"foo_h", "hyv", "", "", "http://insecure/"}, gh("foo_ok", "me", "repo.name-1_x")};
        bad.builtIn = {gh("foo_b", "me", "a b"), gh("foo_e", "", "")};
        ResolvedSource q = resolveSource("foo_r", {false, ""}, bad);
        CHECK(q.origin == SourceOrigin::Registry && !q.invalid.empty(), "registry owner with a slash is invalid");
        q = resolveSource("foo_h", {false, ""}, bad);
        CHECK(q.origin == SourceOrigin::Registry && !q.invalid.empty(), "registry http url is invalid");
        q = resolveSource("foo_b", {false, ""}, bad);
        CHECK(q.origin == SourceOrigin::BuiltIn && !q.invalid.empty(), "built in repo with a space is invalid");
        q = resolveSource("foo_e", {false, ""}, bad);
        CHECK(q.origin == SourceOrigin::BuiltIn && !q.invalid.empty(), "built in entry without owner and repo is invalid");
        bad.registry.push_back({"foo_m1", "github", "attacker", "payload", "https://github.com/trusted/plugin"});
        bad.registry.push_back({"foo_m2", "hyv", "me", "repo", "https://foobar.hyv.fi/?view=foo_m2"});
        q = resolveSource("foo_m1", {false, ""}, bad);
        CHECK(q.origin == SourceOrigin::Registry && q.invalid.find("not \"url\"") != std::string::npos, "registry github entry with a url is rejected");
        q = resolveSource("foo_m2", {false, ""}, bad);
        CHECK(q.origin == SourceOrigin::Registry && q.invalid.find("not \"owner\" and \"repo\"") != std::string::npos, "registry url entry with owner and repo is rejected");
        q = resolveSource("foo_ok", {false, ""}, bad);
        CHECK(q.origin == SourceOrigin::Registry && q.invalid.empty(), "valid characters pass");
        q = resolveSource("foo_c", {false, ""}, bad);
        CHECK(q.invalid.empty(), "catalog source has nothing to validate");
    }
    {
        std::vector<RepositoryMappingEntry> reg;
        CHECK(parseRegistryJson(fixture("registry.json"), reg), "registry fixture");
        int invalid = 0;
        std::string err;
        for (auto const& e : reg) invalid += !validateSourceFields(e, err);
        CHECK_EQ(invalid, 0, "every entry of the shared registry passes validation");
    }

    g_context = "labels";
    CHECK(std::string(originLabel(SourceOrigin::InfoPlist)) == "Info.plist", "plist");
    CHECK(std::string(originLabel(SourceOrigin::Registry)) == "registry", "registry");
    CHECK(std::string(originLabel(SourceOrigin::BuiltIn)) == "built in list", "built in");
    CHECK(std::string(originLabel(SourceOrigin::Catalog)) == "catalog", "catalog");

    g_context = "fall through to the catalog";
    using Kind = AssetOutcome::Kind;
    for (SourceOrigin o : {SourceOrigin::InfoPlist, SourceOrigin::Registry, SourceOrigin::BuiltIn}) {
        CHECK(fallsThroughToCatalog(o, Kind::NotFound), originLabel(o));
        CHECK(!fallsThroughToCatalog(o, Kind::Found) && !fallsThroughToCatalog(o, Kind::Incomplete) && !fallsThroughToCatalog(o, Kind::Error), "only a definitive no match falls through");
    }
    CHECK(!fallsThroughToCatalog(SourceOrigin::Catalog, Kind::NotFound), "the catalog has nothing after it");

    g_context = "registry format";
    std::vector<RepositoryMappingEntry> reg;
    CHECK(parseRegistryJson(fixture("registry.json"), reg) && reg.size() > 200, "shared registry fixture");
    CHECK(!parseRegistryJson("[]", reg) && reg.empty(), "array is not a registry");
    CHECK(!parseRegistryJson("{\"components\":5}", reg), "components must be an array");
    CHECK(parseRegistryJson("{\"components\":[{\"dll\":\"a\"},{\"dll\":\"b\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\"}]}", reg) && reg.size() == 1, "entries without source dropped");
    CHECK(parseRegistryJson(R"({"components":[
        {"component":"foo_a","source":"github","owner":"o","repo":"a"},
        {"dll":"foo_b","source":"github","owner":"o","repo":"b"},
        {"component":"foo_c","dll":"foo_c","source":"github","owner":"o","repo":"c"},
        {"component":"foo_d","dll":"foo_x","source":"github","owner":"o","repo":"d"}]})", reg), "component and dll entries");
    CHECK(reg.size() == 3 && reg[0].dllName == "foo_a" && reg[1].dllName == "foo_b" && reg[2].dllName == "foo_c",
          "\"component\" names an entry, the older \"dll\" still does, two different names drop it");

    g_context = "built in list file";
    std::string extra;
    {
        std::string here = __FILE__;
        extra = fixture("../../Resources/extra_components.json");
    }
    // Invariants only, so adding or removing a component needs no test change.
    std::vector<RepositoryMappingEntry> builtIn;
    CHECK(parseRegistryJson(extra, builtIn) && !builtIn.empty(), "parses and is not empty");
    SourceLists real;
    real.builtIn = builtIn;
    std::set<std::string> seen;
    for (auto const& e : builtIn) {
        char const* name = e.dllName.c_str();
        CHECK(seen.insert(e.dllName).second, name);
        CHECK(e.source == "github" && !e.owner.empty() && !e.repo.empty(), name);
        ResolvedSource r = resolveSource(e.dllName, {false, ""}, real);
        CHECK(r.origin == SourceOrigin::BuiltIn && r.invalid.empty(), name);
        CHECK(r.entry.owner == e.owner && r.entry.repo == e.repo, name);
    }

    TEST_MAIN_END();
}
