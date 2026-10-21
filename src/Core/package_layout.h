#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace fcu {

inline constexpr size_t kMaxPackageEntries = 10000;
inline constexpr uint64_t kMaxPackageUncompressedBytes = 512ull * 1024 * 1024;

struct PackageCheck {
    bool ok = false;
    std::string error;                // user readable, set when !ok
    std::vector<std::string> entries; // every name the central directory lists, set when ok
};

// Reads the zip central directory of `zip` (the whole file) and accepts it only when it is
// safe to extract and holds mac/<name>.component with Contents/Info.plist and a file in
// Contents/MacOS. Nothing is decompressed. Entries for other platforms are ignored.
PackageCheck checkPackageLayout(std::string_view zip, std::string const& name);

// Empty when a check result row can be installed, otherwise the reason (row tooltip).
std::string installBlockReason(bool updateAvailable, std::string const& dllName, std::string const& downloadUrl,
                               std::string const& assetName, bool staged);

} // namespace fcu
