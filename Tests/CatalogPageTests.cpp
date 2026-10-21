// TEST_DEPS: src/Core/catalog_page.cpp
#include "TestHarness.h"
#include "Fixtures.h"
#include "../src/Core/catalog_page.h"

using namespace fcu;

static std::string replaceAll(std::string s, std::string const& from, std::string const& to) {
    for (size_t pos = s.find(from); pos != std::string::npos; pos = s.find(from, pos + to.size())) s.replace(pos, from.size(), to);
    return s;
}

int main() {
    CatalogRelease r;
    std::string err;

    g_context = "foo_abx";
    CHECK(parseCatalogPage(fixture("catalog_foo_abx.html"), r, err) == CatalogStatus::Ok, "parses");
    CHECK(r.version == "2.2.3", "version");
    CHECK(r.downloadPath == "/getcomponent/5ae8a8e80cf7ef18ca0155628f36b458/foo_abx.fb2k-component", "download path");

    g_context = "foo_navidrome";
    r = {};
    CHECK(parseCatalogPage(fixture("catalog_foo_navidrome.html"), r, err) == CatalogStatus::Ok, "parses");
    CHECK(r.version == "1.31.2", "version");
    CHECK(r.downloadPath == "/getcomponent/cae8710f401a39e30da6685e6cd89516/foo_navidrome_1.31.2.fb2k-component", "versioned file name");

    g_context = "foo_openmpt54 (no ARM)";
    r = {};
    CHECK(parseCatalogPage(fixture("catalog_foo_openmpt54.html"), r, err) == CatalogStatus::Ok && r.version == "0.8.9", "macOS listed without Windows ARM");

    g_context = "no macOS";
    std::string windowsOnly = replaceAll(fixture("catalog_foo_abx.html"), ", macOS.", ".");
    CHECK(windowsOnly != fixture("catalog_foo_abx.html"), "fixture edited");
    CHECK(parseCatalogPage(windowsOnly, r, err) == CatalogStatus::NoMacSupport, "Supported systems without macOS");
    CHECK(err.find("macOS") != std::string::npos, "message names macOS");

    g_context = "unknown component";
    CHECK(parseCatalogPage(fixture("catalog_404.html"), r, err) == CatalogStatus::NotInCatalog, "No such component page");

    g_context = "decoy text in the description";
    r = {};
    const std::string description = "<div class=\"component_info\">Performs a double-blind listening test between two tracks.</div>";
    std::string decoyPage = fixture("catalog_foo_abx.html");
    CHECK(decoyPage.find(description) != std::string::npos, "description present in the fixture");
    CHECK(parseCatalogPage(replaceAll(decoyPage, description,
        "<div class=\"component_info\">Performs a double-blind test. Current version: 99.0, released on 2030-01-01. "
        "<p>Supported systems: Windows 32-bit.</p> No such component. "
        "<a href=\"/getcomponent/00000000000000000000000000000000/evil.fb2k-component\">x</a></div>"), r, err) == CatalogStatus::Ok, "description decoys are ignored");
    CHECK(r.version == "2.2.3", "version comes from the generated heading");
    CHECK(r.downloadPath == "/getcomponent/5ae8a8e80cf7ef18ca0155628f36b458/foo_abx.fb2k-component", "link from the download element only");
    std::string windowsOnlyPage = replaceAll(replaceAll(decoyPage, ", macOS.", "."), description, "<div class=\"component_info\">Supported systems: macOS</div>");
    CHECK(parseCatalogPage(windowsOnlyPage, r, err) == CatalogStatus::NoMacSupport, "a description claiming macOS does not count");

    g_context = "ambiguous authoritative fields";
    std::string dup = fixture("catalog_foo_abx.html");
    std::string heading = "<h3>Current version: 2.2.3, released on 2025-09-19</h3>";
    CHECK(dup.find(heading) != std::string::npos, "heading present");
    CHECK(parseCatalogPage(replaceAll(dup, heading, heading + "<h3>Current version: 3.0, released on 2026-01-01</h3>"), r, err) == CatalogStatus::Malformed, "two different headings");
    std::string systems = "<p>Supported systems: Windows 32-bit, Windows 64-bit, Windows ARM, macOS.</p>";
    CHECK(parseCatalogPage(replaceAll(dup, systems, systems + "<p>Supported systems: macOS.</p>"), r, err) == CatalogStatus::Malformed, "two systems lines");
    CHECK(parseCatalogPage(replaceAll(dup, heading, "<!-- " + heading + " -->" + heading), r, err) == CatalogStatus::Ok, "commented heading ignored");
    CHECK(parseCatalogPage(std::string(2 * 1024 * 1024, 'x'), r, err) == CatalogStatus::Malformed, "oversized page");

    g_context = "fail closed";
    std::string html = fixture("catalog_foo_abx.html");
    CHECK(parseCatalogPage(replaceAll(html, "Current version:", "Version:"), r, err) == CatalogStatus::Malformed, "no version");
    CHECK(parseCatalogPage(replaceAll(html, "Supported systems:", "Systems:"), r, err) == CatalogStatus::Malformed, "no systems line");
    CHECK(parseCatalogPage(replaceAll(html, "/getcomponent/", "/elsewhere/"), r, err) == CatalogStatus::Malformed, "no download link");
    std::string link = "<a href=\"/getcomponent/5ae8a8e80cf7ef18ca0155628f36b458/foo_abx.fb2k-component\">";
    CHECK(parseCatalogPage(replaceAll(html, link, link + "</a><a href=\"/getcomponent/00000000000000000000000000000000/foo_abx.fb2k-component\">"), r, err) == CatalogStatus::Malformed
          && err.find("Several") != std::string::npos, "two different links");
    CHECK(parseCatalogPage(replaceAll(html, link, link + "</a>" + link), r, err) == CatalogStatus::Ok, "the same link twice is one link");
    CHECK(parseCatalogPage(replaceAll(html, "/getcomponent/5ae8a8e80cf7ef18ca0155628f36b458/", "/getcomponent/xyz/"), r, err) == CatalogStatus::Malformed, "link needs a 32 hex token");
    CHECK(parseCatalogPage("", r, err) == CatalogStatus::Malformed, "empty page");

    TEST_MAIN_END();
}
