#pragma once

#include "../fb2k_sdk.h"
#include "update_parse.h"
#include "../version.h"

#include <cstdint>
#include <functional>
#include <vector>
#include <string>

// Update Checkのコアロジック。手動確認(mainmenu_commands_check_for_updates)と
// 自動確認(automatic_check.cpp)の両方から共用する。

struct InstalledComponentInfo {
    std::string fileName;
    std::string displayName;
    std::string installedVersion;
    std::string about;              // the component's about text (author, description)
    bool hasBundleSource = false;   // Info.plist has an FB2KUpdateSource key
    std::string bundleSourceJson;   // that dictionary as JSON
    bool hasReplacedBy = false;     // Info.plist has an FB2KReplacedBy key
    std::string replacedByJson;     // that dictionary as JSON
};

struct CheckResult {
    std::string dllName;
    std::string displayName;
    std::string installedVersion;
    std::string latestVersion;
    std::string releaseUrl;
    bool prerelease = false;   // the author marked the latest release as a prerelease
    std::string releaseNotes;  // preview of the release notes, empty when unknown
    std::string releasedAt;    // ISO 8601 publish time of the latest release, empty when unknown
    std::string about;         // the component's about text
    UpdateStatus status = UpdateStatus::Error;
    std::string errorMessage;
    std::string downloadUrl;   // package link, empty for sources that only offer a page
    std::string assetName;
    std::string sourceOrigin;  // user, Info.plist, registry, built in list, catalog
    std::string sourceLabel;   // owner/repo or URL
    std::string note;          // row tooltip
    // Set when the component has a declared replacement. Unless the user keeps this component, the row
    // is UpdateStatus::Replaced and the release fields above describe the replacement.
    std::string replacedBy;          // replacement file name
    std::string replacementOrigin;   // who declared it: "Info.plist" (the component) or "built in list"
    std::string migration;           // https page with migration notes, "" when none
    std::string replacementTeam;     // declared Team ID of the successor, "" when not declared
    bool replacementInstalled = false; // the replacement is installed too: switching only removes this one
    bool replacedByFoobar2000 = false; // foobar2000 itself replaced it (replacedBy is "foobar2000", latestVersion the version that includes it): removal only
    bool kept = false;               // the user keeps this component; the row is checked as usual
    std::string overlap;             // other installed components that do the same job, empty when none
};

// 導入済みコンポーネント一覧を取得する。
// componentversion::enumerate() を呼ぶため、メインスレッドで実行すること。
std::vector<InstalledComponentInfo> GetInstalledComponents();

// ソース解決(Info.plist, registry, built in list, catalog の順)とバージョン比較を行う。
// ネットワークI/Oを含むため、ワーカースレッドで実行すること。
// progress: 状況表示用(ワーカースレッドから呼ばれる)。
std::vector<CheckResult> RunUpdateCheck(
    std::vector<InstalledComponentInfo> const& installed,
    abort_callback& abort,
    std::function<void(std::string const&)> const& progress = {}
);

// 同時に実行する確認は1つだけ。メインスレッドで開始前に TryBegin を呼び、
// 確認(ワーカー)が終わったら End を呼ぶ。
bool TryBeginUpdateCheck();
void EndUpdateCheck();
bool IsUpdateCheckRunning();
// Id of the check begun last (1, 2, ...), unique for the process. Results are delivered
// to the window attached to that id, whichever kind of check it was.
int64_t CurrentUpdateCheckId();

#ifdef FCU_DEBUG_HOOKS
// Number of checks begun since start (autotest assertions).
int DebugChecksBegun();
#endif

// Whether any row offers something to install: an update or a replacement.
bool HasUpdateAvailable(std::vector<CheckResult> const& results);

// resultsの中にエラー(通信失敗・解析失敗・Remote Registry取得失敗等)が
// 1件でもあるかを返す。自動確認の通知レベル判定に使う。
bool HasAnyError(std::vector<CheckResult> const& results);
