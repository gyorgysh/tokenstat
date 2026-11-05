// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>Bounded initial history, older pages, and generation-aware live tails.</summary>
internal sealed class ChatHistoryBuffer
{
    public JsonArray Events { get; set; } = new();
    public ulong Offset { get; set; }
    public string? Cursor { get; private set; }
    public string? TailCursor { get; private set; }
    public bool HasEarlier { get; private set; }
    public bool HasMore { get; private set; }
    public JsonObject? Usage { get; private set; }
    public int Generation { get; private set; }

    public void Reset()
    {
        Generation++;
        Events = new(); Offset = 0;
        Cursor = null; TailCursor = null; HasEarlier = false; HasMore = false; Usage = null;
    }

    public bool ApplyPage(JsonNode page, bool replace)
    {
        var rows = page["events"] as JsonArray ?? new();
        bool reset = replace || page["reset"]?.GetValue<bool>() == true;
        if (reset)
        {
            Generation++;
            HasMore = false;
            Events = (JsonArray)rows.DeepClone();
            Offset = page["nextOffset"]?.GetValue<ulong>() ?? 0;
            TailCursor = page["tailCursor"]?.GetValue<string>();
            Usage = ChatUsageTotals.Read(page["usage"]);
        }
        else
        {
            var combined = (JsonArray)rows.DeepClone();
            foreach (var row in Events) combined.Add(row?.DeepClone());
            Events = combined;
        }
        Cursor = page["cursor"]?.GetValue<string>();
        HasEarlier = page["hasEarlier"]?.GetValue<bool>() == true && !string.IsNullOrEmpty(Cursor);
        return reset;
    }

    public bool ApplyTail(JsonNode chunk, int generation)
    {
        if (generation != Generation || chunk["reset"]?.GetValue<bool>() == true) return false;
        foreach (var row in chunk["events"] as JsonArray ?? new())
        {
            Events.Add(row?.DeepClone());
            if (Usage is not null) Usage = ChatUsageTotals.AddRow(Usage, row);
        }
        var previousOffset = Offset;
        Offset = chunk["nextOffset"]?.GetValue<ulong>() ?? Offset;
        HasMore = chunk["hasMore"]?.GetValue<bool>() == true && Offset > previousOffset;
        TailCursor = chunk["tailCursor"]?.GetValue<string>();
        return true;
    }
}

/// <summary>Verified whole-conversation counts; invalid telemetry never blocks history.</summary>
internal static class ChatUsageTotals
{
    private static readonly string[] Counts = ["input", "output", "cacheRead", "cacheWrite", "turns"];

    internal static ulong? Count(JsonNode? value) => value is JsonValue number && number.GetValueKind() == JsonValueKind.Number
        && ulong.TryParse(number.ToJsonString(), NumberStyles.None, CultureInfo.InvariantCulture, out var count) ? count : null;

    internal static double? Amount(JsonNode? value) => value is JsonValue number && number.GetValueKind() == JsonValueKind.Number
        && double.TryParse(number.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var amount)
        && double.IsFinite(amount) && amount >= 0 ? amount : null;

    internal static JsonObject? Read(JsonNode? value)
    {
        if (value is not JsonObject obj || Counts.Any(key => Count(obj[key]) is null) || Amount(obj["cost"]) is null) return null;
        return (JsonObject)obj.DeepClone();
    }

    internal static bool HasReportedUsage(JsonObject value) => Counts.Where(key => key != "turns").Any(key => Count(value[key]) > 0)
        || Amount(value["cost"]) > 0;

    internal static JsonObject? AddRow(JsonObject total, JsonNode? row)
    {
        if (row is not JsonObject record) return total;
        if (record["kind"] is JsonValue kind && kind.TryGetValue<string>(out var name) && name is "retainedUsage" or "teamAgentSegment") return null;
        if (record["event"] is not JsonObject ev || ev["kind"] is not JsonValue tag || !tag.TryGetValue<string>(out var eventName) || eventName != "usage") return total;
        var next = new JsonObject();
        foreach (var key in Counts)
        {
            var alias = key switch { "cacheRead" => "cache_read", "cacheWrite" => "cache_write", _ => key };
            var raw = ev.ContainsKey(key) ? ev[key] : ev[alias];
            var increment = key == "turns" ? 1UL : raw is null ? 0UL : Count(raw);
            var current = Count(total[key]);
            if (increment is null || current is null || increment > ulong.MaxValue - current) return null;
            next[key] = current.Value + increment.Value;
        }
        var cost = ev.ContainsKey("costUsd") ? ev["costUsd"] : ev["cost_usd"];
        var delta = cost is null ? 0 : Amount(cost);
        var amount = Amount(total["cost"]) + delta;
        if (amount is not double valid || !double.IsFinite(valid)) return null;
        next["cost"] = valid;
        return next;
    }
}
