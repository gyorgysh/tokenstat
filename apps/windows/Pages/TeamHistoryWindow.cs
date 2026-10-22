// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text;
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal sealed record TeamHistoryWindow(IReadOnlyList<JsonObject> Events, bool Truncated = false)
{
    internal TeamHistoryWindow Merge(IEnumerable<JsonObject> incoming, bool earlier, int byteLimit = 8 * 1024 * 1024, int rowLimit = 2000)
    {
        var combined = (earlier ? incoming.Concat(Events) : incoming).ToList();
        var kept = new List<JsonObject>();
        var bytes = 0;
        foreach (var row in combined)
        {
            bytes += Encoding.UTF8.GetByteCount(row.ToJsonString());
            if (kept.Count == rowLimit || bytes > byteLimit) break;
            // JsonNode parents retain the rest of a response. Detach the kept
            // rows, so the window's limit also bounds retained page data.
            kept.Add(row.DeepClone().AsObject());
        }
        return new(kept, earlier && Truncated || kept.Count < combined.Count);
    }
}
