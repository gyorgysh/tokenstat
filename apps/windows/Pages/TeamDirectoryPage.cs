// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

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
internal sealed record TeamCatalogPage(List<JsonObject> Rows, string? Next)
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
        return new(rows, next);
    }
    internal static List<JsonObject> Append(IEnumerable<JsonObject> before, IEnumerable<JsonObject> incoming) => before.Concat(incoming).DistinctBy(row => row["id"]!.GetValue<string>()).ToList();
}
