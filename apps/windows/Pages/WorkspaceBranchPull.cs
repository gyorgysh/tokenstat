// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>The branch's pull request. Sidebar rows use only the host's cached metadata.</summary>
internal static class WorkspaceBranchPull
{
    public static async Task<JsonNode?> LoadAsync(string workspaceId, string branch, bool refresh = false)
    {
        try
        {
            var protocol = await RemoteWorkspaces.CallWorkspaceAsync(workspaceId, "protocol");
            if (RemoteFeatureGate.ProtocolOf(protocol) is not long version || version < RemoteFeatureGate.ReviewedPullMinProtocol)
                return null;
            return await RemoteWorkspaces.CallWorkspaceAsync(workspaceId, "pulls.branch", new JsonObject
            {
                ["workspaceId"] = workspaceId, ["branch"] = branch, ["refresh"] = refresh,
            });
        }
        catch { return null; }
    }

    public static string StateLabel(JsonNode pull) => Format.Text(pull, "state") switch
    {
        "merged" => L10n.Text("windows.branchpull.merged"),
        "closed" => L10n.Text("windows.branchpull.closed"),
        _ => Format.Flag(pull, "draft") ? L10n.Text("windows.branchpull.draft") : L10n.Text("windows.branchpull.open"),
    };

    private static Windows.UI.Color Tint(JsonNode pull) => Format.Text(pull, "state") switch
    {
        "merged" => Theme.Secondary,
        "closed" => Theme.Danger,
        _ => Format.Flag(pull, "draft") ? Theme.StateIdle : Theme.Accent,
    };

    private static string Help(JsonNode pull) => L10n.Text("windows.branchpull.help", StateLabel(pull),
        Format.Text(pull, "number"), Format.Text(pull, "title"));

    public static UIElement Badge(JsonNode pull)
    {
        var icon = ActionIcon.Merge.Icon();
        if (icon is FontIcon font) font.FontSize = 12;
        icon.Foreground = Theme.Brush(() => Tint(pull));
        icon.VerticalAlignment = VerticalAlignment.Center;
        ToolTipService.SetToolTip(icon, Help(pull));
        AutomationProperties.SetName(icon, Help(pull));
        return icon;
    }

    public static Button Chip(JsonNode pull)
    {
        var button = Buttons.Secondary(L10n.Text("windows.branchpull.chip", Format.Text(pull, "number"), StateLabel(pull)),
            ActionIcon.Merge, (_, _) => Open(pull), small: true);
        button.Foreground = Theme.Brush(() => Tint(pull));
        ToolTipService.SetToolTip(button, Help(pull));
        AutomationProperties.SetName(button, Help(pull));
        return button;
    }

    public static Button? Control(UIElement owner, string workspaceId, string folderName,
        JsonNode? answer, Func<Task> reload)
    {
        if (answer?["pull"] is JsonObject pull) return Chip(pull);
        if (!Format.Flag(answer, "connected") || string.IsNullOrEmpty(Format.Text(answer, "branch"))) return null;
        return Buttons.Secondary(L10n.Text("windows.branchpull.create"), ActionIcon.Merge, async (_, _) =>
        {
            await WorkspacePullCreate.ShowAsync(owner, workspaceId, folderName,
                (method, parameters) => RemoteWorkspaces.CallWorkspaceAsync(workspaceId, method, parameters));
            await reload();
        }, small: true);
    }

    private static void Open(JsonNode pull)
    {
        if (!Uri.TryCreate(Format.Text(pull, "url"), UriKind.Absolute, out var url) || url.Scheme != "https") return;
        try { Process.Start(new ProcessStartInfo { FileName = url.AbsoluteUri, UseShellExecute = true }); }
        catch { }
    }
}
