// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Tokenstat.Design;

/// <summary>
/// Content buttons in the Mac capsule family. Metrics come from the Mac Theme:
/// 30pt height, 24pt dense, 8pt radius, 14pt padding, 10pt dense, 13pt medium
/// type, 12pt dense. Every builder picks its mark from ActionIconGlyph, so the
/// one-vocabulary rule holds here too. The older ActionIconGlyph.Button and
/// the Chrome builders stay for their call sites.
/// </summary>
internal static class Buttons
{
    /// <summary>
    /// The filled accent capsule: accent fill, white text, no border. For the
    /// one action a surface offers.
    /// </summary>
    public static Button Primary(string title, ActionIcon icon, RoutedEventHandler click, bool small = false)
    {
        var button = Capsule(
            title, icon, click, small,
            Theme.AccentBrush,
            new SolidColorBrush(Microsoft.UI.Colors.White),
            Theme.AccentBrush);
        button.BorderThickness = new Thickness(0);
        return button;
    }

    /// <summary>
    /// The action somebody may regret: delete, drop, revoke, forget. Same
    /// shape as the rest, danger colour, so a row of actions sorts by colour.
    /// Mirrors the Mac DestructiveButtonStyle: danger at 8 percent behind
    /// danger text, danger at 35 percent around it.
    /// </summary>
    public static Button Destructive(string title, ActionIcon icon, RoutedEventHandler click, bool small = false) =>
        Capsule(
            title, icon, click, small,
            Theme.Brush(WithAlpha(Theme.Danger, 0.08)),
            Theme.Brush(Theme.Danger),
            Theme.Brush(WithAlpha(Theme.Danger, 0.35)));

    /// <summary>
    /// The secondary action: panel fill, hairline border, default text. For
    /// revoke, forget, and every real operation that is not the one being
    /// offered. Mirrors the Mac SecondaryButtonStyle.
    /// </summary>
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

    /// <summary>
    /// A 36px circular toolbar seat. Mirrors the Mac ToolbarIconButton: quiet
    /// control seat, 1px hairline, control grey glyph, accent dot state via
    /// isAccent. Hover lifts the seat and the ring like the Mac does.
    /// </summary>
    public static Button ToolbarIcon(ActionIcon icon, string tooltip, RoutedEventHandler click, bool isAccent = false)
    {
        var button = new Button
        {
            Width = 36,
            Height = 36,
            MinWidth = 0,
            MinHeight = 0,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(18),
            BorderThickness = new Thickness(1),
            Background = Theme.Brush(Theme.ControlSeat),
            BorderBrush = Theme.Brush(WithAlpha(Theme.Border, 0.55)),
            Foreground = Theme.Brush(isAccent ? Theme.Accent : Theme.ControlGlyph),
            Content = icon.Icon(),
        };
        button.Click += click;
        ToolTipService.SetToolTip(button, tooltip);
        AutomationProperties.SetName(button, tooltip);
        button.PointerEntered += (_, _) =>
        {
            button.Background = Theme.Brush(Theme.RowHighlight);
            button.BorderBrush = Theme.Brush(WithAlpha(Theme.Border, 0.9));
            if (!isAccent)
            {
                button.Foreground = Theme.Brush(Theme.ControlGlyphHover);
            }
        };
        button.PointerExited += (_, _) =>
        {
            button.Background = Theme.Brush(Theme.ControlSeat);
            button.BorderBrush = Theme.Brush(WithAlpha(Theme.Border, 0.55));
            if (!isAccent)
            {
                button.Foreground = Theme.Brush(Theme.ControlGlyph);
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
                    icon.Icon(),
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

    /// <summary>
    /// Local property values beat the default disabled look, so dim by hand.
    /// 0.42 matches the Mac styles.
    /// </summary>
    private static void DimWhenDisabled(Button button)
    {
        button.IsEnabledChanged += (_, _) => button.Opacity = button.IsEnabled ? 1 : 0.42;
    }

    private static Color WithAlpha(Color color, double opacity) =>
        Color.FromArgb((byte)(255 * opacity), color.R, color.G, color.B);
}
