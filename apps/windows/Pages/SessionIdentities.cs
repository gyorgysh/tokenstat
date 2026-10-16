// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>Optional, validated native transcript references. Resume credentials are never a fallback.</summary>
internal sealed record SessionIdentity(string Backend, string Id, string Status, string? SourceConversationId);
internal sealed record SessionIdentities(IReadOnlyList<SessionIdentity> Entries, long Total, bool Truncated, string? ArchivePath, string? TranscriptPath)
{
    internal IReadOnlyList<string> SourceConversationIds { get; init; } = [];
    internal bool SameProjection(SessionIdentities? other) => other is not null && Total == other.Total && Truncated == other.Truncated
        && Entries.SequenceEqual(other.Entries) && SourceConversationIds.SequenceEqual(other.SourceConversationIds);

    internal static SessionIdentities Read(JsonNode? value)
    {
        var entries = new Dictionary<(string Backend, string Id), SessionIdentity>();
        var sources = new HashSet<string>(StringComparer.Ordinal);
        var scanned = 0;
        if (value is JsonObject && value["entries"] is JsonArray array)
        {
            foreach (var row in array.Take(256).OfType<JsonObject>())
            {
                var backend = Text(row, "backend");
                var id = Text(row, "id");
                if (!ValidNativeId(backend, id)) continue;
                var source = Text(row, "sourceConversationId");
                if (!ValidReference(source)) source = "";
                if (source.Length > 0) sources.Add(source);
                var status = Text(row, "status");
                var entry = new SessionIdentity(backend, id, status is "current" or "saved" ? status : "historical", source);
                var key = (backend, id);
                if (!entries.TryGetValue(key, out var previous) || Rank(entry.Status) < Rank(previous.Status)) entries[key] = entry;
            }
            scanned = array.Count;
        }
        var total = value is JsonObject && value["total"] is JsonValue number && number.TryGetValue<long>(out var count) ? Math.Max(0, count) : entries.Count;
        var truncated = value is JsonObject && value["truncated"] is JsonValue flag && flag.TryGetValue<bool>(out var partial) && partial;
        var ordered = entries.Values.OrderBy(entry => Rank(entry.Status)).Take(64).ToArray();
        return new(ordered, Math.Max(total, entries.Count), truncated || scanned > 256 || entries.Count > 64 || total > ordered.Length,
            Text(value, "archivePath"), Text(value, "transcriptPath")) { SourceConversationIds = sources.Take(64).ToArray() };
    }

    internal static bool ValidNativeId(string backend, string id)
    {
        if (backend is "opencode" or "opencode2")
            return id.Length == 30 && id.StartsWith("ses_", StringComparison.Ordinal)
                && id.AsSpan(4, 12).IndexOfAnyExcept("0123456789abcdefABCDEF") < 0
                && id.AsSpan(16).IndexOfAnyExcept("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") < 0;
        return backend is "claude" or "codex" or "cursor" or "muse" or "grok" or "agy"
            && Guid.TryParseExact(id, "D", out var guid) && guid != Guid.Empty;
    }

    private static int Rank(string status) => status == "current" ? 0 : status == "saved" ? 1 : 2;
    private static bool ValidReference(string value) => value.Length is > 0 and <= 512
        && !value.Any(char.IsWhiteSpace) && !value.Any(char.IsControl) && value.IndexOfAny(['/', '\\', '{', '[']) < 0;
    private static string Text(JsonNode? row, string key) => row is JsonObject && row[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : "";
}
