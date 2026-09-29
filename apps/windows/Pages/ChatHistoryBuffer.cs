// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
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
    public JsonObject? Usage { get; private set; }
    public int Generation { get; private set; }

    public void Reset()
    {
        Generation++;
        Events = new(); Offset = 0;
        Cursor = null; TailCursor = null; HasEarlier = false; Usage = null;
    }

    public bool ApplyPage(JsonNode page, bool replace)
    {
        var rows = page["events"] as JsonArray ?? new();
        bool reset = replace || page["reset"]?.GetValue<bool>() == true;
        if (reset)
        {
            Generation++;
            Events = (JsonArray)rows.DeepClone();
            Offset = page["nextOffset"]?.GetValue<ulong>() ?? 0;
            TailCursor = page["tailCursor"]?.GetValue<string>();
            Usage = page["usage"]?.DeepClone() as JsonObject;
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
            var ev = row?["event"];
            if (Usage is null || ev?["kind"]?.GetValue<string>() != "usage") continue;
            foreach (var key in new[] { "input", "output", "cacheRead", "cacheWrite" })
                Usage[key] = Number(Usage, key) + Number(ev, key);
            Usage["turns"] = Number(Usage, "turns") + 1;
            Usage["cost"] = (Usage["cost"]?.GetValue<double>() ?? 0) + (ev?["costUsd"]?.GetValue<double>() ?? 0);
        }
        Offset = chunk["nextOffset"]?.GetValue<ulong>() ?? Offset;
        TailCursor = chunk["tailCursor"]?.GetValue<string>();
        return true;
    }

    private static long Number(JsonNode? node, string key) => node?[key]?.GetValue<long>() ?? 0;
}
