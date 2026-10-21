#include "mapping_validation.h"

#include <algorithm>
#include <cctype>
#include <set>

#include "../upstream/third_party/nlohmann/json.hpp"

namespace fcu {

namespace {

bool isIdentifier(std::string const& s, bool allowPlus) {
    if (s.empty() || s.size() > 128) return false;
    for (char c : s) {
        unsigned char u = static_cast<unsigned char>(c);
        if (!(std::isalnum(u) || c == '.' || c == '_' || c == '-' || (allowPlus && c == '+'))) return false;
    }
    return true;
}

bool isUrlSource(std::string const& source) {
    return source == "marc2k3" || source == "sourceforge" || source == "hyv";
}

bool isHttpsUrl(std::string const& url) {
    static const std::string prefix = "https://";
    if (url.size() <= prefix.size() + 1 || url.size() > 2048 || url.rfind(prefix, 0) != 0) return false;
    return std::none_of(url.begin(), url.end(), [](unsigned char c) { return c <= 0x20 || c == 0x7f; })
        && url[prefix.size()] != '/';
}

bool readString(nlohmann::json const& obj, char const* key, std::string& out, std::string& error) {
    auto it = obj.find(key);
    if (it == obj.end()) return true;
    if (!it->is_string()) {
        error = std::string("\"") + key + "\" must be a string";
        return false;
    }
    out = it->get<std::string>();
    return true;
}

// `fields` is the allowed key set; dllName already filled for bundle sources.
bool parseEntry(nlohmann::json const& obj, bool userEntry, RepositoryMappingEntry& e, std::string& error) {
    if (!obj.is_object()) {
        error = "must be an object";
        return false;
    }
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        std::string const& k = it.key();
        if (k != "source" && k != "owner" && k != "repo" && k != "url" && !(userEntry && k == "dll")) {
            error = "unknown field \"" + k + "\"";
            return false;
        }
    }

    std::string dll = e.dllName, source;
    if (userEntry && !readString(obj, "dll", dll, error)) return false;
    if (!readString(obj, "source", source, error) || !readString(obj, "owner", e.owner, error)
        || !readString(obj, "repo", e.repo, error) || !readString(obj, "url", e.url, error)) {
        return false;
    }

    if (userEntry) {
        e.dllName = normalizeComponentName(dll);
        if (e.dllName.empty()) {
            error = "\"dll\" is required";
            return false;
        }
        if (e.dllName[0] == '.' || e.dllName.find("..") != std::string::npos || !isIdentifier(e.dllName, true)) {
            error = "\"dll\" may only contain letters, digits, '.', '_', '-' and '+'";
            return false;
        }
        if (source.empty() && !obj.contains("source")) source = "github";
    } else if (source.empty()) {
        error = "\"source\" is required";
        return false;
    }

    e.source = source;

    return validateSourceFields(e, error);
}

} // namespace

bool validateSourceFields(RepositoryMappingEntry const& e, std::string& error) {
    if (!isSupportedSource(e.source)) {
        error = "unsupported source \"" + e.source + "\" (use github, gitlab, codeberg, marc2k3, sourceforge or hyv)";
        return false;
    }
    // Mixed fields are rejected so what is displayed is exactly what is requested.
    if (isUrlSource(e.source) ? (!e.owner.empty() || !e.repo.empty()) : !e.url.empty()) {
        error = isUrlSource(e.source) ? "source \"" + e.source + "\" takes \"url\", not \"owner\" and \"repo\""
                                      : "source \"" + e.source + "\" takes \"owner\" and \"repo\", not \"url\"";
        return false;
    }
    if (isUrlSource(e.source)) {
        if (!isHttpsUrl(e.url)) {
            error = "\"url\" must be an https:// URL for source \"" + e.source + "\"";
            return false;
        }
    } else if (!isIdentifier(e.owner, false) || !isIdentifier(e.repo, false)) {
        error = "\"owner\" and \"repo\" are required for source \"" + e.source + "\" (letters, digits, '.', '_', '-')";
        return false;
    }
    return true;
}

std::string normalizeComponentName(std::string name) {
    std::transform(name.begin(), name.end(), name.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (name.size() >= 4 && name.compare(name.size() - 4, 4, ".dll") == 0) name.resize(name.size() - 4);
    return name;
}

bool isSupportedSource(std::string const& s) {
    return s == "github" || s == "gitlab" || s == "codeberg" || isUrlSource(s);
}

bool parseUserMappings(std::string const& text, std::vector<RepositoryMappingEntry>& out, std::string& error) {
    if (text.find_first_not_of(" \t\r\n") == std::string::npos) {
        out.clear();
        return true;
    }

    nlohmann::json parsed;
    try {
        parsed = nlohmann::json::parse(text);
    } catch (std::exception const& e) {
        error = std::string("Invalid JSON: ") + e.what();
        return false;
    }
    if (!parsed.is_array()) {
        error = "Expected a JSON array of objects, e.g. [{\"dll\": \"foo_x\", \"source\": \"github\", \"owner\": \"me\", \"repo\": \"foo_x\"}]";
        return false;
    }

    std::vector<RepositoryMappingEntry> entries;
    std::set<std::string> seen;
    int index = 0;
    for (auto const& item : parsed) {
        ++index;
        RepositoryMappingEntry e;
        std::string entryError;
        if (!parseEntry(item, true, e, entryError)) {
            error = "Entry " + std::to_string(index) + ": " + entryError;
            return false;
        }
        if (!seen.insert(e.dllName).second) {
            error = "Entry " + std::to_string(index) + ": duplicate component \"" + e.dllName + "\"";
            return false;
        }
        entries.push_back(std::move(e));
    }
    out = std::move(entries);
    return true;
}

std::string formatUserMappings(std::vector<RepositoryMappingEntry> const& entries) {
    nlohmann::json arr = nlohmann::json::array();
    for (auto const& e : entries) {
        nlohmann::json item;
        item["dll"] = e.dllName;
        item["source"] = e.source.empty() ? "github" : e.source;
        if (!e.owner.empty()) item["owner"] = e.owner;
        if (!e.repo.empty()) item["repo"] = e.repo;
        if (!e.url.empty()) item["url"] = e.url;
        arr.push_back(std::move(item));
    }
    return arr.dump(2);
}

bool parseBundleSource(std::string const& dllName, std::string const& json,
                       RepositoryMappingEntry& out, std::string& error) {
    nlohmann::json parsed;
    try {
        parsed = nlohmann::json::parse(json);
    } catch (std::exception const& e) {
        error = std::string("Invalid FB2KUpdateSource: ") + e.what();
        return false;
    }
    RepositoryMappingEntry e;
    e.dllName = normalizeComponentName(dllName);
    std::string entryError;
    if (!parseEntry(parsed, false, e, entryError)) {
        error = "Invalid FB2KUpdateSource: " + entryError;
        return false;
    }
    out = std::move(e);
    return true;
}

} // namespace fcu
