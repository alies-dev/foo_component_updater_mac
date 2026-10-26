#include "replacement.h"

#include <algorithm>
#include <cctype>
#include <set>

#include "list_entry.h"
#include "mapping_validation.h"
#include "../upstream/third_party/nlohmann/json.hpp"
#include "../upstream/update_parse.h"

namespace fcu {

namespace {

// What foobar2000 accepts as user-components/<name>; nothing that could leave that folder, and not the
// folder foobar2000 stages into.
bool isComponentName(std::string const& s) {
    if (s.empty() || s.size() > 128 || s[0] == '.') return false;
    std::string const n = normalizeComponentName(s);
    if (n == "pending" || n == "core" || n == "foobar2000") return false;
    return std::all_of(s.begin(), s.end(), [](char c) { return isAsciiAlnum(c) || c == '.' || c == '_' || c == '-' || c == '+'; });
}

// Shown to the user by host and opened in the browser on a click: printable ASCII only (no look-alike
// host names), and no user name before the host ("https://github.com@evil.example/").
bool isMigrationUrl(std::string const& url) {
    if (!isHttpsUrl(url) || !std::all_of(url.begin(), url.end(), [](unsigned char c) { return c > 0x20 && c < 0x7f; })) return false;
    std::string const authority = url.substr(8, url.find_first_of("/?#", 8) - 8);
    return authority.find('@') == std::string::npos;
}

bool parseObject(nlohmann::json const& obj, Replacement& out, std::string& error) {
    if (!obj.is_object()) {
        error = "must be a dictionary";
        return false;
    }
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        std::string const& k = it.key();
        if (k != "component" && k != "foobar2000" && k != "migration_url" && k != "team" && k != "source" && k != "owner" && k != "repo" && k != "url") {
            error = "unknown field \"" + k + "\"";
            return false;
        }
    }
    bool const hasComponent = obj.contains("component");
    bool const hasFoobar2000 = obj.contains("foobar2000");
    if (hasComponent && hasFoobar2000) {
        error = "use either \"component\" or \"foobar2000\"";
        return false;
    }
    if (!hasComponent && !hasFoobar2000) {
        error = "\"component\" or \"foobar2000\" is required";
        return false;
    }
    Replacement r;
    nlohmann::json fields = obj;
    if (hasFoobar2000) {
        auto version = obj.find("foobar2000");
        if (!version->is_string() || compareVersions(version->get<std::string>(), version->get<std::string>()) == UpdateStatus::ComparisonUnsupported) {
            error = "\"foobar2000\" must be a version such as 2.27";
            return false;
        }
        if (obj.contains("source") || obj.contains("owner") || obj.contains("repo") || obj.contains("url") || obj.contains("team")) {
            error = "\"foobar2000\" takes no source or team";
            return false;
        }
        r.name = kFoobar2000;
        r.foobar2000 = version->get<std::string>();
        fields.erase("foobar2000");
    } else {
        auto component = obj.find("component");
        if (!component->is_string() || !isComponentName(component->get<std::string>())) {
            error = "\"component\" must name the successor (letters, digits, '.', '_', '-', '+')";
            return false;
        }
        // As declared: it names the package and the folders, which are case sensitive. Only a ".dll" suffix goes.
        r.name = component->get<std::string>();
        if (normalizeComponentName(r.name).size() < r.name.size()) r.name.resize(r.name.size() - 4);
        fields.erase("component");
    }
    if (auto m = fields.find("migration_url"); m != fields.end()) {
        if (!m->is_string() || !isMigrationUrl(m->get<std::string>())) {
            error = "\"migration_url\" must be an https:// URL of printable ASCII without a user name";
            return false;
        }
        r.migration = m->get<std::string>();
        fields.erase("migration_url");
    }
    if (auto t = fields.find("team"); t != fields.end()) {
        std::string const team = t->is_string() ? t->get<std::string>() : "";
        bool const valid = team.size() == 10 && std::all_of(team.begin(), team.end(), [](char c) { return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'); });
        if (!valid) {
            error = "\"team\" must be a Team ID (10 capital letters or digits)";
            return false;
        }
        r.team = team;
        fields.erase("team");
    }
    if (!fields.empty()) {
        if (!parseSourceDictionary(r.name, fields.dump(), r.source, error)) return false;
        r.hasSource = true;
    }
    out = std::move(r);
    return true;
}

} // namespace

bool parseReplacedBy(std::string const& json, Replacement& out, std::string& error) {
    try {
        if (parseObject(nlohmann::json::parse(json), out, error)) return true;
    } catch (std::exception const& e) {
        error = e.what();
    }
    error = "Invalid FB2KReplacedBy: " + error;
    return false;
}

bool foobar2000Includes(std::string const& running, std::string const& declared) {
    return compareVersions(running, declared) == UpdateStatus::UpToDate;
}

void parseBuiltInExtras(std::string const& text, std::map<std::string, Replacement>& replacements,
                        std::vector<ComponentGroup>& groups) {
    replacements.clear();
    groups.clear();
    nlohmann::json parsed;
    try {
        parsed = nlohmann::json::parse(text);
    } catch (std::exception const&) {
        return;
    }
    if (!parsed.is_object()) return;

    auto components = parsed.find("components");
    if (components != parsed.end() && components->is_array()) {
        for (auto const& item : *components) {
            if (!item.is_object() || !item.contains("replaced_by")) continue;
            Replacement r;
            std::string name, error;
            try {
                name = normalizeComponentName(listEntryName(item));
            } catch (std::exception const&) {
                continue;
            }
            if (isComponentName(name) && parseObject(item["replaced_by"], r, error) && normalizeComponentName(r.name) != name) replacements.emplace(name, std::move(r));
        }
    }

    auto list = parsed.find("groups");
    if (list != parsed.end() && list->is_array()) {
        for (auto const& item : *list) {
            if (!item.is_object() || !item.value("title", nlohmann::json()).is_string() || !item.value("members", nlohmann::json()).is_array()) continue;
            ComponentGroup g;
            g.title = item["title"].get<std::string>();
            for (auto const& m : item["members"]) {
                if (m.is_string() && isComponentName(m.get<std::string>())) g.members.push_back(normalizeComponentName(m.get<std::string>()));
            }
            if (!g.title.empty() && g.members.size() >= 2) groups.push_back(std::move(g));
        }
    }
}

ReplacementLookup findReplacement(std::string const& fileName, bool plistPresent, std::string const& plistJson,
                                  std::map<std::string, Replacement> const& builtIn) {
    ReplacementLookup r;
    std::string name = normalizeComponentName(fileName);
    if (name.empty() || fileName == "Core") return r;

    if (plistPresent) {
        Replacement declared;
        std::string error;
        if (!parseReplacedBy(plistJson, declared, error)) {
            r.note = error;
        } else if (normalizeComponentName(declared.name) == name) {
            r.note = "Invalid FB2KReplacedBy: \"component\" names the component itself";
        } else {
            r.origin = ReplacementOrigin::InfoPlist;
            r.replacement = std::move(declared);
            return r;
        }
    }

    auto it = builtIn.find(name);
    if (it != builtIn.end()) {
        r.origin = ReplacementOrigin::BuiltIn;
        r.replacement = it->second;
    }
    return r;
}

std::map<std::string, std::string> overlapNotes(std::vector<std::string> const& installedNames,
                                                std::vector<ComponentGroup> const& groups) {
    std::set<std::string> installed;
    for (auto const& n : installedNames) installed.insert(normalizeComponentName(n));

    std::map<std::string, std::string> notes;
    for (auto const& g : groups) {
        std::vector<std::string> present;
        for (auto const& m : g.members) {
            if (installed.count(m) && std::find(present.begin(), present.end(), m) == present.end()) present.push_back(m);
        }
        if (present.size() < 2) continue;
        for (auto const& m : present) {
            std::string others;
            for (auto const& o : present) {
                if (o != m) others += (others.empty() ? "" : ", ") + o;
            }
            std::string& note = notes[m];
            note += (note.empty() ? "" : " ") + ("Same job as " + others + " (" + g.title + "). Keep only one.");
        }
    }
    return notes;
}

} // namespace fcu
