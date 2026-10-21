// TEST_DEPS: src/Core/github_releases.cpp src/upstream/update_parse.cpp
#include "TestHarness.h"
#include "Fixtures.h"
#include "../src/Core/github_releases.h"

using namespace fcu;

static std::string release(char const* tag, bool draft, bool prerelease, char const* asset) {
    std::string url = std::string("https://github.com/o/r/releases/download/") + tag + "/" + asset;
    return std::string("{\"tag_name\":\"") + tag + "\",\"html_url\":\"https://github.com/o/r/releases/tag/" + tag
        + "\",\"draft\":" + (draft ? "true" : "false") + ",\"prerelease\":" + (prerelease ? "true" : "false")
        + ",\"assets\":[{\"name\":\"" + asset + "\",\"browser_download_url\":\"" + url + "\"}]}";
}

static std::string page(std::vector<std::string> const& releases) {
    std::string s = "[";
    for (size_t i = 0; i < releases.size(); ++i) s += (i ? "," : "") + releases[i];
    return s + "]";
}

static ReleaseMatch select(std::string const& body, char const* asset, bool pre, bool* found = nullptr) {
    std::vector<Release> releases;
    std::string err;
    CHECK(parseReleases(body, releases, err), "page parses");
    ReleaseMatch m;
    bool ok = selectRelease(releases, asset, pre, m);
    if (found) *found = ok;
    return m;
}

int main() {
    g_context = "tag versions";
    CHECK(versionFromTag("v1.2.3") == "1.2.3", "whole tag with v");
    CHECK(versionFromTag("1.2.3") == "1.2.3", "whole tag");
    CHECK(versionFromTag("V2.0") == "2.0", "capital V");
    CHECK(versionFromTag("spectrum-v1.0.0") == "1.0.0", "after -v");
    CHECK(versionFromTag("waveform-v1.1.0") == "1.1.0", "waveform");
    CHECK(versionFromTag("waveform-seekbar-v1.2.0") == "1.2.0", "waveform-seekbar");
    CHECK(versionFromTag("foo_jl_biography-v1.0.0") == "1.0.0", "file name prefix");
    CHECK(versionFromTag("effects_dsp-v1.0.0-beta.1") == "1.0.0-beta.1", "prerelease suffix");
    CHECK(versionFromTag("v1.0.0-rc.1") == "1.0.0-rc.1", "whole tag prerelease");
    CHECK(versionFromTag("release") == "", "no version");
    CHECK(versionFromTag("nightly-build") == "", "no -v");
    CHECK(versionFromTag("x-v") == "", "empty tail");
    CHECK(versionFromTag("x-vfoo") == "", "tail not a version");
    CHECK(versionFromTag("") == "", "empty tag");
    CHECK(versionFromTag("a-v1.0.0-v2.0.0") == "", "two candidates are ambiguous");
    CHECK(versionFromTag("a-v1.0.0-vfoo") == "1.0.0-vfoo", "one valid candidate, prerelease text");
    CHECK(versionFromTag("x-v2.0.") == "", "trailing dot is not a complete version");
    CHECK(versionFromTag("x-v2.0.0+") == "", "empty build metadata");
    CHECK(versionFromTag("x-v2.0.0+b@d") == "", "build identifier outside the SemVer charset");
    CHECK(versionFromTag("x-v2.0.0-") == "", "empty prerelease");
    CHECK(versionFromTag("x-v2.0.0-rc..1") == "", "empty prerelease identifier");
    CHECK(versionFromTag("x-v2..0") == "", "empty segment");
    CHECK(versionFromTag("x-v.2.0") == "", "leading dot");
    CHECK(versionFromTag("v2.0.") == "", "whole tag with a trailing dot");
    CHECK(versionFromTag("x-v2.0.0+build.5") == "2.0.0+build.5", "build metadata kept");
    CHECK(versionFromTag("x-v2.0.0-rc.1+b-7") == "2.0.0-rc.1+b-7", "prerelease and build");
    CHECK(versionFromTag("x-v99999999999999999999") == "", "oversized number rejected by compareVersions");
    CHECK(versionFromTag("v4294967296.0.0") == "4294967296.0.0", "whole tag with a ten digit segment");
    CHECK(versionFromTag("x-v2.4294967296.0") == "2.4294967296.0", "prefixed tag with a ten digit segment");

    g_context = "Jenda releases";
    std::string jenda = fixture("jenda_releases.json");
    struct Want { char const* name; char const* version; char const* tag; } wants[] = {
        {"foo_jl_spectrum", "1.0.0", "spectrum-v1.0.0"},
        {"foo_jl_vectorscope", "1.0.0", "vectorscope-v1.0.0"},
        {"foo_jl_simplaylist", "1.6.0", "simplaylist-v1.6.0"},
        {"foo_jl_scrobble", "1.4.1", "scrobble-v1.4.1"},
        {"foo_jl_wave_seekbar", "1.2.0", "waveform-seekbar-v1.2.0"},
        {"foo_jl_biography", "1.0.0", "foo_jl_biography-v1.0.0"},
        {"foo_jl_queue_manager", "1.2.0", "queuemanager-v1.2.0"},
        {"foo_jl_plorg", "1.5.0", "plorg-v1.5.0"},
        {"foo_jl_tidal", "0.3.0", "tidal-v0.3.0"},
        {"foo_jl_effects_dsp", "1.0.0", "effects_dsp-v1.0.0"},
        {"foo_jl_album_art", "1.0.1", "albumart-v1.0.1"},
    };
    for (auto const& w : wants) {
        bool found = false;
        ReleaseMatch m = select(jenda, (std::string(w.name) + ".fb2k-component").c_str(), false, &found);
        CHECK(found, w.name);
        CHECK(m.version == w.version, w.name);
        CHECK(m.tag == w.tag, w.name);
        CHECK(m.downloadUrl.find(std::string("/") + w.tag + "/" + w.name + ".fb2k-component") != std::string::npos, "download url from the asset");
        CHECK(m.releaseUrl == std::string("https://github.com/JendaT/fb2k-components-mac-suite/releases/tag/") + w.tag, "release page");
    }
    bool found = true;
    select(jenda, "foo_jl_missing.fb2k-component", false, &found);
    CHECK(!found, "missing asset");

    g_context = "one request per repository";
    int calls = 0;
    std::vector<std::string> assets = {"foo_jl_spectrum.fb2k-component", "foo_jl_scrobble.fb2k-component", "foo_jl_simplaylist.fb2k-component",
                                       "foo_jl_vectorscope.fb2k-component", "foo_jl_wave_seekbar.fb2k-component"};
    auto outcomes = resolveRepository(assets, [&](int p) { ++calls; PageFetch pf; pf.ok = true; pf.body = jenda; pf.hasNext = true; (void)p; return pf; }, false);
    CHECK_EQ(calls, 1, "five components, one page");
    CHECK_EQ(outcomes.size(), 5, "five outcomes");
    CHECK(outcomes["foo_jl_spectrum.fb2k-component"].kind == AssetOutcome::Kind::Found, "spectrum found");
    CHECK(outcomes["foo_jl_spectrum.fb2k-component"].match.version == "1.0.0", "spectrum 1.0.0");

    g_context = "prereleases and drafts";
    std::string mixed = page({release("a-v2.0.0-beta", false, true, "foo_x.fb2k-component"),
                              release("a-v1.9.0", true, false, "foo_x.fb2k-component"),
                              release("a-v1.0.0", false, false, "foo_x.fb2k-component")});
    CHECK(select(mixed, "foo_x.fb2k-component", false).version == "1.0.0", "prerelease and draft skipped");
    CHECK(select(mixed, "foo_x.fb2k-component", true).version == "2.0.0-beta", "prerelease enabled takes the newest");
    CHECK(select(page({release("a-v3.0.0", true, false, "foo_x.fb2k-component")}), "foo_x.fb2k-component", true, &found).version == "" && !found, "only a draft");
    std::string wrongAsset = page({release("a-v1.0.0", false, false, "foo_y.fb2k-component")});
    select(wrongAsset, "foo_x.fb2k-component", false, &found);
    CHECK(!found, "asset name must match exactly");
    std::string http = "[{\"tag_name\":\"v1\",\"html_url\":\"x\",\"assets\":[{\"name\":\"foo_x.fb2k-component\",\"browser_download_url\":\"http://insecure/x\"}]}]";
    select(http, "foo_x.fb2k-component", false, &found);
    CHECK(!found, "non https asset skipped");
    ReleaseMatch amb = select(page({release("weird", false, false, "foo_x.fb2k-component")}), "foo_x.fb2k-component", false, &found);
    CHECK(found && amb.version.empty() && amb.tag == "weird", "ambiguous tag keeps the match without a version");

    g_context = "adversarial tags";
    {
        std::string evil = "prefix";
        for (int i = 0; i < 100000; ++i) evil += "-v1";
        CHECK(versionFromTag(evil) == "", "300 KB tag is Unable to compare, in bounded time");
        std::string longVersion = "v" + std::string(200, '1');
        CHECK(versionFromTag(longVersion) == "", "tag over 128 characters");
        CHECK(versionFromTag(std::string(120, 'a') + "-v1.0.0") == "1.0.0", "tag within the cap still works");
        CHECK(versionFromTag("a-v1-v2-v3") == "", "stops at the second distinct candidate");
        CHECK(versionFromTag("a-v1.0.0-v1.0.0") == "", "the tail of the first candidate is not the same text");
    }

    g_context = "release classification";
    {
        std::vector<Release> rel2;
        std::string e2;
        std::string base = "\"tag_name\":\"v1.0.0\",\"html_url\":\"https://x/y\",\"assets\":[]";
        CHECK(parseReleases("[{" + base + "}]", rel2, e2) && rel2.empty(), "no draft and prerelease: skipped");
        CHECK(parseReleases("[{" + base + ",\"draft\":false}]", rel2, e2) && rel2.empty(), "no prerelease: skipped");
        CHECK(parseReleases("[{" + base + ",\"prerelease\":false}]", rel2, e2) && rel2.empty(), "no draft: skipped");
        CHECK(parseReleases("[{" + base + ",\"draft\":\"false\",\"prerelease\":false}]", rel2, e2) && rel2.empty(), "draft not a boolean: skipped");
        CHECK(parseReleases("[{" + base + ",\"draft\":false,\"prerelease\":null}]", rel2, e2) && rel2.empty(), "prerelease null: skipped");
        CHECK(parseReleases("[5,{" + base + ",\"draft\":false,\"prerelease\":false}]", rel2, e2) && rel2.size() == 1, "a non object entry is skipped, the next one kept");
        std::string unclassified = "[{\"tag_name\":\"v9.0.0\",\"html_url\":\"https://x\",\"assets\":[{\"name\":\"foo_x.fb2k-component\",\"browser_download_url\":\"https://x/a\"}]}]";
        ReleaseMatch um = select(unclassified, "foo_x.fb2k-component", true, &found);
        CHECK(!found, "an unclassified release is never selected");
    }

    g_context = "parse errors";
    std::vector<Release> rel;
    std::string err;
    CHECK(!parseReleases("{}", rel, err) && !err.empty(), "object is not a list");
    CHECK(!parseReleases("nope", rel, err), "invalid json");
    CHECK(parseReleases("[]", rel, err) && rel.empty(), "empty list");
    CHECK(!parseReleases("[{\"tag_name\":5,\"draft\":false,\"prerelease\":false}]", rel, err), "wrong field type");

    g_context = "pagination";
    std::string p1 = page({release("a-v1.0.0", false, false, "foo_a.fb2k-component")});
    std::string p2 = page({release("b-v2.0.0", false, false, "foo_b.fb2k-component")});
    std::string p3 = page({release("c-v3.0.0", false, false, "foo_c.fb2k-component")});
    auto fetchPages = [&](std::vector<std::string> const& pages, int* count) {
        return [=](int p) {
            ++*count;
            PageFetch pf;
            pf.ok = true;
            pf.body = pages[p - 1];
            pf.hasNext = p < (int)pages.size();
            return pf;
        };
    };
    int n = 0;
    auto o = resolveRepository({"foo_a.fb2k-component", "foo_b.fb2k-component"}, fetchPages({p1, p2}, &n), false);
    CHECK_EQ(n, 2, "second page fetched because foo_b was missing");
    CHECK(o["foo_a.fb2k-component"].kind == AssetOutcome::Kind::Found && o["foo_b.fb2k-component"].kind == AssetOutcome::Kind::Found, "both found");

    n = 0;
    o = resolveRepository({"foo_a.fb2k-component"}, fetchPages({p1, p2}, &n), false);
    CHECK_EQ(n, 1, "no extra page when everything matched");

    n = 0;
    o = resolveRepository({"foo_z.fb2k-component"}, fetchPages({p1, p2}, &n), false);
    CHECK_EQ(n, 2, "stops when there is no next page");
    CHECK(o["foo_z.fb2k-component"].kind == AssetOutcome::Kind::NotFound, "not found");

    n = 0;
    o = resolveRepository({"foo_z.fb2k-component"}, fetchPages({p1, p2, p3, p1, p1}, &n), false);
    CHECK_EQ(n, 3, "at most 3 pages");
    CHECK(o["foo_z.fb2k-component"].kind == AssetOutcome::Kind::Incomplete, "incomplete");
    CHECK(o["foo_z.fb2k-component"].error.find("incomplete") != std::string::npos, "incomplete message");

    n = 0;
    o = resolveRepository({"foo_a.fb2k-component", "foo_c.fb2k-component"}, fetchPages({p1, p2, p3}, &n), false);
    CHECK_EQ(n, 3, "third page used");
    CHECK(o["foo_c.fb2k-component"].kind == AssetOutcome::Kind::Found, "found on page 3");

    n = 0;
    o = resolveRepository({"foo_a.fb2k-component", "foo_b.fb2k-component"},
        [&](int p) { ++n; PageFetch pf; if (p == 1) { pf.ok = true; pf.body = p1; pf.hasNext = true; } else pf.error = "boom"; return pf; }, false);
    CHECK(o["foo_a.fb2k-component"].kind == AssetOutcome::Kind::Found, "match from page 1 survives a later failure");
    CHECK(o["foo_b.fb2k-component"].kind == AssetOutcome::Kind::Error && o["foo_b.fb2k-component"].error == "boom", "page 2 failure reported");

    o = resolveRepository({"foo_a.fb2k-component"}, [](int) { PageFetch pf; pf.ok = true; pf.body = "garbage"; return pf; }, false);
    CHECK(o["foo_a.fb2k-component"].kind == AssetOutcome::Kind::Error, "garbage page");

    g_context = "link header";
    CHECK(hasNextPage("<https://api.github.com/x?page=2>; rel=\"next\", <https://api.github.com/x?page=5>; rel=\"last\""), "next present");
    CHECK(!hasNextPage("<https://api.github.com/x?page=1>; rel=\"prev\", <https://api.github.com/x?page=5>; rel=\"last\""), "no next");
    CHECK(!hasNextPage(""), "no header");

    g_context = "rate limit";
    HttpMeta m;
    m.status = 403;
    m.rateLimitRemaining = "0";
    m.rateLimitReset = "1700003600";
    RateLimitDecision d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700003600, "403 with remaining 0 uses the reset time");
    m.rateLimitReset = "";
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000060, "missing reset falls back to a minute");
    m = {};
    m.status = 429;
    m.retryAfter = "120";
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000120, "429 with Retry-After");
    m = {};
    m.status = 403;
    m.rateLimitRemaining = "12";
    m.rateLimitReset = "1700003600";
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000060, "403 with rate limit headers and quota left is a secondary limit: a minute");
    m = {};
    m.status = 403;
    m.retryAfter = "30";
    m.rateLimitRemaining = "12";
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000030, "secondary limit with Retry-After uses it");
    m = {};
    m.status = 403;
    m.errorBody = "{\"message\":\"You have exceeded a secondary rate limit. Please wait a few minutes\"}";
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000060, "secondary rate limit message alone");
    m = {};
    m.status = 403;
    m.errorBody = "{\"message\":\"Resource not accessible\"}";
    CHECK(!evaluateRateLimit(m, 1700000000).limited, "403 without headers or message is a plain error");
    m = {};
    m.status = 429;
    CHECK(!evaluateRateLimit(m, 1700000000).limited, "429 without headers is a plain error");
    m = {};
    m.status = 404;
    m.rateLimitRemaining = "0";
    m.retryAfter = "5";
    CHECK(!evaluateRateLimit(m, 1700000000).limited, "only 403 and 429 count");
    m = {};
    m.status = 200;
    m.retryAfter = "5";
    m.rateLimitRemaining = "0";
    CHECK(!evaluateRateLimit(m, 1700000000).limited, "success is never limited");
    m = {};
    m.status = 403;
    m.retryAfter = "99999999999999999999";
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000060, "absurd Retry-After falls back");
    std::string msg = rateLimitMessage(1700003600);
    g_context = "Retry-After forms";
    m = {};
    m.status = 429;
    m.retryAfter = "Tue, 14 Nov 2023 22:15:00 GMT"; // 1700000100
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000100, "HTTP-date in the future");
    m.retryAfter = "Tue, 14 Nov 2023 22:13:00 GMT"; // 1699999980, past
    d = evaluateRateLimit(m, 1700000000);
    CHECK(d.limited && d.untilEpoch == 1700000060, "HTTP-date in the past falls back");
    for (char const* bad : {"soon", "Tue, 14 Nov 2023", "-5", "12abc", "Tue, 14 Nov 2023 22:15:00 PST", "Tue, 14 Nov 2023 22:15:00 GMT junk"}) {
        m.retryAfter = bad;
        d = evaluateRateLimit(m, 1700000000);
        CHECK(d.limited && d.untilEpoch == 1700000060, bad);
    }
    m.retryAfter = "120";
    CHECK(evaluateRateLimit(m, 1700000000).untilEpoch == 1700000120, "numeric");
    m.retryAfter = "999999999";
    CHECK(evaluateRateLimit(m, 1700000000).untilEpoch == int64_t(1700000000) + 999999999, "numeric beyond 24 h is kept");
    m.retryAfter = "Tue, 21 Nov 2023 22:13:20 GMT"; // 1700604800, 7 days after now
    CHECK(evaluateRateLimit(m, 1700000000).untilEpoch == 1700604800, "HTTP-date beyond 24 h is kept");
    m.retryAfter = "99999999999999999999";
    CHECK(evaluateRateLimit(m, 1700000000).untilEpoch == 1700000060, "overflowing number falls back");
    m = {};
    m.status = 403;
    m.retryAfter = "30";
    m.rateLimitRemaining = "0";
    m.rateLimitReset = "1700003600";
    CHECK(evaluateRateLimit(m, 1700000000).untilEpoch == 1700003600, "both: the later deadline (reset)");
    m.rateLimitReset = "1700172800"; // 2 days after now
    m.retryAfter = "30";
    CHECK(evaluateRateLimit(m, 1700000000).untilEpoch == 1700172800, "reset beyond 24 h is kept");
    m.rateLimitReset = "1700003600";
    m.retryAfter = "7200";
    CHECK(evaluateRateLimit(m, 1700000000).untilEpoch == 1700007200, "both: the later deadline (Retry-After)");

    std::string prefix = "GitHub rate limit reached, try again after ";
    CHECK(msg.rfind(prefix, 0) == 0 && msg.size() == prefix.size() + 5, "message with HH:MM");
    CHECK(msg[msg.size() - 3] == ':', "clock format");

    TEST_MAIN_END();
}
