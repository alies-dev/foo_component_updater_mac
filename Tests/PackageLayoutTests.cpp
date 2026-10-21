// TEST_DEPS: src/Core/package_layout.cpp
#include "TestHarness.h"
#include "Fixtures.h"
#include "../src/Core/package_layout.h"

#include <algorithm>
#include <vector>

using namespace fcu;

namespace {

struct Entry {
    std::string name;
    uint32_t size = 0; // declared uncompressed size; the data itself is never needed
};

void put16(std::string& s, uint16_t v) { s.push_back(char(v & 0xff)); s.push_back(char(v >> 8)); }
void put32(std::string& s, uint32_t v) { put16(s, uint16_t(v & 0xffff)); put16(s, uint16_t(v >> 16)); }

// A zip with stored entries and no data: only the central directory matters to the parser.
std::string buildZip(std::vector<Entry> const& entries, uint16_t declaredCount = 0xfffe, std::string const& comment = "") {
    std::string out, central;
    for (Entry const& e : entries) {
        uint32_t offset = uint32_t(out.size());
        put32(out, 0x04034b50); put16(out, 20); put16(out, 0); put16(out, 0); put32(out, 0); put32(out, 0);
        put32(out, 0); put32(out, 0); put16(out, uint16_t(e.name.size())); put16(out, 0);
        out += e.name;
        put32(central, 0x02014b50); put16(central, 20); put16(central, 20); put16(central, 0); put16(central, 0);
        put32(central, 0); put32(central, 0); put32(central, 0); put32(central, e.size);
        put16(central, uint16_t(e.name.size())); put16(central, 0); put16(central, 0); put16(central, 0); put16(central, 0);
        put32(central, 0); put32(central, offset);
        central += e.name;
    }
    uint16_t count = declaredCount == 0xfffe ? uint16_t(entries.size()) : declaredCount;
    uint32_t cdOffset = uint32_t(out.size());
    out += central;
    put32(out, 0x06054b50); put16(out, 0); put16(out, 0); put16(out, count); put16(out, count);
    put32(out, uint32_t(central.size())); put32(out, cdOffset); put16(out, uint16_t(comment.size()));
    out += comment;
    return out;
}

std::vector<Entry> goodEntries(std::string const& name = "foo_test") {
    std::string base = "mac/" + name + ".component/Contents/";
    return {{base + "Info.plist", 10}, {base + "MacOS/" + name, 10}};
}

bool accepts(std::string const& zip, std::string const& name = "foo_test") { return checkPackageLayout(zip, name).ok; }

std::string errorOf(std::string const& zip, std::string const& name = "foo_test") {
    PackageCheck c = checkPackageLayout(zip, name);
    return c.ok ? "" : c.error.empty() ? "(empty error)" : c.error;
}

bool mentions(std::string const& text, char const* needle) { return text.find(needle) != std::string::npos; }

} // namespace

int main() {
    g_context = "ditto fixtures";
    CHECK(accepts(fixture("pkg_valid.zip")), "valid mac layout");
    {
        PackageCheck c = checkPackageLayout(fixture("pkg_valid.zip"), "foo_test");
        CHECK_EQ(c.entries.size(), 6, "all six central directory names are listed");
        CHECK(std::find(c.entries.begin(), c.entries.end(), "mac/foo_test.component/Contents/Info.plist") != c.entries.end(), "Info.plist is listed");
        CHECK(checkPackageLayout(fixture("pkg_nomac.zip"), "foo_test").entries.empty(), "a refused package lists nothing");
    }
    CHECK(accepts(fixture("pkg_multi.zip")), "multi platform layout (dll, x64, arm64ec ignored)");
    CHECK(!accepts(fixture("pkg_valid.zip"), "Foo_Test"), "the name is case sensitive");
    CHECK(!accepts(fixture("pkg_valid.zip"), "foo_tes"), "no prefix match on the name");
    std::string wrong = errorOf(fixture("pkg_wrongname.zip"));
    CHECK(mentions(wrong, "foo_other.component") && mentions(wrong, "foo_test.component"), "wrong name names both bundles");
    CHECK(mentions(errorOf(fixture("pkg_noplist.zip")), "Info.plist"), "missing Info.plist");
    CHECK(mentions(errorOf(fixture("pkg_noexec.zip")), "MacOS"), "missing executable");
    CHECK(mentions(errorOf(fixture("pkg_nomac.zip")), "mac/foo_test.component"), "no mac/ directory");

    g_context = "layout rules";
    CHECK(accepts(buildZip(goodEntries())), "synthetic good zip");
    CHECK(accepts(buildZip(goodEntries(), 0xfffe, "a trailing comment")), "end record found behind a comment");
    CHECK(!accepts(buildZip({{"mac/foo_test.component/Contents/Info.plist"}})), "Info.plist without an executable");
    CHECK(!accepts(buildZip({{"mac/foo_test.component/Contents/Info.plist"}, {"mac/foo_test.component/Contents/MacOS/"}})),
          "an empty MacOS directory entry is no executable");
    CHECK(!accepts(buildZip({{"mac/foo_test.component/Contents/Resources/Info.plist"}, {"mac/foo_test.component/Contents/MacOS/foo_test"}})),
          "Info.plist must sit directly in Contents");
    CHECK(!accepts(buildZip({{"mac/foo_test.componentX/Contents/Info.plist"}, {"mac/foo_test.componentX/Contents/MacOS/x"}})),
          "bundle name must match exactly");
    CHECK(!accepts(buildZip({{"x/mac/foo_test.component/Contents/Info.plist"}, {"x/mac/foo_test.component/Contents/MacOS/x"}})),
          "mac/ must be the top level");
    CHECK(!accepts(buildZip({})), "an empty zip");

    g_context = "unsafe names";
    for (char const* bad : {"../evil", "mac/foo_test.component/../../evil", "/etc/passwd", "mac\\foo_test.component\\evil", "x64/../../evil",
                            "mac/foo_test.component/Contents/..", ".."}) {
        auto entries = goodEntries();
        entries.push_back({bad});
        std::string err = errorOf(buildZip(entries));
        CHECK(!err.empty() && mentions(err, "unsafe"), bad);
    }
    {
        auto entries = goodEntries();
        entries.push_back({std::string("nul\0name", 8)});
        CHECK(mentions(errorOf(buildZip(entries)), "unsafe"), "NUL in a name");
    }
    {
        auto entries = goodEntries();
        entries.push_back({"mac/foo_test.component/Resources/a..b/..c/d.."});
        CHECK(accepts(buildZip(entries)), "dots inside a component are fine");
    }

    g_context = "limits";
    {
        auto entries = goodEntries();
        while (entries.size() < kMaxPackageEntries) entries.push_back({"x64/f" + std::to_string(entries.size())});
        CHECK(accepts(buildZip(entries)), "exactly the entry limit");
        entries.push_back({"x64/one_more"});
        CHECK(mentions(errorOf(buildZip(entries)), "10000"), "one entry over the limit");
    }
    {
        auto entries = goodEntries();
        entries.push_back({"x64/a.bin", 0x10000000});
        entries.push_back({"x64/b.bin", 0x10000000 - 20});
        CHECK(accepts(buildZip(entries)), "exactly 512 MB in total");
        entries.push_back({"x64/c.bin", 1});
        CHECK(mentions(errorOf(buildZip(entries)), "512 MB"), "one byte over 512 MB in total");
    }
    {
        // Sizes are summed in 64 bits: many large entries must not wrap around.
        std::vector<Entry> entries = goodEntries();
        for (int i = 0; i < 20; ++i) entries.push_back({"x64/big" + std::to_string(i), 0xf0000000u});
        CHECK(mentions(errorOf(buildZip(entries)), "512 MB"), "no 32 bit wrap around");
    }
    {
        auto entries = goodEntries();
        entries.push_back({"x64/huge", 0xffffffffu});
        CHECK(!accepts(buildZip(entries)), "a zip64 sized entry");
        CHECK(!accepts(buildZip(goodEntries(), 0xffff)), "a zip64 entry count");
    }

    g_context = "broken files";
    std::string valid = fixture("pkg_valid.zip");
    CHECK(!accepts(""), "empty input");
    CHECK(!accepts("PK\x05\x06"), "a bare signature");
    CHECK(!accepts(std::string(5000, 'x')), "not a zip");
    CHECK(mentions(errorOf(valid.substr(0, valid.size() - 10)), "not a valid package"), "end record cut off");
    CHECK(!accepts(valid.substr(0, valid.size() / 2)), "half of the file");
    CHECK(!accepts(valid.substr(valid.size() / 2)), "second half of the file");
    {
        // Central directory entry whose name runs past the directory.
        std::string z = buildZip(goodEntries());
        size_t cd = z.find("PK\x01\x02");
        z[cd + 28] = char(0xff);
        CHECK(!accepts(z), "name length beyond the directory");
    }
    {
        // End record that claims more entries than the directory holds.
        CHECK(!accepts(buildZip(goodEntries(), 5)), "entry count larger than the directory");
        // End record that counts fewer entries than the directory holds: the rest would be extracted unchecked.
        auto hidden = goodEntries();
        hidden.push_back({"../hidden"});
        CHECK(!accepts(buildZip(hidden, 2)), "entry hidden behind the counted ones");
        // A directory offset that points outside the file.
        std::string z = buildZip(goodEntries());
        size_t eocd = z.rfind("PK\x05\x06");
        z[eocd + 16] = char(0xff); z[eocd + 17] = char(0xff);
        CHECK(!accepts(z), "directory offset outside the file");
    }

    g_context = "install block reason";
    std::string const url = "https://example.org/foo_x.fb2k-component";
    CHECK(installBlockReason(true, "foo_x", url, "foo_x.fb2k-component", false).empty(), "installable");
    CHECK(installBlockReason(true, "foo_x", url, "FOO_X.FB2K-COMPONENT", false).empty(), "extension is case insensitive");
    CHECK(!installBlockReason(false, "foo_x", url, "foo_x.fb2k-component", false).empty(), "no update");
    CHECK(!installBlockReason(true, "Core", url, "foo_x.fb2k-component", false).empty(), "built in");
    CHECK(mentions(installBlockReason(true, "foo_component_updater_mac", url, "foo_x.fb2k-component", false), "later version"), "self update");
    CHECK(mentions(installBlockReason(true, "foo_x", url, "foo_x.fb2k-component", true), "restart"), "already staged");
    CHECK(mentions(installBlockReason(true, "foo_x", "", "", false), "no package"), "page only source");
    CHECK(!installBlockReason(true, "foo_x", "http://example.org/foo_x.fb2k-component", "foo_x.fb2k-component", false).empty(), "http link");
    CHECK(!installBlockReason(true, "foo_x", url, "foo_x.zip", false).empty(), "zip asset is for reporting only");

    TEST_MAIN_END();
}
