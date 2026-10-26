#include "replacement.h"

#include <algorithm>
#include <cctype>
#include <set>

#include "mapping_validation.h"
#include "../upstream/third_party/nlohmann/json.hpp"

namespace fcu {

namespace {

// What foobar2000 accepts as user-components/<name>; nothing that could leave that folder.
bool isComponentName(std::string const& s) {
    if (s.empty() || s.size() > 128 || s[0] == '.') return false;
    return std::all_of(s.begin(), s.end(), [](unsigned char c) { return std::isalnum(c) || c == '.' || c == '_' || c == '-' || c == '+'; });
}

bool parseObject(nlohmann::json const& obj, Replacement& out, std::string& error) {
    if (!obj.is_object()) {
        error = "must be a dictionary";
        return false;
    }
    for (auto it = obj.begin(); it != obj.end(); ++it) {
        std::string const& k = it.key();
        if (k != "dll" && k != "source" && k != "owner" && k != "repo" && k != "url") {
            error = "unknown field \"" + k + "\"";
            return false;
        }
    }
    auto dll = obj.find("dll");
    if (dll == obj.end() || !dll->is_string() || !isComponentName(dll->get<std::string>())) {
        error = "\"dll\" must name the replacing component (letters, digits, '.', '_', '-', '+')";
        return false;
    }
    Replacement r;
    r.dllName = normalizeComponentName(dll->get<std::string>());
    if (obj.size() > 1) {
        nlohmann::json fields = obj;
        fields.erase("dll");
        if (!parseSourceDictionary(r.dllName, fields.dump(), r.source, error)) return false;
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
            if (!item.is_object() || !item.contains("replaced_by") || !item.value("dll", nlohmann::json()).is_string()) continue;
            std::string name = normalizeComponentName(item["dll"].get<std::string>());
            Replacement r;
            std::string error;
            if (isComponentName(name) && parseObject(item["replaced_by"], r, error) && r.dllName != name) replacements.emplace(name, std::move(r));
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
        } else if (declared.dllName == name) {
            r.note = "Invalid FB2KReplacedBy: \"dll\" names the component itself";
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
