#include "mapping_validation.h"

#include <algorithm>
#include <cctype>

#include "../upstream/third_party/nlohmann/json.hpp"

namespace fcu {

namespace {

bool isIdentifier(std::string const& s) {
    if (s.empty() || s.size() > 128) return false;
    return std::all_of(s.begin(), s.end(), [](char c) { return isAsciiAlnum(c) || c == '.' || c == '_' || c == '-'; });
}

bool isUrlSource(std::string const& source) {
    return source == "marc2k3" || source == "sourceforge" || source == "hyv";
}

} // namespace

bool isAsciiAlnum(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}

bool isHttpsUrl(std::string const& url) {
    static const std::string prefix = "https://";
    if (url.size() <= prefix.size() + 1 || url.size() > 2048 || url.rfind(prefix, 0) != 0) return false;
    return std::none_of(url.begin(), url.end(), [](unsigned char c) { return c <= 0x20 || c == 0x7f; })
        && url[prefix.size()] != '/';
}

namespace {

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

// Fields of an FB2KUpdateSource dictionary; e.dllName is already filled.
bool parseEntry(nlohmann::json const& obj, RepositoryMappingEntry& e, std::string& error) {
    if (!obj.is_object()) {
        error = "must be an object";
        return false;
    }
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        std::string const& k = it.key();
        if (k != "source" && k != "owner" && k != "repo" && k != "url") {
            error = "unknown field \"" + k + "\"";
            return false;
        }
    }

    std::string source;
    if (!readString(obj, "source", source, error) || !readString(obj, "owner", e.owner, error)
        || !readString(obj, "repo", e.repo, error) || !readString(obj, "url", e.url, error)) {
        return false;
    }
    if (source.empty()) {
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
    } else if (!isIdentifier(e.owner) || !isIdentifier(e.repo)) {
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

bool parseSourceDictionary(std::string const& dllName, std::string const& json,
                           RepositoryMappingEntry& out, std::string& error) {
    nlohmann::json parsed;
    try {
        parsed = nlohmann::json::parse(json);
    } catch (std::exception const& e) {
        error = e.what();
        return false;
    }
    RepositoryMappingEntry e;
    e.dllName = normalizeComponentName(dllName);
    if (!parseEntry(parsed, e, error)) return false;
    out = std::move(e);
    return true;
}

bool parseBundleSource(std::string const& dllName, std::string const& json,
                       RepositoryMappingEntry& out, std::string& error) {
    if (parseSourceDictionary(dllName, json, out, error)) return true;
    error = "Invalid FB2KUpdateSource: " + error;
    return false;
}

} // namespace fcu
