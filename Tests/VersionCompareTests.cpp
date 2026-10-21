// TEST_DEPS: src/upstream/update_parse.cpp
#include "TestHarness.h"
#include "../src/upstream/update_parse.h"

static void expect(char const* installed, char const* latest, UpdateStatus want) {
    std::string what = std::string(installed) + " -> " + latest;
    CHECK(compareVersions(installed, latest) == want, what.c_str());
}

int main() {
    using S = UpdateStatus;

    g_context = "numeric segments";
    expect("1.2.3", "1.2.4", S::UpdateAvailable);
    expect("1.2.4", "1.2.3", S::UpToDate);
    expect("1.2.3", "1.2.3", S::UpToDate);
    expect("1.9.9", "1.10.0", S::UpdateAvailable);
    expect("1.10.0", "1.9.9", S::UpToDate);
    expect("0.3.0", "1.0.0", S::UpdateAvailable);
    expect("2", "10", S::UpdateAvailable);

    g_context = "padding";
    expect("1.0", "1.0.0", S::UpToDate);
    expect("1.0.0", "1.0", S::UpToDate);
    expect("1.0", "1.0.1", S::UpdateAvailable);
    expect("1.0.1", "1.0", S::UpToDate);
    expect("1.2.3.4", "1.2.3.5", S::UpdateAvailable);

    g_context = "leading v";
    expect("v1.0.0", "1.0.1", S::UpdateAvailable);
    expect("V1.0.0", "v1.0.0", S::UpToDate);
    expect("1.0.0", "v1.0.0", S::UpToDate);

    g_context = "prerelease against release";
    expect("1.0.0-beta", "1.0.0", S::UpdateAvailable);
    expect("1.0.0", "1.0.0-beta", S::UpToDate);
    expect("1.0.0-rc.1", "1.0.1", S::UpdateAvailable);
    expect("1.1.0-alpha", "1.0.9", S::UpToDate);

    g_context = "prerelease ordering";
    expect("1.0.0-alpha", "1.0.0-beta", S::UpdateAvailable);
    expect("1.0.0-beta", "1.0.0-alpha", S::UpToDate);
    expect("1.0.0-rc.1", "1.0.0-rc.2", S::UpdateAvailable);
    expect("1.0.0-rc.2", "1.0.0-rc.10", S::UpdateAvailable);
    expect("1.0.0-rc.10", "1.0.0-rc.2", S::UpToDate);
    expect("1.0.0-1", "1.0.0-alpha", S::UpdateAvailable);
    expect("1.0.0-alpha", "1.0.0-1", S::UpToDate);
    expect("1.0.0-alpha", "1.0.0-alpha.1", S::UpdateAvailable);
    expect("1.0.0-alpha.1", "1.0.0-alpha", S::UpToDate);
    expect("1.0.0-alpha.1", "1.0.0-alpha.1", S::UpToDate);

    g_context = "build metadata";
    expect("1.0.0+5", "1.0.0+9", S::UpToDate);
    expect("1.0.0+9", "1.0.1", S::UpdateAvailable);
    expect("1.0.0-beta+1", "1.0.0-beta+2", S::UpToDate);

    g_context = "upstream quirk";
    // getline drops the empty token after a trailing dot, so "1.2." reads as 1.2.
    expect("1.2.", "1.2.3", S::UpdateAvailable);

    g_context = "unable to compare";
    expect("", "1.0.0", S::ComparisonUnsupported);
    expect("1.0.0", "", S::ComparisonUnsupported);
    expect("v", "1.0.0", S::ComparisonUnsupported);
    expect("abc", "1.0.0", S::ComparisonUnsupported);
    expect("1.0.0", "abc", S::ComparisonUnsupported);
    expect("1..2", "1.0.0", S::ComparisonUnsupported);
    expect(".1", "1.2.3", S::ComparisonUnsupported);
    expect("1.2.x", "1.2.3", S::ComparisonUnsupported);
    expect("1.2.3-", "1.2.3", S::ComparisonUnsupported);
    expect("1.2.3-a..b", "1.2.3", S::ComparisonUnsupported);
    expect("1.2.3-a b", "1.2.3", S::ComparisonUnsupported);
    expect("1.0 beta", "1.0", S::ComparisonUnsupported);
    expect("+5", "1.0", S::ComparisonUnsupported);
    expect("99999999999999999999", "1", S::ComparisonUnsupported);
    expect("1.0.0", "1.0.0 ", S::ComparisonUnsupported);

    TEST_MAIN_END();
}
