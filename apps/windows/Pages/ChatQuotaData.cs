// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class ChatQuotaData
{
    private static string Text(JsonNode? node, string key) => node is JsonObject obj && obj[key] is JsonValue value
        && value.TryGetValue<string>(out var text) ? text : "";
    private static string Canonical(string id) => id switch {
        "claude" => "claude_code", "opencode2" => "opencode", "agy" => "antigravity",
        _ when id.StartsWith("antigravity", StringComparison.Ordinal) => "antigravity", _ => id,
    };
    internal static JsonObject? Read(JsonArray readings, string backend)
    {
        if (string.IsNullOrWhiteSpace(backend)) return null;
        var provider = readings.OfType<JsonObject>().FirstOrDefault(item => Canonical(Text(item, "source")) == Canonical(backend));
        if (provider is null) return null;
        var windows = new JsonArray();
        foreach (var window in (provider["windows"] as JsonArray ?? new()).OfType<JsonObject>())
            if (!string.IsNullOrWhiteSpace(Text(window, "label")) && ChatUsageTotals.Amount(window["percent"]) is not null)
                windows.Add(window.DeepClone());
        if (windows.Count == 0) return null;
        var copy = (JsonObject)provider.DeepClone(); copy["windows"] = windows; return copy;
    }
}
