// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal enum AutomationJobSort { Name, NextRun, LastRun }
internal enum AutomationRunSort { Name, Started, Result }
internal enum AutomationJobFilter { All, Enabled, Paused, Failing }

/// <summary>Sort the host's timestamps, not their localized display labels.</summary>
internal static class AutomationListLogic
{
    private static string Text(JsonNode? row, string key) => row?[key]?.GetValue<string>() ?? "";
    private static long Time(JsonNode? row, string key)
    {
        if (row?[key] is not JsonValue value) return 0;
        if (value.TryGetValue<long>(out var time)) return time;
        return value.TryGetValue<int>(out var small) ? small : 0;
    }
    private static bool Enabled(JsonNode? job) => job?["enabled"]?.GetValue<bool>() == true;

    public static JsonNode? LastRun(JsonNode job, IEnumerable<JsonNode?> runs)
    {
        var id = Text(job, "id");
        var matches = runs.Where(run => Text(run, "jobId") == id).ToList();
        var lastId = Text(job, "lastRunId");
        return matches.FirstOrDefault(run => lastId.Length > 0 && Text(run, "id") == lastId)
            ?? matches.OrderByDescending(run => Time(run, "startedAtMs"))
                .ThenByDescending(run => Text(run, "id"), StringComparer.Ordinal).FirstOrDefault();
    }

    public static bool MatchesFilter(JsonNode job, IEnumerable<JsonNode?> runs, AutomationJobFilter filter) => filter switch
    {
        AutomationJobFilter.Enabled => Enabled(job),
        AutomationJobFilter.Paused => !Enabled(job),
        AutomationJobFilter.Failing => Text(LastRun(job, runs), "status") == "error",
        _ => true,
    };

    public static List<JsonNode> SortJobs(IEnumerable<JsonNode> jobs, AutomationJobSort order, bool descending)
    {
        var rows = jobs.ToList();
        rows.Sort((left, right) =>
        {
            int compared;
            if (order == AutomationJobSort.Name)
                compared = StringComparer.OrdinalIgnoreCase.Compare(Text(left, "name"), Text(right, "name"));
            else
            {
                var key = order == AutomationJobSort.NextRun ? "nextRunAtMs" : "lastRunAtMs";
                var a = Time(left, key);
                var b = Time(right, key);
                if (order == AutomationJobSort.NextRun) { if (!Enabled(left)) a = 0; if (!Enabled(right)) b = 0; }
                // Missing times stay below real dates in either direction.
                if ((a <= 0) != (b <= 0)) return a <= 0 ? 1 : -1;
                compared = a.CompareTo(b);
            }
            if (compared != 0) return descending ? -compared : compared;
            compared = StringComparer.OrdinalIgnoreCase.Compare(Text(left, "name"), Text(right, "name"));
            return compared != 0 ? compared : StringComparer.Ordinal.Compare(Text(left, "id"), Text(right, "id"));
        });
        return rows;
    }

    public static string Duration(long started, long ended)
    {
        if (started <= 0 || ended <= started) return "—";
        var seconds = (ended - started) / 1000;
        return $"{seconds / 3600:D2}:{seconds / 60 % 60:D2}:{seconds % 60:D2}";
    }

    public static List<JsonNode> SortRuns(IEnumerable<JsonNode> runs, AutomationRunSort order, bool descending)
    {
        var rows = runs.ToList();
        rows.Sort((left, right) =>
        {
            var compared = order switch
            {
                AutomationRunSort.Name => StringComparer.OrdinalIgnoreCase.Compare(Text(left, "name"), Text(right, "name")),
                AutomationRunSort.Result => StringComparer.OrdinalIgnoreCase.Compare(Text(left, "status"), Text(right, "status")),
                _ => Time(left, "startedAtMs").CompareTo(Time(right, "startedAtMs")),
            };
            if (compared != 0) return descending ? -compared : compared;
            return StringComparer.Ordinal.Compare(Text(left, "id"), Text(right, "id"));
        });
        return rows;
    }
}
