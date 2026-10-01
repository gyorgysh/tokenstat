// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Pages;

// A host listener is shared by endpoint within the captured account epoch.
// An older account's close must never disconnect a replacement listener.
internal static class BrowserBridges
{
    private static readonly BrowserBridgePool Pool = new(
        () => BrowserProjectMemory.AccountEpoch.Revision,
        async (peer, host, port) =>
        {
            var answer = await AppServices.Host.CallAsync("proxy.listen", new JsonObject
            { ["peer"] = peer, ["host"] = host, ["port"] = port });
            return Format.Text(answer, "url");
        },
        async (peer, host, port) =>
        {
            await AppServices.Host.CallAsync("proxy.unlisten", new JsonObject
            { ["peer"] = peer, ["host"] = host, ["port"] = port });
        });

    public static Task<string> AcquireAsync(string peer, string host, int port, long generation) =>
        Pool.AcquireAsync(peer, host, port, generation);

    public static Task ReleaseAsync(string peer, string host, int port, long generation) =>
        Pool.ReleaseAsync(peer, host, port, generation);

    internal static Task InvalidateAsync() => Pool.InvalidateAsync();

    internal static bool IsCurrentListener(Uri uri) => Pool.IsCurrentListener(uri);
}
