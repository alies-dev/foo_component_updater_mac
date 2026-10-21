#pragma once

#include <fstream>
#include <sstream>
#include <string>

// Reads Tests/fixtures/<name>; the path is derived from this header so the
// tests run from any working directory.
inline std::string fixture(char const* name) {
    std::string here = __FILE__;
    std::ifstream in(here.substr(0, here.rfind('/')) + "/fixtures/" + name, std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    return ss.str();
}
