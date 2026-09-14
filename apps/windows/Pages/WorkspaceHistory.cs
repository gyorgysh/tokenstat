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
    /// show. OpenDiff shows one file's working-tree diff.
    /// </summary>
    public static async Task<UIElement?> LoadCardAsync(
        UIElement owner, string workspaceId, Func<string, Task> openDiff)
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
                var names = tags
                    .Select(tag => tag?.GetValue<string>() ?? "")
                    .Where(tag => !string.IsNullOrEmpty(tag));
                var joined = string.Join(", ", names);
                if (!string.IsNullOrEmpty(joined))
                {
                    second += $" · {joined}";
                }
            }
            if (Format.Flag(commit, "unpushed"))
            {
                second += " · Not pushed yet";
            }
            var row = new Button
            {
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Content = new StackPanel
                {
                    Spacing = 2,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = subject,
                            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                            TextWrapping = TextWrapping.Wrap,
                        },
                        new TextBlock
                        {
                            Text = second,
                            FontSize = 12,
                            Opacity = 0.7,
                            TextWrapping = TextWrapping.Wrap,
                        },
                    },
                },
            };
            row.Click += async (_, _) =>
                await ShowDetailAsync(owner, workspaceId, captured, openDiff);
            list.Children.Add(row);
        }
        return Chrome.Card("History", list);
    }

    private static async Task ShowDetailAsync(
        UIElement owner, string workspaceId, string commitId, Func<string, Task> openDiff)
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
            Foreground = Theme.Brush(Theme.DiffAdded),
            FontSize = 12,
        });
        counts.Children.Add(new TextBlock
        {
            Text = "−" + removed,
            Foreground = Theme.Brush(Theme.DiffRemoved),
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
                    "Diff", ActionIcon.Compare, async (_, _) => await openDiff(captured));
                Grid.SetColumn(diffButton, 1);
                row.Children.Add(diffButton);
                stack.Children.Add(row);
            }
        }
        var dialog = new ContentDialog
        {
            Title = WorkspaceGit.ShortId(commitId),
            Content = new ScrollViewer { MaxHeight = 560, Content = stack },
            CloseButtonText = "Close",
        };
        await Chrome.ShowDialog(owner, dialog);
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
