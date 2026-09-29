// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class TaskBoardOrder
{
    internal static long? InsertionIndex(IEnumerable<JsonNode?> cards, string moving, string column,
        string? anchor = null, bool after = false)
    {
        var rows = cards.ToList();
        if (!rows.Any(row => row?["id"]?.GetValue<string>() == moving)) return null;
        var destination = rows.Where(row => row?["column"]?.GetValue<string>() == column
                && row?["id"]?.GetValue<string>() != moving)
            .OrderBy(row => row?["order"]?.GetValue<long>() ?? 0).ToList();
        if (anchor is null) return destination.Count;
        var index = destination.FindIndex(row => row?["id"]?.GetValue<string>() == anchor);
        return index < 0 ? null : index + (after ? 1 : 0);
    }
}
