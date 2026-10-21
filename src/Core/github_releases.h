#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "http_meta.h"

namespace fcu {

struct ReleaseAsset {
    std::string name;
    std::string url;
};

struct Release {
    std::string tag;
    std::string htmlUrl;
    bool draft = false;
    bool prerelease = false;
    std::vector<ReleaseAsset> assets;
};

struct ReleaseMatch {
    std::string tag;
    std::string version; // empty when the tag has no unambiguous version
    std::string releaseUrl;
    std::string downloadUrl;
    std::string assetName;
};

// Parses one page of GET /repos/{owner}/{repo}/releases.
bool parseReleases(std::string const& body, std::vector<Release>& out, std::string& error);

// The whole tag when it is a valid version (optional "v"),
// otherwise the text after a "-v" that forms a complete valid version.
// Returns "" when nothing or more than one candidate qualifies.
std::string versionFromTag(std::string const& tag);

enum class Selection { Found, NoMatch, Ambiguous };

// The newest release (list order, no draft, no prerelease unless enabled) with an
// https asset that is a candidate package for componentKey (exact
// "<key>.fb2k-component", or key plus version and platform suffixes). Older
// releases are not consulted once one has a candidate. Ambiguous: that release
// has several equally good candidates (out.tag names it); fail closed.
Selection selectRelease(std::vector<Release> const& releases, std::string const& componentKey,
                        bool includePrereleases, ReleaseMatch& out);

// True when the Link header carries rel="next".
bool hasNextPage(std::string const& linkHeader);

struct PageFetch {
    bool ok = false;
    std::string body;
    bool hasNext = false;
    std::string error;
};

struct AssetOutcome {
    enum class Kind { Found, NotFound, Incomplete, Error };
    Kind kind = Kind::Error;
    ReleaseMatch match;
    std::string error;
};

// One repository, several components (monorepo), keyed by component name: pages
// are requested only while some component is unmatched, at most maxPages.
// NotFound means no release has a candidate package; an ambiguous release is an Error.
std::map<std::string, AssetOutcome> resolveRepository(
    std::vector<std::string> const& componentKeys,
    std::function<PageFetch(int page)> const& fetchPage,
    bool includePrereleases, int maxPages = 3);

struct RateLimitDecision {
    bool limited = false;
    int64_t untilEpoch = 0;
};

// 403 or 429 carrying Retry-After or x-ratelimit-remaining: 0.
RateLimitDecision evaluateRateLimit(HttpMeta const& meta, int64_t nowEpoch);

// "GitHub rate limit reached, try again after HH:MM" (local time).
std::string rateLimitMessage(int64_t untilEpoch);

} // namespace fcu
