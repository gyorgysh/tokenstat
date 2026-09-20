// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Commit history for a folder on another machine. The same list and the
/// same commit sheet as WorkspaceHistory, with every read routed through
/// the peer that owns the folder.
/// </summary>
internal static class WorkspaceRemoteHistory
{
    /// <summary>
    /// The history card, or null when this folder has no git history to
    /// show. File details come from the selected commit.
    /// </summary>
    public static async Task<UIElement?> LoadCardAsync(
        UIElement owner, string remoteId)
    {
        JsonNode listed;
        try
        {
            listed = await RemoteWorkspaces.CallWorkspaceAsync(
                remoteId,
                "workspace.log",
                new JsonObject { ["id"] = remoteId, ["limit"] = 100 });
        }
        catch (Exception ex)
        {
            return Chrome.Banner(ex.Message, Theme.Danger, Symbol.Important);
        }
        var array = Format.Items(listed, "commits", "history", "log");
        if (array is null || array.Count == 0)
        {
            return EmptyState.View(
                "No commits yet",
                "Make your first commit and it will appear here.",
                EmptyArtKind.Changes);
        }
        var hasUpstream = false;
        try
        {
            var status = await Tokenstat.Navigation.RemoteWorkspaces.CallWorkspaceAsync(
                remoteId, "workspace.status", new JsonObject { ["id"] = remoteId });
            hasUpstream = !string.IsNullOrEmpty(Format.Text(status["git"], "upstream", Format.Text(status, "upstream")));
        }
        catch { /* Do not claim that a commit was pushed without an upstream. */ }
        JsonNode? ownAccount = null;
        string? ownAvatar = null;
        string ownHandle = "", ownName = "";
        try { var status = await AppServices.Host.CallAsync("account.status"); var account = status["account"] ?? status; ownAccount = account; ownAvatar = Format.Text(account, "avatar"); ownHandle = Format.Text(account, "handle"); ownName = Format.Text(account, "displayName"); }
        catch { /* History remains usable while account status is unavailable. */ }
        var ownEmails = await HistoryAvatars.OwnEmailsAsync(ownAccount, array);
        var list = new StackPanel { Spacing = 4 };
        foreach (var commit in array)
        {
            var id = Format.Text(commit, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            var captured = id;
            var capturedRemote = remoteId;
            var subject = Format.Text(commit, "subject", "(no message)");
            var author = Format.Text(commit, "author");
            var moment = RelativeTime(Format.Long(commit, "timestamp"));
            var second = string.Join(" · ", new[]
            {
                author,
                moment,
                WorkspaceGit.ShortId(captured),
            }.Where(part => !string.IsNullOrEmpty(part)));
            if (commit?["tags"] is JsonArray tags && tags.Count > 0)
            {
                // A non-string tag must not take down the whole list. The
                // parse materializes inside the try, so a bad entry lands
                // here instead of at the join below.
                List<string> names;
                try
                {
                    names = tags
                        .Select(tag => tag?.GetValue<string>() ?? "")
                        .Where(tag => !string.IsNullOrEmpty(tag))
                        .ToList();
                }
                catch
                {
                    names = new List<string>();
                }
                var joined = string.Join(", ", names);
                if (!string.IsNullOrEmpty(joined))
                {
                    second += $" · {joined}";
                }
            }
            var unpushed = Format.Flag(commit, "unpushed");
            var body = new StackPanel { Spacing = 4 };
            body.Children.Add(new TextBlock
            {
                Text = subject, FontSize = 13,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap,
            });
            body.Children.Add(new TextBlock { Text = second, FontSize = 11, Opacity = 0.65, TextWrapping = TextWrapping.Wrap });
            body.Children.Add(new TextBlock
            {
                Text = unpushed ? "↑ Not pushed" : hasUpstream ? "✓ On upstream" : "Local history",
                FontSize = 11,
                Foreground = unpushed ? Theme.AccentBrush : Theme.Brush(static () => Theme.DefaultText),
                Opacity = unpushed ? 1 : 0.65,
            });
            var content = new Grid { ColumnSpacing = Theme.SpaceS };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var avatar = Marks.Avatar(url: ownEmails.Contains(Format.Text(commit, "email")) || Format.Flag(commit, "mine") || (ownHandle.Length > 0 && author.Equals(ownHandle, StringComparison.OrdinalIgnoreCase)) || (ownName.Length > 0 && author.Equals(ownName, StringComparison.OrdinalIgnoreCase)) ? ownAvatar : null, name: author, size: 30);
            avatar.VerticalAlignment = VerticalAlignment.Top;
            content.Children.Add(avatar);
            Grid.SetColumn(body, 1);
            content.Children.Add(body);
            var row = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = Theme.PanelBrush,
                BorderBrush = Theme.BorderBrush,
                BorderThickness = new Thickness(0, 0, 0, 1),
                Padding = new Thickness(Theme.SpaceS),
                Content = content,
            };
            row.Click += async (_, _) =>
                await ShowDetailAsync(owner, capturedRemote, captured);
            list.Children.Add(row);
        }
        return list;
    }

    private static async Task ShowDetailAsync(
        UIElement owner, string remoteId, string commitId)
    {
        JsonNode detail;
        try
        {
            detail = await RemoteWorkspaces.CallWorkspaceAsync(
                remoteId,
                "workspace.show",
                new JsonObject { ["id"] = remoteId, ["path"] = commitId });
        }
        catch (Exception ex)
        {
            var failed = new ContentDialog
            {
                Title = WorkspaceGit.ShortId(commitId),
                Content = Chrome.Banner(
                    FriendlyError.Display(ex.Message), Theme.Danger, Symbol.Important),
                CloseButtonText = "Close",
            };
            await Chrome.ShowDialog(owner, failed);
            return;
        }
        await WorkspaceDiff.ShowCommitAsync(owner, detail);
    }

    private static string RelativeTime(long unixSeconds)
    {
        if (unixSeconds <= 0)
        {
            return "";
        }
        try
        {
            return Format.Relative(
                DateTimeOffset.FromUnixTimeSeconds(unixSeconds).ToString("o"));
        }
        catch
        {
            return "";
        }
    }

}
