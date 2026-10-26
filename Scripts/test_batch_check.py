#!/usr/bin/env python3
"""Assertions for the M1 batch (Scripts/test_batch.sh). Prints PASS/FAIL per check.

Usage: test_batch_check.py <run> <autotest.json> [<stub.log>]
Runs: real, stub, down, ratelimit, badregistry, triggers
"""
import json
import re
import sys
from pathlib import Path

failures = 0


def check(name, ok, detail=""):
    global failures
    if not ok:
        failures += 1
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or not detail else f": {detail}"))


def rows_by_name(log):
    return {r["component"]: r for r in log["rows"] if r["component"]}


def stub_paths(stub_log):
    if not stub_log:
        return []
    with open(stub_log) as f:
        return [json.loads(line)["path"] for line in f if line.strip()]


def common(log):
    reg = log["registered"]
    check("menu command registered in Help",
          len(reg["menu"]) == 1 and reg["menu"][0]["name"] == "Check for Component Updates..." and reg["menu"][0]["in_help_menu"], reg["menu"])
    check("preferences page registered under Tools",
          len(reg["preferences"]) == 1 and reg["preferences"][0]["name"] == "Component Updates" and reg["preferences"][0]["under_tools"], reg["preferences"])
    for r in log["rows"]:
        if r["component"] == "Core":
            check("Core row is No source", r["status"] == "no_source", r)
            break
    rw = log["results_window"]
    check("results window with built in components hidden builds every visible cell off screen",
          rw["rows"] == len(log["rows"]) and rw["visible_rows"] == rw["rows"] - rw["built_in_rows"] and rw["built_in_rows"] > 0
          and rw["cells"] == 7 * rw["visible_rows"], rw)
    check("results window with built in components shown lists every row (measured separately from the saved preference)",
          rw["visible_rows_shown"] == rw["rows"] and rw["cells_shown"] == 7 * rw["rows"], rw)
    iv = log["apply"]["interval"]
    check("interval field commits on end editing: 12 saved, 0 clamps to 1, 31 clamps to 30, empty and text revert, typed text survives a stepper click",
          iv["type_12"] == 12 and iv["type_0"] == 1 and iv["type_31"] == 30 and iv["type_12_again"] == 12
          and iv["type_empty"] == 12 and iv["empty_field_text"] == "12" and iv["type_text"] == 12 and iv["type_12_step_up"] == 13
          and iv["at_30_type_12_up"] == 13 and iv["at_1_type_12_down"] == 11 and iv["at_30_type_junk_up"] == 30, iv)
    snap = log["snapshots"]
    check("preferences page is pinned at the margin", snap["prefs_geometry"].startswith("page y=20 x=20"), snap)
    check("off screen snapshots written",
          snap["prefs_light"] and snap["prefs_dark"] and snap["prefs_help_popover"]
          and snap["results_default_rows"] == rw["visible_rows"] and snap["results_core_shown_rows"] == rw["rows"], snap)
    lc = log["last_check_refresh"]
    check("Last check line refreshes when a check completes while the page is open, and not after it closed",
          lc["began"] and lc["refreshed_when_visible"] and lc["not_refreshed_when_hidden"], lc)
    check("settings written by the run", log["settings_set"] == {"auto_check": True, "interval_days": 11, "include_prereleases": True}, log["settings_set"])


JL = ["foo_jl_spectrum", "foo_jl_vectorscope", "foo_jl_simplaylist", "foo_jl_scrobble", "foo_jl_wave_seekbar"]
FRESH = {"auto_check": True, "interval_days": 7, "include_prereleases": False}
PERSISTED = {"auto_check": True, "interval_days": 11, "include_prereleases": True}


def jenda_rows(rows):
    for name in JL:
        r = rows.get(name)
        check(f"{name} present and resolved through the built in list", r is not None and r["origin"] == "built in list", r)
    s = rows.get("foo_jl_spectrum", {})
    check("Spectrum 0.3.0 reports 1.0.0 available",
          s.get("installed") == "0.3.0" and s.get("latest") == "1.0.0" and s.get("status") == "update_available", s)
    for name in JL[1:]:
        r = rows.get(name, {})
        check(f"{name} up to date", r.get("status") == "up_to_date", r)


# GitHub release list requests (/repos/.../releases) each run must make: 2 checks' worth is a bug.
# The checked component and JendaT's suite are one request each; triggers also counts the 7 later
# checks (the command twice, the command with the window open, periodic, attach, manual reopen, dismiss, concurrent) of the scenario.
EXPECTED_GITHUB_REQUESTS = {"real": 2, "stub": 2, "down": 2, "ratelimit": 1, "badregistry": 2, "triggers": 16}


def github_requests(log, stub_log, run):
    # "triggers" counts at the end of the run on the stub (the log of requests is taken after the first check).
    if run == "real":
        return len([u for u in log["requests"] if u.startswith("https://api.github.com/") and "/repos/" in u])
    if run == "down":
        return len([u for u in log["requests"] if "/repos/" in u])
    return len([p for p in stub_paths(stub_log) if p.startswith("/repos/")])


SELF_UPDATE = "9.9.9"  # the version of the package the batch serves as the updater's own update


def fcu_version():
    return re.search(r'#define\s+FCU_VERSION\s+"([^"]+)"', (Path(__file__).parent.parent / "src" / "version.h").read_text()).group(1)


def refused(log, name, text):
    o = log["outcomes"].get(name, {})
    check(f"{name}: refused with a message about \"{text}\"", o.get("ok") is False and text in o.get("message", ""), o)


def m2(run, log, previous_pid):
    before, after, o = log["before"], log["after"], log.get("outcomes", {})
    if previous_pid:
        check("a new foobar2000 process started (the restart)", before["pid"] != int(previous_pid[0]), before)
    if run == "m2-install":
        row = log["row"]
        check("foo_abx shows an update from 2.2.1 to 2.2.3 and is installable",
              (row["status"], row["installed"], row["latest"], row["block_reason"]) == ("update_available", "2.2.1", "2.2.3", ""), row)
        check("start state: 2.2.1 installed, nothing staged, no backup", (before["installed_version"], before["staged"], before["backup_version"]) == ("2.2.1", False, ""), before)
        check("install staged the new version and kept 2.2.1 as the backup",
              o["install"]["ok"] is True and after["staged"] is True and after["backup_version"] == "2.2.1" and after["installed_version"] == "2.2.1", log)
    elif run == "m2-restore":
        check("after the restart the Components list shows 2.2.3, nothing pending, the backup is 2.2.1",
              (before["installed_version"], before["staged"], before["backup_version"]) == ("2.2.3", False, "2.2.1"), before)
        check("Restore Previous staged the backup and the backup now holds 2.2.3",
              o["restore"]["ok"] is True and after["staged"] is True and after["backup_version"] == "2.2.3", log)
    elif run == "m2-refuse":
        check("after the restart the Components list shows 2.2.1 again and the backup holds 2.2.3",
              (before["installed_version"], before["staged"], before["backup_version"]) == ("2.2.1", False, "2.2.3"), before)
        for name, text in (("tampered", "code signature"), ("wrongid", "bundle identifier"), ("zipslip", "unsafe path"), ("nomac", "no macOS build"),
                           ("notzip", "not a valid package"), ("missing", "download failed"), ("linkout", "link that points outside"),
                           ("hiddenentry", "not in its own listing"), ("unreadable", "cannot be examined")):
            refused(log, name, text)
        check("nothing staged, installed version and backup unchanged",
              (after["staged"], after["installed_version"], after["backup_version"]) == (False, "2.2.1", "2.2.3"), after)
        menu = log["restore_menu"]
        check("context menu: Restore Previous (2.2.3) is enabled for foo_abx, disabled without a backup",
              (menu["title"], menu["enabled"], menu["title_without_backup"], menu["enabled_without_backup"]) == ("Restore Previous (2.2.3)", True, "Restore Previous", False), menu)
    elif run == "m2-bomb":
        refused(log, "bomb", "expands to more than 512 MB")
        refused(log, "forkbomb", "expands to more than 512 MB")  # the AppleDouble resource fork, written as a plain file, is counted
        check("nothing staged, installed version and backup unchanged",
              (after["staged"], after["installed_version"], after["backup_version"]) == (False, "2.2.1", "2.2.3"), after)
    elif run == "m2-self-install":
        own = fcu_version()
        check("the own row is installable once an update is available", log["block_reason"] == "", log["block_reason"])
        check(f"the updater runs {own} and has nothing pending", (before["installed_version"], before["staged"]) == (own, False), before)
        check(f"install staged the new package and kept {own} as the backup",
              o["install"]["ok"] is True and after["staged"] is True and after["backup_version"] == own and after["installed_version"] == own, log)
    elif run == "m2-self-restore":
        own = fcu_version()
        check(f"after the restart the updater reports {SELF_UPDATE}, nothing pending, the backup is {own}",
              (before["installed_version"], before["staged"], before["backup_version"]) == (SELF_UPDATE, False, own), before)
        check(f"Restore Previous staged {own} and the backup now holds {SELF_UPDATE}",
              o["restore"]["ok"] is True and after["staged"] is True and after["backup_version"] == SELF_UPDATE, log)
    elif run == "m2-self-back":
        own = fcu_version()
        check(f"after the second restart the updater reports {own} again and the backup holds {SELF_UPDATE}",
              (before["installed_version"], before["staged"], before["backup_version"]) == (own, False, SELF_UPDATE), before)
    elif run == "m2-team":
        refused(log, "other_developer", "different developer")
        refused(log, "forged_team", "different developer")
        refused(log, "switch_other_developer", "not signed by the developer the switch requires (Team ID 9UF72C5LAW)")
        check("a package from the same Team ID is staged", o["same_developer"]["ok"] is True and after["staged"] is True, log)
    elif run == "m2-switch":
        kept, row, ng = log["kept_row"], log["row"], log["replacement_before"]
        check("kept: foo_abx is checked as usual (catalog, up to date) and says what it keeps",
              (kept["status"], kept["kept"], kept["replaced_by"]) == ("up_to_date", True, "foo_abx_ng") and "you keep this component" in kept["note"], kept)
        check("foo_abx shows Replaced by foo_abx_ng 1.0.0 from its own Info.plist, with migration notes, and is installable",
              (row["status"], row["replaced_by"], row["origin"], row["latest"], row["source"], row["asset"], row["block_reason"], row["migration"])
              == ("replaced", "foo_abx_ng", "Info.plist", "1.0.0", "fcu-test/foo_abx_ng", "foo_abx_ng.fb2k-component", "",
                  "https://github.com/fcu-test/foo_abx_ng#migrating"), row)
        check("start state: foo_abx 2.2.3 installed, foo_abx_ng absent, nothing pending",
              (before["installed_version"], before["staged"], before["removal_staged"], ng["installed_version"], ng["staged"]) == ("2.2.3", False, False, "", False), log)
        check("the switch staged foo_abx_ng and the removal of foo_abx",
              o["switch"]["ok"] is True and after["removal_staged"] is True and log["replacement_after"]["staged"] is True, log)
        check("the results window rendered the switch rows", log["snapshot_rows"] > 0, log["snapshot_rows"])
        expected = ("Switch foo_abx to foo_abx_ng?\nfoo_abx 2.2.3 will be removed.\nfoo_abx_ng 1.0.0 will be installed.\nFrom: fcu-test/foo_abx_ng\n"
                    "Declared by foo_abx itself.\n\nSettings are not carried over. The changes apply when foobar2000 restarts.\n"
                    "[link] Migration notes for foo_abx_ng (github.com) -> https://github.com/fcu-test/foo_abx_ng#migrating")
        check("the switch confirmation names what goes, what comes, from where, who declared it, and links the notes",
              log["switch_confirmation"] == expected, log["switch_confirmation"])
    elif run == "m2-switch-after":
        ng = log["replacement_before"]
        check("after the restart foo_abx is gone and foo_abx_ng 2.2.3 runs, nothing pending",
              (before["installed_version"], before["removal_staged"], ng["installed_version"], ng["staged"]) == ("", False, "2.2.3", False), log)
        check("the migration notes of the applied switch are kept until offered, then gone",
              log["migration_notes"] == [{"from": "foo_abx", "to": "foo_abx_ng", "url": "https://github.com/fcu-test/foo_abx_ng#migrating"}]
              and log["migration_notes_kept_until_offered"] == 1 and log["migration_notes_again"] == 0, log)
        check("the alert after the restart names both components and the notes' host",
              log["migration_alert"] == "foo_abx_ng replaced foo_abx\nIts author wrote migration notes on github.com: what to set up again after the switch.",
              log["migration_alert"])
    elif run == "m2-core":
        row, older = log["row"], log["older_row"]
        check("foo_abx shows Replaced by foobar2000 2.0 from its own Info.plist, with migration notes",
              (row["status"], row["replaced_by"], row["replaced_by_foobar2000"], row["origin"], row["latest"], row["migration"])
              == ("replaced", "foobar2000", True, "Info.plist", "2.0", "https://example.org/foo_abx#built-in") and "foobar2000 2.0" in row["note"], row)
        check("a foobar2000 older than the declared version does not replace it: the row is checked as usual and says when it can go",
              (older["status"], older["replaced_by_foobar2000"]) == ("up_to_date", False) and "foobar2000 99 includes this" in older["note"], older)
        check("start state: foo_abx 2.2.3 installed, nothing pending", (before["installed_version"], before["staged"], before["removal_staged"]) == ("2.2.3", False, False), before)
        check("Install staged the removal of foo_abx", o["stage_removal"]["ok"] is True and after["removal_staged"] is True, log)
        expected = ("Remove foo_abx?\nfoo_abx 2.2.3 will be removed.\nfoobar2000 2.0 already includes it.\nDeclared by foo_abx itself.\n\n"
                    "Settings are not carried over. The changes apply when foobar2000 restarts.\n"
                    "[link] Migration notes for foobar2000 (example.org) -> https://example.org/foo_abx#built-in")
        check("the confirmation names what goes, that foobar2000 includes it, who declared it, and links the notes",
              log["core_confirmation"] == expected, log["core_confirmation"])
    elif run == "m2-core-after":
        check("after the restart foo_abx is gone and nothing is pending", (before["installed_version"], before["staged"], before["removal_staged"]) == ("", False, False), before)
        check("the migration notes of the applied removal are kept until offered, then gone",
              log["migration_notes"] == [{"from": "foo_abx", "to": "foobar2000", "url": "https://example.org/foo_abx#built-in"}]
              and log["migration_notes_kept_until_offered"] == 1 and log["migration_notes_again"] == 0, log)
        check("the alert after the restart names foobar2000 and the notes' host",
              log["migration_alert"] == "foobar2000 replaced foo_abx\nIts author wrote migration notes on example.org: what to set up again after the switch.",
              log["migration_alert"])
    sys.exit(1 if failures else 0)


def main():
    run, path = sys.argv[1], sys.argv[2]
    log = json.load(open(path))
    if run.startswith("m2-"):
        m2(run, log, sys.argv[3:4])
    stub_log = sys.argv[3] if len(sys.argv) > 3 else None
    rows = rows_by_name(log)
    requests = log["requests"]
    common(log)
    n = github_requests(log, stub_log, run)
    check(f"exactly {EXPECTED_GITHUB_REQUESTS[run]} GitHub release list requests in run {run}", n == EXPECTED_GITHUB_REQUESTS[run], n)
    print(f"INFO GitHub release list requests in run {run}: {n}")
    own = rows.get("foo_component_updater_mac")
    check("own component resolved through its Info.plist key", own is not None and own["origin"] == "Info.plist" and own["source"] == "alies-dev/foo_component_updater_mac", own)

    if run == "real":
        check("settings at start are the defaults", log["settings_at_start"] == FRESH, log["settings_at_start"])
        jenda_rows(rows)
        jenda = [u for u in requests if "/repos/JendaT/fb2k-components-mac-suite/releases" in u]
        github = [u for u in requests if u.startswith("https://api.github.com/")]
        check("exactly 1 GitHub API request for the 5 JendaT components", len(jenda) == 1, jenda)
        print(f"INFO GitHub API requests in total: {len(github)} {github}")
        check("no request outside GitHub, the registry and the catalog",
              all(u.startswith(("https://api.github.com/", "https://raw.githubusercontent.com/", "https://www.foobar2000.org/")) for u in requests), requests)
    elif run == "stub":
        check("settings persisted across the restart", log["settings_at_start"] == PERSISTED, log["settings_at_start"])
        jenda_rows(rows)
        abx = rows.get("foo_abx", {})
        check("older foo_abx resolved through the catalog", abx.get("origin") == "catalog", abx)
        check("foo_abx reports the current catalog version",
              abx.get("installed") == "2.2.1" and abx.get("latest") == "2.2.3" and abx.get("status") == "update_available", abx)
        check("foo_abx download link comes from the catalog page",
              abx.get("download_url", "").endswith("/getcomponent/5ae8a8e80cf7ef18ca0155628f36b458/foo_abx.fb2k-component"), abx)
        paths = stub_paths(stub_log)
        check("stub saw exactly 1 request for the JendaT releases", sum(p.startswith("/repos/JendaT/") for p in paths) == 1, paths)
        check("stub saw exactly 1 catalog request", sum(p.startswith("/components/view/") for p in paths) == 1, paths)
        check("foo_abx keeps the ignored FB2KUpdateSource diagnostic after falling back to the catalog",
              "Invalid FB2KUpdateSource" in abx.get("note", ""), abx)
        check("successful rows carry no stale error", all(r["error"] == "" for r in log["rows"] if r["status"] != "error"), [r for r in log["rows"] if r["status"] != "error" and r["error"]])
        check("every request went to the stub", all(u.startswith("https://127.0.0.1:") for u in requests), requests)
    elif run == "down":
        check("settings persisted across the restart", log["settings_at_start"] == PERSISTED, log["settings_at_start"])
        for name in JL + ["foo_abx"]:
            r = rows.get(name, {})
            check(f"{name} shows Error with a network message", r.get("status") == "error" and r.get("error", "").startswith("Network/API error"), r)
        check("check finished and the log was written", len(log["rows"]) > 0)
    elif run == "ratelimit":
        message = "GitHub rate limit reached, try again after "
        for name in JL + ["foo_component_updater_mac"]:
            r = rows.get(name, {})
            check(f"{name} shows the rate limit message", r.get("status") == "error" and r.get("error", "").startswith(message), r)
        paths = stub_paths(stub_log)
        check("exactly 1 GitHub API request before the limit stopped further calls", sum(p.startswith("/repos/") for p in paths) == 1, paths)
        check("Check Again made no GitHub request", log.get("second_check_requests") is not None
              and not any("/repos/" in u for u in log["second_check_requests"]), log.get("second_check_requests"))
        check("Check Again still shows the limit", log.get("second_check_limited_rows", 0) >= 6, log.get("second_check_limited_rows"))
        abx = rows.get("foo_abx", {})
        check("catalog source unaffected by the GitHub limit", abx.get("status") == "update_available", abx)
    elif run == "badregistry":
        for name, why in (("foo_jl_vectorscope", "owner with a slash"), ("foo_jl_scrobble", "non https url")):
            r = rows.get(name, {})
            check(f"{name} ({why}) is an Invalid source row from the registry",
                  r.get("status") == "error" and r.get("error", "").startswith("Invalid source") and r.get("origin") == "registry", r)
        paths = stub_paths(stub_log)
        check("no request was built from the bad entries", not any(".." in p or "insecure" in p for p in paths), paths)
        check("valid components in the same run are unaffected", rows.get("foo_jl_spectrum", {}).get("status") == "update_available", rows.get("foo_jl_spectrum"))
    elif run == "triggers":
        t = log.get("triggers", {})
        check("foobar2000's own update menu titles (app and Help menu) start no check and open no window",
              t.get("old_menu_titles") == {"begun_delta": 0, "window_open": False}, t.get("old_menu_titles"))
        check("Help > Check for Component Updates... twice in a row: 1 check begun, its completion is recorded as the last check",
              t.get("manual", {}).get("begun_delta") == 1 and t.get("manual", {}).get("last_check_recorded") is True, t.get("manual"))
        check("the command with the window already open starts exactly 1 check", t.get("manual_open_window") == {"begun_delta": 1}, t.get("manual_open_window"))
        p = t.get("periodic", {})
        check("periodic evaluation with the interval elapsed starts exactly 1 more check while the timer keeps firing",
              p.get("begun_delta") == 1 and p.get("ticks_delta", 0) >= 2, p)
        check("the automatic check opened the results window (update found)", p.get("window_open") is True, p)
        a = t.get("attach", {})
        check("toggling Show built in components while waiting keeps the waiting status",
              a.get("status_kept_on_toggle") is True and "already running" in a.get("waiting_status", ""), a)
        check("a window opened while an automatic check runs attaches to it: no second check, results shown when it ends",
              a.get("auto_started") is True and a.get("running_when_window_opened") is True and a.get("attached_while_running") is True
              and a.get("begun_delta") == 1 and a.get("attached_after") is False and a.get("rows_after", 0) > 0, a)
        r = t.get("reopen", {})
        check("manual check: window closed and reopened while it runs, the reopened window attaches and receives the results, no second check",
              r.get("first_window_owned_check") is True and r.get("running_when_reopened") is True and r.get("reopened_attached") is True
              and r.get("begun_delta") == 1 and r.get("attached_after") is False and r.get("rows_after", 0) > 0, r)
        d = t.get("dismiss", {})
        check("automatic check: window attached then closed, the completion does not open a window again although updates were found",
              d.get("auto_started") is True and d.get("window_attached_before_close") is True and d.get("running_after_close") is True
              and d.get("reopened_attached_to_same_check") is True
              and d.get("window_open_after_completion") is False and d.get("begun_delta") == 1, d)
        c = t.get("concurrent", {})
        check("two back to back evaluations start 1 check, the second is refused while it runs",
              c.get("first_started") is True and c.get("second_started") is False and c.get("begun_delta") == 1 and c.get("running_after") is True, c)
    sys.exit(1 if failures else 0)


main()
