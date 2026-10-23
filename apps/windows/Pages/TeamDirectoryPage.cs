// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;
using System.Globalization;

namespace Tokenstat.Pages;

internal sealed record TeamDirectoryPage(List<JsonObject> Rows, int? Next)
{
    internal static List<JsonObject> ReadRows(JsonNode answer, string field)
    {
        if (answer[field] is not JsonArray raw || raw.Count > 100 || raw.Any(row => row is not JsonObject)) throw new InvalidDataException();
        var rows = raw.OfType<JsonObject>().ToList();
        var ids = rows.Select(row => row["id"] is JsonValue v && v.TryGetValue<string>(out var id) ? id : "").ToList();
        if (ids.Any(string.IsNullOrEmpty) || ids.Distinct().Count() != rows.Count) throw new InvalidDataException();
        return rows;
    }
    internal static TeamDirectoryPage Read(JsonNode answer, string field, int offset)
    {
        int? next = null;
        if (answer["nextOffset"] is { } value)
        {
            if (value is not JsonValue v || !v.TryGetValue<int>(out var number) || number <= offset || number > 10000) throw new InvalidDataException();
            next = number;
        }
        return new(ReadRows(answer, field), next);
    }
}
internal sealed record TeamBackendOption(string Id, string Label)
{
    internal static IReadOnlyList<TeamBackendOption> Read(JsonNode? value)
    {
        if (value is not JsonArray rows) return [];
        var result = new List<TeamBackendOption>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in rows.Take(32))
        {
            if (entry is not JsonObject row || row["id"] is not JsonValue idValue || !idValue.TryGetValue<string>(out var id)
                || string.IsNullOrEmpty(id) || id.Length > 64 || id.Any(c => c is not (>= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_'))) continue;
            var label = id;
            if (row["label"] is { } rawLabel)
            {
                if (rawLabel is not JsonValue labelValue || !labelValue.TryGetValue<string>(out var name) || string.IsNullOrEmpty(name) || name.Length > 128 || string.IsNullOrWhiteSpace(name)
                    || name.Any(c => char.IsControl(c) || char.GetUnicodeCategory(c) == UnicodeCategory.Format)) continue;
                label = name.Trim();
            }
            if (seen.Add(id)) result.Add(new(id, label));
        }
        return result;
    }
}
internal sealed record TeamCatalogPage(List<JsonObject> Rows, string? Next, IReadOnlyList<TeamBackendOption> Backends)
{
    internal static TeamCatalogPage Read(JsonNode answer, string checkout, string? cursor)
    {
        string? next = null;
        if (answer["nextCursor"] is { } value)
        {
            if (value is not JsonValue v || !v.TryGetValue<string>(out next) || string.IsNullOrEmpty(next) || next == cursor) throw new InvalidDataException();
        }
        var rows = TeamDirectoryPage.ReadRows(answer, "shares");
        if (rows.Any(row => row["checkoutId"] is not JsonValue v || !v.TryGetValue<string>(out var id) || id != checkout)) throw new InvalidDataException();
        return new(rows, next, TeamBackendOption.Read(answer["backends"]));
    }
    internal static List<JsonObject> Append(IEnumerable<JsonObject> before, IEnumerable<JsonObject> incoming) => before.Concat(incoming).DistinctBy(row => row["id"]!.GetValue<string>()).ToList();
}
