// TEST_DEPS: src/Core/triggers.cpp
#include "TestHarness.h"
#include "../src/Core/triggers.h"

using namespace fcu;

int main() {
    g_context = "menu titles";
    CHECK(isCoreUpdateMenuTitle("Check For New Versions"), "app menu title");
    CHECK(isCoreUpdateMenuTitle("Check for new foobar2000 versions"), "Help menu title");
    CHECK(!isCoreUpdateMenuTitle("Check for Component Updates..."), "our own command");
    CHECK(!isCoreUpdateMenuTitle("Check for New Versions"), "case sensitive");
    CHECK(!isCoreUpdateMenuTitle("Check For New Versions..."), "no ellipsis variant");
    CHECK(!isCoreUpdateMenuTitle(" Check For New Versions"), "no surrounding space");
    CHECK(!isCoreUpdateMenuTitle("Check for new foobar2000 versions "), "no trailing space");
    CHECK(!isCoreUpdateMenuTitle(""), "empty title");

    g_context = "due (counts from the last check of any kind)";
    const int64_t day = 86400, now = 1700000000;
    CHECK(!isAutomaticCheckDue(false, 0, 7, now), "disabled is never due");
    CHECK(!isAutomaticCheckDue(false, now - 30 * day, 7, now), "disabled with an old last run");
    CHECK(isAutomaticCheckDue(true, 0, 7, now), "never ran");
    CHECK(isAutomaticCheckDue(true, -5, 7, now), "negative last run counts as never");
    CHECK(!isAutomaticCheckDue(true, now - 6 * day, 7, now), "6 of 7 days");
    CHECK(!isAutomaticCheckDue(true, now - 7 * day + 1, 7, now), "one second short");
    CHECK(isAutomaticCheckDue(true, now - 7 * day, 7, now), "exactly 7 days");
    CHECK(isAutomaticCheckDue(true, now - 8 * day, 7, now), "8 days");
    CHECK(isAutomaticCheckDue(true, now - 1 * day, 1, now), "1 day interval");
    CHECK(isAutomaticCheckDue(true, now - 30 * day, 30, now), "30 day interval");
    CHECK(!isAutomaticCheckDue(true, now + 100, 7, now), "clock went backwards");
    CHECK(!isAutomaticCheckDue(true, now + 30 * day, 1, now), "last run far in the future");
    CHECK(isAutomaticCheckDue(true, 1, 30, 4000000000LL), "64 bit time past 2038");
    // A manual check yesterday postpones a 7 day automatic check; a 1 day interval is due again.
    CHECK(!isAutomaticCheckDue(true, now - day, 7, now), "manual check yesterday, 7 day interval: not due");
    CHECK(isAutomaticCheckDue(true, now - day, 1, now), "manual check yesterday, 1 day interval: due");
    CHECK(!isAutomaticCheckDue(true, now - 10, 1, now), "a check seconds ago: not due");

    g_context = "interval input";
    CHECK_EQ(parseIntervalInput("12", 7), 12, "plain number");
    CHECK_EQ(parseIntervalInput("  12 ", 7), 12, "surrounding spaces");
    CHECK_EQ(parseIntervalInput("1", 7), 1, "lower bound");
    CHECK_EQ(parseIntervalInput("30", 7), 30, "upper bound");
    CHECK_EQ(parseIntervalInput("0", 7), 1, "0 clamps to 1");
    CHECK_EQ(parseIntervalInput("000", 7), 1, "zeros clamp to 1");
    CHECK_EQ(parseIntervalInput("31", 7), 30, "31 clamps to 30");
    CHECK_EQ(parseIntervalInput("007", 7), 7, "leading zeros");
    CHECK_EQ(parseIntervalInput("99999999999999999999", 7), 30, "overflow clamps to 30");
    CHECK_EQ(parseIntervalInput("", 9), 9, "empty reverts");
    CHECK_EQ(parseIntervalInput("   ", 9), 9, "blank reverts");
    CHECK_EQ(parseIntervalInput("abc", 9), 9, "text reverts");
    CHECK_EQ(parseIntervalInput("7abc", 9), 9, "trailing text reverts");
    CHECK_EQ(parseIntervalInput("1 2", 9), 9, "inner space reverts");
    CHECK_EQ(parseIntervalInput("-3", 9), 9, "sign reverts");
    CHECK_EQ(parseIntervalInput("+3", 9), 9, "plus sign reverts");
    CHECK_EQ(parseIntervalInput("2.5", 9), 9, "decimal reverts");

    TEST_MAIN_END();
}
