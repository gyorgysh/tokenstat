// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

/// <summary>Keep pending CLI probes with their open conversation and current catalog row.</summary>
internal sealed class ChatSignInChecks
{
    private readonly HashSet<(int Generation, string Backend)> _active = [];

    public async Task<bool> CheckAsync(JsonNode backend, int generation,
        Func<string, Task<JsonNode>> check, Func<int> currentGeneration,
        Func<string, JsonNode?> currentBackend)
    {
        var id = Text(backend, "id");
        var launcher = Text(backend, "launcherId");
        var key = (generation, id);
        if (!_active.Add(key)) return false;
        try
        {
            var status = await check(launcher);
            if (generation != currentGeneration()) return false;
            // A catalog refresh can replace the node while a probe is running.
            var current = currentBackend(id);
            if (current is null || Text(current, "launcherId") != launcher) return false;
            var readiness = Text(status, "readiness", "unknown");
            var verified = status["checked"]?.GetValue<bool>() == true;
            if (Text(current, "readiness") == readiness &&
                (current["signInVerified"]?.GetValue<bool>() == true) == verified) return false;
            current["readiness"] = readiness;
            current["signInVerified"] = verified;
            return true;
        }
        finally { _active.Remove(key); }
    }

    private static string Text(JsonNode node, string key, string fallback = "") =>
        node[key]?.GetValue<string>() ?? fallback;
}
