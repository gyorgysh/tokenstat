// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Text.Json.Nodes;

namespace Tokenstat.Navigation;

/// <summary>
/// Remote feature gate. Mirrors Apple ClientRemoteFeatureGate: a phone may
/// update before its paired host, so check the peer's sessionless protocol
/// before mounting a host-owned feature instead of showing unknown-method.
/// </summary>
internal static class RemoteFeatureGate
{
    public const int ChatMinProtocol = 4;
    public const int PullsMinProtocol = 3;

    public static long? ProtocolOf(JsonNode? status) =>
        status?["protocol"]?.GetValue<long?>()
        ?? status?["protocolVersion"]?.GetValue<long?>();

    public static bool SupportsChat(long? protocol) => protocol is null || protocol >= ChatMinProtocol;
    public static bool SupportsPulls(long? protocol) => protocol is null || protocol >= PullsMinProtocol;

    /// <summary>
    /// Workbench gates. Mirrors the Apple minimumProtocol table: 17 adds
    /// revision-checked task editing, 18 adds checked task deletion, 19 adds
    /// create-once tasks, 20 adds checked task runs with launch receipts, 21
    /// adds revision-checked automation edits with create/run receipts, and 22
    /// adds revision-checked workflow edits.
    /// </summary>
    public const int TaskEditingMinProtocol = 17;
    public const int TaskDeletionMinProtocol = 18;
    public const int TaskCreationMinProtocol = 19;
    public const int TaskExecutionMinProtocol = 20;
    public const int AutomationReceiptsMinProtocol = 21;
    public const int WorkflowEditingMinProtocol = 22;

    public static bool SupportsProtocol(long? protocol, int minimum) =>
        protocol is null || protocol >= minimum;

    public static async Task<long?> PeerProtocolAsync(string peer)
    {
        try
        {
            var answer = await AppServices.Host.CallAsync(
                "remote.call",
                new JsonObject
                {
                    ["peer"] = peer,
                    ["method"] = "protocol",
                    ["params"] = new JsonObject(),
                });
            return answer?["protocol"]?.GetValue<long?>()
                ?? answer?["version"]?.GetValue<long?>();
        }
        catch
        {
            return null;
        }
    }
}
