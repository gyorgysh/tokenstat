// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design;

internal static class Buttons
{
    public static Button Primary(string title, ActionIcon icon, RoutedEventHandler click, bool small = false)
    {
        var button = Capsule(
            title, icon, click, small,
            Theme.AccentBrush,
            Theme.OnAccentBrush,
            Theme.AccentBrush);
        button.BorderThickness = new Thickness(0);
        return button;
    }

    public static Button Destructive(string title, ActionIcon icon, RoutedEventHandler click, bool small = false) =>
        Capsule(
            title, icon, click, small,
            Theme.Brush(static () => WithAlpha(Theme.Danger, 0.08)),
            Theme.Brush(static () => Theme.Danger),
            Theme.Brush(static () => WithAlpha(Theme.Danger, 0.35)));

    public static Button Secondary(string title, ActionIcon icon, RoutedEventHandler click, bool small = false)
    {
        var button = Capsule(
            title, icon, click, small,
            Theme.PanelBrush,
            null,
            Theme.BorderBrush);
        button.ClearValue(Control.ForegroundProperty);
        return button;
    }

    public static Button ToolbarIcon(ActionIcon icon, string tooltip, RoutedEventHandler click, bool isAccent = false)
    {
        var button = new Button
        {
            Width = 30,
            Height = 30,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            BorderThickness = new Thickness(0),
            Background = isAccent ? Theme.AccentSoftBrush : Theme.ClearBrush,
            Foreground = isAccent ? Theme.AccentBrush : Theme.Brush(static () => Theme.ControlGlyph),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Content = icon.Mark(14),
        };
        button.Resources["ButtonBackgroundPointerOver"] = Theme.Brush(static () => Theme.RowHighlight);
        button.Resources["ButtonBackgroundPressed"] = Theme.AccentSoftBrush;
        button.Click += click;
        ToolTipService.SetToolTip(button, tooltip);
        AutomationProperties.SetName(button, tooltip);
        button.PointerEntered += (_, _) =>
        {
            button.Background = Theme.Brush(static () => Theme.RowHighlight);
            if (!isAccent)
            {
                button.Foreground = Theme.Brush(static () => Theme.ControlGlyphHover);
            }
        };
        button.PointerExited += (_, _) =>
        {
            button.Background = isAccent ? Theme.AccentSoftBrush : Theme.ClearBrush;
            if (!isAccent)
            {
                button.Foreground = Theme.Brush(static () => Theme.ControlGlyph);
            }
        };
        DimWhenDisabled(button);
        return button;
    }

    private static Button Capsule(
        string title,
        ActionIcon icon,
        RoutedEventHandler click,
        bool small,
        Brush background,
        Brush? foreground,
        Brush border)
    {
        var button = new Button
        {
            Background = background,
            BorderBrush = border,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            MinWidth = 0,
            MinHeight = small ? 24 : 30,
            Padding = small ? new Thickness(10, 0, 10, 0) : new Thickness(14, 0, 14, 0),
            FontSize = small ? 12 : 13,
            FontWeight = Microsoft.UI.Text.FontWeights.Medium,
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children =
                {
                    icon.Mark(12),
                    new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center },
                },
            },
        };
        if (foreground != null)
        {
            button.Foreground = foreground;
        }
        button.Click += click;
        AutomationProperties.SetName(button, title);
        DimWhenDisabled(button);
        return button;
    }

    private static void DimWhenDisabled(Button button)
    {
        button.IsEnabledChanged += (_, _) => button.Opacity = button.IsEnabled ? 1 : 0.42;
    }

    private static Color WithAlpha(Color color, double opacity) =>
        Color.FromArgb((byte)(255 * opacity), color.R, color.G, color.B);
}
