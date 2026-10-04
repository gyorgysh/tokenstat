// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// File diffs in the D1 palette: added lines in the muted added green,
/// removed lines in the muted removed red, context in the primary text,
/// washes behind the changed rows, hunk headers tertiary on panel.
/// One horizontal scroll per file, lines never wrap: a wrapped line loses
/// its place against the gutter.
/// </summary>
internal static class WorkspaceDiff
{
    public const int ReviewMaxFiles = 20;
    public const int ReviewLinesPerFile = 60;
    private const int MaxLines = 2000;

    private enum LineKind
    {
        Context,
        Added,
        Removed,
    }

    private sealed class Line
    {
        public LineKind Kind;
        public uint? OldNumber;
        public uint? NewNumber;
        public string Text = "";
    }

    private sealed class Hunk
    {
        public string Header = "";
        public readonly List<Line> Lines = new();
    }

    private sealed class File
    {
        public bool Binary;
        public bool Untracked;
        public readonly List<Hunk> Hunks = new();

        public int TotalLines()
        {
            var total = 0;
            foreach (var hunk in Hunks)
            {
                total += 1 + hunk.Lines.Sum(line => DiffTextChunks.Count(line.Text));
            }
            return total;
        }
    }

    public static async Task ShowFileDiffAsync(
        UIElement owner, string title, JsonNode? diffNode, bool showAll = false)
    {
        var file = Parse(diffNode);
        var stack = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 560 };
        var page = 0;
        void RenderPage()
        {
            stack.Children.Clear();
            stack.Children.Add(RenderFile(file, MaxLines, out var cut, out _, skipRows: page * MaxLines));
            var navigation = new FlowPanel { Spacing = Theme.SpaceS };
            if (page > 0)
            {
                navigation.Children.Add(Buttons.Secondary(L10n.Text("windows.workspacediff.previous_page"), ActionIcon.Back,
                    (_, _) => { page--; RenderPage(); }, small: true));
            }
            if (cut > 0)
            {
                navigation.Children.Add(Buttons.Secondary(L10n.Text("windows.workspacediff.next_page"), ActionIcon.Reveal,
                    (_, _) => { page++; RenderPage(); }, small: true));
            }
            stack.Children.Add(navigation);
        }
        RenderPage();
        if (WorkspaceTabsPage.Find(owner) is { } workbench)
        {
            stack.MinWidth = 0;
            workbench.OpenReview(title, new ScrollViewer
            {
                Content = stack, Padding = new Thickness(Theme.SpaceM),
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            });
            return;
        }
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new ScrollViewer { MaxHeight = 560, Content = stack },
            CloseButtonText = L10n.Text("common.close"),
        };
        await Chrome.ShowDialog(owner, dialog);
    }

    /// <summary>A bounded diff in the Changes inspector, with the full review one press away.</summary>
    public static UIElement PreviewFile(UIElement owner, string path, JsonNode? diff)
    {
        var file = Parse(diff);
        var stack = new StackPanel { Spacing = Theme.SpaceS };
        stack.Children.Add(RenderFile(file, ReviewLinesPerFile));
        stack.Children.Add(Buttons.Secondary(L10n.Text("windows.workspacepage.diff.7ecf4628"), ActionIcon.Compare,
            async (_, _) => await ShowFileDiffAsync(owner, path, diff), small: true));
        return stack;
    }

    /// <summary>
    /// One commit as a workbench document: header then every file's diff,
    /// like the Mac CommitView. Uses the diffs already on workspace.show.
    /// </summary>
    public static Task ShowCommitAsync(UIElement owner, JsonNode detail)
    {
        var diffs = detail["diffs"] as JsonArray;
        var files = detail["files"] as JsonArray;
        var reviewFiles = new List<(string Path, string Kind, long? Added, long? Removed)>();
        if (diffs is not null)
        {
            foreach (var item in diffs)
            {
                var diffPath = Format.Text(item, "path");
                if (string.IsNullOrEmpty(diffPath))
                {
                    continue;
                }
                var fileMeta = files?.FirstOrDefault(file => Format.Text(file, "path") == diffPath);
                reviewFiles.Add((
                    diffPath,
                    Format.Text(fileMeta, "kind"),
                    fileMeta?["added"] is null ? null : Format.Long(fileMeta, "added"),
                    fileMeta?["removed"] is null ? null : Format.Long(fileMeta, "removed")));
            }
        }
        var shortId = WorkspaceGit.ShortId(Format.Text(detail, "id"));
        return ShowReviewAllAsync(
            owner,
            reviewFiles,
            path => Task.FromResult(diffs?.FirstOrDefault(
                item => Format.Text(item, "path") == path)),
            shortId,
            CommitHeader(detail));
    }

    /// <summary>
    /// Every changed file's diff on one screen, for the final read before a
    /// commit. Bounded: at most twenty files, sixty lines each, with a full
    /// diff per file for the rest. Selection and draft live above this
    /// screen and are untouched by opening it.
    /// </summary>
    public static async Task ShowReviewAllAsync(
        UIElement owner,
        IList<(string Path, string Kind, long? Added, long? Removed)> files,
        Func<string, Task<JsonNode?>> loadDiff,
        string? title = null,
        UIElement? header = null)
    {
        var shown = files.Take(ReviewMaxFiles).ToList();
        var leftover = files.Count - shown.Count;
        var stack = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 560 };
        stack.Children.Add(new TextBlock
        {
            Text = L10n.Text("windows.workspacediff.reading_every_change.9fd3cc74"),
            Opacity = 0.7,
        });
        var tabTitle = string.IsNullOrEmpty(title) ? L10n.Text("windows.workspacediff.review_all.d05163fa") : title;
        var dialog = new ContentDialog
        {
            Title = tabTitle,
            Content = new ScrollViewer { MaxHeight = 560, Content = stack },
            CloseButtonText = L10n.Text("common.close"),
        };
        var closed = false;
        dialog.Closed += (_, _) => closed = true;
        Task pending;
        if (WorkspaceTabsPage.Find(owner) is { } workbench)
        {
            ((ScrollViewer)dialog.Content).Content = null;
            stack.MinWidth = 0;
            workbench.OpenReview(tabTitle, new ScrollViewer
            {
                Content = stack, Padding = new Thickness(Theme.SpaceM),
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            });
            pending = Task.CompletedTask;
        }
        else pending = Chrome.ShowDialog(owner, dialog);
        stack.Children.Clear();
        if (header is not null)
        {
            stack.Children.Add(header);
        }
        var slots = new SemaphoreSlim(4);
        var loads = new List<Task>();
        foreach (var file in shown)
        {
            var slot = new ContentControl
            {
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Content = Note(L10n.Text("windows.workspacediff.reading_0.f5d364f3", $"{file.Path}")),
            };
            stack.Children.Add(slot);
            async Task Load()
            {
                await slots.WaitAsync();
                try
                {
                    if (closed) return;
                    var diff = await loadDiff(file.Path).WaitAsync(TimeSpan.FromSeconds(30));
                    if (closed) return;
                    if (diff is null) throw new InvalidOperationException(L10n.Text("windows.workspacediff.no_diff_was_returned.b30e0096"));
                    slot.Content = FileCard(owner, file, diff);
                }
                catch (Exception error)
                {
                    if (closed) return;
                    var failed = new StackPanel { Spacing = Theme.SpaceS };
                    failed.Children.Add(Note($"{file.Path}: " + (error is TimeoutException
                        ? L10n.Text("windows.workspacediff.the_computer_did_not_respond_in_time.8eebc73b") : error.Message)));
                    var retry = new Button { Content = L10n.Text("common.retry") };
                    retry.Click += async (_, _) =>
                    {
                        retry.IsEnabled = false;
                        await Load();
                    };
                    failed.Children.Add(retry);
                    slot.Content = failed;
                }
                finally { slots.Release(); }
            }
            loads.Add(Load());
        }
        if (shown.Count == 0 && header is null) stack.Children.Add(Note(L10n.Text("windows.workspacediff.no_changes_to_review.1f08cad6")));
        if (leftover > 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.workspacediff.0_more_1_changed_open_2_from_changes_for_t.f976e9a1", $"{leftover}", $"{(leftover == 1 ? L10n.Text("windows.workspacediff.file.3b9c358f") : L10n.Text("windows.workspacediff.files.3d7db37d"))}", $"{(leftover == 1 ? L10n.Text("windows.workspacediff.it.2ad8a704") : L10n.Text("windows.workspacediff.them.c9a8dc33"))}"),
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        await Task.WhenAll(loads);
        await pending;
    }

    private static UIElement FileCard(
        UIElement owner,
        (string Path, string Kind, long? Added, long? Removed) file,
        JsonNode diffNode)
    {
        var card = new StackPanel { Spacing = Theme.SpaceS };
        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        head.Children.Add(new TextBlock
        {
            Text = file.Path,
            FontFamily = Fonts.Mono,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        if (!string.IsNullOrEmpty(file.Kind))
        {
            head.Children.Add(new TextBlock
            {
                Text = WorkspaceGit.KindLabel(file.Kind),
                FontSize = 12,
                FontWeight = Microsoft.UI.Text.FontWeights.Medium,
                Foreground = Theme.Brush(WorkspaceGit.KindTint(file.Kind)),
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        card.Children.Add(head);
        if (file.Added.HasValue || file.Removed.HasValue)
        {
            var counts = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
            };
            if (file.Added > 0)
            {
                counts.Children.Add(new TextBlock
                {
                    Text = "+" + file.Added,
                    FontSize = 12,
                    Foreground = Theme.Brush(static () => Theme.DiffAdded),
                });
            }
            if (file.Removed > 0)
            {
                counts.Children.Add(new TextBlock
                {
                    Text = "−" + file.Removed,
                    FontSize = 12,
                    Foreground = Theme.Brush(static () => Theme.DiffRemoved),
                });
            }
            card.Children.Add(counts);
        }
        card.Children.Add(RenderFile(Parse(diffNode), ReviewLinesPerFile, out var cut, out var total));
        if (cut > 0)
        {
            card.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.workspacediff.showing_0_of_1_lines_here.f2764462", $"{total - cut}", $"{total}"),
                FontSize = 12,
                Opacity = 0.7,
            });
        }
        var full = new Button
        {
            Content = new TextBlock { Text = L10n.Text("windows.workspacediff.full_diff.79eeb065") },
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        full.Click += async (_, _) => await ShowFileDiffAsync(owner, file.Path, diffNode);
        card.Children.Add(full);
        return Chrome.Card(file.Path, card);
    }

    private static UIElement RenderFile(File file, int maxLines) =>
        RenderFile(file, maxLines, out _, out _);

    private static UIElement RenderFile(File file, int maxLines, out int cut, out int total, int skipRows = 0)
    {
        total = file.TotalLines();
        if (file.Binary)
        {
            cut = 0;
            return Note(L10n.Text("windows.workspacediff.this_is_a_binary_file_there_is_nothing_to.6573d54c"));
        }
        if (file.Hunks.Count == 0)
        {
            cut = 0;
            return Note(file.Untracked
                ? L10n.Text("windows.workspacediff.this_file_is_not_tracked_yet_and_is_empty.7354c94b")
                : L10n.Text("windows.workspacediff.no_changes_against_head.84a982f2"));
        }
        var rows = new StackPanel { Spacing = 0 };
        var remaining = maxLines;
        cut = total;
        foreach (var hunk in file.Hunks)
        {
            if (remaining <= 0)
            {
                break;
            }
            if (skipRows > 0) skipRows--;
            else
            {
                remaining--;
                rows.Children.Add(new Border
            {
                Background = Theme.PanelBrush,
                Padding = new Thickness(Theme.SpaceS, 6, Theme.SpaceS, 6),
                Child = new TextBlock
                {
                    Text = hunk.Header.Length > DiffTextChunks.MaxUnits ? hunk.Header[..DiffTextChunks.MaxUnits] : hunk.Header,
                    FontFamily = Fonts.Mono,
                    FontSize = 11,
                    Foreground = Theme.Brush(static () => Theme.ControlGlyph),
                },
                });
            }
            cut--;
            foreach (var line in hunk.Lines)
            {
                if (remaining <= 0)
                {
                    break;
                }
                var continuation = false;
                foreach (var text in DiffTextChunks.Split(line.Text))
                {
                    if (skipRows > 0) skipRows--;
                    else
                    {
                        if (remaining <= 0) break;
                        remaining--;
                        rows.Children.Add(RenderLine(line, text, continuation));
                    }
                    cut--;
                    continuation = true;
                }
            }
        }
        return new ScrollViewer
        {
            HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = rows,
        };
    }

    private static UIElement RenderLine(Line line, string piece, bool continuation)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var lineKind = line.Kind;
        Windows.UI.Color Tint() => lineKind switch
        {
            LineKind.Added => Theme.DiffAdded,
            LineKind.Removed => Theme.DiffRemoved,
            _ => Theme.DefaultText,
        };
        row.Children.Add(Gutter(continuation ? null : line.OldNumber));
        var right = Gutter(continuation ? null : line.NewNumber);
        Grid.SetColumn(right, 1);
        row.Children.Add(right);
        var marker = new TextBlock
        {
            Text = continuation ? "↪" : line.Kind switch
            {
                LineKind.Added => "+",
                LineKind.Removed => "−",
                _ => " ",
            },
            FontFamily = Fonts.Mono,
            FontSize = 12,
            Foreground = Theme.Brush(Tint),
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
        };
        Grid.SetColumn(marker, 2);
        row.Children.Add(marker);
        var text = new TextBlock
        {
            Text = piece.Length == 0 ? " " : piece,
            FontFamily = Fonts.Mono,
            FontSize = 12,
            Foreground = Theme.Brush(Tint),
            IsTextSelectionEnabled = true,
        };
        Grid.SetColumn(text, 3);
        row.Children.Add(text);
        if (line.Kind == LineKind.Added || line.Kind == LineKind.Removed)
        {
            row.Background = Theme.Brush(() =>
            {
                var wash = lineKind == LineKind.Added ? Theme.DiffAdded : Theme.DiffRemoved;
                return Windows.UI.Color.FromArgb(31, wash.R, wash.G, wash.B);
            });
        }
        return row;
    }

    private static TextBlock Gutter(uint? number) => new()
    {
        Text = number?.ToString() ?? "·",
        FontFamily = Fonts.Mono,
        FontSize = 11,
        Foreground = Theme.Brush(static () => Theme.ControlGlyph),
        TextAlignment = TextAlignment.Right,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, 0, Theme.SpaceS, 0),
    };

    private static UIElement CommitHeader(JsonNode detail)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceS };
        stack.Children.Add(new TextBlock
        {
            Text = Format.Text(detail, "subject", L10n.Text("windows.workspacediff.no_message.c480160e")),
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
        var meta = string.Join(" · ", new[]
        {
            Format.Text(detail, "author"),
            AbsoluteTime(Format.Long(detail, "timestamp")),
            WorkspaceGit.ShortId(Format.Text(detail, "id")),
        }.Where(part => !string.IsNullOrEmpty(part)));
        stack.Children.Add(new TextBlock
        {
            Text = meta,
            FontSize = 12,
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
        });
        var parents = detail["parents"] as JsonArray;
        if (parents is not null && parents.Count >= 2)
        {
            stack.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.workspacediff.a_merge_so_there_is_nothing_of_its_own_to.6435e3f6"),
                FontSize = 13,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        var files = detail["files"] as JsonArray;
        var counts = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
        };
        counts.Children.Add(new TextBlock
        {
            Text = "+" + Format.Long(detail, "added"),
            Foreground = Theme.Brush(static () => Theme.DiffAdded),
            FontSize = 12,
        });
        counts.Children.Add(new TextBlock
        {
            Text = "−" + Format.Long(detail, "removed"),
            Foreground = Theme.Brush(static () => Theme.DiffRemoved),
            FontSize = 12,
        });
        var fileCount = files?.Count ?? 0;
        counts.Children.Add(new TextBlock
        {
            Text = $"· {fileCount} {(fileCount == 1 ? L10n.Text("windows.workspacediff.file.3b9c358f") : L10n.Text("windows.workspacediff.files.3d7db37d"))}",
            FontSize = 12,
            Opacity = 0.7,
        });
        stack.Children.Add(counts);
        return stack;
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

    private static TextBlock Note(string text) => new()
    {
        Text = text,
        Opacity = 0.7,
        TextWrapping = TextWrapping.Wrap,
    };

    private static File Parse(JsonNode? diffNode)
    {
        var file = new File();
        if (diffNode is null)
        {
            return file;
        }
        file.Binary = Format.Flag(diffNode, "binary");
        file.Untracked = Format.Flag(diffNode, "untracked");
        if (diffNode["hunks"] is JsonArray hunks)
        {
            foreach (var hunkNode in hunks)
            {
                var hunk = new Hunk { Header = Format.Text(hunkNode, "header") };
                if (hunkNode?["lines"] is JsonArray lines)
                {
                    foreach (var lineNode in lines)
                    {
                        hunk.Lines.Add(new Line
                        {
                            Kind = ParseKind(Format.Text(lineNode, "kind")),
                            OldNumber = ParseNumber(lineNode?["oldLine"]),
                            NewNumber = ParseNumber(lineNode?["newLine"]),
                            Text = Format.Text(lineNode, "text"),
                        });
                    }
                }
                file.Hunks.Add(hunk);
            }
        }
        return file;
    }

    private static LineKind ParseKind(string raw) => raw switch
    {
        "added" => LineKind.Added,
        "removed" => LineKind.Removed,
        _ => LineKind.Context,
    };

    private static uint? ParseNumber(JsonNode? node)
    {
        if (node is null)
        {
            return null;
        }
        try
        {
            var value = node.GetValue<ulong>();
            return value > uint.MaxValue ? null : (uint?)value;
        }
        catch
        {
            return null;
        }
    }
}
