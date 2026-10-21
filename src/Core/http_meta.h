#pragma once

#include <string>

namespace fcu {

// Response facts the callers need besides the body. Filled by fcu::httpGet
// before it throws on a non 2xx status.
struct HttpMeta {
    int status = 0;
    std::string link;
    std::string retryAfter;
    std::string rateLimitRemaining;
    std::string rateLimitReset;
    std::string errorBody; // first bytes of a non 2xx body, for "secondary rate limit" detection
};

} // namespace fcu
