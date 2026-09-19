// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Globalization;
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
    public const int FolderPickerMinProtocol = 7;
    public const int CloneRepositoryMinProtocol = 7;

    public static long? ProtocolOf(JsonNode? status)
    {
        if (status is not JsonObject)
        {
            return null;
        }
        // The sessionless host response uses protocolVersion as a string.
        // Also accept numeric versions and older cached status field names.
        foreach (var key in new[] { "protocolVersion", "protocol", "version" })
        {
            if (status[key] is not JsonValue value)
            {
                continue;
            }
            if (value.TryGetValue<long>(out var number) && number > 0)
            {
                return number;
            }
            if (value.TryGetValue<int>(out var small) && small > 0)
            {
                return small;
            }
            if (value.TryGetValue<string>(out var text)
                && long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out number)
                && number > 0)
            {
                return number;
            }
        }
        return null;
    }

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
            return ProtocolOf(answer);
        }
        catch
        {
            return null;
        }
    }
}
