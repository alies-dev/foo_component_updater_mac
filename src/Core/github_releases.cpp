#include "github_releases.h"

#include <algorithm>
#include <cctype>
#include <ctime>
#include <set>

#include "../upstream/third_party/nlohmann/json.hpp"
#include "../upstream/update_parse.h"

namespace fcu {

namespace {

constexpr size_t kMaxTagLength = 128;

bool isIdentifierList(std::string const& s) {
    if (s.empty()) return false;
    size_t start = 0;
    while (true) {
        size_t dot = s.find('.', start);
        std::string id = s.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        if (id.empty()) return false;
        for (char c : id) {
            if (!std::isalnum(static_cast<unsigned char>(c)) && c != '-') return false;
        }
        if (dot == std::string::npos) return true;
        start = dot + 1;
    }
}

// Complete versions only, for tag extraction: [v]N(.N)*[-prerelease][+build] with
// non empty SemVer identifiers. upstream's compareVersions is more lenient
// ("1.2." reads as 1.2) and stays untouched; this runs first.
bool isValidVersion(std::string const& raw) {
    std::string s = raw;
    if (!s.empty() && (s[0] == 'v' || s[0] == 'V')) s.erase(0, 1);
    size_t plus = s.find('+');
    if (plus != std::string::npos) {
        if (!isIdentifierList(s.substr(plus + 1))) return false;
        s.resize(plus);
    }
    size_t dash = s.find('-');
    if (dash != std::string::npos) {
        if (!isIdentifierList(s.substr(dash + 1))) return false;
        s.resize(dash);
    }
    size_t start = 0;
    while (true) {
        size_t dot = s.find('.', start);
        std::string seg = s.substr(start, dot == std::string::npos ? std::string::npos : dot - start);
        if (seg.empty()) return false;
        for (char c : seg) if (!std::isdigit(static_cast<unsigned char>(c))) return false;
        if (dot == std::string::npos) break;
        start = dot + 1;
    }
    return compareVersions(raw, raw) != UpdateStatus::ComparisonUnsupported;
}

std::string stripV(std::string s) {
    if (!s.empty() && (s[0] == 'v' || s[0] == 'V')) s.erase(0, 1);
    return s;
}

bool allDigits(std::string const& s) {
    if (s.empty() || s.size() > 12) return false;
    for (char c : s) if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    return true;
}

} // namespace

bool parseReleases(std::string const& body, std::vector<Release>& out, std::string& error) {
    out.clear();
    try {
        nlohmann::json parsed = nlohmann::json::parse(body);
        if (!parsed.is_array()) {
            error = "Invalid response: expected a list of releases.";
            return false;
        }
        for (auto const& item : parsed) {
            // A release whose draft or prerelease flag is missing or not a boolean cannot
            // be classified, so it is skipped rather than assumed to be a stable release.
            auto draft = item.find("draft");
            auto prerelease = item.find("prerelease");
            if (!item.is_object() || draft == item.end() || !draft->is_boolean()
                || prerelease == item.end() || !prerelease->is_boolean()) {
                continue;
            }
            Release r;
            r.tag = item.value("tag_name", "");
            r.htmlUrl = item.value("html_url", "");
            r.draft = draft->get<bool>();
            r.prerelease = prerelease->get<bool>();
            if (item.contains("assets") && item["assets"].is_array()) {
                for (auto const& a : item["assets"]) {
                    r.assets.push_back({a.value("name", ""), a.value("browser_download_url", "")});
                }
            }
            out.push_back(std::move(r));
        }
        return true;
    } catch (std::exception const& e) {
        error = std::string("Invalid response: ") + e.what();
        return false;
    }
}

std::string versionFromTag(std::string const& tag) {
    // Bounded work on remote input: no real version tag is this long.
    if (tag.size() > kMaxTagLength) return std::string();
    if (isValidVersion(tag)) return stripV(tag);

    std::string candidate;
    for (size_t pos = tag.find("-v"); pos != std::string::npos; pos = tag.find("-v", pos + 1)) {
        std::string tail = tag.substr(pos + 2);
        if (tail.empty() || !isValidVersion(tail) || tail == candidate) continue;
        if (!candidate.empty()) return std::string(); // a second distinct candidate: ambiguous
        candidate = std::move(tail);
    }
    return candidate;
}

bool selectRelease(std::vector<Release> const& releases, std::string const& assetName,
                   bool includePrereleases, ReleaseMatch& out) {
    for (auto const& r : releases) {
        if (r.draft || (r.prerelease && !includePrereleases)) continue;
        for (auto const& a : r.assets) {
            if (a.name != assetName || a.url.rfind("https://", 0) != 0) continue;
            out.tag = r.tag;
            out.version = versionFromTag(r.tag);
            out.releaseUrl = r.htmlUrl;
            out.downloadUrl = a.url;
            out.assetName = a.name;
            return true;
        }
    }
    return false;
}

bool hasNextPage(std::string const& linkHeader) {
    return linkHeader.find("rel=\"next\"") != std::string::npos;
}

std::map<std::string, AssetOutcome> resolveRepository(
    std::vector<std::string> const& assetNames,
    std::function<PageFetch(int page)> const& fetchPage,
    bool includePrereleases, int maxPages) {
    std::map<std::string, AssetOutcome> result;
    std::set<std::string> pending(assetNames.begin(), assetNames.end());

    auto failPending = [&](AssetOutcome::Kind kind, std::string const& error) {
        for (auto const& name : pending) {
            AssetOutcome o;
            o.kind = kind;
            o.error = error;
            result[name] = std::move(o);
        }
        pending.clear();
    };

    for (int page = 1; page <= maxPages && !pending.empty(); ++page) {
        PageFetch pf = fetchPage(page);
        if (!pf.ok) {
            failPending(AssetOutcome::Kind::Error, pf.error);
            break;
        }
        std::vector<Release> releases;
        std::string error;
        if (!parseReleases(pf.body, releases, error)) {
            failPending(AssetOutcome::Kind::Error, error);
            break;
        }
        for (auto it = pending.begin(); it != pending.end();) {
            AssetOutcome o;
            if (selectRelease(releases, *it, includePrereleases, o.match)) {
                o.kind = AssetOutcome::Kind::Found;
                result[*it] = std::move(o);
                it = pending.erase(it);
            } else {
                ++it;
            }
        }
        if (pending.empty()) break;
        if (!pf.hasNext) {
            failPending(AssetOutcome::Kind::NotFound, "No release with this component's package was found.");
        } else if (page == maxPages) {
            failPending(AssetOutcome::Kind::Incomplete, "Release list incomplete: no matching release in the newest " + std::to_string(maxPages) + " pages.");
        }
    }
    return result;
}

namespace {

constexpr int64_t kFallbackCooldown = 60;

// Retry-After is delta-seconds or an HTTP-date (RFC 9110); anything else, and a
// date that is not in the future, falls back to a minute.
int64_t retryAfterDeadline(std::string const& value, int64_t nowEpoch) {
    if (allDigits(value)) return nowEpoch + std::stoll(value);
    std::tm tm{};
    char const* end = strptime(value.c_str(), "%a, %d %b %Y %H:%M:%S GMT", &tm);
    if (end && *end == '\0') {
        int64_t when = static_cast<int64_t>(timegm(&tm));
        if (when > nowEpoch) return when;
    }
    return nowEpoch + kFallbackCooldown;
}

} // namespace

RateLimitDecision evaluateRateLimit(HttpMeta const& meta, int64_t nowEpoch) {
    RateLimitDecision d;
    if (meta.status != 403 && meta.status != 429) return d;

    bool secondary = meta.errorBody.find("secondary rate limit") != std::string::npos;
    bool hasRetryAfter = !meta.retryAfter.empty();
    bool hasLimitHeaders = !meta.rateLimitRemaining.empty() || !meta.rateLimitReset.empty();
    if (!secondary && !hasRetryAfter && !hasLimitHeaders) return d;

    int64_t until = nowEpoch + kFallbackCooldown;
    if (hasRetryAfter) until = retryAfterDeadline(meta.retryAfter, nowEpoch);
    if (meta.rateLimitRemaining == "0" && allDigits(meta.rateLimitReset)) {
        int64_t reset = std::stoll(meta.rateLimitReset);
        until = hasRetryAfter ? std::max(until, reset) : reset;
    }
    d.limited = true;
    d.untilEpoch = until;
    return d;
}

std::string rateLimitMessage(int64_t untilEpoch) {
    std::time_t t = static_cast<std::time_t>(untilEpoch);
    std::tm local{};
    localtime_r(&t, &local);
    char buf[16];
    std::strftime(buf, sizeof buf, "%H:%M", &local);
    return std::string("GitHub rate limit reached, try again after ") + buf;
}

} // namespace fcu
