#!/usr/bin/env python3
"""Assertions for the M1 batch (Scripts/test_batch.sh). Prints PASS/FAIL per check.

Usage: test_batch_check.py <run> <autotest.json> [<stub.log>]
Runs: real, stub, down, ratelimit, badregistry, triggers
"""
import json
import sys

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
    ie = snap["insert_example"]
    check("Insert Example is enabled on an empty box, disabled once filled, and inserts a valid entry",
          ie["enabled_when_empty"] and ie["disabled_when_filled"] and ie["parses"], ie)
    check("expanding Custom sources moves neither the page nor the view frame",
          snap["prefs_geometry_collapsed"] == snap["prefs_geometry_expanded"] and snap["prefs_geometry_collapsed"].startswith("page y=20 x=20"), snap)
    check("off screen snapshots written",
          snap["prefs_light"] and snap["prefs_dark"] and snap["prefs_expanded"]
          and snap["prefs_help_popover"] and snap["prefs_sources_popover"]
          and snap["results_default_rows"] == rw["visible_rows"] and snap["results_core_shown_rows"] == rw["rows"], snap)
    check("apply: valid sources saved", log["apply"]["valid_accepted"] and log["apply"]["entries_after_valid"] == 1, log["apply"])
    check("apply: invalid sources rejected, old value kept",
          log["apply"]["invalid_rejected"] and log["apply"]["invalid_message"] and log["apply"]["entries_after_invalid"] == 1, log["apply"])
    check("settings written by the run", log["settings_set"] == {"auto_check": True, "interval_days": 11, "include_prereleases": True, "sources": 1}, log["settings_set"])


JL = ["foo_jl_spectrum", "foo_jl_vectorscope", "foo_jl_simplaylist", "foo_jl_scrobble", "foo_jl_wave_seekbar"]
FRESH = {"auto_check": True, "interval_days": 7, "include_prereleases": False, "sources": 0}
PERSISTED = {"auto_check": True, "interval_days": 11, "include_prereleases": True, "sources": 1}


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
# The checked component and JendaT's suite are one request each; triggers also counts the 5 later
# checks (menu app title, Help title, periodic, attach, manual reopen, dismiss, concurrent) of the scenario.
EXPECTED_GITHUB_REQUESTS = {"real": 2, "stub": 2, "down": 2, "ratelimit": 1, "badregistry": 2, "triggers": 16}


def github_requests(log, stub_log, run):
    # "triggers" counts at the end of the run on the stub (the log of requests is taken after the first check).
    if run == "real":
        return len([u for u in log["requests"] if u.startswith("https://api.github.com/") and "/repos/" in u])
    if run == "down":
        return len([u for u in log["requests"] if "/repos/" in u])
    return len([p for p in stub_paths(stub_log) if p.startswith("/repos/")])


def refused(log, name, text):
    o = log["outcomes"].get(name, {})
    check(f"{name}: refused with a message about \"{text}\"", o.get("ok") is False and text in o.get("message", ""), o)


def m2(run, log, previous_pid):
    before, after, o = log["before"], log["after"], log["outcomes"]
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
                           ("notzip", "not a valid package"), ("missing", "download failed")):
            refused(log, name, text)
        check("nothing staged, installed version and backup unchanged",
              (after["staged"], after["installed_version"], after["backup_version"]) == (False, "2.2.1", "2.2.3"), after)
        menu = log["restore_menu"]
        check("context menu: Restore Previous (2.2.3) is enabled for foo_abx, disabled without a backup",
              (menu["title"], menu["enabled"], menu["title_without_backup"], menu["enabled_without_backup"]) == ("Restore Previous (2.2.3)", True, "Restore Previous", False), menu)
    elif run == "m2-team":
        refused(log, "other_developer", "different developer")
        check("a package from the same Team ID is staged", o["same_developer"]["ok"] is True and after["staged"] is True, log)
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
        check("app menu title twice plus an unrelated title: 1 check begun, 2 triggers handled",
              t.get("menu_app", {}).get("begun_delta") == 1 and t.get("menu_app", {}).get("handled_delta") == 2, t.get("menu_app"))
        check("a completed manual check (from the foobar2000 menu item) records the last check time",
              t.get("menu_app", {}).get("last_check_recorded") is True, t.get("menu_app"))
        check("Help menu title starts exactly 1 check", t.get("menu_help") == {"begun_delta": 1, "handled_delta": 1}, t.get("menu_help"))
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
