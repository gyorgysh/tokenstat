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
        content.Children.Add(new Viewbox { Width = 14, Height = 14, Child = icon.Icon() });
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
