// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Tokenstat.Pages;

namespace Tokenstat.Navigation;

/// <summary>Explicit desktop navigation. URLs cannot carry shell commands.</summary>
internal sealed record DesktopOpenRequest(DesktopWorkbenchTool Tool, string WorkspaceId,
    string? InspectorTab, Uri? BrowserUrl, string? SessionId, bool NewTerminal, string? CommitId)
{
    public static DesktopOpenRequest? Parse(string? value)
    {
        if (value is null || value.Length > 16384 || !Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme != "tokenstat" || uri.Host != "workbench" || uri.AbsolutePath != "/open"
            || uri.UserInfo.Length != 0 || !uri.IsDefaultPort || uri.Fragment.Length != 0) return null;
        var query = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in uri.Query.TrimStart('?').Split('&'))
        {
            var pair = part.Split('=', 2);
            if (pair.Length != 2) return null;
            string key, item;
            try { key = Uri.UnescapeDataString(pair[0].Replace('+', ' ')); item = Uri.UnescapeDataString(pair[1].Replace('+', ' ')); }
            catch (UriFormatException) { return null; }
            if (!query.TryAdd(key, item)) return null;
        }
        if (!query.TryGetValue("workspace", out var workspace) || !ValidWorkspaceId(workspace)
            || !query.TryGetValue("tool", out var name)) return null;
        var tool = name switch
        {
            "inspector" => DesktopWorkbenchTool.Inspector, "changes" => DesktopWorkbenchTool.Changes,
            "browser" => DesktopWorkbenchTool.Browser, "terminal" => DesktopWorkbenchTool.Terminal,
            _ => (DesktopWorkbenchTool?)null,
        };
        if (tool is null) return null;
        string[] extras = tool switch
        {
            DesktopWorkbenchTool.Inspector => ["tab"], DesktopWorkbenchTool.Browser => ["url"],
            DesktopWorkbenchTool.Terminal => ["session", "new"], DesktopWorkbenchTool.Changes => ["commit"], _ => [],
        };
        if (query.Keys.Any(key => key is not ("workspace" or "tool") && !extras.Contains(key))) return null;
        var tab = query.GetValueOrDefault("tab");
        if (tab is not null && tab is not ("files" or "changes" or "history")) return null;
        Uri? browser = null;
        if (query.TryGetValue("url", out var address)
            && (address.Length > 8192 || !Uri.TryCreate(address, UriKind.Absolute, out browser)
                || browser.Scheme is not ("http" or "https") || browser.Host.Length == 0 || browser.UserInfo.Length != 0)) return null;
        var session = query.GetValueOrDefault("session");
        if (session is not null && !ValidSessionId(session)) return null;
        var spawn = query.GetValueOrDefault("new");
        if (spawn is not null && (spawn != "1" || session is not null)) return null;
        var commit = query.GetValueOrDefault("commit");
        if (commit is not null && (commit.Length is not (40 or 64) || !commit.All(char.IsAsciiHexDigit))) return null;
        return new(tool.Value, workspace, tab, browser, session, spawn == "1", commit);
    }
    private static bool ValidSessionId(string value) => value.Length is > 0 and <= 512
        && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.' or ':');
    // Registry IDs are paths. Exact registered-project lookup, rather than
    // an ASCII session-ID grammar, proves ownership before navigation.
    private static bool ValidWorkspaceId(string value) => !string.IsNullOrWhiteSpace(value)
        && System.Text.Encoding.UTF8.GetByteCount(value) <= 4096
        && !value.Any(c => c < 32 || c is >= '\u007f' and <= '\u009f');
}
