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
    private const int FullRenderLimit = 20000;

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
                total += hunk.Lines.Count;
            }
            return total;
        }
    }

    public static async Task ShowFileDiffAsync(
        UIElement owner, string title, JsonNode? diffNode, bool showAll = false)
    {
        var file = Parse(diffNode);
        var total = file.TotalLines();
        var capped = showAll || total <= MaxLines;
        var stack = new StackPanel { Spacing = Theme.SpaceS, MinWidth = 560 };
        stack.Children.Add(RenderFile(file, capped ? total : MaxLines));
        if (!capped)
        {
            if (total <= FullRenderLimit)
            {
                var show = new Button
                {
                    Content = new TextBlock { Text = $"Show all {total} lines" },
                    HorizontalAlignment = HorizontalAlignment.Left,
                };
                show.Click += (_, _) =>
                {
                    stack.Children.Clear();
                    stack.Children.Add(RenderFile(file, total));
                };
                stack.Children.Add(show);
            }
            else
            {
                stack.Children.Add(Note(
                    $"Showing the first {MaxLines} of {total} lines. "
                    + "The rest is on the computer."));
            }
        }
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
            CloseButtonText = "Close",
        };
        await Chrome.ShowDialog(owner, dialog);
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
        Func<string, Task<JsonNode?>> loadDiff)
    {
        var shown = files.Take(ReviewMaxFiles).ToList();
        var leftover = files.Count - shown.Count;
        var stack = new StackPanel { Spacing = Theme.SpaceM, MinWidth = 560 };
        stack.Children.Add(new TextBlock
        {
            Text = "Reading every change…",
            Opacity = 0.7,
        });
        var dialog = new ContentDialog
        {
            Title = "Review all",
            Content = new ScrollViewer { MaxHeight = 560, Content = stack },
            CloseButtonText = "Close",
        };
        var closed = false;
        dialog.Closed += (_, _) => closed = true;
        Task pending;
        if (WorkspaceTabsPage.Find(owner) is { } workbench)
        {
            ((ScrollViewer)dialog.Content).Content = null;
            stack.MinWidth = 0;
            workbench.OpenReview("Review all", new ScrollViewer
            {
                Content = stack, Padding = new Thickness(Theme.SpaceM),
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            });
            pending = Task.CompletedTask;
        }
        else pending = Chrome.ShowDialog(owner, dialog);
        var failures = 0;
        var cards = new List<UIElement>();
        foreach (var file in shown)
        {
            if (closed)
            {
                break;
            }
            JsonNode? diffNode;
            try
            {
                diffNode = await loadDiff(file.Path);
            }
            catch
            {
                diffNode = null;
            }
            if (diffNode is null)
            {
                failures++;
                continue;
            }
            cards.Add(FileCard(owner, file, diffNode));
        }
        stack.Children.Clear();
        if (failures > 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = $"{failures} {(failures == 1 ? "file" : "files")} did not load. "
                    + $"Open {(failures == 1 ? "it" : "them")} individually for the diff.",
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        foreach (var card in cards)
        {
            stack.Children.Add(card);
        }
        if (leftover > 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = $"{leftover} more {(leftover == 1 ? "file" : "files")} changed. "
                    + $"Open {(leftover == 1 ? "it" : "them")} from Changes for the diff.",
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
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
                Text = $"Showing {total - cut} of {total} lines here.",
                FontSize = 12,
                Opacity = 0.7,
            });
        }
        var full = new Button
        {
            Content = new TextBlock { Text = "Full diff" },
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        full.Click += (_, _) =>
        {
            card.Children.Clear();
            var parsed = Parse(diffNode);
            card.Children.Add(RenderFile(parsed, Math.Min(parsed.TotalLines(), FullRenderLimit)));
        };
        card.Children.Add(full);
        return Chrome.Card(file.Path, card);
    }

    private static UIElement RenderFile(File file, int maxLines) =>
        RenderFile(file, maxLines, out _, out _);

    private static UIElement RenderFile(File file, int maxLines, out int cut, out int total)
    {
        total = file.TotalLines();
        if (file.Binary)
        {
            cut = 0;
            return Note("This is a binary file. There is nothing to show line by line.");
        }
        if (file.Hunks.Count == 0)
        {
            cut = 0;
            return Note(file.Untracked
                ? "This file is not tracked yet and is empty."
                : "No changes against HEAD.");
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
            rows.Children.Add(new Border
            {
                Background = Theme.PanelBrush,
                Padding = new Thickness(Theme.SpaceS, 6, Theme.SpaceS, 6),
                Child = new TextBlock
                {
                    Text = hunk.Header,
                    FontFamily = Fonts.Mono,
                    FontSize = 11,
                    Foreground = Theme.Brush(static () => Theme.ControlGlyph),
                },
            });
            foreach (var line in hunk.Lines)
            {
                if (remaining <= 0)
                {
                    break;
                }
                remaining--;
                cut--;
                rows.Children.Add(RenderLine(line));
            }
        }
        return new ScrollViewer
        {
            HorizontalScrollMode = ScrollMode.Enabled,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = rows,
        };
    }

    private static UIElement RenderLine(Line line)
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
        row.Children.Add(Gutter(line.OldNumber));
        var right = Gutter(line.NewNumber);
        Grid.SetColumn(right, 1);
        row.Children.Add(right);
        var marker = new TextBlock
        {
            Text = line.Kind switch
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
            Text = line.Text.Length == 0 ? " " : line.Text,
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
