#pragma once

#include <string>

#include "../upstream/third_party/nlohmann/json.hpp"

namespace fcu {

// The component name of a JSON list entry (shared registry, Resources/extra_components.json): "component",
// or the older "dll" that the registry format started with. Both are read; an entry naming two different
// components is refused. Returns "" when there is no usable name.
inline std::string listEntryName(nlohmann::json const& item) {
    if (!item.is_object()) return "";
    auto read = [&](char const* key) {
        auto it = item.find(key);
        return it != item.end() && it->is_string() ? it->get<std::string>() : std::string();
    };
    std::string const component = read("component"), dll = read("dll");
    if (!component.empty() && !dll.empty() && component != dll) return "";
    return component.empty() ? dll : component;
}

} // namespace fcu
