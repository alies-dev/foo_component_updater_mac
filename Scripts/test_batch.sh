#!/bin/bash
#
# test_batch.sh - Run one milestone's test batch in the real foobar2000
#
# Usage:
#   ./Scripts/test_batch.sh m1          all runs
#   ./Scripts/test_batch.sh m1 real     only the real GitHub run (to compare request counts)
#
# M1 runs six headless starts of foobar2000 against the Debug build, driven by the
# foo_component_updater_mac.debug.autotest hook (no UI, no keystrokes, no clicks):
#   real       real GitHub API: the 5 installed JendaT components, exactly 1 API request
#   stub       local HTTPS stub: persisted settings, catalog source (older foo_abx)
#   down       stub not listening: network errors, no crash
#   ratelimit  stub answers 403 with x-ratelimit headers: message, no further API calls
#   badregistry registry entries that must never reach a URL
#   triggers   synthetic "Check For New Versions" menu notifications and the periodic evaluation (counted checks)
#
# Rules (hard): ~/Library/foobar2000-v2 is backed up first and restored afterwards
# (verified with diff -rq); foobar2000 is started only with `open -g -a foobar2000`,
# never activated, and quit with osascript.
#
# Environment: FB2K_SDK_PATH (SDK location), FOO_ABX_PACKAGE (a local copy of the foo_abx package
# from the catalog, used instead of downloading it), PROOF_OUT (where to copy the proof log,
# default build/<batch>-proof.md).

set -uo pipefail

BATCH="${1:-}"
ONLY="${2:-}"
if [ "$BATCH" != "m1" ]; then
    echo "Usage: $0 m1" >&2
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
    open -g -a foobar2000
    for _ in $(seq 1 40); do BATCH_PID="$(fb2k_pid)"; [ -n "$BATCH_PID" ] && break; sleep 0.25; done
    for _ in $(seq 1 240); do
        [ -s "$log" ] && break
        sleep 0.5
    done
    if [ ! -s "$log" ]; then
        fail "$name: no autotest log after 120 s"
        quit_fb2k
        return 1
    fi
    local pid; pid="$(fb2k_pid)"
    section "Run $name: loaded images and log"
    lsof -p "$pid" 2>/dev/null | grep -E 'foo_component_updater_mac' | awk '{print $NF}' | sort -u | fence
    quit_fb2k || fail "$name: foobar2000 did not quit"
    cp "$log" "$WORK/run-$name.json"
    fence < "$log"
}

check_run() {
    local name="$1" stub_log="${2:-}"
    section "Run $name: checks"
    python3 "$SCRIPT_DIR/test_batch_check.py" "$name" "$WORK/run-$name.json" $stub_log > "$WORK/check-$name.txt"
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
        --fixtures "$FIXTURES" --log "$log" --mode "$mode" --delay "${STUB_DELAY:-0}" &
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

# ---- run 6: menu trigger and periodic evaluation ----------------------------------------------
cfg_set_string foo_component_updater_mac.debug.recheck_seconds 2
STUB_DELAY=0.3 run_against_stub triggers normal
cfg_delete_string foo_component_updater_mac.debug.recheck_seconds

section "Crash reports"
ls "$REPORTS"/foobar2000* > "$WORK/reports-after.txt" 2>/dev/null
if diff "$WORK/reports-before.txt" "$WORK/reports-after.txt" > "$WORK/reports-diff.txt"; then
    say "PASS no new foobar2000 crash report"
else
    fail "new foobar2000 crash report"
    fence < "$WORK/reports-diff.txt"
fi
