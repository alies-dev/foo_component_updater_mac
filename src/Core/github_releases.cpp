#include "github_releases.h"

#include <algorithm>
#include <cctype>
#include <ctime>
#include <set>
#include <string_view>

#include "../upstream/third_party/nlohmann/json.hpp"
#include "../upstream/update_parse.h"

namespace fcu {

namespace {

constexpr size_t kMaxTagLength = 128;
constexpr size_t kMaxNotesPreview = 1000;

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

std::string normalizeAssetText(std::string s) {
    for (char& c : s) c = c == '-' ? '_' : static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool endsWith(std::string_view s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Filename version token: optional v/V, then digits separated by single dots
// ("1.2.1", "v0.1.5", "2"). Unlike isValidVersion, no pre-release or build suffix.
bool isNumericVersionToken(std::string_view t) {
    if (!t.empty() && (t.front() == 'v' || t.front() == 'V')) t.remove_prefix(1);
    if (t.empty()) return false;
    bool digitSeen = false;
    for (char c : t) {
        if (std::isdigit(static_cast<unsigned char>(c))) digitSeen = true;
        else if (c == '.' && digitSeen) digitSeen = false;
        else return false;
    }
    return digitSeen;
}

// Lower is better: exact name, then a platform suffix, then a bare or versioned
// name; within a rank .fb2k-component beats .zip. A candidate is the normalized
// key, one optional version token, then platform tokens, each after a separator,
// so "foo_x" never claims "foo_x_y". A zip is accepted for reporting only.
bool assetScore(std::string const& key, std::string const& name, bool isExact, int& score) {
    std::string const normalized = normalizeAssetText(name);
    std::string_view n = normalized;
    int extension;
    if (endsWith(n, ".fb2k_component")) {
        extension = 0;
        n.remove_suffix(15);
    } else if (endsWith(n, ".zip")) {
        extension = 1;
        n.remove_suffix(4);
    } else {
        return false;
    }
    if (n.compare(0, key.size(), key) != 0) return false;

    bool versioned = false;
    int platforms = 0;
    for (size_t pos = key.size(); pos < n.size();) {
        if (n[pos] != '_') return false;
        size_t end = std::min(n.find('_', pos + 1), n.size());
        std::string_view token = n.substr(pos + 1, end - pos - 1);
        if (token == "macos" || token == "mac" || token == "arm64" || token == "universal") ++platforms;
        else if (!versioned && platforms == 0 && isNumericVersionToken(token)) versioned = true;
        else return false;
        pos = end;
    }
    score = (isExact ? 0 : platforms > 0 ? 1 : 2) * 2 + extension;
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
            auto body = item.find("body"); // null when the author wrote no notes
            if (body != item.end() && body->is_string()) r.body = body->get<std::string>();
            auto published = item.find("published_at");
            if (published != item.end() && published->is_string()) r.publishedAt = published->get<std::string>();
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

std::string textPreview(std::string const& body) {
    std::string out;
    bool blank = false; // a blank line was skipped since the last text
    size_t pos = 0;
    while (pos <= body.size()) {
        size_t end = body.find_first_of("\r\n", pos);
        if (end == std::string::npos) end = body.size();
        std::string_view line(body.data() + pos, end - pos);
        size_t last = line.find_last_not_of(" \t");
        if (last == std::string_view::npos) {
            blank = !out.empty();
        } else {
            if (!out.empty()) out.append(blank ? "\n\n" : "\n");
            blank = false;
            size_t first = out.empty() ? line.find_first_not_of(" \t") : 0;
            out.append(line.substr(first, last + 1 - first));
        }
        pos = end + (body.compare(end, 2, "\r\n") == 0 ? 2 : 1); // \r\n, \r and \n all end a line
    }
    if (out.size() > kMaxNotesPreview) {
        size_t cut = kMaxNotesPreview;
        while (cut > 0 && (static_cast<unsigned char>(out[cut]) & 0xC0) == 0x80) --cut; // not inside a UTF-8 sequence
        out.erase(cut);
        out += "\u2026";
    }
    return out;
}

Selection selectRelease(std::vector<Release> const& releases, std::string const& componentKey,
                        bool includePrereleases, ReleaseMatch& out) {
    std::string const key = normalizeAssetText(componentKey);
    std::string const exact = componentKey + ".fb2k-component";
    for (auto const& r : releases) {
        if (r.draft || (r.prerelease && !includePrereleases)) continue;
        ReleaseAsset const* best = nullptr;
        int bestScore = 0;
        bool tie = false;
        for (auto const& a : r.assets) {
            int score = 0;
            if (a.url.rfind("https://", 0) != 0 || !assetScore(key, a.name, a.name == exact, score)) continue;
            if (best && score == bestScore) tie = true;
            if (!best || score < bestScore) { best = &a; bestScore = score; tie = false; }
        }
        if (!best) continue;
        out.tag = r.tag;
        if (tie) return Selection::Ambiguous;
        out.version = versionFromTag(r.tag);
        out.releaseUrl = r.htmlUrl;
        out.downloadUrl = best->url;
        out.assetName = best->name;
        out.prerelease = r.prerelease;
        out.notes = textPreview(r.body);
        out.publishedAt = r.publishedAt;
        return Selection::Found;
    }
    return Selection::NoMatch;
}

bool hasNextPage(std::string const& linkHeader) {
    return linkHeader.find("rel=\"next\"") != std::string::npos;
}

std::map<std::string, AssetOutcome> resolveRepository(
    std::vector<std::string> const& componentKeys,
    std::function<PageFetch(int page)> const& fetchPage,
    bool includePrereleases, int maxPages) {
    std::map<std::string, AssetOutcome> result;
    std::set<std::string> pending(componentKeys.begin(), componentKeys.end());

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
            Selection selection = selectRelease(releases, *it, includePrereleases, o.match);
            if (selection == Selection::NoMatch) {
                ++it;
                continue;
            }
            if (selection == Selection::Found) {
                o.kind = AssetOutcome::Kind::Found;
            } else {
                o.kind = AssetOutcome::Kind::Error;
                o.error = "Release " + o.match.tag + " has several equally suitable packages for this component.";
            }
            result[*it] = std::move(o);
            it = pending.erase(it);
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
