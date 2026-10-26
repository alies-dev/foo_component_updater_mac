#pragma once

#include <string>

#include "../upstream/third_party/nlohmann/json.hpp"

namespace fcu {

// The component name of a JSON list entry (shared registry, Resources/extra_components.json): "component",
// or the older "dll" that the registry format started with. Both are read; an entry naming two different
// components is refused (""). A name of another type throws, like nlohmann's value(): the shared registry
// cache is replaced only by a download that reads without errors.
inline std::string listEntryName(nlohmann::json const& item) {
    if (!item.is_object()) return "";
    std::string const component = item.value("component", std::string()), dll = item.value("dll", std::string());
    if (!component.empty() && !dll.empty() && component != dll) return "";
    return component.empty() ? dll : component;
}

} // namespace fcu
