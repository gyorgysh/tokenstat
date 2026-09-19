// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

// A host listener is shared by endpoint. Closing one tab must not disconnect
// another tab looking at the same remote server.
internal static class BrowserBridges
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly Dictionary<(string Peer, string Host, int Port), (string Url, int Count)> Held = new();

    public static async Task<string> AcquireAsync(string peer, string host, int port)
    {
        await Gate.WaitAsync();
        try
        {
            var key = (peer, host, port);
            if (Held.TryGetValue(key, out var existing))
            {
                Held[key] = (existing.Url, existing.Count + 1);
                return existing.Url;
            }
            var answer = await AppServices.Host.CallAsync("proxy.listen", new JsonObject
            { ["peer"] = peer, ["host"] = host, ["port"] = port });
            var url = Format.Text(answer, "url");
            if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) || !parsed.IsLoopback
                || parsed.Scheme != "http") throw new InvalidOperationException("The host did not return a local browser address.");
            Held[key] = (url, 1);
            return url;
        }
        finally { Gate.Release(); }
    }

    public static async Task ReleaseAsync(string peer, string host, int port)
    {
        await Gate.WaitAsync();
        try
        {
            var key = (peer, host, port);
            if (!Held.TryGetValue(key, out var existing)) return;
            if (existing.Count > 1) { Held[key] = (existing.Url, existing.Count - 1); return; }
            Held.Remove(key);
            await AppServices.Host.CallAsync("proxy.unlisten", new JsonObject
            { ["peer"] = peer, ["host"] = host, ["port"] = port });
        }
        finally { Gate.Release(); }
    }
}
