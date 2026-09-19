// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
namespace Tokenstat.Navigation;

/// <summary>Preserve both namespaced resource ids in a sidebar selection.</summary>
internal static class LiveRoute
{
    public static string Join(string prefix, string folder, string leaf) =>
        prefix + Uri.EscapeDataString(folder) + ":" + Uri.EscapeDataString(leaf);

    public static bool TrySplit(string tag, string prefix, out string folder, out string leaf)
    {
        folder = leaf = "";
        if (!tag.StartsWith(prefix, StringComparison.Ordinal)) return false;
        var rest = tag[prefix.Length..];
        var cut = rest.IndexOf(':');
        if (cut <= 0 || cut == rest.Length - 1 || rest.IndexOf(':', cut + 1) >= 0) return false;
        folder = Uri.UnescapeDataString(rest[..cut]);
        leaf = Uri.UnescapeDataString(rest[(cut + 1)..]);
        return true;
    }
}
