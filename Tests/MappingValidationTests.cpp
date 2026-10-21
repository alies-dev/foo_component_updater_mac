// TEST_DEPS: src/Core/mapping_validation.cpp
#include "TestHarness.h"
#include "../src/Core/mapping_validation.h"

using namespace fcu;

static bool parse(std::string const& text, std::vector<RepositoryMappingEntry>& out, std::string& err) {
    return parseUserMappings(text, out, err);
}

static void rejects(char const* text, char const* messagePart) {
    std::vector<RepositoryMappingEntry> out = {{"keep", "github", "o", "r", ""}};
    std::string err;
    CHECK(!parse(text, out, err), text);
    CHECK(err.find(messagePart) != std::string::npos, (std::string(text) + " -> " + err).c_str());
    CHECK(out.size() == 1 && out[0].dllName == "keep", "previous value untouched on failure");
}

int main() {
    std::vector<RepositoryMappingEntry> out;
    std::string err;

    g_context = "names";
    CHECK(normalizeComponentName("Foo_X.DLL") == "foo_x", "lowercase and .dll stripped");
    CHECK(normalizeComponentName("foo_jl_spectrum") == "foo_jl_spectrum", "plain name unchanged");

    g_context = "valid input";
    CHECK(parse("", out, err) && out.empty(), "empty text is an empty list");
    CHECK(parse(" \n\t", out, err) && out.empty(), "blank text is an empty list");
    CHECK(parse("[]", out, err) && out.empty(), "empty array");
    CHECK(parse("[{\"dll\":\"Foo_X.dll\",\"source\":\"github\",\"owner\":\"me\",\"repo\":\"foo_x\"}]", out, err), "github entry");
    CHECK(out.size() == 1 && out[0].dllName == "foo_x" && out[0].owner == "me" && out[0].repo == "foo_x" && out[0].source == "github", "normalized fields");
    CHECK(parse("[{\"dll\":\"foo_y\",\"owner\":\"me\",\"repo\":\"y\"}]", out, err) && out[0].source == "github", "source defaults to github");
    CHECK(parse("[{\"dll\":\"foo_out_asio+dsd\",\"source\":\"sourceforge\",\"url\":\"https://sourceforge.net/projects/p/files/d/\"}]", out, err), "sourceforge entry");
    CHECK(parse("[{\"dll\":\"a\",\"source\":\"marc2k3\",\"url\":\"https://marc2k3.github.io/component/x/\"},"
                "{\"dll\":\"b\",\"source\":\"hyv\",\"url\":\"https://foobar.hyv.fi/?view=b\"},"
                "{\"dll\":\"c\",\"source\":\"gitlab\",\"owner\":\"g\",\"repo\":\"c\"},"
                "{\"dll\":\"d\",\"source\":\"codeberg\",\"owner\":\"g\",\"repo\":\"d\"}]", out, err) && out.size() == 4, "every supported source");

    g_context = "structure";
    rejects("{", "Invalid JSON");
    rejects("{\"dll\":\"a\"}", "array");
    rejects("42", "array");
    rejects("[1]", "Entry 1: must be an object");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\",\"extra\":1}]", "unknown field \"extra\"");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\"},{\"owner\":\"o\",\"repo\":\"r\"}]", "Entry 2");

    g_context = "dll";
    rejects("[{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\"}]", "\"dll\" is required");
    rejects("[{\"dll\":\"\",\"owner\":\"o\",\"repo\":\"r\"}]", "\"dll\" is required");
    rejects("[{\"dll\":\"../x\",\"owner\":\"o\",\"repo\":\"r\"}]", "\"dll\" may only contain");
    rejects("[{\"dll\":\"a/b\",\"owner\":\"o\",\"repo\":\"r\"}]", "\"dll\" may only contain");
    rejects("[{\"dll\":\".hidden\",\"owner\":\"o\",\"repo\":\"r\"}]", "\"dll\" may only contain");
    rejects("[{\"dll\":\"a..b\",\"owner\":\"o\",\"repo\":\"r\"}]", "\"dll\" may only contain");
    rejects("[{\"dll\":7,\"owner\":\"o\",\"repo\":\"r\"}]", "\"dll\" must be a string");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\"},{\"dll\":\"A.DLL\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r2\"}]", "duplicate component \"a\"");

    g_context = "source specific fields";
    rejects("[{\"dll\":\"a\",\"source\":\"svn\",\"owner\":\"o\",\"repo\":\"r\"}]", "unsupported source \"svn\"");
    rejects("[{\"dll\":\"a\",\"source\":\"\",\"owner\":\"o\",\"repo\":\"r\"}]", "unsupported source");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"repo\":\"r\"}]", "\"owner\" and \"repo\" are required");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"owner\":\"o\"}]", "\"owner\" and \"repo\" are required");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"owner\":\"o/x\",\"repo\":\"r\"}]", "\"owner\" and \"repo\" are required");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r r\"}]", "\"owner\" and \"repo\" are required");
    rejects("[{\"dll\":\"a\",\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\",\"url\":\"https://x.y/\"}]", "not \"url\"");
    rejects("[{\"dll\":\"a\",\"source\":\"hyv\",\"owner\":\"o\",\"repo\":\"r\",\"url\":\"https://x.y/\"}]", "not \"owner\" and \"repo\"");
    rejects("[{\"dll\":\"a\",\"source\":\"hyv\"}]", "\"url\" must be an https:// URL");
    rejects("[{\"dll\":\"a\",\"source\":\"marc2k3\",\"url\":\"http://x.y/\"}]", "\"url\" must be an https:// URL");
    rejects("[{\"dll\":\"a\",\"source\":\"marc2k3\",\"url\":\"https:///path\"}]", "\"url\" must be an https:// URL");
    rejects("[{\"dll\":\"a\",\"source\":\"marc2k3\",\"url\":\"https://x.y/a b\"}]", "\"url\" must be an https:// URL");
    rejects("[{\"dll\":\"a\",\"source\":\"sourceforge\",\"url\":\"ftp://x.y/\"}]", "\"url\" must be an https:// URL");

    g_context = "formatting";
    std::vector<RepositoryMappingEntry> entries = {{"foo_x", "github", "me", "foo_x", ""}, {"foo_y", "hyv", "", "", "https://foobar.hyv.fi/?view=foo_y"}};
    std::string text = formatUserMappings(entries);
    CHECK(text.find("\"url\"") != std::string::npos && text.find("\"owner\": \"me\"") != std::string::npos, "readable output");
    std::vector<RepositoryMappingEntry> back;
    CHECK(parse(text, back, err) && back.size() == 2 && back[0].repo == "foo_x" && back[1].url == entries[1].url, "round trip");
    CHECK(formatUserMappings({}) == "[]", "empty list");

    g_context = "Info.plist source";
    RepositoryMappingEntry e;
    CHECK(parseBundleSource("foo_x", "{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\"}", e, err), "github dictionary");
    CHECK(e.dllName == "foo_x" && e.source == "github" && e.owner == "o" && e.repo == "r", "entry filled with the component name");
    CHECK(parseBundleSource("foo_x", "{\"source\":\"hyv\",\"url\":\"https://foobar.hyv.fi/?view=foo_x\"}", e, err), "url dictionary");
    CHECK(!parseBundleSource("foo_x", "{\"owner\":\"o\",\"repo\":\"r\"}", e, err) && err.find("\"source\" is required") != std::string::npos, "source is required");
    CHECK(!parseBundleSource("foo_x", "{\"source\":\"github\",\"dll\":\"other\",\"owner\":\"o\",\"repo\":\"r\"}", e, err) && err.find("unknown field \"dll\"") != std::string::npos, "dll cannot be overridden");
    CHECK(!parseBundleSource("foo_x", "{\"source\":\"github\",\"owner\":\"o\",\"repo\":\"r\",\"url\":\"https://a.b/\"}", e, err), "mixed fields");
    CHECK(!parseBundleSource("foo_x", "{\"source\":\"marc2k3\",\"url\":\"http://a.b/\"}", e, err), "http url");
    CHECK(!parseBundleSource("foo_x", "null", e, err) && err.find("must be an object") != std::string::npos, "not a dictionary");
    CHECK(!parseBundleSource("foo_x", "{", e, err) && err.rfind("Invalid FB2KUpdateSource", 0) == 0, "broken json");

    TEST_MAIN_END();
}
