#include "../fb2k_sdk.h"
#include "repository_mapping.h"
#include "remote_registry.h"
#include "update_check.h"
#include "../Core/catalog_page.h"
#include "../Core/github_releases.h"
#include "../Core/mapping_validation.h"
#include "../Core/replacement.h"
#include "../Core/source_resolution.h"
#include "../Integration/Settings.h"
#include "../Platform/fcu_http.h"
#include "../Platform/fcu_platform.h"

#include <atomic>
#include <ctime>
#include <map>
#include <vector>
#include <string>
#include <algorithm>

// ------------------------------------------------------------------
// 更新確認のコアロジック(手動確認・自動確認で共用)
//
// 流れ:
//   1. componentversion::enumerate() で導入済みコンポーネントを取得(メインスレッド)
//   2. ソース解決(Core/source_resolution): Info.plist, Registry,
//      built in list, official catalog の順
//   3. GitHub は repository ごとに /releases を1回(最大3ページ)、他は upstream の fetcher
//   4. バージョン比較(compareVersions: update_parse.cpp)
// ------------------------------------------------------------------

namespace {

// 403/429 を受けた後、この時刻(epoch秒)まで GitHub を呼ばない。Check Again をまたいで保持する。
std::atomic<int64_t> g_githubBlockedUntil{0};

const char* const k_catalogBase = "https://www.foobar2000.org";

// ------------------------------------------------------------------
// サイト別のリリース取得。HTTP は fcu::httpGet、本文の解析は update_parse.cpp。
// ------------------------------------------------------------------

bool FetchBody(std::string const& url, abort_callback& abort, std::string& body, std::string& errorMessage) {
    try {
        body = fcu::httpGet(url, {}, abort);
        return true;
    } catch (std::exception const& e) {
        errorMessage = std::string("Network/API error: ") + e.what();
        return false;
    }
}

bool FetchGitLabLatestRelease(
    std::string const& owner, std::string const& repo, abort_callback& abort,
    FetchedRelease& out, std::string& errorMessage
) {
    std::string body;
    // GitLabのプロジェクトIDは "owner/repo" をURLエンコードした形("%2F"区切り)で指定する。
    if (!FetchBody("https://gitlab.com/api/v4/projects/" + owner + "%2F" + repo + "/releases/permalink/latest", abort, body, errorMessage)) return false;
    return ParseGitLabRelease(body, owner, repo, out, errorMessage);
}

bool FetchCodebergLatestRelease(
    std::string const& owner, std::string const& repo, abort_callback& abort,
    FetchedRelease& out, std::string& errorMessage
) {
    std::string body;
    // Codeberg(Gitea)は一覧取得APIを使い、先頭(最新)の1件だけ要求する。
    if (!FetchBody("https://codeberg.org/api/v1/repos/" + owner + "/" + repo + "/releases?limit=1&draft=false&pre-release=false", abort, body, errorMessage)) return false;
    return ParseCodebergRelease(body, out, errorMessage);
}

bool FetchMarc2k3LatestRelease(
    std::string const& pageUrl, abort_callback& abort,
    FetchedRelease& out, std::string& errorMessage
) {
    std::string body;
    if (!FetchBody(pageUrl, abort, body, errorMessage)) return false;
    return ParseMarc2k3Page(body, pageUrl, out, errorMessage);
}

bool FetchSourceForgeLatestRelease(
    std::string const& folderUrl, abort_callback& abort,
    FetchedRelease& out, std::string& errorMessage
) {
    std::string rssUrl, body;
    if (!BuildSourceForgeRssUrl(folderUrl, rssUrl, errorMessage)) return false;
    if (!FetchBody(rssUrl, abort, body, errorMessage)) return false;
    return ParseSourceForgeFeed(body, folderUrl, out, errorMessage);
}

bool FetchHyvLatestRelease(
    std::string const& pageUrl, abort_callback& abort,
    FetchedRelease& out, std::string& errorMessage
) {
    std::string body;
    if (!FetchBody(pageUrl, abort, body, errorMessage)) return false;
    return ParseHyvPage(body, pageUrl, out, errorMessage);
}

// ------------------------------------------------------------------
// GitHub(repositoryごとに /releases を取得し、asset名で選ぶ)
// ------------------------------------------------------------------

fcu::PageFetch FetchGitHubReleasesPage(
    std::string const& owner, std::string const& repo, int page, abort_callback& abort
) {
    fcu::PageFetch pf;
    int64_t blockedUntil = g_githubBlockedUntil.load();
    if (blockedUntil > static_cast<int64_t>(std::time(nullptr))) {
        pf.error = fcu::rateLimitMessage(blockedUntil);
        return pf;
    }

    std::string path = "/repos/" + owner + "/" + repo + "/releases?per_page=100&page=" + std::to_string(page);
    fcu::HttpMeta meta;
    try {
        pf.body = fcu::httpGet(fcu::endpoint("https://api.github.com" + path, path),
                               {{"Accept", "application/vnd.github+json"}}, abort, &meta);
        pf.ok = true;
        pf.hasNext = fcu::hasNextPage(meta.link);
    } catch (std::exception const& e) {
        // Cooldowns count from when the response arrived, not from request start.
        fcu::RateLimitDecision d = fcu::evaluateRateLimit(meta, static_cast<int64_t>(std::time(nullptr)));
        if (d.limited) {
            // Atomic maximum: a concurrent check must never shorten an active cooldown.
            int64_t current = g_githubBlockedUntil.load();
            while (current < d.untilEpoch && !g_githubBlockedUntil.compare_exchange_weak(current, d.untilEpoch)) {}
            pf.error = fcu::rateLimitMessage(g_githubBlockedUntil.load());
        } else if (meta.status == 404) {
            pf.error = "Repository or releases not found (HTTP 404)";
        } else {
            pf.error = std::string("Network/API error: ") + e.what();
        }
    }
    return pf;
}

// Notes accumulate so an ignored invalid FB2KUpdateSource stays visible after the
// check fell through to a later source.
void AddNote(CheckResult& r, std::string const& text) {
    if (text.empty()) return;
    r.note = r.note.empty() ? text : r.note + " " + text;
}

// A replacement row shows the release of the replacement; only a failed lookup stays an error.
void FinishReplacement(CheckResult& r) {
    if (r.status == UpdateStatus::Error) {
        // The error stays first: the Component Updates page recognizes a rate limit by how the message starts.
        r.errorMessage += " (while checking " + r.replacedBy + ", which replaces this component)";
        return;
    }
    r.status = UpdateStatus::Replaced;
}

void ApplyGitHubOutcome(CheckResult& r, fcu::AssetOutcome const& o) {
    r.errorMessage.clear();
    if (o.kind != fcu::AssetOutcome::Kind::Found) {
        r.status = UpdateStatus::Error;
        r.errorMessage = o.error;
        return;
    }
    r.releaseUrl = o.match.releaseUrl;
    r.downloadUrl = o.match.downloadUrl;
    r.assetName = o.match.assetName;
    r.prerelease = o.match.prerelease;
    r.releaseNotes = o.match.notes;
    r.releasedAt = o.match.publishedAt;
    if (o.match.version.empty()) {
        r.latestVersion = o.match.tag;
        r.status = UpdateStatus::ComparisonUnsupported;
    } else {
        r.latestVersion = o.match.version;
        r.status = compareVersions(r.installedVersion, r.latestVersion);
    }
}

// ------------------------------------------------------------------
// foobar2000.org のコンポーネントカタログ(ファイル名がそのままキー)
// ------------------------------------------------------------------

void CheckCatalog(CheckResult& r, abort_callback& abort) {
    r.errorMessage.clear();
    if (r.dllName.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-") != std::string::npos) {
        r.status = UpdateStatus::NoSource;
        AddNote(r, "The file name cannot be a catalog key.");
        return;
    }
    std::string path = "/components/view/" + r.dllName;
    std::string pageUrl = std::string(k_catalogBase) + path;
    std::string body;
    fcu::HttpMeta meta;
    try {
        body = fcu::httpGet(fcu::endpoint(pageUrl, path), {}, abort, &meta);
    } catch (std::exception const& e) {
        if (meta.status == 404) {
            r.status = UpdateStatus::NoSource;
            AddNote(r, "Not listed in the foobar2000.org component catalog.");
        } else {
            r.status = UpdateStatus::Error;
            r.errorMessage = std::string("Network/API error: ") + e.what();
        }
        return;
    }

    fcu::CatalogRelease release;
    std::string error;
    switch (fcu::parseCatalogPage(body, release, error)) {
    case fcu::CatalogStatus::Ok:
        r.latestVersion = release.version;
        r.releaseUrl = pageUrl;
        r.downloadUrl = fcu::endpoint(std::string(k_catalogBase) + release.downloadPath, release.downloadPath);
        r.assetName = release.downloadPath.substr(release.downloadPath.rfind('/') + 1);
        r.status = compareVersions(r.installedVersion, r.latestVersion);
        break;
    case fcu::CatalogStatus::NotInCatalog:
    case fcu::CatalogStatus::NoMacSupport:
        r.status = UpdateStatus::NoSource;
        AddNote(r, error);
        break;
    case fcu::CatalogStatus::Malformed:
        r.status = UpdateStatus::Error;
        r.errorMessage = error;
        break;
    }
}

std::string SourceLabel(RepositoryMappingEntry const& e) {
    if (e.source == "catalog") return "foobar2000.org";
    // The same fields the request is built from (validateSourceFields rejects mixed ones).
    if (e.source == "marc2k3" || e.source == "sourceforge" || e.source == "hyv") return e.url;
    return e.owner + "/" + e.repo;
}

std::string LowerKey(RepositoryMappingEntry const& e) {
    std::string k = e.owner + "/" + e.repo;
    std::transform(k.begin(), k.end(), k.begin(), [](unsigned char c) { return (char)std::tolower(c); });
    return k;
}

} // namespace

std::vector<InstalledComponentInfo> GetInstalledComponents() {
    std::vector<InstalledComponentInfo> installed;

    for (auto ptr : componentversion::enumerate()) {
        pfc::string8 fileName, name, version, about;
        ptr->get_file_name(fileName);
        ptr->get_component_name(name);
        ptr->get_component_version(version);
        ptr->get_about_message(about);

        InstalledComponentInfo info;
        info.fileName = fileName.c_str();
        info.displayName = name.c_str();
        info.installedVersion = version.c_str();
        info.about = fcu::textPreview(about.c_str());
        if (info.fileName != "Core") {
            auto keys = fcu::readBundleDictionaries(info.fileName, {"FB2KUpdateSource", "FB2KReplacedBy"});
            if ((info.hasBundleSource = keys.count("FB2KUpdateSource"))) info.bundleSourceJson = keys["FB2KUpdateSource"];
            if ((info.hasReplacedBy = keys.count("FB2KReplacedBy"))) info.replacedByJson = keys["FB2KReplacedBy"];
        }
        installed.push_back(std::move(info));
    }

    return installed;
}

namespace {

void RunChecks(
    std::vector<InstalledComponentInfo> const& installed,
    abort_callback& abort,
    std::function<void(std::string const&)> const& progress,
    std::vector<CheckResult>& results
) {
    auto say = [&](std::string const& message) { if (progress) progress(message); };

    fcu::SourceLists lists;

    // Remote Registry(開発側が管理する既知コンポーネントDB)。
    // Info.plistに更新元が無いコンポーネントの補完として使う(DP-0018 Hybrid Registry Model)。
    // GitHub上の静的JSONを取得するため、ここでもネットワークI/Oが発生しうる。
    say("Loading the shared registry...");
    RemoteRegistryFetchStatus registryStatus;
    std::vector<RemoteRegistryEntry> remoteEntries = GetRemoteRegistryEntries(abort, &registryStatus);
    for (auto const& e : remoteEntries) {
        lists.registry.push_back({e.dllName, e.source, e.owner, e.repo, e.url});
    }
    std::string const builtInText = fcu::bundledResource("extra_components", "json");
    fcu::parseRegistryJson(builtInText, lists.builtIn);
    std::map<std::string, fcu::Replacement> listedReplacements;
    std::vector<fcu::ComponentGroup> groups;
    fcu::parseBuiltInExtras(builtInText, listedReplacements, groups);

    // Remote Registry自体の取得に失敗した場合、これまでは完全に見えなかった。
    // 通知レベルの判定(automatic_check.cpp)に使えるよう、結果セットの一部として
    // 合成エントリを含める(手動確認では常に表示される)。
    if (!registryStatus.succeeded && !registryStatus.errorMessage.empty()) {
        CheckResult r;
        r.dllName = "";
        r.displayName = "Shared Registry (known_components.json)";
        r.installedVersion = "";
        r.status = UpdateStatus::Error;
        r.errorMessage = registryStatus.errorMessage;
        results.push_back(std::move(r));
    }

    struct Job {
        size_t row;
        RepositoryMappingEntry entry;
        fcu::SourceOrigin origin;
        bool isCatalog;
        std::string key;  // asset key: the component's file name, or its replacement's
        bool replacement; // the row shows the replacement's release (FinishReplacement); never falls through to the catalog
    };
    std::vector<Job> jobs;

    std::map<std::string, std::string> installedVersions; // normalized file name -> version
    std::vector<std::string> names;
    for (auto const& comp : installed) {
        if (comp.fileName == "Core") continue;
        installedVersions[fcu::normalizeComponentName(comp.fileName)] = comp.installedVersion;
        names.push_back(comp.fileName);
    }
    std::map<std::string, std::string> const overlaps = fcu::overlapNotes(names, groups);

    // Read once: what the foobar2000 that is running now already includes.
    std::string const runningVersion = core_version_info_v2::get()->get_version_as_text();

    for (auto const& comp : installed) {
        CheckResult r;
        r.dllName = comp.fileName;
        r.displayName = comp.displayName;
        r.installedVersion = comp.installedVersion;
        r.about = comp.about;
        auto overlap = overlaps.find(fcu::normalizeComponentName(comp.fileName));
        if (overlap != overlaps.end() && comp.fileName != "Core") r.overlap = overlap->second;

        fcu::ReplacementLookup rl = fcu::findReplacement(comp.fileName, comp.hasReplacedBy, comp.replacedByJson, listedReplacements);
        if (rl.origin != fcu::ReplacementOrigin::None) {
            r.replacedBy = rl.replacement.name;
            r.migration = rl.replacement.migration;
            r.replacementTeam = rl.replacement.team;
            r.replacementOrigin = rl.origin == fcu::ReplacementOrigin::InfoPlist ? "Info.plist" : "built in list";
            r.kept = IsReplacementKept(comp.fileName, r.replacedBy);
        }
        std::string const declaredBy = rl.origin == fcu::ReplacementOrigin::InfoPlist ? ", as this component declares." : ", according to the built in list of this updater.";
        bool const byFoobar2000 = !rl.replacement.foobar2000.empty();
        bool const foobar2000Older = byFoobar2000 && !r.kept && !fcu::foobar2000Includes(runningVersion, rl.replacement.foobar2000);
        if (byFoobar2000 && !r.kept && !foobar2000Older) {
            // foobar2000 itself took over: only the removal is left, so there is no successor to look up or download.
            AddNote(r, "Replaced by foobar2000 " + rl.replacement.foobar2000 + ", which includes it" + declaredBy);
            AddNote(r, rl.note);
            r.status = UpdateStatus::Replaced;
            r.replacedByFoobar2000 = true;
            r.replacementInstalled = true;
            r.latestVersion = rl.replacement.foobar2000;
            results.push_back(std::move(r));
            continue;
        }
        if (!r.replacedBy.empty() && !r.kept && !byFoobar2000) {
            AddNote(r, "Replaced by " + r.replacedBy + declaredBy);
            AddNote(r, rl.note);
            r.status = UpdateStatus::Replaced;
            auto present = installedVersions.find(fcu::normalizeComponentName(r.replacedBy));
            if (present != installedVersions.end()) {
                r.replacementInstalled = true;
                r.latestVersion = present->second;
                results.push_back(std::move(r));
                continue;
            }
            // Only the built in list or the declaration itself may say where the successor's code comes from; there is
            // no identity to compare it with. A name the built in list knows keeps that source, so a declaration cannot
            // install an impostor under a trusted name. Neither the shared registry nor the catalog is consulted.
            fcu::SourceLists listed;
            listed.builtIn = lists.builtIn;
            fcu::ResolvedSource rs = fcu::resolveSource(r.replacedBy, {}, listed);
            if (rs.origin != fcu::SourceOrigin::BuiltIn && rl.replacement.hasSource) {
                rs.origin = rl.origin == fcu::ReplacementOrigin::InfoPlist ? fcu::SourceOrigin::InfoPlist : fcu::SourceOrigin::BuiltIn;
                rs.entry = rl.replacement.source;
                rs.invalid.clear();
            }
            if (rs.origin == fcu::SourceOrigin::Catalog) {
                AddNote(r, "No source of " + r.replacedBy + " was declared, so it cannot be installed from here.");
                results.push_back(std::move(r));
                continue;
            }
            r.sourceOrigin = fcu::originLabel(rs.origin);
            r.sourceLabel = SourceLabel(rs.entry);
            if (!rs.invalid.empty()) {
                AddNote(r, "The source of " + r.replacedBy + " is invalid: " + rs.invalid);
            } else {
                r.status = UpdateStatus::Error;
                r.errorMessage = "Check cancelled.";
                jobs.push_back({results.size(), rs.entry, rs.origin, false, r.replacedBy, true});
            }
            results.push_back(std::move(r));
            continue;
        }
        if (r.kept) AddNote(r, "Replaced by " + r.replacedBy + "; you keep this component.");

        fcu::ResolvedSource rs = fcu::resolveSource(comp.fileName, {comp.hasBundleSource, comp.bundleSourceJson}, lists);
        AddNote(r, rs.note);
        AddNote(r, rl.note);
        if (foobar2000Older) AddNote(r, "foobar2000 " + rl.replacement.foobar2000 + " includes this; after updating foobar2000 it can be removed.");
        if (rs.origin == fcu::SourceOrigin::None) {
            r.status = UpdateStatus::NoSource;
            if (comp.fileName == "Core") r.note = "Built in to foobar2000.";
        } else {
            r.sourceOrigin = fcu::originLabel(rs.origin);
            r.sourceLabel = SourceLabel(rs.entry);
            r.status = UpdateStatus::Error;
            if (!rs.invalid.empty()) {
                // The entry never reaches a URL: the row just reports why.
                r.errorMessage = "Invalid source: " + rs.invalid;
            } else {
                r.errorMessage = "Check cancelled.";
                jobs.push_back({results.size(), rs.entry, rs.origin, rs.origin == fcu::SourceOrigin::Catalog, comp.fileName, false});
            }
        }
        results.push_back(std::move(r));
    }

    const bool includePrereleases = GetIncludePrereleases();

    // GitHub: repositoryごとにまとめて、releasesの取得は1回(最大3ページ)。
    std::map<std::string, std::vector<size_t>> githubGroups;
    for (size_t j = 0; j < jobs.size(); ++j) {
        if (!jobs[j].isCatalog && jobs[j].entry.source == "github") githubGroups[LowerKey(jobs[j].entry)].push_back(j);
    }
    for (auto const& group : githubGroups) {
        if (abort.is_aborting()) return;
        RepositoryMappingEntry const& first = jobs[group.second.front()].entry;
        say("Checking " + first.owner + "/" + first.repo + "...");

        std::vector<std::string> keys;
        for (size_t j : group.second) keys.push_back(jobs[j].key);

        auto outcomes = fcu::resolveRepository(
            keys,
            [&](int page) { return FetchGitHubReleasesPage(first.owner, first.repo, page, abort); },
            includePrereleases);
        for (size_t j : group.second) {
            CheckResult& r = results[jobs[j].row];
            fcu::AssetOutcome const& outcome = outcomes[jobs[j].key];
            if (jobs[j].replacement || !fcu::fallsThroughToCatalog(jobs[j].origin, outcome.kind)) {
                ApplyGitHubOutcome(r, outcome);
                continue;
            }
            // Handled by the catalog pass below, after every GitHub repository.
            jobs[j].isCatalog = true;
            r.sourceOrigin = fcu::originLabel(fcu::SourceOrigin::Catalog);
            r.sourceLabel = "foobar2000.org";
            AddNote(r, "No release of " + first.owner + "/" + first.repo + " has a matching package, so the foobar2000.org catalog was checked instead.");
        }
    }

    size_t done = 0;
    for (auto const& job : jobs) {
        if (job.isCatalog || job.entry.source == "github") continue;
        if (abort.is_aborting()) return;
        CheckResult& r = results[job.row];
        say("Checking " + r.displayName + " (" + std::to_string(++done) + ")...");

        RepositoryMappingEntry const& mapping = job.entry;
        FetchedRelease release;
        std::string errorMessage;
        bool fetchOk = false;

        if (mapping.source == "gitlab") {
            fetchOk = FetchGitLabLatestRelease(mapping.owner, mapping.repo, abort, release, errorMessage);
        } else if (mapping.source == "codeberg") {
            fetchOk = FetchCodebergLatestRelease(mapping.owner, mapping.repo, abort, release, errorMessage);
        } else if (mapping.source == "marc2k3") {
            fetchOk = FetchMarc2k3LatestRelease(mapping.url, abort, release, errorMessage);
        } else if (mapping.source == "sourceforge") {
            fetchOk = FetchSourceForgeLatestRelease(mapping.url, abort, release, errorMessage);
        } else if (mapping.source == "hyv") {
            fetchOk = FetchHyvLatestRelease(mapping.url, abort, release, errorMessage);
        }

        if (fetchOk) {
            r.errorMessage.clear();
            r.latestVersion = release.tagName;
            r.releaseUrl = release.releaseUrl;
            r.status = compareVersions(r.installedVersion, r.latestVersion);
        } else {
            r.status = UpdateStatus::Error;
            r.errorMessage = errorMessage.empty() ? "Invalid response: no release found." : errorMessage;
        }
    }

    for (auto const& job : jobs) {
        if (!job.isCatalog) continue;
        if (abort.is_aborting()) return;
        CheckResult& r = results[job.row];
        say("Checking " + r.displayName + " in the foobar2000.org catalog...");
        CheckCatalog(r, abort);
    }

    for (auto const& job : jobs) {
        if (job.replacement) FinishReplacement(results[job.row]);
    }
}

} // namespace

// Entry point of every worker (Component Updates page, automatic check, autotest): nothing may
// escape into foobar2000, including std::bad_alloc, so a failure ends as a row.
std::vector<CheckResult> RunUpdateCheck(
    std::vector<InstalledComponentInfo> const& installed,
    abort_callback& abort,
    std::function<void(std::string const&)> const& progress
) {
    std::vector<CheckResult> results;
    try {
        RunChecks(installed, abort, progress, results);
    } catch (std::exception const& e) {
        CheckResult r;
        r.displayName = "Update check";
        r.status = UpdateStatus::Error;
        r.errorMessage = std::string("The check stopped unexpectedly: ") + e.what();
        results.push_back(std::move(r));
    } catch (...) {
        CheckResult r;
        r.displayName = "Update check";
        r.status = UpdateStatus::Error;
        r.errorMessage = "The check stopped unexpectedly.";
        results.push_back(std::move(r));
    }
    return results;
}

namespace {
std::atomic<bool> g_checkRunning{false};
std::atomic<int64_t> g_checkId{0};
#ifdef FCU_DEBUG_HOOKS
std::atomic<int> g_checksBegun{0};
#endif
}

bool TryBeginUpdateCheck() {
    bool expected = false;
    if (!g_checkRunning.compare_exchange_strong(expected, true)) return false;
    ++g_checkId;
#ifdef FCU_DEBUG_HOOKS
    ++g_checksBegun;
#endif
    return true;
}

void EndUpdateCheck() { g_checkRunning = false; }

bool IsUpdateCheckRunning() { return g_checkRunning.load(); }

int64_t CurrentUpdateCheckId() { return g_checkId.load(); }

#ifdef FCU_DEBUG_HOOKS
int DebugChecksBegun() { return g_checksBegun.load(); }
#endif

bool HasUpdateAvailable(std::vector<CheckResult> const& results) {
    for (auto const& r : results) {
        if (r.status == UpdateStatus::UpdateAvailable || r.status == UpdateStatus::Replaced) return true;
    }
    return false;
}

bool HasAnyError(std::vector<CheckResult> const& results) {
    for (auto const& r : results) {
        if (r.status == UpdateStatus::Error) return true;
    }
    return false;
}
