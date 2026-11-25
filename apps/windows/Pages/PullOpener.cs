// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Opens a chat's pull request where this person wants them: the app's own
/// page, the browser, or a question each time.
/// </summary>
internal static class PullOpener
{
    /// <summary>
    /// One whose repository is not a folder on that computer only has the
    /// browser.
    /// </summary>
    public static async Task OpenAsync(UIElement owner, string chatFolderId, JsonNode pull)
    {
        var folder = Format.Text(pull, "workspaceId");
        if (folder.Length == 0)
        {
            Browse(pull);
            return;
        }
        // The host names its own folder. A chat on another computer needs
        // that computer's name in front of it.
        var target = RemoteWorkspaces.TrySplit(chatFolderId, out var peer, out _)
            ? RemoteWorkspaces.Join(peer, folder) : folder;
        var choice = PullOpenPreference.Choice;
        if (choice == PullOpenChoice.Ask)
        {
            if (await AskAsync(owner, pull) is not { } answer) return;
            choice = answer;
        }
        if (choice == PullOpenChoice.Here && AppServices.OpenPull is { } open) open(target, Format.Long(pull, "number"));
        else Browse(pull);
    }

    public static void Browse(JsonNode pull)
    {
        if (!Uri.TryCreate(Format.Text(pull, "url"), UriKind.Absolute, out var url) || url.Scheme != "https") return;
        try { Process.Start(new ProcessStartInfo { FileName = url.AbsoluteUri, UseShellExecute = true }); }
        catch { }
    }

    private static async Task<PullOpenChoice?> AskAsync(UIElement owner, JsonNode pull)
    {
        var body = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 360 };
        body.Children.Add(new TextBlock
        {
            Text = Format.Text(pull, "title"),
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        body.Children.Add(WorkspaceBranchPull.Summary(pull));
        var remember = new CheckBox
        {
            Content = L10n.Text("common.pulls.open_remember"),
            Margin = new Thickness(0, Theme.SpaceS, 0, 0),
        };
        body.Children.Add(remember);
        body.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.pulls.open_remember_help"),
            FontSize = 12,
            Opacity = 0.68,
            TextWrapping = TextWrapping.Wrap,
        });
        var result = await Chrome.ShowDialog(owner, new ContentDialog
        {
            Title = L10n.Text("common.pulls.open_title"),
            Content = body,
            PrimaryButtonText = L10n.Text("common.pulls.view_here"),
            SecondaryButtonText = L10n.Text("common.pulls.open_browser"),
            CloseButtonText = L10n.Text("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
        });
        PullOpenChoice? choice = result switch
        {
            ContentDialogResult.Primary => PullOpenChoice.Here,
            ContentDialogResult.Secondary => PullOpenChoice.Browser,
            _ => null,
        };
        if (choice is { } kept && remember.IsChecked == true) PullOpenPreference.Choice = kept;
        return choice;
    }

    /// <summary>The same choice, for the settings card.</summary>
    public static UIElement Picker()
    {
        var row = new StackPanel { Spacing = Theme.SpaceS };
        row.Children.Add(new TextBlock { Text = L10n.Text("common.pulls.open_in") });
        row.Children.Add(SegmentedCapsule.View(
            [
                ("ask", L10n.Text("common.pulls.open_in_ask"), null),
                ("here", "tokenstat", null),
                ("browser", L10n.Text("common.pulls.open_in_browser"), null),
            ],
            PullOpenPreference.Key(PullOpenPreference.Choice),
            value =>
            {
                PullOpenPreference.Choice = PullOpenPreference.Parse(value);
                return Task.CompletedTask;
            }));
        return row;
    }
}
