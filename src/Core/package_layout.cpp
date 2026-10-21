#include "package_layout.h"

#include <algorithm>
#include <cctype>

namespace fcu {

namespace {

uint16_t u16(std::string_view s, size_t at) {
    return static_cast<uint16_t>(static_cast<uint8_t>(s[at]) | static_cast<uint8_t>(s[at + 1]) << 8);
}

uint32_t u32(std::string_view s, size_t at) { return u16(s, at) | static_cast<uint32_t>(u16(s, at + 2)) << 16; }

constexpr size_t kEndRecordSize = 22;
constexpr size_t kEntryHeaderSize = 46;

PackageCheck fail(std::string message) {
    PackageCheck c;
    c.error = std::move(message);
    return c;
}

bool startsWith(std::string_view s, std::string_view prefix) { return s.substr(0, prefix.size()) == prefix; }

bool isUnsafeName(std::string_view name) {
    if (name.find('\0') != std::string_view::npos || name.find('\\') != std::string_view::npos) return true;
    if (name.empty() || name.front() == '/') return true;
    for (size_t pos = 0; pos <= name.size();) {
        size_t end = std::min(name.find('/', pos), name.size());
        if (name.substr(pos, end - pos) == "..") return true;
        pos = end + 1;
    }
    return false;
}

std::string printable(std::string_view name) {
    std::string out(name.substr(0, 80));
    for (char& c : out) if (static_cast<unsigned char>(c) < 0x20) c = '?';
    return out;
}

} // namespace

PackageCheck checkPackageLayout(std::string_view zip, std::string const& name) {
    std::string const notZip = "The download is not a valid package (no zip directory found).";

    // The end record sits at the very end, behind an optional comment of up to 64 KB.
    size_t eocd = std::string_view::npos;
    if (zip.size() >= kEndRecordSize) {
        size_t lowest = zip.size() - kEndRecordSize > 0xffff ? zip.size() - kEndRecordSize - 0xffff : 0;
        for (size_t at = zip.size() - kEndRecordSize + 1; at-- > lowest;) {
            if (u32(zip, at) == 0x06054b50 && at + kEndRecordSize + u16(zip, at + 20) == zip.size()) { eocd = at; break; }
        }
    }
    if (eocd == std::string_view::npos) return fail(notZip);

    uint32_t const count = u16(zip, eocd + 10), dirSize = u32(zip, eocd + 12), dirOffset = u32(zip, eocd + 16);
    if (count == 0xffff || dirSize == 0xffffffff || dirOffset == 0xffffffff) {
        return fail("The package uses the zip64 format, which this updater does not support.");
    }
    if (count > kMaxPackageEntries) return fail("The package has more than " + std::to_string(kMaxPackageEntries) + " entries.");
    if (static_cast<uint64_t>(dirOffset) + dirSize > eocd) return fail(notZip);

    std::string_view const dir = zip.substr(dirOffset, dirSize);
    std::string const bundle = "mac/" + name + ".component/Contents/";
    std::string const macosDir = bundle + "MacOS/";
    std::string otherBundle;
    bool hasMac = false, hasPlist = false, hasExecutable = false;
    uint64_t total = 0;

    size_t at = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (at + kEntryHeaderSize > dir.size() || u32(dir, at) != 0x02014b50) return fail(notZip);
        size_t const nameLength = u16(dir, at + 28);
        size_t const next = at + kEntryHeaderSize + nameLength + u16(dir, at + 30) + u16(dir, at + 32);
        if (next > dir.size()) return fail(notZip);
        std::string_view const entry = dir.substr(at + kEntryHeaderSize, nameLength);
        uint32_t const size = u32(dir, at + 24);
        at = next;

        if (size == 0xffffffff) return fail("The package uses the zip64 format, which this updater does not support.");
        total += size;
        if (total > kMaxPackageUncompressedBytes) {
            return fail("The package expands to more than " + std::to_string(kMaxPackageUncompressedBytes >> 20) + " MB.");
        }
        if (isUnsafeName(entry)) return fail("The package contains an unsafe path: " + printable(entry));

        if (startsWith(entry, "mac/")) {
            hasMac = true;
            if (!startsWith(entry, "mac/" + name + ".component/") && otherBundle.empty()) {
                size_t end = entry.find('/', 4);
                if (end != std::string_view::npos && entry.substr(4, end - 4).ends_with(".component")) otherBundle = std::string(entry.substr(0, end));
            }
        }
        if (entry == bundle + "Info.plist") hasPlist = true;
        if (startsWith(entry, macosDir) && entry.size() > macosDir.size() && entry.back() != '/') hasExecutable = true;
    }

    // Entries past the counted ones would still be extracted by ditto, unchecked.
    if (at != dir.size()) return fail(notZip);

    std::string const expected = "mac/" + name + ".component";
    if (!hasMac) return fail("The package has no macOS build (expected " + expected + ").");
    if (!hasPlist && !hasExecutable && !otherBundle.empty()) {
        return fail("The package holds " + otherBundle + " but the installed component is " + expected + ".");
    }
    if (!hasPlist) return fail("The package's " + expected + " has no Contents/Info.plist.");
    if (!hasExecutable) return fail("The package's " + expected + " has no executable in Contents/MacOS.");

    PackageCheck ok;
    ok.ok = true;
    return ok;
}

std::string installBlockReason(bool updateAvailable, std::string const& dllName, std::string const& downloadUrl,
                               std::string const& assetName, bool staged) {
    if (staged) return "Installed, restart foobar2000 to finish";
    if (!updateAvailable) return "No update available";
    if (dllName == "Core") return "Built in components are updated with foobar2000";
    if (dllName == "foo_component_updater_mac") return "Self update arrives in a later version";

    std::string asset = assetName;
    std::transform(asset.begin(), asset.end(), asset.begin(), [](unsigned char c) { return std::tolower(c); });
    if (!startsWith(downloadUrl, "https://") || !asset.ends_with(".fb2k-component")) return "This source offers no package to install";
    return "";
}

} // namespace fcu
