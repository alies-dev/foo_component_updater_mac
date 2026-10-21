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

// First release in list order that is not a draft (nor a prerelease unless
// enabled) and carries an https asset called assetName.
bool selectRelease(std::vector<Release> const& releases, std::string const& assetName,
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

// One repository, several components (monorepo): pages are requested only
// while some asset is still unmatched, at most maxPages.
std::map<std::string, AssetOutcome> resolveRepository(
    std::vector<std::string> const& assetNames,
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
