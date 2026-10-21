#include "catalog_page.h"

#include <regex>
#include <set>

namespace fcu {

namespace {

// Removes every `open ... close` block. An unterminated block removes the rest of
// the page, which can only make the parse fail closed.
std::string stripBlocks(std::string html, std::string const& open, std::string const& close) {
    for (size_t from = html.find(open); from != std::string::npos; from = html.find(open, from)) {
        size_t to = html.find(close, from + open.size());
        html.erase(from, to == std::string::npos ? std::string::npos : to + close.size() - from);
    }
    return html;
}

// Distinct values of group 1 over all matches.
std::set<std::string> matches(std::string const& html, std::regex const& pattern) {
    std::set<std::string> found;
    for (auto it = std::sregex_iterator(html.begin(), html.end(), pattern); it != std::sregex_iterator(); ++it) {
        found.insert((*it)[1].str());
    }
    return found;
}

} // namespace

CatalogStatus parseCatalogPage(std::string const& rawHtml, CatalogRelease& out, std::string& error) {
    if (rawHtml.size() > 1024 * 1024) {
        error = "The catalog page is unexpectedly large.";
        return CatalogStatus::Malformed;
    }

    // Authoritative metadata lives in the generated elements only: the description and
    // change log (div.component_info), comments and scripts are removed first.
    std::string html = stripBlocks(rawHtml, "<!--", "-->");
    html = stripBlocks(html, "<script", "</script>");
    html = stripBlocks(html, "<div class=\"component_info\">", "</div>");

    static const std::regex notFoundPattern(R"RX(<p>\s*(No such component\.)\s*</p>)RX");
    if (!matches(html, notFoundPattern).empty()) {
        error = "Not listed in the foobar2000.org component catalog.";
        return CatalogStatus::NotInCatalog;
    }

    static const std::regex versionPattern(R"RX(<h3>\s*Current version:\s*([^,<\s]+)\s*,[^<]*</h3>)RX");
    std::set<std::string> versions = matches(html, versionPattern);
    if (versions.size() != 1) {
        error = versions.empty() ? "Unable to locate the current version on the catalog page (page structure may have changed)."
                                 : "Several current versions on the catalog page.";
        return CatalogStatus::Malformed;
    }

    static const std::regex systemsPattern(R"RX(<p>\s*Supported systems:([^<]*)</p>)RX");
    std::set<std::string> systems = matches(html, systemsPattern);
    if (systems.size() != 1) {
        error = systems.empty() ? "Unable to locate the supported systems on the catalog page (page structure may have changed)."
                                : "Several supported systems lines on the catalog page.";
        return CatalogStatus::Malformed;
    }
    if (systems.begin()->find("macOS") == std::string::npos) {
        error = "The catalog lists no macOS build of this component.";
        return CatalogStatus::NoMacSupport;
    }

    static const std::regex linkPattern(R"RX(href="(/getcomponent/[0-9a-f]{32}/[^"/]+\.fb2k-component)")RX");
    std::set<std::string> links = matches(html, linkPattern);
    if (links.size() != 1) {
        error = links.empty() ? "No download link on the catalog page." : "Several download links on the catalog page.";
        return CatalogStatus::Malformed;
    }

    out.version = *versions.begin();
    out.downloadPath = *links.begin();
    return CatalogStatus::Ok;
}

} // namespace fcu
