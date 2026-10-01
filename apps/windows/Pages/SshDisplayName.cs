// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Net;

namespace Tokenstat.Pages;

/// <summary>Connection titles use friendly names, including after platform caching.</summary>
internal static class SshDisplayName
{
    internal static string Private(string? label, string fallback)
    {
        var value = label?.Trim() ?? "";
        if (value.Length == 0 || value.Contains('@') || IPAddress.TryParse(value, out _)) return fallback;
        if (Uri.TryCreate(value.Contains("://", StringComparison.Ordinal) ? value : "ssh://" + value, UriKind.Absolute, out var endpoint)
            && endpoint.HostNameType is UriHostNameType.IPv4 or UriHostNameType.IPv6) return fallback;
        return value;
    }
}
