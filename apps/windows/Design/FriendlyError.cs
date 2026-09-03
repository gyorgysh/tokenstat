// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

namespace Tokenstat.Design;

/// <summary>
/// Friendly error copy. Mirrors Apple FriendlyError.swift rows the app hits.
/// </summary>
internal static class FriendlyError
{
    public static string Display(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "The request could not be completed.";
        var lower = raw.ToLowerInvariant();
        if (lower.Contains("no_such_peer") || lower.Contains("not on the tunnel") || lower.Contains("offline"))
            return "The computer is unreachable. It is asleep, or tokenstat is not running there.";
        if (lower.Contains("timeout") || lower.Contains("host_timeout"))
            return "The machine did not answer in time. Try again.";
        if (lower.Contains("unknown method") || lower.Contains("unknown_method"))
            return "The background helper is older than the app. Restart the app to replace it, then try again.";
        if (lower.Contains("unauthorized") || lower.Contains("forbidden"))
            return "This account or device does not have access to that.";
        if (lower.Contains("quota") || lower.Contains("429") || lower.Contains("rate"))
            return "The service asked us to slow down. Wait a moment and try again.";
        if (lower.Contains("vault") || lower.Contains("not enrolled"))
            return "Unlock the vault on the host to continue.";
        if (lower.Contains("not approved"))
            return "The host has not approved this device yet.";
        if (lower.Contains("paid") || lower.Contains("device limit"))
            return "This needs a paid plan or has hit a device limit. Check Account.";
        return raw;
    }
}
