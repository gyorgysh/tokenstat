// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Navigation;

internal static class RemoteWorkspaceParameters
{
    public static JsonObject Forward(JsonNode? parameters, string workspaceId, string innerId)
    {
        var forwarded = parameters?.DeepClone() as JsonObject ?? new JsonObject();
        forwarded["id"] = innerId;
        // Forge methods name their owner workspaceId instead of id.
        if (forwarded["workspaceId"] is JsonValue value
            && value.TryGetValue<string>(out var owner) && owner == workspaceId)
            forwarded["workspaceId"] = innerId;
        return forwarded;
    }
}
