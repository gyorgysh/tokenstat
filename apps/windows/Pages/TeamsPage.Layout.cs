// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Tokenstat.Design;

namespace Tokenstat.Pages;

/// <summary>
/// The shape every Teams screen shares, the same one Devices uses: a row
/// with the screen's navigation and tabs on the leading edge and its actions
/// on the trailing edge, then full-width cards. A shared chat docks its
/// composer under the transcript, as the main chat does.
/// </summary>
internal sealed partial class TeamsPage
{
    // Rebuilt on every Reset. A WinUI element keeps its old parent after the
    // screen is cleared, so reusing one in the next row throws.
    private StackPanel _leading = new();
    private StackPanel _trailing = new();
    private readonly StackPanel _dockStack = new() { Spacing = Theme.SpaceS };
    private Border? _dock;

    /// The page root: the scrolling screen above, the composer dock below.
    private Grid BuildRoot()
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer
        {
            Padding = new Thickness(Theme.SpaceM),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _body,
        };
        root.Children.Add(scroll);
        var well = new Border
        {
            Background = Theme.PanelBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(16),
            Padding = new Thickness(Theme.SpaceM),
            MaxWidth = 1040,
            Child = _dockStack,
        };
        _dock = new Border
        {
            Background = Theme.BackgroundBrush,
            BorderBrush = Theme.BorderBrush,
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(Theme.SpaceL, Theme.SpaceM, Theme.SpaceL, Theme.SpaceM),
            Visibility = Visibility.Collapsed,
            Child = well,
        };
        Grid.SetRow(_dock, 1);
        root.Children.Add(_dock);
        return root;
    }

    /// The leading and trailing row every screen starts with.
    private Grid NavigationRow(string title)
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceM, MinHeight = 32 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _leading = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS, VerticalAlignment = VerticalAlignment.Center };
        _trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS, VerticalAlignment = VerticalAlignment.Center };
        _leading.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        _leading.Children.Add(PreviewBadge());
        row.Children.Add(_leading);
        Grid.SetColumn(_trailing, 1);
        row.Children.Add(_trailing);
        return row;
    }

    /// Says that Teams is an early preview, beside the title on every Teams
    /// screen. Hovering shows what that means, and a click or tap opens the
    /// same note, so it also works with touch and the keyboard.
    private static Border PreviewBadge()
    {
        var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        label.Children.Add(new FontIcon { Glyph = "\uE946", FontSize = 10, Foreground = Theme.AccentBrush });
        label.Children.Add(new TextBlock { Text = L10n.Text("common.teams.preview_badge"), FontSize = 11,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = Theme.AccentBrush });
        var badge = new Border
        {
            Child = label, Background = Theme.AccentSoftBrush, CornerRadius = new CornerRadius(999),
            Padding = new Thickness(8, 2, 8, 3), VerticalAlignment = VerticalAlignment.Center, IsTabStop = true,
        };
        ToolTipService.SetToolTip(badge, new ToolTip { Content = PreviewNote(), MaxWidth = 340 });
        var flyout = new Flyout { Content = PreviewNote() };
        FlyoutBase.SetAttachedFlyout(badge, flyout);
        badge.Tapped += (_, _) => FlyoutBase.ShowAttachedFlyout(badge);
        badge.KeyDown += (_, e) =>
        {
            if (e.Key is not (Windows.System.VirtualKey.Enter or Windows.System.VirtualKey.Space)) return;
            FlyoutBase.ShowAttachedFlyout(badge); e.Handled = true;
        };
        AutomationProperties.SetName(badge, L10n.Text("common.teams.preview_title"));
        AutomationProperties.SetHelpText(badge, L10n.Text("common.teams.preview_detail"));
        return badge;
    }
    /// The note behind the badge: what works, what does not yet, and that
    /// the person's own projects are safe whatever happens to Teams.
    private static StackPanel PreviewNote()
    {
        var note = new StackPanel { Spacing = Theme.SpaceS, MaxWidth = 320 };
        note.Children.Add(new TextBlock { Text = L10n.Text("common.teams.preview_title"), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Theme.AccentBrush, TextWrapping = TextWrapping.Wrap });
        note.Children.Add(new TextBlock { Text = L10n.Text("common.teams.preview_detail"), TextWrapping = TextWrapping.Wrap });
        note.Children.Add(new TextBlock { Text = L10n.Text("common.teams.preview_safety"), TextWrapping = TextWrapping.Wrap, Opacity = 0.75 });
        return note;
    }

    /// Back goes first, before the title, where a hand reaches to leave.
    private void NavBack(string name, RoutedEventHandler click) => _leading.Children.Insert(0, Buttons.ToolbarIcon(ActionIcon.Back, name, click));

    /// Tabs sit after the title, as Devices puts its sections first in the row.
    private void Tabs(UIElement tabs) => _leading.Children.Add(tabs);

    /// A quiet icon action at the trailing edge: refresh, drafts, saved asks.
    private Button Tool(ActionIcon icon, string name, RoutedEventHandler click)
    {
        var button = Buttons.ToolbarIcon(icon, name, click);
        _trailing.Children.Add(button);
        return button;
    }

    /// The trailing action this screen adds, pinned to the right like Add device.
    private T Trail<T>(T element) where T : UIElement { _trailing.Children.Add(element); return element; }

    /// A titled card at the full width of the screen, with the shared mark.
    private Border Section(string title, UIElement body, string? subtitle = null, ActionIcon mark = ActionIcon.Profile, FrameworkElement? accessory = null)
    {
        var card = Chrome.Card(title, body, subtitle, accessory, Chrome.CardMark(mark));
        _body.Children.Add(card);
        return card;
    }

    /// Rows inside a card, divided by hairlines.
    private static StackPanel Rows() => new() { Spacing = 0 };

    private static void AddRow(StackPanel rows, UIElement row)
    {
        if (rows.Children.Count > 0) rows.Children.Add(new Border { Height = 1, Background = Theme.BorderBrush });
        rows.Children.Add(row);
    }

    /// A row: what it is on the leading side, what can be done on the trailing side.
    private static Grid Row(UIElement leading, params UIElement[] trailing)
    {
        var row = new Grid { ColumnSpacing = Theme.SpaceM, Padding = new Thickness(0, Theme.SpaceS, 0, Theme.SpaceS), MinHeight = 44 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (leading is FrameworkElement lead) lead.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(leading);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS, VerticalAlignment = VerticalAlignment.Center };
        foreach (var item in trailing) actions.Children.Add(item);
        Grid.SetColumn(actions, 1);
        row.Children.Add(actions);
        return row;
    }

    /// A row that opens something: the whole row is the target, a chevron
    /// says it leads somewhere, and hover tints it like a sidebar row.
    private static Button OpenRow(UIElement content, string name, RoutedEventHandler click)
    {
        var face = new Grid { ColumnSpacing = Theme.SpaceM };
        face.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        face.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        face.Children.Add(content);
        var chevron = ActionIcon.Next.Mark(11);
        chevron.Opacity = 0.5;
        Grid.SetColumn(chevron, 1);
        face.Children.Add(chevron);
        var button = new Button
        {
            Content = face,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(Theme.SpaceS),
            Margin = new Thickness(-Theme.SpaceS, 0, -Theme.SpaceS, 0),
            MinHeight = 44,
        };
        button.Resources["ButtonBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
        button.Resources["ButtonBackgroundPressed"] = Theme.AccentSoftBrush;
        button.Click += click;
        AutomationProperties.SetName(button, name);
        return button;
    }

    /// Name over one quiet line, the text block of a row.
    private static StackPanel Labelled(string title, string? detail = null)
    {
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.Medium, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrEmpty(detail)) text.Children.Add(new TextBlock { Text = detail, FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
        return text;
    }

    /// A role or state, as a small pill.
    private static Border Badge(string text) => new()
    {
        Background = Theme.Brush(static () => Theme.RowHighlight),
        CornerRadius = new CornerRadius(10),
        Padding = new Thickness(8, 2, 8, 2),
        VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock { Text = text, FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Opacity = 0.8 },
    };

    /// A group's first letter on an accent tile, as the Mac marks an organization.
    private static Border Initial(string name) => new()
    {
        Width = 36, Height = 36,
        CornerRadius = new CornerRadius(10),
        Background = Theme.AccentSoftBrush,
        VerticalAlignment = VerticalAlignment.Center,
        Child = new TextBlock
        {
            Text = name.Length == 0 ? "?" : char.ToUpperInvariant(name[0]).ToString(),
            FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = Theme.AccentBrush,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        },
    };

    /// Mark, then text, then whatever trails it, in one horizontal line.
    private static StackPanel Marked(UIElement mark, UIElement text, params UIElement[] after)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceM, VerticalAlignment = VerticalAlignment.Center };
        line.Children.Add(mark); line.Children.Add(text);
        foreach (var item in after) line.Children.Add(item);
        return line;
    }

    /// Something for the composer dock. Shows the dock the first time.
    private void Dock(UIElement element)
    {
        _dockStack.Children.Add(element);
        if (_dock is not null) _dock.Visibility = Visibility.Visible;
    }

    /// Buttons that close an editor or a flow, pinned to the trailing edge.
    private static StackPanel ActionRow(params UIElement[] buttons)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = Theme.SpaceS, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var button in buttons) row.Children.Add(button);
        return row;
    }
}
