// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
static JsonObject Job(string id, string name, long next = 0, bool enabled = true) => new()
{ ["id"] = id, ["name"] = name, ["enabled"] = enabled, ["nextRunAtMs"] = next };
static string Id(JsonNode row) => row["id"]!.GetValue<string>();
var jobs = new[] { Job("none", "Never"), Job("late", "Alpha", 1000), Job("early", "Zulu", 10), Job("paused", "Paused", 5, false) };
Check(AutomationListLogic.SortJobs(jobs, AutomationJobSort.NextRun, false).Select(Id).SequenceEqual(new[] { "early", "late", "none", "paused" }),
    "Next runs did not sort chronologically or paused/missing dates interrupted real dates");
Check(AutomationListLogic.SortJobs(jobs, AutomationJobSort.NextRun, true).Select(Id).Take(2).SequenceEqual(new[] { "late", "early" }),
    "Descending dates sorted display labels instead of host timestamps");
var runs = new JsonNode[] {
    new JsonObject { ["id"] = "old", ["jobId"] = "early", ["startedAtMs"] = 10, ["status"] = "error" },
    new JsonObject { ["id"] = "latest", ["jobId"] = "early", ["startedAtMs"] = 1000, ["status"] = "ok" },
};
Check(!AutomationListLogic.MatchesFilter(jobs[2], runs, AutomationJobFilter.Failing), "An old failure hid the latest successful outcome");
jobs[2]["lastRunId"] = "old";
Check(AutomationListLogic.MatchesFilter(jobs[2], runs, AutomationJobFilter.Failing), "The host's explicit last run was ignored");
Check(AutomationListLogic.MatchesFilter(jobs[3], runs, AutomationJobFilter.Paused), "Paused jobs did not match their filter");
Check(AutomationListLogic.SortRuns(runs, AutomationRunSort.Started, true).Select(Id).SequenceEqual(new[] { "latest", "old" }), "Run dates were not newest first");
Check(AutomationListLogic.LastRun(jobs[0], runs) is null, "A job inherited another job's outcome");
Console.WriteLine("Automations: chronological sorting, missing/paused dates, last-run identity and filters passed");

Check(AutomationListLogic.Duration(1000, 25 * 3600000L + 1000) == "25:00:00", "A long run wrapped its duration after one day");

var editor = new AutomationEditorState<JsonObject> { Draft = new JsonObject { ["name"] = "Old", ["prompt"] = "Old prompt" }, Revision = 7 };
editor.Refresh(new JsonObject { ["name"] = "Host name", ["prompt"] = "New host prompt" }, 8, dirty: false);
editor.Draft!["name"] = "Local name";
Check(editor.Draft["prompt"]!.GetValue<string>() == "New host prompt" && editor.Revision == 8, "Clean refresh paired a stale payload with a fresh revision");
editor.Refresh(new JsonObject { ["name"] = "Another host name", ["prompt"] = "Another host prompt" }, 9, dirty: true);
Check(editor.Draft["name"]!.GetValue<string>() == "Local name" && editor.Revision == 8, "Dirty refresh lost the local draft or advanced its expected revision");
var lifetime = new OperationEpoch();
var mounted = lifetime.Capture();
lifetime.Advance(); // Unloaded before the initial host read completes.
Check(!mounted.IsCurrent && lifetime.Capture().IsCurrent, "A late initial load started a hidden automation poller");
