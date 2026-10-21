#include "triggers.h"

namespace fcu {

bool isAutomaticCheckDue(bool enabled, int64_t lastCheck, int intervalDays, int64_t now) {
    if (!enabled) return false;
    if (lastCheck <= 0) return true;
    int64_t intervalSeconds = static_cast<int64_t>(intervalDays) * 24 * 60 * 60;
    return now >= lastCheck && now - lastCheck >= intervalSeconds;
}

int parseIntervalInput(std::string const& text, int current) {
    size_t begin = text.find_first_not_of(" \t\r\n");
    if (begin == std::string::npos) return current;
    size_t end = text.find_last_not_of(" \t\r\n");
    int64_t value = 0;
    for (size_t i = begin; i <= end; ++i) {
        if (text[i] < '0' || text[i] > '9') return current;
        if (value < 1000) value = value * 10 + (text[i] - '0');
    }
    return value < 1 ? 1 : value > 30 ? 30 : static_cast<int>(value);
}

} // namespace fcu
