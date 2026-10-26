#pragma once

#include <string>

// Pure parsing and version comparison moved out of update_check.cpp so the unit
// tests build without the foobar2000 SDK. Bodies are verbatim from upstream.

enum class UpdateStatus {
    UpdateAvailable,
    UpToDate,
    ComparisonUnsupported,
    Error,
    NoSource,
    Replaced, // another component took over (CheckResult::replacedBy); never from compareVersions
};

UpdateStatus compareVersions(std::string const& installedRaw, std::string const& latestRaw);

struct FetchedRelease {
    std::string tagName;
    std::string releaseUrl;
};

bool ParseGitLabRelease(
    std::string const& body, std::string const& owner, std::string const& repo,
    FetchedRelease& out, std::string& errorMessage
);

bool ParseCodebergRelease(
    std::string const& body,
    FetchedRelease& out, std::string& errorMessage
);

bool ParseMarc2k3Page(
    std::string const& html, std::string const& pageUrl,
    FetchedRelease& out, std::string& errorMessage
);

bool BuildSourceForgeRssUrl(
    std::string const& folderUrl, std::string& rssUrl, std::string& errorMessage
);

bool ParseSourceForgeFeed(
    std::string const& xml, std::string const& folderUrl,
    FetchedRelease& out, std::string& errorMessage
);

bool ParseHyvPage(
    std::string const& html, std::string const& pageUrl,
    FetchedRelease& out, std::string& errorMessage
);
