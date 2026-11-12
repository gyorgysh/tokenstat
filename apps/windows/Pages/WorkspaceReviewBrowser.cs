// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Tokenstat.Design;
using Tokenstat.Navigation;

namespace Tokenstat.Pages;

/// <summary>One file list and one diff, with a compact picker for narrow panes.</summary>
internal sealed class WorkspaceReviewBrowser : Grid
{
    private readonly ScrollViewer _detail;
    private readonly ListView _files = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly ComboBox _picker = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    private bool _updating;
    /// <summary>The list width the person dragged to, kept for this session.</summary>
    private static double s_listWidth = 210;
    private readonly ColumnDefinition _listColumn;
    private readonly Border _splitter;
    private double _dragStartX = -1;
    private double _dragStartWidth;
    private double _width;

    internal WorkspaceReviewBrowser(IReadOnlyList<string> paths, string? selected,
        UIElement detail, Action<string> select)
    {
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _listColumn = new ColumnDefinition { Width = new GridLength(s_listWidth) };
        ColumnDefinitions.Add(_listColumn);
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(9) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _detail = new ScrollViewer { Content = detail, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        SetRow(_detail, 1); SetColumn(_detail, 2); Children.Add(_detail);
        // A one pixel rule with a wider grab area, so the list can be resized.
        var splitter = new Border { Background = Theme.ClearBrush,
            Child = new Border { Width = 1, Background = Theme.BorderBrush, HorizontalAlignment = HorizontalAlignment.Center } };
        AutomationProperties.SetName(splitter, L10n.Text("common.files"));
        splitter.PointerPressed += (_, e) =>
        {
            _dragStartX = e.GetCurrentPoint(this).Position.X;
            _dragStartWidth = _listColumn.Width.Value;
            splitter.CapturePointer(e.Pointer);
        };
        splitter.PointerMoved += (_, e) =>
        {
            if (_dragStartX < 0) return;
            s_listWidth = ClampListWidth(_dragStartWidth + e.GetCurrentPoint(this).Position.X - _dragStartX, _width);
            _listColumn.Width = new GridLength(s_listWidth);
        };
        splitter.PointerReleased += (_, e) => { _dragStartX = -1; splitter.ReleasePointerCapture(e.Pointer); };
        splitter.PointerCaptureLost += (_, _) => _dragStartX = -1;
        SetRow(splitter, 1); SetColumn(splitter, 1); Children.Add(splitter);
        _splitter = splitter;
        SetRow(_files, 1); Children.Add(_files);
        SetColumnSpan(_picker, 3); Children.Add(_picker);
        var index = -1;
        for (var i = 0; i < paths.Count; i++)
        {
            var path = paths[i];
            if (path == selected) index = i;
            var parts = path.Replace('\\', '/').Split('/');
            var label = new StackPanel { Spacing = 2 };
            label.Children.Add(new TextBlock { Text = parts.LastOrDefault() ?? path,
                TextTrimming = TextTrimming.CharacterEllipsis });
            if (parts.Length > 1) label.Children.Add(new TextBlock {
                Text = string.Join('/', parts.Take(parts.Length - 1)), FontSize = 10, Opacity = .65,
                TextTrimming = TextTrimming.CharacterEllipsis });
            var item = new ListViewItem { Content = label, Tag = path, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            ToolTipService.SetToolTip(item, path);
            _files.Items.Add(item);
            _picker.Items.Add(new ComboBoxItem { Content = path, Tag = path });
        }
        _files.SelectedIndex = index;
        _picker.SelectedIndex = index;
        _files.SelectionChanged += (_, _) => Choose(_files.SelectedIndex);
        _picker.SelectionChanged += (_, _) => Choose(_picker.SelectedIndex);
        void Choose(int chosen)
        {
            if (_updating || chosen < 0 || chosen >= paths.Count) return;
            _updating = true;
            _files.SelectedIndex = chosen;
            _picker.SelectedIndex = chosen;
            _updating = false;
            _detail.ChangeView(null, 0, null, true);
            select(paths[chosen]);
        }
        void Layout(double width)
        {
            _width = width;
            var compact = width < 560;
            _listColumn.Width = new GridLength(compact ? 0 : ClampListWidth(s_listWidth, width));
            ColumnDefinitions[1].Width = new GridLength(compact ? 0 : 9);
            _files.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
            _splitter.Visibility = _files.Visibility;
            _picker.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        }
        SizeChanged += (_, args) => Layout(args.NewSize.Width);
        Layout(0);
    }

    /// <summary>Between 160 and 420 pixels, and never more than half the pane.</summary>
    internal static double ClampListWidth(double width, double pane) =>
        Math.Clamp(width, 160, Math.Max(160, Math.Min(420, pane * 0.5)));

    internal double VerticalOffset => _detail.VerticalOffset;
    internal void RestoreOffset(double offset)
    {
        _detail.UpdateLayout();
        _detail.ChangeView(null, offset, null, true);
    }
}
