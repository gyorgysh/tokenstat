// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

internal static class ChatRoutingChoices
{
    // A preferred destination can be saved independently of the fallback list.
    // Keep that choice, and use the route instance when edits should follow it.
    public static List<JsonObject?> Preferred(IReadOnlyList<JsonObject> routes, JsonObject? preferred)
    {
        var choices = new List<JsonObject?> { null };
        if (preferred is not null && !routes.Any(route => JsonNode.DeepEquals(route, preferred)))
            choices.Add(preferred);
        choices.AddRange(routes);
        return choices;
    }

    public static DateTimeOffset Moment(long milliseconds) => DateTimeOffset.FromUnixTimeMilliseconds(
        Math.Clamp(milliseconds, -62135596800000L, 253402300799999L));
}
