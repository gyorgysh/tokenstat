// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Tokenstat.Design;

/// <summary>Shared sidebar and rail metrics, independent of native template defaults.</summary>
internal static class SidebarChrome
{
    public static void ExpandNewHistory(NavigationViewItem row, bool hadChildren, bool paneOpen)
    {
        if (hadChildren || row.MenuItems.Count == 0 || !paneOpen) return;
        // WinUI creates its child repeater lazily. Setting an already-true
        // IsExpanded leaves that newly created repeater collapsed, so refresh
        // the state after the first history rows exist.
        row.IsExpanded = false;
        row.IsExpanded = true;
    }

    public static Grid ProjectContent(NavigationViewItem row, UIElement label, bool remote, params Control[] actions)
    {
        var grid = new Grid { ColumnSpacing = 6, MinHeight = 28 };
        foreach (var width in new[] { new GridLength(16), new GridLength(18), new GridLength(1, GridUnitType.Star) })
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var chevron = new FontIcon { FontSize = 8 };
        var expand = new Button
        {
            Content = chevron, Width = 16, Height = 24, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0), BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        void Paint()
        {
            chevron.Glyph = row.IsExpanded ? "\uE70D" : "\uE76C";
            AutomationProperties.SetName(expand, L10n.Text("windows.mainwindow_xaml.expand_collapse"));
            AlignProject(row);
        }
        expand.Click += (_, _) => row.IsExpanded = !row.IsExpanded;
        row.RegisterPropertyChangedCallback(NavigationViewItem.IsExpandedProperty, (_, _) => Paint());
        row.Loaded += (_, _) => Paint();
        Paint();
        grid.Children.Add(expand);
        var folder = new Viewbox { Width = 16, Height = 16, Child = new SymbolIcon { Symbol = remote ? Symbol.Globe : Symbol.Folder } };
        Grid.SetColumn(folder, 1);
        grid.Children.Add(folder);
        Grid.SetColumn((FrameworkElement)label, 2);
        grid.Children.Add(label);
        foreach (var action in actions)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(action, grid.ColumnDefinitions.Count - 1);
            grid.Children.Add(action);
        }
        return grid;
    }

    // CompactPaneLength is zero because the shell owns its rail. That also
    // makes the native icon seat zero-width. Project icons and the leading
    // disclosure are therefore part of our row, while native selection,
    // hierarchy and keyboard navigation remain owned by NavigationView.
    public static void AlignProject(NavigationViewItem row)
    {
        row.ApplyTemplate();
        Visit(row);
        static void Visit(DependencyObject parent)
        {
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            {
                var child = VisualTreeHelper.GetChild(parent, i);
                if (child is FrameworkElement { Name: "ExpandCollapseChevron" } chevron)
                {
                    chevron.Width = 0;
                    chevron.Visibility = Visibility.Collapsed;
                }
                if (child is NavigationViewItem) continue;
                Visit(child);
            }
        }
    }

    public static NavigationViewItem ChatFooter(string tag, string label, Action toggle, Action? all)
    {
        var grid = new Grid { ColumnSpacing = 8, Tag = label + ":" + (all is not null) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Button Link(string text) => new()
        {
            Content = text, FontSize = 11, Opacity = 0.7, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0, 4, 0, 4), BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        var more = Link(label);
        more.Click += (_, _) => toggle();
        AutomationProperties.SetAutomationId(more, "sidebar.chatMore");
        grid.Children.Add(more);
        if (all is not null)
        {
            var archive = Link(L10n.Text("windows.mainwindow_xaml.see_all_chats.e705024a"));
            archive.Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4,
                Children = { new Viewbox { Width = 11, Height = 11, Child = ActionIcon.Search.Icon() },
                    new TextBlock { Text = L10n.Text("windows.mainwindow_xaml.see_all_chats.e705024a"), FontSize = 11 } } };
            archive.Click += (_, _) => all();
            AutomationProperties.SetAutomationId(archive, "sidebar.chatAll");
            AutomationProperties.SetName(archive, L10n.Text("windows.mainwindow_xaml.see_all_chats.e705024a"));
            Grid.SetColumn(archive, 1);
            grid.Children.Add(archive);
        }
        return new NavigationViewItem { Tag = tag, Content = grid, SelectsOnInvoked = false,
            HorizontalContentAlignment = HorizontalAlignment.Stretch };
    }

    /// <summary>Keep row actions visible while the pointer or keyboard focus is inside.</summary>
    public static void RevealActions(Control row, params Control[] actions)
    {
        bool pointer = false;
        bool focused = false;
        void Paint()
        {
            foreach (var action in actions) action.Opacity = pointer || focused ? 1 : 0;
        }
        void RefreshFocus()
        {
            focused = false;
            if (row.XamlRoot is not null)
                for (var current = FocusManager.GetFocusedElement(row.XamlRoot) as DependencyObject;
                    current is not null; current = VisualTreeHelper.GetParent(current))
                    if (ReferenceEquals(current, row)) { focused = true; break; }
            Paint();
        }
        row.PointerEntered += (_, _) => { pointer = true; Paint(); };
        row.PointerExited += (_, _) => { pointer = false; RefreshFocus(); };
        row.GotFocus += (_, _) => { focused = true; Paint(); };
        // LostFocus bubbles while moving between children of the same row.
        // Inspect the settled focus so the next action remains visible.
        row.LostFocus += (_, _) => row.DispatcherQueue.TryEnqueue(RefreshFocus);
        Paint();
    }

    public static Button RailButton(IconElement icon, string label, RoutedEventHandler click)
    {
        var button = new Button
        {
            Width = 40, Height = 36, MinWidth = 0, MinHeight = 0,
            Padding = new Thickness(0), CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Center,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Content = new Viewbox { Width = 16, Height = 16, Child = icon },
        };
        button.Click += click;
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        Select(button, false);
        return button;
    }

    public static void Select(Button button, bool selected)
    {
        button.Background = selected ? Theme.Brush(static () => Theme.RowSelected)
            : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.Foreground = selected ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph);
        button.Resources["ButtonBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
        button.Resources["ButtonBackgroundPressed"] = Theme.Brush(static () => Theme.RowSelected);
        button.Resources["ButtonForegroundPointerOver"] = selected ? Theme.AccentBrush
            : Theme.Brush(static () => Theme.ControlGlyphHover);
        AutomationProperties.SetItemStatus(button, selected
            ? L10n.Text("windows.segmentedcapsule.selected.57fd7a0c")
            : L10n.Text("windows.segmentedcapsule.not_selected.df12aeba"));
    }

    public static Button Row(string label, ActionIcon icon, RoutedEventHandler click, string? shortcut = null)
    {
        var content = new Grid { ColumnSpacing = 10 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        content.Children.Add(icon.Mark(14));
        var text = new TextBlock { Text = label, FontSize = 13, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis };
        Grid.SetColumn(text, 1);
        content.Children.Add(text);
        if (shortcut is not null)
        {
            var hint = new TextBlock { Text = shortcut, FontSize = 10, Opacity = 0.5,
                VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(hint, 2);
            content.Children.Add(hint);
        }
        var button = new Button
        {
            Content = content, Height = 32, MinHeight = 0, MinWidth = 0,
            Padding = new Thickness(10, 0, 10, 0), Margin = new Thickness(4, 0, 4, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8),
        };
        button.Click += click;
        AutomationProperties.SetName(button, label);
        return button;
    }
}
