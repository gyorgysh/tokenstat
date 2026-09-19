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

namespace Tokenstat.Pages;

/// <summary>
/// Commit history for one workspace: a scrolling list, then one commit in
/// full, message first. Matches the Mac history surface: the message is
/// the part people came for and it goes at the top, in full.
/// </summary>
internal static class WorkspaceHistory
{
    /// <summary>
    /// The history card, or null when this folder has no git history to
    /// show. File details come from the selected commit.
    /// </summary>
    public static async Task<UIElement?> LoadCardAsync(
        UIElement owner, string workspaceId)
    {
        JsonNode listed;
        try
        {
            listed = await AppServices.Host.CallAsync(
                "workspace.log",
                new JsonObject { ["id"] = workspaceId, ["limit"] = 100 });
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
                workspaceId, "workspace.status", new JsonObject { ["id"] = workspaceId });
            hasUpstream = !string.IsNullOrEmpty(Format.Text(status["git"], "upstream", Format.Text(status, "upstream")));
        }
        catch { /* Do not claim that a commit was pushed without an upstream. */ }
        string? ownAvatar = null;
        string ownHandle = "", ownName = "";
        try { var status = await AppServices.Host.CallAsync("account.status"); var account = status["account"] ?? status; ownAvatar = Format.Text(account, "avatar"); ownHandle = Format.Text(account, "handle"); ownName = Format.Text(account, "displayName"); }
        catch { /* History remains usable while account status is unavailable. */ }
        var list = new StackPanel { Spacing = 4 };
        foreach (var commit in array)
        {
            var id = Format.Text(commit, "id");
            if (string.IsNullOrEmpty(id))
            {
                continue;
            }
            var captured = id;
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
            var avatar = Marks.Avatar(url: Format.Flag(commit, "mine") || (ownHandle.Length > 0 && author.Equals(ownHandle, StringComparison.OrdinalIgnoreCase)) || (ownName.Length > 0 && author.Equals(ownName, StringComparison.OrdinalIgnoreCase)) ? ownAvatar : null, name: author, size: 30);
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
                await ShowDetailAsync(owner, workspaceId, captured);
            list.Children.Add(row);
        }
        return list;
    }

    private static async Task ShowDetailAsync(
        UIElement owner, string workspaceId, string commitId)
    {
        JsonNode detail;
        try
        {
            detail = await AppServices.Host.CallAsync(
                "workspace.show",
                new JsonObject { ["id"] = workspaceId, ["path"] = commitId });
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
        var stack = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 480 };
        stack.Children.Add(new TextBlock
        {
            Text = Format.Text(detail, "subject", "(no message)"),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 15,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        });
        var body = Format.Text(detail, "body");
        if (!string.IsNullOrEmpty(body))
        {
            stack.Children.Add(new TextBlock
            {
                Text = body,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            });
        }
        var author = Format.Text(detail, "author");
        var moment = AbsoluteTime(Format.Long(detail, "timestamp"));
        var meta = string.Join(" · ", new[]
        {
            author,
            moment,
            WorkspaceGit.ShortId(Format.Text(detail, "id", commitId)),
        }.Where(part => !string.IsNullOrEmpty(part)));
        stack.Children.Add(new TextBlock
        {
            Text = meta,
            FontSize = 12,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        var parents = detail?["parents"] as JsonArray;
        if (parents is not null && parents.Count >= 2)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "A merge, so there is nothing of its own to show. "
                    + "Its changes belong to the commits it brought in.",
                FontSize = 13,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        var files = detail?["files"] as JsonArray;
        var added = Format.Long(detail, "added");
        var removed = Format.Long(detail, "removed");
        var counts = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        counts.Children.Add(new TextBlock
        {
            Text = "+" + added,
            Foreground = Theme.Brush(static () => Theme.DiffAdded),
            FontSize = 12,
        });
        counts.Children.Add(new TextBlock
        {
            Text = "−" + removed,
            Foreground = Theme.Brush(static () => Theme.DiffRemoved),
            FontSize = 12,
        });
        var fileCount = files?.Count ?? 0;
        counts.Children.Add(new TextBlock
        {
            Text = $"· {fileCount} {(fileCount == 1 ? "file" : "files")}",
            FontSize = 12,
            Opacity = 0.7,
        });
        stack.Children.Add(counts);
        ContentDialog? dialog = null;
        string? selectedPath = null;
        if (files is not null)
        {
            foreach (var file in files)
            {
                var path = Format.Text(file, "path");
                if (string.IsNullOrEmpty(path))
                {
                    continue;
                }
                var captured = path;
                var kind = Format.Text(file, "kind");
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = new GridLength(1, GridUnitType.Star),
                });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var label = new StackPanel { Spacing = 2 };
                label.Children.Add(new TextBlock
                {
                    Text = captured,
                    FontFamily = Fonts.Mono,
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap,
                });
                var fileAdded = Format.Long(file, "added");
                var fileRemoved = Format.Long(file, "removed");
                var sub = WorkspaceGit.KindLabel(kind);
                if (fileAdded > 0)
                {
                    sub += $" · +{fileAdded}";
                }
                if (fileRemoved > 0)
                {
                    sub += $" · −{fileRemoved}";
                }
                label.Children.Add(new TextBlock
                {
                    Text = sub,
                    FontSize = 11,
                    Foreground = Theme.Brush(WorkspaceGit.KindTint(kind)),
                });
                row.Children.Add(label);
                var diffButton = ActionIconGlyph.Button(
                    "Diff", ActionIcon.Compare, (_, _) => { selectedPath = captured; dialog?.Hide(); });
                Grid.SetColumn(diffButton, 1);
                row.Children.Add(diffButton);
                stack.Children.Add(row);
            }
        }
        dialog = new ContentDialog
        {
            Title = WorkspaceGit.ShortId(commitId),
            Content = new ScrollViewer { MaxHeight = 560, Content = stack },
            CloseButtonText = "Close",
        };
        await Chrome.ShowDialog(owner, dialog);
        if (selectedPath is not null)
        {
            // The commit owns this diff. Do not read the current working tree,
            // and wait for the detail dialog to close before showing another.
            var diff = (detail?["diffs"] as JsonArray)?.FirstOrDefault(
                item => Format.Text(item, "path") == selectedPath);
            await WorkspaceDiff.ShowFileDiffAsync(owner,
                WorkspaceGit.ShortId(commitId) + " · " + selectedPath, diff);
        }
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

    private static string AbsoluteTime(long unixSeconds)
    {
        if (unixSeconds <= 0)
        {
            return "";
        }
        try
        {
            return DateTimeOffset.FromUnixTimeSeconds(unixSeconds).LocalDateTime.ToString("g");
        }
        catch
        {
            return "";
        }
    }
}
