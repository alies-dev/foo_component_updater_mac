#include "update_parse.h"

#include <algorithm>
#include <cctype>
#include <regex>
#include <sstream>
#include <vector>

#include "third_party/nlohmann/json.hpp"

namespace {

// DP-0009 / DP-0010: 誤判定するくらいなら「比較不能」を返す。
//
// 対応する形式(SemVer準拠。先頭のv/Vは許容):
//   MAJOR.MINOR.PATCH[.MORE...][-prerelease][+build]
// 例: "4.2.0", "v1.5.2", "1.0.0-beta", "2.0.0-rc.1", "1.2.3+20240101"
//
// - ビルドメタデータ(+以降)は優先順位に影響しないため無視する(SemVer仕様通り)
// - prerelease同士の比較はSemVer 2.0.0の優先順位ルールに従う:
//     * ドット区切りの識別子ごとに比較する
//     * 数字のみの識別子は数値として比較する
//     * 数字のみの識別子は、英数字混在の識別子より必ず「小さい」とみなす
//     * それ以外(英字を含む)は文字コード順(ASCII)で比較する
//     * すべて一致した場合、識別子の数が少ない方を「小さい」とみなす
// - この形式に当てはまらないバージョン文字列は「比較不能」として扱う
struct ParsedVersion {
    std::vector<long long> core;
    std::vector<std::string> prerelease; // 空 = 正式リリース(prereleaseなし)
    bool hasPrerelease = false;
};

bool isValidPrereleaseIdentifier(std::string const& id) {
    if (id.empty()) return false;
    for (char c : id) {
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-')) return false;
    }
    return true;
}

bool isNumericIdentifier(std::string const& id) {
    if (id.empty()) return false;
    for (char c : id) {
        if (!std::isdigit(static_cast<unsigned char>(c))) return false;
    }
    return true;
}

bool tryParseVersion(std::string raw, ParsedVersion& out) {
    std::string s = raw;
    if (!s.empty() && (s[0] == 'v' || s[0] == 'V')) s.erase(0, 1);
    if (s.empty()) return false;

    // ビルドメタデータ(+以降)は優先順位に無関係なので切り落とす
    size_t plusPos = s.find('+');
    if (plusPos != std::string::npos) {
        s = s.substr(0, plusPos);
    }
    if (s.empty()) return false;

    // prerelease(-以降)を切り出す
    std::string corePart = s;
    std::string prereleasePart;
    bool hasPrerelease = false;

    size_t dashPos = s.find('-');
    if (dashPos != std::string::npos) {
        corePart = s.substr(0, dashPos);
        prereleasePart = s.substr(dashPos + 1);
        hasPrerelease = true;
    }

    // コア部分(数字とドットのみ)を解析
    if (corePart.empty()) return false;
    for (char c : corePart) {
        if (!(std::isdigit(static_cast<unsigned char>(c)) || c == '.')) return false;
    }

    std::vector<long long> core;
    {
        std::stringstream ss(corePart);
        std::string token;
        while (std::getline(ss, token, '.')) {
            if (token.empty()) return false;
            try {
                core.push_back(std::stoll(token));
            } catch (...) {
                return false;
            }
        }
    }
    if (core.empty()) return false;

    // prerelease部分(あれば)を解析
    std::vector<std::string> prerelease;
    if (hasPrerelease) {
        if (prereleasePart.empty()) return false; // "1.2.3-" のような不完全な形式は不可

        std::stringstream ss(prereleasePart);
        std::string token;
        while (std::getline(ss, token, '.')) {
            if (!isValidPrereleaseIdentifier(token)) return false;
            prerelease.push_back(token);
        }
        if (prerelease.empty()) return false;
    }

    out.core = std::move(core);
    out.prerelease = std::move(prerelease);
    out.hasPrerelease = hasPrerelease;
    return true;
}

// SemVer 2.0.0の優先順位ルールでprerelease識別子リストを比較する。
// 戻り値: a<b なら負、a>b なら正、等しければ0。
int comparePrereleaseIdentifiers(std::vector<std::string> const& a, std::vector<std::string> const& b) {
    size_t n = (std::min)(a.size(), b.size());

    for (size_t i = 0; i < n; ++i) {
        std::string const& ida = a[i];
        std::string const& idb = b[i];

        bool numA = isNumericIdentifier(ida);
        bool numB = isNumericIdentifier(idb);

        if (numA && numB) {
            long long va, vb;
            try {
                va = std::stoll(ida);
                vb = std::stoll(idb);
            } catch (...) {
                // 極端に長い数字列などで変換に失敗した場合は文字列比較にフォールバック
                if (ida != idb) return ida < idb ? -1 : 1;
                continue;
            }
            if (va != vb) return va < vb ? -1 : 1;
            continue;
        }

        if (numA != numB) {
            // 数字のみの識別子は、英数字混在の識別子より必ず小さい(SemVer仕様)
            return numA ? -1 : 1;
        }

        if (ida != idb) return ida < idb ? -1 : 1;
    }

    if (a.size() != b.size()) return a.size() < b.size() ? -1 : 1;
    return 0;
}

} // namespace

UpdateStatus compareVersions(std::string const& installedRaw, std::string const& latestRaw) {
    ParsedVersion a, b;
    if (!tryParseVersion(installedRaw, a) || !tryParseVersion(latestRaw, b)) {
        return UpdateStatus::ComparisonUnsupported;
    }

    // 1. コア部分(Major.Minor.Patch...)を比較
    size_t n = (std::max)(a.core.size(), b.core.size());
    for (size_t i = 0; i < n; ++i) {
        long long av = i < a.core.size() ? a.core[i] : 0;
        long long bv = i < b.core.size() ? b.core[i] : 0;
        if (av < bv) return UpdateStatus::UpdateAvailable;
        if (av > bv) return UpdateStatus::UpToDate;
    }

    // 2. コアが同じ場合、prereleaseの有無・内容で比較する(SemVer仕様)
    //    正式リリースは、同じコアのどのprereleaseよりも優先順位が高い
    if (!a.hasPrerelease && !b.hasPrerelease) return UpdateStatus::UpToDate;
    if (a.hasPrerelease && !b.hasPrerelease) return UpdateStatus::UpdateAvailable; // 導入版がprerelease、最新は正式版
    if (!a.hasPrerelease && b.hasPrerelease) return UpdateStatus::UpToDate;        // 導入版が既に正式版、最新はprerelease

    int cmp = comparePrereleaseIdentifiers(a.prerelease, b.prerelease);
    if (cmp < 0) return UpdateStatus::UpdateAvailable;
    return UpdateStatus::UpToDate;
}

// ------------------------------------------------------------------
// サイト別のリリース取得。それぞれ「取得できたか」「tag_name/リリースページURL」
// 「(失敗時の)原因別メッセージ」を返す。
//
// 注意: GitLab/CodebergのAPI仕様は、GitHub(実機で動作検証済み)ほど検証が
// できていない。エンドポイントの詳細(特にCodebergの/latestの有無、GitLabの
// permalink/latestの挙動)は実際にビルドして動作確認しながら調整すること。
//
// marc2k3(HTML直書き配布)は正式なAPIが無いサイト固有のパーサーであり、
// ページの構造(Zensicalテーマ)が変わると壊れる前提。DP-0009に従い、
// 想定した構造が見つからない場合は誤判定せず必ずエラーを返す。
// ------------------------------------------------------------------

bool ParseGitLabRelease(
    std::string const& body, std::string const& owner, std::string const& repo,
    FetchedRelease& out, std::string& errorMessage
) {
    try {
        nlohmann::json parsed = nlohmann::json::parse(body.c_str());
        out.tagName = parsed.value("tag_name", "");

        // GitLabのAPIレスポンスにはリリースページの直接URLが含まれていないため、
        // 標準的なURL形式から組み立てる。
        out.releaseUrl = "https://gitlab.com/" + owner + "/" + repo + "/-/releases/" + out.tagName;

        return !out.tagName.empty();
    } catch (std::exception const& e) {
        errorMessage = std::string("Invalid response: ") + e.what();
        return false;
    }
}

bool ParseCodebergRelease(
    std::string const& body,
    FetchedRelease& out, std::string& errorMessage
) {
    try {
        nlohmann::json parsed = nlohmann::json::parse(body.c_str());

        if (!parsed.is_array() || parsed.empty()) {
            errorMessage = "Invalid response: no releases found for this repository.";
            return false;
        }

        nlohmann::json const& latest = parsed[0];
        out.tagName = latest.value("tag_name", "");
        out.releaseUrl = latest.value("html_url", "");
        return !out.tagName.empty();
    } catch (std::exception const& e) {
        errorMessage = std::string("Invalid response: ") + e.what();
        return false;
    }
}

bool ParseMarc2k3Page(
    std::string const& html, std::string const& pageUrl,
    FetchedRelease& out, std::string& errorMessage
) {
    // marc2k3サイト(Zensicalテーマ)のDownloadボタンを特定する。実例:
    //   <a class="md-button md-button--primary" href="../../files/foo_cover_utils-1.7.fb2k-component">
    // href は "../../files/..." のような相対パスのままで、絶対URL化する必要はない
    // (末尾のファイル名からバージョンさえ取れればよく、releaseUrlは登録ページURLを
    //  そのまま使うため)。
    // 注意: このパターンは "([^"]+)" のように )" という並びを含むため、
    // 既定の区切り子 R"( ... )" だと生文字列リテラルが途中で終端してしまう。
    // カスタム区切り子 R"RX( ... )RX" を使って衝突を避ける。
    static const std::regex downloadButtonPattern(
        R"RX(class="md-button md-button--primary"\s+href="([^"]+)")RX"
    );

    std::smatch m;
    if (!std::regex_search(html, m, downloadButtonPattern)) {
        errorMessage = "Unable to locate the download button on this page (page structure may have changed).";
        return false;
    }

    std::string href = m[1].str();

    // ファイル名末尾の "-<version>.fb2k-component" からバージョンを抜き出す。
    static const std::regex versionPattern(
        R"(-([0-9]+(?:\.[0-9]+)*)\.fb2k-component$)"
    );

    std::smatch vm;
    if (!std::regex_search(href, vm, versionPattern)) {
        errorMessage = "Download link found, but its filename didn't match the expected version pattern.";
        return false;
    }

    out.tagName = vm[1].str();  // 例: "1.7"
    out.releaseUrl = pageUrl;   // 専用のリリースページが無いため、登録ページURLをそのまま使う
    return true;
}

// SourceForgeは正式なReleases APIを持たないが、プラットフォーム共通機能として
// 各プロジェクトのファイル配布用RSSフィード(/projects/{project}/rss?path={path})
// を持っている。これはmarc2k3と違いSourceForge全プロジェクトに共通する構造なので、
// プロジェクトごとの特別対応なしに汎用的に扱える。
//
// 登録は「フォルダのファイル一覧ページURL」で行う(例:
// https://sourceforge.net/projects/sacddecoder/files/foo_input_sacd/)。
// フェッチ時にそこからプロジェクト名とフォルダパスを抜き出し、RSS URLを組み立てる。
bool BuildSourceForgeRssUrl(
    std::string const& folderUrl, std::string& rssUrl, std::string& errorMessage
) {
    static const std::regex folderUrlPattern(
        R"RX(sourceforge\.net/projects/([^/]+)/files(/[^?#]*)?)RX"
    );

    std::smatch fm;
    if (!std::regex_search(folderUrl, fm, folderUrlPattern)) {
        errorMessage = "Invalid SourceForge URL: expected a project files page, e.g. https://sourceforge.net/projects/<project>/files/<folder>/";
        return false;
    }

    std::string project = fm[1].str();
    std::string path = fm[2].matched ? fm[2].str() : "";
    // RSSのpathパラメータは末尾スラッシュ無しの形式を使う。空ならルート("/")扱い。
    if (!path.empty() && path.back() == '/') path.pop_back();
    if (path.empty()) path = "/";

    rssUrl = "https://sourceforge.net/projects/" + project + "/rss?path=" + path;
    return true;
}

bool ParseSourceForgeFeed(
    std::string const& xml, std::string const& folderUrl,
    FetchedRelease& out, std::string& errorMessage
) {
    // <item><title><![CDATA[/folder/filename]]></title>...</item> という並びを
    // 日付が新しい順(SourceForgeのRSSはアップロード順)に走査し、バージョン番号+
    // アーカイブ拡張子という形に厳密にマッチする最初のファイルを採用する。
    // これにより readme.txt 等の非パッケージファイルや、"-1.6.x.zip" のような
    // 互換ビルド用サフィックス付きファイル(数字だけで終わらない)は自然に
    // スキップされ、実質「最新の正式リリース」だけが拾われる(DP-0009)。
    static const std::regex itemTitlePattern(
        R"RX(<title><!\[CDATA\[([^\]]+)\]\]></title>)RX"
    );
    static const std::regex fileVersionPattern(
        R"RX(-([0-9]+(?:\.[0-9]+)*)\.(?:zip|rar|7z|fb2k-component)$)RX",
        std::regex::icase
    );

    auto begin = std::sregex_iterator(xml.begin(), xml.end(), itemTitlePattern);
    auto end = std::sregex_iterator();

    for (auto it = begin; it != end; ++it) {
        std::string title = (*it)[1].str();
        std::smatch vm;
        if (std::regex_search(title, vm, fileVersionPattern)) {
            out.tagName = vm[1].str();
            out.releaseUrl = folderUrl; // RSS URLではなく、人が見られるフォルダページを使う
            return true;
        }
    }

    errorMessage = "No release archive with a recognizable version number was found in this SourceForge folder's feed.";
    return false;
}

// foobar.hyv.fi(Case氏の個人配布サイト)は、marc2k3と同じくこのサイト専用の
// パーサー。ただし構造がmarc2k3と異なり、ダウンロードリンクのファイル名には
// バージョンが含まれていない(例: foo_hdcd.fb2k-component)。代わりにページ内の
// 情報テーブルに "Version:" の行が明示的にあるので、そちらから直接読み取る。
// サイト全体で同一テンプレートが使われていることを実サイト2件
// (foo_hdcd, foo_out_digital)で確認済み。
bool ParseHyvPage(
    std::string const& html, std::string const& pageUrl,
    FetchedRelease& out, std::string& errorMessage
) {
    // 実例: <tr><td>Version:</td><td>1.22</td></tr>
    // "Changes" テーブル側にも "1.22 (2025-09-08):" のような紛らわしい文字列が
    // あるが、リテラル "Version:" は情報テーブル側にしか出現しないため、
    // このパターンで確実に区別できる。
    static const std::regex versionRowPattern(
        R"RX(<tr><td>Version:</td><td>([^<]+)</td></tr>)RX"
    );

    std::smatch vm;
    if (!std::regex_search(html, vm, versionRowPattern)) {
        errorMessage = "Unable to locate the Version field on this page (page structure may have changed).";
        return false;
    }

    out.tagName = vm[1].str();
    out.releaseUrl = pageUrl; // 専用のリリースページが無いため、登録ページURLをそのまま使う
    return true;
}
