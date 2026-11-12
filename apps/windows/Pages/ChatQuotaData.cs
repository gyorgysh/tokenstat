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
    private static string? Tag(string label)
    {
        var text = string.Join(' ', label.Trim().ToLowerInvariant().Replace("·", " · ").Replace('-', ' ')
            .Split(' ', StringSplitOptions.RemoveEmptyEntries));
        if (text is "5 hour" or "5h" || text.EndsWith("· 5 hour", StringComparison.Ordinal) || text.EndsWith("· 5h", StringComparison.Ordinal)) return "5h";
        if (text is "weekly" or "7d" or "7 day" || text.EndsWith("· weekly", StringComparison.Ordinal) || text.Contains("per week", StringComparison.Ordinal)) return "7d";
        return null;
    }

    /// <summary>
    /// The 5h and 7d figures an agent row shows, as the Mac and Android pickers
    /// do. Codex reports an account week beside the model's own, so its general
    /// windows come first.
    /// </summary>
    internal static IReadOnlyList<(string Tag, double Percent)> Headline(JsonObject provider)
    {
        var windows = (provider["windows"] as JsonArray ?? new()).OfType<JsonObject>().ToList();
        var general = Canonical(Text(provider, "source")) == "codex"
            ? windows.Where(w => string.Equals(Text(w, "scope"), "general", StringComparison.OrdinalIgnoreCase)).ToList() : [];
        var unscoped = windows.Where(w => string.IsNullOrEmpty(Text(w, "scope"))).ToList();
        var pool = general.Count > 0 ? general : unscoped.Count > 0 ? unscoped : windows;
        var rows = new List<(string, double)>();
        foreach (var tag in new[] { "5h", "7d" })
            if (pool.FirstOrDefault(w => Tag(Text(w, "label")) == tag) is { } window
                && ChatUsageTotals.Amount(window["percent"]) is double percent)
                rows.Add((tag, percent));
        return rows;
    }

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
