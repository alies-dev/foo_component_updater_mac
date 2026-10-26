#pragma once

#include <map>
#include <string>
#include <vector>

namespace fcu {

// Text of Resources/<name>.<ext> inside this component's bundle, "" when missing.
std::string bundledResource(char const* name, char const* ext);

// The dictionaries `keys` of <user-components>/<fileName>/<fileName>.component/Contents/Info.plist
// as JSON, by key; absent keys (or bundle) are missing from the result. A value that is
// not a dictionary yields "null" so the strict parsers report it.
std::map<std::string, std::string> readBundleDictionaries(std::string const& fileName, std::vector<char const *> const& keys);

} // namespace fcu
