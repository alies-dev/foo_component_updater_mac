#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "../fb2k_sdk.h"
#include "../Core/http_meta.h"
#include "../version.h"

namespace fcu {

using HttpHeaders = std::vector<std::pair<std::string, std::string>>;

// "foo_component_updater_mac/<version>"
std::string userAgent();

// HTTPS only, on the first request and on every redirect hop; certificate
// validation stays on. Polls `abort` every 100 ms and cancels the request.
// Throws std::runtime_error on a transport failure, a refused redirect or a
// non 2xx status; `meta`, when given, is filled before the throw.
std::string httpGet(std::string const& url, HttpHeaders const& headers, abort_callback& abort,
                    HttpMeta* meta = nullptr);

// Same rules; streams to destPath and fails once more than maxBytes arrive.
void httpDownload(std::string const& url, std::string const& destPath, uint64_t maxBytes,
                  abort_callback& abort);

// Debug builds with the foo_component_updater_mac.debug.api_base config key set
// (an https://127.0.0.1:PORT stub) return base + stubPath. Everything else
// returns `normal`.
std::string endpoint(std::string const& normal, std::string const& stubPath);

#ifdef FCU_DEBUG_HOOKS
// Every URL requested through httpGet since start, for the autotest log.
std::vector<std::string> requestLog();
#endif

} // namespace fcu
