#pragma once

#include <string>

namespace fcu {

// Text of Resources/<name>.<ext> inside this component's bundle, "" when missing.
std::string bundledResource(char const* name, char const* ext);

// The FB2KUpdateSource value of <user-components>/<fileName>/<fileName>.component/Contents/Info.plist
// as JSON. Returns false when the bundle or the key is absent; a value that is
// not a dictionary yields "null" so the strict parser reports it.
bool readBundleUpdateSource(std::string const& fileName, std::string& json);

} // namespace fcu
