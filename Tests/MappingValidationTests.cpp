// TEST_DEPS: src/Core/mapping_validation.cpp
#include "TestHarness.h"
#include "../src/Core/mapping_validation.h"

using namespace fcu;

static void rejects(char const* json, char const* messagePart) {
    RepositoryMappingEntry out = {"keep", "github", "o", "r", ""};
    std::string err;
    CHECK(!parseBundleSource("foo_x", json, out, err), json);
    CHECK(err.find(messagePart) != std::string::npos, (std::string(json) + " -> " + err).c_str());
    CHECK(out.dllName == "keep", "previous value untouched on failure");
}

int main() {
    RepositoryMappingEntry e;
    std::string err;

    g_context = "names";
    CHECK(normalizeComponentName("Foo_X.DLL") == "foo_x", "lowercase and .dll stripped");
    CHECK(normalizeComponentName("foo_jl_spectrum") == "foo_jl_spectrum", "plain name unchanged");

    g_context = "valid input";
    CHECK(parseBundleSource("Foo_X.dll", "{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\"}", e, err), "github dictionary");
    CHECK(e.dllName == "foo_x" && e.source == "github" && e.owner == "o" && e.repo == "r", "entry filled with the normalized component name");
    CHECK(parseBundleSource("foo_x", "{\"source\":\"hyv\",\"url\":\"https://foobar.hyv.fi/?view=foo_x\"}", e, err), "hyv");
    CHECK(parseBundleSource("foo_x", "{\"source\":\"marc2k3\",\"url\":\"https://marc2k3.github.io/component/x/\"}", e, err), "marc2k3");
    CHECK(parseBundleSource("foo_x", "{\"source\":\"sourceforge\",\"url\":\"https://sourceforge.net/projects/p/files/d/\"}", e, err), "sourceforge");
    CHECK(parseBundleSource("foo_x", "{\"source\":\"gitlab\",\"owner\":\"g\",\"repo\":\"c\"}", e, err), "gitlab");
    CHECK(parseBundleSource("foo_x", "{\"source\":\"codeberg\",\"owner\":\"g\",\"repo\":\"d\"}", e, err), "codeberg");

    g_context = "structure";
    rejects("{", "Invalid FB2KUpdateSource");
    rejects("null", "must be an object");
    rejects("[]", "must be an object");
    rejects("{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\",\"extra\":1}", "unknown field \"extra\"");
    rejects("{\"source\":\"github\",\"dll\":\"other\",\"owner\":\"o\",\"repo\":\"r\"}", "unknown field \"dll\"");
    rejects("{\"source\":\"github\",\"owner\":7,\"repo\":\"r\"}", "\"owner\" must be a string");

    g_context = "source specific fields";
    rejects("{\"owner\":\"o\",\"repo\":\"r\"}", "\"source\" is required");
    rejects("{\"source\":\"\",\"owner\":\"o\",\"repo\":\"r\"}", "\"source\" is required");
    rejects("{\"source\":\"svn\",\"owner\":\"o\",\"repo\":\"r\"}", "unsupported source \"svn\"");
    rejects("{\"source\":\"github\",\"repo\":\"r\"}", "\"owner\" and \"repo\" are required");
    rejects("{\"source\":\"github\",\"owner\":\"o\"}", "\"owner\" and \"repo\" are required");
    rejects("{\"source\":\"github\",\"owner\":\"o/x\",\"repo\":\"r\"}", "\"owner\" and \"repo\" are required");
    rejects("{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r r\"}", "\"owner\" and \"repo\" are required");
    rejects("{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r+\"}", "\"owner\" and \"repo\" are required");
    rejects("{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\",\"url\":\"https://x.y/\"}", "not \"url\"");
    rejects("{\"source\":\"hyv\",\"owner\":\"o\",\"repo\":\"r\",\"url\":\"https://x.y/\"}", "not \"owner\" and \"repo\"");
    rejects("{\"source\":\"hyv\"}", "\"url\" must be an https:// URL");
    rejects("{\"source\":\"marc2k3\",\"url\":\"http://x.y/\"}", "\"url\" must be an https:// URL");
    rejects("{\"source\":\"marc2k3\",\"url\":\"https:///path\"}", "\"url\" must be an https:// URL");
    rejects("{\"source\":\"marc2k3\",\"url\":\"https://x.y/a b\"}", "\"url\" must be an https:// URL");
    rejects("{\"source\":\"sourceforge\",\"url\":\"ftp://x.y/\"}", "\"url\" must be an https:// URL");

    TEST_MAIN_END();
}
