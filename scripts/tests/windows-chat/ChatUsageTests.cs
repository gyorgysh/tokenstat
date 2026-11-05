// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using Tokenstat.Pages;

static class ChatUsageTests
{
    static JsonNode Json(string value) => JsonNode.Parse(value)!;
    static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    static ChatHistoryBuffer History(string input = "0")
    {
        var history = new ChatHistoryBuffer();
        history.ApplyPage(Json($$$"""{"events":[],"nextOffset":10,"usage":{"input":{{{input}}},"output":0,"cacheRead":0,"cacheWrite":0,"turns":0,"cost":0}}"""), true);
        return history;
    }
    static void Tail(ChatHistoryBuffer history, string value) => history.ApplyTail(
        Json($$$"""{"events":[{{{value}}}],"nextOffset":20}"""), history.Generation);
    public static void Run()
    {
        var quota = (JsonArray)Json("""[{"source":"claude_code","windows":[{"label":"5-hour","percent":0},{"label":"weekly","percent":68},{"label":"bad","percent":-1},{"label":"bad","percent":"3"},{"label":"bad","percent":1e999},{"percent":10}]},{"source":"codex","windows":[{"label":"weekly","percent":99}]}]""");
        var claude = ChatQuotaData.Read(quota, "claude");
        Check(claude?["windows"] is JsonArray { Count: 2 } && claude["windows"]![0]!["percent"]!.GetValue<double>() == 0,
            "Zero allowance stays zero; malformed or unlabeled windows are omitted");
        Check(ChatQuotaData.Read(quota, "muse") is null && ChatQuotaData.Read(quota, "shell") is null
            && ChatQuotaData.Read(quota, "") is null, "Limits never come from a different backend");
        Check(ChatQuotaData.Read(quota, "codex")?["windows"]?[0]?["percent"]?.GetValue<double>() == 99,
            "Current backend selects its own quota");
        claude!["windows"]![0]!["percent"] = 15;
        Check(quota[0]!["windows"]![0]!["percent"]!.GetValue<double>() == 0, "UI readings do not mutate shared responses");
        Check(ChatQuotaData.Read((JsonArray)Json("""[null,17,{}, {"source":"muse","windows":[{},null]}]"""), "muse") is null,
            "Missing vendor readings remain unavailable");
        var overflow = History("9223372036854775807");
        Tail(overflow, """{"event":{"kind":"usage","input":1}}""");
        Check(overflow.Usage?["input"]?.ToJsonString() == "9223372036854775808", "Counters above the signed range must not wrap negative");
        var precise = History("9007199254740993");
        Tail(precise, """{"event":{"kind":"usage","input":2,"cache_read":3,"cache_write":4,"cost_usd":0.5}}""");
        Check(precise.Usage?["input"]?.ToJsonString() == "9007199254740995" && precise.Usage?["cacheRead"]?.ToJsonString() == "3"
            && precise.Usage?["cost"]?.GetValue<double>() == .5, "Exact totals and legacy event aliases survive tail updates");
        var maximum = History("18446744073709551615");
        Tail(maximum, """{"event":{"kind":"usage","input":1}}""");
        Check(maximum.Usage is null && maximum.Events.Count == 1 && maximum.Offset == 20, "Overflow invalidates totals without losing the transcript or cursor");
        foreach (var bad in new[] { "-1", "\"2\"", "1.5", "{}", "18446744073709551616" })
        {
            var invalid = History(bad);
            Check(invalid.Usage is null, "Malformed aggregate counters must be unavailable");
            invalid = History();
            Tail(invalid, $$$"""{"event":{"kind":"usage","input":{{{bad}}}}}""");
            Check(invalid.Usage is null && invalid.Events.Count == 1, "Malformed optional telemetry must not prevent displaying chat events");
        }
        foreach (var kind in new[] { "retainedUsage", "teamAgentSegment" })
        {
            var segment = History("10"); Tail(segment, $$$"""{"kind":"{{{kind}}}"}""");
            Check(segment.Usage is null, "A summary can overlap earlier totals and requires a new aggregate");
        }
        foreach (var cost in new[] { "-0.5", "1e999", "\"0.5\"", "{}" })
        {
            var invalid = History();
            Tail(invalid, $$$"""{"event":{"kind":"usage","costUsd":{{{cost}}}}}""");
            Check(invalid.Usage is null && invalid.Events.Count == 1, "Invalid costs do not block the transcript");
        }
        var missing = History();
        Tail(missing, """{"event":{"kind":"usage","input":null,"costUsd":null}}""");
        Check(missing.Usage is not null && !ChatUsageTotals.HasReportedUsage(missing.Usage), "An event without reported counters does not imply a measured zero");
        missing.ApplyPage(Json("""{"events":[],"nextOffset":30,"usage":{"input":3}}"""), true);
        Check(missing.Usage is null, "Incomplete aggregate totals are unavailable");
        var legacy = new ChatHistoryBuffer();
        legacy.ApplyPage(Json("""{"events":[],"nextOffset":10}"""), true);
        Tail(legacy, """{"event":{"kind":"usage","input":10}}""");
        Check(legacy.Usage is null, "An old host's partial tail is not a whole-conversation total");
        Console.WriteLine("Windows chat usage: exact counters, overflow, malformed telemetry, legacy aliases and summary boundaries pass.");
    }
}
