// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Tokenstat.Design;
using Tokenstat.Host;

namespace Tokenstat.Pages;

/// <summary>
/// Where the tokens went. Mirrors the desktop Mac Insights: a period picker
/// and the screen's own actions in the toolbar, a tab strip for the
/// breakdowns, an overview with metric tiles and a daily chart, and the
/// inspector beside it with the period figures, the selected row, and the
/// archive. Local only, like the Mac: there is no account scope here.
/// </summary>
internal sealed class InsightsPage : Page, IInspectorContent, IToolbarItems
{
    private readonly ContentControl _tabSlot = new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch,
        HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };
    private readonly StackPanel _root = new() { Spacing = Theme.SpaceL };
    private readonly StackPanel _inspectorRoot = new()
    {
        Spacing = Theme.SpaceM,
        Padding = new Thickness(Theme.SpaceM),
    };
    private readonly TextBlock _status = new() { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };

    private string _period = "all";
    /// <summary>
    /// A single day, pinned from Home's heatmap. Overrides the period rather
    /// than being another period, like the Mac focused day: it is not a
    /// length of time chosen from a control, and clearing it goes back to
    /// whatever the period was.
    /// </summary>
    private string? _focusDay;
    private string _tab = "overview";
    private string? _selectedKey;
    private int _visible = FirstPage;
    private bool _chartShowsValue;
    private int _flowBucket = -1;
    private double _contentWidth;

    private JsonNode? _snapshot;
    private string? _error;

    private bool _loading;
    private bool _hasContent;
    private bool _reloadRequested;
    private bool _scanning;
    private bool _fetching;

    /// <summary>Rows drawn before the reveal button, same as the Mac table.</summary>
    private const int FirstPage = 50;
    /// <summary>Rows added per press of the reveal button.</summary>
    private const int PageStep = 30;

    private static readonly List<(string Value, string Label, ActionIcon? Glyph)> LocalTabs =
        new List<(string, string, ActionIcon?)>
        {
            ("overview", "Overview", null),
            ("models", "Models", null),
            ("projects", "Projects", null),
            ("harnesses", "Harnesses", null),
            ("sessions", "Sessions", null),
        };

    private static readonly List<(string Value, string Label, ActionIcon? Glyph)> Periods =
        new List<(string, string, ActionIcon?)>
        {
            ("7d", "7d", null),
            ("30d", "30d", null),
            ("90d", "90d", null),
            ("all", "All", null),
        };

    /// <param name="focusDay">One day to pin from a deep link, in archive
    /// YYYY-MM-DD text. Every figure on the screen is about that day until
    /// the period picker or Clear dismisses it.</param>
    public InsightsPage(string? focusDay = null)
    {
        if (!string.IsNullOrEmpty(focusDay))
        {
            _focusDay = focusDay;
        }
        var scroller = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceM),
            Content = _root,
        };
        scroller.SizeChanged += OnContentSizeChanged;
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition
        {
            Height = new GridLength(1, GridUnitType.Star),
        });
        layout.Children.Add(_tabSlot);
        Grid.SetRow(scroller, 1);
        layout.Children.Add(scroller);
        Content = layout;
        _root.Children.Add(_status);
        RebuildTabs();
        RefreshInspector();
        Loaded += async (_, _) =>
        {
            if (!_hasContent && !_loading)
            {
                await LoadAsync();
            }
        };
    }

    /// <summary>
    /// The shell reads this once, at navigation, and keeps the element.
    /// Selection and reloads replace its children, so the column stays live
    /// without the shell ever asking again.
    /// </summary>
    public UIElement? Inspector => _inspectorRoot;

    /// <summary>
    /// Pin one day from Home's heatmap, like the Mac focused day. Safe
    /// before first load: the day is set first and the load reads it.
    /// </summary>
    public Task FocusDayAsync(string day)
    {
        if (string.IsNullOrEmpty(day))
        {
            return Task.CompletedTask;
        }
        if (_focusDay == day && _hasContent)
        {
            return Task.CompletedTask;
        }
        _focusDay = day;
        _selectedKey = null;
        _visible = FirstPage;
        return LoadAsync();
    }

    private Task ClearFocusDayAsync()
    {
        _focusDay = null;
        _selectedKey = null;
        _visible = FirstPage;
        return LoadAsync();
    }

    private void OnContentSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (!_hasContent || _loading || e.NewSize.Width <= 0)
        {
            return;
        }
        int metrics = e.NewSize.Width >= 760 ? 2 : e.NewSize.Width >= 380 ? 1 : 0;
        int rank = e.NewSize.Width >= 680 ? 1 : 0;
        int combined = metrics * 2 + rank;
        _contentWidth = e.NewSize.Width;
        if (combined == _flowBucket)
        {
            return;
        }
        _flowBucket = combined;
        Render();
    }

    public event Action? ToolbarChanged;

    /// <summary>Global screen: no folder to name.</summary>
    public UIElement? ToolbarScope => null;

    /// <summary>
    /// The screen's own actions: the period picker with scan and fetch, like
    /// the desktop Mac bar.
    /// </summary>
    public IList<UIElement> ToolbarActions()
    {
        var picker = SegmentedCapsule.View(Periods, _period, value =>
        {
            _period = value;
            // Choosing a period is choosing to stop looking at one day.
            _focusDay = null;
            _selectedKey = null;
            _visible = FirstPage;
            return LoadAsync();
        });
        picker.Width = 240;
        picker.VerticalAlignment = VerticalAlignment.Center;
        var scan = Buttons.ToolbarIcon(
            ActionIcon.Refresh,
            "Read new sessions from supported local tools into the archive",
            async (_, _) => await ScanAsync());
        scan.IsEnabled = !_scanning && !_loading;
        var fetch = Buttons.ToolbarIcon(
            ActionIcon.Download,
            "Fetch usage from remote vendors such as Cursor",
            async (_, _) => await FetchAsync());
        fetch.IsEnabled = !_fetching && !_loading;
        return new List<UIElement> { picker, scan, fetch };
    }

    private void RaiseToolbarChanged() => ToolbarChanged?.Invoke();

    private void RebuildTabs()
    {
        _tabSlot.Content = TabStrip.View(LocalTabs, _tab, value =>
        {
            _tab = value;
            _selectedKey = null;
            _visible = FirstPage;
            Render();
            RefreshInspector();
            return Task.CompletedTask;
        });
    }

    private async Task ScanAsync()
    {
        if (_scanning)
        {
            return;
        }
        _scanning = true;
        RaiseToolbarChanged();
        _status.Text = "Scanning local logs…";
        LogoRefresh.Began();
        try
        {
            var report = await AppServices.Host.CallAsync(
                "scan", patience: TimeSpan.FromMinutes(10));
            _status.Text = "Scan complete: added "
                + Format.Long(report, "eventsNew") + " new events from "
                + Format.Long(report, "filesRead") + " files.";
        }
        catch (Exception ex)
        {
            _status.Text = FriendlyError.Display(ex.Message);
            _scanning = false;
            RaiseToolbarChanged();
            return;
        }
        _scanning = false;
        await LoadAsync();
    }

    private async Task FetchAsync()
    {
        if (_fetching)
        {
            return;
        }
        _fetching = true;
        RaiseToolbarChanged();
        _status.Text = "Fetching remote usage…";
        LogoRefresh.Began();
        try
        {
            var reports = await AppServices.Host.CallAsync(
                "fetch", patience: TimeSpan.FromMinutes(10));
            var details = new List<string>();
            if (reports is JsonArray list)
            {
                foreach (var item in list)
                {
                    var message = Format.Text(item, "message");
                    if (!string.IsNullOrEmpty(message))
                    {
                        details.Add(message);
                    }
                }
            }
            _status.Text = details.Count > 0
                ? string.Join(" · ", details)
                : "Remote fetch complete.";
        }
        catch (Exception ex)
        {
            _status.Text = FriendlyError.Display(ex.Message);
            _fetching = false;
            RaiseToolbarChanged();
            return;
        }
        _fetching = false;
        await LoadAsync();
    }

    private async Task LoadAsync()
    {
        if (_loading)
        {
            _reloadRequested = true;
            return;
        }
        _loading = true;
        RaiseToolbarChanged();
        try
        {
            do
            {
                _reloadRequested = false;
                await LoadOnceAsync();
            }
            while (_reloadRequested);
        }
        finally
        {
            _loading = false;
            RaiseToolbarChanged();
        }
    }

    private async Task LoadOnceAsync()
    {
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        _status.Text = "Loading…";
        _root.Children.Add(Motion.SkeletonCard());

        await LoadLocalAsync();

        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        _hasContent = true;
        Render();
        RefreshInspector();
    }

    private async Task LoadLocalAsync()
    {
        _error = null;
        var query = PeriodQuery();
        try
        {
            // One coherent snapshot first, which is what the Mac reads. An
            // older host that does not know it falls back to one report call
            // per breakdown.
            try
            {
                _snapshot = await AppServices.Host.CallAsync(
                    "insights.snapshot", new JsonObject { ["query"] = query });
            }
            catch (HostException ex) when (ex.Code.Contains(
                "unknown", StringComparison.OrdinalIgnoreCase))
            {
                _snapshot = await LoadLocalFallbackAsync();
            }
        }
        catch (Exception ex)
        {
            _snapshot = null;
            _error = FriendlyError.Display(ex.Message);
            return;
        }
        if (_status.Text == "Loading…")
        {
            _status.Text = "";
        }
        // A selection from before the reload may no longer exist, and a stale
        // row would sit in the inspector describing nothing.
        if (_selectedKey is not null)
        {
            bool stillThere = false;
            foreach (var row in TabRows(_tab))
            {
                if (Format.Text(row, "key") == _selectedKey)
                {
                    stillThere = true;
                    break;
                }
            }
            if (!stillThere)
            {
                _selectedKey = null;
            }
        }
    }

    /// <summary>
    /// The pre-snapshot read: the same aggregates, one call each, packed into
    /// the snapshot shape so rendering stays uniform. No active block and no
    /// per-project harness split down here, those calls are newer than the
    /// hosts this path serves.
    /// </summary>
    private async Task<JsonNode> LoadLocalFallbackAsync()
    {
        var query = PeriodQuery();
        var snapshot = new JsonObject();
        try
        {
            snapshot["info"] = (await AppServices.Host.CallAsync("info"))?.DeepClone();
        }
        catch
        {
            snapshot["info"] = new JsonObject();
        }
        try
        {
            snapshot["totals"] = (await AppServices.Host.CallAsync(
                "totals", new JsonObject { ["query"] = query.DeepClone() }))?.DeepClone();
        }
        catch
        {
            snapshot["totals"] = new JsonObject();
        }
        foreach (var group in new[] { "model", "source", "project", "day" })
        {
            try
            {
                snapshot[GroupKey(group)] = (await AppServices.Host.CallAsync(
                    "report",
                    new JsonObject
                    {
                        ["group"] = group,
                        ["query"] = query.DeepClone(),
                    }))?.DeepClone();
            }
            catch
            {
                snapshot[GroupKey(group)] = new JsonArray();
            }
        }
        try
        {
            var sessions = PeriodQuery();
            sessions["limit"] = 80;
            snapshot["bySession"] = (await AppServices.Host.CallAsync(
                "report",
                new JsonObject { ["group"] = "session", ["query"] = sessions }))?.DeepClone();
        }
        catch
        {
            snapshot["bySession"] = new JsonArray();
        }
        snapshot["activeBlock"] = null;
        snapshot["projectHarnesses"] = new JsonArray();
        return snapshot;
    }

    /// <summary>
    /// The period as an archive query. The archive stores local dates as plain
    /// text, so the filter is built the same way rather than as an instant. A
    /// fresh object per call: a node keeps its parent.
    /// </summary>
    private JsonObject PeriodQuery()
    {
        // A pinned day is a range whose ends are the same string: the
        // archive stores local dates as plain text. It overrides the
        // period, like the Mac focused day.
        if (!string.IsNullOrEmpty(_focusDay))
        {
            return new JsonObject
            {
                ["since"] = _focusDay,
                ["until"] = _focusDay,
            };
        }
        int? days = _period switch
        {
            "7d" => 7,
            "30d" => 30,
            "90d" => 90,
            _ => null,
        };
        if (days is null)
        {
            return new JsonObject();
        }
        var start = DateTime.Today.AddDays(-(days.Value - 1));
        return new JsonObject
        {
            ["since"] = start.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        };
    }

    private static string GroupKey(string group) => group switch
    {
        "model" => "byModel",
        "source" => "bySource",
        "project" => "byProject",
        "day" => "daily",
        _ => group,
    };

    private void Render()
    {
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }
        RenderLocal();
    }

    private JsonArray TabRows(string tab)
    {
        return tab switch
        {
            "models" => SnapshotRows("byModel", "by_model"),
            "projects" => SnapshotRows("byProject", "by_project"),
            "harnesses" => SnapshotRows("bySource", "by_source"),
            "sessions" => SnapshotRows("bySession", "by_session"),
            _ => SnapshotRows("byModel", "by_model"),
        };
    }

    private JsonArray SnapshotRows(params string[] keys)
    {
        return Format.Items(_snapshot, keys) ?? new JsonArray();
    }

    private void RenderLocal()
    {
        if (_error is not null)
        {
            _root.Children.Add(Chrome.Banner(_error, Theme.Danger, Symbol.Important));
            return;
        }
        if (_snapshot is null)
        {
            return;
        }
        // A day arrived from Home's heatmap. It has to be visible and
        // dismissable, or every figure on the screen is quietly about one
        // day and the period control says otherwise.
        if (!string.IsNullOrEmpty(_focusDay))
        {
            _root.Children.Add(FocusChip());
        }
        if (_tab == "overview")
        {
            RenderOverview();
            return;
        }
        bool showsValue = _tab == "models";
        bool monospaced = _tab != "harnesses";
        bool isHarness = _tab == "harnesses";
        string title = _tab switch
        {
            "models" => "Models",
            "projects" => "Projects",
            "harnesses" => "Harnesses",
            _ => "Sessions",
        };
        _root.Children.Add(BreakdownTable(title, TabRows(_tab), showsValue, monospaced, isHarness));
    }

    /// <summary>
    /// The pinned day as a chip: the date, what it means, and the way out.
    /// </summary>
    private UIElement FocusChip()
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceS };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var glyph = new SymbolIcon(Symbol.Calendar)
        {
            Foreground = Theme.AccentBrush,
            VerticalAlignment = VerticalAlignment.Center,
        };
        row.Children.Add(glyph);
        var day = new TextBlock
        {
            Text = _focusDay ?? "",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(day, 1);
        row.Children.Add(day);
        var note = new TextBlock
        {
            Text = "Every figure below is about this one day.",
            Opacity = 0.7,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(note, 2);
        row.Children.Add(note);
        var clear = ActionIconGlyph.Button(
            "Clear", ActionIcon.Dismiss, async (_, _) => await ClearFocusDayAsync());
        clear.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(clear, 3);
        row.Children.Add(clear);
        return new Border
        {
            Background = Theme.AccentSoftBrush,
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Padding = new Thickness(Theme.SpaceM),
            Child = row,
        };
    }

    private void RenderOverview()
    {
        var totals = _snapshot?["totals"];
        long events = Format.Long(totals, "events");
        if (events == 0 && _error is null)
        {
            _root.Children.Add(EmptyState.View(
                "Nothing scanned yet",
                "tokenstat reads the session logs the tools on this PC already write. Run a scan and this fills in.",
                EmptyArtKind.FirstBars,
                ActionIconGlyph.Button("Scan now", ActionIcon.Refresh, async (_, _) => await ScanAsync())));
            return;
        }
        _root.Children.Add(MetricTiles(totals));
        _root.Children.Add(DailyCard(SnapshotRows("daily")));
        double width = _contentWidth > 0 ? _contentWidth : 800;
        var models = SnapshotRows("byModel", "by_model");
        var sources = SnapshotRows("bySource", "by_source");
        var projects = SnapshotRows("byProject", "by_project");
        if (width >= 680)
        {
            var row = new Grid { ColumnSpacing = Theme.SpaceL };
            row.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            row.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            var left = RankingCard("Top models", models, isHarness: false, showsValue: true, "models");
            var right = RankingCard("By harness", sources, isHarness: true, showsValue: false, "harnesses");
            Grid.SetColumn(right, 1);
            row.Children.Add(left);
            row.Children.Add(right);
            _root.Children.Add(row);
        }
        else
        {
            _root.Children.Add(RankingCard("Top models", models, isHarness: false, showsValue: true, "models"));
            _root.Children.Add(RankingCard("By harness", sources, isHarness: true, showsValue: false, "harnesses"));
        }
        if (projects.Count > 0)
        {
            _root.Children.Add(RankingCard(
                "Project activity", projects, isHarness: false, showsValue: false, "projects"));
        }
    }

    /// <summary>
    /// The four headline tiles: tokens, list-rate value, sessions, active
    /// days. Four across on a wide pane, two across, then one, like the Mac.
    /// </summary>
    private UIElement MetricTiles(JsonNode? totals)
    {
        var counters = totals?["counters"];
        long total = Format.Long(counters, "total");
        long days = Format.Long(totals, "days");
        long perDay = days > 0 ? total / days : 0;
        var tiles = new List<(string Label, string Value, string Detail)>
        {
            ("Total tokens", Format.Tokens(total), "Including reported cache usage"),
            ("List-rate value", MoneyTotal(SnapshotRows("byModel", "by_model")), "Token valuation, not billed"),
            ("Sessions", Format.Long(totals, "sessions").ToString("N0", CultureInfo.InvariantCulture),
                Format.Long(totals, "events").ToString("N0", CultureInfo.InvariantCulture) + " recorded events"),
            ("Active days", days.ToString("N0", CultureInfo.InvariantCulture),
                Format.Tokens(perDay) + " tokens / active day"),
        };
        double width = _contentWidth > 0 ? _contentWidth : 800;
        int columns = width >= 760 ? 4 : width >= 380 ? 2 : 1;
        var grid = new Grid { ColumnSpacing = Theme.SpaceM, RowSpacing = Theme.SpaceM };
        for (int c = 0; c < columns; c++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
        }
        int rows = (tiles.Count + columns - 1) / columns;
        for (int r = 0; r < rows; r++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }
        for (int i = 0; i < tiles.Count; i++)
        {
            var tile = tiles[i];
            var body = new StackPanel { Spacing = Theme.SpaceS };
            body.Children.Add(new TextBlock
            {
                Text = tile.Label,
                FontSize = Fonts.Callout,
                Opacity = 0.7,
            });
            body.Children.Add(Fonts.Numeric(tile.Value, 22));
            body.Children.Add(new TextBlock
            {
                Text = tile.Detail,
                FontSize = Fonts.Caption,
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
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
            Grid.SetColumn(card, i % columns);
            Grid.SetRow(card, i / columns);
            grid.Children.Add(card);
        }
        return grid;
    }

    private UIElement DailyCard(JsonArray rows)
    {
        return Chrome.Card(
            "Usage over time",
            DailyChart(rows, _chartShowsValue, showsToggle: true),
            "Daily tokens · cache included");
    }

    /// <summary>
    /// Daily bars drawn from rectangles: one star column per day, the bar
    /// anchored to the bottom. The hover summary the Mac draws over the chart
    /// is a tooltip here, which is the closer control on this platform.
    /// </summary>
    private UIElement DailyChart(JsonArray rows, bool showsValue, bool showsToggle)
    {
        var stack = new StackPanel { Spacing = Theme.SpaceM };
        if (rows.Count == 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "No usage in this period. Try a wider range.",
                Opacity = 0.7,
                TextWrapping = TextWrapping.Wrap,
            });
            return stack;
        }
        if (showsToggle)
        {
            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.Children.Add(new TextBlock
            {
                Text = showsValue
                    ? "Daily value at published rates · not billed"
                    : "Daily token volume",
                FontSize = Fonts.Callout,
                Opacity = 0.7,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var toggle = SegmentedCapsule.View(
                new List<(string, string, ActionIcon?)>
                {
                    ("tokens", "Tokens", null),
                    ("value", "List-rate value", null),
                },
                showsValue ? "value" : "tokens",
                value =>
                {
                    _chartShowsValue = value == "value";
                    Render();
                    return Task.CompletedTask;
                });
            toggle.Width = 230;
            Grid.SetColumn(toggle, 1);
            head.Children.Add(toggle);
            stack.Children.Add(head);
        }
        double peak = 0;
        foreach (var row in rows)
        {
            peak = Math.Max(peak, ChartMagnitude(row, showsValue));
        }
        if (peak <= 0)
        {
            peak = 1;
        }
        const double chartHeight = 200;
        var plot = new Grid { Height = chartHeight };
        foreach (var _ in rows)
        {
            plot.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
        }
        int column = 0;
        string peakKey = "";
        double peakValue = -1;
        foreach (var row in rows)
        {
            double magnitude = ChartMagnitude(row, showsValue);
            double height = Math.Max(2, chartHeight * magnitude / peak);
            var key = Format.Text(row, "key");
            if (magnitude > peakValue)
            {
                peakValue = magnitude;
                peakKey = key;
            }
            var bar = new Rectangle
            {
                Fill = Theme.AccentBrush,
                RadiusX = 2,
                RadiusY = 2,
                Height = height,
                VerticalAlignment = VerticalAlignment.Bottom,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Margin = new Thickness(1, 0, 1, 0),
            };
            string tip = key + " · " + Format.Tokens(Format.Long(row?["counters"], "total"))
                + " tokens · " + Money(row);
            ToolTipService.SetToolTip(bar, tip);
            Grid.SetColumn(bar, column);
            plot.Children.Add(bar);
            column++;
        }
        stack.Children.Add(plot);
        var foot = new Grid();
        foot.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        foot.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        string first = Format.Text(rows[0], "key");
        string last = Format.Text(rows[rows.Count - 1], "key");
        foot.Children.Add(new TextBlock
        {
            Text = first == last ? first : first + " to " + last,
            FontSize = Fonts.Caption,
            Opacity = 0.7,
        });
        var right = new TextBlock
        {
            Text = "Peak " + Format.Tokens(PeakTokens(rows, peakKey)) + " · " + peakKey
                + " · " + rows.Count + " recorded days",
            FontSize = Fonts.Caption,
            Opacity = 0.7,
            TextAlignment = TextAlignment.Right,
            TextWrapping = TextWrapping.Wrap,
        };
        Grid.SetColumn(right, 1);
        foot.Children.Add(right);
        stack.Children.Add(foot);
        return stack;
    }

    private static double ChartMagnitude(JsonNode? row, bool showsValue)
    {
        if (showsValue)
        {
            return Math.Max(0, (double)Format.Long(row, "valueMicros") / 1_000_000);
        }
        return Format.Long(row?["counters"], "total");
    }

    private static long PeakTokens(JsonArray rows, string peakKey)
    {
        foreach (var row in rows)
        {
            if (Format.Text(row, "key") == peakKey)
            {
                return Format.Long(row?["counters"], "total");
            }
        }
        return 0;
    }

    /// <summary>
    /// A ranked top six with progress bars, plus a View all button that opens
    /// the full breakdown. Tapping a row opens the tab with that row selected.
    /// </summary>
    private FrameworkElement RankingCard(
        string title, JsonArray rows, bool isHarness, bool showsValue, string tab)
    {
        var stack = new StackPanel { Spacing = 14 };
        if (rows.Count == 0)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "Nothing recorded yet.",
                Opacity = 0.7,
            });
            return Chrome.Card(title, stack, "Ranked by tokens · share of this breakdown");
        }
        double total = 0;
        double peak = 0;
        foreach (var row in rows)
        {
            double tokens = Format.Long(row?["counters"], "total");
            total += tokens;
            peak = Math.Max(peak, tokens);
        }
        if (peak <= 0)
        {
            peak = 1;
        }
        int shown = 0;
        foreach (var row in rows)
        {
            if (shown >= 6)
            {
                break;
            }
            shown++;
            long tokens = Format.Long(row?["counters"], "total");
            double share = total > 0 ? tokens / total : 0;
            var key = Format.Text(row, "key");
            var cell = new StackPanel { Spacing = 7 };
            var head = new Grid();
            head.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            head.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(48) });
            var name = isHarness
                ? Fonts.Text(DisplayName(key, isHarness: true), Fonts.Headline)
                : Fonts.Code(string.IsNullOrEmpty(key) ? "unknown" : key, Fonts.Callout);
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.MaxLines = 1;
            head.Children.Add(name);
            var count = Fonts.Numeric(Format.Tokens(tokens), Fonts.Callout);
            Grid.SetColumn(count, 1);
            head.Children.Add(count);
            var pct = new TextBlock
            {
                Text = share.ToString("P1", CultureInfo.InvariantCulture),
                FontSize = Fonts.Subheadline,
                Opacity = 0.7,
                TextAlignment = TextAlignment.Right,
            };
            Grid.SetColumn(pct, 2);
            head.Children.Add(pct);
            cell.Children.Add(head);
            var track = new Grid { Height = 5 };
            track.Children.Add(new Rectangle
            {
                Fill = Theme.AccentSoftBrush,
                RadiusX = 2.5,
                RadiusY = 2.5,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            });
            track.Children.Add(new Rectangle
            {
                Fill = Theme.AccentBrush,
                RadiusX = 2.5,
                RadiusY = 2.5,
                HorizontalAlignment = HorizontalAlignment.Left,
                Width = 0,
            });
            double fraction = tokens / peak;
            track.SizeChanged += (_, e) =>
            {
                if (track.Children[1] is Rectangle fill && e.NewSize.Width > 0)
                {
                    fill.Width = Math.Max(2, e.NewSize.Width * fraction);
                }
            };
            cell.Children.Add(track);
            var foot = new Grid();
            foot.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            foot.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            foot.Children.Add(new TextBlock
            {
                Text = SessionsCount(row) is string sessions
                    ? sessions + " sessions"
                    : "–",
                FontSize = Fonts.Caption,
                Opacity = 0.7,
            });
            if (showsValue)
            {
                var value = new TextBlock
                {
                    Text = Money(row) + " at list rates",
                    FontSize = Fonts.Caption,
                    Opacity = 0.7,
                };
                Grid.SetColumn(value, 1);
                foot.Children.Add(value);
            }
            cell.Children.Add(foot);
            var hit = new Border
            {
                Child = cell,
                Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(4),
                Margin = new Thickness(-4),
            };
            var captured = key;
            hit.Tapped += (_, _) => SelectAndOpen(tab, captured);
            hit.PointerEntered += (_, _) => hit.Background = Theme.Brush(Theme.RowHighlight);
            hit.PointerExited += (_, _) => hit.Background =
                new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            stack.Children.Add(hit);
        }
        var more = ActionIconGlyph.Button(
            "View all (" + rows.Count + ")", ActionIcon.More,
            (_, _) =>
            {
                _tab = tab;
                _selectedKey = null;
                _visible = FirstPage;
                RebuildTabs();
                Render();
                RefreshInspector();
            });
        return Chrome.Card(title, stack, "Ranked by tokens · share of this breakdown", more);
    }

    private void SelectAndOpen(string tab, string key)
    {
        _tab = tab;
        _selectedKey = key;
        _visible = FirstPage;
        RebuildTabs();
        Render();
        RefreshInspector();
    }

    /// <summary>
    /// The full breakdown for a tab. No sort controls: the archive already
    /// returns rows largest first. Paged past fifty rows, because an archive
    /// holds every session that ever ran and laying out thousands of rows at
    /// once hangs the window.
    /// </summary>
    private UIElement BreakdownTable(
        string title, JsonArray rows, bool showsValue, bool monospaced, bool isHarness)
    {
        if (rows.Count == 0)
        {
            return EmptyState.View(
                "Nothing recorded",
                "No usage landed in this period. Scan, or widen the time range.",
                EmptyArtKind.FirstBars);
        }
        var stack = new StackPanel { Spacing = 0 };
        var header = new Grid { Padding = new Thickness(Theme.SpaceM, Theme.SpaceS, Theme.SpaceM, Theme.SpaceS) };
        header.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(66) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(66) });
        if (showsValue)
        {
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(88) });
        }
        header.Children.Add(HeaderCell("NAME", TextAlignment.Left));
        var sessions = HeaderCell("SESSIONS", TextAlignment.Right);
        Grid.SetColumn(sessions, 1);
        header.Children.Add(sessions);
        var tokens = HeaderCell("TOKENS", TextAlignment.Right);
        Grid.SetColumn(tokens, 2);
        header.Children.Add(tokens);
        if (showsValue)
        {
            var value = HeaderCell("VALUE", TextAlignment.Right);
            Grid.SetColumn(value, 3);
            header.Children.Add(value);
        }
        stack.Children.Add(header);
        stack.Children.Add(new Rectangle
        {
            Height = 1,
            Fill = Theme.BorderBrush,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        });
        long top = 1;
        if (rows.Count > 0)
        {
            top = Math.Max(1, Format.Long(rows[0]?["counters"], "total"));
        }
        int shown = Math.Min(_visible, rows.Count);
        for (int i = 0; i < shown; i++)
        {
            var row = rows[i];
            var key = Format.Text(row, "key");
            long rowTokens = Format.Long(row?["counters"], "total");
            double share = Math.Min(1, (double)rowTokens / top);
            var line = new Grid
            {
                Padding = new Thickness(Theme.SpaceM, Theme.SpaceS, Theme.SpaceM, Theme.SpaceS),
            };
            line.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = new GridLength(1, GridUnitType.Star),
            });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(66) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(66) });
            if (showsValue)
            {
                line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(88) });
            }
            var name = monospaced
                ? Fonts.Code(DisplayName(key, isHarness), Fonts.Callout)
                : Fonts.Text(DisplayName(key, isHarness), Fonts.Headline);
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.MaxLines = 1;
            line.Children.Add(name);
            var sessionCount = Fonts.Tabular(new TextBlock
            {
                Text = SessionsCount(row) ?? "–",
                FontSize = Fonts.Callout,
                Opacity = 0.7,
                TextAlignment = TextAlignment.Right,
            });
            Grid.SetColumn(sessionCount, 1);
            line.Children.Add(sessionCount);
            var tokenCount = Fonts.Tabular(new TextBlock
            {
                Text = Format.Tokens(rowTokens),
                FontSize = Fonts.Callout,
                Opacity = 0.7,
                TextAlignment = TextAlignment.Right,
            });
            Grid.SetColumn(tokenCount, 2);
            line.Children.Add(tokenCount);
            if (showsValue)
            {
                var value = Fonts.Tabular(new TextBlock
                {
                    Text = Money(row),
                    FontSize = Fonts.Callout,
                    TextAlignment = TextAlignment.Right,
                    MaxLines = 1,
                });
                ToolTipService.SetToolTip(value, "Value at list rates, not billed");
                Grid.SetColumn(value, 3);
                line.Children.Add(value);
            }
            var hit = new Border
            {
                Child = line,
                Background = key == _selectedKey
                    ? Theme.Brush(Theme.RowSelected)
                    : new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            };
            var captured = key;
            hit.Tapped += (_, _) =>
            {
                _selectedKey = _selectedKey == captured ? null : captured;
                Render();
                RefreshInspector();
            };
            if (captured != _selectedKey)
            {
                hit.PointerEntered += (_, _) => hit.Background = Theme.Brush(Theme.RowHighlight);
                hit.PointerExited += (_, _) => hit.Background =
                    new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            }
            stack.Children.Add(hit);
            var shareBar = new Grid { Height = 1 };
            shareBar.Children.Add(new Rectangle
            {
                Fill = Theme.AccentBrush,
                Opacity = 0.55,
                HorizontalAlignment = HorizontalAlignment.Left,
                Width = 0,
            });
            double fraction = share;
            shareBar.SizeChanged += (_, e) =>
            {
                if (shareBar.Children[0] is Rectangle fill && e.NewSize.Width > 0)
                {
                    fill.Width = e.NewSize.Width * fraction;
                }
            };
            stack.Children.Add(shareBar);
        }
        int hidden = rows.Count - shown;
        if (hidden > 0)
        {
            var more = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = Theme.SpaceM,
                Padding = new Thickness(Theme.SpaceM, Theme.SpaceS, Theme.SpaceM, Theme.SpaceS),
            };
            more.Children.Add(ActionIconGlyph.Button(
                "Show " + Math.Min(PageStep, hidden) + " more", ActionIcon.More,
                (_, _) =>
                {
                    _visible += PageStep;
                    Render();
                }));
            more.Children.Add(new TextBlock
            {
                Text = hidden + " more hidden",
                FontSize = Fonts.Caption,
                Opacity = 0.55,
                VerticalAlignment = VerticalAlignment.Center,
            });
            more.Children.Add(ActionIconGlyph.Button(
                "Show all", ActionIcon.More,
                (_, _) =>
                {
                    _visible = rows.Count;
                    Render();
                }));
            stack.Children.Add(more);
        }
        var panel = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(Theme.CardRadius),
            Child = stack,
        };
        var outer = new StackPanel { Spacing = Theme.SpaceS };
        outer.Children.Add(new TextBlock
        {
            Text = title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontSize = 13,
        });
        outer.Children.Add(panel);
        outer.Children.Add(new TextBlock
        {
            Text = "List-rate equivalent, not a charge.",
            FontSize = Fonts.Caption,
            Opacity = 0.7,
        });
        return outer;
    }

    private static TextBlock HeaderCell(string text, TextAlignment align)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = Fonts.SectionHeader,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Opacity = 0.55,
            TextAlignment = align,
        };
    }

    private void RefreshInspector()
    {
        _inspectorRoot.Children.Clear();
        _inspectorRoot.Children.Add(PeriodCard());
        _inspectorRoot.Children.Add(SelectionCard());
        _inspectorRoot.Children.Add(ArchiveCard());
    }

    private UIElement PeriodCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        var totals = _snapshot?["totals"];
        long events = Format.Long(totals, "events");
        if (_snapshot is not null && events == 0 && _error is null && !_loading)
        {
            body.Children.Add(Chrome.Empty(
                "Nothing scanned yet",
                "tokenstat reads the session logs the tools on this PC already write. Run a scan and this fills in.",
                ActionIcon.Search));
            return Chrome.Card(_focusDay is null ? "This period" : "This day", body);
        }
        body.Children.Add(Chrome.Stat(
            "Value at list rates", MoneyTotal(SnapshotRows("byModel", "by_model")), "not billed"));
        body.Children.Add(StatPair(
            "Tokens", Format.Tokens(Format.Long(totals?["counters"], "total")),
            "Sessions", Format.Long(totals, "sessions").ToString("N0", CultureInfo.InvariantCulture)));
        body.Children.Add(StatPair(
            "Events", Format.Tokens(Format.Long(totals, "events")),
            "Active days", Format.Long(totals, "days").ToString("N0", CultureInfo.InvariantCulture)));
        var block = _snapshot?["activeBlock"];
        if (block is JsonObject)
        {
            body.Children.Add(new Rectangle
            {
                Height = 1,
                Fill = Theme.BorderBrush,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            });
            var open = new StackPanel { Spacing = Theme.SpaceXs };
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceXs };
            head.Children.Add(new Ellipse
            {
                Fill = Theme.Brush(Theme.Secondary),
                Width = 6,
                Height = 6,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var label = Fonts.Text("Block open", Fonts.Callout, Microsoft.UI.Text.FontWeights.Medium);
            head.Children.Add(label);
            open.Children.Add(head);
            long startMs = Format.Long(block, "startMs");
            string since = startMs > 0
                ? DateTimeOffset.FromUnixTimeMilliseconds(startMs).ToLocalTime().ToString(
                    "HH:mm", CultureInfo.InvariantCulture)
                : "earlier";
            open.Children.Add(new TextBlock
            {
                Text = Format.Tokens(Format.Long(block?["counters"], "total")) + " since " + since,
                FontSize = Fonts.Callout,
                Opacity = 0.7,
            });
            body.Children.Add(open);
        }
        return Chrome.Card(_focusDay is null ? "This period" : "This day", body);
    }

    private UIElement SelectionCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceM };
        JsonNode? selected = null;
        foreach (var row in TabRows(_tab))
        {
            if (Format.Text(row, "key") == _selectedKey)
            {
                selected = row;
                break;
            }
        }
        if (selected is null)
        {
            body.Children.Add(Chrome.Empty(
                "Nothing selected",
                "Pick a row on the left to see what it is made of: fresh input, cache, output, and what the tools did not report.",
                ActionIcon.Next));
            return Chrome.Card("Selected", body);
        }
        var key = Format.Text(selected, "key");
        var name = Fonts.Code(
            _tab == "harnesses" ? DisplayName(key, isHarness: true)
            : string.IsNullOrEmpty(key) ? "unknown" : key,
            Fonts.Callout);
        name.TextWrapping = TextWrapping.Wrap;
        name.MaxLines = 3;
        body.Children.Add(name);
        body.Children.Add(Chrome.Stat("Value", Money(selected)));
        var counters = selected?["counters"];
        var splits = new StackPanel { Spacing = Theme.SpaceXs };
        splits.Children.Add(CounterRow("Fresh input", OptLong(counters, "inputFresh")));
        splits.Children.Add(CounterRow("Cache read", OptLong(counters, "cacheRead")));
        splits.Children.Add(CounterRow("Cache write 5m", OptLong(counters, "cacheWrite5m")));
        splits.Children.Add(CounterRow("Cache write 1h", OptLong(counters, "cacheWrite1h")));
        splits.Children.Add(CounterRow("Output", OptLong(counters, "output")));
        body.Children.Add(splits);
        if (Format.Flag(counters, "hasUnknown"))
        {
            body.Children.Add(new TextBlock
            {
                Text = "A dash means the tool does not report that counter, which is not the same as zero.",
                FontSize = Fonts.Caption,
                Opacity = 0.55,
                TextWrapping = TextWrapping.Wrap,
            });
        }
        body.Children.Add(StatPair(
            "Sessions", SessionsCount(selected) ?? "–",
            "Events", Format.Tokens(Format.Long(selected, "events"))));
        if (_tab == "projects")
        {
            var harnesses = HarnessesInProject(key);
            if (harnesses.Count > 0)
            {
                var group = new StackPanel { Spacing = Theme.SpaceXs };
                group.Children.Add(Fonts.Text(
                    "Harnesses here", Fonts.Callout, Microsoft.UI.Text.FontWeights.Medium));
                foreach (var (split, splitTokens) in harnesses)
                {
                    var line = new Grid();
                    line.ColumnDefinitions.Add(new ColumnDefinition
                    {
                        Width = new GridLength(1, GridUnitType.Star),
                    });
                    line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    line.Children.Add(new TextBlock
                    {
                        Text = HarnessName(split),
                        FontSize = Fonts.Callout,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    });
                    var count = new TextBlock
                    {
                        Text = Format.Tokens(splitTokens),
                        FontSize = Fonts.Caption,
                        Opacity = 0.7,
                    };
                    Grid.SetColumn(count, 1);
                    line.Children.Add(count);
                    group.Children.Add(line);
                }
                body.Children.Add(group);
            }
        }
        if (selected?["unpricedModels"] is JsonArray unpriced && unpriced.Count > 0)
        {
            var group = new StackPanel { Spacing = Theme.SpaceXs };
            group.Children.Add(Fonts.Text(
                "Unpriced models", Fonts.Callout, Microsoft.UI.Text.FontWeights.Medium));
            foreach (var item in unpriced)
            {
                if (item is JsonValue value && value.TryGetValue<string>(out var model)
                    && !string.IsNullOrEmpty(model))
                {
                    group.Children.Add(Fonts.Code(model, Fonts.Caption, opacity: 0.7));
                }
            }
            body.Children.Add(group);
        }
        return Chrome.Card("Selected", body);
    }

    private UIElement ArchiveCard()
    {
        var body = new StackPanel { Spacing = Theme.SpaceS };
        var info = _snapshot?["info"];
        if (info is JsonObject)
        {
            body.Children.Add(KeyValue("Timezone", Format.Text(info, "timezone", "local")));
            body.Children.Add(KeyValue("Core", Format.Text(info, "coreVersion", "unknown")));
            body.Children.Add(KeyValue("Host", "daemon"));
            if (Format.Flag(info, "hasPrices"))
            {
                body.Children.Add(KeyValue(
                    "Rates from", Format.Text(info, "priceBookEffectiveFrom", "unknown")));
            }
            else
            {
                body.Children.Add(new TextBlock
                {
                    Text = "No price book yet, so values are estimated from the model catalog. The app refreshes the price book automatically.",
                    FontSize = Fonts.Caption,
                    TextWrapping = TextWrapping.Wrap,
                    Opacity = 0.7,
                });
            }
        }
        body.Children.Add(new TextBlock
        {
            Text = "Read from this device. Nothing left it.",
            FontSize = Fonts.Caption,
            Opacity = 0.55,
            TextWrapping = TextWrapping.Wrap,
        });
        return Chrome.Card("Archive", body);
    }

    private static UIElement StatPair(string label1, string value1, string label2, string value2)
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceM };
        row.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        row.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        row.Children.Add(Chrome.Stat(label1, value1));
        var second = Chrome.Stat(label2, value2);
        Grid.SetColumn(second, 1);
        row.Children.Add(second);
        return row;
    }

    private static UIElement CounterRow(string label, long? value)
    {
        var line = new Grid();
        line.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = Fonts.Caption,
            Opacity = 0.7,
        });
        var count = Fonts.Tabular(new TextBlock
        {
            Text = value.HasValue ? Format.Tokens(value.Value) : "n/a",
            FontSize = Fonts.Subheadline,
            Opacity = value.HasValue ? 1 : 0.55,
        });
        Grid.SetColumn(count, 1);
        line.Children.Add(count);
        return line;
    }

    private static UIElement KeyValue(string key, string value)
    {
        var line = new Grid();
        line.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = new GridLength(1, GridUnitType.Star),
        });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.Children.Add(new TextBlock
        {
            Text = key,
            FontSize = Fonts.Caption,
            Opacity = 0.7,
        });
        var val = Fonts.Code(value, Fonts.Caption);
        val.TextTrimming = TextTrimming.CharacterEllipsis;
        val.MaxLines = 1;
        Grid.SetColumn(val, 1);
        line.Children.Add(val);
        return line;
    }

    private List<(string Split, long Tokens)> HarnessesInProject(string project)
    {
        var outRows = new List<(string, long)>();
        var split = Format.Items(_snapshot, "projectHarnesses", "project_harnesses");
        if (split is null)
        {
            return outRows;
        }
        foreach (var item in split)
        {
            if (Format.Text(item, "key") == project)
            {
                outRows.Add((
                    Format.Text(item, "split"),
                    Format.Long(item?["counters"], "total")));
            }
        }
        return outRows;
    }

    /// <summary>
    /// A row's session count, or null when the payload carries none. The table
    /// shows a missing mark there instead of a zero that would claim an empty
    /// result rather than no data.
    /// </summary>
    private static string? SessionsCount(JsonNode? row)
    {
        var raw = row?["sessions"];
        if (raw is null || raw.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return null;
        }
        return Format.Long(row, "sessions").ToString("N0", CultureInfo.InvariantCulture);
    }

    private static long? OptLong(JsonNode? node, string name)
    {
        var raw = node?[name];
        if (raw is null || raw.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return null;
        }
        try
        {
            return (long)Math.Round(raw.GetValue<double>());
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// One row's list-rate value, with the Mac Money markers: a plus suffix
    /// when a model could not be priced (the figure is a floor), a tilde
    /// prefix when it was estimated. Never a charge.
    /// </summary>
    private static string Money(JsonNode? row)
    {
        string amount = Format.ListRate(Format.Long(row, "valueMicros"));
        if (row?["unpricedModels"] is JsonArray unpriced && unpriced.Count > 0)
        {
            return amount + "+";
        }
        if (Format.Flag(row, "estimated"))
        {
            return "~" + amount;
        }
        return amount;
    }

    /// <summary>
    /// Fold rows into one value, carrying the qualifiers up. A total built
    /// from an incomplete row is itself incomplete.
    /// </summary>
    private static string MoneyTotal(JsonArray rows)
    {
        long micros = 0;
        bool estimated = false;
        bool complete = true;
        foreach (var row in rows)
        {
            micros += Format.Long(row, "valueMicros");
            estimated |= Format.Flag(row, "estimated");
            if (row?["unpricedModels"] is JsonArray unpriced && unpriced.Count > 0)
            {
                complete = false;
            }
        }
        string amount = Format.ListRate(micros);
        if (!complete)
        {
            return amount + "+";
        }
        if (estimated)
        {
            return "~" + amount;
        }
        return amount;
    }

    private static string DisplayName(string key, bool isHarness)
    {
        if (isHarness)
        {
            return HarnessName(key);
        }
        return string.IsNullOrEmpty(key) ? "unknown" : key;
    }

    /// <summary>
    /// Display name for a harness, the agent CLI that produced the events.
    /// Same spelling tokenstat.ai uses, same as the Home page.
    /// </summary>
    private static string HarnessName(string id)
    {
        if (id == "opencode2")
        {
            return "OpenCode 2";
        }
        return CanonicalHarness(id) switch
        {
            "claude_code" => "Claude Code",
            "claude_code_rollup" or "claude_code_estimate" => "Claude Code (recovered)",
            "codex" => "Codex",
            "grok" => "Grok Build",
            "opencode" => "OpenCode",
            "cline" => "Cline",
            "openclaw" => "OpenClaw",
            "muse" => "Muse",
            "devin" => "Devin CLI",
            "pi" => "Pi",
            "dsh" => "DeepSeek Harness",
            "zed" => "Zed",
            "copilot" => "Copilot CLI",
            "antigravity" => "Antigravity",
            "cursor" => "Cursor",
            "gemini" => "Gemini",
            "hermes" => "Hermes Agent",
            "kilo" => "Kilo Code",
            "kimi" => "Kimi Code",
            "qwen" => "Qwen Code",
            "" => "unknown",
            var canonical => canonical,
        };
    }

    private static string CanonicalHarness(string id)
    {
        if (id == "agy" || id.StartsWith("antigravity", StringComparison.Ordinal))
        {
            return "antigravity";
        }
        if (id == "claude")
        {
            return "claude_code";
        }
        if (id == "opencode2")
        {
            return "opencode";
        }
        return id;
    }

}
