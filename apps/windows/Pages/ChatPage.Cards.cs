// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE.

using System.Text.Json.Nodes;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Windows.UI;

namespace Tokenstat.Pages;

/// <summary>
/// Transcript cards and the follow pill. Same behaviour as the Mac ToolRow,
/// ChatFileEditRow and TranscriptFollowPill: collapse first, then Follow,
/// then the 150-row window in RebuildTranscript.
/// </summary>
internal sealed partial class ChatPage
{
    private const int SliceLength = 150;
    private const int SliceStep = 100;
    private const int ToolSnippetLines = 60;
    private const int EditSnippetLines = 200;
    private const int SnippetColumnCap = 600;
    private const int AutoExpandLines = 10;
    private const double FollowThreshold = 56;
    private const double WorkingSeatHeight = 34;

    private readonly Dictionary<string, bool> _expandedCards = [];
    private readonly Border _followPillHost = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Bottom,
        Margin = new Thickness(0, 0, 0, Theme.SpaceS),
        Visibility = Visibility.Collapsed,
    };
    private bool _followPaused;
    private int _sliceOlder;
    private double _lastScrollable;

    private int _historyGeneration => _history.Generation;
    private string? _historyCursor => _history.Cursor;
    private string? _tailCursor => _history.TailCursor;
    private bool _hasEarlier => _history.HasEarlier;
    private bool _historyLoading;
    private JsonObject? _aggregateUsage => _history.Usage;

    private void ResetTranscriptWindow()
    {
        _history.Reset();
        _historyLoading = false;
        _expandedCards.Clear();
        _sliceOlder = 0;
        _followEnd = true;
        _followPaused = false;
        _lastScrollable = 0;
        HideFollowPill();
    }

    private void HideFollowPill()
    {
        _followPillHost.Child = null;
        _followPillHost.Visibility = Visibility.Collapsed;
    }

    private void OnTranscriptViewChanged()
    {
        if (_scroll is null || _openId is null) return;
        var fromBottom = _scroll.ScrollableHeight - _scroll.VerticalOffset;
        var grew = _scroll.ScrollableHeight > _lastScrollable + 0.5;
        _lastScrollable = _scroll.ScrollableHeight;
        if (_followEnd)
        {
            // Content growth while pinned is not a user scroll. Stay with the
            // live turn instead of unpinning because the height moved.
            if (grew)
            {
                _scroll.ChangeView(null, _scroll.ScrollableHeight, null, true);
                UpdateFollowPill();
                return;
            }
            if (fromBottom > FollowThreshold)
            {
                _followEnd = false;
                _followPaused = false;
            }
        }
        else if (!_followPaused && _sliceOlder == 0 && fromBottom <= FollowThreshold)
        {
            _followEnd = true;
        }
        UpdateFollowPill();
    }

    private void ResumeFollow()
    {
        _followPaused = false;
        _followEnd = true;
        _sliceOlder = 0;
        RebuildTranscript(full: true);
        _scroll?.ChangeView(null, _scroll.ScrollableHeight, null, true);
        UpdateFollowPill();
    }

    private void PauseFollow()
    {
        _followEnd = false;
        _followPaused = true;
        UpdateFollowPill();
    }

    private void ApplyHistoryPage(JsonNode page, bool replace)
    {
        if (_history.ApplyPage(page, replace))
        {
            _historyLoading = false;
            _sliceOlder = 0;
        }
    }

    private async Task RevealEarlierAsync()
    {
        if (_historyLoading || _openId is not string id) return;
        var generation = _openGeneration;
        var historyGeneration = _historyGeneration;
        var count = Coalesce(_events).Count;
        if (SliceStart(count, _sliceOlder) == 0 && _hasEarlier)
        {
            _historyLoading = true;
            RebuildTranscript();
            try
            {
                var page = await CallChatAsync("chat.eventPage", new JsonObject
                    { ["id"] = id, ["cursor"] = _historyCursor, ["limit"] = 300, ["stablePositions"] = true });
                if (_openId != id || generation != _openGeneration || historyGeneration != _historyGeneration || !IsLoaded) return;
                ApplyHistoryPage(page, replace: false);
                count = Coalesce(_events).Count;
            }
            catch (Exception error)
            {
                if (_openId == id && generation == _openGeneration) Banner(error.Message);
            }
            finally { if (generation == _openGeneration) _historyLoading = false; }
        }
        if (_openId != id || generation != _openGeneration) return;
        _sliceOlder = SliceClamp(_sliceOlder + SliceStep, count);
        _followEnd = false;
        _followPaused = false;
        RebuildTranscript(full: true);
        UpdateFollowPill();
    }

    private void UpdateFollowPill()
    {
        if (_openId is null || _scroll is null)
        {
            HideFollowPill();
            return;
        }
        var nearBottom = _scroll.ScrollableHeight - _scroll.VerticalOffset <= FollowThreshold;
        var hidesNewest = _sliceOlder > 0;
        var showJump = hidesNewest || (!_followEnd && !nearBottom);
        var busy = Busy();
        Button? button = null;
        if (showJump)
        {
            button = FollowButton(L10n.Text("windows.chatpage_cards.jump_to_latest.86752458"), ResumeFollow, L10n.Text("windows.chatpage_cards.jump_to_the_latest_messages.4ac18a52"));
        }
        else if (busy && !_followEnd)
        {
            button = FollowButton(L10n.Text("windows.chatpage_cards.follow.641d1ef6"), ResumeFollow, L10n.Text("windows.chatpage_cards.follow_new_responses_as_they_arrive.bc0eb314"));
        }
        else if (busy && _followEnd)
        {
            button = FollowButton(L10n.Text("windows.chatpage_cards.following.344b4271"), PauseFollow, L10n.Text("windows.chatpage_cards.pause_auto_follow.554e9318"));
        }
        if (button is null)
        {
            HideFollowPill();
            return;
        }
        _followPillHost.Child = button;
        _followPillHost.Visibility = Visibility.Visible;
    }

    private static Button FollowButton(string title, Action click, string tip)
    {
        var button = Buttons.Primary(title, ActionIcon.Latest, (_, _) => click());
        ToolTipService.SetToolTip(button, tip);
        return button;
    }

    private static int SliceClamp(int older, int count)
    {
        if (count <= SliceLength) return 0;
        return Math.Min(Math.Max(0, older), count - SliceLength);
    }

    private static int SliceStart(int count, int older)
    {
        if (count <= 0) return 0;
        if (count <= SliceLength) return 0;
        var end = count - SliceClamp(older, count);
        return end - SliceLength;
    }

    private static int SliceEnd(int count, int older)
    {
        if (count <= 0) return 0;
        if (count <= SliceLength) return count;
        return count - SliceClamp(older, count);
    }

    private FrameworkElement ShowEarlierButton(int hidden)
    {
        var button = Buttons.Secondary(
            _historyLoading ? L10n.Text("windows.chatpage_cards.loading_earlier_messages.b8507b92") : hidden > 0 ? L10n.Text("windows.chatpage_cards.show_0_earlier_messages.2e5e4ab9", $"{hidden}") : L10n.Text("windows.chatpage_cards.load_earlier_messages.33fd46b9"),
            ActionIcon.History,
            async (_, _) => await RevealEarlierAsync(),
            small: true);
        button.IsEnabled = !_historyLoading;
        button.HorizontalAlignment = HorizontalAlignment.Center;
        return button;
    }

    private bool CardExpanded(DisplayItem item)
    {
        if (_expandedCards.TryGetValue(item.Id, out var user)) return user;
        return ShouldAutoExpand(item);
    }

    private static bool ShouldAutoExpand(DisplayItem item)
    {
        if (item.Running) return false;
        if (item.Kind == ItemKind.Edit)
        {
            if (string.IsNullOrEmpty(item.Patch)) return false;
            return LineCount(item.Patch) is > 0 and <= AutoExpandLines;
        }
        if (item.Kind != ItemKind.Tool) return false;
        if (!ToolHasDiff(item.Verb, item.Detail)) return false;
        return LineCount(item.Detail) is > 0 and <= AutoExpandLines;
    }

    private void ToggleCard(string id, bool expanded)
    {
        _expandedCards[id] = expanded;
        RebuildTranscript();
    }

    private UIElement ThinkingRow(string text)
    {
        return new Border
        {
            Padding = new Thickness(0, 2, 0, 2),
            Child = new TextBlock
            {
                Text = text,
                FontSize = 12,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            },
        };
    }

    private UIElement ToolRow(DisplayItem item)
    {
        var tint = ToolTint(item);
        var border = ToolBorder(item);
        var expanded = CardExpanded(item);
        var lines = SnippetLines(item.Verb, item.Detail);
        var hasDiff = ToolHasDiff(item.Verb, item.Detail);
        var snippetIsOutput = lines.Exists(line => line.StartsWith('|'));
        var body = new StackPanel { Spacing = Theme.SpaceXs };

        var header = new Grid { ColumnSpacing = Theme.SpaceS };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        FrameworkElement mark = item.Running
            ? new ProgressRing { Width = 12, Height = 12, IsActive = true, VerticalAlignment = VerticalAlignment.Center }
            : IconMark(VerbIcon(item.Verb), tint);
        header.Children.Add(mark);

        var verb = new TextBlock
        {
            Text = SeatStep.Word(item.Verb, item.Running),
            FontSize = 13,
            FontWeight = FontWeights.Medium,
            Foreground = tint,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(verb, 1);
        header.Children.Add(verb);

        if (!string.IsNullOrEmpty(item.Target))
        {
            var target = new TextBlock
            {
                Text = item.Target,
                FontFamily = Fonts.Mono,
                FontSize = 11,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 2,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(target, 2);
            header.Children.Add(target);
        }

        if (hasDiff && !item.Running)
        {
            var stat = DiffStat(DiffAddedCount(lines), DiffRemovedCount(lines));
            Grid.SetColumn(stat, 3);
            header.Children.Add(stat);
        }

        if (item.Running && !SeatStep.Speaks(item.Verb))
        {
            var running = new TextBlock
            {
                Text = L10n.Text("common.running"),
                FontFamily = Fonts.Mono,
                FontSize = 10,
                Foreground = Theme.AccentBrush,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(running, 4);
            header.Children.Add(running);
        }
        else
        {
            var status = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceS,
                VerticalAlignment = VerticalAlignment.Center,
            };
            if (item.Failed)
            {
                status.Children.Add(new TextBlock
                {
                    Text = L10n.Text("common.failed"),
                    FontFamily = Fonts.Mono,
                    FontSize = 10,
                    Foreground = Theme.Brush(static () => Theme.Danger),
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            if (!string.IsNullOrEmpty(item.Duration))
            {
                status.Children.Add(new TextBlock
                {
                    Text = item.Duration,
                    FontFamily = Fonts.Mono,
                    FontSize = 10,
                    Opacity = 0.55,
                    VerticalAlignment = VerticalAlignment.Center,
                });
            }
            if (status.Children.Count > 0)
            {
                Grid.SetColumn(status, 4);
                header.Children.Add(status);
            }
        }

        if (lines.Count > 0 && !item.Running)
        {
            var show = hasDiff
                ? (expanded ? L10n.Text("windows.chatpage_cards.hide_edit.e9dbd4f5") : L10n.Text("windows.chatpage_cards.show_edit.8da806e1"))
                : snippetIsOutput
                    ? (expanded ? L10n.Text("windows.chatpage_cards.hide_output.64876c47") : L10n.Text("windows.chatpage_cards.show_output.9dbbb249"))
                    : (expanded ? L10n.Text("windows.chatpage_cards.hide_edit.e9dbd4f5") : L10n.Text("windows.chatpage_cards.show_edit.8da806e1"));
            var toggle = Buttons.Primary(show, ActionIcon.Preview, (_, _) => ToggleCard(item.Id, !expanded), small: true);
            Grid.SetColumn(toggle, 5);
            header.Children.Add(toggle);
        }

        body.Children.Add(header);

        if (!expanded && !item.Running && !hasDiff)
        {
            var preview = FirstPreview(lines);
            if (!string.IsNullOrEmpty(preview))
            {
                body.Children.Add(new TextBlock
                {
                    Text = preview,
                    FontFamily = Fonts.Mono,
                    FontSize = 11,
                    Opacity = 0.7,
                    TextWrapping = TextWrapping.NoWrap,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    IsTextSelectionEnabled = true,
                });
            }
        }

        if (expanded && lines.Count > 0 && !item.Running)
        {
            body.Children.Add(SnippetBlock(lines, ToolSnippetLines));
        }

        return ToolCard(body, border);
    }

    private UIElement EditRow(DisplayItem item)
    {
        var expanded = CardExpanded(item);
        var name = FileName(item.Path);
        var tint = item.Failed
            ? Theme.Brush(static () => Theme.Danger)
            : Theme.AccentBrush;
        var border = item.Failed
            ? Theme.Brush(static () => WithAlpha(Theme.Danger, 0.45))
            : Theme.BorderBrush;

        var header = new Grid { ColumnSpacing = Theme.SpaceS };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        header.Children.Add(IconMark(ActionIcon.Edit, tint));

        var title = new TextBlock
        {
            Text = name,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = tint,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 1);
        header.Children.Add(title);

        if (item.Added + item.Removed > 0)
        {
            var stat = DiffStat(item.Added, item.Removed);
            Grid.SetColumn(stat, 2);
            header.Children.Add(stat);
        }

        if (!string.IsNullOrEmpty(item.Duration))
        {
            var time = new TextBlock
            {
                Text = item.Duration,
                FontFamily = Fonts.Mono,
                FontSize = 10,
                Opacity = 0.55,
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(time, 3);
            header.Children.Add(time);
        }

        if (!string.IsNullOrEmpty(item.Patch))
        {
            var show = expanded ? L10n.Text("windows.chatpage_cards.hide_changes.c960be38") : L10n.Text("windows.chatpage_cards.show_changes.b12a6ef8");
            var toggle = Buttons.Primary(show, ActionIcon.Preview, (_, _) => ToggleCard(item.Id, !expanded), small: true);
            Grid.SetColumn(toggle, 4);
            header.Children.Add(toggle);
        }

        var inner = new StackPanel { Spacing = Theme.SpaceXs };
        inner.Children.Add(header);
        if (!string.IsNullOrEmpty(item.Path) && !string.Equals(item.Path, name, StringComparison.Ordinal))
        {
            inner.Children.Add(new TextBlock
            {
                Text = item.Path,
                FontFamily = Fonts.Mono,
                FontSize = 11,
                Opacity = 0.7,
                TextWrapping = TextWrapping.NoWrap,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
        }
        if (expanded && !string.IsNullOrEmpty(item.Patch))
        {
            var lines = item.Patch.Replace("\r\n", "\n").Split('\n').ToList();
            inner.Children.Add(SnippetBlock(lines, EditSnippetLines));
        }

        var bar = new Border
        {
            Width = 3,
            CornerRadius = new CornerRadius(2),
            Background = item.Failed
                ? Theme.Brush(static () => Theme.Danger)
                : Theme.AccentBrush,
            Margin = new Thickness(0, 6, 0, 6),
            VerticalAlignment = VerticalAlignment.Stretch,
        };
        var row = new Grid { ColumnSpacing = 0 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(bar);
        var content = new Border
        {
            Padding = new Thickness(Theme.SpaceS),
            Child = inner,
        };
        Grid.SetColumn(content, 1);
        row.Children.Add(content);

        return new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = border,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Child = row,
        };
    }

    private static Border ToolCard(UIElement body, Brush border) => new()
    {
        Background = Theme.PanelBrush,
        BorderBrush = border,
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(Theme.CardRadius),
        Padding = new Thickness(Theme.SpaceS),
        Child = body,
    };

    private static Brush ToolTint(DisplayItem item)
    {
        if (item.Failed) return Theme.Brush(static () => Theme.Danger);
        if (item.Running) return Theme.AccentBrush;
        if (item.Verb is "Shell" or "Bash") return Theme.Brush(static () => Theme.Warning);
        return Theme.AccentBrush;
    }

    private static Brush ToolBorder(DisplayItem item)
    {
        if (item.Failed) return Theme.Brush(static () => WithAlpha(Theme.Danger, 0.45));
        if (item.Running) return Theme.Brush(static () => WithAlpha(Theme.Accent, 0.45));
        return Theme.BorderBrush;
    }

    private static ActionIcon VerbIcon(string verb) => verb switch
    {
        "Read" => ActionIcon.Docs,
        "Write" => ActionIcon.Edit,
        "Edit" or "NotebookEdit" => ActionIcon.Edit,
        "Diff" => ActionIcon.Compare,
        "Shell" or "Bash" => ActionIcon.Source,
        "Grep" or "Search" => ActionIcon.Search,
        "Glob" or "Find" => ActionIcon.Reveal,
        "WebFetch" or "WebSearch" => ActionIcon.Browser,
        "Task" or "Subagent" => ActionIcon.Persona,
        "TodoWrite" => ActionIcon.Apply,
        _ => ActionIcon.Settings,
    };

    private static Viewbox IconMark(ActionIcon icon, Brush tint)
    {
        var glyph = icon.Icon();
        glyph.Foreground = tint;
        return new Viewbox
        {
            Width = 16,
            Height = 16,
            VerticalAlignment = VerticalAlignment.Center,
            Child = glyph,
        };
    }

    private static FrameworkElement DiffStat(long added, long removed)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(Fonts.Tabular(new TextBlock
        {
            Text = "+" + added,
            Foreground = Theme.Brush(static () => Theme.DiffAdded),
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            FontFamily = Fonts.Mono,
        }));
        row.Children.Add(Fonts.Tabular(new TextBlock
        {
            Text = "−" + removed,
            Foreground = Theme.Brush(static () => Theme.DiffRemoved),
            FontSize = 11,
            FontWeight = FontWeights.Medium,
            FontFamily = Fonts.Mono,
        }));
        return row;
    }

    private static Border SnippetBlock(List<string> lines, int cap)
    {
        var shown = Math.Min(lines.Count, cap);
        var cut = Math.Max(0, lines.Count - cap);
        var block = new TextBlock
        {
            FontFamily = Fonts.Mono,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        for (var i = 0; i < shown; i++)
        {
            if (i > 0) block.Inlines.Add(new LineBreak());
            var raw = lines[i];
            var run = new Run { Text = ClipLine(DisplaySnippet(raw)) };
            if (IsDiffLine(raw, added: true))
            {
                run.Foreground = Theme.Brush(static () => Theme.DiffAdded);
            }
            else if (IsDiffLine(raw, added: false))
            {
                run.Foreground = Theme.Brush(static () => Theme.DiffRemoved);
            }
            else
            {
                run.Foreground = Theme.Brush(static () => Theme.ControlGlyph);
            }
            block.Inlines.Add(run);
        }
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(block);
        if (cut > 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = L10n.Text("windows.chatpage_cards.0_more_lines.c352841d", $"{cut}"),
                FontFamily = Fonts.Mono,
                FontSize = 11,
                Opacity = 0.55,
            });
        }
        return new Border
        {
            Background = Theme.BackgroundBrush,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(Theme.SpaceS),
            Child = stack,
        };
    }

    private static List<string> SnippetLines(string verb, string detail)
    {
        if (string.IsNullOrEmpty(detail)) return [];
        var raw = detail.Replace("\r\n", "\n").Split('\n');
        var isDiff = verb is "Edit" or "NotebookEdit" or "Diff";
        var lines = new List<string>(Math.Min(raw.Length, ToolSnippetLines) + 1);
        var take = Math.Min(raw.Length, ToolSnippetLines);
        for (var i = 0; i < take; i++)
        {
            var shown = ClipLine(raw[i]);
            if (isDiff && (IsDiffLine(shown, added: true) || IsDiffLine(shown, added: false)))
            {
                lines.Add(shown);
            }
            else
            {
                lines.Add("| " + shown);
            }
        }
        if (raw.Length > ToolSnippetLines)
        {
            lines.Add("| … (" + (raw.Length - ToolSnippetLines) + " more)");
        }
        return lines;
    }

    private static bool ToolHasDiff(string verb, string detail)
    {
        if (verb is not ("Edit" or "NotebookEdit" or "Diff") || string.IsNullOrEmpty(detail))
        {
            return false;
        }
        var start = 0;
        while (start <= detail.Length)
        {
            var nl = detail.IndexOf('\n', start);
            var line = nl < 0 ? detail[start..] : detail[start..nl];
            if (line.EndsWith('\r')) line = line[..^1];
            if (IsDiffLine(line, added: true) || IsDiffLine(line, added: false)) return true;
            if (nl < 0) break;
            start = nl + 1;
        }
        return false;
    }

    private static long DiffAddedCount(List<string> lines)
    {
        long n = 0;
        foreach (var line in lines)
        {
            if (IsDiffLine(line, added: true)) n++;
        }
        return n;
    }

    private static long DiffRemovedCount(List<string> lines)
    {
        long n = 0;
        foreach (var line in lines)
        {
            if (IsDiffLine(line, added: false)) n++;
        }
        return n;
    }

    private static bool IsDiffLine(string line, bool added)
    {
        if (string.IsNullOrEmpty(line)) return false;
        var want = added ? '+' : '-';
        if (line[0] != want) return false;
        return !(line.StartsWith("+++ ", StringComparison.Ordinal) || line.StartsWith("--- ", StringComparison.Ordinal));
    }

    private static string DisplaySnippet(string line)
    {
        if (line.StartsWith("| ", StringComparison.Ordinal)) return line[2..];
        if (line == "| …") return "…";
        return line;
    }

    private static string? FirstPreview(List<string> lines)
    {
        foreach (var line in lines)
        {
            var text = DisplaySnippet(line).Trim();
            if (text.Length == 0 || text == "…") continue;
            return text.Length <= 160 ? text : text[..160];
        }
        return null;
    }

    private static int LineCount(string text)
    {
        if (string.IsNullOrEmpty(text)) return 0;
        var n = 1;
        foreach (var c in text)
        {
            if (c == '\n') n++;
        }
        return n;
    }

    private static string ClipLine(string line)
    {
        if (line.Length <= SnippetColumnCap) return line;
        return line[..SnippetColumnCap] + "…";
    }

    private static string FileName(string path)
    {
        if (string.IsNullOrEmpty(path)) return L10n.Text("windows.chatpage_cards.file");
        var trimmed = path.TrimEnd('/', '\\');
        var slash = trimmed.LastIndexOf('/');
        var back = trimmed.LastIndexOf('\\');
        var at = Math.Max(slash, back);
        return at >= 0 ? trimmed[(at + 1)..] : trimmed;
    }

    private static Color WithAlpha(Color color, double opacity) =>
        Color.FromArgb((byte)(255 * opacity), color.R, color.G, color.B);
}
