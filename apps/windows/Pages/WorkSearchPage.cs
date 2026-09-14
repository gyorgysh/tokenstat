// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>
/// Search over the same host queries as the Mac work search. A query field
/// with kind filters, live results from work.search with cursor paging, and
/// recent queries for an empty field. Opening a hit returns to the folder
/// it lives in: a conversation opens in Chat, anything else in Sessions.
/// </summary>
internal sealed class WorkSearchPage : Page
{
    private readonly TextBox _query = new()
    {
        PlaceholderText = "Search work",
    };
    private readonly StackPanel _filters = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = Theme.SpaceS,
    };
    private readonly StackPanel _results = new() { Spacing = Theme.SpaceS };
    private readonly ScrollViewer _scroll;
    private readonly ProgressRing _busy = new()
    {
        Width = 20,
        Height = 20,
        Visibility = Visibility.Collapsed,
    };
    private readonly List<Button> _chips = [];

    private string _filter = "All";
    private string? _cursor;
    private CancellationTokenSource? _debounce;
    private CancellationTokenSource? _search;
    private readonly List<string> _recent = [];

    public WorkSearchPage()
    {
        _query.TextChanged += (_, _) =>
        {
            _debounce?.Cancel();
            _debounce = new CancellationTokenSource();
            var token = _debounce.Token;
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(350, token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                DispatcherQueue.TryEnqueue(() => _ = SearchAsync(false));
            });
        };

        foreach (var name in new[] { "All", "Conversations", "Folders", "Changes" })
        {
            var local = name;
            var chip = new Button { Content = local };
            if (local == _filter)
            {
                chip.Foreground = Theme.AccentBrush;
            }
            chip.Click += (_, _) =>
            {
                _filter = local;
                foreach (var other in _chips)
                {
                    other.ClearValue(Button.ForegroundProperty);
                }
                chip.Foreground = Theme.AccentBrush;
                _ = SearchAsync(false);
            };
            _chips.Add(chip);
            _filters.Children.Add(chip);
        }

        var head = new StackPanel { Spacing = Theme.SpaceM };
        head.Children.Add(new TextBlock
        {
            Text = "Search work",
            FontSize = 24,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        head.Children.Add(_query);
        head.Children.Add(_filters);
        head.Children.Add(_busy);

        var body = new StackPanel { Spacing = Theme.SpaceL };
        body.Children.Add(head);
        body.Children.Add(_results);
        _scroll = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceXl, Theme.SpaceL, Theme.SpaceXl, Theme.SpaceXl),
            Content = new Grid
            {
                MaxWidth = 760,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children = { body },
            },
        };
        Content = _scroll;
        Loaded += (_, _) => ShowRecent();
    }

    private string[] EntityKinds() => _filter switch
    {
        "Conversations" => ["conversation"],
        "Folders" => ["workspace"],
        "Changes" => ["commit", "savedDiff"],
        _ => [],
    };

    private async Task SearchAsync(bool more)
    {
        var query = (_query.Text ?? "").Trim();
        if (query.Length == 0)
        {
            ShowRecent();
            return;
        }
        _search?.Cancel();
        _search = new CancellationTokenSource();
        var token = _search.Token;
        if (!more)
        {
            _cursor = null;
            _results.Children.Clear();
        }
        _busy.Visibility = Visibility.Visible;
        try
        {
            var request = new JsonObject
            {
                ["query"] = query,
                ["limit"] = 50,
            };
            var kinds = EntityKinds();
            if (kinds.Length > 0)
            {
                var array = new JsonArray();
                foreach (var kind in kinds)
                {
                    array.Add(JsonValue.Create(kind));
                }
                request["entityKinds"] = array;
            }
            if (more && !string.IsNullOrEmpty(_cursor))
            {
                request["cursor"] = _cursor;
            }
            var answer = await AppServices.Host.CallAsync("work.search", request);
            if (token.IsCancellationRequested)
            {
                return;
            }
            if (!more)
            {
                _results.Children.Clear();
            }
            else
            {
                RemoveMoreButton();
            }
            Remember(query);
            AppendCoverage(answer);
            var hits = answer["hits"] as JsonArray;
            if ((hits is null || hits.Count == 0) && !more)
            {
                _results.Children.Add(Chrome.Empty(
                    "No matches in your work",
                    "Nothing here matches. Try fewer words, or another machine.",
                    Symbol.Find));
                return;
            }
            if (hits is not null)
            {
                foreach (var hit in hits)
                {
                    if (hit is null)
                    {
                        continue;
                    }
                    _results.Children.Add(Row(hit));
                }
            }
            _cursor = Format.Text(answer, "nextCursor");
            if (!string.IsNullOrEmpty(_cursor))
            {
                var showMore = ActionIconGlyph.Button(
                    "Show more results", ActionIcon.More, async (_, _) => await SearchAsync(true));
                showMore.Tag = "more";
                _results.Children.Add(showMore);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            if (!token.IsCancellationRequested)
            {
                _results.Children.Clear();
                _results.Children.Add(Chrome.Banner(ex.Message, Theme.Warning, Symbol.Important));
            }
        }
        finally
        {
            _busy.Visibility = Visibility.Collapsed;
        }
    }

    private void RemoveMoreButton()
    {
        for (var i = _results.Children.Count - 1; i >= 0; i--)
        {
            if (_results.Children[i] is Button button && button.Tag as string == "more")
            {
                _results.Children.RemoveAt(i);
            }
        }
    }

    private void AppendCoverage(JsonNode answer)
    {
        var coverage = answer["coverage"];
        var unreadable = Format.Long(coverage, "unreadable");
        if (unreadable > 0)
        {
            _results.Children.Add(new TextBlock
            {
                Text = $"{unreadable} saved items could not be read. Results cover the copies available now.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
        }
    }

    private UIElement Row(JsonNode hit)
    {
        var reference = hit["reference"];
        var kind = Format.Text(reference, "kind", "conversation");
        var workspaceId = Format.Text(reference, "workspaceId");
        var title = Format.Text(hit, "title", "(untitled)");
        var folder = Format.Text(hit, "folderName");
        var excerpt = Format.Text(hit, "excerpt");

        var body = new StackPanel { Spacing = Theme.SpaceXs };
        var heading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS };
        heading.Children.Add(new SymbolIcon
        {
            Symbol = KindSymbol(kind),
            Foreground = Theme.AccentBrush,
        });
        heading.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(heading);
        // A folder's row is its own name twice over otherwise: the title and
        // the trail. Show the excerpt only when it says something new.
        if (!string.IsNullOrEmpty(excerpt) && excerpt != title)
        {
            body.Children.Add(Excerpt(hit, excerpt));
        }
        if (!string.IsNullOrEmpty(folder) && folder != title)
        {
            body.Children.Add(new TextBlock
            {
                Text = folder,
                Opacity = 0.68,
            });
        }
        body.Children.Add(new TextBlock
        {
            Text = Timing(hit),
            Opacity = 0.68,
            FontSize = 12,
        });

        var card = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.CardPadding),
            Child = body,
        };
        if (string.IsNullOrEmpty(workspaceId))
        {
            return card;
        }
        var open = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Content = card,
        };
        var section = kind == "conversation" ? WorkspaceSection.Chat : WorkspaceSection.Sessions;
        open.Click += (_, _) => AppServices.OpenWorkspace?.Invoke(workspaceId, section);
        return open;
    }

    private static Symbol KindSymbol(string kind) => kind switch
    {
        "conversation" => Symbol.Message,
        "workspace" => Symbol.Folder,
        "commit" => Symbol.Switch,
        "savedDiff" => Symbol.Document,
        _ => Symbol.Find,
    };

    private static UIElement Excerpt(JsonNode hit, string excerpt)
    {
        var rich = new RichTextBlock { TextWrapping = TextWrapping.Wrap };
        var paragraph = new Paragraph();
        var marks = hit["highlights"] as JsonArray;
        var ranges = new List<(int Start, int Length)>();
        if (marks is not null)
        {
            foreach (var mark in marks)
            {
                var start = (int)Format.Long(mark, "location");
                var length = (int)Format.Long(mark, "length");
                if (start >= 0 && length > 0 && start + length <= excerpt.Length)
                {
                    ranges.Add((start, length));
                }
            }
        }
        ranges.Sort((a, b) => a.Start.CompareTo(b.Start));
        var at = 0;
        foreach (var (start, length) in ranges)
        {
            if (start < at)
            {
                continue;
            }
            if (start > at)
            {
                paragraph.Inlines.Add(new Run { Text = excerpt[at..start] });
            }
            var mark = new Run
            {
                Text = excerpt[start..(start + length)],
                Foreground = Theme.AccentBrush,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            };
            paragraph.Inlines.Add(mark);
            at = start + length;
        }
        if (at < excerpt.Length)
        {
            paragraph.Inlines.Add(new Run { Text = excerpt[at..] });
        }
        rich.Blocks.Add(paragraph);
        return rich;
    }

    /// <summary>
    /// Where it came from, and when it last changed when that is known. A
    /// folder carries no time of its own: the host answers zero for it, which
    /// would print as decades ago. Saying Live and stopping is honest.
    /// </summary>
    private static string Timing(JsonNode hit)
    {
        var source = Format.Text(hit, "source", "Live");
        var ms = Format.Long(hit, "updatedAtMs");
        var dated = "";
        if (ms > 0)
        {
            try
            {
                dated = " " + Format.Relative(
                    DateTimeOffset.FromUnixTimeMilliseconds(ms).ToString("o"));
            }
            catch
            {
            }
        }
        var partial = Format.Flag(hit, "partial") ? " · Partial conversation" : "";
        return source + dated + partial;
    }

    private void Remember(string query)
    {
        _recent.RemoveAll(q => q == query);
        _recent.Insert(0, query);
        while (_recent.Count > 8)
        {
            _recent.RemoveAt(_recent.Count - 1);
        }
    }

    /// <summary>
    /// Nothing typed yet: recent searches, or what the field can find.
    /// </summary>
    private void ShowRecent()
    {
        _results.Children.Clear();
        if (_recent.Count == 0)
        {
            _results.Children.Add(Chrome.Empty(
                "Search your work",
                "Type to find a conversation, a folder, or a change you have opened or saved.",
                Symbol.Find));
            return;
        }
        var list = new StackPanel { Spacing = Theme.SpaceS };
        list.Children.Add(new TextBlock
        {
            Text = "Recent searches",
            Opacity = 0.68,
        });
        foreach (var query in _recent)
        {
            var local = query;
            var pick = ActionIconGlyph.Button(local, ActionIcon.Search, (_, _) =>
            {
                _query.Text = local;
            });
            list.Children.Add(pick);
        }
        list.Children.Add(ActionIconGlyph.Button(
            "Clear", ActionIcon.Delete, (_, _) =>
            {
                _recent.Clear();
                ShowRecent();
            }));
        _results.Children.Add(list);
    }
}
