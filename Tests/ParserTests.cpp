// TEST_DEPS: src/upstream/update_parse.cpp
#include "TestHarness.h"
#include "Fixtures.h"
#include "../src/upstream/update_parse.h"

int main() {
    FetchedRelease r;
    std::string err;

    g_context = "GitLab";
    CHECK(ParseGitLabRelease(fixture("gitlab_latest.json"), "gitlab-org", "cli", r, err), "fixture parses");
    CHECK(r.tagName == "v1.124.0", "tag");
    CHECK(r.releaseUrl == "https://gitlab.com/gitlab-org/cli/-/releases/v1.124.0", "release url built from the tag");
    r = {};
    CHECK(!ParseGitLabRelease("{\"message\":\"404 Not Found\"}", "a", "b", r, err), "no tag fails");
    CHECK(!ParseGitLabRelease("not json", "a", "b", r, err) && err.rfind("Invalid response", 0) == 0, "invalid json reports");

    g_context = "Codeberg";
    r = {};
    CHECK(ParseCodebergRelease(fixture("codeberg_releases.json"), r, err), "fixture parses");
    CHECK(r.tagName == "v17.0.0", "tag");
    CHECK(r.releaseUrl == "https://codeberg.org/forgejo/forgejo/releases/tag/v17.0.0", "html url");
    CHECK(!ParseCodebergRelease("[]", r, err) && !err.empty(), "empty list fails");
    CHECK(!ParseCodebergRelease("{\"message\":\"x\"}", r, err), "object instead of list fails");

    g_context = "marc2k3";
    r = {};
    CHECK(ParseMarc2k3Page(fixture("marc2k3_cover_utils.html"), "https://marc2k3.github.io/component/cover-utils/", r, err), "fixture parses");
    CHECK(r.tagName == "1.8", "version from the download file name");
    CHECK(r.releaseUrl == "https://marc2k3.github.io/component/cover-utils/", "release url is the page");
    CHECK(!ParseMarc2k3Page("<html>nothing</html>", "u", r, err) && err.find("download button") != std::string::npos, "no button fails closed");
    CHECK(!ParseMarc2k3Page("<a class=\"md-button md-button--primary\" href=\"x/foo.zip\">", "u", r, err), "link without version fails closed");

    g_context = "SourceForge";
    std::string rss;
    CHECK(BuildSourceForgeRssUrl("https://sourceforge.net/projects/sacddecoder/files/foo_input_sacd/", rss, err), "folder url");
    CHECK(rss == "https://sourceforge.net/projects/sacddecoder/rss?path=/foo_input_sacd", "rss url");
    CHECK(BuildSourceForgeRssUrl("https://sourceforge.net/projects/foopopupplus/files/", rss, err), "root folder");
    CHECK(rss == "https://sourceforge.net/projects/foopopupplus/rss?path=/", "root path");
    CHECK(!BuildSourceForgeRssUrl("https://example.com/x", rss, err) && !err.empty(), "other url rejected");
    r = {};
    CHECK(ParseSourceForgeFeed(fixture("sourceforge_sacd.rss"), "https://sourceforge.net/projects/sacddecoder/files/foo_input_sacd/", r, err), "feed parses");
    CHECK(r.tagName == "2.0.25", "skips the for_foobar-1.6.x build and takes the real release");
    CHECK(!ParseSourceForgeFeed("<rss></rss>", "u", r, err) && !err.empty(), "empty feed fails");

    g_context = "hyv";
    r = {};
    CHECK(ParseHyvPage(fixture("hyv_foo_hdcd.html"), "https://foobar.hyv.fi/?view=foo_hdcd", r, err), "fixture parses");
    CHECK(r.tagName == "1.22", "version row");
    CHECK(r.releaseUrl == "https://foobar.hyv.fi/?view=foo_hdcd", "release url is the page");
    CHECK(!ParseHyvPage("<html></html>", "u", r, err) && err.find("Version") != std::string::npos, "no version row fails closed");

    TEST_MAIN_END();
}
