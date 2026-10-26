#!/bin/bash
#
# test_batch.sh - Run one milestone's test batch in the real foobar2000
#
# Usage:
#   ./Scripts/test_batch.sh m1          all runs
#   ./Scripts/test_batch.sh m1 real     only the real GitHub run (to compare request counts)
#   ./Scripts/test_batch.sh m2          install, Restore Previous and restart, in the real foobar2000
#
# M1 runs six headless starts of foobar2000 against the Debug build, driven by the
# foo_component_updater_mac.debug.autotest hook (no UI, no keystrokes, no clicks):
#   real       real GitHub API: the 5 installed JendaT components, exactly 1 API request
#   stub       local HTTPS stub: persisted settings, catalog source (older foo_abx)
#   down       stub not listening: network errors, no crash
#   ratelimit  stub answers 403 with x-ratelimit headers: message, no further API calls
#   badregistry registry entries that must never reach a URL
#   triggers   Help > Check for Third-Party Component Updates... and the periodic evaluation (counted checks), and that foobar2000's own update menu titles start none
#
# M2 runs the install scenarios in the real foobar2000 (the chains are linked by main_restart() calls of the component itself):
#   m2-install   the check finds the older foo_abx, the install stages the catalog package, the process restarts
#   m2-restore   the new version runs (Components list, mapped binary); Restore Previous stages the backup; restart
#   m2-refuse    the old version runs again, the backup holds the new one; nine bad packages are refused
#   m2-bomb      two packages whose declared sizes pass but which hold 3000 MB (plain, and as an AppleDouble resource fork): ditto is killed, nothing is staged
#   m2-self-*    the component installs its own update (9.9.9), restarts into it, restores its own backup and restarts again
#   m2-team      a Developer ID bundle is installed: another developer's package is refused, the same Team ID is staged, and a
#                switch to an ad hoc successor is refused (no declared Team ID: the old one's applies)
#   m2-switch    foo_abx declares FB2KReplacedBy foo_abx_ng: a kept row is checked as usual, the switch stages foo_abx_ng and
#                removes foo_abx; after the restart only foo_abx_ng is installed and its migration notes are offered once
#   m2-core      foo_abx declares FB2KReplacedBy foobar2000 2.0: the row is Replaced (not for a pretend older foobar2000), Install stages only
#                the removal; after the restart foo_abx is gone and its migration notes are offered once
#
# Known profile: whatever the user has installed or toggled, the batch runs against the same one. Right after the backup
# every user component except the updater is removed and JendaT's five (foo_jl_spectrum 0.3.0, the other four in their newest
# GitHub release) are installed from JendaT's GitHub releases; our own settings rows (and the debug keys) are deleted so every
# setting is at its default. The versions picked go to $WORK/known-profile.json for the checker. The exit restores the profile.
#
# Rules (hard): ~/Library/foobar2000-v2 is backed up first and restored afterwards
# (verified with diff -rq); foobar2000 is started only with `open -g -a foobar2000`,
# never activated, and quit with osascript.
#
# Environment: FB2K_SDK_PATH (SDK location), FOO_ABX_PACKAGE (a local copy of the foo_abx package
# from the catalog, used instead of downloading it), JENDA_PACKAGES (a folder with the five JendaT
# <component>.fb2k-component files, used instead of downloading them; versions are read from the bundles,
# foo_jl_spectrum must be 0.3.0), PROOF_OUT (where to copy the proof log, default build/<batch>-proof.md).

set -uo pipefail

BATCH="${1:-}"
ONLY="${2:-}"
if [ "$BATCH" != "m1" ] && [ "$BATCH" != "m2" ]; then
    echo "Usage: $0 m1|m2" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="$HOME/Library/foobar2000-v2"
COMPONENT_DIR="$PROFILE/user-components/foo_component_updater_mac"
CONFIG_DB="$PROFILE/config.sqlite"
FIXTURES="$PROJECT_DIR/Tests/fixtures"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/fb2k-backup-fcu-$BATCH-$STAMP"
# App level state (window frames and so on) lives in the defaults domain, outside the profile.
DEFAULTS_DOMAIN=com.foobar2000.mac
DEFAULTS_BACKUP="$HOME/fb2k-backup-fcu-$BATCH-$STAMP.defaults.plist"
DEFAULTS_SAVED=0
WORK="$(mktemp -d /tmp/fcu-batch.XXXXXX)"
PROOF="$WORK/proof.md"
PROOF_OUT="${PROOF_OUT:-$PROJECT_DIR/build/$BATCH-proof.md}"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
FAILURES=0
BATCH_PID=""   # pid of the foobar2000 this batch started; only that one is ever quit
BACKUP_DONE=0
STUB_PID=""

say() { echo "$*" | tee -a "$PROOF"; }
section() { printf '\n## %s\n\n' "$*" >> "$PROOF"; echo "==> $*"; }
fence() { { echo '```'; cat; echo '```'; } >> "$PROOF"; }
fail() { say "FAIL $*"; FAILURES=$((FAILURES + 1)); }

fb2k_pid() { pgrep -x foobar2000 | head -1; }

# Starts foobar2000 in the background and sets BATCH_PID. Right after a quit LaunchServices can still hold the old
# instance and drop the open (error -600, no process), so the open is repeated until a process appears.
launch_fb2k() {
    BATCH_PID=""
    for _ in 1 2 3; do
        open -g -a foobar2000 2>/dev/null
        for _ in $(seq 1 40); do BATCH_PID="$(fb2k_pid)"; [ -n "$BATCH_PID" ] && return 0; sleep 0.25; done
    done
    return 1
}

# Quits only the foobar2000 this batch started. Any other instance (the owner may be
# listening to music) is never quit: this returns 1 and the caller stops.
quit_fb2k() {
    local pid; pid="$(fb2k_pid)"
    [ -n "$pid" ] || return 0
    [ -n "$BATCH_PID" ] && [ "$pid" = "$BATCH_PID" ] || return 1
    osascript -e 'tell application "foobar2000" to quit' >/dev/null 2>&1
    for _ in $(seq 1 60); do
        [ -z "$(fb2k_pid)" ] && return 0
        sleep 0.5
    done
    return 1
}

# Every quit that matters: when foobar2000 does not go away nothing else may touch the profile. The exit runs the
# cleanup, which sees the same failure, keeps the backup and does not restore over a running application.
quit_or_stop() {
    quit_fb2k || { fail "$1: foobar2000 did not quit; stopping before anything else changes the profile"; exit 3; }
}

stop_stub() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null && wait "$STUB_PID" 2>/dev/null
    STUB_PID=""
}

restore_profile() {
    stop_stub
    if ! quit_fb2k; then
        echo "foobar2000 did not quit; profile NOT restored. Backup: $BACKUP" >&2
        return
    fi
    if [ "$BACKUP_DONE" = 1 ]; then
        section "Profile restore"
        diff -rq "$BACKUP" "$PROFILE" > "$WORK/changed-before-restore.txt" 2>&1
        say "Files that differ between the backup and the profile before the restore (expected: config.sqlite, our component, foo_abx, foobar2000's own state):"
        fence < "$WORK/changed-before-restore.txt"
        rm -rf "$PROFILE"
        ditto "$BACKUP" "$PROFILE"
        if diff -rq "$BACKUP" "$PROFILE" > "$WORK/restore-diff.txt" 2>&1; then
            say "PASS restore: diff -rq \"$BACKUP\" \"$PROFILE\" is empty"
        else
            fail "restore: diff -rq reports differences"
            fence < "$WORK/restore-diff.txt"
        fi
    fi
    if [ "$DEFAULTS_SAVED" = 1 ]; then
        # foobar2000 is not running here (quit_fb2k above), so the import cannot be overwritten.
        defaults export "$DEFAULTS_DOMAIN" "$WORK/defaults-before-restore.plist" 2>/dev/null
        defaults import "$DEFAULTS_DOMAIN" "$DEFAULTS_BACKUP"
        defaults export "$DEFAULTS_DOMAIN" "$WORK/defaults-after-restore.plist"
        # Compare the content (plutil -p sorts the keys): the binary files differ byte for byte between exports.
        if diff <(plutil -p "$DEFAULTS_BACKUP") <(plutil -p "$WORK/defaults-after-restore.plist") > "$WORK/defaults-diff.txt" 2>&1; then
            say "PASS restore: defaults export of $DEFAULTS_DOMAIN after the restore equals the one before the batch (diff empty)"
        else
            fail "restore: defaults of $DEFAULTS_DOMAIN differ from before the batch"
            fence < "$WORK/defaults-diff.txt"
        fi
        if diff <(plutil -p "$DEFAULTS_BACKUP") <(plutil -p "$WORK/defaults-before-restore.plist") >/dev/null 2>&1; then
            say "INFO app defaults were not changed by the batch"
        else
            say "INFO app defaults had changed during the batch and were restored"
        fi
    fi
}

finish() {
    local code=$?
    restore_profile
    mkdir -p "$(dirname "$PROOF_OUT")"
    cp "$PROOF" "$PROOF_OUT"
    echo "Proof log: $PROOF_OUT"
    if [ "$FAILURES" -ne 0 ] || [ "$code" -ne 0 ]; then
        echo "BATCH $BATCH FAILED ($FAILURES failed checks, exit $code)"
        exit 1
    fi
    echo "BATCH $BATCH PASSED"
}
trap finish EXIT

cfg_set_string() { sqlite3 "$CONFIG_DB" "INSERT OR REPLACE INTO configStrings(name, value) VALUES('$1', '$2');"; }
cfg_delete_string() { sqlite3 "$CONFIG_DB" "DELETE FROM configStrings WHERE name = '$1';"; }

# start_run <name> <stub-log-or-empty>: starts foobar2000 in the background, waits for the autotest log.
start_run() {
    local name="$1" log="$WORK/autotest-$1.json"
    rm -f "$log"
    # `open` attaches to a running foobar2000 and that instance never reads the autotest key.
    # One started by someone else between quit and start would make this run silently wait and
    # its own checks count as ours, so refuse to go on.
    if [ -n "$(fb2k_pid)" ]; then
        fail "$name: foobar2000 (pid $(fb2k_pid)) is already running and was not started by this batch; it is left alone"
        # Abort the whole batch: the exit trap restores the profile and no run may start foobar2000 again.
        exit 3
    fi
    cfg_set_string foo_component_updater_mac.debug.autotest "$log"
    launch_fb2k
    for _ in $(seq 1 240); do
        [ -s "$log" ] && break
        sleep 0.5
    done
    if [ ! -s "$log" ]; then
        fail "$name: no autotest log after 120 s"
        quit_or_stop "$name"
        return 1
    fi
    local pid; pid="$(fb2k_pid)"
    section "Run $name: loaded images and log"
    lsof -p "$pid" 2>/dev/null | grep -E 'foo_component_updater_mac' | awk '{print $NF}' | sort -u | fence
    quit_or_stop "$name"
    cp "$log" "$WORK/run-$name.json"
    fence < "$log"
}

check_run() {
    local name="$1" stub_log="${2:-}"
    section "Run $name: checks"
    KNOWN_PROFILE="$WORK/known-profile.json" python3 "$SCRIPT_DIR/test_batch_check.py" "$name" "$WORK/run-$name.json" $stub_log > "$WORK/check-$name.txt"
    local rc=$?
    fence < "$WORK/check-$name.txt"
    grep -E '^(FAIL|INFO)' "$WORK/check-$name.txt"
    [ "$rc" -eq 0 ] || FAILURES=$((FAILURES + 1))
    say "$(grep -c '^PASS' "$WORK/check-$name.txt") checks passed, $(grep -c '^FAIL' "$WORK/check-$name.txt") failed in run $name"
}

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }

start_stub() {
    local mode="$1" port="$2" log="$3"
    : > "$log"
    python3 "$SCRIPT_DIR/test_stub.py" --port "$port" --cert "$WORK/cert.pem" --key "$WORK/key.pem" \
        --fixtures "$FIXTURES" --log "$log" --mode "$mode" --delay "${STUB_DELAY:-0}" ${PKG_DIR:+--packages "$PKG_DIR"} &
    STUB_PID=$!
    for _ in $(seq 1 40); do
        curl -sk -o /dev/null "https://127.0.0.1:$port/" && return 0
        sleep 0.25
    done
    return 1
}

for tool in python3 sqlite3 openssl curl ditto osascript lsof codesign; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done

{
    echo "# Proof log: $BATCH batch, $STAMP"
    echo
    echo "Host: $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m); foobar2000: $(defaults read /Applications/foobar2000.app/Contents/Info CFBundleShortVersionString 2>/dev/null)"
} > "$PROOF"

section "Backup"
ls "$REPORTS"/foobar2000* > "$WORK/reports-before.txt" 2>/dev/null
# Fail fast, before anything is backed up, changed or quit: a running foobar2000 is never quit.
if [ -n "$(fb2k_pid)" ]; then
    echo "foobar2000 is running (pid $(fb2k_pid)). The batch never quits it; stop it yourself and run again. Nothing was touched." >&2
    trap - EXIT
    rm -rf "$WORK"
    exit 2
fi
ditto "$PROFILE" "$BACKUP" || { echo "backup failed" >&2; exit 2; }
if defaults export "$DEFAULTS_DOMAIN" "$DEFAULTS_BACKUP" >/dev/null 2>&1; then
    DEFAULTS_SAVED=1
    say "PASS defaults backup: $DEFAULTS_BACKUP ($(wc -c < "$DEFAULTS_BACKUP" | tr -d ' ') bytes)"
else
    say "INFO no $DEFAULTS_DOMAIN defaults to back up"
fi
if diff -rq "$PROFILE" "$BACKUP" > "$WORK/backup-diff.txt" 2>&1; then
    BACKUP_DONE=1
    say "PASS backup: $BACKUP is identical to $PROFILE (diff -rq empty)"
else
    cat "$WORK/backup-diff.txt" >&2
    echo "backup differs from the profile; aborting" >&2
    exit 2
fi

section "Prepare a known profile"
JL_COMPONENTS="foo_jl_spectrum foo_jl_vectorscope foo_jl_simplaylist foo_jl_scrobble foo_jl_wave_seekbar"
JENDA_RELEASES_URL="https://api.github.com/repos/JendaT/fb2k-components-mac-suite/releases?per_page=100"
USER_COMPONENTS="$PROFILE/user-components"
mkdir -p "$USER_COMPONENTS"
find "$USER_COMPONENTS" -mindepth 1 -maxdepth 1 ! -name foo_component_updater_mac -exec rm -rf {} +
say "PASS user-components holds only: $(ls -A "$USER_COMPONENTS" | tr '\n' ' ')(the Debug build replaces ours next)"

mkdir -p "$WORK/jenda"
JENDA_PICKS="$WORK/jenda-picks.tsv"
if curl -sf -o "$WORK/jenda-releases.json" "$JENDA_RELEASES_URL"; then
    python3 - "$WORK/jenda-releases.json" $JL_COMPONENTS > "$JENDA_PICKS" <<'PY'
import json, re, sys

releases = json.load(open(sys.argv[1]))
components = sys.argv[2:]
missing = []

def version(tag):
    m = re.search(r"-v(\d+(?:\.\d+)*[^/]*)$", tag)
    return m.group(1) if m else None

def asset(release, component):
    for a in release.get("assets", []):
        if a["name"] == component + ".fb2k-component":
            return a["browser_download_url"]
    return None

def stable(release):
    return not release.get("draft") and not release.get("prerelease")

def newest(component):
    # The list is newest first.
    return next((r for r in releases if stable(r) and asset(r, component) and version(r["tag_name"])), None)

latest = newest("foo_jl_spectrum")
if latest:
    print("latest\tfoo_jl_spectrum\t" + version(latest["tag_name"]) + "\t" + asset(latest, "foo_jl_spectrum"))
for c in components:
    if c == "foo_jl_spectrum":
        r = next((r for r in releases if not r.get("draft") and asset(r, c) and version(r["tag_name"]) == "0.3.0"), None)
    else:
        r = newest(c)
    if r is None:
        missing.append(c)
    else:
        print("pick\t" + c + "\t" + version(r["tag_name"]) + "\t" + asset(r, c))
if missing:
    sys.stderr.write("no suitable release asset for: " + ", ".join(missing) + "\n")
    sys.exit(1)
PY
    JENDA_PICK_RC=$?
else
    : > "$JENDA_PICKS"
    JENDA_PICK_RC=1
fi
if [ -z "${JENDA_PACKAGES:-}" ] && [ "$JENDA_PICK_RC" -ne 0 ]; then
    fail "known profile: could not pick the JendaT releases (GitHub unreachable, or an asset is missing); set JENDA_PACKAGES to use local packages"
    exit 1
fi

for c in $JL_COMPONENTS; do
    pkg="$WORK/jenda/$c.fb2k-component"
    if [ -n "${JENDA_PACKAGES:-}" ]; then
        [ -f "$JENDA_PACKAGES/$c.fb2k-component" ] || { fail "known profile: $JENDA_PACKAGES/$c.fb2k-component is missing"; exit 1; }
        cp "$JENDA_PACKAGES/$c.fb2k-component" "$pkg"
    else
        url="$(awk -F'\t' -v c="$c" '$1 == "pick" && $2 == c { print $4 }' "$JENDA_PICKS")"
        [ -n "$url" ] || { fail "known profile: no release asset $c.fb2k-component"; exit 1; }
        curl -sfL -o "$pkg" "$url" || { fail "known profile: download of $url failed"; exit 1; }
    fi
    unzip -q -o "$pkg" 'mac/*' -d "$WORK/jenda/$c" && [ -d "$WORK/jenda/$c/mac/$c.component" ] || { fail "known profile: $c.fb2k-component has no mac/$c.component"; exit 1; }
    xattr -cr "$WORK/jenda/$c/mac/$c.component"
    if [ -n "${JENDA_PACKAGES:-}" ]; then
        ver="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$WORK/jenda/$c/mac/$c.component/Contents/Info.plist" 2>/dev/null)"
    else
        ver="$(awk -F'\t' -v c="$c" '$1 == "pick" && $2 == c { print $3 }' "$JENDA_PICKS")"
    fi
    [ -n "$ver" ] || { fail "known profile: no version for $c"; exit 1; }
    echo "$ver" > "$WORK/jenda/$c.version"
    mkdir -p "$USER_COMPONENTS/$c"
    cp -R "$WORK/jenda/$c/mac/$c.component" "$USER_COMPONENTS/$c/"
done
[ "$(cat "$WORK/jenda/foo_jl_spectrum.version")" = "0.3.0" ] || { fail "known profile: foo_jl_spectrum is $(cat "$WORK/jenda/foo_jl_spectrum.version"), not 0.3.0"; exit 1; }

# The newest Spectrum release is what the real run must report as available. Without GitHub (JENDA_PACKAGES only) it is unknown.
SPECTRUM_LATEST="$(awk -F'\t' '$1 == "latest" { print $3 }' "$JENDA_PICKS")"
python3 - "$WORK" "$SPECTRUM_LATEST" $JL_COMPONENTS > "$WORK/known-profile.json" <<'PY'
import json, sys
work, latest, components = sys.argv[1], sys.argv[2], sys.argv[3:]
known = {c: open(f"{work}/jenda/{c}.version").read().strip() for c in components}
if latest:
    known["foo_jl_spectrum_latest"] = latest
print(json.dumps(known))
PY
say "PASS known profile: $(cat "$WORK/known-profile.json") ($([ -n "${JENDA_PACKAGES:-}" ] && echo "packages from $JENDA_PACKAGES" || echo "GitHub releases of JendaT/fb2k-components-mac-suite"))"
[ -n "$SPECTRUM_LATEST" ] || say "INFO newest foo_jl_spectrum release unknown (GitHub not reachable); the real run cannot be checked"

# Every setting of ours at its default: the rows of the settings, the periodic check, the notes and the debug keys.
# foobar2000 stores a cfg_var under the GUID in uppercase; the last run time (A3C8E6D1-...) is set by the scenarios.
KNOWN_CFG_NAMES="'cfg_var.E1A6C4B9-3F7D-4E2A-9C8B-5D1F6A4E7C90','cfg_var.F2B7D5C0-4A8E-4F3B-AD9C-6E2A7B5F8D01','cfg_var.F7C3A9E2-6D1B-4F8A-9C2E-3B5D7A1F9C60','cfg_var.5876B420-1282-464E-9CB9-7CF32156F4F5','cfg_var.03396D36-9ED8-4F2E-9DC8-B1A16C75EE5D','cfg_var.141C795E-24E0-45FE-ABC2-15AA49E4766B','cfg_var.FD5423CC-F021-4C2B-A7E9-B0A211B85D27'"
sqlite3 "$CONFIG_DB" "DELETE FROM configInts WHERE name IN ($KNOWN_CFG_NAMES); DELETE FROM configStrings WHERE name IN ($KNOWN_CFG_NAMES) OR name GLOB 'foo_component_updater_mac.debug.*';" \
    || { fail "known profile: could not reset the settings rows"; exit 1; }
say "PASS settings reset: our cfg_var rows and foo_component_updater_mac.debug.* keys deleted (all defaults)"

section "Build and install the Debug component"
if "$PROJECT_DIR/Scripts/build.sh" --debug --install > "$WORK/build.log" 2>&1; then
    say "PASS Debug build installed: $(grep -c 'BUILD SUCCEEDED' "$WORK/build.log") x BUILD SUCCEEDED"
else
    tail -30 "$WORK/build.log"
    fail "Debug build"
    exit 1
fi

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 1 -nodes \
    -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >/dev/null 2>&1 || { echo "openssl failed" >&2; exit 2; }

cfg_delete_string foo_component_updater_mac.debug.api_base

# ---- run 1: real GitHub, one positive check -------------------------------------------------
if [ "$BATCH" = m1 ]; then
section "Run real: real GitHub API"
if ! curl -sf -o /dev/null https://api.github.com/rate_limit; then
    fail "real: api.github.com not reachable"
else
    used_before="$(curl -s https://api.github.com/rate_limit | python3 -c 'import json,sys; print(json.load(sys.stdin)["resources"]["core"]["used"])')"
    start_run real && check_run real
    used_after="$(curl -s https://api.github.com/rate_limit | python3 -c 'import json,sys; print(json.load(sys.stdin)["resources"]["core"]["used"])')"
    say "INFO GitHub rate limit counter (core.used) before: $used_before, after: $used_after (rate_limit calls are free)"
fi

if [ "$ONLY" = real ]; then exit 0; fi
fi

# ---- stage an older foo_abx (the catalog has one macOS build, 2.2.3; its version string is patched to 2.2.1) ----
section "Stage an older foo_abx"
ABX_URL="https://www.foobar2000.org$(grep -o '/getcomponent/[0-9a-f]\{32\}/foo_abx.fb2k-component' "$FIXTURES/catalog_foo_abx.html" | head -1)"
if [ -n "${FOO_ABX_PACKAGE:-}" ]; then cp "$FOO_ABX_PACKAGE" "$WORK/foo_abx.zip"; else curl -sSf -o "$WORK/foo_abx.zip" "$ABX_URL"; fi \
    && unzip -q -o "$WORK/foo_abx.zip" 'mac/*' -d "$WORK/abx" || { fail "download foo_abx"; exit 1; }
python3 - "$WORK/abx/mac/foo_abx.component/Contents/MacOS/foo_abx" <<'PY'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
n = d.count(b"2.2.3\x00")
assert n == 2, f"expected the version string once per architecture, found {n}"
open(p, "wb").write(d.replace(b"2.2.3\x00", b"2.2.1\x00"))
PY
# An invalid FB2KUpdateSource must stay visible after the check falls through to the catalog.
/usr/libexec/PlistBuddy -c "Add :FB2KUpdateSource dict" -c "Add :FB2KUpdateSource:source string nowhere" "$WORK/abx/mac/foo_abx.component/Contents/Info.plist"
xattr -cr "$WORK/abx/mac/foo_abx.component"
codesign --force --sign - "$WORK/abx/mac/foo_abx.component" >/dev/null 2>&1 || { fail "codesign foo_abx"; exit 1; }
mkdir -p "$PROFILE/user-components/foo_abx"
rm -rf "$PROFILE/user-components/foo_abx/foo_abx.component"
cp -R "$WORK/abx/mac/foo_abx.component" "$PROFILE/user-components/foo_abx/"
say "PASS foo_abx staged from $ABX_URL (mac part only, version string 2.2.3 -> 2.2.1, ad hoc signed)"

# One run against the local stub: start it (mode, optional STUB_DELAY), point the component at it, run, check,
# show the requests the stub saw, stop it. Usage: run_against_stub <run name> <stub mode>
run_against_stub() {
    local name="$1" mode="$2" port; port="$(free_port)"
    start_stub "$mode" "$port" "$WORK/stub-$name.log" || { fail "stub did not start"; exit 1; }
    cfg_set_string foo_component_updater_mac.debug.api_base "https://127.0.0.1:$port"
    start_run "$name" && check_run "$name" "$WORK/stub-$name.log"
    section "Run $name: requests the stub saw"
    fence < "$WORK/stub-$name.log"
    stop_stub
}

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Packages for the stub: good is the catalog's foo_abx re-signed ad hoc like the installed one (a restore of an ad hoc
# backup over a Developer ID bundle is refused by design), devid the original, forgedteam an ad hoc one whose code directory
# claims the Team ID of devid, the rest are broken in one way each.
m2_packages() {
    local pk="$WORK/pkgs"
    mkdir -p "$pk"
    unzip -q "$WORK/foo_abx.zip" 'mac/*' -d "$WORK/orig" || return 1
    cp "$WORK/foo_abx.zip" "$pk/devid.fb2k-component"
    ditto "$WORK/orig" "$WORK/good" && codesign --force --sign - "$WORK/good/mac/foo_abx.component" >/dev/null 2>&1 || return 1
    ditto "$WORK/good" "$WORK/tampered" && ditto "$WORK/good" "$WORK/wrongid" || return 1
    # The replacement: the same binary in a bundle of another name and bundle identifier.
    mkdir -p "$WORK/abxng/mac" && ditto "$WORK/good/mac/foo_abx.component" "$WORK/abxng/mac/foo_abx_ng.component" || return 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.foo-abx-ng" "$WORK/abxng/mac/foo_abx_ng.component/Contents/Info.plist"
    codesign --force --sign - "$WORK/abxng/mac/foo_abx_ng.component" >/dev/null 2>&1 && (cd "$WORK/abxng" && zip -qry "$pk/foo_abx_ng.fb2k-component" mac) || return 1
    python3 - "$WORK/tampered/mac/foo_abx.component/Contents/MacOS/foo_abx" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
open(sys.argv[1], "wb").write(d.replace(b"2.2.3\x00", b"2.2.9\x00"))
PY
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.other" "$WORK/wrongid/mac/foo_abx.component/Contents/Info.plist"
    codesign --force --sign - "$WORK/wrongid/mac/foo_abx.component" >/dev/null 2>&1 || return 1
    ditto "$WORK/good" "$WORK/linkout" && ln -s /etc "$WORK/linkout/mac/foo_abx.component/Contents/Resources/outside" || return 1
    ditto "$WORK/orig" "$WORK/forgedteam" && codesign --force --sign - --identifier com.foobar2000.foo-abxXXXXXXXXXXX "$WORK/forgedteam/mac/foo_abx.component" >/dev/null 2>&1 || return 1
    # Pad the identifier by 11 bytes, then overwrite the padding with the NUL and "9UF72C5LAW\0" (teamOffset) so nothing else moves.
    python3 - "$WORK/forgedteam/mac/foo_abx.component/Contents/MacOS/foo_abx" <<'PY'
import struct, sys
d = bytearray(open(sys.argv[1], "rb").read())
i = d.find(b"\xfa\xde\x0c\x02")
while i >= 0:
    ident, = struct.unpack(">I", d[i + 20:i + 24])
    assert d[i + ident:i + ident + 34] == b"com.foobar2000.foo-abx" + b"X" * 11 + b"\0"
    d[i + ident + 22:i + ident + 34] = b"\0" + b"9UF72C5LAW\0"
    d[i + 48:i + 52] = struct.pack(">I", ident + 23)
    i = d.find(b"\xfa\xde\x0c\x02", i + 1)
open(sys.argv[1], "wb").write(d)
PY
    [ "$(codesign -dv "$WORK/forgedteam/mac/foo_abx.component" 2>&1 | grep -c 'TeamIdentifier=9UF72C5LAW')" = 1 ] && codesign --verify --strict --deep "$WORK/forgedteam/mac/foo_abx.component" || return 1
    for n in good tampered wrongid linkout forgedteam; do (cd "$WORK/$n" && zip -qry "$pk/$n.fb2k-component" mac) || return 1; done
    (cd "$WORK/good/mac" && zip -qry "$pk/nomac.fb2k-component" foo_abx.component) || return 1
    python3 - "$pk/good.fb2k-component" "$pk/zipslip.fb2k-component" <<'PY'
import shutil, sys, zipfile
shutil.copy(sys.argv[1], sys.argv[2])
with zipfile.ZipFile(sys.argv[2], "a") as z:
    z.writestr("../../zipslip.txt", "x")
PY
    echo "not a zip" > "$pk/notzip.fb2k-component"
    # Two zips with a local entry that the central directory does not list (ditto would extract it, the layout check never saw it):
    # hiddenentry as it is, unreadable below a listed folder with mode 0200 (ditto applies it), so nothing under it can be examined.
    python3 - "$pk/good.fb2k-component" "$pk/hiddenentry.fb2k-component" "$pk/unreadable.fb2k-component" <<'PY'
import struct, sys, zlib
z = open(sys.argv[1], "rb").read()
eocd = z.rfind(b"PK\x05\x06")
count, size, cd_off = struct.unpack("<HII", z[eocd + 10:eocd + 20])
local_fmt = "<IHHHHHIIIHH"
name, data = b"extra/hidden.bin", b"hidden"
hidden = struct.pack(local_fmt, 0x04034b50, 20, 0, 0, 0, 0x21, zlib.crc32(data), len(data), len(data), len(name), 0) + name + data
open(sys.argv[2], "wb").write(z[:cd_off] + hidden + z[cd_off:eocd + 16] + struct.pack("<I", cd_off + len(hidden)) + z[eocd + 20:])
folder = b"extra/"
local = struct.pack(local_fmt, 0x04034b50, 20, 0, 0, 0, 0x21, 0, 0, 0, len(folder), 0) + folder + hidden
record = struct.pack("<I6H3I5H2I", 0x02014b50, 0x031e, 20, 0, 0, 0, 0x21, 0, 0, 0, len(folder), 0, 0, 0, 0, (0o40200 << 16) | 0x10, cd_off) + folder
tail = struct.pack("<HHII", count + 1, count + 1, size + len(record), cd_off + len(local))
open(sys.argv[3], "wb").write(z[:cd_off] + local + z[cd_off:eocd] + record + z[eocd:eocd + 8] + tail + z[eocd + 20:])
PY
    # self: the installed Debug component with the version string patched to 9.9.9 (same length, so nothing else moves) and signed
    # ad hoc again, the same bundle identifier. The bombs: central directory sizes that pass, 3000 MB of zeros that ditto really writes.
    local own="foo_component_updater_mac.component" own_version
    own_version="$(sed -nE 's/^#define[[:space:]]+FCU_VERSION[[:space:]]+"([^"]+)".*/\1/p' "$PROJECT_DIR/src/version.h")"
    mkdir -p "$WORK/self/mac" && ditto "$COMPONENT_DIR/$own" "$WORK/self/mac/$own" && xattr -cr "$WORK/self/mac/$own" || return 1
    python3 - "$WORK/self/mac/$own/Contents/MacOS/foo_component_updater_mac" "$own_version" <<'PY' || return 1
import sys
d = open(sys.argv[1], "rb").read()
old = sys.argv[2].encode() + b"\0"
assert len(old) == 6 and old in d
open(sys.argv[1], "wb").write(d.replace(old, b"9.9.9\0"))
PY
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" "$WORK/self/mac/$own/Contents/Info.plist"
    codesign --force --sign - "$WORK/self/mac/$own" >/dev/null 2>&1 && (cd "$WORK/self" && zip -qry "$pk/self.fb2k-component" mac) || return 1
    python3 - "$pk" <<'PY' || return 1
import struct, sys, zlib

def zeros(prefix):  # prefix followed by 3000 MB of zeros, deflated: (data, crc)
    chunk, crc, deflater = b"\0" * (1 << 20), zlib.crc32(prefix), zlib.compressobj(1, zlib.DEFLATED, -15)
    packed = bytearray(deflater.compress(prefix))
    for _ in range(3000):
        packed += deflater.compress(chunk)
        crc = zlib.crc32(chunk, crc)
    return bytes(packed + deflater.flush()), crc

BIG = 3000 << 20
plain, plain_crc = zeros(b"")
# AppleDouble header with one entry, the resource fork (id 2), of 3000 MB
fork, fork_crc = zeros(struct.pack(">IIQQH", 0x00051607, 0x00020000, 0, 0, 1) + struct.pack(">III", 2, 38, BIG))
small = lambda name: (name, b"x", 0, zlib.crc32(b"x"), 1, 1, 0o100644)
res = "mac/foo_abx.component/Contents/Resources/"
base = [small("mac/foo_abx.component/Contents/Info.plist"), small("mac/foo_abx.component/Contents/MacOS/foo_abx")]
# name, data, method, crc, size in the local header, size in the central directory, unix mode
variants = {
    "bomb": base + [(res + "bomb.bin", plain, 8, plain_crc, BIG, 1000, 0o100644)],
    "forkbomb": base + [small(res + "fork.bin"), ("__MACOSX/" + res + "._fork.bin", fork, 8, fork_crc, BIG + 38, 1000, 0o100644)],
}
for variant, parts in variants.items():
    out, directory = bytearray(), bytearray()
    for name, data, method, check, real, declared, mode in parts:
        n = name.encode()
        directory += struct.pack("<I6H3I5H2I", 0x02014b50, 0x031e, 20, 0, method, 0, 0x21, check, len(data), declared, len(n), 0, 0, 0, 0, (mode << 16) | (0x10 if name.endswith("/") else 0), len(out)) + n
        out += struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, 0, method, 0, 0x21, check, len(data), real, len(n), 0) + n + data
    out += directory + struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, len(parts), len(parts), len(directory), len(out), 0)
    open(f"{sys.argv[1]}/{variant}.fb2k-component", "wb").write(out)
PY
}

# m2_start <scenario>: starts foobar2000 on a scenario of the autotest hook and waits for its log.
m2_start() {
    [ -z "$(fb2k_pid)" ] || { fail "m2 $1: foobar2000 is already running and was not started by this batch; it is left alone"; exit 3; }
    cfg_set_string foo_component_updater_mac.debug.m2 "$1"
    cfg_set_string foo_component_updater_mac.debug.autotest "$WORK/autotest-m2-$1.json"
    launch_fb2k
    m2_wait "$1"
}

# m2_wait <scenario>: waits for the log of the scenario; the process that wrote it is the one to quit (a restart changes the pid).
m2_wait() {
    local log="$WORK/autotest-m2-$1.json"
    for _ in $(seq 1 240); do [ -s "$log" ] && break; sleep 0.5; done
    if [ ! -s "$log" ]; then fail "m2 $1: no autotest log after 120 s"; return 1; fi
    BATCH_PID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["before"]["pid"])' "$log")"
    section "m2 $1: loaded images and log"
    lsof -p "$BATCH_PID" 2>/dev/null | grep -E 'foo_abx|foo_component_updater_mac' | awk '{print $(NF-1), $NF}' | sort -u | tee "$WORK/lsof-$1.txt" | fence
    cp "$log" "$WORK/run-m2-$1.json"
    fence < "$log"
}

# m2_peak <scenario>: records the largest size (KB) of the work folder until the scenario's log exists.
m2_peak() {
    local log="$WORK/autotest-m2-$1.json" max=0 kb
    for _ in $(seq 1 1200); do
        [ -s "$log" ] && break
        kb="$(du -sk "$PROFILE/foo_component_updater_mac/work" 2>/dev/null | cut -f1)"
        [ "${kb:-0}" -gt "$max" ] && max="$kb"
        echo "$max" > "$WORK/peak-$1.kb"
        sleep 0.05
    done
}

# m2_disk <scenario> <sha256 of the binary expected on disk and mapped, or empty to skip> [component, default foo_abx]: the file system after a step.
m2_disk() {
    local c="${3:-foo_abx}" bin inode mapped
    bin="$PROFILE/user-components/$c/$c.component/Contents/MacOS/$c"
    if [ -n "$2" ]; then
        inode="$(stat -f %i "$bin")"
        mapped="$(grep "$c.component/Contents/MacOS/$c" "$WORK/lsof-$1.txt" | awk '{print $1}' | sort -u | tr '\n' ' ')"
        if [ "$(sha "$bin")" = "$2" ] && [ "$mapped" = "$inode " ]; then
            say "PASS m2 $1: the binary on disk is ${2:0:12}... and the process maps that very file (inode $inode)"
        else
            fail "m2 $1: binary sha $(sha "$bin") (want $2), mapped inodes '$mapped', file inode $inode"
        fi
    fi
    [ -z "$(ls "$PROFILE/foo_component_updater_mac/work" 2>/dev/null)" ] && say "PASS m2 $1: work folder is empty" || fail "m2 $1: work folder is not empty"
}

run_m2() {
    section "m2: packages for the stub"
    m2_packages && say "PASS packages built: $(ls "$WORK/pkgs" | tr '\n' ' ')" || { fail "building the packages"; exit 1; }
    local installed="$PROFILE/user-components/foo_abx/foo_abx.component" old_sha good_sha orig_sha own_sha port
    old_sha="$(sha "$installed/Contents/MacOS/foo_abx")"
    own_sha="$(sha "$COMPONENT_DIR/foo_component_updater_mac.component/Contents/MacOS/foo_component_updater_mac")"
    good_sha="$(sha "$WORK/good/mac/foo_abx.component/Contents/MacOS/foo_abx")"
    orig_sha="$(sha "$WORK/orig/mac/foo_abx.component/Contents/MacOS/foo_abx")"
    # The scenarios assume that no component has a backup yet (the profile is restored afterwards).
    rm -rf "$PROFILE/foo_component_updater_mac/backup"
    PKG_DIR="$WORK/pkgs"
    port="$(free_port)"
    start_stub normal "$port" "$WORK/stub-m2.log" || { fail "stub did not start"; exit 1; }
    cfg_set_string foo_component_updater_mac.debug.api_base "https://127.0.0.1:$port"

    BATCH_PID=""
    m2_start install && check_run m2-install
    local previous="$BATCH_PID"
    # Restart 1: pending/foo_abx is applied, the process maps the new binary.
    if m2_wait restore; then
        check_run m2-restore "$previous"; m2_disk restore "$good_sha"; previous="$BATCH_PID"
    fi
    # Restart 2: the backup is back, and the backup holds the newer version.
    if m2_wait refuse; then
        check_run m2-refuse "$previous"; m2_disk refuse "$old_sha"
        [ ! -e "$PROFILE/user-components/pending/foo_abx" ] && say "PASS m2 refuse: nothing pending after nine refused packages" || fail "m2 refuse: pending/foo_abx exists"
        say "INFO backup.json on disk: $(cat "$PROFILE/foo_component_updater_mac/backup/foo_abx/backup.json")"
    fi
    quit_or_stop m2

    # bomb: the 3000 MB package passes the layout check. The work folder is sampled while the scenario runs; ditto must be killed far below that.
    m2_peak bomb &
    local sampler=$!
    if m2_start bomb; then
        wait "$sampler"
        check_run m2-bomb
        local peak; peak="$(cat "$WORK/peak-bomb.kb" 2>/dev/null || echo 0)"
        [ "$peak" -lt 1500000 ] && say "PASS m2 bomb: the work folder peaked at $((peak / 1024)) MB for a 3000 MB bomb" || fail "m2 bomb: the work folder reached $((peak / 1024)) MB"
        [ -z "$(pgrep -x ditto)" ] && say "PASS m2 bomb: ditto is not running" || fail "m2 bomb: ditto is still running"
        [ ! -e "$PROFILE/user-components/pending/foo_abx" ] && say "PASS m2 bomb: nothing pending" || fail "m2 bomb: pending/foo_abx exists"
        m2_disk bomb ""
    fi
    quit_or_stop m2

    # self: the Debug component updates itself to 9.9.9 (restart), Restore Previous brings the installed one back (restart).
    local self_new_sha
    self_new_sha="$(sha "$WORK/self/mac/foo_component_updater_mac.component/Contents/MacOS/foo_component_updater_mac")"
    BATCH_PID=""
    if m2_start self-install; then
        check_run m2-self-install
        previous="$BATCH_PID"
        if m2_wait self-restore; then
            check_run m2-self-restore "$previous"; m2_disk self-restore "$self_new_sha" foo_component_updater_mac; previous="$BATCH_PID"
            if m2_wait self-back; then
                check_run m2-self-back "$previous"; m2_disk self-back "$own_sha" foo_component_updater_mac
                [ ! -e "$PROFILE/user-components/pending/foo_component_updater_mac" ] && say "PASS m2 self-back: nothing pending" || fail "m2 self-back: pending/foo_component_updater_mac exists"
            fi
        fi
    fi
    quit_or_stop m2

    rm -rf "$PROFILE/user-components/foo_abx" && mkdir "$PROFILE/user-components/foo_abx" && cp -R "$WORK/orig/mac/foo_abx.component" "$PROFILE/user-components/foo_abx/"
    say "INFO foo_abx replaced by the original Developer ID bundle: $(codesign -dv "$installed" 2>&1 | grep TeamIdentifier)"
    if m2_start team; then
        check_run m2-team
        local staged="$PROFILE/user-components/pending/foo_abx/foo_abx.component"
        if [ "$(sha "$staged/Contents/MacOS/foo_abx")" = "$orig_sha" ] && codesign --verify --strict --deep "$staged" 2>/dev/null \
            && [ "$(xattr -lr "$staged" | grep -c quarantine)" = 0 ] && [ "$(sha "$installed/Contents/MacOS/foo_abx")" = "$orig_sha" ]; then
            say "PASS m2 team: the staged bundle is the Developer ID package, verifies, has no quarantine; the installed bundle is untouched"
        else
            fail "m2 team: staged bundle is not as expected"
        fi
    fi
    quit_or_stop m2

    # switch: the ad hoc foo_abx with an FB2KReplacedBy key, nothing pending (the team run staged foo_abx).
    rm -rf "$PROFILE/user-components/pending/foo_abx" "$PROFILE/user-components/foo_abx/foo_abx.component"
    cp -R "$WORK/good/mac/foo_abx.component" "$PROFILE/user-components/foo_abx/"
    /usr/libexec/PlistBuddy -c "Add :FB2KReplacedBy dict" -c "Add :FB2KReplacedBy:component string foo_abx_ng" -c "Add :FB2KReplacedBy:source string github" \
        -c "Add :FB2KReplacedBy:owner string fcu-test" -c "Add :FB2KReplacedBy:repo string foo_abx_ng" \
        -c "Add :FB2KReplacedBy:migration_url string https://github.com/fcu-test/foo_abx_ng#migrating" "$installed/Contents/Info.plist"
    codesign --force --sign - "$installed" >/dev/null 2>&1 || { fail "codesign foo_abx with FB2KReplacedBy"; exit 1; }
    mkdir -p /tmp/fcu-ui
    BATCH_PID=""
    if m2_start switch; then
        check_run m2-switch
        [ -f "$PROFILE/user-components/pending/foo_abx" ] && [ ! -s "$PROFILE/user-components/pending/foo_abx" ] \
            && [ -d "$PROFILE/user-components/pending/foo_abx_ng/foo_abx_ng.component" ] \
            && say "PASS m2 switch: pending/foo_abx is an empty removal marker, pending/foo_abx_ng holds the replacement" \
            || fail "m2 switch: pending is not as expected: $(ls -la "$PROFILE/user-components/pending" 2>&1)"
        previous="$BATCH_PID"
        if m2_wait switch-after; then
            check_run m2-switch-after "$previous"
            m2_disk switch-after ""
            # The bundle keeps its executable name (foo_abx), so m2_disk's path does not apply.
            local ng="foo_abx_ng.component/Contents/MacOS/foo_abx"
            [ "$(sha "$PROFILE/user-components/foo_abx_ng/$ng")" = "$(sha "$WORK/abxng/mac/$ng")" ] && grep -q "foo_abx_ng/$ng" "$WORK/lsof-switch-after.txt" \
                && say "PASS m2 switch-after: the process maps the replacement's binary from user-components/foo_abx_ng" \
                || fail "m2 switch-after: the replacement binary is not installed or not mapped"
            [ ! -e "$PROFILE/user-components/foo_abx" ] && [ -z "$(ls "$PROFILE/user-components/pending" 2>/dev/null)" ] \
                && say "PASS m2 switch-after: user-components/foo_abx is gone and nothing is pending" \
                || fail "m2 switch-after: foo_abx or pending entries remain: $(ls "$PROFILE/user-components" "$PROFILE/user-components/pending" 2>&1)"
        fi
    fi
    quit_or_stop m2

    # core: foobar2000 itself replaced foo_abx (FB2KReplacedBy foobar2000 2.0, older than the running version); no successor, only the removal is staged.
    rm -rf "$PROFILE/user-components/pending/foo_abx" "$PROFILE/user-components/foo_abx" && mkdir "$PROFILE/user-components/foo_abx"
    cp -R "$WORK/good/mac/foo_abx.component" "$PROFILE/user-components/foo_abx/"
    /usr/libexec/PlistBuddy -c "Add :FB2KReplacedBy dict" -c "Add :FB2KReplacedBy:foobar2000 string 2.0" \
        -c "Add :FB2KReplacedBy:migration_url string https://example.org/foo_abx#built-in" "$installed/Contents/Info.plist"
    codesign --force --sign - "$installed" >/dev/null 2>&1 || { fail "codesign foo_abx with FB2KReplacedBy foobar2000"; exit 1; }
    BATCH_PID=""
    if m2_start core; then
        check_run m2-core
        [ -f "$PROFILE/user-components/pending/foo_abx" ] && [ ! -s "$PROFILE/user-components/pending/foo_abx" ] \
            && [ "$(ls "$PROFILE/user-components/pending" | wc -l | tr -d ' ')" = 1 ] \
            && say "PASS m2 core: pending/foo_abx is an empty removal marker and nothing else is pending" \
            || fail "m2 core: pending is not as expected: $(ls -la "$PROFILE/user-components/pending" 2>&1)"
        previous="$BATCH_PID"
        if m2_wait core-after; then
            check_run m2-core-after "$previous"
            m2_disk core-after ""
            [ ! -e "$PROFILE/user-components/foo_abx" ] && [ -z "$(ls "$PROFILE/user-components/pending" 2>/dev/null)" ] \
                && say "PASS m2 core-after: user-components/foo_abx is gone and nothing is pending" \
                || fail "m2 core-after: foo_abx or pending entries remain: $(ls "$PROFILE/user-components" "$PROFILE/user-components/pending" 2>&1)"
        fi
    fi
    quit_or_stop m2
    section "m2: requests the stub saw"
    fence < "$WORK/stub-m2.log"
}

if [ "$BATCH" = m1 ]; then
# ---- run 2: stub, settings persisted, catalog source ---------------------------------------
run_against_stub stub normal

# ---- run 3: nothing listening ---------------------------------------------------------------
cfg_set_string foo_component_updater_mac.debug.api_base "https://127.0.0.1:$(free_port)"
start_run down && check_run down

# ---- run 4: rate limited ---------------------------------------------------------------------
run_against_stub ratelimit ratelimit

# ---- run 5: registry entries that must never reach a URL -------------------------------------
# Forget the cached registry so the run fetches the stub's bad one.
sqlite3 "$CONFIG_DB" "DELETE FROM configInts WHERE name LIKE 'cfg_var.bd0271b2%'; DELETE FROM configStrings WHERE name LIKE 'cfg_var.a308a585%';"
run_against_stub badregistry badregistry

# ---- run 6: manual command, periodic evaluation and the old menu titles ------------------------
cfg_set_string foo_component_updater_mac.debug.recheck_seconds 2
STUB_DELAY=0.3 run_against_stub triggers normal
cfg_delete_string foo_component_updater_mac.debug.recheck_seconds
else
run_m2
fi

section "Crash reports"
ls "$REPORTS"/foobar2000* > "$WORK/reports-after.txt" 2>/dev/null
if diff "$WORK/reports-before.txt" "$WORK/reports-after.txt" > "$WORK/reports-diff.txt"; then
    say "PASS no new foobar2000 crash report"
else
    fail "new foobar2000 crash report"
    fence < "$WORK/reports-diff.txt"
fi
