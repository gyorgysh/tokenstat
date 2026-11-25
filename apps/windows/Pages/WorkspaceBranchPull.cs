// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
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
        "merged" => Theme.PullMerged,
        "closed" => Theme.PullClosed,
        _ => Format.Flag(pull, "draft") ? Theme.StateIdle : Theme.PullOpen,
    };

    private static string Help(JsonNode pull) => L10n.Text("windows.branchpull.help", StateLabel(pull),
        Format.Text(pull, "number"), Format.Text(pull, "title"));

    /// <summary>Every pull request a chat opened or talked about, newest first. A host
    /// older than 1.26.0 only knows the branch's own.</summary>
    private static List<JsonNode> Pulls(JsonNode chat)
    {
        var rows = (chat["pulls"] as JsonArray)?.OfType<JsonObject>().Cast<JsonNode>().ToList() ?? [];
        if (rows.Count == 0 && chat["pull"] is JsonObject pull) rows.Add(pull);
        return rows;
    }

    /// <summary>The state of a chat's pull requests, and how many when there are several.
    /// Drawing it never asks the forge. A click lists them, and a row opens one.</summary>
    public static UIElement? Badge(JsonNode chat, string folderId)
    {
        var pulls = Pulls(chat);
        if (pulls.Count == 0) return null;
        bool Is(JsonNode pull, string state) => Format.Text(pull, "state") == state;
        var lead = pulls.FirstOrDefault(pull => Is(pull, "open") && !Format.Flag(pull, "draft"))
            ?? pulls.FirstOrDefault(pull => Is(pull, "open"))
            ?? pulls.FirstOrDefault(pull => Is(pull, "merged")) ?? pulls[0];
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        var icon = ActionIcon.Merge.Icon();
        if (icon is FontIcon font) font.FontSize = 12;
        icon.Foreground = Theme.Brush(() => Tint(lead));
        icon.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(icon);
        if (pulls.Count > 1)
            row.Children.Add(new TextBlock { Text = pulls.Count.ToString(), FontSize = 11, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center });
        var help = string.Join(Environment.NewLine, pulls.Select(Help));
        // A button, so the press stays here instead of opening the chat.
        var button = new Button
        {
            Content = row,
            Background = Theme.ClearBrush,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(3, 1, 3, 1),
            MinWidth = 0,
            MinHeight = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(button, help);
        AutomationProperties.SetName(button, help);
        var menu = new MenuFlyout();
        foreach (var pull in pulls)
        {
            var glyph = ActionIcon.Merge.Icon();
            glyph.Foreground = Theme.Brush(() => Tint(pull));
            var item = new MenuFlyoutItem { Text = Help(pull), Icon = glyph };
            item.Click += async (_, _) => await PullOpener.OpenAsync(button, folderId, pull);
            menu.Items.Add(item);
        }
        button.Flyout = menu;
        return button;
    }

    /// <summary>State, repository and number, and the size of the change.</summary>
    public static UIElement Summary(JsonNode pull)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        TextBlock Word(string text, Func<Windows.UI.Color>? tint = null) => tint is null
            ? new TextBlock { Text = text, FontSize = 12, Opacity = 0.68 }
            : new TextBlock { Text = text, FontSize = 12, Foreground = Theme.Brush(tint) };
        row.Children.Add(Word(StateLabel(pull), () => Tint(pull)));
        row.Children.Add(Word((Format.Text(pull, "repo") + " #" + Format.Text(pull, "number")).Trim()));
        if (pull["additions"] is not null) row.Children.Add(Word("+" + Format.Long(pull, "additions"), static () => Theme.DiffAdded));
        if (pull["deletions"] is not null) row.Children.Add(Word("−" + Format.Long(pull, "deletions"), static () => Theme.DiffRemoved));
        return row;
    }

    public static Button Chip(JsonNode pull)
    {
        var button = Buttons.Secondary(L10n.Text("windows.branchpull.chip", Format.Text(pull, "number"), StateLabel(pull)),
            ActionIcon.Merge, (_, _) => PullOpener.Browse(pull), small: true);
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
}
