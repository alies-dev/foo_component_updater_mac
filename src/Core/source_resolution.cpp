#include "source_resolution.h"

#include "mapping_validation.h"
#include "../upstream/third_party/nlohmann/json.hpp"

namespace fcu {

namespace {

bool find(std::vector<RepositoryMappingEntry> const& entries, std::string const& name, RepositoryMappingEntry& out) {
    for (auto const& e : entries) {
        if (!isSupportedSource(e.source)) continue; // unknown future sources are skipped, as upstream does
        if (normalizeComponentName(e.dllName) == name) {
            out = e;
            return true;
        }
    }
    return false;
}

} // namespace

char const* originLabel(SourceOrigin origin) {
    switch (origin) {
    case SourceOrigin::User: return "user";
    case SourceOrigin::InfoPlist: return "Info.plist";
    case SourceOrigin::Registry: return "registry";
    case SourceOrigin::BuiltIn: return "built in list";
    case SourceOrigin::Catalog: return "catalog";
    case SourceOrigin::None: break;
    }
    return "";
}

bool parseRegistryJson(std::string const& text, std::vector<RepositoryMappingEntry>& out) {
    out.clear();
    try {
        nlohmann::json parsed = nlohmann::json::parse(text);
        if (!parsed.is_object() || !parsed.contains("components") || !parsed["components"].is_array()) return false;
        for (auto const& item : parsed["components"]) {
            RepositoryMappingEntry e;
            e.dllName = item.value("dll", "");
            e.source = item.value("source", "");
            e.owner = item.value("owner", "");
            e.repo = item.value("repo", "");
            e.url = item.value("url", "");
            if (!e.dllName.empty() && !e.source.empty()) out.push_back(std::move(e));
        }
        return true;
    } catch (std::exception const&) {
        out.clear();
        return false;
    }
}

namespace {

// Every list entry is checked before a URL is built from it, whatever list it came from.
void finish(ResolvedSource& r, SourceOrigin origin) {
    r.origin = origin;
    validateSourceFields(r.entry, r.invalid);
}

} // namespace

ResolvedSource resolveSource(std::string const& fileName, BundleSource const& bundle, SourceLists const& lists) {
    ResolvedSource r;
    std::string name = normalizeComponentName(fileName);
    if (name.empty() || fileName == "Core") return r;

    if (find(lists.user, name, r.entry)) {
        finish(r, SourceOrigin::User);
        return r;
    }

    if (bundle.present) {
        std::string error;
        if (parseBundleSource(name, bundle.json, r.entry, error)) {
            r.origin = SourceOrigin::InfoPlist;
            return r;
        }
        r.note = error;
    }

    if (find(lists.registry, name, r.entry)) {
        finish(r, SourceOrigin::Registry);
        return r;
    }
    if (find(lists.builtIn, name, r.entry)) {
        finish(r, SourceOrigin::BuiltIn);
        return r;
    }

    r.entry = RepositoryMappingEntry{};
    r.entry.dllName = name;
    r.entry.source = "catalog";
    r.origin = SourceOrigin::Catalog;
    return r;
}

} // namespace fcu
