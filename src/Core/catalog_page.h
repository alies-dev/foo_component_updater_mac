#pragma once

#include <string>

namespace fcu {

enum class CatalogStatus {
    Ok,
    NotInCatalog, // page says "No such component."
    NoMacSupport, // "Supported systems" does not list macOS
    Malformed,    // structure not as expected: fail closed
};

struct CatalogRelease {
    std::string version;
    std::string downloadPath; // "/getcomponent/<32 hex>/<file>.fb2k-component"
};

// Parses https://www.foobar2000.org/components/view/<name>. Fails closed when
// the version, the macOS support line or exactly one download link is missing.
CatalogStatus parseCatalogPage(std::string const& html, CatalogRelease& out, std::string& error);

} // namespace fcu
