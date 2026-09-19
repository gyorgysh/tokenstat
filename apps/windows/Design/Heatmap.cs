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
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace Tokenstat.Design;

/// <summary>
/// One day of the activity grid, as the host calendar payload carries it.
/// Same keys the page already reads: date, value in microdollars at list
/// rates, level 0 to 4, and the optional locked flag.
/// </summary>
internal sealed record HeatDay(string Date, long Value, int Level, bool Locked);

/// <summary>
/// A month label and the week column it sits over, from the host.
/// </summary>
internal sealed record HeatMonth(int Column, string Name);

/// <summary>
/// The activity grid: a year of days, a column per week.
/// A port of the Mac HeatmapView anatomy and math. Constants are transcribed,
/// not tuned: gutter 30, gap as 0.2 of a cell, corner radius 2.5, cell capped
/// at 16, gap capped at half a cell, width quantised to 4.
/// </summary>
internal static class Heatmap
{
    /// <summary>
    /// The grid fed from the host calendar payload the page already parses.
    /// </summary>
    /// <param name="calendar">The activity.calendar answer, rows built by the core.</param>
    /// <param name="selectedDate">The pinned day, YYYY-MM-DD, so the grid can ring it.</param>
    /// <param name="onSelect">Clicking a day pins it in the inspector.</param>
    /// <param name="onHover">The pointer moved over or off a day.</param>
    public static HeatmapView View(
        JsonNode calendar,
        string? selectedDate = null,
        Action<HeatDay?>? onSelect = null,
        Action<HeatDay?>? onHover = null) =>
        new(calendar, selectedDate, onSelect, onHover);
}

/// <summary>
/// The activity grid as one control: month strip, weekday gutter, a canvas of
/// day squares, hover and selection rings, and the Less to More footer.
/// Drawing only. It never packs days into columns itself: the archive stores
/// only days that had events, so packing them together draws a plausible
/// calendar with every date in the wrong place.
/// </summary>
internal sealed class HeatmapView : StackPanel
{
    private const double Gutter = 30;
    private const double GapRatio = 0.2;
    private const double CellCorner = 2.5;
    private const double MaxCell = 16;
    private const double MaxGapRatio = 0.5;
    private const double MonthStripHeight = 11;
    private const double QuantiseStep = 4;

    private sealed record Slot(HeatDay Day, int Row, int Column);

    private sealed class Snapshot
    {
        public List<List<HeatDay?>> Rows { get; } = new();
        public List<HeatMonth> Months { get; } = new();
        public int Weeks;
        public string First = "";
        public string Last = "";
        public string NoticeCode = "";
        public long FetchedAtMs;
        public bool HistoryLocked;
        public int HistoryDays = 30;
    }

    private Snapshot _snap;
    private readonly Action<HeatDay?>? _onSelect;
    private readonly Action<HeatDay?>? _onHover;
    private string? _selectedDate;
    private Slot? _hovered;
    private double _builtWidth = -1;

    private double _cell;
    private double _gap;
    private double _stride;
    private Rectangle? _hoverRing;
    private Rectangle? _selectedRing;
    private Button? _hitRect;
    private StackPanel? _footerLeft;

    public HeatmapView(
        JsonNode calendar,
        string? selectedDate = null,
        Action<HeatDay?>? onSelect = null,
        Action<HeatDay?>? onHover = null)
    {
        Spacing = Theme.SpaceS;
        _snap = Parse(calendar);
        _selectedDate = selectedDate;
        _onSelect = onSelect;
        _onHover = onHover;
        SizeChanged += OnSizeChanged;
        Rebuild();
    }

    public string? SelectedDate => _selectedDate;

    public void SetSelectedDate(string? date)
    {
        _selectedDate = date;
        ApplySelection();
    }

    public void SetCalendar(JsonNode calendar)
    {
        _snap = Parse(calendar);
        _hovered = null;
        Rebuild();
    }

    private void OnSizeChanged(object sender, SizeChangedEventArgs e)
    {
        // Quantised before anything derives from it, like the Mac: a live drag
        // hands this a new sub-pixel width every frame, and rounding to 4
        // turns most frames of a drag into the same grid.
        double width = Quantised(ActualWidth);
        if (Math.Abs(width - _builtWidth) < 0.01)
        {
            return;
        }
        _builtWidth = width;
        Rebuild();
    }

    private void Rebuild()
    {
        Children.Clear();
        _hoverRing = null;
        _selectedRing = null;
        _hitRect = null;
        _footerLeft = null;
        if (_snap.Weeks <= 0 || _snap.Rows.Count == 0)
        {
            Children.Add(EmptyState.View(
                "No activity yet",
                "Scan local logs to fill the year.",
                EmptyArtKind.FirstBars));
            return;
        }

        double width = _builtWidth >= 0 ? _builtWidth : Quantised(ActualWidth);
        _cell = CellSizeFor(width, _snap.Weeks);
        _gap = GapSizeFor(width, _cell, _snap.Weeks);
        _stride = _cell + _gap;

        // Centred, not leading. Once the cell and the gap are both at their
        // ceilings a very wide card has width left over, and all of it
        // collecting on one side reads as the grid having failed to reach
        // the edge.
        var content = new StackPanel { Spacing = _gap };
        content.Children.Add(MonthStrip());
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = _gap };
        row.Children.Add(RowLabels());
        row.Children.Add(GridCanvas());
        content.Children.Add(row);
        var centred = new Grid { HorizontalAlignment = HorizontalAlignment.Center };
        centred.Children.Add(content);
        Children.Add(centred);

        Children.Add(Footer());
        ApplySelection();
        ApplyHoverVisuals();
    }

    private UIElement MonthStrip()
    {
        // Absolute placement rather than a stack of spacers: a month label is
        // wider than the column it belongs to, so laying them out in sequence
        // pushes every later one out of alignment with its week.
        var strip = new Canvas { Height = MonthStripHeight };
        foreach (var month in _snap.Months)
        {
            var label = Fonts.Text(month.Name, 9, opacity: 0.55);
            Canvas.SetLeft(label, Gutter + _gap + month.Column * _stride);
            Canvas.SetTop(label, 0);
            strip.Children.Add(label);
        }
        return strip;
    }

    private UIElement RowLabels()
    {
        var gutter = new StackPanel { Spacing = _gap };
        for (int i = 0; i < _snap.Rows.Count; i++)
        {
            gutter.Children.Add(new TextBlock
            {
                Text = RowLabel(i),
                FontFamily = Fonts.Interface,
                FontSize = 9,
                Opacity = 0.55,
                Width = Gutter,
                Height = _cell,
                VerticalAlignment = VerticalAlignment.Center,
            });
        }
        return gutter;
    }

    private UIElement GridCanvas()
    {
        double contentWidth = _snap.Weeks * _cell + Math.Max(_snap.Weeks - 1, 0) * _gap;
        double contentHeight = _snap.Rows.Count * _cell + Math.Max(_snap.Rows.Count - 1, 0) * _gap;
        var canvas = new Canvas { Width = contentWidth, Height = contentHeight };
        for (int r = 0; r < _snap.Rows.Count; r++)
        {
            for (int c = 0; c < _snap.Weeks; c++)
            {
                var day = DayAt(r, c);
                if (day is null)
                {
                    continue;
                }
                var square = new Rectangle
                {
                    Width = _cell,
                    Height = _cell,
                    RadiusX = CellCorner,
                    RadiusY = CellCorner,
                    Fill = Theme.Brush(Theme.HeatLevel(day.Level)),
                    Opacity = day.Locked ? 0.28 : 1,
                };
                Canvas.SetLeft(square, c * _stride);
                Canvas.SetTop(square, r * _stride);
                canvas.Children.Add(square);
            }
        }

        _selectedRing = new Rectangle
        {
            Width = _cell,
            Height = _cell,
            RadiusX = CellCorner,
            RadiusY = CellCorner,
            Stroke = Theme.AccentBrush,
            StrokeThickness = 1.5,
            Visibility = Visibility.Collapsed,
        };
        canvas.Children.Add(_selectedRing);

        var primary = Theme.DefaultText;
        _hoverRing = new Rectangle
        {
            Width = _cell,
            Height = _cell,
            RadiusX = CellCorner,
            RadiusY = CellCorner,
            Stroke = Theme.Brush(Windows.UI.Color.FromArgb(140, primary.R, primary.G, primary.B)),
            StrokeThickness = 1,
            Visibility = Visibility.Collapsed,
        };
        canvas.Children.Add(_hoverRing);

        // One transparent hit layer over the canvas. It maps a pointer point
        // back to a cell with the same packing math the squares use.
        _hitRect = new Button
        {
            Width = contentWidth,
            Height = contentHeight,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
        };
        _hitRect.Resources["ButtonBackgroundPointerOver"] = _hitRect.Background;
        _hitRect.Resources["ButtonBackgroundPressed"] = _hitRect.Background;
        _hitRect.Resources["ButtonBorderBrushPointerOver"] = _hitRect.Background;
        _hitRect.Resources["ButtonBorderBrushPressed"] = _hitRect.Background;
        AutomationProperties.SetName(_hitRect, $"Activity, {_snap.First} to {_snap.Last}");
        AutomationProperties.SetHelpText(_hitRect, "Use arrow keys to browse days, then Enter to open a day.");
        _hitRect.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnDayKeyDown), true);
        _hitRect.GotFocus += (_, _) => SetHovered(FindDate(_selectedDate) ?? AvailableDays().LastOrDefault());
        _hitRect.PointerMoved += OnPointerMoved;
        _hitRect.PointerExited += (_, _) => SetHovered(null);
        _hitRect.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnPointerPressed), true);
        canvas.Children.Add(_hitRect);

        AutomationProperties.SetName(canvas, $"Activity, {_snap.First} to {_snap.Last}");
        return canvas;
    }

    private UIElement Footer()
    {
        var footer = new StackPanel { Spacing = Theme.SpaceS };
        if (_snap.HistoryLocked)
        {
            footer.Children.Add(HistoryBanner(_snap.HistoryDays));
        }
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _footerLeft = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
        };
        RefreshFooterLeft();
        Grid.SetColumn(_footerLeft, 0);
        row.Children.Add(_footerLeft);

        var legend = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = Theme.SpaceS,
            VerticalAlignment = VerticalAlignment.Center,
        };
        legend.Children.Add(LegendLabel("Less"));
        for (int level = 0; level < 5; level++)
        {
            legend.Children.Add(new Rectangle
            {
                Width = 9,
                Height = 9,
                RadiusX = 2,
                RadiusY = 2,
                Fill = Theme.Brush(Theme.HeatLevel(level)),
            });
        }
        legend.Children.Add(LegendLabel("More"));
        Grid.SetColumn(legend, 2);
        row.Children.Add(legend);
        footer.Children.Add(row);
        return footer;
    }

    private void RefreshFooterLeft()
    {
        if (_footerLeft is null)
        {
            return;
        }
        _footerLeft.Children.Clear();
        if (_hovered is not null)
        {
            _footerLeft.Children.Add(Fonts.Numeric(
                _hovered.Day.Date, 11, Microsoft.UI.Text.FontWeights.Normal));
            _footerLeft.Children.Add(Fonts.Numeric(
                ListRate(_hovered.Day.Value), 11, Microsoft.UI.Text.FontWeights.Medium));
            _footerLeft.Children[0].Opacity = 0.8;
        }
        else
        {
            var range = Fonts.Numeric(
                $"{_snap.First} to {_snap.Last}", 11, Microsoft.UI.Text.FontWeights.Normal);
            range.Opacity = 0.55;
            _footerLeft.Children.Add(range);
            string? freshness = Freshness();
            if (!string.IsNullOrEmpty(freshness))
            {
                var ago = Fonts.Text("· " + freshness, 11);
                if (_snap.NoticeCode == "stale")
                {
                    ago.Foreground = Theme.Brush(Theme.Warning);
                }
                else
                {
                    ago.Opacity = 0.8;
                }
                _footerLeft.Children.Add(ago);
            }
        }
    }

    private static TextBlock LegendLabel(string text) => Fonts.Text(text, 10, opacity: 0.55);

    private void OnPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_hitRect is null)
        {
            return;
        }
        var position = e.GetCurrentPoint(_hitRect).Position;
        SetHovered(SlotAt(position.X, position.Y));
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_hitRect is null)
        {
            return;
        }
        var position = e.GetCurrentPoint(_hitRect).Position;
        var slot = SlotAt(position.X, position.Y);
        if (slot is null)
        {
            return;
        }
        SetHovered(slot);
        _selectedDate = slot.Day.Date;
        ApplySelection();
        _onSelect?.Invoke(slot.Day);
    }

    private List<Slot> AvailableDays()
    {
        var days = new List<Slot>();
        for (var column = 0; column < _snap.Weeks; column++)
        {
            for (var row = 0; row < _snap.Rows.Count; row++)
            {
                if (DayAt(row, column) is HeatDay day && !day.Locked)
                {
                    days.Add(new Slot(day, row, column));
                }
            }
        }
        return days.OrderBy(slot => slot.Day.Date, StringComparer.Ordinal).ToList();
    }

    private void OnDayKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var days = AvailableDays();
        if (days.Count == 0)
        {
            return;
        }
        var index = _hovered is null ? days.Count - 1 : days.FindIndex(day => day.Day.Date == _hovered.Day.Date);
        index = Math.Max(index, 0);
        switch (e.Key)
        {
            case Windows.System.VirtualKey.Left:
                index = Math.Max(index - _snap.Rows.Count, 0);
                break;
            case Windows.System.VirtualKey.Up:
                index = Math.Max(index - 1, 0);
                break;
            case Windows.System.VirtualKey.Right:
                index = Math.Min(index + _snap.Rows.Count, days.Count - 1);
                break;
            case Windows.System.VirtualKey.Down:
                index = Math.Min(index + 1, days.Count - 1);
                break;
            case Windows.System.VirtualKey.Home:
                index = 0;
                break;
            case Windows.System.VirtualKey.End:
                index = days.Count - 1;
                break;
            case Windows.System.VirtualKey.Enter:
            case Windows.System.VirtualKey.Space:
                _selectedDate = days[index].Day.Date;
                ApplySelection();
                _onSelect?.Invoke(days[index].Day);
                e.Handled = true;
                return;
            default:
                return;
        }
        SetHovered(days[index]);
        e.Handled = true;
    }

    private Slot? SlotAt(double x, double y)
    {
        if (x < 0 || y < 0 || _stride <= 0)
        {
            return null;
        }
        int column = (int)(x / _stride);
        int row = (int)(y / _stride);
        if (row < 0 || row >= _snap.Rows.Count || column < 0 || column >= _snap.Weeks)
        {
            return null;
        }
        // Reject the gap band between cells so moving through a gutter clears
        // the hover rather than sticking to the previous day.
        double localX = x - column * _stride;
        double localY = y - row * _stride;
        if (localX > _cell || localY > _cell)
        {
            return null;
        }
        var day = DayAt(row, column);
        if (day is null || day.Locked)
        {
            return null;
        }
        return new Slot(day, row, column);
    }

    private void SetHovered(Slot? slot)
    {
        // Avoid thrashing the parent hover handler when the pointer stays
        // inside the same square.
        if (Equals(slot, _hovered))
        {
            return;
        }
        _hovered = slot;
        ApplyHoverVisuals();
        RefreshFooterLeft();
        _onHover?.Invoke(slot?.Day);
    }

    private void ApplyHoverVisuals()
    {
        if (_hoverRing is null || _hitRect is null)
        {
            return;
        }
        if (_hovered is null)
        {
            _hoverRing.Visibility = Visibility.Collapsed;
            ToolTipService.SetToolTip(_hitRect, null);
            return;
        }
        Canvas.SetLeft(_hoverRing, _hovered.Column * _stride);
        Canvas.SetTop(_hoverRing, _hovered.Row * _stride);
        _hoverRing.Visibility = Visibility.Visible;
        string tip = $"{_hovered.Day.Date}: {ListRate(_hovered.Day.Value)} at list rates";
        ToolTipService.SetToolTip(_hitRect, tip);
        AutomationProperties.SetName(_hitRect, tip);
    }

    private void ApplySelection()
    {
        if (_selectedRing is null)
        {
            return;
        }
        var slot = FindDate(_selectedDate);
        if (slot is null)
        {
            _selectedRing.Visibility = Visibility.Collapsed;
            return;
        }
        Canvas.SetLeft(_selectedRing, slot.Column * _stride);
        Canvas.SetTop(_selectedRing, slot.Row * _stride);
        _selectedRing.Visibility = Visibility.Visible;
    }

    private Slot? FindDate(string? date)
    {
        if (string.IsNullOrEmpty(date))
        {
            return null;
        }
        for (int r = 0; r < _snap.Rows.Count; r++)
        {
            for (int c = 0; c < _snap.Weeks; c++)
            {
                var day = DayAt(r, c);
                if (day?.Date == date)
                {
                    return new Slot(day, r, c);
                }
            }
        }
        return null;
    }

    private HeatDay? DayAt(int row, int column)
    {
        if (row < 0 || row >= _snap.Rows.Count)
        {
            return null;
        }
        var cells = _snap.Rows[row];
        return column >= 0 && column < cells.Count ? cells[column] : null;
    }

    /// <summary>
    /// Square size that makes the week columns span the width, up to MaxCell.
    /// Solved rather than guessed. With gap as a fraction of cell the width is
    /// gutter plus gap plus weeks times cell plus gap, which rearranges to this.
    /// </summary>
    private static double CellSizeFor(double width, int weeks)
    {
        if (weeks <= 0 || width <= 0)
        {
            return 11;
        }
        double columns = weeks;
        double fitted = (width - Gutter) / (GapRatio + columns * (1 + GapRatio));
        return Math.Clamp(fitted, 7, MaxCell);
    }

    /// <summary>
    /// Gap that spends whatever width the capped cells did not. Widening the
    /// gaps keeps the grid spanning the card without making it taller. Capped
    /// in turn, or a very wide window scatters the squares.
    /// </summary>
    private static double GapSizeFor(double width, double cell, int weeks)
    {
        if (weeks <= 0 || width <= 0)
        {
            return cell * GapRatio;
        }
        double columns = weeks;
        double spare = (width - Gutter - columns * cell) / (columns + 1);
        return Math.Clamp(spare, cell * GapRatio, cell * MaxGapRatio);
    }

    private static double Quantised(double length) =>
        Math.Round(length / QuantiseStep, MidpointRounding.AwayFromZero) * QuantiseStep;

    /// <summary>
    /// Only alternate rows are labelled, so the gutter stays quiet. Same choice
    /// the CLI makes.
    /// </summary>
    private static string RowLabel(int row) => row switch
    {
        0 => "Mon",
        2 => "Wed",
        4 => "Fri",
        _ => "",
    };

    /// <summary>
    /// How current the account grid is, in the same words the limit cards use.
    /// Absent on a local grid, which is read from disk and never remembered.
    /// </summary>
    private string? Freshness()
    {
        if (_snap.FetchedAtMs <= 0)
        {
            return null;
        }
        string ago = RelativeTime(_snap.FetchedAtMs);
        return _snap.NoticeCode == "stale" ? "stale, last updated " + ago : "updated " + ago;
    }

    private static Border HistoryBanner(int days)
    {
        var accent = Theme.Accent;
        var lead = new Microsoft.UI.Xaml.Documents.Run
        {
            Text = "Older history is locked. ",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        var body = new Microsoft.UI.Xaml.Documents.Run
        {
            Text = $"Free shows the last {days} days in full. Older days keep the year shape only.",
        };
        var text = new TextBlock
        {
            FontFamily = Fonts.Interface,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
        };
        text.Inlines.Add(lead);
        text.Inlines.Add(body);
        var stack = new StackPanel { Spacing = 6 };
        stack.Children.Add(text);
        stack.Children.Add(new HyperlinkButton
        {
            Content = "Upgrade to see the year",
            NavigateUri = new Uri("https://tokenstat.ai/pricing"),
            FontFamily = Fonts.Interface,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Theme.AccentBrush,
            Padding = new Thickness(0),
        });
        return new Border
        {
            Background = Theme.Brush(Windows.UI.Color.FromArgb(140, accent.R, accent.G, accent.B)),
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 10, 12, 10),
            Child = stack,
        };
    }

    private static Snapshot Parse(JsonNode calendar)
    {
        var snap = new Snapshot();
        if (calendar["rows"] is JsonArray rows)
        {
            foreach (var row in rows)
            {
                var cells = new List<HeatDay?>();
                if (row is JsonArray days)
                {
                    foreach (var cell in days)
                    {
                        if (cell is null || cell.GetValueKind() == JsonValueKind.Null)
                        {
                            cells.Add(null);
                            continue;
                        }
                        string date = Text(cell, "date");
                        if (string.IsNullOrEmpty(date))
                        {
                            cells.Add(null);
                            continue;
                        }
                        cells.Add(new HeatDay(
                            date,
                            Long(cell, "value"),
                            (int)Long(cell, "level"),
                            Flag(cell, "locked")));
                    }
                }
                snap.Rows.Add(cells);
            }
        }
        int width = 0;
        foreach (var cells in snap.Rows)
        {
            width = Math.Max(width, cells.Count);
        }
        snap.Weeks = (int)Long(calendar, "weeks");
        if (snap.Weeks <= 0)
        {
            snap.Weeks = width;
        }

        if (calendar["months"] is JsonArray months)
        {
            foreach (var month in months)
            {
                string name = Text(month, "name");
                if (string.IsNullOrEmpty(name))
                {
                    continue;
                }
                snap.Months.Add(new HeatMonth((int)Long(month, "column"), name));
            }
        }
        if (snap.Months.Count == 0)
        {
            snap.Months.AddRange(DeriveMonths(snap));
        }

        snap.First = Text(calendar, "first");
        snap.Last = Text(calendar, "last");
        snap.NoticeCode = Text(calendar, "noticeCode");
        snap.FetchedAtMs = Long(calendar, "fetchedAtMs");
        snap.HistoryLocked = Flag(calendar, "historyLocked");
        snap.HistoryDays = Math.Max(1, (int)Long(calendar, "historyDays", 30));
        return snap;
    }

    /// <summary>
    /// Month labels from the days themselves, for a host old enough to send no
    /// month strip. The first column whose week holds the first of a month gets
    /// the label, spaced so neighbours cannot overlap.
    /// </summary>
    private static List<HeatMonth> DeriveMonths(Snapshot snap)
    {
        string[] names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        var labels = new List<HeatMonth>();
        int placedAt = -8;
        for (int c = 0; c < snap.Weeks; c++)
        {
            string? first = null;
            for (int r = 0; r < snap.Rows.Count && first is null; r++)
            {
                var day = r < snap.Rows.Count && c < snap.Rows[r].Count ? snap.Rows[r][c] : null;
                if (day is not null && day.Date.Length == 10 && day.Date.EndsWith("-01", StringComparison.Ordinal))
                {
                    first = day.Date;
                }
            }
            if (first is null || c - placedAt < 4)
            {
                continue;
            }
            if (int.TryParse(first.AsSpan(5, 2), out int month) && month >= 1 && month <= 12)
            {
                labels.Add(new HeatMonth(c, names[month - 1]));
                placedAt = c;
            }
        }
        return labels;
    }

    /// <summary>
    /// List-rate micros as a dollar figure. Never a charge. The grid sends one
    /// number per day and the card above it already carries the qualifiers, so
    /// this is the plain figure like the Mac formatSpend.
    /// </summary>
    private static string ListRate(long micros) =>
        (micros / 1_000_000d).ToString("C2", CultureInfo.GetCultureInfo("en-US"));

    private static string RelativeTime(long epochMs)
    {
        DateTimeOffset moment;
        try
        {
            moment = DateTimeOffset.FromUnixTimeMilliseconds(epochMs);
        }
        catch
        {
            return "recently";
        }
        var age = DateTimeOffset.Now - moment;
        if (age < TimeSpan.FromMinutes(1))
        {
            return "just now";
        }
        if (age < TimeSpan.FromHours(1))
        {
            int minutes = Math.Max(1, (int)age.TotalMinutes);
            return minutes == 1 ? "1 minute ago" : $"{minutes} minutes ago";
        }
        if (age < TimeSpan.FromDays(1))
        {
            int hours = Math.Max(1, (int)age.TotalHours);
            return hours == 1 ? "1 hour ago" : $"{hours} hours ago";
        }
        if (age < TimeSpan.FromDays(30))
        {
            int days = Math.Max(1, (int)age.TotalDays);
            return days == 1 ? "1 day ago" : $"{days} days ago";
        }
        return moment.LocalDateTime.ToString("d");
    }

    // Small JSON readers mirroring the page Format helpers. Design stays
    // independent of Pages, so they live here rather than being shared.
    private static string Text(JsonNode? node, string name, string fallback = "")
    {
        if (node is not JsonObject)
        {
            return fallback;
        }
        var value = node?[name];
        if (value is null || value.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return fallback;
        }
        if (value.GetValueKind() == JsonValueKind.String)
        {
            return value.GetValue<string>() ?? fallback;
        }
        string printed = value.ToJsonString().Trim('"');
        return string.IsNullOrEmpty(printed) ? fallback : printed;
    }

    private static long Long(JsonNode? node, string name, long fallback = 0)
    {
        var value = node?[name];
        if (value is null || value.GetValueKind() is JsonValueKind.Null or JsonValueKind.Undefined)
        {
            return fallback;
        }
        try
        {
            return value.GetValueKind() switch
            {
                JsonValueKind.Number => (long)Math.Round(value.GetValue<double>()),
                JsonValueKind.String => double.TryParse(
                    value.GetValue<string>(),
                    NumberStyles.Any,
                    CultureInfo.InvariantCulture,
                    out double n)
                    ? (long)Math.Round(n)
                    : fallback,
                JsonValueKind.True => 1,
                JsonValueKind.False => 0,
                _ => fallback,
            };
        }
        catch
        {
            return fallback;
        }
    }

    private static bool Flag(JsonNode? node, string name) =>
        node?[name] is JsonValue v && v.GetValueKind() == JsonValueKind.True;
}
